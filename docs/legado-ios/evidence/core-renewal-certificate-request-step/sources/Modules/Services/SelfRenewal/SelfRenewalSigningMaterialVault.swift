import CryptoKit
import Foundation
import Security

/// Public material storage reuses the existing generic-password owner. Private
/// keys are never converted to Data/String; Security stores their key objects.
protocol SelfRenewalSigningManifestStorage: Sendable {
    func load(account: String) throws -> String?
    func save(account: String, value: String) throws
    func delete(account: String) throws
}

struct SelfRenewalSigningKeychainManifestStorage: SelfRenewalSigningManifestStorage {
    private let service = "com.yuedu.selfRenewal.publicSigningManifest.v1"
    func load(account: String) throws -> String? {
        try KeychainHelper.loadChecked(account: account, service: service,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, synchronizable: false,
            maximumBytes: SelfRenewalSigningMaterialVault.Limits.manifestBytes)
    }
    func save(account: String, value: String) throws {
        guard KeychainHelper.save(account: account, data: value, service: service,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, synchronizable: false) else {
            throw SelfRenewalSigningMaterialVault.Failure.manifestWrite
        }
    }
    func delete(account: String) throws {
        guard KeychainHelper.delete(account: account, service: service, synchronizable: false) else {
            throw SelfRenewalSigningMaterialVault.Failure.manifestWrite
        }
    }
}

