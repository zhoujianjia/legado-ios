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
    struct Status: Sendable, Codable, Equatable {
        let state: State
        let phase: Journal.Phase?
        let observedAt: Date
        let problem: Problem?
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
    private var root: URL?
    private var journal: Journal?
    private var vault: Vault?
    private var coordinator: Coordinator?
    private var configuration: Configuration?
    private var lastStatus: Status?
    private var persistedConfiguration: Configuration?
    private var configurationNeedsReload = false
    private var busy = false
    static let maximumConfigurationBytes = 524_288

    /// No file, Bundle, Keychain or network work happens during App.init.
    init(root: URL? = nil) { requestedRoot = root }

    func bootstrap(handoff: SelfRenewalUserDataHandoff) async throws -> Status {
        guard !busy else { throw Failure.busy }
        busy = true; defer { busy = false }
        let started = SourcePerfTrace.now
        defer { trace("bootstrap", since: started) }
        try Task.checkCancellation()
        try await openLocalOwner()
        if let coordinator {
            do { try await recoverLocalPreparation() }
            catch is CancellationError { throw CancellationError() }
            catch { throw await unavailable(error, problem: .storage) }
            return try await observe(coordinator, handoff: handoff)
        }
        guard let configuration else {
            return try publish(state: .unconfigured, phase: try await journal?.load()?.record.phase)
        }
        let candidate: (vault: Vault, coordinator: Coordinator)
        do { candidate = try await connect(configuration) }
        catch is CancellationError { throw CancellationError() }
        catch { throw await unavailable(error, problem: .signingMaterials) }
        vault = candidate.vault; coordinator = candidate.coordinator
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
        // Actual Bundle signatures, published vault key/profile and namespace
        // identity are checked before persisting this configuration as usable.
        let candidate = try await connect(proposed)
        try Task.checkCancellation()
        let priorConfiguration = configuration
        configuration = proposed
        do { _ = try publish(state: .ready, phase: existing?.record.phase) }
        catch {
            configuration = priorConfiguration
            // A rename followed by a failed directory sync may have changed
            // disk. Never keep using an older in-memory authorization binding.
            coordinator = nil; vault = nil; configurationNeedsReload = true
            throw error
        }
        vault = candidate.vault; coordinator = candidate.coordinator
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
        guard let coordinator, let configuration else { throw Failure.notConfigured }
        guard let device = configuration.device else { throw Failure.authenticationNotConfigured }
        let pairing = try Self.pairing(device)
        let endpoint = Transport.Endpoint(numericAddress: device.numericAddress,
            port: device.port, interfaceIndex: device.interfaceIndex)
        _ = try await coordinator.recover(pairing: pairing, endpoint: endpoint, timeoutSeconds: 30)
        // A successful Lookup/Remove is reported as that observation, never as
        // installed code, Apple authority, or a completed automatic renewal.
        let status = try await observe(coordinator, handoff: handoff)
        if status.state == .recoveryRequired {
            return try publish(state: .authenticatedRecoveryObserved, phase: status.phase)
        }
        return status
    }

    func status() -> Status? { lastStatus }
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
        journal = nil; vault = nil; coordinator = nil; root = nil
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
            codeAnchors: configuration.codeAnchors, profileAnchors: configuration.profileAnchors, at: Date())
        try Task.checkCancellation()
        let vault = Vault(codeAnchors: configuration.codeAnchors, profileAnchors: configuration.profileAnchors)
        let namespace = try await vault.resume(namespaceID: configuration.namespaceID, identity: material)
        let lease = try await vault.lease(in: namespace)
        try await vault.validate(lease, for: material)
        if let snapshot = try await journal.load() {
            guard snapshot.record.materialNamespace == namespace.id else { throw Coordinator.Failure.leaseChanged }
            // A generation change remains a real failure, not an automatic
            // rewrite of the persisted transaction's signing materials.
            guard snapshot.record.materialGeneration == lease.generation else { throw Coordinator.Failure.leaseChanged }
            if let submission = snapshot.record.submission, let device = configuration.device {
                guard submission.deviceCertificateSHA256 == Data(SHA256.hash(data: device.deviceCertificateDER)) else { throw Coordinator.Failure.wrongPeer }
            }
        }
        return (vault, Coordinator(journal: journal, vault: vault, namespace: namespace))
    }

    private func recoverLocalPreparation() async throws {
        guard let journal, let snapshot = try await journal.load() else { return }
        switch snapshot.record.phase {
        case .created, .signing:
            _ = try await journal.retireUnsubmitted(snapshot, reason: .preparationInterrupted, at: Date())
        case .retirementPending, .retired:
            _ = try await journal.resumeRetirement(snapshot, at: Date())
        case .candidateReady:
            if snapshot.record.remoteHistory == .started, snapshot.record.safePreSubmissionCleanup != nil {
                _ = try await journal.retireUnsubmitted(snapshot, reason: .authenticatedUploadCleanup, at: Date())
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
           lastStatus.problem == problem, configuration == persistedConfiguration { return lastStatus }
        let status = Status(state: state, phase: phase, observedAt: Date(), problem: problem)
        let document = Document(schema: 1, configuration: configuration, status: status)
        let raw = try JSONEncoder().encode(document)
        guard raw.count <= Self.maximumConfigurationBytes else { throw Failure.limit }
        try Self.writeDocument(raw, root: root)
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

    private static func writeDocument(_ raw: Data, root: URL) throws {
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
    }

    private func trace(_ stage: String, since started: TimeInterval) {
        SourcePerfTrace.record("renewal.app.\(stage)", "bytesLimit=\(Self.maximumConfigurationBytes) main=\(Thread.isMainThread)", since: started, thresholdMs: 0)
    }
}
