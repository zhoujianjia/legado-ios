import CoreFoundation
import CryptoKit
import Foundation
import Security

// macOS generator tool only, never linked into the iOS app. Private PKCS12 and
// random passwords arrive only through stdin and never become a file or output.
struct Input: Decodable {
    let operation: Operation?
    let path: String
    let keychainPassword: String
    let p12Password: String
    let p12: Data
    let leafCertificate: Data
    let rootCertificate: Data
}
enum Operation: String, Decodable { case importIdentity, reopenIdentity, prepareCodesignAccess, inspectCodesignAccess }
var activeOperation = Operation.importIdentity
enum Stage: String {
    case readInput, createKeychain, createTrustedApplications, createACL, importPKCS12
    case findImportedIdentity, findStoredIdentity, matchLeaf, findRoot, privateKey, signChallenge, verifyChallenge, complete
    case openKeychain, unlockKeychain, keychainStatus, legacyIdentitySearch
    case inspectKeyACL, prepareKeyACL
}
struct Failure: Error { let stage: Stage; let status: OSStatus }
func keyFailure(_ stage: Stage, _ error: Unmanaged<CFError>?, fallback: OSStatus) -> Failure {
    guard let error else { return Failure(stage: stage, status: fallback) }
    let value = error.takeRetainedValue()
    guard CFEqual(CFErrorGetDomain(value), kCFErrorDomainOSStatus),
          let status = OSStatus(exactly: CFErrorGetCode(value)) else { return Failure(stage: stage, status: fallback) }
    return Failure(stage: stage, status: status)
}
func require(_ status: OSStatus, at stage: Stage) throws {
    guard status == errSecSuccess else { throw Failure(stage: stage, status: status) }
}
func report(_ value: [String: Any]) {
    // Only typed stages/status and public fingerprints are serialized here.
    // Never describe an Error or emit stdin, private key data or passwords.
    do {
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        FileHandle.standardOutput.write(bytes + Data([10]))
    } catch { fputs("Owned public status encoding failed\n", stderr) }
}
func fingerprint(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
func run() throws -> [String: Any] {
    try require(SecKeychainSetUserInteractionAllowed(false), at: .readInput)
    let inputHandle = FileHandle.standardInput
    guard let bytes = try inputHandle.read(upToCount: 1_048_577), bytes.count <= 1_048_576,
          (try inputHandle.read(upToCount: 1) ?? Data()).isEmpty else { throw Failure(stage: .readInput, status: errSecParam) }
    let input = try JSONDecoder().decode(Input.self, from: bytes)
    activeOperation = input.operation ?? .importIdentity
    guard (activeOperation != .importIdentity ? input.p12.isEmpty && input.p12Password.isEmpty : !input.p12.isEmpty && (1...256).contains(input.p12Password.utf8.count)),
          input.p12.count <= 524_288,
          (1...65_536).contains(input.leafCertificate.count), (1...65_536).contains(input.rootCertificate.count),
          (1...256).contains(input.keychainPassword.utf8.count),
          let expectedLeaf = SecCertificateCreateWithData(nil, input.leafCertificate as CFData),
          SecCertificateCreateWithData(nil, input.rootCertificate as CFData) != nil else {
        throw Failure(stage: .readInput, status: errSecParam)
    }
    if activeOperation != .importIdentity {
        // Run in a fresh process after import/partition changes. Open only the
        // caller-owned Keychain; neither default nor global search list changes.
        var reopened: SecKeychain?
        try require(SecKeychainOpen(input.path, &reopened), at: .openKeychain)
        guard let reopened else { throw Failure(stage: .openKeychain, status: errSecInvalidKeychain) }
        var initialStatus: SecKeychainStatus = 0
        try require(SecKeychainGetStatus(reopened, &initialStatus), at: .keychainStatus)
        let initiallyUnlocked = initialStatus & SecKeychainStatus(kSecUnlockStateStatus) != 0
        try input.keychainPassword.withCString { password in
            try require(SecKeychainUnlock(reopened, UInt32(input.keychainPassword.utf8.count), password, true), at: .unlockKeychain)
        }
        var keychainStatus: SecKeychainStatus = 0
        try require(SecKeychainGetStatus(reopened, &keychainStatus), at: .keychainStatus)
        let unlocked = keychainStatus & SecKeychainStatus(kSecUnlockStateStatus) != 0
        let readable = keychainStatus & SecKeychainStatus(kSecReadPermStatus) != 0
        let writable = keychainStatus & SecKeychainStatus(kSecWritePermStatus) != 0
        guard unlocked && readable && writable else { throw Failure(stage: .keychainStatus, status: errSecInteractionNotAllowed) }
        let legacyCount = try legacySigningIdentityCount(reopened, expected: input.leafCertificate)
        var value = try verifyStoredIdentity(reopened, input: input, expectedLeaf: expectedLeaf, importedCount: nil)
        value["schemaVersion"] = activeOperation == .reopenIdentity ? 2 : 3
        value["operation"] = activeOperation.rawValue
        value["legacySigningIdentityCount"] = legacyCount
        value["keychainUnlockedBeforeRequest"] = initiallyUnlocked
        value["keychainUnlocked"] = unlocked; value["keychainReadable"] = readable; value["keychainWritable"] = writable
        return value
    }
    var keychain: SecKeychain?
    let status = input.keychainPassword.withCString { password in
        SecKeychainCreate(input.path, UInt32(input.keychainPassword.utf8.count), password, false, nil, &keychain)
    }
    try require(status, at: .createKeychain)
    guard let keychain else { throw Failure(stage: .createKeychain, status: errSecInternalComponent) }
    var application: SecTrustedApplication?
    try require(SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &application), at: .createTrustedApplications)
    guard let application else {
        throw Failure(stage: .createTrustedApplications, status: errSecInternalComponent)
    }
    // The importer actually tests its newly imported key. Permit only that
    // current tool and codesign, never an allow-all trusted-application ACL.
    var thisTool: SecTrustedApplication?
    try require(SecTrustedApplicationCreateFromPath(nil, &thisTool), at: .createTrustedApplications)
    guard let thisTool else { throw Failure(stage: .createTrustedApplications, status: errSecInternalComponent) }
    var access: SecAccess?
    try require(SecAccessCreate("Owned short-lived fixture" as CFString, [application, thisTool] as CFArray, &access), at: .createACL)
    guard let access else { throw Failure(stage: .createACL, status: errSecInternalComponent) }
    // This one new owned identity explicitly authorizes the current importer
    // to edit its ACL before import. The actual owner is recognized by the
    // public API's owner-edit rejection, not by an ordinary CHANGE_ACL tag.
    // Existing subjects/prompt survive; no global key or trust setting changes.
    try require(YueduOwnedAccessAuthorizeCreator(access), at: .createACL)
    let options: [String: Any] = [kSecImportExportPassphrase as String: input.p12Password,
        kSecImportExportKeychain as String: keychain, kSecImportExportAccess as String: access]
    var imported: CFArray?
    let result = SecPKCS12Import(input.p12 as CFData, options as CFDictionary, &imported)
    try require(result, at: .importPKCS12)
    guard let imported, (1...16).contains(CFArrayGetCount(imported)),
          let items = imported as? [[String: Any]] else { throw Failure(stage: .findImportedIdentity, status: errSecDecode) }
    var importedIdentities: [SecIdentity] = []
    for item in items {
        if let raw = item[kSecImportItemIdentity as String] {
            guard CFGetTypeID(raw as CFTypeRef) == SecIdentityGetTypeID() else { throw Failure(stage: .findImportedIdentity, status: errSecDecode) }
            importedIdentities.append(raw as! SecIdentity)
        }
    }
    guard importedIdentities.count == 1 else { throw Failure(stage: .findImportedIdentity, status: errSecItemNotFound) }
    var importedLeaf: SecCertificate?
    try require(SecIdentityCopyCertificate(importedIdentities[0], &importedLeaf), at: .matchLeaf)
    guard let importedLeaf, SecCertificateCopyData(importedLeaf) as Data == input.leafCertificate else {
        throw Failure(stage: .matchLeaf, status: errSecDecode)
    }
    return try verifyStoredIdentity(keychain, input: input, expectedLeaf: expectedLeaf, importedCount: items.count)
}

