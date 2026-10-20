import CryptoKit
import Darwin
import Foundation
import Security

/// Explicit user-selected, password-protected PKCS #12 input only. This is a
/// stateless use case of the App's existing Keychain owner, not a pairing store,
/// discovery mechanism, or grant of local-device installation permission.
enum SelfRenewalPairingIdentityImport {
    typealias Device = SelfRenewalAppSession.DeviceConfiguration
    typealias Transport = SelfRenewalAuthenticatedDeviceTransport
    enum Failure: Error, Sendable, Equatable {
        case invalidPublicConfiguration, invalidPassword, invalidPKCS12(OSStatus)
        case hostCertificateMismatch, invalidCertificateChain, keyPossession
        case keychain(OSStatus), invalidPersistentReference
    }
    /// Only public pairing facts. HostCertificate is required so that selecting
    /// a different, otherwise valid P12 cannot silently change the host identity.
    /// HostID/SystemBUID are the existing pairing values, never newly generated.
    struct PublicConfiguration: Codable, Sendable, Equatable {
        let schema: Int
        let hostCertificateDER: Data
        let deviceCertificateDER: Data
        let rootCertificateDER: Data
        let hostID: String
        let systemBUID: String
        let numericAddress: String
        let port: UInt16
        let interfaceIndex: UInt32
    }
    private static let publicKeys: Set<String> = ["schema", "hostCertificateDER", "deviceCertificateDER",
        "rootCertificateDER", "hostID", "systemBUID", "numericAddress", "port", "interfaceIndex"]

