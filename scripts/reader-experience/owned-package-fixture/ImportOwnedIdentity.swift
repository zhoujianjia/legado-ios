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
enum Operation: String, Decodable { case importIdentity, reopenIdentity }
var activeOperation = Operation.importIdentity
enum Stage: String {
    case readInput, createKeychain, createTrustedApplications, createACL, importPKCS12
    case findImportedIdentity, findStoredIdentity, matchLeaf, findRoot, privateKey, signChallenge, verifyChallenge, complete
    case openKeychain, unlockKeychain, keychainStatus, legacyIdentitySearch
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
    guard (activeOperation == .reopenIdentity ? input.p12.isEmpty && input.p12Password.isEmpty : !input.p12.isEmpty && (1...256).contains(input.p12Password.utf8.count)),
          input.p12.count <= 524_288,
          (1...65_536).contains(input.leafCertificate.count), (1...65_536).contains(input.rootCertificate.count),
          (1...256).contains(input.keychainPassword.utf8.count),
          let expectedLeaf = SecCertificateCreateWithData(nil, input.leafCertificate as CFData),
          SecCertificateCreateWithData(nil, input.rootCertificate as CFData) != nil else {
        throw Failure(stage: .readInput, status: errSecParam)
    }
    if activeOperation == .reopenIdentity {
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
        value["schemaVersion"] = 2; value["operation"] = Operation.reopenIdentity.rawValue
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
    var search: SecIdentitySearch?
    try require(SecIdentitySearchCreate(keychain, CSSM_KEYUSE(CSSM_KEYUSE_SIGN), &search), at: .legacyIdentitySearch)
    guard let search else { throw Failure(stage: .legacyIdentitySearch, status: errSecInternalComponent) }
    var count = 0
    while true {
        var identity: SecIdentity?
        let status = SecIdentitySearchCopyNext(search, &identity)
        if status == errSecItemNotFound { break }
        try require(status, at: .legacyIdentitySearch)
        guard let identity, count < 16 else { throw Failure(stage: .legacyIdentitySearch, status: errSecDecode) }
        var certificate: SecCertificate?
        try require(SecIdentityCopyCertificate(identity, &certificate), at: .legacyIdentitySearch)
        guard let certificate, SecCertificateCopyData(certificate) as Data == expected else {
            throw Failure(stage: .legacyIdentitySearch, status: errSecDecode)
        }
        count += 1
    }
    guard count == 1 else { throw Failure(stage: .legacyIdentitySearch, status: errSecItemNotFound) }
    return count
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
    return value
}
do { report(try run()) } catch {
    let failure = error as? Failure
    var value: [String: Any] = ["schemaVersion": activeOperation == .reopenIdentity ? 2 : 1,
        "stage": (failure?.stage ?? .readInput).rawValue, "status": "failed", "osStatus": Int(failure?.status ?? errSecDecode)]
    if activeOperation == .reopenIdentity { value["operation"] = Operation.reopenIdentity.rawValue }
    report(value)
    // Never echo stdin, passwords, key data or Error.userInfo.
    fputs("Owned identity import failed\n", stderr); exit(1)
}