func legacySigningIdentityCount(_ keychain: SecKeychain, expected: Data) throws -> Int {
    // codesign's historical identity search uses the legacy sign-use search,
    // while the existing proof uses SecItemCopyMatching. Both must really find
    // this exact leaf in this one owned file before codesign is invoked again.
    // This does not assert that the installed codesign implementation uses an
    // identical search, or that codesign's own ACL has executed successfully.
    var count: UInt32 = 0
    try require(YueduOwnedIdentitySearchCount(keychain, expected as CFData, &count), at: .legacyIdentitySearch)
    guard count == 1 else { throw Failure(stage: .legacyIdentitySearch, status: errSecItemNotFound) }
    return Int(count)
}

func verifyStoredIdentity(_ keychain: SecKeychain, input: Input, expectedLeaf: SecCertificate, importedCount: Int?) throws -> [String: Any] {
    // A successful import-return dictionary alone is insufficient: query the
    // actual one owned Keychain that the later codesign command selects.
    var found: CFTypeRef?
    try require(SecItemCopyMatching([kSecClass as String: kSecClassIdentity,
        kSecMatchSearchList as String: [keychain], kSecReturnRef as String: true,
        kSecMatchLimit as String: kSecMatchLimitAll] as CFDictionary, &found), at: .findStoredIdentity)
    guard let stored = found as? [SecIdentity], stored.count == 1 else { throw Failure(stage: .findStoredIdentity, status: errSecItemNotFound) }
    var leaf: SecCertificate?
    try require(SecIdentityCopyCertificate(stored[0], &leaf), at: .matchLeaf)
    guard let leaf, SecCertificateCopyData(leaf) as Data == input.leafCertificate else {
        throw Failure(stage: .matchLeaf, status: errSecDecode)
    }
    var certificates: CFTypeRef?
    try require(SecItemCopyMatching([kSecClass as String: kSecClassCertificate,
        kSecMatchSearchList as String: [keychain], kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitAll] as CFDictionary, &certificates), at: .findRoot)
    guard let certificateBytes = certificates as? [Data], certificateBytes.count <= 16,
          certificateBytes.contains(input.rootCertificate), certificateBytes.contains(input.leafCertificate) else {
        throw Failure(stage: .findRoot, status: errSecItemNotFound)
    }
    var key: SecKey?
    try require(SecIdentityCopyPrivateKey(stored[0], &key), at: .privateKey)
    guard let key, let keyPublic = SecKeyCopyPublicKey(key), let certificateKey = SecCertificateCopyKey(expectedLeaf) else {
        throw Failure(stage: .privateKey, status: errSecInvalidKeyRef)
    }
    var error: Unmanaged<CFError>?
    guard let keyBytes = SecKeyCopyExternalRepresentation(keyPublic, &error) as Data? else {
        throw keyFailure(.privateKey, error, fallback: errSecInvalidKeyRef)
    }
    guard let certBytes = SecKeyCopyExternalRepresentation(certificateKey, &error) as Data? else {
        throw keyFailure(.privateKey, error, fallback: errSecInvalidKeyRef)
    }
    guard keyBytes == certBytes, SecKeyIsAlgorithmSupported(key, .sign, .rsaSignatureMessagePKCS1v15SHA256) else {
        throw Failure(stage: .privateKey, status: errSecInvalidKeyRef)
    }
    var aclFacts: [String: Any] = [:]
    if activeOperation == .prepareCodesignAccess || activeOperation == .inspectCodesignAccess {
        var before = YueduOwnedKeyACLReport(), after = YueduOwnedKeyACLReport()
        var changed: UInt32 = 0
        let preparing = activeOperation == .prepareCodesignAccess
        try require(YueduOwnedKeyACLInspect(keychain, key, preparing ? 1 : 0, &before, &after, &changed),
                    at: preparing ? .prepareKeyACL : .inspectKeyACL)
        guard changed == (preparing ? 1 : 0) else { throw Failure(stage: .inspectKeyACL, status: errSecDecode) }
        if preparing {
            var partitionBefore = YueduOwnedKeyACLReport(), partitionAfter = YueduOwnedKeyACLReport()
            try input.keychainPassword.withCString { password in
                try require(YueduOwnedKeyCreatePartition(keychain, key,
                    UnsafeRawPointer(password).assumingMemoryBound(to: UInt8.self),
                    UInt32(input.keychainPassword.utf8.count), &partitionBefore, &partitionAfter), at: .prepareKeyACL)
            }
            guard NSDictionary(dictionary: aclReport(after)).isEqual(to: aclReport(partitionBefore)) else {
                throw Failure(stage: .prepareKeyACL, status: errSecDecode)
            }
            after = partitionAfter
        }
        guard after.partitionACLCount == 1, after.partitionIDCount == 4, after.applePartitionCount == 1,
              after.appleToolPartitionCount == 1, after.codesignPartitionCount == 1,
              after.creatorPartitionCount == 1, after.otherPartitionCount == 0 else {
            throw Failure(stage: .inspectKeyACL, status: errSecDecode)
        }
        aclFacts = ["aclBefore": aclReport(before), "aclAfter": aclReport(after), "classicACLChanged": changed == 1,
                    "partitionACLAdded": preparing, "creatorPartitionVerified": true,
                    "fixtureOwnerPolicy": "current-importer-subject-before-import"]
    }
    // In schema 3 this challenge happens after any actual ACL publication.
    // Only the following separate codesign process can prove its own access.
    let challenge = Data(("owned-keychain-identity-preflight-v1-" + UUID().uuidString).utf8)
    guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, challenge as CFData, &error) as Data? else {
        throw keyFailure(.signChallenge, error, fallback: errSecInternalComponent)
    }
    guard SecKeyVerifySignature(certificateKey, .rsaSignatureMessagePKCS1v15SHA256, challenge as CFData, signature as CFData, &error) else {
        throw keyFailure(.verifyChallenge, error, fallback: errSecVerifyFailed)
    }
    var value: [String: Any] = ["schemaVersion": 1, "stage": Stage.complete.rawValue, "status": "passed", "osStatus": 0,
        "storedIdentityCount": stored.count,
        "leafSHA256": fingerprint(input.leafCertificate), "rootSHA256": fingerprint(input.rootCertificate),
        "privateKeySignatureVerified": true,
        // This process performed the preflight. Another process's ACL use is
        // proven only when the subsequent real codesign command succeeds.
        "codesignACLExecutionVerified": false]
    if let importedCount { value["importedItemCount"] = importedCount }
    value.merge(aclFacts) { _, new in new }
    return value
}

