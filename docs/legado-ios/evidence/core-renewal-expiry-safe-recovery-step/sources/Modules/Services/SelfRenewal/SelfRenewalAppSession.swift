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
        let coordinator: Coordinator
        let access: Access
        let materialFailure: SigningMaterialUnavailable?
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
    private struct Document: Codable {
        let schema: Int
        let configuration: Configuration?
        let status: Status
    }
    private let requestedRoot: URL?
    private let clock: @Sendable () -> Date
    private var root: URL?
    private var journal: Journal?
    private var vault: Vault?
    private var coordinator: Coordinator?
    private var access: Access?
    private var materialFailure: SigningMaterialUnavailable?
    private var configuration: Configuration?
    private var lastStatus: Status?
    private var persistedConfiguration: Configuration?
    private var configurationNeedsReload = false
    private var busy = false
    #if DEBUG
    enum PublicationFault: Sendable {
        case loseNextDirectorySyncAcknowledgement
        case loseNextAuthenticatedRecoveryDirectorySyncAcknowledgement
    }
    private var publicationFault: PublicationFault?
    init(root: URL, publicationFault: PublicationFault, clock: @escaping @Sendable () -> Date = { Date() }) {
        requestedRoot = root; self.clock = clock; self.publicationFault = publicationFault
    }
    #endif
    static let maximumConfigurationBytes = 524_288

    /// No file, Bundle, Keychain or network work happens during App.init.
    init(root: URL? = nil, clock: @escaping @Sendable () -> Date = { Date() }) {
        requestedRoot = root; self.clock = clock
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
            coordinator = nil; vault = nil; access = nil; configurationNeedsReload = true
            throw error
        }
        if candidate.access == .recoveryOnly { return try await observeRecoveryOnly(candidate.coordinator, handoff: handoff) }
        do { try await recoverLocalPreparation() }
        catch is CancellationError { throw CancellationError() }
        catch { throw await unavailable(error, problem: .storage) }
        return try await observe(candidate.coordinator, handoff: handoff)
    }

    /// This is the only network entry in the App owner. It recovers the existing
    /// journal via the unique installer; it never uploads or submits Upgrade.
    func recoverExplicitly(handoff: SelfRenewalUserDataHandoff) async throws -> Status {
        guard !busy else { throw Failure.busy }
        busy = true; defer { busy = false }
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

    func status() -> Status? { lastStatus }
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
        if let journal { try await journal.close() }
        journal = nil; vault = nil; coordinator = nil; access = nil; materialFailure = nil; root = nil
        configuration = nil; persistedConfiguration = nil; lastStatus = nil; configurationNeedsReload = false
    }

    private func openLocalOwner() async throws {
        if journal != nil {
            if configurationNeedsReload {
                guard let root else { throw Failure.storage }
                try Self.synchronizeConfigurationRoot(root)
                let document = try Self.loadDocument(root)
                try Self.removeUncommittedDocument(root)
                configuration = document?.configuration; persistedConfiguration = configuration; lastStatus = document?.status
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
        } catch {
            let original = error
            do { try await opened.close() }
            catch { throw InitializationFailure(underlying: original, journalCloseError: error) }
            throw original
        }
    }

    private func connect(_ configuration: Configuration) async throws -> (vault: Vault, coordinator: Coordinator) {
        guard let journal else { throw Failure.notConfigured }
        let material = try await SelfRenewalApplicationMaterialVerifier.read(unpackedApplication: Bundle.main.bundleURL,
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
            guard snapshot.record.materialGeneration == lease.generation else { throw Vault.Failure.staleGeneration }
            if let submission = snapshot.record.submission, let device = configuration.device {
                guard submission.deviceCertificateSHA256 == Data(SHA256.hash(data: device.deviceCertificateDER)) else { throw Coordinator.Failure.wrongPeer }
            }
        }
        return (vault, Coordinator(journal: journal, vault: vault, namespace: namespace, clock: clock))
    }

    private func activate(_ connection: Connection) {
        vault = connection.vault; coordinator = connection.coordinator
        access = connection.access; materialFailure = connection.materialFailure
    }

    private func resolve(_ configuration: Configuration) async throws -> Connection {
        do {
            let full = try await connect(configuration)
            return Connection(vault: full.vault, coordinator: full.coordinator, access: .signing, materialFailure: nil)
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
            return Connection(vault: nil, coordinator: recovery, access: .recoveryOnly,
                materialFailure: SigningMaterialUnavailable(underlying: materialError, recoveryContextError: nil))
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
        do { _ = try await coordinator.observeCurrentProcess() }
        catch is CancellationError { throw CancellationError() }
        catch { materialError = error }
        // These are independent observations. An installed-material mismatch
        // must not suppress the real normal-load comparison of selected files.
        do { snapshot = try await coordinator.observeUserDataAfterNormalLoad(handoff: handoff) }
        catch is CancellationError { throw CancellationError() }
        catch { userDataError = error }
        if let materialError, Self.isSigningMaterialUnavailable(materialError), let configuration {
            // A previously live signing session may expire while this App stays
            // open. Downgrade through the same record-only factory; keep an
            // independent normal-load failure instead of treating it as success.
            let fallback = try await recoveryConnection(configuration, materialError: materialError)
            activate(fallback)
            if let userDataError {
                throw await unavailable(ObservationFailures(installedMaterial: materialError, normalUserData: userDataError), problem: .observation)
            }
            return try await observeRecoveryOnly(fallback.coordinator, handoff: handoff)
        }
        if materialError != nil || userDataError != nil {
            throw await unavailable(ObservationFailures(installedMaterial: materialError, normalUserData: userDataError), problem: .observation)
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
        guard let root else { throw Failure.storage }
        if let lastStatus, lastStatus.state == state, lastStatus.phase == phase,
           lastStatus.problem == problem, lastStatus.access == access, configuration == persistedConfiguration { return lastStatus }
        let status = Status(state: state, phase: phase, observedAt: clock(), problem: problem, access: access)
        let document = Document(schema: 1, configuration: configuration, status: status)
        let raw = try JSONEncoder().encode(document)
        guard raw.count <= Self.maximumConfigurationBytes else { throw Failure.limit }
        do {
            #if DEBUG
            let losesAcknowledgement: Bool
            switch publicationFault {
            case .loseNextDirectorySyncAcknowledgement: losesAcknowledgement = true
            case .loseNextAuthenticatedRecoveryDirectorySyncAcknowledgement:
                losesAcknowledgement = state == .authenticatedRecoveryObserved
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
                coordinator = nil; vault = nil; access = nil; configurationNeedsReload = true
            }
            throw error
        }
        lastStatus = status
        persistedConfiguration = configuration
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
        // No global search, PKCS12 import, private export or key generation.
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