/// One injected actor owns all lifecycle mutations. There is no second shared
/// key manager. A single manifest is the publication boundary, not a promise of
/// atomicity across the manifest and multiple Security key items/processes.
actor SelfRenewalSigningMaterialVault {
    /// Raw crypto input shared with S3. Its initializer conveys no publication,
    /// profile, Apple-account, provisioning-purpose or installation authority.
    struct KeyMaterial: @unchecked Sendable {
        let privateKey: SecKey
        let certificateChainDER: [Data]
        init(privateKey: SecKey, certificateChainDER: [Data]) {
            self.privateKey = privateKey; self.certificateChainDER = certificateChainDER
        }
    }
    struct Namespace: Sendable, Hashable {
        let id: UUID
        fileprivate init(_ id: UUID) { self.id = id }
    }
    struct PendingKey: @unchecked Sendable {
        let namespace: Namespace
        let id: UUID
        let generation: UInt64
        let publicKeySHA256: Data
        /// Opaque software-key handle for CSR construction/owned PKI fixtures.
        /// No private external representation is requested by this module.
        let privateKey: SecKey
        fileprivate init(namespace: Namespace, id: UUID, generation: UInt64, hash: Data, key: SecKey) {
            self.namespace = namespace; self.id = id; self.generation = generation
            publicKeySHA256 = hash; privateKey = key
        }
    }
    enum CertificateRequestFailure: Error, Sendable, Equatable { case invalidSubject, signature }

    /// Public PKCS#10 bytes only. Request creation proves possession of this
    /// namespace's current key, not account authorization or certificate issue.
    struct CertificateRequest: Sendable {
        let namespace: Namespace
        let keyID: UUID
        let generation: UInt64
        let publicKeySHA256: Data
        let der: Data
        fileprivate init(namespace: Namespace, keyID: UUID, generation: UInt64, hash: Data, der: Data) {
            self.namespace = namespace; self.keyID = keyID; self.generation = generation
            publicKeySHA256 = hash; self.der = der
        }
    }

    struct ProfileInput: Sendable, Equatable, Codable {
        let componentRelativePath: String
        let bytes: Data
    }
    struct Lease: @unchecked Sendable {
        let namespace: Namespace
        let generation: UInt64
        let keyID: UUID
        let keyMaterial: KeyMaterial
        let profiles: [SelfRenewalProvisioningProfileVerifier.ModernProfile]
        /// Exact raw CMS bytes that produced these verified profiles.
        let profileInputs: [ProfileInput]
        let verifiedAt: Date
        var appleSigningAuthorityEstablished: Bool { false }
        var remoteRevocationEstablished: Bool { false }
        var accountIdentityEstablished: Bool { false }
        var replacementAuthorized: Bool { false }
        fileprivate init(namespace: Namespace, generation: UInt64, keyID: UUID, key: SecKey,
            chain: [Data], profiles: [SelfRenewalProvisioningProfileVerifier.ModernProfile], inputs: [ProfileInput], date: Date) {
            self.namespace = namespace; self.generation = generation; self.keyID = keyID
            keyMaterial = KeyMaterial(privateKey: key, certificateChainDER: chain)
            self.profiles = profiles; profileInputs = inputs; verifiedAt = date
        }
    }
    enum Failure: Error, Sendable, Equatable {
        case limit, namespaceUnavailable, malformedManifest, manifestWrite, staleGeneration
        case keyGeneration, keychain(OSStatus), missingKey, keyMismatch, revoked
        case invalidCertificate, untrustedCertificate, identityChanged, invalidProfiles, clockMovedBackwards
    }
    enum Limits {
        static let namespaces = 8
        static let keysPerNamespace = 4
        static let bundles = 8
        static let certificates = 8
        static let certificateBytes = 65_536
        static let profileBytes = 65_536
        static let publicMaterialBytes = 262_144
        static let manifestBytes = 524_288
    }

    private struct Identity: Codable, Equatable {
        let component: String
        let bundleIdentifier: String
        let team: String
        let applicationIdentifier: String
        let appGroups: [String]
        let keychainGroups: [String]
        let profileTeams: [String]
        let profilePrefixes: [String]
        let profileApplicationPattern: String
        let profileTeam: String?
        let profileEntitlementsSHA256: Data
    }
    private enum KeyState: String, Codable, Equatable { case pending, ready, revoked }
    private struct KeyRecord: Codable, Equatable {
        let id: UUID
        var state: KeyState
        var publicHash: Data?
    }
    private struct Published: Codable, Equatable {
        let keyID: UUID
        let chain: [Data]
        let profiles: [ProfileInput]
        let publishedAt: Date
    }
    private struct Manifest: Codable, Equatable {
        let schema: Int
        let namespace: UUID
        let identity: [Identity]
        var generation: UInt64
        var keys: [KeyRecord]
        var published: Published?
    }
    private struct Session { var manifest: Manifest; var encoded: String }
    private let codeAnchors: [Data]
    private let profileAnchors: [Data]
    private let storage: any SelfRenewalSigningManifestStorage
    private let clock: @Sendable () -> Date
    private var sessions: [UUID: Session] = [:]

    init(codeAnchors: [Data], profileAnchors: [Data],
        storage: any SelfRenewalSigningManifestStorage = SelfRenewalSigningKeychainManifestStorage(),
        clock: @escaping @Sendable () -> Date = { Date() }) {
        self.codeAnchors = codeAnchors; self.profileAnchors = profileAnchors
        self.storage = storage; self.clock = clock
    }

    func create(identity material: SelfRenewalApplicationMaterialVerifier.Materials) throws -> Namespace {
        precondition(!Thread.isMainThread, "Signing material Keychain I/O must stay off main")
        let started = SourcePerfTrace.now
        defer { trace("create", bytes: 0, since: started) }
        try Task.checkCancellation()
        guard sessions.count < Limits.namespaces else { throw Failure.limit }
        let identity = try Self.identity(material)
        let namespace = Namespace(UUID())
        let manifest = Manifest(schema: 1, namespace: namespace.id, identity: identity, generation: 0, keys: [], published: nil)
        let encoded = try Self.encode(manifest)
        try Task.checkCancellation()
        try storage.save(account: Self.account(namespace.id), value: encoded)
        sessions[namespace.id] = Session(manifest: manifest, encoded: encoded)
        return namespace
    }

    /// The namespace identifier is App-owned metadata, never an Apple account ID.
    /// Reopening requires the same sealed App identity; missing/locked manifest
    /// reads fail closed instead of being treated as a new, overwritable state.
    func resume(namespaceID: UUID, identity material: SelfRenewalApplicationMaterialVerifier.Materials) throws -> Namespace {
        let started = SourcePerfTrace.now
        defer { trace("resume", bytes: 0, since: started) }
        try Task.checkCancellation()
        guard sessions[namespaceID] != nil || sessions.count < Limits.namespaces else { throw Failure.limit }
        guard let encoded = try storage.load(account: Self.account(namespaceID)) else { throw Failure.namespaceUnavailable }
        var manifest = try Self.decode(encoded, namespace: namespaceID)
        guard manifest.identity == (try Self.identity(material)) else { throw Failure.identityChanged }
        // A journal entry precedes key creation. Recovery touches only exact,
        // random tags recorded by this module, never an unscoped Keychain query.
        let pending = manifest.keys.filter { $0.state == .pending }
        for record in pending { try Self.deleteKey(namespace: namespaceID, id: record.id) }
        if !pending.isEmpty {
            manifest.keys.removeAll { $0.state == .pending }
            try Self.advance(&manifest)
            let recovered = try Self.encode(manifest)
            try storage.save(account: Self.account(namespaceID), value: recovered)
            sessions[namespaceID] = Session(manifest: manifest, encoded: recovered)
        } else { sessions[namespaceID] = Session(manifest: manifest, encoded: encoded) }
        return Namespace(namespaceID)
    }

    func generation(in namespace: Namespace) throws -> UInt64 { try current(namespace).manifest.generation }

    func generateKey(in namespace: Namespace, expectedGeneration: UInt64) throws -> PendingKey {
        let started = SourcePerfTrace.now
        defer { trace("generate-key", bytes: 0, since: started) }
        try Task.checkCancellation()
        var session = try current(namespace)
        guard session.manifest.generation == expectedGeneration else { throw Failure.staleGeneration }
        guard session.manifest.keys.count < Limits.keysPerNamespace else { throw Failure.limit }
        let id = UUID()
        session.manifest.keys.append(KeyRecord(id: id, state: .pending, publicHash: nil))
        try publishManifest(&session, namespace: namespace)
        do {
            let privateAttributes: [String: Any] = [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: Self.tag(namespace: namespace.id, id: id),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecAttrSynchronizable as String: false,
                kSecAttrCanSign as String: true,
                kSecAttrCanDecrypt as String: false,
                kSecAttrCanDerive as String: false,
                kSecAttrCanUnwrap as String: false,
            ]
            let options: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeySizeInBits as String: 2048, kSecPrivateKeyAttrs as String: privateAttributes,
                kSecPublicKeyAttrs as String: [kSecAttrIsPermanent as String: false]]
            var error: Unmanaged<CFError>?
            guard let key = SecKeyCreateRandomKey(options as CFDictionary, &error) else {
                if let error { _ = error.takeRetainedValue() }
                throw Failure.keyGeneration
            }
            let hash = try Self.publicHash(key)
            try Task.checkCancellation()
            guard let index = session.manifest.keys.firstIndex(where: { $0.id == id }) else { throw Failure.malformedManifest }
            session.manifest.keys[index].state = .ready
            session.manifest.keys[index].publicHash = hash
            try publishManifest(&session, namespace: namespace)
            return PendingKey(namespace: namespace, id: id, generation: session.manifest.generation, hash: hash, key: key)
        } catch {
            // Do not touch the old published key or old public material. A failed
            // journal cleanup remains recoverable on the next explicit resume.
            do { try Self.deleteKey(namespace: namespace.id, id: id) }
            catch { AppLogger.error("Owned signing-key cleanup failed", error: error) }
            throw error
        }
    }

    /// Reopen the exact permanent key on every request. A retained PendingKey
    /// handle is deliberately not accepted as authority after revoke/CAS drift.
    /// RFC2986 section4: DER CRI v0, subject, RSA SPKI, mandatory empty [0]
    /// attributes, then SHA256-with-RSA signature over those exact CRI bytes.
    func certificateSigningRequest(in namespace: Namespace, keyID: UUID, expectedGeneration: UInt64,
        commonName: String, emailAddress: String) throws -> CertificateRequest {
        let started = SourcePerfTrace.now
        var requestBytes = 0
        defer { trace("certificate-request", bytes: requestBytes, since: started) }
        try Task.checkCancellation()
        let session = try current(namespace)
        guard session.manifest.generation == expectedGeneration else { throw Failure.staleGeneration }
        guard let record = session.manifest.keys.first(where: { $0.id == keyID }) else { throw Failure.missingKey }
        guard record.state == .ready else { throw Failure.revoked }
        let subject = try CertificateRequestDER.subject(commonName: commonName, emailAddress: emailAddress)
        let key = try Self.loadKey(namespace: namespace.id, id: keyID)
        guard let publicKey = SecKeyCopyPublicKey(key),
              let attributes = SecKeyCopyAttributes(publicKey) as? [String: Any],
              attributes[kSecAttrKeyClass as String] as? String == kSecAttrKeyClassPublic as String,
              attributes[kSecAttrKeyType as String] as? String == kSecAttrKeyTypeRSA as String,
              attributes[kSecAttrKeySizeInBits as String] as? Int == 2048 else { throw Failure.keyMismatch }
        var exportError: Unmanaged<CFError>?
        // This is the public key only. No private representation is requested.
        let exported = SecKeyCopyExternalRepresentation(publicKey, &exportError) as Data?
        if let exportError { _ = exportError.takeRetainedValue() }
        guard let exported, !exported.isEmpty, exported.count <= 1024 else { throw Failure.keyMismatch }
        let hash = Data(SHA256.hash(data: exported))
        guard hash == record.publicHash else { throw Failure.keyMismatch }
        let spki = try CertificateRequestDER.sequence([
            CertificateRequestDER.algorithm(lastOIDByte: 1),
            CertificateRequestDER.tlv(3, Data([0]) + exported)])
        let info = try CertificateRequestDER.sequence([Data([2, 1, 0]), subject, spki, Data([0xa0, 0])])
        try Task.checkCancellation()
        guard try current(namespace).encoded == session.encoded else { throw Failure.staleGeneration }
        let algorithm = SecKeyAlgorithm.rsaSignatureMessagePKCS1v15SHA256
        guard SecKeyIsAlgorithmSupported(key, .sign, algorithm),
              SecKeyIsAlgorithmSupported(publicKey, .verify, algorithm) else { throw CertificateRequestFailure.signature }
        var signError: Unmanaged<CFError>?
        let result = SecKeyCreateSignature(key, algorithm, info as CFData, &signError) as Data?
        if let signError { _ = signError.takeRetainedValue() }
        guard let signature = result, signature.count == 256 else { throw CertificateRequestFailure.signature }
        var verifyError: Unmanaged<CFError>?
        let verified = SecKeyVerifySignature(publicKey, algorithm, info as CFData, signature as CFData, &verifyError)
        if let verifyError { _ = verifyError.takeRetainedValue() }
        guard verified else { throw CertificateRequestFailure.signature }
        let der = try CertificateRequestDER.sequence([
            info, CertificateRequestDER.algorithm(lastOIDByte: 11),
            CertificateRequestDER.tlv(3, Data([0]) + signature)])
        requestBytes = der.count
        try Task.checkCancellation()
        // A different process can change the manifest while Security signs.
        // This detects an observed change; it is not a cross-process lock or a
        // promise that a later remote enrollment can bypass publication CAS.
        guard try current(namespace).encoded == session.encoded else { throw Failure.staleGeneration }
        return CertificateRequest(namespace: namespace, keyID: keyID, generation: expectedGeneration, hash: hash, der: der)
    }

    /// Only writes this bounded PKCS#10 shape; existing CMS/profile decoders
    /// and all publication/trust decisions remain the same owners as before.
    private enum CertificateRequestDER {
        static let maximumBytes = 8192
        static func subject(commonName: String, emailAddress: String) throws -> Data {
            // Bound iteration before allocating from externally supplied text.
            // CN uses RFC5280's 64-character bound and UTF8String. The supported
            // email subject form is non-whitespace ASCII with one non-edge @.
            let name = Array(commonName.unicodeScalars.prefix(65))
            let email = Array(emailAddress.utf8.prefix(129))
            guard !name.isEmpty, name.count <= 64,
                  name.allSatisfy({ $0.value >= 0x20 && !((0x7f...0x9f).contains($0.value)) }),
                  !email.isEmpty, email.count <= 128,
                  email.allSatisfy({ (0x21...0x7e).contains($0) }),
                  email.filter({ $0 == 0x40 }).count == 1,
                  email.first != 0x40, email.last != 0x40 else { throw CertificateRequestFailure.invalidSubject }
            let commonNameOID = Data([6, 3, 0x55, 4, 3])
            let emailOID = Data([6, 9, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 9, 1])
            // Each RDN contains exactly one value, so no SET member sorting is
            // needed. Subject text is never converted into slash/DN syntax.
            return try sequence([
                tlv(0x31, sequence([commonNameOID, tlv(0x0c, Data(commonName.utf8))])),
                tlv(0x31, sequence([emailOID, tlv(0x16, Data(email))]))])
        }
        static func algorithm(lastOIDByte: UInt8) throws -> Data {
            try sequence([Data([6, 9, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 1, lastOIDByte]), Data([5, 0])])
        }
        static func sequence(_ fields: [Data]) throws -> Data {
            var body = Data()
            for field in fields {
                guard field.count <= maximumBytes - body.count else { throw Failure.limit }
                body.append(field)
            }
            return try tlv(0x30, body)
        }
        static func tlv(_ tag: UInt8, _ body: Data) throws -> Data {
            guard body.count <= maximumBytes - 4 else { throw Failure.limit }
            var result = Data([tag])
            if body.count < 128 { result.append(UInt8(body.count)) }
            else if body.count < 256 { result.append(contentsOf: [0x81, UInt8(body.count)]) }
            else { result.append(contentsOf: [0x82, UInt8(body.count >> 8), UInt8(body.count & 0xff)]) }
            result.append(body)
            return result
        }
    }

    func publish(in namespace: Namespace, keyID: UUID, expectedGeneration: UInt64,
        certificateChainDER: [Data], profiles: [ProfileInput]) throws -> Lease {
        let started = SourcePerfTrace.now
        defer { trace("publish", bytes: profiles.prefix(Limits.bundles).reduce(0) { $0 + $1.bytes.count }, since: started) }
        try Task.checkCancellation()
        var session = try current(namespace)
        guard session.manifest.generation == expectedGeneration else { throw Failure.staleGeneration }
        let date = clock()
        let candidate = Published(keyID: keyID, chain: certificateChainDER, profiles: profiles, publishedAt: date)
        let (key, verifiedProfiles) = try verify(candidate, manifest: session.manifest, at: date)
        try Task.checkCancellation()
        guard clock() >= date else { throw Failure.clockMovedBackwards }
        guard verifiedProfiles.allSatisfy({ $0.summary.expiresAt > clock() }) else { throw Failure.invalidProfiles }
        session.manifest.published = candidate
        // This synchronous single-item save is the publication boundary. No
        // post-commit CancellationError falsely reports that it was rolled back.
        try publishManifest(&session, namespace: namespace)
        return Lease(namespace: namespace, generation: session.manifest.generation, keyID: keyID, key: key,
            chain: certificateChainDER, profiles: verifiedProfiles, inputs: candidate.profiles, date: date)
    }

    func lease(in namespace: Namespace) throws -> Lease {
        let started = SourcePerfTrace.now
        defer { trace("lease", bytes: 0, since: started) }
        try Task.checkCancellation()
        let session = try current(namespace)
        guard let published = session.manifest.published else { throw Failure.namespaceUnavailable }
        let date = clock()
        let (key, profiles) = try verify(published, manifest: session.manifest, at: date)
        try Task.checkCancellation()
        return Lease(namespace: namespace, generation: session.manifest.generation, keyID: published.keyID,
            key: key, chain: published.chain, profiles: profiles, inputs: published.profiles, date: date)
    }

    /// Call immediately before signing and again before publishing signed bytes.
    /// Deleting a Keychain item cannot invalidate SecKey references already held
    /// by other code, so a retained raw handle is never a commit capability.
    func validate(_ lease: Lease) throws {
        let session = try current(lease.namespace)
        guard session.manifest.generation == lease.generation,
              session.manifest.published?.keyID == lease.keyID else { throw Failure.staleGeneration }
        _ = try self.lease(in: lease.namespace)
    }

    /// A live lease is scoped to the namespace's original sealed App identity,
    /// including ACTUAL signed group/order claims, not only profile allowances.
    func validate(_ lease: Lease, for material: SelfRenewalApplicationMaterialVerifier.Materials) throws {
        try Task.checkCancellation()
        try validate(lease)
        let session = try current(lease.namespace)
        guard try Self.identity(material) == session.manifest.identity else { throw Failure.identityChanged }
    }

    func revoke(_ keyID: UUID, in namespace: Namespace, expectedGeneration: UInt64) throws {
        let started = SourcePerfTrace.now
        defer { trace("revoke", bytes: 0, since: started) }
        try Task.checkCancellation()
        var session = try current(namespace)
        guard session.manifest.generation == expectedGeneration else { throw Failure.staleGeneration }
        guard let index = session.manifest.keys.firstIndex(where: { $0.id == keyID }) else { throw Failure.missingKey }
        session.manifest.keys[index].state = .revoked
        if session.manifest.published?.keyID == keyID { session.manifest.published = nil }
        // Persist invalidation first. Deletion failure never restores a revoked
        // generation; a later explicit cleanup may retry this exact key tag.
        try publishManifest(&session, namespace: namespace)
        try Self.deleteKey(namespace: namespace.id, id: keyID)
    }

    func destroy(_ namespace: Namespace, expectedGeneration: UInt64) throws {
        let started = SourcePerfTrace.now
        defer { trace("destroy", bytes: 0, since: started) }
        try Task.checkCancellation()
        var session = try current(namespace)
        guard session.manifest.generation == expectedGeneration else { throw Failure.staleGeneration }
        session.manifest.published = nil
        for index in session.manifest.keys.indices { session.manifest.keys[index].state = .revoked }
        try publishManifest(&session, namespace: namespace)
        for record in session.manifest.keys { try Self.deleteKey(namespace: namespace.id, id: record.id) }
        try storage.delete(account: Self.account(namespace.id))
        sessions.removeValue(forKey: namespace.id)
    }

    private func current(_ namespace: Namespace) throws -> Session {
        precondition(!Thread.isMainThread, "Signing material Keychain I/O must stay off main")
        try Task.checkCancellation()
        guard let session = sessions[namespace.id], let saved = try storage.load(account: Self.account(namespace.id)) else {
            throw Failure.namespaceUnavailable
        }
        guard saved == session.encoded else { throw Failure.staleGeneration }
        return session
    }
    private func trace(_ operation: String, bytes: Int, since started: TimeInterval) {
        SourcePerfTrace.record("renewal.signing.vault", "op=\(operation) bytes=\(bytes) main=\(Thread.isMainThread)",
            since: started, thresholdMs: 0)
    }
    private func publishManifest(_ session: inout Session, namespace: Namespace) throws {
        try Task.checkCancellation()
        let old = try current(namespace)
        guard old.encoded == session.encoded else { throw Failure.staleGeneration }
        try Self.advance(&session.manifest)
        let encoded = try Self.encode(session.manifest)
        try Task.checkCancellation()
        try storage.save(account: Self.account(namespace.id), value: encoded)
        session.encoded = encoded
        sessions[namespace.id] = session
    }

    private func verify(_ published: Published, manifest: Manifest, at date: Date) throws -> (SecKey, [SelfRenewalProvisioningProfileVerifier.ModernProfile]) {
        guard date.timeIntervalSince1970.isFinite, date >= published.publishedAt else { throw Failure.clockMovedBackwards }
        guard let record = manifest.keys.first(where: { $0.id == published.keyID }) else { throw Failure.missingKey }
        guard record.state == .ready else { throw Failure.revoked }
        guard !published.chain.isEmpty, published.chain.count <= Limits.certificates,
              Set(published.chain).count == published.chain.count,
              published.chain.allSatisfy({ !$0.isEmpty && $0.count <= Limits.certificateBytes }),
              published.profiles.count == manifest.identity.count,
              Set(published.profiles.map(\.componentRelativePath)).count == published.profiles.count else { throw Failure.limit }
        var bytes = published.chain.reduce(0) { $0 + $1.count }
        for profile in published.profiles {
            guard !profile.bytes.isEmpty, profile.bytes.count <= Limits.profileBytes,
                  profile.bytes.count <= Limits.publicMaterialBytes - bytes else { throw Failure.limit }
            bytes += profile.bytes.count
        }
        let key = try Self.loadKey(namespace: manifest.namespace, id: record.id)
        guard try Self.publicHash(key) == record.publicHash else { throw Failure.keyMismatch }
        let certificates = try Self.validateChain(published.chain, anchors: codeAnchors, at: date)
        guard let leaf = certificates.first, let certificateKey = SecCertificateCopyKey(leaf),
              try Self.publicHash(certificateKey) == record.publicHash else { throw Failure.keyMismatch }
        let leafHash = Data(SHA256.hash(data: published.chain[0]))
        var profiles: [SelfRenewalProvisioningProfileVerifier.ModernProfile] = []
        for identity in manifest.identity {
            try Task.checkCancellation()
            guard let input = published.profiles.first(where: { $0.componentRelativePath == identity.component }) else { throw Failure.invalidProfiles }
            let relative = identity.component == "." ? "embedded.mobileprovision" : identity.component + "/embedded.mobileprovision"
            let fact = SelfRenewalMaterialInventory.FileFact(relativePath: relative, byteCount: Int64(input.bytes.count))
            let profile = try SelfRenewalProvisioningProfileVerifier.verifyModern(input.bytes, file: fact, anchors: profileAnchors, at: date)
            let summary = profile.summary
            guard profile.file == fact, profile.rawFileDigests[2] == Data(SHA256.hash(data: input.bytes)),
                  summary.teamIdentifiers == identity.profileTeams,
                  summary.applicationIdentifierPrefixes == identity.profilePrefixes,
                  summary.applicationIdentifier == identity.profileApplicationPattern,
                  summary.entitlementTeamIdentifier == identity.profileTeam,
                  summary.developerCertificateSHA256.contains(leafHash),
                  case .dictionary(let properties) = profile.properties,
                  let entitlements = properties["Entitlements"],
                  try Self.digest(entitlements) == identity.profileEntitlementsSHA256 else { throw Failure.identityChanged }
            profiles.append(profile)
        }
        return (key, profiles)
    }

    private static func identity(_ material: SelfRenewalApplicationMaterialVerifier.Materials) throws -> [Identity] {
        guard !material.bundles.isEmpty, material.bundles.count <= Limits.bundles else { throw Failure.limit }
        return try material.bundles.map { bundle in
            guard let first = bundle.slices.first, bundle.slices.allSatisfy({
                $0.teamIdentifier == first.teamIdentifier && $0.applicationIdentifier == first.applicationIdentifier
                    && $0.appGroups == first.appGroups && $0.keychainAccessGroups == first.keychainAccessGroups
            }), let profile = material.profiles.profiles.first(where: { $0.file.relativePath == bundle.profileRelativePath }),
                  case .dictionary(let properties) = profile.properties, let entitlements = properties["Entitlements"] else { throw Failure.identityChanged }
            return Identity(component: bundle.componentRelativePath, bundleIdentifier: bundle.bundleIdentifier,
                team: first.teamIdentifier, applicationIdentifier: first.applicationIdentifier,
                appGroups: first.appGroups, keychainGroups: first.keychainAccessGroups,
                profileTeams: profile.summary.teamIdentifiers, profilePrefixes: profile.summary.applicationIdentifierPrefixes,
                profileApplicationPattern: profile.summary.applicationIdentifier, profileTeam: profile.summary.entitlementTeamIdentifier,
                profileEntitlementsSHA256: try digest(entitlements))
        }.sorted { $0.component < $1.component }
    }
    private static func validateChain(_ chain: [Data], anchors: [Data], at date: Date) throws -> [SecCertificate] {
        guard !anchors.isEmpty, anchors.count <= Limits.certificates,
              anchors.allSatisfy({ !$0.isEmpty && $0.count <= Limits.certificateBytes }), Set(anchors).count == anchors.count else { throw Failure.invalidCertificate }
        func certificate(_ data: Data) throws -> SecCertificate {
            guard let value = SecCertificateCreateWithData(nil, data as CFData) else { throw Failure.invalidCertificate }; return value
        }
        let certificates = try chain.map(certificate)
        let roots = try anchors.map(certificate)
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
              let trust, SecTrustSetAnchorCertificates(trust, roots as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
              SecTrustSetVerifyDate(trust, date as CFDate) == errSecSuccess else { throw Failure.untrustedCertificate }
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else { throw Failure.untrustedCertificate }
        guard let selected = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              !selected.isEmpty, selected.count <= Limits.certificates else { throw Failure.untrustedCertificate }
        let selectedDER = selected.map { SecCertificateCopyData($0) as Data }
        guard selectedDER == chain, let root = selectedDER.last, anchors.contains(root) else { throw Failure.untrustedCertificate }
        return certificates
    }
    private static func publicHash(_ key: SecKey) throws -> Data {
        let publicKey = SecKeyCopyPublicKey(key) ?? key
        guard let attributes = SecKeyCopyAttributes(publicKey) as? [String: Any],
              attributes[kSecAttrKeyClass as String] as? String == kSecAttrKeyClassPublic as String else { throw Failure.keyMismatch }
        var error: Unmanaged<CFError>?
        guard let representation = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            if let error { _ = error.takeRetainedValue() }; throw Failure.keyMismatch
        }
        return Data(SHA256.hash(data: representation))
    }
    private static func loadKey(namespace: UUID, id: UUID) throws -> SecKey {
        var query = keyQuery(namespace: namespace, id: id)
        query[kSecReturnRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let result else { throw status == errSecItemNotFound ? Failure.missingKey : Failure.keychain(status) }
        guard CFGetTypeID(result) == SecKeyGetTypeID() else { throw Failure.missingKey }
        return result as! SecKey
    }
    private static func deleteKey(namespace: UUID, id: UUID) throws {
        let status = SecItemDelete(keyQuery(namespace: namespace, id: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
    }
    private static func keyQuery(namespace: UUID, id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassKey, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
         kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrApplicationTag as String: tag(namespace: namespace, id: id),
         kSecAttrSynchronizable as String: false]
    }
    private static func tag(namespace: UUID, id: UUID) -> Data {
        Data(("com.yuedu.selfRenewal.signingKey.v1." + namespace.uuidString.lowercased() + "." + id.uuidString.lowercased()).utf8)
    }
    private static func account(_ namespace: UUID) -> String { "owned-v1-" + namespace.uuidString.lowercased() }
    private static func advance(_ manifest: inout Manifest) throws {
        guard manifest.generation < UInt64.max else { throw Failure.limit }; manifest.generation += 1
    }
    private static func encode(_ manifest: Manifest) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        guard data.count <= Limits.manifestBytes else { throw Failure.limit }
        return String(decoding: data, as: UTF8.self)
    }
    private static func decode(_ text: String, namespace: UUID) throws -> Manifest {
        guard text.utf8.count <= Limits.manifestBytes else { throw Failure.limit }
        let value = try JSONDecoder().decode(Manifest.self, from: Data(text.utf8))
        guard value.schema == 1, value.namespace == namespace, !value.identity.isEmpty,
              value.identity.count <= Limits.bundles, value.keys.count <= Limits.keysPerNamespace,
              Set(value.keys.map(\.id)).count == value.keys.count,
              value.keys.allSatisfy({ ($0.state != .ready || $0.publicHash?.count == 32)
                && ($0.publicHash == nil || $0.publicHash?.count == 32) }),
              value.published.map({ publication in value.keys.contains { $0.id == publication.keyID && $0.state == .ready } }) ?? true else {
            throw Failure.malformedManifest
        }
        return value
    }

    /// Canonical typed encoding of already bounded DER properties, preserving
    /// integer/date/data distinctions and keychain-group array order.
    private static func digest(_ value: SelfRenewalDERPropertyList.Value) throws -> Data {
        var output = Data()
        func append(_ data: Data) throws {
            guard data.count <= Limits.publicMaterialBytes - output.count else { throw Failure.limit }
            output.append(data)
        }
        func length(_ value: Int) throws {
            let size = UInt32(value)
            try append(Data((0..<4).map { UInt8(truncatingIfNeeded: size >> ($0 * 8)) }))
        }
        func encode(_ value: SelfRenewalDERPropertyList.Value, depth: Int) throws {
            try Task.checkCancellation()
            guard depth <= 16 else { throw Failure.limit }
            switch value {
            case .dictionary(let values):
                try append(Data([1])); try length(values.count)
                for key in values.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
                    try encode(.string(key), depth: depth + 1); try encode(values[key]!, depth: depth + 1)
                }
            case .array(let values): try append(Data([2])); try length(values.count); for value in values { try encode(value, depth: depth + 1) }
            case .string(let value): try append(Data([3])); try length(value.utf8.count); try append(Data(value.utf8))
            case .data(let value): try append(Data([4])); try length(value.count); try append(value)
            case .integer(let value): try append(Data([5])); let bits = UInt64(bitPattern: value); try append(Data((0..<8).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }))
            case .boolean(let value): try append(Data([6, value ? 1 : 0]))
            case .date(let value):
                guard value.timeIntervalSince1970.isFinite else { throw Failure.limit }
                try append(Data([7])); let bits = value.timeIntervalSince1970.bitPattern
                try append(Data((0..<8).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }))
            case .null: try append(Data([8]))
            }
        }
        try encode(value, depth: 0)
        return Data(SHA256.hash(data: output))
    }
}