func aclReport(_ report: YueduOwnedKeyACLReport) -> [String: Any] {
    ["privateKeyCount": Int(report.privateKeyCount), "sameOwnedKeychain": report.sameOwnedKeychain == 1,
     "aclCount": Int(report.aclCount), "signACLCount": Int(report.signACLCount),
     "signAppListACLCount": Int(report.signAppListACLCount), "signAllowAnyACLCount": Int(report.signAllowAnyACLCount),
     "signEmptyACLCount": Int(report.signEmptyACLCount), "signTrustedApplicationCount": Int(report.signTrustedApplicationCount),
     "codesignPathEntryCount": Int(report.codesignPathEntryCount), "partitionACLCount": Int(report.partitionACLCount),
     "partitionIDCount": Int(report.partitionIDCount), "applePartitionCount": Int(report.applePartitionCount),
     "appleToolPartitionCount": Int(report.appleToolPartitionCount), "codesignPartitionCount": Int(report.codesignPartitionCount),
     "creatorPartitionCount": Int(report.creatorPartitionCount),
     "otherPartitionCount": Int(report.otherPartitionCount), "opaqueACLCount": Int(report.opaqueACLCount),
     "unknownAuthorizationCount": Int(report.unknownAuthorizationCount),
     "ownerACLCount": Int(report.ownerACLCount), "ownerAllowAnyACLCount": Int(report.ownerAllowAnyACLCount),
     "ownerTrustedApplicationCount": Int(report.ownerTrustedApplicationCount),
     "creatorOwnerPathEntryCount": Int(report.creatorOwnerPathEntryCount)]
}
do { report(try run()) } catch {
    let failure = error as? Failure
    var value: [String: Any] = ["schemaVersion": activeOperation == .importIdentity ? 1 : (activeOperation == .reopenIdentity ? 2 : 3),
        "stage": (failure?.stage ?? .readInput).rawValue, "status": "failed", "osStatus": Int(failure?.status ?? errSecDecode)]
    if activeOperation != .importIdentity { value["operation"] = activeOperation.rawValue }
    report(value)
    // Never echo stdin, passwords, key data or Error.userInfo.
    fputs("Owned identity import failed\n", stderr); exit(1)
}
