import CryptoKit
import Foundation
import Security

protocol SelfRenewalDeveloperSessionStorage: Sendable {
    func load(namespace: UUID) throws -> String?
    func save(namespace: UUID, value: String) throws
}

struct SelfRenewalDeveloperKeychainSessionStorage: SelfRenewalDeveloperSessionStorage {
    private let service = "com.yuedu.selfRenewal.developerSession.v1"
    func load(namespace: UUID) throws -> String? {
        try KeychainHelper.loadChecked(account: namespace.uuidString, service: service,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            synchronizable: false, maximumBytes: 65_536)
    }
    func save(namespace: UUID, value: String) throws {
        guard KeychainHelper.save(account: namespace.uuidString, data: value, service: service,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, synchronizable: false) else {
            throw SelfRenewalDeveloperAccountClient.Failure.storage
        }
    }
}

/// One injected account/network owner consumes the existing material Vault.
/// The wire contract follows the locked public AltSign developer-services
/// implementation; no upstream implementation or private framework is linked.
/// GSA/SRP/2FA and anisette generation are separate unfinished prerequisites.
actor SelfRenewalDeveloperAccountClient {
    typealias Vault = SelfRenewalSigningMaterialVault
    private typealias Value = SelfRenewalDERPropertyList.Value
    enum Failure: Error, Sendable, Equatable {
        case busy, signedOut, invalidInput, malformedResponse, limit, storage
        case sessionExpired, accountChanged, teamChanged, notPersonalTeam
        case appIdentifierMissing, ambiguousAppIdentifier, keyMismatch
        case staleOperation, reconciliationRequired, incompleteCertificateList, ambiguousCertificate, transport(Int), http(Int), portal(Int64)
    }
    /// Carries a real completed Vault publication if the later account journal
    /// write fails. Never misreports the accepted publication as rolled back.
    struct PublicationFinalizationFailure: Error, @unchecked Sendable {
        let publishedLease: Vault.Lease
        let underlying: Error
    }
    struct EnrollmentFailure: Error, @unchecked Sendable {
        let underlying: Error
        let remoteCertificateMayHaveBeenIssued: Bool
        let remoteProfilesMayHaveBeenRefreshed: Bool
    }
    struct SessionInvalidationFailure: Error, @unchecked Sendable {
        let sessionError: Error
        let storageError: Error
    }
    /// Candidate credentials, never an authenticated session capability. Even
    /// restored candidates must pass viewDeveloper and listTeams again. The
    /// expiry is only a local refusal bound, not a server-authorization proof.
    struct Credentials: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let dsid: String
        let xcodeToken: String
        let expiresAt: Date
        var description: String { "Developer credential candidate <redacted>" }
        var debugDescription: String { description }
    }
    /// Fresh data is obtained for each request, never persisted as a reusable
    /// OTP. Supplying these values grants no authority; Apple's response does.
    struct Anisette: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let machineID: String
        let oneTimePassword: String
        let localUserID: String
        let routingInfo: UInt64
        let deviceID: String
        var deviceSerialNumber: String? = nil
        let clientInfo: String
        let issuedAt: Date
        let locale: String
        let timeZone: String
        var description: String { "Developer anisette candidate <redacted>" }
        var debugDescription: String { description }
    }
    struct SessionObservation: Sendable {
        let checkedAt: Date
        let personalTeamMatched: Bool
        var appleSigningAuthorityEstablished: Bool { false }
        var replacementAuthorized: Bool { false }
    }
    struct PendingEnrollment: Codable, Sendable, Equatable {
        enum Phase: String, Codable, Sendable { case certificateRequestIntent, certificateObserved }
        let operationID: UUID
        let keyID: UUID
        let materialGeneration: UInt64
        let requestPublicKeySHA256: Data
        let startedAt: Date
        var phase: Phase
        var certificateSHA256: Data?
        // Optional for source/storage compatibility. Older intents without a
        // complete baseline and exact CSR can only finalize a proved existing
        // publication; they cannot infer a new issue from a later list.
        var reconciliationBaseline: CertificateBaseline? = nil
    }
    struct CertificateBaseline: Codable, Sendable, Equatable {
        let certificateSHA256s: [Data]
        let priorPublishedLeafSHA256: Data?
        let requestDERSHA256: Data
    }
    private struct ListedCertificate {
        let id: String
        let der: Data
        let sha256: Data
        let publicKeySHA256: Data
        let machineID: String?
    }
    private struct AccountPin: Codable, Equatable {
        let dsid: String
        let personID: String
        let email: String
        let teamID: String
    }
    private struct Record: Codable {
        let schema: Int
        let namespaceID: UUID
        let identitySHA256: Data
        let pin: AccountPin
        var credentials: Credentials?
        var pending: PendingEnrollment?
    }
    private struct Loaded { var record: Record; var encoded: String }
    private struct RemoteAccount { let pin: AccountPin; let commonName: String }
    private struct BundleTarget: Sendable { let component: String; let identifier: String }
    private enum Action: String {
        case developer = "viewDeveloper.action", teams = "listTeams.action"
        case certificates = "ios/submitDevelopmentCSR.action", appIDs = "ios/listAppIds.action"
        case profile = "ios/downloadTeamProvisioningProfile.action"
    }
    private let vault: Vault
    private let namespace: Vault.Namespace
    private let bundles: [BundleTarget]
    private let teamID: String
    private let identitySHA256: Data
    private let issuerChainDER: [Data]
    private let transport: any SelfRenewalDeveloperAccountTransport
    private let storage: any SelfRenewalDeveloperSessionStorage
    private let freshAnisette: @Sendable () async throws -> Anisette
    private let clock: @Sendable () -> Date
    private var busy = false
    private var epoch: UInt64 = 0
    private var locallyInvalidated = false

    /// Bind the namespace to the real sealed original identity through the
    /// existing Vault owner before retaining a client. Only the small original
    /// bundle/group pin is retained, not the complete verified resource tree.
    static func open(vault: Vault, namespace: Vault.Namespace, identity: SelfRenewalApplicationMaterialVerifier.Materials,
        issuerChainDER: [Data],
        transport: any SelfRenewalDeveloperAccountTransport = SelfRenewalDeveloperURLSessionTransport(),
        storage: any SelfRenewalDeveloperSessionStorage = SelfRenewalDeveloperKeychainSessionStorage(),
        freshAnisette: @escaping @Sendable () async throws -> Anisette,
        clock: @escaping @Sendable () -> Date = { Date() }) async throws -> SelfRenewalDeveloperAccountClient {
        let started = SourcePerfTrace.now
        defer { SourcePerfTrace.record("renewal.account.open",
            "bundles=\(identity.bundles.count) main=\(Thread.isMainThread)", since: started, thresholdMs: 0) }
        let bound = try await vault.resume(namespaceID: namespace.id, identity: identity)
        guard bound == namespace else { throw Failure.invalidInput }
        try Task.checkCancellation()
        return try SelfRenewalDeveloperAccountClient(vault: vault, namespace: bound, identity: identity,
            issuerChainDER: issuerChainDER, transport: transport, storage: storage,
            freshAnisette: freshAnisette, clock: clock)
    }

    /// The same account owner may reopen its original Keychain-scoped identity
    /// after installed profiles or the prior published lease expire. This does
    /// not authenticate the current Bundle and grants no signing capability.
    /// Every remote account/team check and complete new Vault publication still
    /// uses the unchanged live protocol and actual current verification date.
    static func openForEnrollment(vault: Vault, identity: Vault.EnrollmentIdentity,
        transport: any SelfRenewalDeveloperAccountTransport,
        storage: any SelfRenewalDeveloperSessionStorage,
        freshAnisette: @escaping @Sendable () async throws -> Anisette,
        clock: @escaping @Sendable () -> Date = { Date() }) async throws -> SelfRenewalDeveloperAccountClient {
        let started = SourcePerfTrace.now
        defer { SourcePerfTrace.record("renewal.account.open-enrollment",
            "bundles=\(identity.bundles.count) main=\(Thread.isMainThread)", since: started, thresholdMs: 0) }
        _ = try await vault.generation(in: identity.namespace)
        try Task.checkCancellation()
        return try SelfRenewalDeveloperAccountClient(vault: vault, identity: identity,
            transport: transport, storage: storage, freshAnisette: freshAnisette, clock: clock)
    }

    private init(vault: Vault, identity: Vault.EnrollmentIdentity,
        transport: any SelfRenewalDeveloperAccountTransport, storage: any SelfRenewalDeveloperSessionStorage,
        freshAnisette: @escaping @Sendable () async throws -> Anisette, clock: @escaping @Sendable () -> Date) throws {
        guard let team = identity.bundles.first?.teamIdentifier, !team.isEmpty,
              identity.bundles.allSatisfy({ Self.same($0.teamIdentifier, team) }),
              !identity.bundles.isEmpty, identity.bundles.count <= Vault.Limits.bundles,
              identity.bundles.allSatisfy({ !$0.bundleIdentifier.isEmpty && $0.bundleIdentifier.utf8.count <= 255 &&
                  $0.bundleIdentifier.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 } }),
              identity.issuerChainDER.count < Vault.Limits.certificates,
              Set(identity.issuerChainDER).count == identity.issuerChainDER.count,
              identity.issuerChainDER.allSatisfy({ !$0.isEmpty && $0.count <= Vault.Limits.certificateBytes }) else { throw Failure.invalidInput }
        self.vault = vault; namespace = identity.namespace; teamID = team
        bundles = identity.bundles.map { BundleTarget(component: $0.componentRelativePath, identifier: $0.bundleIdentifier) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        identitySHA256 = Data(SHA256.hash(data: try encoder.encode(IdentityPin(identity))))
        issuerChainDER = identity.issuerChainDER; self.transport = transport; self.storage = storage
        self.freshAnisette = freshAnisette; self.clock = clock
    }

    private init(vault: Vault, namespace: Vault.Namespace, identity: SelfRenewalApplicationMaterialVerifier.Materials,
        issuerChainDER: [Data], transport: any SelfRenewalDeveloperAccountTransport,
        storage: any SelfRenewalDeveloperSessionStorage,
        freshAnisette: @escaping @Sendable () async throws -> Anisette,
        clock: @escaping @Sendable () -> Date = { Date() }) throws {
        let slices = identity.bundles.flatMap(\.slices)
        guard !slices.isEmpty, let team = slices.first?.teamIdentifier,
              slices.allSatisfy({ Self.same($0.teamIdentifier, team) }),
              !identity.bundles.isEmpty, identity.bundles.count <= Vault.Limits.bundles,
              identity.bundles.allSatisfy({ !$0.bundleIdentifier.isEmpty && $0.bundleIdentifier.utf8.count <= 255 &&
                  $0.bundleIdentifier.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 } }),
              issuerChainDER.count < Vault.Limits.certificates,
              Set(issuerChainDER).count == issuerChainDER.count,
              issuerChainDER.allSatisfy({ !$0.isEmpty && $0.count <= Vault.Limits.certificateBytes }) else { throw Failure.invalidInput }
        self.vault = vault; self.namespace = namespace; teamID = team
        bundles = identity.bundles.map { BundleTarget(component: $0.componentRelativePath, identifier: $0.bundleIdentifier) }
        // This sealed value already contains original bundles, ordered groups,
        // signed profile allowances and signer hashes. No caller-made team DTO.
        let identityEncoder = JSONEncoder(); identityEncoder.outputFormatting = [.sortedKeys]
        identitySHA256 = Data(SHA256.hash(data: try identityEncoder.encode(IdentityPin(identity))))
        self.issuerChainDER = issuerChainDER; self.transport = transport; self.storage = storage
        self.freshAnisette = freshAnisette; self.clock = clock
    }

    /// Explicit session import is transitional until the real GSA login owner
    /// produces Credentials. It never accepts a caller's "validated" Boolean.
    func connect(_ candidate: Credentials) async throws -> SessionObservation {
        guard !busy else { throw Failure.busy }; busy = true; defer { busy = false }
        let operationEpoch = epoch
        let loaded = try load()
        let remote = try await validateRemote(candidate, expected: loaded?.record.pin, epoch: operationEpoch)
        try check(operationEpoch)
        let record = Record(schema: 1, namespaceID: namespace.id, identitySHA256: identitySHA256,
            pin: remote.pin, credentials: candidate, pending: loaded?.record.pending)
        try save(record, replacing: loaded?.encoded)
        locallyInvalidated = false
        return SessionObservation(checkedAt: clock(), personalTeamMatched: true)
    }

    func observeSession() async throws -> SessionObservation {
        guard !busy else { throw Failure.busy }; busy = true; defer { busy = false }
        guard !locallyInvalidated else { throw Failure.signedOut }
        let operationEpoch = epoch
        guard let loaded = try load(), let credentials = loaded.record.credentials else { throw Failure.signedOut }
        do { _ = try await validateRemote(credentials, expected: loaded.record.pin, epoch: operationEpoch) }
        catch { try invalidateIfNecessary(error, loaded: loaded); throw error }
        return SessionObservation(checkedAt: clock(), personalTeamMatched: true)
    }

    /// Calls the actual portal CSR/profile protocol and publishes only through
    /// the SAME Vault's chain, private-key, profile double-CMS and identity CAS.
    /// Existing registered App IDs are required: no bundle/group rewrite or
    /// implicit remote certificate revocation is performed to make it succeed.
    func refreshMaterials(keyID: UUID, expectedGeneration: UInt64, machineName: String) async throws -> Vault.Lease {
        guard !busy else { throw Failure.busy }; busy = true; defer { busy = false }
        guard !locallyInvalidated else { throw Failure.signedOut }
        let started = SourcePerfTrace.now
        defer { SourcePerfTrace.record("renewal.account.refresh",
            "bundles=\(bundles.count) main=\(Thread.isMainThread)", since: started, thresholdMs: 0) }
        let operationEpoch = epoch
        guard var loaded = try load(), let credentials = loaded.record.credentials else { throw Failure.signedOut }
        guard loaded.record.pending == nil else { throw Failure.reconciliationRequired }
        guard Self.headerValue(machineName, limit: 128) else { throw Failure.invalidInput }
        var certificateIntent = false, profileIntent = false
        do {
            let account = try await validateRemote(credentials, expected: loaded.record.pin, epoch: operationEpoch)
            let csr = try await vault.certificateSigningRequest(in: namespace, keyID: keyID,
                expectedGeneration: expectedGeneration, commonName: account.commonName, emailAddress: account.pin.email)
            try check(operationEpoch)
            let appIDs = try await request(.appIDs, credentials: credentials, team: teamID, epoch: operationEpoch)
            let identifiers = try registeredAppIDs(appIDs)
            let publication = try await vault.publicationBaseline(in: namespace, expectedGeneration: expectedGeneration)
            let certificates = try await listDevelopmentCertificates(credentials: credentials, epoch: operationEpoch)
            try check(operationEpoch)
            let currentPublication = try await vault.publicationBaseline(in: namespace, expectedGeneration: expectedGeneration)
            guard currentPublication == publication else { throw Failure.staleOperation }
            let currentRequest = try await vault.certificateSigningRequest(in: namespace, keyID: keyID,
                expectedGeneration: expectedGeneration, commonName: account.commonName, emailAddress: account.pin.email)
            guard currentRequest.der == csr.der, currentRequest.publicKeySHA256 == csr.publicKeySHA256 else { throw Failure.keyMismatch }
            try check(operationEpoch)
            let baseline = CertificateBaseline(certificateSHA256s: certificates.map(\.sha256).sorted { $0.lexicographicallyPrecedes($1) },
                priorPublishedLeafSHA256: publication?.leafCertificateSHA256, requestDERSHA256: Data(SHA256.hash(data: csr.der)))
            let operationID = UUID()
            loaded.record.pending = PendingEnrollment(operationID: operationID, keyID: keyID,
                materialGeneration: expectedGeneration, requestPublicKeySHA256: csr.publicKeySHA256,
                startedAt: clock(), phase: .certificateRequestIntent, certificateSHA256: nil, reconciliationBaseline: baseline)
            loaded.encoded = try save(loaded.record, replacing: loaded.encoded)
            // Persist the possibility BEFORE dispatch. A timeout/lost ACK is
            // never retried automatically, including after process restart.
            certificateIntent = true
            let certificateResponse = try await request(.certificates, credentials: credentials, team: teamID,
                parameters: ["csrContent": Self.pem(csr.der), "machineId": operationID.uuidString,
                    "machineName": machineName], epoch: operationEpoch)
            let certificate = try issuedCertificate(certificateResponse, csr: csr)
            let certificateHash = Data(SHA256.hash(data: certificate))
            guard !baseline.certificateSHA256s.contains(certificateHash),
                  baseline.priorPublishedLeafSHA256 != certificateHash else { throw Failure.reconciliationRequired }
            loaded.record.pending?.phase = .certificateObserved
            loaded.record.pending?.certificateSHA256 = certificateHash
            loaded.encoded = try save(loaded.record, replacing: loaded.encoded)
            return try await completeEnrollment(loaded: &loaded, certificate: certificate, csr: csr,
                account: account, identifiers: identifiers, credentials: credentials,
                operationEpoch: operationEpoch, profileIntent: &profileIntent)
        } catch let error as PublicationFinalizationFailure { throw error }
        catch {
            // Only a verified session failure removes credential use. Pending
            // remote intent survives; old valid Vault publication is untouched
            // unless the actual final publish above was acknowledged.
            let originalFailure = error
            let finalFailure: Error
            do { try invalidateIfNecessary(originalFailure, loaded: loaded); finalFailure = originalFailure }
            catch { finalFailure = error }
            throw EnrollmentFailure(underlying: finalFailure, remoteCertificateMayHaveBeenIssued: certificateIntent,
                remoteProfilesMayHaveBeenRefreshed: profileIntent)
        }
    }


    private func completeEnrollment(loaded: inout Loaded, certificate: Data, csr: Vault.CertificateRequest,
        account: RemoteAccount, identifiers: [String: String], credentials: Credentials,
        operationEpoch: UInt64, profileIntent: inout Bool) async throws -> Vault.Lease {
        var profiles: [Vault.ProfileInput] = []
        for bundle in bundles {
            try check(operationEpoch)
            guard let identifier = identifiers[bundle.identifier] else { throw Failure.appIdentifierMissing }
            profileIntent = true
            let response = try await request(.profile, credentials: credentials, team: teamID,
                parameters: ["appIdId": identifier], epoch: operationEpoch)
            let container = try Self.dictionary(response["provisioningProfile"])
            let bytes = try Self.bytes(container["encodedProfile"], maximum: Vault.Limits.profileBytes)
            profiles.append(.init(componentRelativePath: bundle.component, bytes: bytes))
        }
        // Recheck remote account/team and the real persisted key after all
        // awaits. A retained CSR or raw token is not a commit capability.
        _ = try await validateRemote(credentials, expected: loaded.record.pin, epoch: operationEpoch)
        let currentCSR = try await vault.certificateSigningRequest(in: namespace, keyID: csr.keyID,
            expectedGeneration: csr.generation, commonName: account.commonName, emailAddress: account.pin.email)
        guard currentCSR.publicKeySHA256 == csr.publicKeySHA256, currentCSR.der == csr.der else { throw Failure.keyMismatch }
        try check(operationEpoch)
        let lease = try await vault.publish(in: namespace, keyID: csr.keyID, expectedGeneration: csr.generation,
            certificateChainDER: [certificate] + issuerChainDER, profiles: profiles)
        // No cancellation check after this acknowledged Vault commit.
        // The later credential write cannot roll it back or hide its fact.
        do {
            loaded.record.pending = nil
            _ = try save(loaded.record, replacing: loaded.encoded)
        } catch { throw PublicationFinalizationFailure(publishedLease: lease, underlying: error) }
        return lease
    }

    /// A read-only certificate-list reconciliation never submits another CSR.
    /// Candidate presence is not revocation, issue causality or Apple authority.
    /// Profiles and publication still use the sole verified Vault commit path.
    func reconcilePendingMaterials() async throws -> Vault.Lease {
        guard !busy else { throw Failure.busy }; busy = true; defer { busy = false }
        let started = SourcePerfTrace.now
        defer { SourcePerfTrace.record("renewal.account.reconcile", "main=\(Thread.isMainThread)", since: started, thresholdMs: 0) }
        let operationEpoch = epoch
        guard var loaded = try load(), let pending = loaded.record.pending else { throw Failure.reconciliationRequired }
        let now = clock()
        guard now.timeIntervalSince1970.isFinite, now >= pending.startedAt else { throw Vault.Failure.clockMovedBackwards }
        // An acknowledged publication can be finalized locally even if the
        // account credential later expired. Never replace this with a new issue.
        let generation = try await vault.generation(in: namespace)
        try check(operationEpoch)
        if generation == pending.materialGeneration + 1, pending.phase == .certificateObserved {
            return try await finalizeObservedPublication(loaded: &loaded, pending: pending, operationEpoch: operationEpoch)
        }
        guard generation == pending.materialGeneration else { throw Vault.Failure.staleGeneration }
        guard !locallyInvalidated, let credentials = loaded.record.credentials else { throw Failure.signedOut }
        guard let baseline = pending.reconciliationBaseline else { throw Failure.reconciliationRequired }
        var profileIntent = false
        do {
            let account = try await validateRemote(credentials, expected: loaded.record.pin, epoch: operationEpoch)
            let publication = try await vault.publicationBaseline(in: namespace, expectedGeneration: pending.materialGeneration)
            guard publication?.leafCertificateSHA256 == baseline.priorPublishedLeafSHA256 else { throw Failure.staleOperation }
            let csr = try await vault.certificateSigningRequest(in: namespace, keyID: pending.keyID,
                expectedGeneration: pending.materialGeneration, commonName: account.commonName, emailAddress: account.pin.email)
            guard csr.publicKeySHA256 == pending.requestPublicKeySHA256,
                  Data(SHA256.hash(data: csr.der)) == baseline.requestDERSHA256 else { throw Failure.keyMismatch }
            let certificates = try await listDevelopmentCertificates(credentials: credentials, epoch: operationEpoch)
            try check(operationEpoch)
            var excluded = Set(baseline.certificateSHA256s)
            if let old = baseline.priorPublishedLeafSHA256 { excluded.insert(old) }
            let candidates = certificates.filter {
                !excluded.contains($0.sha256) && $0.publicKeySHA256 == csr.publicKeySHA256
            }
            guard candidates.count <= 1 else { throw Failure.ambiguousCertificate }
            guard let candidate = candidates.first else { throw Failure.reconciliationRequired }
            // Metadata can reject a conflicting request association, but must
            // not turn multiple actual key-matching certificates into one.
            guard candidate.machineID == nil || candidate.machineID.flatMap(UUID.init(uuidString:)) == pending.operationID else {
                throw Failure.reconciliationRequired
            }
            if let observed = pending.certificateSHA256, observed != candidate.sha256 { throw Failure.reconciliationRequired }
            let currentCSR = try await vault.certificateSigningRequest(in: namespace, keyID: pending.keyID,
                expectedGeneration: pending.materialGeneration, commonName: account.commonName, emailAddress: account.pin.email)
            guard currentCSR.der == csr.der, currentCSR.publicKeySHA256 == csr.publicKeySHA256 else { throw Failure.keyMismatch }
            try check(operationEpoch)
            let response = try await request(.appIDs, credentials: credentials, team: teamID, epoch: operationEpoch)
            let identifiers = try registeredAppIDs(response)
            loaded.record.pending?.phase = .certificateObserved
            loaded.record.pending?.certificateSHA256 = candidate.sha256
            loaded.encoded = try save(loaded.record, replacing: loaded.encoded)
            return try await completeEnrollment(loaded: &loaded, certificate: candidate.der, csr: csr,
                account: account, identifiers: identifiers, credentials: credentials,
                operationEpoch: operationEpoch, profileIntent: &profileIntent)
        } catch let failure as PublicationFinalizationFailure { throw failure }
        catch {
            let original = error
            let finalFailure: Error
            do { try invalidateIfNecessary(original, loaded: loaded); finalFailure = original }
            catch { finalFailure = error }
            throw EnrollmentFailure(underlying: finalFailure, remoteCertificateMayHaveBeenIssued: true,
                remoteProfilesMayHaveBeenRefreshed: profileIntent)
        }
    }

    func pendingEnrollment() throws -> PendingEnrollment? { try load()?.record.pending }

    /// Reconciles only a real already-published Vault lease. It does not issue
    /// another certificate/profile request or accept a caller success flag.
    func finalizeObservedPublication() async throws -> Vault.Lease {
        guard !busy else { throw Failure.busy }; busy = true; defer { busy = false }
        let operationEpoch = epoch
        guard var loaded = try load(), let pending = loaded.record.pending else { throw Failure.reconciliationRequired }
        return try await finalizeObservedPublication(loaded: &loaded, pending: pending, operationEpoch: operationEpoch)
    }

    private func finalizeObservedPublication(loaded: inout Loaded, pending: PendingEnrollment,
        operationEpoch: UInt64) async throws -> Vault.Lease {
        guard pending.phase == .certificateObserved, let fingerprint = pending.certificateSHA256,
              pending.materialGeneration < UInt64.max else { throw Failure.reconciliationRequired }
        let lease = try await vault.lease(in: namespace)
        try check(operationEpoch)
        guard lease.keyID == pending.keyID, lease.generation == pending.materialGeneration + 1,
              let leaf = lease.keyMaterial.certificateChainDER.first,
              Data(SHA256.hash(data: leaf)) == fingerprint else { throw Failure.reconciliationRequired }
        loaded.record.pending = nil
        do { _ = try save(loaded.record, replacing: loaded.encoded) }
        catch { throw PublicationFinalizationFailure(publishedLease: lease, underlying: error) }
        return lease
    }

    /// Caller cancels/awaits an active refresh before logout. Rejecting busy
    /// avoids promising atomic logout against another actor's Vault commit.
    /// Keep any unresolved remote intent; logout is not remote revocation.
    func signOut() throws {
        guard !busy else { throw Failure.busy }
        guard epoch < UInt64.max else { throw Failure.limit }; epoch += 1
        locallyInvalidated = true
        if var loaded = try load() {
            loaded.record.credentials = nil
            _ = try save(loaded.record, replacing: loaded.encoded)
        }
    }

    /// Erase-only access for an already configured namespace whose signing
    /// materials can no longer open a client. This does not authenticate a
    /// namespace, alter its pin/pending intent, or grant signing authority.
    /// Call off main and only after the owning Session has released its client.
    static func signOutStoredCredentials(namespaceID: UUID,
        storage: any SelfRenewalDeveloperSessionStorage = SelfRenewalDeveloperKeychainSessionStorage()) throws {
        let started = SourcePerfTrace.now
        defer { SourcePerfTrace.record("renewal.account.eraseCredentials",
            "main=\(Thread.isMainThread)", since: started, thresholdMs: 0) }
        try Task.checkCancellation()
        guard var loaded = try loadStored(namespaceID: namespaceID, storage: storage) else { return }
        guard loaded.record.credentials != nil else { return }
        loaded.record.credentials = nil
        _ = try saveStored(loaded.record, replacing: loaded.encoded, namespaceID: namespaceID, storage: storage)
    }

    private func validateRemote(_ credentials: Credentials, expected: AccountPin?, epoch: UInt64) async throws -> RemoteAccount {
        try validateCredentials(credentials)
        let developerResponse = try await request(.developer, credentials: credentials, epoch: epoch)
        let developer = try Self.dictionary(developerResponse["developer"])
        let personID = try Self.identifier(developer["personId"])
        let email = try Self.text(developer["email"], limit: 254)
        let first = try Self.text(developer["firstName"] ?? developer["dsFirstName"], limit: 100)
        let last = try Self.text(developer["lastName"] ?? developer["dsLastName"], limit: 100)
        let pin = AccountPin(dsid: credentials.dsid, personID: personID, email: email, teamID: teamID)
        if let expected, !Self.samePin(pin, expected) { throw Failure.accountChanged }
        let response = try await request(.teams, credentials: credentials, epoch: epoch)
        guard case .array(let teams)? = response["teams"], !teams.isEmpty, teams.count <= 32 else { throw Failure.malformedResponse }
        var matched = 0
        for value in teams {
            let team = try Self.dictionary(value)
            if Self.same(try Self.text(team["teamId"], limit: 128), teamID) {
                matched += 1
                guard try Self.text(team["type"], limit: 64) == "Individual",
                      case .array(let memberships)? = team["memberships"], memberships.count == 1 else { throw Failure.notPersonalTeam }
                let membership = try Self.dictionary(memberships[0])
                guard try Self.text(membership["name"], limit: 128).lowercased().contains("free") else { throw Failure.notPersonalTeam }
            }
        }
        guard matched == 1 else { throw Failure.teamChanged }
        try check(epoch)
        return RemoteAccount(pin: pin, commonName: first + " " + last)
    }

    private func request(_ action: Action, credentials: Credentials, team: String? = nil,
        parameters: [String: String] = [:], epoch: UInt64) async throws -> [String: Value] {
        let started = SourcePerfTrace.now
        var responseBytes = 0
        defer { SourcePerfTrace.record("renewal.account.request",
            "stage=\(action.rawValue) responseBytes=\(responseBytes) main=\(Thread.isMainThread)", since: started, thresholdMs: 0) }
        var body = parameters
        body["clientId"] = "XABBG36SBA"; body["protocolVersion"] = "QH65B2"; body["requestId"] = UUID().uuidString
        if let team { body["teamId"] = team }
        let data = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
        guard data.count <= 32_768,
              let url = URL(string: "https://developerservices2.apple.com/services/QH65B2/" + action.rawValue + "?clientId=XABBG36SBA") else { throw Failure.limit }
        let response = try await sendDeveloperRequest(url: url, body: data, mediaType: "text/x-xml-plist",
            credentials: credentials, epoch: epoch)
        responseBytes = response.count
        let result: [String: Value]
        do { result = try Self.dictionary(SelfRenewalDERPropertyList.decodeXMLPropertyList(response)) }
        catch is CancellationError { throw CancellationError() }
        catch { throw Failure.malformedResponse }
        let code = try Self.integer(result["resultCode"])
        guard code != 1100 else { throw Failure.sessionExpired }
        guard code == 0 else { throw Failure.portal(code) }
        return result
    }

    /// Exact pinned AltSign services/v1 wire: POST containing an encoded query,
    /// with GET override. No revocation, unfiltered request, paging guess or CSR.
    private func listDevelopmentCertificates(credentials: Credentials, epoch: UInt64) async throws -> [ListedCertificate] {
        let started = SourcePerfTrace.now
        var responseBytes = 0
        defer { SourcePerfTrace.record("renewal.account.list-certificates",
            "responseBytes=\(responseBytes) main=\(Thread.isMainThread)", since: started, thresholdMs: 0) }
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "teamId", value: teamID),
            URLQueryItem(name: "filter[certificateType]", value: "IOS_DEVELOPMENT")]
        guard let encoded = components.query,
              let url = URL(string: "https://developerservices2.apple.com/services/v1/certificates") else { throw Failure.invalidInput }
        let body = try JSONSerialization.data(withJSONObject: ["urlEncodedQueryParams": encoded], options: [.sortedKeys])
        let bytes = try await sendDeveloperRequest(url: url, body: body, mediaType: "application/vnd.api+json",
            methodOverride: "GET", credentials: credentials, epoch: epoch)
        responseBytes = bytes.count
        let document: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw Failure.malformedResponse }
            document = parsed
        } catch { throw Failure.malformedResponse }
        guard Set(document.keys).isSubset(of: ["data", "meta", "links", "jsonapi", "resultCode", "resultString", "userString", "errors"]) else {
            throw Failure.incompleteCertificateList
        }
        if let raw = document["resultCode"] {
            let code: Int64
            if let text = raw as? String { code = try Self.integer(.string(text)) }
            else { code = try Self.jsonInteger(raw, minimum: Int64.min, maximum: Int64.max) }
            guard code != 1100 else { throw Failure.sessionExpired }
            guard code == 0 else { throw Failure.portal(code) }
        }
        if let rawErrors = document["errors"], !(rawErrors is NSNull) {
            guard let errors = rawErrors as? [Any], errors.isEmpty else { throw Failure.malformedResponse }
        }
        guard let entries = document["data"] as? [[String: Any]], entries.count <= 256 else { throw Failure.malformedResponse }
        // AltSign's old parser ignores pagination. It does NOT establish that
        // every real response has this marker. Unknown/missing completeness is
        // explicitly unresolved, not a truncated baseline or a new authority.
        guard let meta = document["meta"] as? [String: Any], Set(meta.keys) == ["paging"],
              let paging = meta["paging"] as? [String: Any],
              Set(paging.keys).isSubset(of: ["total", "limit", "nextCursor"]),
              let total = paging["total"], try Self.jsonInteger(total, maximum: 256) == Int64(entries.count) else {
            throw Failure.incompleteCertificateList
        }
        if let limit = paging["limit"] {
            guard try Self.jsonInteger(limit, maximum: 1_000_000) >= Int64(entries.count) else { throw Failure.incompleteCertificateList }
        }
        if let cursor = paging["nextCursor"], !(cursor is NSNull) { throw Failure.incompleteCertificateList }
        if let raw = document["links"], !(raw is NSNull) {
            guard let links = raw as? [String: Any], Set(links.keys).isSubset(of: ["self", "next", "prev", "first", "last"]) else {
                throw Failure.incompleteCertificateList
            }
            for key in ["next", "prev", "first", "last"] {
                if let value = links[key], !(value is NSNull) { throw Failure.incompleteCertificateList }
            }
        }
        var result: [ListedCertificate] = [], ids = Set<String>(), fingerprints = Set<Data>(), totalDERBytes = 0
        for entry in entries {
            try check(epoch)
            guard let id = entry["id"] as? String, Self.headerValue(id, limit: 128), ids.insert(id).inserted,
                  entry["type"] as? String == "certificates", let attributes = entry["attributes"] as? [String: Any],
                  let encoded = attributes["certificateContent"] as? String, !encoded.isEmpty, encoded.utf8.count <= 87_384,
                  let encodedBytes = Data(base64Encoded: encoded), !encodedBytes.isEmpty,
                  encodedBytes.count <= Vault.Limits.certificateBytes,
                  encodedBytes.base64EncodedString() == encoded else { throw Failure.malformedResponse }
            let (der, certificate) = try Self.certificateDER(encodedBytes)
            guard der.count <= 524_288 - totalDERBytes,
                  let publicKey = SecCertificateCopyKey(certificate) else { throw Failure.malformedResponse }
            totalDERBytes += der.count
            let hash = Data(SHA256.hash(data: der))
            guard fingerprints.insert(hash).inserted else { throw Failure.ambiguousCertificate }
            var error: Unmanaged<CFError>?
            let raw = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?
            if let error { _ = error.takeRetainedValue() }
            guard let raw, !raw.isEmpty, raw.count <= 1024 else { throw Failure.malformedResponse }
            let machine: String?
            if let value = attributes["machineId"], !(value is NSNull) {
                guard let text = value as? String, Self.headerValue(text, limit: 128) else { throw Failure.malformedResponse }
                machine = text
            } else { machine = nil }
            result.append(ListedCertificate(id: id, der: der, sha256: hash,
                publicKeySHA256: Data(SHA256.hash(data: raw)), machineID: machine))
        }
        try check(epoch)
        return result
    }

    private static func jsonInteger(_ value: Any, minimum: Int64 = 0, maximum: Int64) throws -> Int64 {
        guard let number = value as? NSNumber, CFGetTypeID(number as CFTypeRef) == CFNumberGetTypeID(),
              String(cString: number.objCType) != "d", String(cString: number.objCType) != "f", number.int64Value >= minimum,
              number.int64Value <= maximum, number.stringValue == String(number.int64Value) else { throw Failure.malformedResponse }
        return number.int64Value
    }

    /// The same session, fresh anisette, privacy, cancellation and HTTP checks
    /// serve both the existing plist actions and the one read-only JSON action.
    private func sendDeveloperRequest(url: URL, body: Data, mediaType: String, methodOverride: String? = nil,
        credentials: Credentials, epoch: UInt64) async throws -> Data {
        try check(epoch); try validateCredentials(credentials)
        guard body.count <= 32_768 else { throw Failure.limit }
        let anisette = try await freshAnisette()
        try check(epoch); try validateCredentials(credentials)
        let now = clock()
        guard now.timeIntervalSince1970.isFinite, anisette.issuedAt.timeIntervalSince1970.isFinite,
              abs(now.timeIntervalSince(anisette.issuedAt)) <= 300 else { throw Failure.invalidInput }
        let values = [anisette.machineID, anisette.oneTimePassword, anisette.localUserID,
            anisette.deviceID, anisette.clientInfo, anisette.locale, anisette.timeZone]
        guard values.allSatisfy({ Self.headerValue($0, limit: 4096) }) else { throw Failure.invalidInput }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 30
        let formatter = ISO8601DateFormatter()
        let headers = ["Content-Type": mediaType, "Accept": mediaType, "User-Agent": "Xcode",
            "Accept-Language": "en-us", "X-Apple-App-Info": "com.apple.gs.xcode.auth", "X-Xcode-Version": "11.2 (11B41)",
            "X-Apple-I-Identity-Id": credentials.dsid, "X-Apple-GS-Token": credentials.xcodeToken,
            "X-Apple-I-MD-M": anisette.machineID, "X-Apple-I-MD": anisette.oneTimePassword,
            "X-Apple-I-MD-LU": anisette.localUserID, "X-Apple-I-MD-RINFO": String(anisette.routingInfo),
            "X-Mme-Device-Id": anisette.deviceID, "X-MMe-Client-Info": anisette.clientInfo,
            "X-Apple-I-Client-Time": formatter.string(from: anisette.issuedAt), "X-Apple-Locale": anisette.locale,
            "X-Apple-I-Locale": anisette.locale, "X-Apple-I-TimeZone": anisette.timeZone]
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let methodOverride { request.setValue(methodOverride, forHTTPHeaderField: "X-HTTP-Method-Override") }
        let response: SelfRenewalDeveloperAccountResponse
        do { response = try await transport.send(request) }
        catch is CancellationError { throw CancellationError() }
        catch let failure as SelfRenewalDeveloperAccountTransportFailure {
            if failure == .cancelled { throw CancellationError() }
            throw Failure.transport(failure.rawValue)
        }
        catch { throw Failure.transport(-1) }
        try check(epoch)
        guard response.statusCode != 401, response.statusCode != 403 else { throw Failure.sessionExpired }
        guard response.statusCode == 200 else { throw Failure.http(response.statusCode) }
        guard response.body.count <= SelfRenewalDERPropertyList.Limits.bytes else { throw Failure.limit }
        return response.body
    }

    private func registeredAppIDs(_ response: [String: Value]) throws -> [String: String] {
        guard case .array(let values)? = response["appIds"], values.count <= 256 else { throw Failure.malformedResponse }
        var result: [String: String] = [:]
        for value in values {
            let app = try Self.dictionary(value)
            let bundle = try Self.text(app["identifier"], limit: 255)
            if bundles.contains(where: { Self.same($0.identifier, bundle) }) {
                guard result[bundle] == nil else { throw Failure.ambiguousAppIdentifier }
                result[bundle] = try Self.text(app["appIdId"], limit: 128)
            }
        }
        guard bundles.allSatisfy({ result[$0.identifier] != nil }) else { throw Failure.appIdentifierMissing }
        return result
    }

    private func issuedCertificate(_ response: [String: Value], csr: Vault.CertificateRequest) throws -> Data {
        let container = try Self.dictionary(response["certRequest"])
        let encoded = try Self.bytes(container["certContent"], maximum: Vault.Limits.certificateBytes)
        let (bytes, certificate) = try Self.certificateDER(encoded)
        guard let publicKey = SecCertificateCopyKey(certificate) else { throw Failure.malformedResponse }
        var error: Unmanaged<CFError>?
        let raw = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?
        if let error { _ = error.takeRetainedValue() }
        guard let raw, raw.count <= 1024, Data(SHA256.hash(data: raw)) == csr.publicKeySHA256 else { throw Failure.keyMismatch }
        // Only a key-bound candidate here. Final trust/date/profile/group
        // verification remains the existing Vault publish(), never a second
        // weaker account-client certificate verifier.
        return bytes
    }

    /// AltSign accepts certificate data as DER or a single PEM certificate.
    /// Normalize before hashing so a PEM re-encoding cannot look like a new
    /// certificate. This is bounded structure parsing, never chain trust.
    private static func certificateDER(_ bytes: Data) throws -> (Data, SecCertificate) {
        guard !bytes.isEmpty, bytes.count <= Vault.Limits.certificateBytes else { throw Failure.limit }
        let der: Data
        let prefix = "-----BEGIN CERTIFICATE-----"
        if bytes.starts(with: Data(prefix.utf8)) {
            guard let text = String(data: bytes, encoding: .utf8),
                  text.utf8.allSatisfy({ $0 == 10 || $0 == 13 || (32...126).contains($0) }) else { throw Failure.malformedResponse }
            let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            guard !normalized.contains("\r") else { throw Failure.malformedResponse }
            let lines = normalized.trimmingCharacters(in: .newlines).split(separator: "\n", omittingEmptySubsequences: false)
            guard lines.count >= 3, lines.first == Substring(prefix), lines.last == "-----END CERTIFICATE-----",
                  lines.dropFirst().dropLast().allSatisfy({ !$0.isEmpty }) else { throw Failure.malformedResponse }
            let base64 = lines.dropFirst().dropLast().joined()
            guard let decoded = Data(base64Encoded: base64), !decoded.isEmpty, decoded.count <= Vault.Limits.certificateBytes,
                  decoded.base64EncodedString() == base64 else { throw Failure.malformedResponse }
            der = decoded
        } else { der = bytes }
        do { _ = try SelfRenewalCMSVerifier.parseDER(der) }
        catch is CancellationError { throw CancellationError() }
        catch { throw Failure.malformedResponse }
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { throw Failure.malformedResponse }
        return (der, certificate)
    }

    private func load() throws -> Loaded? {
        guard let loaded = try Self.loadStored(namespaceID: namespace.id, storage: storage) else { return nil }
        guard loaded.record.identitySHA256 == identitySHA256, Self.same(loaded.record.pin.teamID, teamID) else {
            throw Failure.accountChanged
        }
        return loaded
    }
    private static func loadStored(namespaceID: UUID, storage: any SelfRenewalDeveloperSessionStorage) throws -> Loaded? {
        try Task.checkCancellation()
        guard let encoded = try storage.load(namespace: namespaceID) else { return nil }
        let bytes = Data(encoded.utf8)
        guard bytes.count <= 65_536 else { throw Failure.limit }
        let record: Record
        do { record = try JSONDecoder().decode(Record.self, from: bytes) }
        catch { throw Failure.storage }
        guard record.schema == 1, record.namespaceID == namespaceID, record.identitySHA256.count == 32,
              headerValue(record.pin.dsid, limit: 128), headerValue(record.pin.personID, limit: 128),
              headerValue(record.pin.email, limit: 254), headerValue(record.pin.teamID, limit: 128) else { throw Failure.storage }
        if let credentials = record.credentials {
            guard headerValue(credentials.dsid, limit: 128), headerValue(credentials.xcodeToken, limit: 8192),
                  credentials.expiresAt.timeIntervalSince1970.isFinite,
                  same(credentials.dsid, record.pin.dsid) else { throw Failure.storage }
        }
        if let pending = record.pending {
            guard pending.requestPublicKeySHA256.count == 32, pending.startedAt.timeIntervalSince1970.isFinite,
                  pending.materialGeneration < UInt64.max else { throw Failure.storage }
            if let baseline = pending.reconciliationBaseline {
                guard baseline.certificateSHA256s.count <= 256,
                      baseline.certificateSHA256s.allSatisfy({ $0.count == 32 }),
                      Set(baseline.certificateSHA256s).count == baseline.certificateSHA256s.count,
                      baseline.certificateSHA256s == baseline.certificateSHA256s.sorted(by: { $0.lexicographicallyPrecedes($1) }),
                      baseline.requestDERSHA256.count == 32,
                      baseline.priorPublishedLeafSHA256 == nil || baseline.priorPublishedLeafSHA256?.count == 32 else {
                    throw Failure.storage
                }
            }
            switch pending.phase {
            case .certificateRequestIntent:
                guard pending.certificateSHA256 == nil else { throw Failure.storage }
            case .certificateObserved:
                guard pending.certificateSHA256?.count == 32 else { throw Failure.storage }
            }
        }
        try Task.checkCancellation()
        return Loaded(record: record, encoded: encoded)
    }
    @discardableResult private func save(_ record: Record, replacing old: String?) throws -> String {
        try Self.saveStored(record, replacing: old, namespaceID: namespace.id, storage: storage)
    }
    @discardableResult private static func saveStored(_ record: Record, replacing old: String?, namespaceID: UUID,
        storage: any SelfRenewalDeveloperSessionStorage) throws -> String {
        try Task.checkCancellation()
        let current = try storage.load(namespace: namespaceID)
        guard current.map({ Data($0.utf8) }) == old.map({ Data($0.utf8) }) else { throw Failure.staleOperation }
        let bytes = try JSONEncoder().encode(record)
        guard bytes.count <= 65_536, let encoded = String(data: bytes, encoding: .utf8) else { throw Failure.limit }
        try Task.checkCancellation()
        // One injected actor and observed equality, not a cross-process CAS.
        try storage.save(namespace: namespaceID, value: encoded)
        return encoded
    }
    private func invalidateIfNecessary(_ error: Error, loaded: Loaded) throws {
        guard let failure = error as? Failure,
              [.sessionExpired, .accountChanged, .teamChanged, .notPersonalTeam].contains(failure) else { return }
        guard epoch < UInt64.max else { throw Failure.limit }; epoch += 1
        locallyInvalidated = true
        var record = loaded.record; record.credentials = nil
        do { _ = try save(record, replacing: loaded.encoded) }
        catch { throw SessionInvalidationFailure(sessionError: failure, storageError: error) }
    }
    private func validateCredentials(_ value: Credentials) throws {
        guard Self.headerValue(value.dsid, limit: 128), Self.headerValue(value.xcodeToken, limit: 8192),
              value.expiresAt.timeIntervalSince1970.isFinite else { throw Failure.invalidInput }
        guard clock().timeIntervalSince1970.isFinite, value.expiresAt > clock() else { throw Failure.sessionExpired }
    }
    private func check(_ expectedEpoch: UInt64) throws {
        try Task.checkCancellation()
        guard epoch == expectedEpoch else { throw Failure.staleOperation }
    }
    private static func headerValue(_ value: String, limit: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= limit && value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7f }
    }
    private static func dictionary(_ value: Value?) throws -> [String: Value] {
        guard case .dictionary(let result)? = value else { throw Failure.malformedResponse }; return result
    }
    private static func text(_ value: Value?, limit: Int) throws -> String {
        guard case .string(let text)? = value, headerValue(text, limit: limit) else { throw Failure.malformedResponse }; return text
    }
    private static func bytes(_ value: Value?, maximum: Int) throws -> Data {
        guard case .data(let bytes)? = value, !bytes.isEmpty, bytes.count <= maximum else { throw Failure.malformedResponse }; return bytes
    }
    private static func integer(_ value: Value?) throws -> Int64 {
        if case .integer(let number)? = value { return number }
        if case .string(let text)? = value, !text.isEmpty, text.utf8.count <= 24,
           text.utf8.allSatisfy({ (48...57).contains($0) || $0 == 45 }), let result = Int64(text) { return result }
        throw Failure.malformedResponse
    }
    private static func identifier(_ value: Value?) throws -> String {
        if case .string(let text)? = value { return try Self.text(.string(text), limit: 128) }
        if case .integer(let value)? = value, value >= 0 { return String(value) }
        throw Failure.malformedResponse
    }
    private static func pem(_ der: Data) -> String {
        let base64 = Array(der.base64EncodedString().utf8)
        let lines = stride(from: 0, to: base64.count, by: 64).map { String(decoding: base64[$0..<min($0 + 64, base64.count)], as: UTF8.self) }
        return "-----BEGIN CERTIFICATE REQUEST-----\n" + lines.joined(separator: "\n") + "\n-----END CERTIFICATE REQUEST-----\n"
    }
    private static func same(_ lhs: String, _ rhs: String) -> Bool { Data(lhs.utf8) == Data(rhs.utf8) }
    private static func samePin(_ lhs: AccountPin, _ rhs: AccountPin) -> Bool {
        same(lhs.dsid, rhs.dsid) && same(lhs.personID, rhs.personID) && same(lhs.email, rhs.email) && same(lhs.teamID, rhs.teamID)
    }
    private struct IdentityPin: Encodable {
        struct Bundle: Encodable {
            let component: String; let identifier: String; let slices: [Slice]
        }
        struct Slice: Encodable {
            let applicationIdentifier: String; let team: String; let appGroups: [String]; let keychainGroups: [String]
        }
        let bundles: [Bundle]
        init(_ identity: SelfRenewalApplicationMaterialVerifier.Materials) {
            bundles = identity.bundles.map { bundle in Bundle(component: bundle.componentRelativePath,
                identifier: bundle.bundleIdentifier, slices: bundle.slices.map { Slice(applicationIdentifier: $0.applicationIdentifier,
                    team: $0.teamIdentifier, appGroups: $0.appGroups, keychainGroups: $0.keychainAccessGroups) }) }
        }
        init(_ identity: Vault.EnrollmentIdentity) {
            bundles = identity.bundles.map { bundle in Bundle(component: bundle.componentRelativePath,
                identifier: bundle.bundleIdentifier, slices: (0..<bundle.observedSliceCount).map { _ in
                    Slice(applicationIdentifier: bundle.applicationIdentifier, team: bundle.teamIdentifier,
                        appGroups: bundle.appGroups, keychainGroups: bundle.keychainAccessGroups)
                }) }
        }
    }
}
