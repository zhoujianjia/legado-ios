import CryptoKit
import Darwin
import Foundation
import Security

/// The App's single local session. Public configuration selects existing vault
/// and Keychain objects; decoding it never produces a trusted signing proof.
actor SelfRenewalAppSession {
    typealias Journal = SelfRenewalTransactionJournal
    typealias Vault = SelfRenewalSigningMaterialVault
    typealias Coordinator = SelfRenewalControlledRenewalCoordinator
    typealias Transport = SelfRenewalAuthenticatedDeviceTransport
    enum Failure: Error, Sendable, Equatable {
        case invalidConfiguration, configurationInUse, storage, changedFile, limit
        case notConfigured, authenticationNotConfigured, identityUnavailable(OSStatus), busy
        case commitDurabilityUnknown
        case ownedApplicationIsNotCurrentProcess
    }
    enum DeveloperServicesFailure: Error, Sendable, Equatable { case unavailable }
    /// Cancellation can race a successful secure save. Preserve that confirmed
    /// connection fact while clearing the actual pending authentication state.
    struct DeveloperAuthenticationCancellation: Sendable {
        let confirmedSession: SelfRenewalDeveloperAccountClient.SessionObservation?
    }
    /// One injected account HTTP owner and credential service, shared with the
    /// GSA login path. Constructing the App session performs no account I/O.
    struct DeveloperServices: Sendable {
        let transport: any SelfRenewalDeveloperAccountTransport
        let storage: any SelfRenewalDeveloperSessionStorage
        let freshAnisette: @Sendable () async throws -> SelfRenewalDeveloperAccountClient.Anisette
    }
    /// Public acknowledgement facts only. The private signing handle remains
    /// in the Vault; a refreshed material set is not an installed application.
    struct DeveloperMaterialObservation: Sendable, Equatable {
        let namespaceID: UUID
        let keyID: UUID
        let generation: UInt64
        let leafSHA256: Data?
        let profileExpiresAt: Date?
        let verifiedAt: Date
        var appleAuthorizationEstablished: Bool { false }
        var installedApplicationRenewed: Bool { false }
        fileprivate init(_ lease: Vault.Lease) {
            namespaceID = lease.namespace.id; keyID = lease.keyID; generation = lease.generation
            leafSHA256 = lease.keyMaterial.certificateChainDER.first.map { Data(SHA256.hash(data: $0)) }
            profileExpiresAt = lease.profiles.map(\.summary.expiresAt).min(); verifiedAt = lease.verifiedAt
        }
    }
    /// The existing Document retains the initial binding before any create.
    /// A failed final acknowledgement cannot discard that durable UUID or
    /// substitute a new namespace on the next retry/process.
    struct InitialNamespaceBindingFailure: Error, @unchecked Sendable {
        let namespaceID: UUID
        let underlying: Error
    }
    struct DeveloperMaterialFinalizationFailure: Error, @unchecked Sendable {
        let published: DeveloperMaterialObservation
        let underlying: Error
    }
    enum State: String, Sendable, Codable {
        case unconfigured, ready, candidateReady, recoveryRequired, attentionRequired
        case retiredUnsubmitted, authenticatedRecoveryObserved, unavailable
    }
    enum Access: String, Sendable, Codable { case signing, recoveryOnly }
    struct Status: Sendable, Codable, Equatable {
        let state: State
        let phase: Journal.Phase?
        let observedAt: Date
        let problem: Problem?
        let access: Access?
        var automaticRenewalVerified: Bool { false }
        var appleAuthorizationVerified: Bool { false }
        var coldLaunchVerified: Bool { false }
        var allUserDataPreservationVerified: Bool { false }
    }
    enum Problem: String, Sendable, Codable {
        case configuration, signingMaterials, authentication, storage, observation, cancelled
    }
    struct Unavailable: Error, @unchecked Sendable {
        let underlying: Error
        let problem: Problem
        let statusPersistenceError: Error?
    }
    struct ObservationFailures: Error, @unchecked Sendable {
        let installedMaterial: Error?
        let normalUserData: Error?
    }
    struct InitializationFailure: Error, @unchecked Sendable {
        let underlying: Error
        let journalCloseError: Error
    }
    struct SigningMaterialUnavailable: Error, @unchecked Sendable {
        let underlying: Error
        let recoveryContextError: Error?
    }
    struct RecoveryFailed: Error, @unchecked Sendable {
        let signingMaterials: SigningMaterialUnavailable?
        let recoveryError: Error?
        let observationError: Error?
        let completedRecovery: Coordinator.Recovery?
    }
    private struct Connection {
        let vault: Vault?
        let namespace: Vault.Namespace?
        let coordinator: Coordinator
        let access: Access
        let materialFailure: SigningMaterialUnavailable?
        let profileValidity: ConnectedProfileValidity?
    }
    /// Two bounds derived only from the signed profiles of the actual verified
    /// connect input. This is not another file/material cache or a remote
    /// revocation check; repeated foregrounds need no whole-Bundle read.
    private struct ConnectedProfileValidity {
        let notBefore: Date
        let expiresAt: Date
        init(_ material: SelfRenewalApplicationMaterialVerifier.Materials) throws {
            let summaries = material.profiles.profiles.map(\.summary)
            guard !summaries.isEmpty, summaries.count <= Vault.Limits.bundles,
                  let notBefore = summaries.map(\.createdAt).max(), let expiresAt = summaries.map(\.expiresAt).min(),
                  notBefore.timeIntervalSince1970.isFinite, expiresAt.timeIntervalSince1970.isFinite,
                  notBefore < expiresAt else { throw SelfRenewalProvisioningProfileVerifier.Failure.invalidValidityWindow }
            self.notBefore = notBefore; self.expiresAt = expiresAt
        }
        func validate(at date: Date) throws {
            guard date.timeIntervalSince1970.isFinite else { throw Vault.Failure.clockMovedBackwards }
            guard date >= notBefore else { throw SelfRenewalProvisioningProfileVerifier.Failure.profileNotYetValid }
            guard date < expiresAt else { throw SelfRenewalProvisioningProfileVerifier.Failure.profileExpired }
        }
    }
    struct DeviceConfiguration: Sendable, Codable, Equatable {
        let identityPersistentReference: Data
        let deviceCertificateDER: Data
        let rootCertificateDER: Data
        let hostID: String
        let systemBUID: String
        let numericAddress: String
        let port: UInt16
        let interfaceIndex: UInt32
    }
    struct Configuration: Sendable, Codable, Equatable {
        let schema: Int
        let namespaceID: UUID
        let codeAnchors: [Data]
        let profileAnchors: [Data]
        let device: DeviceConfiguration?
    }
    /// First-use public input omits namespaceID. An explicit ID only resumes
    /// an existing manifest or the same already-persisted initial intent.
    struct EnrollmentConfiguration: Sendable, Codable, Equatable {
        let schema: Int
        let namespaceID: UUID?
        let codeAnchors: [Data]
        let profileAnchors: [Data]
        let device: DeviceConfiguration?
    }
    private struct InitialNamespaceBinding: Codable, Equatable {
        let schema: Int
        let configuration: Configuration
        let identitySHA256: Data
        let allowsCreate: Bool
    }
    /// This capability is not Codable and has no public memberwise initializer.
    /// Only this file mints it after the Document's durable intent is confirmed.
    struct InitialNamespaceCreationAuthorization: Sendable {
        let namespaceID: UUID
        let identitySHA256: Data
        fileprivate init(namespaceID: UUID, identitySHA256: Data) {
            self.namespaceID = namespaceID; self.identitySHA256 = identitySHA256
        }
    }
    private struct Document: Codable {
        let schema: Int
        let configuration: Configuration?
        let initialNamespaceBinding: InitialNamespaceBinding?
        let automaticRenewal: AutomaticRenewalPolicy?
        // Optional schema-1 addition. It contains only an explicit endpoint;
        // the ID and registration blob belong to the existing Keychain owner.
        let anisetteProvider: SelfRenewalAnisetteV3Configuration?
        let status: Status
    }
    private let requestedRoot: URL?
    private let ownedApplicationRoot: URL?
    private let clock: @Sendable () -> Date
    private let developerServices: DeveloperServices?
    private var liveDeveloperServices: DeveloperServices?
    private var liveAnisetteProvider: SelfRenewalAnisetteV3Provider?
    private var localDeveloperStorage: (any SelfRenewalDeveloperSessionStorage)?
    private var anisetteConfiguration: SelfRenewalAnisetteV3Configuration?
    private var persistedAnisetteConfiguration: SelfRenewalAnisetteV3Configuration?
    private var root: URL?
    private var journal: Journal?
    private var vault: Vault?
    private var namespace: Vault.Namespace?
    private var developerAccount: SelfRenewalDeveloperAccountClient?
    private var developerEnrollmentIdentity: Vault.EnrollmentIdentity?
    private var developerAuthentication: SelfRenewalDeveloperAuthentication?
    private struct DeveloperAuthenticationOperation {
        let id: UUID
        let task: Task<SelfRenewalDeveloperAuthentication.Outcome, Error>
    }
    private var developerAuthenticationOperation: DeveloperAuthenticationOperation?
    private var developerAuthenticationEpoch = UUID()
    private var developerAuthenticationResult: SelfRenewalDeveloperAuthentication.Outcome?
    private var developerMaterial: DeveloperMaterialObservation?
    private var developerLocallySignedOut = false
    private var coordinator: Coordinator?
    private var access: Access?
    private var materialFailure: SigningMaterialUnavailable?
    private var profileValidity: ConnectedProfileValidity?
    private var configuration: Configuration?
    private var lastStatus: Status?
    private var persistedConfiguration: Configuration?
    private var initialNamespaceBinding: InitialNamespaceBinding?
    private var persistedInitialNamespaceBinding: InitialNamespaceBinding?
    private var configurationNeedsReload = false
    private var automaticPolicy: AutomaticRenewalPolicy?
    private var persistedAutomaticPolicy: AutomaticRenewalPolicy?
    private var busy = false
    #if DEBUG
    private var developerAuthenticationRandom: @Sendable () throws -> Data = SelfRenewalGSASRP.randomExponent
    enum PublicationFault: Sendable {
        case loseNextDirectorySyncAcknowledgement
        case loseNextAuthenticatedRecoveryDirectorySyncAcknowledgement
        case failInitialConfigurationBeforeWrite
    }
    private var publicationFault: PublicationFault?
    private var initialNamespaceStorage: any SelfRenewalSigningManifestStorage = SelfRenewalSigningKeychainManifestStorage()
    init(root: URL, publicationFault: PublicationFault, developerServices: DeveloperServices? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }) {
        requestedRoot = root; ownedApplicationRoot = nil; self.clock = clock; self.publicationFault = publicationFault
        self.developerServices = developerServices
    }
    /// An owned test root still goes through the real complete verifier and
    /// Vault. It can never produce a current-process file observation.
    init(root: URL, currentApplicationRoot: URL, developerServices: DeveloperServices? = nil,
        publicationFault: PublicationFault? = nil,
        initialNamespaceStorage: any SelfRenewalSigningManifestStorage = SelfRenewalSigningKeychainManifestStorage(),
        developerAuthenticationRandom: @escaping @Sendable () throws -> Data = SelfRenewalGSASRP.randomExponent,
        clock: @escaping @Sendable () -> Date = { Date() }) {
        requestedRoot = root; ownedApplicationRoot = currentApplicationRoot; self.clock = clock
        self.developerServices = developerServices
        self.developerAuthenticationRandom = developerAuthenticationRandom
        self.publicationFault = publicationFault; self.initialNamespaceStorage = initialNamespaceStorage
    }
    #endif
    static let maximumConfigurationBytes = 524_288

    /// No file, Bundle, Keychain or network work happens during App.init.
    init(root: URL? = nil, developerServices: DeveloperServices? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }) {
        requestedRoot = root; ownedApplicationRoot = nil; self.clock = clock
        self.developerServices = developerServices
    }

    func bootstrap(handoff: SelfRenewalUserDataHandoff) async throws -> Status {
        guard !busy else { throw Failure.busy }
        busy = true; defer { busy = false }
        let started = SourcePerfTrace.now
        defer { trace("bootstrap", since: started) }
        try Task.checkCancellation()
        try await openLocalOwner()
        if let coordinator {
            if access == .recoveryOnly { return try await observeRecoveryOnly(coordinator, handoff: handoff) }
            do { try await recoverLocalPreparation() }
            catch is CancellationError { throw CancellationError() }
            catch { throw await unavailable(error, problem: .storage) }
            return try await observe(coordinator, handoff: handoff)
        }
        guard let configuration else {
            if let journal, let snapshot = try await journal.load(), Self.isRemoteRecoveryPhase(snapshot.record.phase) {
                let recovery = try await Coordinator.recoveryOnly(journal: journal, clock: clock)
                self.coordinator = recovery; access = .recoveryOnly
                materialFailure = SigningMaterialUnavailable(underlying: Failure.notConfigured, recoveryContextError: nil)
            }
            return try publish(state: .unconfigured, phase: try await journal?.load()?.record.phase,
                problem: access == .recoveryOnly ? .signingMaterials : nil)
        }
        let candidate: Connection
        do { candidate = try await resolve(configuration) }
        catch is CancellationError { throw CancellationError() }
        catch { throw await unavailable(error, problem: Self.isLocalStorageFailure(error) ? .storage : .signingMaterials) }
        activate(candidate)
        if candidate.access == .recoveryOnly { return try await observeRecoveryOnly(candidate.coordinator, handoff: handoff) }
        do { try await recoverLocalPreparation() }
        catch is CancellationError { throw CancellationError() }
        catch { throw await unavailable(error, problem: .storage) }
        return try await observe(candidate.coordinator, handoff: handoff)
    }

    /// Explicit first-use registration through the same strong Bundle verifier
    /// and sole Vault. An unreadable/missing configured manifest never selects
    /// this path, and no existing transaction or configuration is overwritten.
    func initializeSigningNamespace(from input: URL) async throws -> Status {
        guard !busy else { throw Failure.busy }; busy = true; defer { busy = false }
        let started = SourcePerfTrace.now
        defer { trace("initialize-signing-namespace", since: started) }
        try await openLocalOwner()
        guard configuration == nil, let journal, try await journal.load() == nil else { throw Failure.configurationInUse }
        let scope = input.startAccessingSecurityScopedResource()
        defer { if scope { input.stopAccessingSecurityScopedResource() } }
        let raw = try Self.readBounded(input, maximum: Self.maximumConfigurationBytes)
        let request: EnrollmentConfiguration
        do { request = try JSONDecoder().decode(EnrollmentConfiguration.self, from: raw) }
        catch { throw Failure.invalidConfiguration }
        // Validate the original public trust/pairing schema and complete actual
        // Bundle before persisting an intent or touching its exact manifest.
        let validation = Configuration(schema: request.schema,
            namespaceID: request.namespaceID ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
            codeAnchors: request.codeAnchors, profileAnchors: request.profileAnchors, device: request.device)
        try Self.validate(validation)
        if let device = request.device { _ = try Self.pairing(device) }
        if let pending = initialNamespaceBinding {
            guard request.namespaceID == nil || request.namespaceID == pending.configuration.namespaceID,
                  request.schema == pending.configuration.schema,
                  request.codeAnchors == pending.configuration.codeAnchors,
                  request.profileAnchors == pending.configuration.profileAnchors,
                  request.device == pending.configuration.device else { throw Failure.configurationInUse }
        }
        let material = try await SelfRenewalApplicationMaterialVerifier.read(
            unpackedApplication: ownedApplicationRoot ?? Bundle.main.bundleURL,
            codeAnchors: request.codeAnchors, profileAnchors: request.profileAnchors, at: clock())
        let identitySHA256 = try Vault.initialEnrollmentIdentityDigest(material)
        try Task.checkCancellation()
        let requestedID = request.namespaceID ?? initialNamespaceBinding?.configuration.namespaceID ?? UUID()
        let proposed = Configuration(schema: request.schema, namespaceID: requestedID,
            codeAnchors: request.codeAnchors, profileAnchors: request.profileAnchors, device: request.device)
        #if DEBUG
        let ownedVault = Vault(codeAnchors: request.codeAnchors, profileAnchors: request.profileAnchors,
            storage: initialNamespaceStorage, clock: clock)
        #else
        let ownedVault = Vault(codeAnchors: request.codeAnchors, profileAnchors: request.profileAnchors, clock: clock)
        #endif
        let pending: InitialNamespaceBinding
        if let existing = initialNamespaceBinding {
            guard existing.identitySHA256 == identitySHA256 else { throw Failure.configurationInUse }
            // A prior process may have lost the rename's directory-sync ACK.
            // Confirm this exact on-disk intent is durable before minting the
            // creation capability, even on the first open after a restart.
            do {
                guard let root else { throw Failure.storage }
                try Self.synchronizeConfigurationRoot(root)
            } catch {
                configurationNeedsReload = true
                throw InitialNamespaceBindingFailure(namespaceID: requestedID, underlying: error)
            }
            pending = existing
        } else {
            // Explicit foreign IDs keep their prior resume-only semantics. A
            // missing/locked/malformed manifest must not establish a new intent.
            if let requested = request.namespaceID {
                let resumed = try await ownedVault.resume(namespaceID: requested, identity: material)
                let generation = try await ownedVault.generation(in: resumed)
                guard try await ownedVault.publicationBaseline(in: resumed, expectedGeneration: generation) == nil else {
                    throw Failure.configurationInUse
                }
            }
            pending = InitialNamespaceBinding(schema: 1, configuration: proposed,
                identitySHA256: identitySHA256, allowsCreate: request.namespaceID == nil)
            initialNamespaceBinding = pending
            do { _ = try publish(state: .unconfigured, phase: nil) }
            catch {
                // No manifest was touched; a lost rename/fsync acknowledgement
                // is re-read under the same journal lock before any retry.
                initialNamespaceBinding = nil; configurationNeedsReload = true
                throw InitialNamespaceBindingFailure(namespaceID: requestedID, underlying: error)
            }
        }
        do {
            let ownedNamespace: Vault.Namespace
            if pending.allowsCreate {
                let authorization = InitialNamespaceCreationAuthorization(namespaceID: requestedID, identitySHA256: identitySHA256)
                ownedNamespace = try await ownedVault.resumeOrCreateInitialEnrollment(authorization, identity: material)
            } else {
                ownedNamespace = try await ownedVault.resume(namespaceID: requestedID, identity: material)
                let generation = try await ownedVault.generation(in: ownedNamespace)
                guard try await ownedVault.publicationBaseline(in: ownedNamespace, expectedGeneration: generation) == nil else {
                    throw Failure.configurationInUse
                }
            }
            configuration = pending.configuration
            vault = ownedVault; namespace = ownedNamespace
            coordinator = nil; access = nil; profileValidity = nil; materialFailure = nil
            liveDeveloperServices = nil; liveAnisetteProvider = nil; developerAccount = nil; developerEnrollmentIdentity = nil; developerAuthentication = nil; developerMaterial = nil
            developerAuthenticationEpoch = UUID(); developerAuthenticationResult = nil
            initialNamespaceBinding = nil
            // Only this durable final Document clears the initial intent. The
            // namespace itself still grants no signing lease before enrollment.
            return try publish(state: .unavailable, phase: nil, problem: .signingMaterials)
        } catch {
            configuration = nil; vault = nil; namespace = nil
            initialNamespaceBinding = pending; configurationNeedsReload = true
            throw InitialNamespaceBindingFailure(namespaceID: requestedID, underlying: error)
        }
    }

    /// Only an explicit Settings action imports public configuration. A live
    /// transaction cannot be rebound to another namespace, trust set or peer.
    func configure(from input: URL, handoff: SelfRenewalUserDataHandoff) async throws -> Status {
        guard !busy else { throw Failure.busy }
        busy = true; defer { busy = false }
        let started = SourcePerfTrace.now
        defer { trace("configure", since: started) }
        try Task.checkCancellation()
        try await openLocalOwner()
        let scope = input.startAccessingSecurityScopedResource()
        defer { if scope { input.stopAccessingSecurityScopedResource() } }
        let raw = try Self.readBounded(input, maximum: Self.maximumConfigurationBytes)
        let proposed = try Self.decodeConfiguration(raw)
        return try await configure(proposed, handoff: handoff)
    }

    /// Explicit file import uses this same namespace, busy guard and journal
    /// flock. Import success establishes a usable Keychain identity only; the
    /// numeric endpoint still needs the existing real Lockdown/mTLS checks.
    func importPairingIdentity(pkcs12: URL, password: String, publicConfiguration: URL,
        handoff: SelfRenewalUserDataHandoff) async throws -> Status {
        guard !busy else { throw Failure.busy }
        busy = true; defer { busy = false }
        try Task.checkCancellation()
        try await openLocalOwner()
        guard initialNamespaceBinding == nil else { throw Failure.configurationInUse }
        guard let configuration, let journal else { throw Failure.notConfigured }
        if let snapshot = try await journal.load() {
            // Even an equal peer cannot replace identities through an active
            // or remotely uncertain transaction. Retired metadata must prove
            // the actual candidate is absent before it permits configuration.
            guard snapshot.record.phase == .retired else { throw Failure.configurationInUse }
            _ = try await journal.resumeRetirement(snapshot, at: clock())
        }
        let device = try SelfRenewalPairingIdentityImport.importIdentity(pkcs12: pkcs12, password: password,
            publicConfiguration: publicConfiguration, at: clock())
        let proposed = Configuration(schema: configuration.schema, namespaceID: configuration.namespaceID,
            codeAnchors: configuration.codeAnchors, profileAnchors: configuration.profileAnchors, device: device)
        try Self.validate(proposed)
        return try await configure(proposed, handoff: handoff)
    }

    /// The two explicit configuration entry points share one actual resolver,
    /// epoch invalidation and atomic Document publication while busy is held.
    private func configure(_ proposed: Configuration, handoff: SelfRenewalUserDataHandoff) async throws -> Status {
        guard initialNamespaceBinding == nil else { throw Failure.configurationInUse }
        let existing = try await journal?.load()
        if existing != nil, let configuration {
            // Authentication may be supplied later, but the live transaction's
            // namespace and trust sets cannot be silently changed underneath it.
            guard configuration.schema == proposed.schema, configuration.namespaceID == proposed.namespaceID,
                  configuration.codeAnchors == proposed.codeAnchors,
                  configuration.profileAnchors == proposed.profileAnchors else { throw Failure.configurationInUse }
        }
        if let device = proposed.device { _ = try Self.pairing(device) }
        // Signing access still requires real Bundle/vault proofs. Recovery-only
        // access instead requires the existing record + actual paired handle;
        // it is persisted and displayed explicitly without signing power.
        let candidate = try await resolve(proposed)
        if candidate.access == .recoveryOnly, proposed.device == nil { throw Failure.authenticationNotConfigured }
        try await developerAuthentication?.clearPendingAuthentication()
        try Task.checkCancellation()
        let priorConfiguration = configuration
        configuration = proposed
        activate(candidate)
        do {
            _ = try publish(state: candidate.access == .signing ? .ready : .recoveryRequired,
                phase: existing?.record.phase, problem: candidate.access == .recoveryOnly ? .signingMaterials : nil)
        }
        catch {
            configuration = priorConfiguration
            // A rename followed by a failed directory sync may have changed
            // disk. Never keep using an older in-memory authorization binding.
            coordinator = nil; vault = nil; namespace = nil; liveDeveloperServices = nil; liveAnisetteProvider = nil; developerAccount = nil; developerEnrollmentIdentity = nil; developerAuthentication = nil; developerMaterial = nil
            developerAuthenticationEpoch = UUID(); developerAuthenticationResult = nil
            access = nil; profileValidity = nil; configurationNeedsReload = true
            throw error
        }
        if candidate.access == .recoveryOnly { return try await observeRecoveryOnly(candidate.coordinator, handoff: handoff) }
        do { try await recoverLocalPreparation() }
        catch is CancellationError { throw CancellationError() }
        catch { throw await unavailable(error, problem: .storage) }
        return try await observe(candidate.coordinator, handoff: handoff)
    }

    enum AutomaticRenewalOutcome: String, Codable, Sendable {
        case disabled, waiting, configurationRequired, accountRequired, recoveryRequired
        case interrupted, receiptObserved, failed, clockChanged
    }
    struct AutomaticRenewalObservation: Sendable, Equatable {
        let isEnabled: Bool
        let nextEligibleAt: Date?
        let lastAttemptAt: Date?
        let outcome: AutomaticRenewalOutcome
        var automaticRenewalVerified: Bool { false }
    }
    private struct AutomaticRenewalPolicy: Codable, Equatable, Sendable {
        var enabled: Bool
        var lastAttemptAt: Date?
        var nextEligibleAt: Date?
        var lastClockAt: Date?
        var failureCount: Int
        var attemptID: UUID?
        var outcome: AutomaticRenewalOutcome
        func validate() throws {
            guard (0...16).contains(failureCount),
                  [lastAttemptAt, nextEligibleAt, lastClockAt].compactMap({ $0 }).allSatisfy({
                      $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince1970 >= 315_532_800
                  }), enabled || attemptID == nil else { throw Failure.invalidConfiguration }
        }
        var observation: AutomaticRenewalObservation {
            .init(isEnabled: enabled, nextEligibleAt: nextEligibleAt, lastAttemptAt: lastAttemptAt,
                outcome: enabled ? (attemptID == nil ? outcome : .interrupted) : .disabled)
        }
    }
    private enum AutomaticRenewalFailure: Error { case materialsDoNotExtendCurrentApplication }
    private static let automaticRenewalLead: TimeInterval = 48 * 3_600
    private static let automaticRetryMinimum: TimeInterval = 3_600

    func automaticRenewalObservation() -> AutomaticRenewalObservation {
        automaticPolicy?.observation ?? .init(isEnabled: false, nextEligibleAt: nil, lastAttemptAt: nil, outcome: .disabled)
    }

    /// Opt-in is stored in the existing flock-owned configuration document.
    /// Neither enabling nor disabling creates credentials or network traffic.
    func setAutomaticRenewalEnabled(_ enabled: Bool) async throws -> AutomaticRenewalObservation {
        guard !busy else { throw Failure.busy }; busy = true; defer { busy = false }
        try await openLocalOwner()
        guard configuration != nil || !enabled else { throw Failure.notConfigured }
        var policy = automaticPolicy ?? AutomaticRenewalPolicy(enabled: false, failureCount: 0, outcome: .disabled)
        guard policy.enabled != enabled else { return policy.observation }
        policy.enabled = enabled; policy.attemptID = nil
        policy.nextEligibleAt = enabled ? clock() : nil
        policy.outcome = enabled ? .waiting : .disabled
        try persistAutomaticPolicy(policy)
        return policy.observation
    }

    /// A whole automatic attempt owns the same Session busy guard. Its private
    /// stages are exactly the explicit prepare/submit/material/recovery paths;
    /// no second signer, installer, journal, Vault or data owner is introduced.
    func runAutomaticRenewal(handoff: SelfRenewalUserDataHandoff) async throws -> AutomaticRenewalObservation {
        guard !busy else { throw Failure.busy }; busy = true; defer { busy = false }
        let started = SourcePerfTrace.now
        defer { trace("automatic-renewal", since: started) }
        try Task.checkCancellation(); try await openLocalOwner()
        guard var policy = automaticPolicy, policy.enabled else { return automaticRenewalObservation() }
        let now = clock()
        guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= 315_532_800 else { throw Vault.Failure.clockMovedBackwards }
        if let last = policy.lastClockAt, now < last {
            policy.lastClockAt = now; policy.nextEligibleAt = now.addingTimeInterval(Self.automaticRetryMinimum)
            policy.outcome = .clockChanged; policy.attemptID = nil
            try persistAutomaticPolicy(policy); return policy.observation
        }
        if let next = policy.nextEligibleAt, now < next { return policy.observation }
        guard let configuration, configuration.device != nil, let journal else {
            policy.outcome = .configurationRequired; policy.nextEligibleAt = now.addingTimeInterval(Self.automaticRetryMinimum)
            policy.lastClockAt = now; policy.attemptID = nil
            try persistAutomaticPolicy(policy); return policy.observation
        }
        do {
            let snapshot = try await journal.load()
            if let phase = snapshot?.record.phase, Self.isRemoteRecoveryPhase(phase) {
                // Intent is durable BEFORE any authenticated Lookup/cleanup.
                try beginAutomaticAttempt(&policy, at: now)
                if coordinator == nil { activate(try await resolve(configuration)) }
                _ = try await recoverExplicitlyOwned(handoff: handoff)
                return try await finishAutomaticAttempt(policy, outcome: .recoveryRequired)
            }
            if snapshot?.record.phase == .attentionRequired { throw Journal.Failure.activeTransaction }
            if snapshot?.record.phase == .candidateReady {
                // A prior automatic preparation may have completed before
                // cancellation/termination. Revalidate and submit those exact
                // durable bytes, without changing their material generation,
                // refreshing the account, or replacing the candidate.
                try beginAutomaticAttempt(&policy, at: now)
                if coordinator == nil { activate(try await resolve(configuration)) }
                _ = try await renewalSigningContext()
                _ = try await submitPreparedRenewalOwned(handoff: handoff)
                return try await finishAutomaticAttempt(policy, outcome: .receiptObserved)
            }
            let actual = try await SelfRenewalApplicationMaterialVerifier.read(
                unpackedApplication: ownedApplicationRoot ?? Bundle.main.bundleURL,
                codeAnchors: configuration.codeAnchors, profileAnchors: configuration.profileAnchors, at: now)
            let validity = try ConnectedProfileValidity(actual)
            let due = validity.expiresAt.addingTimeInterval(-Self.automaticRenewalLead)
            if now < due {
                policy.outcome = .waiting; policy.nextEligibleAt = due; policy.lastClockAt = now; policy.attemptID = nil
                try persistAutomaticPolicy(policy); return policy.observation
            }
            try beginAutomaticAttempt(&policy, at: now)
            let liveVault = vault ?? Vault(codeAnchors: configuration.codeAnchors, profileAnchors: configuration.profileAnchors, clock: clock)
            let liveNamespace: Vault.Namespace
            if let namespace { liveNamespace = namespace }
            else { liveNamespace = try await liveVault.resume(namespaceID: configuration.namespaceID, identity: actual) }
            vault = liveVault; namespace = liveNamespace
            // A still-valid already-refreshed lease avoids unnecessary Apple
            // requests. Missing/expired publication may be enrolled through the
            // same account owner, but cryptographic/key/storage failures remain.
            var lease: Vault.Lease?
            do { lease = try await liveVault.lease(in: liveNamespace) }
            catch Vault.Failure.namespaceUnavailable { lease = nil }
            catch SelfRenewalProvisioningProfileVerifier.Failure.profileExpired { lease = nil }
            let existingExpiry = lease?.profiles.map(\.summary.expiresAt).min()
            let needsRefresh = existingExpiry.map { $0 <= validity.expiresAt } ?? true
            if needsRefresh {
                guard developerServicesAreConfigured(), !developerLocallySignedOut else {
                    return try await finishAutomaticAttempt(policy, outcome: .accountRequired)
                }
                let account = try await developerAccountOwner()
                // A pending CSR always takes read-only reconciliation; never
                // send another CSR after an unknown account result.
                if try await account.pendingEnrollment() != nil { _ = try await reconcileDeveloperMaterialsOwned() }
                else { _ = try await refreshDeveloperMaterialsOwned(machineName: "Yuedu") }
                lease = try await liveVault.lease(in: liveNamespace)
            }
            guard let lease, let renewedExpiry = lease.profiles.map(\.summary.expiresAt).min(),
                  renewedExpiry > validity.expiresAt else { throw AutomaticRenewalFailure.materialsDoNotExtendCurrentApplication }
            try await liveVault.validate(lease, for: actual)
            // Reconnect the same actual namespace after a material generation
            // change before private prepare/submit obtain their fresh proofs.
            activate(try await resolve(configuration))
            let application = ownedApplicationRoot ?? Bundle.main.bundleURL
            _ = try await SelfRenewalIPAUnpacker.withCurrentApplicationArchive(application: application,
                codeAnchors: configuration.codeAnchors, profileAnchors: configuration.profileAnchors, at: now) { [self] ipa in
                try await prepareRenewalOwned(from: ipa)
            }
            _ = try await submitPreparedRenewalOwned(handoff: handoff)
            return try await finishAutomaticAttempt(policy, outcome: .receiptObserved)
        } catch {
            // Every actual worker has returned/drained before policy is saved.
            // A killed process keeps attemptID + the same durable journal; it
            // can only recover an existing upload/Upgrade on its next trigger.
            let original = error
            let outcome: AutomaticRenewalOutcome
            if Self.renewalWasCancelled(original) { outcome = .interrupted }
            else if original is SelfRenewalDeveloperAccountClient.Failure || original is SelfRenewalDeveloperAccountClient.EnrollmentFailure || original is DeveloperServicesFailure {
                outcome = .accountRequired
            } else { outcome = .failed }
            do { _ = try await finishAutomaticAttempt(policy, outcome: outcome) }
            catch { throw RenewalExecutionFailure(underlying: original, problem: .storage,
                preparedCandidate: nil, completedSubmission: nil, statusPersistenceError: error) }
            throw original
        }
    }

    private func beginAutomaticAttempt(_ policy: inout AutomaticRenewalPolicy, at now: Date) throws {
        policy.attemptID = UUID(); policy.lastAttemptAt = now; policy.lastClockAt = now
        policy.nextEligibleAt = now.addingTimeInterval(Self.automaticRetryMinimum); policy.outcome = .interrupted
        try persistAutomaticPolicy(policy)
    }
    private func finishAutomaticAttempt(_ initial: AutomaticRenewalPolicy, outcome: AutomaticRenewalOutcome) async throws -> AutomaticRenewalObservation {
        // An uncancelled, actor-owned terminal write follows the same rule as
        // finishRenewalExecution and is awaited before releasing busy.
        let terminal = Task { [self] in
            // A lost configuration ACK must first reload the same locked
            // Document, including its precise opt-in and attempt identity.
            try await openLocalOwner()
            guard let current = automaticPolicy, current.enabled,
                  current.attemptID == initial.attemptID else { return automaticRenewalObservation() }
            var policy = initial
            policy.attemptID = nil; policy.outcome = outcome
            if outcome == .receiptObserved { policy.failureCount = 0 }
            else { policy.failureCount = min(16, policy.failureCount + 1) }
            let interval = min(86_400, Self.automaticRetryMinimum * pow(2, Double(min(5, policy.failureCount))))
            policy.nextEligibleAt = clock().addingTimeInterval(interval)
            try persistAutomaticPolicy(policy)
            return policy.observation
        }
        return try await terminal.value
    }
    private func persistAutomaticPolicy(_ policy: AutomaticRenewalPolicy) throws {
        guard !configurationNeedsReload else { throw Failure.commitDurabilityUnknown }
        try policy.validate()
        let previous = automaticPolicy; automaticPolicy = policy
        do {
            _ = try publish(state: lastStatus?.state ?? .unconfigured, phase: lastStatus?.phase,
                problem: lastStatus?.problem)
        } catch {
            automaticPolicy = previous; configurationNeedsReload = true
            throw error
        }
    }

    /// Keep exact operation/transport facts even when the final local status
    /// write fails. A receipt does not prove installation or renewed profiles.
    struct RenewalExecutionFailure: Error, @unchecked Sendable {
        let underlying: Error
        let problem: Problem
        let preparedCandidate: Journal.Snapshot?
        let completedSubmission: Coordinator.TransportCompletion?
        let statusPersistenceError: Error?
    }

    /// Explicit file import prepares one candidate only. The external scope
    /// stays live through both existing bounded snapshots and their digest
    /// comparison; neither an imported path nor a Bundle ZIP grants authority.
    func prepareRenewal(from ipa: URL) async throws -> Status {
        guard !busy else { throw Failure.busy }
        busy = true; defer { busy = false }
        return try await prepareRenewalOwned(from: ipa)
    }

    private func prepareRenewalOwned(from ipa: URL) async throws -> Status {
        let started = SourcePerfTrace.now
        var candidateBytes = 0
        defer { SourcePerfTrace.record("renewal.app.prepare",
            "bytes=\(candidateBytes) inputLimit=\(SelfRenewalIPAArchiveValidator.Limits.archiveBytes) main=\(Thread.isMainThread)",
            since: started, thresholdMs: 0) }
        guard let journal else { throw Failure.notConfigured }
        let prepared: Journal.Snapshot
        do {
            try Task.checkCancellation()
            if let phase = try await journal.load()?.record.phase,
               [.uploadIntent, .upgradeIntent, .installationUnknown, .receiptObserved, .lookupObserved, .attentionRequired].contains(phase) {
                throw Journal.Failure.activeTransaction
            }
            let context = try await renewalSigningContext()
            guard ipa.isFileURL, ipa.query == nil, ipa.fragment == nil else { throw SelfRenewalIPAUnpacker.Failure.invalidInput }
            let scoped = ipa.startAccessingSecurityScopedResource()
            defer { if scoped { ipa.stopAccessingSecurityScopedResource() } }
            prepared = try await context.coordinator.prepare(ipa: ipa, lease: context.lease,
                originalCodeAnchors: context.configuration.codeAnchors,
                originalProfileAnchors: context.configuration.profileAnchors)
            candidateBytes = prepared.record.candidate?.byteCount ?? 0
        } catch {
            return try await finishRenewalExecution(failure: error)
        }
        return try await finishRenewalExecution(prepared: prepared)
    }

    /// A distinct explicit action submits the already-persisted candidate.
    /// Unknown upload/Upgrade phases are recovery-only; the Coordinator's real
    /// before-Upgrade hook saves the same three injected App persistence owners.
    func submitPreparedRenewal(handoff: SelfRenewalUserDataHandoff) async throws -> Status {
        guard !busy else { throw Failure.busy }
        busy = true; defer { busy = false }
        return try await submitPreparedRenewalOwned(handoff: handoff)
    }

    private func submitPreparedRenewalOwned(handoff: SelfRenewalUserDataHandoff) async throws -> Status {
        let started = SourcePerfTrace.now
        var candidateBytes = 0
        defer { SourcePerfTrace.record("renewal.app.submit",
            "bytes=\(candidateBytes) main=\(Thread.isMainThread)", since: started, thresholdMs: 0) }
        guard let journal else { throw Failure.notConfigured }
        let completed: Coordinator.TransportCompletion
        do {
            try Task.checkCancellation()
            guard let ready = try await journal.load(), ready.record.phase == .candidateReady,
                  let candidate = ready.record.candidate else { throw Coordinator.Failure.candidateNotReady }
            candidateBytes = candidate.byteCount
            guard let device = configuration?.device else { throw Failure.authenticationNotConfigured }
            let pairing = try Self.pairing(device)
            let context = try await renewalSigningContext()
            let endpoint = Transport.Endpoint(numericAddress: device.numericAddress,
                port: device.port, interfaceIndex: device.interfaceIndex)
            completed = try await context.coordinator.submitWithAppDataHandoff(pairing: pairing,
                endpoint: endpoint, handoff: handoff)
        } catch {
            return try await finishRenewalExecution(failure: error)
        }
        return try await finishRenewalExecution(submitted: completed)
    }

    private func renewalSigningContext() async throws -> (configuration: Configuration,
        coordinator: Coordinator, lease: Vault.Lease) {
        guard !configurationNeedsReload, access == .signing, let configuration,
              let coordinator, let vault, let namespace, let profileValidity else {
            throw Coordinator.Failure.signingMaterialsUnavailable
        }
        do {
            try Task.checkCancellation()
            try profileValidity.validate(at: clock())
            let actual = try await SelfRenewalApplicationMaterialVerifier.read(
                unpackedApplication: ownedApplicationRoot ?? Bundle.main.bundleURL,
                codeAnchors: configuration.codeAnchors, profileAnchors: configuration.profileAnchors, at: clock())
            let lease = try await vault.lease(in: namespace)
            try await vault.validate(lease, for: actual)
            return (configuration, coordinator, lease)
        } catch is CancellationError { throw CancellationError() }
        catch {
            let original = error
            // Same revoke-before-await barrier as observe(): a failed fresh
            // proof cannot leave cached signing access usable by a later call.
            self.vault = nil; self.namespace = nil; liveDeveloperServices = nil; liveAnisetteProvider = nil; developerAccount = nil; developerEnrollmentIdentity = nil
            developerAuthentication = nil; developerMaterial = nil
            developerAuthenticationEpoch = UUID(); developerAuthenticationResult = nil
            self.coordinator = nil; access = nil; self.profileValidity = nil
            let unavailable = SigningMaterialUnavailable(underlying: original, recoveryContextError: nil)
            materialFailure = unavailable
            guard Self.isSigningMaterialUnavailable(original) else { throw unavailable }
            do {
                let recovery = try await recoveryConnection(configuration, materialError: original)
                activate(recovery)
            } catch {
                // Preserve the already-observed proof failure if recovery I/O
                // is cancelled/fails. No candidate is retired or resubmitted.
                let combined = (error as? SigningMaterialUnavailable)
                    ?? SigningMaterialUnavailable(underlying: original, recoveryContextError: error)
                materialFailure = combined
                throw combined
            }
            throw unavailable
        }
    }

    /// The awaited Coordinator call has already drained its archive/transport
    /// workers. Keep busy until a fresh, uncancelled bounded journal read/status
    /// write also finishes, so cancellation cannot leave a false ready state.
    private func finishRenewalExecution(prepared: Journal.Snapshot? = nil,
        submitted: Coordinator.TransportCompletion? = nil, failure: Error? = nil) async throws -> Status {
        let observation = Task { [self] in
            try await openLocalOwner()
            let phase = try await journal?.load()?.record.phase
            let problem: Problem?
            if let failure {
                let actual = Self.renewalExecutionProblem(failure)
                if actual == .cancelled || actual == .storage { problem = actual }
                else if access != .signing, let materialFailure { problem = Self.renewalExecutionProblem(materialFailure) }
                else { problem = actual }
            } else if access != .signing, let materialFailure {
                problem = Self.renewalExecutionProblem(materialFailure)
            } else { problem = nil }
            let state: State
            if problem == .storage || (configuration != nil && access == nil) { state = .unavailable }
            else if access == .recoveryOnly { state = .recoveryRequired }
            else {
                switch phase {
                case nil: state = configuration == nil ? .unconfigured : .ready
                case .candidateReady: state = .candidateReady
                case .retired: state = .retiredUnsubmitted
                case .created, .signing, .retirementPending, .attentionRequired: state = .attentionRequired
                case .uploadIntent, .upgradeIntent, .installationUnknown, .receiptObserved, .lookupObserved: state = .recoveryRequired
                }
            }
            return try publish(state: state, phase: phase, problem: problem)
        }
        let terminal = await observation.result
        switch terminal {
        case .success(let status):
            if let failure {
                throw RenewalExecutionFailure(underlying: failure, problem: status.problem ?? .observation, preparedCandidate: prepared,
                    completedSubmission: submitted, statusPersistenceError: nil)
            }
            return status
        case .failure(let observationError):
            throw RenewalExecutionFailure(underlying: failure ?? observationError, problem: .storage, preparedCandidate: prepared,
                completedSubmission: submitted, statusPersistenceError: observationError)
        }
    }

    private static func renewalWasCancelled(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let failure = error as? RenewalExecutionFailure { return renewalWasCancelled(failure.underlying) }
        if let failure = error as? BookMetadataPersistenceFailure, failure.code == .cancelled { return true }
        if let failure = error as? Coordinator.PreparationFailure { return renewalWasCancelled(failure.underlying) }
        if let failure = error as? Coordinator.Interrupted { return renewalWasCancelled(failure.underlying) }
        if let failure = error as? SelfRenewalAuthenticatedInstallationClient.OperationFailure { return renewalWasCancelled(failure.underlying) }
        return (error as? Transport.Failure) == .cancelled
    }

    private static func renewalExecutionProblem(_ error: Error) -> Problem {
        if renewalWasCancelled(error) { return .cancelled }
        if let failure = error as? SigningMaterialUnavailable {
            if let context = failure.recoveryContextError, isLocalStorageFailure(context) { return .storage }
            return renewalExecutionProblem(failure.underlying)
        }
        if let failure = error as? Coordinator.PreparationFailure { return renewalExecutionProblem(failure.underlying) }
        if let failure = error as? Coordinator.Interrupted { return renewalExecutionProblem(failure.underlying) }
        if let failure = error as? SelfRenewalAuthenticatedInstallationClient.OperationFailure { return renewalExecutionProblem(failure.underlying) }
        if error is BookMetadataPersistenceFailure || error is BookSourcePersistenceFailure || error is ReadingPositionPersistenceFailure { return .storage }
        if isLocalStorageFailure(error) { return .storage }
        if isSigningMaterialUnavailable(error) { return .signingMaterials }
        if let failure = error as? Coordinator.Failure, failure == .signingMaterialsUnavailable { return .signingMaterials }
        if let failure = error as? Failure, failure == .authenticationNotConfigured { return .authentication }
        return .observation
    }

    /// Recover the existing journal through its unique authenticated installer.
    /// Account enrollment uses the separate fixed developer-services protocol.
    func recoverExplicitly(handoff: SelfRenewalUserDataHandoff) async throws -> Status {
        guard !busy else { throw Failure.busy }
        busy = true; defer { busy = false }
        return try await recoverExplicitlyOwned(handoff: handoff)
    }

    private func recoverExplicitlyOwned(handoff: SelfRenewalUserDataHandoff) async throws -> Status {
        let started = SourcePerfTrace.now
        defer { trace("recover-explicit", since: started) }
        guard let coordinator else { throw Failure.notConfigured }
        let completed: Coordinator.Recovery
        do {
            guard let device = configuration?.device else { throw Failure.authenticationNotConfigured }
            let pairing = try Self.pairing(device)
            let endpoint = Transport.Endpoint(numericAddress: device.numericAddress,
                port: device.port, interfaceIndex: device.interfaceIndex)
            completed = try await coordinator.recover(pairing: pairing, endpoint: endpoint, timeoutSeconds: 30)
        } catch {
            throw RecoveryFailed(signingMaterials: materialFailure, recoveryError: error, observationError: nil, completedRecovery: nil)
        }
        // A successful Lookup/Remove is reported as that observation, never as
        // installed code, Apple authority, or a completed automatic renewal.
        do {
            let status = access == .recoveryOnly
                ? try await observeRecoveryOnly(coordinator, handoff: handoff)
                : try await observe(coordinator, handoff: handoff)
            if status.state == .recoveryRequired {
                return try publish(state: .authenticatedRecoveryObserved, phase: status.phase,
                    problem: access == .recoveryOnly ? .signingMaterials : nil)
            }
            return status
        } catch {
            throw RecoveryFailed(signingMaterials: materialFailure, recoveryError: nil, observationError: error, completedRecovery: completed)
        }
    }

    func developerServicesAreConfigured() -> Bool { developerServices != nil || anisetteConfiguration != nil }
    func configuredAnisetteProvider() -> SelfRenewalAnisetteV3Configuration? { anisetteConfiguration }

    /// Public phase only; no identity/blob and no transport construction.
    func observeAnisetteRegistration() async throws -> SelfRenewalAnisetteV3Provider.RegistrationObservation? {
        guard !busy else { throw Failure.busy }; busy = true; defer { busy = false }
        try await openLocalOwner()
        guard let anisetteConfiguration, let configuration else { return nil }
        return try SelfRenewalAnisetteV3Provider.observeRegistration(configuration: anisetteConfiguration,
            namespaceID: configuration.namespaceID, storage: developerStorageOwner())
    }

    /// Explicit recovery only. This clears stored Apple credentials before
    /// changing an unknown registration; the user must sign in again. Signing
    /// materials and pending certificate/installation intents are retained.
    /// A failure after credential removal may still leave the account signed
    /// out, but never starts provisioning or erases a provisioned adi_pb.
    func resetUnknownAnisetteRegistration() async throws -> SelfRenewalAnisetteV3Provider.RegistrationObservation {
        _ = try await acquireAfterDrainingDeveloperAuthentication()
        defer { busy = false }
        try await developerAuthentication?.clearPendingAuthentication()
        try await openLocalOwner()
        guard !configurationNeedsReload else { throw Failure.commitDurabilityUnknown }
        guard let anisetteConfiguration, let configuration else { throw Failure.notConfigured }
        let storage = developerStorageOwner()
        let observed = try SelfRenewalAnisetteV3Provider.observeRegistration(configuration: anisetteConfiguration,
            namespaceID: configuration.namespaceID, storage: storage)
        guard observed?.phase == .provisioningOutcomeUnknown || observed?.phase == .resetOutcomeUnknown else {
            throw SelfRenewalAnisetteV3Provider.Failure.resetNotRequired
        }
        developerLocallySignedOut = true
        developerAuthenticationEpoch = UUID(); developerAuthenticationResult = nil
        // Drop all old account/authentication capabilities before changing the
        // registration identity. The same storage owner retains their record.
        let account = developerAccount
        developerAccount = nil; developerAuthentication = nil; developerMaterial = nil
        liveDeveloperServices = nil; liveAnisetteProvider = nil
        if let account { try await account.signOut() }
        try SelfRenewalDeveloperAccountClient.signOutStoredCredentials(namespaceID: configuration.namespaceID,
            storage: storage, requireReadback: true)
        // Accurate credential readback is a durable barrier: automatic paths
        // require a stored token before asking this provider for fresh data.
        return try SelfRenewalAnisetteV3Provider.resetUnknownRegistration(configuration: anisetteConfiguration,
            namespaceID: configuration.namespaceID, storage: storage)
    }

    /// Configuration is an explicit local action and performs no network work.
    /// A login is cancelled and drained through the existing epoch barrier
    /// before changing the provider. Stored Apple tokens/registration remain
    /// owned by their existing Keychain scope; endpoint changes cannot silently
    /// migrate a registration to a different server.
    func configureAnisetteProvider(_ value: SelfRenewalAnisetteV3Configuration?) async throws {
        _ = try await acquireAfterDrainingDeveloperAuthentication()
        defer { busy = false }
        try await developerAuthentication?.clearPendingAuthentication()
        try await openLocalOwner()
        guard !configurationNeedsReload else { throw Failure.commitDurabilityUnknown }
        if let value { try value.validate() }
        guard value != anisetteConfiguration else { return }
        let previous = anisetteConfiguration
        anisetteConfiguration = value
        do {
            _ = try publish(state: lastStatus?.state ?? .unconfigured,
                phase: lastStatus?.phase, problem: lastStatus?.problem)
        } catch {
            anisetteConfiguration = previous; configurationNeedsReload = true
            throw error
        }
        liveDeveloperServices = nil; liveAnisetteProvider = nil; developerAccount = nil; developerAuthentication = nil; developerMaterial = nil
        developerAuthenticationEpoch = UUID(); developerAuthenticationResult = nil
    }

    /// Dependencies are constructed only when an explicit account/renewal
    /// action needs them. GSA, account services and anisette share this exact
    /// transport and Keychain owner; startup/endpoint selection never connects.
    private func developerServicesOwner(namespaceID: UUID) throws -> DeveloperServices {
        if let developerServices { return developerServices }
        if let liveDeveloperServices { return liveDeveloperServices }
        guard let anisetteConfiguration else { throw DeveloperServicesFailure.unavailable }
        let transport = SelfRenewalDeveloperURLSessionTransport()
        let storage = developerStorageOwner()
        let provider = try SelfRenewalAnisetteV3Provider(configuration: anisetteConfiguration, namespaceID: namespaceID,
            transport: transport, storage: storage, clock: clock)
        let services = DeveloperServices(transport: transport, storage: storage,
            freshAnisette: { try await provider.freshAnisette() })
        liveAnisetteProvider = provider; liveDeveloperServices = services
        return services
    }

    private func developerStorageOwner() -> any SelfRenewalDeveloperSessionStorage {
        if let developerServices { return developerServices.storage }
        if let localDeveloperStorage { return localDeveloperStorage }
        let storage = SelfRenewalDeveloperKeychainSessionStorage()
        localDeveloperStorage = storage
        return storage
    }

    /// The actual login task belongs to this session, rather than the caller's
    /// view task. Caller cancellation is forwarded to that same task and every
    /// terminal path releases the operation before publishing its result.
    func signInDeveloperAccount(appleID: String, password: String) async throws
        -> SelfRenewalDeveloperAuthentication.Outcome {
        try await runDeveloperAuthentication { authentication in
            try await authentication.signIn(appleID: appleID, password: password)
        }
    }

    func submitDeveloperVerificationCode(_ code: String, challengeID: UUID) async throws
        -> SelfRenewalDeveloperAuthentication.Outcome {
        try await runDeveloperAuthentication { authentication in
            try await authentication.submitVerificationCode(code, challengeID: challengeID)
        }
    }

    func cancelDeveloperAuthentication() async throws -> DeveloperAuthenticationCancellation {
        let observed = try await acquireAfterDrainingDeveloperAuthentication()
        defer { busy = false }
        try await developerAuthentication?.clearPendingAuthentication()
        developerAuthenticationResult = nil
        developerAuthenticationEpoch = UUID()
        return observed
    }

    private func runDeveloperAuthentication(
        _ action: @escaping @Sendable (SelfRenewalDeveloperAuthentication) async throws -> SelfRenewalDeveloperAuthentication.Outcome
    ) async throws -> SelfRenewalDeveloperAuthentication.Outcome {
        guard !busy else { throw Failure.busy }
        busy = true
        let id = UUID()
        developerAuthenticationEpoch = id; developerAuthenticationResult = nil
        let task = Task { [self] in
            do {
                try Task.checkCancellation()
                let authentication = try await developerAuthenticationOwner()
                try Task.checkCancellation()
                let result = try await action(authentication)
                finishDeveloperAuthentication(id, result: result)
                return result
            } catch {
                finishDeveloperAuthentication(id, result: nil)
                throw error
            }
        }
        developerAuthenticationOperation = DeveloperAuthenticationOperation(id: id, task: task)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private func finishDeveloperAuthentication(_ id: UUID, result: SelfRenewalDeveloperAuthentication.Outcome?) {
        guard developerAuthenticationOperation?.id == id else { return }
        developerAuthenticationResult = result
        if case .connected? = result { developerLocallySignedOut = false }
        developerAuthenticationOperation = nil
        busy = false
    }

    /// Once an awaited login releases busy, another operation may enter this
    /// actor. Its epoch/busy barrier wins; an old cancellation cannot clear a
    /// newer challenge, connection or changed namespace binding.
    private func acquireAfterDrainingDeveloperAuthentication() async throws -> DeveloperAuthenticationCancellation {
        let completed: SelfRenewalDeveloperAuthentication.Outcome?
        if let operation = developerAuthenticationOperation {
            operation.task.cancel()
            let result = await operation.task.result
            guard !busy, developerAuthenticationEpoch == operation.id,
                  developerAuthenticationOperation == nil else { throw Failure.busy }
            switch result { case .success(let value): completed = value; case .failure: completed = nil }
        } else {
            guard !busy else { throw Failure.busy }
            completed = developerAuthenticationResult
        }
        busy = true
        if case .connected(let observed)? = completed {
            return DeveloperAuthenticationCancellation(confirmedSession: observed)
        }
        return DeveloperAuthenticationCancellation(confirmedSession: nil)
    }

    private func developerAuthenticationOwner() async throws -> SelfRenewalDeveloperAuthentication {
        let account = try await developerAccountOwner()
        if let developerAuthentication { return developerAuthentication }
        guard let configuration else { throw Failure.notConfigured }
        let developerServices = try developerServicesOwner(namespaceID: configuration.namespaceID)
        #if DEBUG
        let authentication = SelfRenewalDeveloperAuthentication(account: account, transport: developerServices.transport,
            freshAnisette: developerServices.freshAnisette, clock: clock, random: developerAuthenticationRandom)
        #else
        let authentication = SelfRenewalDeveloperAuthentication(account: account, transport: developerServices.transport,
            freshAnisette: developerServices.freshAnisette, clock: clock)
        #endif
        developerAuthentication = authentication
        return authentication
    }

    /// Transitional token input from the real GSA flow. The account client
    /// must still check the live remote session and original Personal Team.
    func connectDeveloperAccount(_ candidate: SelfRenewalDeveloperAccountClient.Credentials) async throws
        -> SelfRenewalDeveloperAccountClient.SessionObservation {
        guard !busy else { throw Failure.busy }; busy = true; defer { busy = false }
        let account = try await developerAccountOwner()
        let observed = try await account.connect(candidate)
        developerLocallySignedOut = false
        return observed
    }

    func observeDeveloperAccount() async throws -> SelfRenewalDeveloperAccountClient.SessionObservation {
        guard !busy else { throw Failure.busy }; busy = true; defer { busy = false }
        guard !developerLocallySignedOut else { throw SelfRenewalDeveloperAccountClient.Failure.signedOut }
        return try await developerAccountOwner().observeSession()
    }

    /// A published key is reused for renewal. First enrollment prepares one
    /// permanent Vault key and reuses it after a pre-CSR failure or App restart.
    /// Prior candidates retire through the existing transaction owner first;
    /// a possible upload/submission blocks every remote enrollment mutation.
    func refreshDeveloperMaterials(machineName: String) async throws -> DeveloperMaterialObservation {
        guard !busy else { throw Failure.busy }; busy = true; defer { busy = false }
        return try await refreshDeveloperMaterialsOwned(machineName: machineName)
    }

    private func refreshDeveloperMaterialsOwned(machineName: String) async throws -> DeveloperMaterialObservation {
        let started = SourcePerfTrace.now
        defer { trace("developer-material-refresh", since: started) }
        guard !developerLocallySignedOut else { throw SelfRenewalDeveloperAccountClient.Failure.signedOut }
        let account = try await developerAccountOwner()
        guard try await account.pendingEnrollment() == nil else {
            throw SelfRenewalDeveloperAccountClient.Failure.reconciliationRequired
        }
        guard let journal, let vault, let namespace, let developerEnrollmentIdentity else { throw Failure.notConfigured }
        try await Coordinator.retireBeforeEnrollmentRefresh(journal: journal, identity: developerEnrollmentIdentity, at: clock())
        let generation = try await vault.generation(in: namespace)
        let keyID: UUID
        let materialGeneration: UInt64
        if let publication = try await vault.publicationBaseline(in: namespace, expectedGeneration: generation) {
            keyID = publication.keyID; materialGeneration = publication.generation
        } else {
            // A pre-CSR failure or restart reuses the exact permanent owned
            // key. An unresolved remote intent was refused before this point.
            let key = try await vault.initialEnrollmentKey(in: namespace, expectedGeneration: generation)
            keyID = key.id; materialGeneration = key.generation
        }
        do {
            let published = try await account.refreshMaterials(keyID: keyID,
                expectedGeneration: materialGeneration, machineName: machineName)
            let observation = DeveloperMaterialObservation(published)
            developerMaterial = observation
            return observation
        } catch let failure as SelfRenewalDeveloperAccountClient.PublicationFinalizationFailure {
            let observation = DeveloperMaterialObservation(failure.publishedLease)
            developerMaterial = observation
            throw DeveloperMaterialFinalizationFailure(published: observation, underlying: failure.underlying)
        }
    }

    /// Explicit recovery of the existing CSR intent. A possible installation
    /// submission must first refuse the same generation-changing publication,
    /// even though the certificate-list request itself is read-only. This
    /// never issues another CSR or implicitly connects at App startup.
    func reconcileDeveloperMaterials() async throws -> DeveloperMaterialObservation {
        guard !busy else { throw Failure.busy }; busy = true; defer { busy = false }
        return try await reconcileDeveloperMaterialsOwned()
    }

    private func reconcileDeveloperMaterialsOwned() async throws -> DeveloperMaterialObservation {
        let started = SourcePerfTrace.now
        defer { trace("developer-material-reconcile", since: started) }
        guard !developerLocallySignedOut else { throw SelfRenewalDeveloperAccountClient.Failure.signedOut }
        let account = try await developerAccountOwner()
        guard try await account.pendingEnrollment() != nil else {
            throw SelfRenewalDeveloperAccountClient.Failure.reconciliationRequired
        }
        guard let journal, let developerEnrollmentIdentity else { throw Failure.notConfigured }
        try await Coordinator.retireBeforeEnrollmentRefresh(journal: journal, identity: developerEnrollmentIdentity, at: clock())
        do {
            let observed = DeveloperMaterialObservation(try await account.reconcilePendingMaterials())
            developerMaterial = observed; return observed
        } catch let failure as SelfRenewalDeveloperAccountClient.PublicationFinalizationFailure {
            let observed = DeveloperMaterialObservation(failure.publishedLease)
            developerMaterial = observed
            throw DeveloperMaterialFinalizationFailure(published: observed, underlying: failure.underlying)
        }
    }

    func finalizeDeveloperMaterialPublication() async throws -> DeveloperMaterialObservation {
        guard !busy else { throw Failure.busy }; busy = true; defer { busy = false }
        let account = try await developerAccountOwner()
        do {
            let observed = DeveloperMaterialObservation(try await account.finalizeObservedPublication())
            developerMaterial = observed; return observed
        } catch let failure as SelfRenewalDeveloperAccountClient.PublicationFinalizationFailure {
            let observed = DeveloperMaterialObservation(failure.publishedLease)
            developerMaterial = observed
            throw DeveloperMaterialFinalizationFailure(published: observed, underlying: failure.underlying)
        }
    }

    func signOutDeveloperAccount() async throws {
        _ = try await acquireAfterDrainingDeveloperAuthentication()
        defer { busy = false }
        developerLocallySignedOut = true
        try await developerAuthentication?.clearPendingAuthentication()
        developerAuthenticationResult = nil
        developerAuthenticationEpoch = UUID()
        if let developerAccount { try await developerAccount.signOut(); return }
        try await openLocalOwner()
        guard let configuration else { throw Failure.notConfigured }
        // Erase-only operation uses the existing account record owner. Expired
        // signing materials must not prevent removal of stored credentials.
        try SelfRenewalDeveloperAccountClient.signOutStoredCredentials(namespaceID: configuration.namespaceID,
            storage: developerStorageOwner())
    }

    func developerMaterialObservation() -> DeveloperMaterialObservation? { developerMaterial }

    private func developerAccountOwner() async throws -> SelfRenewalDeveloperAccountClient {
        try await openLocalOwner()
        guard let configuration else { throw Failure.notConfigured }
        let developerServices = try developerServicesOwner(namespaceID: configuration.namespaceID)
        try Task.checkCancellation()
        // This is a real bounded structural observation, not a current CMS or
        // profile verification result. Account scope comes exclusively from
        // the original Keychain manifest; expiry does not invent a new scope.
        let observed = try await SelfRenewalMachOSignatureReader.read(
            unpackedApplication: ownedApplicationRoot ?? Bundle.main.bundleURL)
        let vault = self.vault ?? Vault(codeAnchors: configuration.codeAnchors,
            profileAnchors: configuration.profileAnchors, clock: clock)
        let identity = try await vault.resumeForEnrollment(namespaceID: configuration.namespaceID, observed: observed)
        self.vault = vault; namespace = identity.namespace; developerEnrollmentIdentity = identity
        if let developerAccount { return developerAccount }
        let account = try await SelfRenewalDeveloperAccountClient.openForEnrollment(vault: vault, identity: identity,
            transport: developerServices.transport, storage: developerServices.storage,
            freshAnisette: developerServices.freshAnisette, clock: clock)
        try Task.checkCancellation()
        developerAccount = account
        return account
    }

    func status() -> Status? {
        guard let lastStatus else { return nil }
        // A failed status write may leave an older on-disk observation. Never
        // present its old signing access as a currently retained capability.
        guard lastStatus.access != access else { return lastStatus }
        let storage = configurationNeedsReload || materialFailure.map { Self.isLocalStorageFailure($0.underlying) } == true
        return Status(state: .unavailable, phase: lastStatus.phase, observedAt: lastStatus.observedAt,
            problem: storage ? .storage : .signingMaterials, access: access)
    }
    func signingMaterialFailure() -> SigningMaterialUnavailable? { materialFailure }
    func recoveryIsAvailable() -> Bool {
        guard coordinator != nil, let phase = lastStatus?.phase else { return false }
        return [.uploadIntent, .upgradeIntent, .receiptObserved, .installationUnknown, .lookupObserved].contains(phase)
    }

    /// Process lifetime owns the journal. Tests/explicit shutdown may close it;
    /// scene background does not release its lock underneath another action.
    func close() async throws {
        guard !busy else { throw Failure.busy }
        busy = true; defer { busy = false }
        try await developerAuthentication?.clearPendingAuthentication()
        if let journal { try await journal.close() }
        journal = nil; vault = nil; namespace = nil; liveDeveloperServices = nil; liveAnisetteProvider = nil; developerAccount = nil; developerEnrollmentIdentity = nil; developerAuthentication = nil; developerMaterial = nil
        developerAuthenticationEpoch = UUID(); developerAuthenticationResult = nil
        coordinator = nil; access = nil; materialFailure = nil; profileValidity = nil; root = nil
        configuration = nil; persistedConfiguration = nil; lastStatus = nil; configurationNeedsReload = false
        initialNamespaceBinding = nil; persistedInitialNamespaceBinding = nil
        automaticPolicy = nil; persistedAutomaticPolicy = nil
        anisetteConfiguration = nil; persistedAnisetteConfiguration = nil
    }

    private func openLocalOwner() async throws {
        if journal != nil {
            if configurationNeedsReload {
                guard let root else { throw Failure.storage }
                try Self.synchronizeConfigurationRoot(root)
                let document = try Self.loadDocument(root)
                try Self.removeUncommittedDocument(root)
                configuration = document?.configuration; persistedConfiguration = configuration; lastStatus = document?.status
                initialNamespaceBinding = document?.initialNamespaceBinding; persistedInitialNamespaceBinding = initialNamespaceBinding
                automaticPolicy = document?.automaticRenewal; persistedAutomaticPolicy = automaticPolicy
                anisetteConfiguration = document?.anisetteProvider; persistedAnisetteConfiguration = anisetteConfiguration
                configurationNeedsReload = false
            }
            return
        }
        let directory = try Self.openConfigurationRoot(requestedRoot)
        let opened = try await Journal.open(at: directory.appendingPathComponent("SelfRenewalTransactions", isDirectory: true))
        do {
            // Configuration and transaction share this owner's existing flock.
            // Never read a pre-lock document and apply it after another owner
            // has published newer configuration and released that lock.
            let document = try Self.loadDocument(directory)
            try Self.removeUncommittedDocument(directory)
            root = directory; journal = opened
            configuration = document?.configuration; persistedConfiguration = configuration; lastStatus = document?.status
                initialNamespaceBinding = document?.initialNamespaceBinding; persistedInitialNamespaceBinding = initialNamespaceBinding
                automaticPolicy = document?.automaticRenewal; persistedAutomaticPolicy = automaticPolicy
                anisetteConfiguration = document?.anisetteProvider; persistedAnisetteConfiguration = anisetteConfiguration
        } catch {
            let original = error
            do { try await opened.close() }
            catch { throw InitializationFailure(underlying: original, journalCloseError: error) }
            throw original
        }
    }

    private func connect(_ configuration: Configuration) async throws -> (vault: Vault, namespace: Vault.Namespace, coordinator: Coordinator, profileValidity: ConnectedProfileValidity) {
        guard let journal else { throw Failure.notConfigured }
        let material = try await SelfRenewalApplicationMaterialVerifier.read(unpackedApplication: ownedApplicationRoot ?? Bundle.main.bundleURL,
            codeAnchors: configuration.codeAnchors, profileAnchors: configuration.profileAnchors, at: clock())
        try Task.checkCancellation()
        let vault = Vault(codeAnchors: configuration.codeAnchors, profileAnchors: configuration.profileAnchors, clock: clock)
        let namespace = try await vault.resume(namespaceID: configuration.namespaceID, identity: material)
        let lease = try await vault.lease(in: namespace)
        try await vault.validate(lease, for: material)
        if let snapshot = try await journal.load() {
            guard snapshot.record.materialNamespace == namespace.id else { throw Coordinator.Failure.leaseChanged }
            // A generation change remains a real failure, not an automatic
            // rewrite of the persisted transaction's signing materials.
            if snapshot.record.phase == .retired {
                // Historical retired metadata owns no signing capability. Its
                // durable candidate-absence receipt is checked before allowing
                // newer material generation; active records retain exact CAS.
                _ = try await journal.resumeRetirement(snapshot, at: clock())
            } else {
                guard snapshot.record.materialGeneration == lease.generation else { throw Vault.Failure.staleGeneration }
            }
            if let submission = snapshot.record.submission, let device = configuration.device {
                guard submission.deviceCertificateSHA256 == Data(SHA256.hash(data: device.deviceCertificateDER)) else { throw Coordinator.Failure.wrongPeer }
            }
        }
        return (vault, namespace, Coordinator(journal: journal, vault: vault, namespace: namespace, clock: clock), try ConnectedProfileValidity(material))
    }

    private func activate(_ connection: Connection) {
        vault = connection.vault; namespace = connection.namespace; coordinator = connection.coordinator
        liveDeveloperServices = nil; liveAnisetteProvider = nil; developerAccount = nil; developerEnrollmentIdentity = nil; developerAuthentication = nil; developerMaterial = nil
        developerAuthenticationEpoch = UUID(); developerAuthenticationResult = nil
        access = connection.access; materialFailure = connection.materialFailure
        profileValidity = connection.profileValidity
    }

    private func resolve(_ configuration: Configuration) async throws -> Connection {
        do {
            let full = try await connect(configuration)
            return Connection(vault: full.vault, namespace: full.namespace, coordinator: full.coordinator, access: .signing, materialFailure: nil,
                profileValidity: full.profileValidity)
        } catch is CancellationError { throw CancellationError() }
        catch {
            let materialError = error
            guard Self.isSigningMaterialUnavailable(materialError) else { throw materialError }
            return try await recoveryConnection(configuration, materialError: materialError)
        }
    }

    private func recoveryConnection(_ configuration: Configuration, materialError: Error) async throws -> Connection {
        guard let journal else { throw materialError }
        let snapshot: Journal.Snapshot
        do {
            guard let loaded = try await journal.load(), Self.isRemoteRecoveryPhase(loaded.record.phase) else {
                throw Coordinator.Failure.invalidRecoveryContext
            }
            snapshot = loaded
        } catch is CancellationError { throw CancellationError() }
        catch {
            throw SigningMaterialUnavailable(underlying: materialError, recoveryContextError: error)
        }
        // Routing restriction only: no Vault.Namespace or signing proof.
        guard snapshot.record.materialNamespace == configuration.namespaceID else { throw Failure.configurationInUse }
        if let device = configuration.device {
            guard snapshot.record.submission?.deviceCertificateSHA256 == Data(SHA256.hash(data: device.deviceCertificateDER)) else { throw Coordinator.Failure.wrongPeer }
        }
        do {
            let recovery = try await Coordinator.recoveryOnly(journal: journal, clock: clock)
            return Connection(vault: nil, namespace: nil, coordinator: recovery, access: .recoveryOnly,
                materialFailure: SigningMaterialUnavailable(underlying: materialError, recoveryContextError: nil), profileValidity: nil)
        } catch is CancellationError { throw CancellationError() }
        catch {
            throw SigningMaterialUnavailable(underlying: materialError, recoveryContextError: error)
        }
    }

    private static func isRemoteRecoveryPhase(_ phase: Journal.Phase) -> Bool {
        [.uploadIntent, .upgradeIntent, .installationUnknown, .receiptObserved, .lookupObserved].contains(phase)
    }

    /// Only known material/crypto/lease failures permit a recovery capability.
    /// Journal, POSIX/Cocoa storage errors, read races, budgets and cancellation
    /// retain their original failure and never select a recovery fallback.
    static func isSigningMaterialUnavailable(_ error: Error) -> Bool {
        if let error = error as? SelfRenewalInstalledMaterialObserver.Unavailable {
            return isSigningMaterialUnavailable(error.underlying)
        }
        if error is KeychainHelper.ReadFailure { return false }
        if let error = error as? SelfRenewalApplicationMaterialVerifier.Failure {
            switch error {
            case .missingComponentMaterial, .unsignedCode, .missingDEREntitlements, .malformedIdentity,
                 .signerNotInProfile, .applicationIdentifierMismatch, .teamMismatch, .groupNotInProfile: return true
            case .changedInfo, .changedProfileResource: return false
            }
        }
        if let error = error as? SelfRenewalProvisioningProfileVerifier.Failure {
            switch error {
            case .missingProfile, .malformedProfile, .invalidValidityWindow, .profileNotYetValid,
                 .profileExpired, .missingDERProfile, .invalidDERProfile: return true
            case .totalReadLimit: return false
            }
        }
        if let error = error as? SelfRenewalCMSVerifier.Failure {
            switch error {
            case .malformedDER, .unsupportedCMS, .unsupportedAlgorithm, .missingContent, .ambiguousContent,
                 .invalidAttributes, .digestMismatch, .malformedCertificate, .signerNotFound, .ambiguousSigner,
                 .invalidSignature, .invalidAnchors, .untrustedChain: return true
            case .sizeLimit, .certificateLimit, .trustConfiguration: return false
            }
        }
        if let error = error as? Vault.Failure {
            switch error {
            case .namespaceUnavailable, .missingKey, .keyMismatch, .revoked, .invalidCertificate,
                 .untrustedCertificate, .identityChanged, .invalidProfiles, .staleGeneration: return true
            case .keychain, .limit, .malformedManifest, .manifestWrite, .keyGeneration, .clockMovedBackwards: return false
            }
        }
        if let error = error as? SelfRenewalSignedCodeVerifier.Failure {
            switch error {
            case .missingCMS, .duplicateHashType, .malformedHashAgilityV1, .malformedHashAgilityV2, .hashAgilityMismatch: return true
            case .readLimit, .truncatedRead, .changedCodeDirectory: return false
            }
        }
        if let error = error as? SelfRenewalCodeDirectoryHashVerifier.Failure {
            switch error {
            case .missingSignature, .unsupportedHash, .unsupportedSpecialSlot, .missingSpecialSlot,
                 .unexpectedSpecialSlot, .codeSlotMismatch, .specialSlotMismatch: return true
            case .contentReadLimit, .hashOperationLimit, .truncatedRead, .changedDirectory: return false
            }
        }
        if let error = error as? SelfRenewalResourceSealVerifier.Failure {
            switch error {
            case .malformedEnvelope, .invalidRule, .invalidPath, .unsupportedHash, .missingEnvelope, .unboundEnvelope,
                 .digestMismatch, .addedResource, .missingResource, .resourceTypeMismatch, .invalidDigest,
                 .nestedRequirementFailed, .missingNestedCode: return true
            case .envelopeLimit, .ruleLimit, .resourceReadLimit, .changedCodeDirectory: return false
            }
        }
        if let error = error as? SelfRenewalMaterialInventory.Failure {
            switch error {
            case .missingApplicationInfo, .malformedInfoPlist, .invalidInfoMetadata: return true
            default: return false
            }
        }
        if let error = error as? SelfRenewalMachOSignatureReader.Failure {
            switch error {
            case .unsupportedMagic, .malformedFat, .overlappingRanges, .architectureMismatch,
                 .malformedLoadCommand, .unknownRequiredCommand, .duplicateCodeSignature, .malformedSignature,
                 .unsupportedSignatureSlot, .malformedCodeDirectory, .unsupportedCodeDirectory, .unsupportedScatter,
                 .unsupportedPreEncryptedHashes, .unsupportedLinkage, .malformedString: return true
            default: return false
            }
        }
        return false
    }

    private static func isLocalStorageFailure(_ error: Error) -> Bool {
        if let error = error as? SelfRenewalInstalledMaterialObserver.Unavailable {
            return isLocalStorageFailure(error.underlying)
        }
        if error is Journal.Failure || error is POSIXError || error is CocoaError || error is KeychainHelper.ReadFailure { return true }
        if let error = error as? SigningMaterialUnavailable, let context = error.recoveryContextError {
            return isLocalStorageFailure(context)
        }
        if let error = error as? Vault.Failure {
            switch error {
            case .malformedManifest, .manifestWrite: return true
            case .keychain: return true
            default: return false
            }
        }
        return false
    }

    private func observeRecoveryOnly(_ coordinator: Coordinator, handoff: SelfRenewalUserDataHandoff) async throws -> Status {
        do {
            let snapshot = try await coordinator.observeUserDataAfterNormalLoad(handoff: handoff)
            let phase = snapshot?.record.phase
            // Cleanup -> ready is retained locally. It does not restore signing
            // power or authorize retirement/new preparation on this capability.
            return try publish(state: configuration == nil ? .unconfigured : (phase == .candidateReady ? .candidateReady : .recoveryRequired),
                phase: phase, problem: .signingMaterials)
        } catch is CancellationError { throw CancellationError() }
        catch { throw await unavailable(error, problem: .observation) }
    }

    private func recoverLocalPreparation() async throws {
        guard let journal, let snapshot = try await journal.load() else { return }
        switch snapshot.record.phase {
        case .created, .signing:
            _ = try await journal.retireUnsubmitted(snapshot, reason: .preparationInterrupted, at: clock())
        case .retirementPending, .retired:
            _ = try await journal.resumeRetirement(snapshot, at: clock())
        case .candidateReady:
            if snapshot.record.remoteHistory == .started, snapshot.record.safePreSubmissionCleanup != nil {
                _ = try await journal.retireUnsubmitted(snapshot, reason: .authenticatedUploadCleanup, at: clock())
            }
        case .uploadIntent, .upgradeIntent, .installationUnknown, .receiptObserved, .lookupObserved, .attentionRequired:
            break
        }
    }

    private func observe(_ coordinator: Coordinator, handoff: SelfRenewalUserDataHandoff) async throws -> Status {
        var materialError: Error?
        var userDataError: Error?
        var snapshot: Journal.Snapshot?
        do {
            guard let profileValidity else { throw Failure.notConfigured }
            try profileValidity.validate(at: clock())
            #if DEBUG
            if ownedApplicationRoot != nil {
                let bounded = try await coordinator.revalidateSigningMaterials()
                if let phase = bounded?.record.phase,
                   [.upgradeIntent, .installationUnknown, .receiptObserved, .lookupObserved].contains(phase) {
                    throw Failure.ownedApplicationIsNotCurrentProcess
                }
            } else { _ = try await coordinator.observeCurrentProcess() }
            #else
            _ = try await coordinator.observeCurrentProcess()
            #endif
        }
        catch is CancellationError { throw CancellationError() }
        catch {
            materialError = error
            // Stop retaining failed signing access before another awaited
            // observation can be cancelled. Its separate failure must not
            // restore access already disproved by the live-material read.
            vault = nil; namespace = nil; liveDeveloperServices = nil; liveAnisetteProvider = nil; developerAccount = nil; developerEnrollmentIdentity = nil; developerAuthentication = nil; developerMaterial = nil
            developerAuthenticationEpoch = UUID(); developerAuthenticationResult = nil
            self.coordinator = nil; access = nil; profileValidity = nil
            materialFailure = SigningMaterialUnavailable(underlying: error, recoveryContextError: nil)
        }
        // These are independent observations. An installed-material mismatch
        // must not suppress the real normal-load comparison of selected files.
        do { snapshot = try await coordinator.observeUserDataAfterNormalLoad(handoff: handoff) }
        catch is CancellationError { throw CancellationError() }
        catch { userDataError = error }
        if let materialError, Self.isSigningMaterialUnavailable(materialError), let configuration {
            // A previously live signing session may expire while this App stays
            // open. Downgrade through the same record-only factory; keep an
            // independent normal-load failure instead of treating it as success.
            let fallback: Connection
            do { fallback = try await recoveryConnection(configuration, materialError: materialError) }
            catch is CancellationError { throw CancellationError() }
            catch {
                let problem: Problem = Self.isLocalStorageFailure(error) ? .storage : .signingMaterials
                if let userDataError {
                    // The fallback error already keeps the material and remote
                    // context failures. Keep the independent normal-load error
                    // as well, without reclassifying a real storage failure.
                    throw await unavailable(ObservationFailures(installedMaterial: error,
                        normalUserData: userDataError), problem: problem)
                }
                throw await unavailable(error, problem: problem)
            }
            activate(fallback)
            if let userDataError {
                throw await unavailable(ObservationFailures(installedMaterial: materialError, normalUserData: userDataError), problem: .observation)
            }
            return try await observeRecoveryOnly(fallback.coordinator, handoff: handoff)
        }
        if materialError != nil || userDataError != nil {
            let storage = materialError.map(Self.isLocalStorageFailure) == true
            throw await unavailable(ObservationFailures(installedMaterial: materialError, normalUserData: userDataError), problem: storage ? .storage : .observation)
        }
        do {
            let phase = snapshot?.record.phase
            let state: State
            switch phase {
            case nil: state = .ready
            case .candidateReady: state = .candidateReady
            case .retired: state = .retiredUnsubmitted
            case .attentionRequired: state = .attentionRequired
            case .created, .signing, .retirementPending: state = .attentionRequired
            case .uploadIntent, .upgradeIntent, .installationUnknown, .receiptObserved, .lookupObserved: state = .recoveryRequired
            }
            return try publish(state: state, phase: phase)
        } catch is CancellationError { throw CancellationError() }
        catch { throw await unavailable(error, problem: .observation) }
    }

    private func unavailable(_ original: Error, problem: Problem) async -> Unavailable {
        var persistenceError: Error?
        do { _ = try publish(state: .unavailable, phase: try await journal?.load()?.record.phase, problem: problem) }
        catch { persistenceError = error }
        return Unavailable(underlying: original, problem: problem, statusPersistenceError: persistenceError)
    }

    private func publish(state: State, phase: Journal.Phase?, problem: Problem? = nil) throws -> Status {
        guard !configurationNeedsReload else { throw Failure.storage }
        guard let root else { throw Failure.storage }
        if let lastStatus, lastStatus.state == state, lastStatus.phase == phase,
           lastStatus.problem == problem, lastStatus.access == access, configuration == persistedConfiguration,
           initialNamespaceBinding == persistedInitialNamespaceBinding, automaticPolicy == persistedAutomaticPolicy,
           anisetteConfiguration == persistedAnisetteConfiguration { return lastStatus }
        let status = Status(state: state, phase: phase, observedAt: clock(), problem: problem, access: access)
        let document = Document(schema: 1, configuration: configuration, initialNamespaceBinding: initialNamespaceBinding, automaticRenewal: automaticPolicy, anisetteProvider: anisetteConfiguration, status: status)
        let raw = try JSONEncoder().encode(document)
        guard raw.count <= Self.maximumConfigurationBytes else { throw Failure.limit }
        do {
            #if DEBUG
            let losesAcknowledgement: Bool
            switch publicationFault {
            case .loseNextDirectorySyncAcknowledgement: losesAcknowledgement = true
            case .loseNextAuthenticatedRecoveryDirectorySyncAcknowledgement:
                losesAcknowledgement = state == .authenticatedRecoveryObserved
            case .failInitialConfigurationBeforeWrite:
                if configuration != nil, persistedInitialNamespaceBinding != nil {
                    publicationFault = nil
                    throw Failure.storage
                }
                losesAcknowledgement = false
            case nil: losesAcknowledgement = false
            }
            if losesAcknowledgement { publicationFault = nil }
            try Self.writeDocument(raw, root: root, loseCommitAcknowledgement: losesAcknowledgement)
            #else
            try Self.writeDocument(raw, root: root)
            #endif
        } catch {
            if let failure = error as? Failure, failure == .commitDurabilityUnknown {
                // Every publication uses this boundary, including bootstrap
                // status, observations and error status. A lost durable ACK
                // can never leave a prior coordinator binding usable.
                coordinator = nil; vault = nil; namespace = nil; liveDeveloperServices = nil; liveAnisetteProvider = nil; developerAccount = nil; developerEnrollmentIdentity = nil; developerAuthentication = nil; developerMaterial = nil
            developerAuthenticationEpoch = UUID(); developerAuthenticationResult = nil
                access = nil; profileValidity = nil; configurationNeedsReload = true
            }
            throw error
        }
        lastStatus = status
        persistedConfiguration = configuration
        persistedInitialNamespaceBinding = initialNamespaceBinding
        persistedAutomaticPolicy = automaticPolicy
        persistedAnisetteConfiguration = anisetteConfiguration
        return status
    }

    static func decodeConfiguration(_ raw: Data) throws -> Configuration {
        precondition(!Thread.isMainThread)
        guard !raw.isEmpty, raw.count <= maximumConfigurationBytes else { throw Failure.limit }
        let result: Configuration
        do { result = try JSONDecoder().decode(Configuration.self, from: raw) }
        catch { throw Failure.invalidConfiguration }
        try validate(result)
        return result
    }

    private static func validate(_ configuration: Configuration) throws {
        guard configuration.schema == 1 else { throw Failure.invalidConfiguration }
        var certificateBytes = 0
        for anchors in [configuration.codeAnchors, configuration.profileAnchors] {
            guard !anchors.isEmpty, anchors.count <= 8, Set(anchors).count == anchors.count else { throw Failure.invalidConfiguration }
            for der in anchors {
                try Task.checkCancellation()
                certificateBytes += der.count
                guard !der.isEmpty, der.count <= 65_536, certificateBytes <= 262_144,
                      SecCertificateCreateWithData(nil, der as CFData) != nil else { throw Failure.invalidConfiguration }
            }
        }
        if let device = configuration.device {
            guard !device.identityPersistentReference.isEmpty, device.identityPersistentReference.count <= 4096,
                  device.port > 0,
                  [device.hostID, device.systemBUID].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.utf8.contains(0) }),
                  [device.deviceCertificateDER, device.rootCertificateDER].allSatisfy({ !$0.isEmpty && $0.count <= 65_536 && SecCertificateCreateWithData(nil, $0 as CFData) != nil }) else { throw Failure.invalidConfiguration }
            var address4 = in_addr(), address6 = in6_addr()
            guard device.numericAddress.utf8.count <= 64, !device.numericAddress.utf8.contains(0),
                  inet_pton(AF_INET, device.numericAddress, &address4) == 1 || inet_pton(AF_INET6, device.numericAddress, &address6) == 1 else { throw Failure.invalidConfiguration }
        }
    }

    static func pairing(_ device: DeviceConfiguration) throws -> Transport.PairingIdentity {
        try Task.checkCancellation()
        // Persistent ref is scoped to this App's actual accessible Keychain.
        // No global search, private export or key generation. Explicit P12
        // import obtains this same selector and re-reads this actual handle.
        let query: [String: Any] = [kSecClass as String: kSecClassIdentity,
            kSecValuePersistentRef as String: device.identityPersistentReference,
            kSecReturnRef as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let item, CFGetTypeID(item) == SecIdentityGetTypeID() else {
            throw Failure.identityUnavailable(status)
        }
        let identity = unsafeBitCast(item, to: SecIdentity.self)
        return try Transport.PairingIdentity(hostIdentity: identity, deviceCertificateDER: device.deviceCertificateDER,
            rootCertificateDER: device.rootCertificateDER, hostID: device.hostID, systemBUID: device.systemBUID)
    }

    private static func openConfigurationRoot(_ requested: URL?) throws -> URL {
        precondition(!Thread.isMainThread)
        let parent: URL
        if let requested {
            guard requested.isFileURL, requested.lastPathComponent == "SelfRenewalApp" else { throw Failure.storage }
            parent = requested.deletingLastPathComponent()
        } else {
            parent = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
        }
        let descriptor = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.storage }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else { throw Failure.storage }
        if mkdirat(descriptor, "SelfRenewalApp", 0o700) != 0, errno != EEXIST { throw Failure.storage }
        let root = parent.appendingPathComponent("SelfRenewalApp", isDirectory: true)
        let owned = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard owned >= 0 else { throw Failure.storage }
        defer { Darwin.close(owned) }
        guard fstat(owned, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              fsync(descriptor) == 0 else { throw Failure.storage }
        return root
    }

    private static func loadDocument(_ root: URL) throws -> Document? {
        let input = root.appendingPathComponent("configuration.json")
        let raw: Data
        do { raw = try readBounded(input, maximum: maximumConfigurationBytes) }
        catch let error as POSIXError where error.code == .ENOENT { return nil }
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: raw) }
        catch { throw Failure.invalidConfiguration }
        guard document.schema == 1, document.status.observedAt.timeIntervalSince1970.isFinite else { throw Failure.invalidConfiguration }
        guard document.configuration != nil || document.status.state == .unconfigured else { throw Failure.invalidConfiguration }
        if let configuration = document.configuration { try validate(configuration) }
        if let policy = document.automaticRenewal { try policy.validate() }
        if let provider = document.anisetteProvider { try provider.validate() }
        if let pending = document.initialNamespaceBinding {
            guard document.configuration == nil, pending.schema == 1, pending.identitySHA256.count == 32,
                  document.status.state == .unconfigured, document.status.phase == nil, document.status.access == nil else {
                throw Failure.invalidConfiguration
            }
            try validate(pending.configuration)
        }
        return document
    }

    private static func synchronizeConfigurationRoot(_ root: URL) throws {
        let directory = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Failure.storage }
        defer { Darwin.close(directory) }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              fsync(directory) == 0 else { throw Failure.commitDurabilityUnknown }
    }

    /// The journal lock is held. Reclaim only this owner's one fixed atomic
    /// temporary after a crash; never enumerate or repair unrelated files.
    private static func removeUncommittedDocument(_ root: URL) throws {
        let directory = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Failure.storage }
        defer { Darwin.close(directory) }
        let name = "configuration.pending"
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return }
            throw Failure.storage
        }
        defer { Darwin.close(descriptor) }
        var info = stat(), named = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= maximumConfigurationBytes,
              fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == info.st_dev, named.st_ino == info.st_ino else { throw Failure.storage }
        guard unlinkat(directory, name, 0) == 0 else { throw Failure.storage }
        guard fsync(directory) == 0 else { throw Failure.commitDurabilityUnknown }
    }

    static func readBounded(_ path: URL, maximum: Int) throws -> Data {
        precondition(!Thread.isMainThread)
        try Task.checkCancellation()
        guard path.isFileURL, maximum > 0, maximum <= maximumConfigurationBytes else { throw Failure.limit }
        let fd = Darwin.open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, before.st_size > 0, before.st_size <= maximum else { throw Failure.limit }
        var result = Data(count: Int(before.st_size))
        try result.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try Task.checkCancellation()
                let amount = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw Failure.storage }
                offset += amount
            }
        }
        var extra: UInt8 = 0
        guard Darwin.read(fd, &extra, 1) == 0, fstat(fd, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw Failure.changedFile }
        return result
    }

    private static func writeDocument(_ raw: Data, root: URL, loseCommitAcknowledgement: Bool = false) throws {
        precondition(!Thread.isMainThread)
        try Task.checkCancellation()
        let directory = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Failure.storage }
        defer { Darwin.close(directory) }
        let name = "configuration.pending"
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.storage }
        var closed = false
        defer { if !closed { Darwin.close(fd) }; unlinkat(directory, name, 0) }
        try raw.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try Task.checkCancellation()
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.storage }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw Failure.storage }
        closed = true
        guard Darwin.close(fd) == 0 else { throw Failure.storage }
        try Task.checkCancellation()
        guard renameat(directory, name, directory, "configuration.json") == 0 else { throw Failure.storage }
        guard fsync(directory) == 0 else { throw Failure.commitDurabilityUnknown }
        // DEBUG fault withdraws an acknowledgement only AFTER all genuine file
        // I/O and fsync succeeded. It cannot replace I/O or manufacture success.
        if loseCommitAcknowledgement { throw Failure.commitDurabilityUnknown }
    }

    private func trace(_ stage: String, since started: TimeInterval) {
        SourcePerfTrace.record("renewal.app.\(stage)", "bytesLimit=\(Self.maximumConfigurationBytes) main=\(Thread.isMainThread)", since: started, thresholdMs: 0)
    }
}