    static func decodePublicConfiguration(_ raw: Data) throws -> PublicConfiguration {
        precondition(!Thread.isMainThread)
        try Task.checkCancellation()
        guard !raw.isEmpty, raw.count <= SelfRenewalAppSession.maximumConfigurationBytes else {
            throw Failure.invalidPublicConfiguration
        }
        let value: PublicConfiguration
        do {
            // Codable alone ignores unknown keys. Reject whole pairing plists,
            // private-key/password fields and accidental private JSON exports.
            guard let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  Set(object.keys) == publicKeys else { throw Failure.invalidPublicConfiguration }
            value = try JSONDecoder().decode(PublicConfiguration.self, from: raw)
        } catch { throw Failure.invalidPublicConfiguration }
        guard value.schema == 1,
              [value.hostID, value.systemBUID].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.utf8.contains(0) }),
              [value.hostCertificateDER, value.deviceCertificateDER, value.rootCertificateDER].allSatisfy({
                  !$0.isEmpty && $0.count <= 65_536 && SecCertificateCreateWithData(nil, $0 as CFData) != nil
              }), value.hostCertificateDER != value.rootCertificateDER,
              value.deviceCertificateDER != value.rootCertificateDER,
              value.hostCertificateDER != value.deviceCertificateDER,
              value.port > 0, value.numericAddress.utf8.count <= 64,
              !value.numericAddress.utf8.contains(0) else { throw Failure.invalidPublicConfiguration }
        var v4 = in_addr(), v6 = in6_addr()
        guard inet_pton(AF_INET, value.numericAddress, &v4) == 1 ||
              inet_pton(AF_INET6, value.numericAddress, &v6) == 1 else { throw Failure.invalidPublicConfiguration }
        return value
    }

    /// Called off main while Session owns busy and its existing journal flock.
    /// Scopes, P12 bytes and password are confined to this call. There is no raw
    /// input copy, private-key export, credential log, new file or access group.
    static func importIdentity(pkcs12: URL, password: String, publicConfiguration: URL, at date: Date) throws -> Device {
        precondition(!Thread.isMainThread)
        let started = SourcePerfTrace.now
        var inputBytes = 0
        defer {
            SourcePerfTrace.record("renewal.app.import-pairing-identity",
                "bytes=\(inputBytes) main=\(Thread.isMainThread)", since: started, thresholdMs: 0)
        }
        try Task.checkCancellation()
        guard !password.isEmpty, password.utf8.count <= 1_024, !password.utf8.contains(0) else {
            throw Failure.invalidPassword
        }
        let publicScope = publicConfiguration.startAccessingSecurityScopedResource()
        defer { if publicScope { publicConfiguration.stopAccessingSecurityScopedResource() } }
        let facts = try decodePublicConfiguration(SelfRenewalAppSession.readBounded(publicConfiguration,
            maximum: SelfRenewalAppSession.maximumConfigurationBytes))
        try validateCertificate(facts.hostCertificateDER, rootDER: facts.rootCertificateDER, at: date)
        try validateCertificate(facts.deviceCertificateDER, rootDER: facts.rootCertificateDER, at: date)
        let privateScope = pkcs12.startAccessingSecurityScopedResource()
        defer { if privateScope { pkcs12.stopAccessingSecurityScopedResource() } }
        let raw = try SelfRenewalAppSession.readBounded(pkcs12, maximum: SelfRenewalAppSession.maximumConfigurationBytes)
        inputBytes = raw.count
        let options = [kSecImportExportPassphrase as String: password]
        var imported: CFArray?
        // On iOS SecPKCS12Import returns in-memory identities; SecItemAdd below
        // is the explicit persistence boundary (Apple Security documentation).
        let status = SecPKCS12Import(raw as CFData, options as CFDictionary, &imported)
        guard status == errSecSuccess else { throw Failure.invalidPKCS12(status) }
        guard let items = imported as? [[String: Any]], items.count == 1,
              let value = items[0][kSecImportItemIdentity as String] else { throw Failure.invalidPKCS12(errSecDecode) }
        let candidate = value as CFTypeRef
        guard CFGetTypeID(candidate) == SecIdentityGetTypeID() else { throw Failure.invalidPKCS12(errSecDecode) }
        let identity = unsafeBitCast(candidate, to: SecIdentity.self)
        try validateIdentity(identity, facts: facts)
        try Task.checkCancellation()
        // Exact, deterministic owner label makes a lost Document ACK retry
        // reuse the same confirmed item. Never enumerate or relabel identities.
        let digest = SHA256.hash(data: facts.hostCertificateDER).map { String(format: "%02x", $0) }.joined()
        let label = "com.yuedu-reader.self-renewal.pairing.\(digest)"
        let reference: Data
        if let existing = try ownedReference(label: label, facts: facts) { reference = existing }
        else {
            var result: CFTypeRef?
            // The default access group is this App's existing Keychain owner.
            // A duplicate belonging to a different label is refused, not moved.
            let add: [String: Any] = [kSecValueRef as String: identity, kSecAttrLabel as String: label,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecAttrSynchronizable as String: false, kSecReturnPersistentRef as String: true]
            let added = SecItemAdd(add as CFDictionary, &result)
            if added == errSecDuplicateItem {
                guard let reused = try ownedReference(label: label, facts: facts) else { throw Failure.keychain(added) }
                reference = reused
            } else {
                guard added == errSecSuccess else { throw Failure.keychain(added) }
                guard let value = result as? Data, !value.isEmpty, value.count <= 4_096 else {
                    throw Failure.invalidPersistentReference
                }
                reference = value
            }
        }
        // An additive Keychain item survives cancellation/publication failure.
        // This exact label+certificate is reusable on explicit retry; deleting
        // it could invalidate a Document whose durable ACK was just lost.
        try Task.checkCancellation()
        let device = Device(identityPersistentReference: reference, deviceCertificateDER: facts.deviceCertificateDER,
            rootCertificateDER: facts.rootCertificateDER, hostID: facts.hostID, systemBUID: facts.systemBUID,
            numericAddress: facts.numericAddress, port: facts.port, interfaceIndex: facts.interfaceIndex)
        let readBack = try SelfRenewalAppSession.pairing(device)
        try validateIdentity(readBack.hostIdentity, facts: facts)
        try Task.checkCancellation()
        return device
    }

    private static func ownedReference(label: String, facts: PublicConfiguration) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecAttrLabel as String: label,
            kSecAttrSynchronizable as String: false, kSecReturnRef as String: true,
            kSecReturnPersistentRef as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        guard let values = result as? [String: Any], let value = values[kSecValueRef as String],
              let reference = values[kSecValuePersistentRef as String] as? Data,
              !reference.isEmpty, reference.count <= 4_096 else { throw Failure.invalidPersistentReference }
        let item = value as CFTypeRef
        guard CFGetTypeID(item) == SecIdentityGetTypeID() else { throw Failure.invalidPersistentReference }
        try validateIdentity(unsafeBitCast(item, to: SecIdentity.self), facts: facts)
        return reference
    }

    private static func validateIdentity(_ identity: SecIdentity, facts: PublicConfiguration) throws {
        let pairing = try Transport.PairingIdentity(hostIdentity: identity, deviceCertificateDER: facts.deviceCertificateDER,
            rootCertificateDER: facts.rootCertificateDER, hostID: facts.hostID, systemBUID: facts.systemBUID)
        guard pairing.hostCertificateDER == facts.hostCertificateDER else { throw Failure.hostCertificateMismatch }
        var key: SecKey?, certificate: SecCertificate?
        guard SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess, let key,
              SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
              let publicKey = SecCertificateCopyKey(certificate) else { throw Failure.keyPossession }
        let algorithms: [SecKeyAlgorithm] = [.rsaSignatureMessagePKCS1v15SHA256, .ecdsaSignatureMessageX962SHA256]
        guard let algorithm = algorithms.first(where: { SecKeyIsAlgorithmSupported(key, .sign, $0) &&
            SecKeyIsAlgorithmSupported(publicKey, .verify, $0) }) else { throw Failure.keyPossession }
        var challenge = Data(count: 32)
        guard challenge.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }) == errSecSuccess else {
            throw Failure.keyPossession
        }
        try Task.checkCancellation()
        var signingError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, algorithm, challenge as CFData, &signingError) else {
            if let signingError { _ = signingError.takeRetainedValue() }; throw Failure.keyPossession
        }
        var verificationError: Unmanaged<CFError>?
        guard SecKeyVerifySignature(publicKey, algorithm, challenge as CFData, signature, &verificationError) else {
            if let verificationError { _ = verificationError.takeRetainedValue() }; throw Failure.keyPossession
        }
    }

    private static func validateCertificate(_ der: Data, rootDER: Data, at date: Date) throws {
        guard date.timeIntervalSince1970.isFinite,
              let leaf = SecCertificateCreateWithData(nil, der as CFData),
              let root = SecCertificateCreateWithData(nil, rootDER as CFData) else { throw Failure.invalidCertificateChain }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates([leaf, root] as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
              let trust, SecTrustSetAnchorCertificates(trust, [root] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
              SecTrustSetVerifyDate(trust, date as CFDate) == errSecSuccess else { throw Failure.invalidCertificateChain }
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error),
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], chain.count == 2,
              chain.first.map({ SecCertificateCopyData($0) as Data }) == der,
              chain.last.map({ SecCertificateCopyData($0) as Data }) == rootDER else { throw Failure.invalidCertificateChain }
    }
}
