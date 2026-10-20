import CryptoKit
import Darwin
import Foundation

/// One injected main-App owner, one active renewal, no credentials or library copy.
/// The advisory lock excludes another cooperating owner across process restarts.
/// A committed Upgrade intent is never rewritten as "not submitted" on disconnect.
actor SelfRenewalTransactionJournal {
    typealias Installer = SelfRenewalAuthenticatedInstallationClient
    enum Failure: Error, Sendable, Equatable {
        case invalidDirectory, ownerAlreadyOpen, storageIO, malformedRecord, missingRecord
        case staleSnapshot, activeTransaction, invalidTransition, invalidCandidate, limit
        case retirementNotAuthorized
        /// rename succeeded but directory durability could not be confirmed. Reload;
        /// do not submit a network operation based on a thrown publication call.
        case commitDurabilityUnknown
    }
    enum Phase: String, Sendable, Codable {
        case created, signing, candidateReady, uploadIntent, upgradeIntent, receiptObserved
        case installationUnknown, lookupObserved, attentionRequired
        case retirementPending, retired
    }
    struct Candidate: Sendable, Codable, Equatable {
        let byteCount: Int
        let sha256: Data
    }
    struct Submission: Sendable, Codable, Equatable {
        let remotePackagePath: String
        let deviceCertificateSHA256: Data
    }
    /// Persisted only by completeRemoteCleanup after its actual sealed Outcome.
    /// Empty paths, a version Lookup or an old ready record cannot manufacture it.
    struct SafePreSubmissionCleanup: Sendable, Codable, Equatable {
        let grantID: UUID
        let candidate: Candidate
        let submission: Submission
        let removal: String
        let completedAt: Date
        fileprivate init(grant: RemoteCleanupGrant, outcome: SelfRenewalInstallationRecovery.Outcome, at date: Date) throws {
            guard grant.disposition == .safeBeforeSubmission, let removal = outcome.removal,
                  outcome.grantID == grant.id, outcome.remotePackagePath == grant.remotePackagePath,
                  outcome.deviceCertificateSHA256 == grant.deviceCertificateSHA256,
                  outcome.stopSessionAcknowledged, outcome.lookup == nil,
                  outcome.afcChannelReleasedLocally, outcome.lockdownChannelReleasedLocally,
                  let candidate = grant.snapshot.record.candidate,
                  let submission = grant.snapshot.record.submission else { throw Failure.invalidTransition }
            grantID = grant.id; self.candidate = candidate; self.submission = submission
            self.removal = removal.rawValue; completedAt = date
        }
    }
    enum RetirementReason: String, Sendable, Codable {
        case preparationFailed, preparationInterrupted, supersededUnsubmittedCandidate, authenticatedUploadCleanup
    }
    enum RemoteHistory: String, Sendable, Codable {
        /// Written by this journal's actual create, not inferred from a nil path.
        case neverStarted
        /// Written durably before the install client may create its remote file.
        case started
    }
    enum LocalCandidateRemoval: String, Sendable, Codable {
        case removed, alreadyAbsent
    }
    struct Retirement: Sendable, Codable, Equatable {
        let originalPhase: Phase
        let originalRevision: UInt64
        let originalRecordSHA256: Data
        let candidate: Candidate?
        let reason: RetirementReason
        let initiatedAt: Date
        var localCandidateRemoval: LocalCandidateRemoval?
        var completedAt: Date?
    }
    /// One constant-size predecessor commitment, never a growing history array.
    struct PreviousRetirement: Sendable, Codable, Equatable {
        let transactionID: UUID
        let revision: UInt64
        let recordSHA256: Data
        let retiredAt: Date
        fileprivate init(_ receipt: RetirementReceipt) {
            transactionID = receipt.transactionID; revision = receipt.revision
            recordSHA256 = receipt.recordSHA256; retiredAt = receipt.retiredAt
        }
    }
    struct RetirementReceipt: Sendable {
        let transactionID: UUID
        let revision: UInt64
        let recordSHA256: Data
        let originalPhase: Phase
        let reason: RetirementReason
        let localCandidateRemoval: LocalCandidateRemoval
        let retiredAt: Date
        let safePreSubmissionCleanup: SafePreSubmissionCleanup?
        /// Does not establish installation, remote absence outside the sealed
        /// pre-submission cleanup, user-data preservation or Apple authority.
        var renewalVerified: Bool { false }
        fileprivate init(_ snapshot: Snapshot) throws {
            guard snapshot.record.phase == .retired, let retirement = snapshot.record.retirement,
                  let removal = retirement.localCandidateRemoval,
                  let date = retirement.completedAt else { throw Failure.invalidTransition }
            transactionID = snapshot.record.id; revision = snapshot.record.revision
            recordSHA256 = snapshot.encodedSHA256; originalPhase = retirement.originalPhase
            reason = retirement.reason; localCandidateRemoval = removal; retiredAt = date
            safePreSubmissionCleanup = snapshot.record.safePreSubmissionCleanup
        }
    }
    struct InstalledMaterialObservation: Sendable, Codable, Equatable {
        let candidateArchiveSHA256: Data
        let authenticatedMaterialSHA256: Data
        let processID: UUID
        let observedAt: Date
    }
    struct UserDataCheckpoint: Sendable, Codable, Equatable {
        struct File: Sendable, Codable, Equatable {
            let role: String
            let operation: String
            let rawSHA256: Data?
            let rawByteCount: Int
        }
        struct Position: Sendable, Codable, Equatable {
            let bookID: String
            let position: CoreTextReadingPosition
            let rawSHA256: Data
            let rawByteCount: Int
        }
        let processID: UUID
        let capturedAt: Date
        let bookMutationRevision: UInt64
        let sourceMutationRevision: Int
        let sourceCount: Int
        let files: [File]
        let positions: [Position]
        /// Only these selected owner files/active positions were observed.
        var allUserDataPreservationVerified: Bool { false }

        fileprivate init(_ receipt: SelfRenewalUserDataHandoff.Receipt) throws {
            guard receipt.books.phase == .save,
                  receipt.books.files.map(\.role) == [.shelf, .reading],
                  receipt.sources.operation == .atomicWriteCompleted,
                  receipt.positions.allSatisfy({ $0.operation == .atomicWriteCompleted }) else { throw Failure.invalidTransition }
            processID = receipt.processID; capturedAt = receipt.capturedAt
            bookMutationRevision = receipt.books.localRevision
            sourceMutationRevision = receipt.sources.mutationRevision
            sourceCount = receipt.sources.sourceCount
            files = try receipt.books.files.map { file in
                File(role: file.role.rawValue, operation: file.operation.rawValue,
                    rawSHA256: try file.rawSHA256.map(Self.decodeHash), rawByteCount: file.rawByteCount)
            } + [File(role: "sources", operation: "atomicWriteCompleted",
                rawSHA256: receipt.sources.rawSHA256, rawByteCount: receipt.sources.rawByteCount)]
            positions = receipt.positions.map { Position(bookID: $0.bookId, position: $0.position,
                rawSHA256: $0.rawSHA256, rawByteCount: $0.rawByteCount) }
        }
        fileprivate static func decodeHash(_ hex: String) throws -> Data {
            let bytes = Array(hex.utf8)
            guard bytes.count == 64, bytes.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Failure.invalidTransition }
            var result = Data(); result.reserveCapacity(32)
            func digit(_ byte: UInt8) -> UInt8 { byte <= 57 ? byte - 48 : byte - 87 }
            for offset in stride(from: 0, to: 64, by: 2) { result.append(digit(bytes[offset]) << 4 | digit(bytes[offset + 1])) }
            return result
        }
    }
    struct UserDataReadObservation: Sendable, Codable, Equatable {
        struct Position: Sendable, Codable, Equatable {
            let bookID: String
            let position: CoreTextReadingPosition?
            let rawSHA256: Data?
            let rawByteCount: Int
        }
        let processID: UUID
        let observedAt: Date
        let files: [UserDataCheckpoint.File]
        let positions: [Position]
        let selectedFilesMatch: Bool
        let sourceWasBootstrapped: Bool
        var allUserDataPreservationVerified: Bool { false }
    }
    struct Record: Sendable, Codable, Equatable {
        let schema: Int
        let id: UUID
        var revision: UInt64
        let createdAt: Date
        var updatedAt: Date
        let materialNamespace: UUID
        let materialGeneration: UInt64
        let originalArchiveSHA256: Data
        let identitySHA256: Data
        let bundleIdentifier: String
        let bundleVersion: String
        let preparationProcessID: UUID?
        var phase: Phase
        var candidate: Candidate?
        var submission: Submission?
        var lookupReportedSameVersion: Bool?
        var installedMaterial: InstalledMaterialObservation?
        var userDataHandoff: UserDataCheckpoint?
        var userDataRead: UserDataReadObservation?
        var safePreSubmissionCleanup: SafePreSubmissionCleanup? = nil
        var retirement: Retirement? = nil
        var previousRetirement: PreviousRetirement? = nil
        /// nil is a legacy record with unrecorded history, never a negative proof.
        var remoteHistory: RemoteHistory? = nil
        var userDataReadInDifferentProcess: Bool? {
            guard let userDataHandoff, let userDataRead else { return nil }
            return userDataHandoff.processID != userDataRead.processID
        }
        var observedDifferentProcess: Bool? {
            guard let preparationProcessID, let installedMaterial else { return nil }
            return preparationProcessID != installedMaterial.processID
        }
        /// No phase here proves a renewed profile, cold launch or retained data.
        var renewalVerified: Bool { false }
    }
    struct Snapshot: Sendable {
        let record: Record
        fileprivate let encodedSHA256: Data
        fileprivate let owner: UUID
    }
    struct ArchiveInput: Sendable {
        let byteCount: Int
        let sha256: Data
        let read: @Sendable (Int, Int) async throws -> Data
    }
    struct RemoteCleanupGrant: Sendable {
        enum Disposition: Sendable, Equatable { case safeBeforeSubmission, reportedComplete, unknownSubmission }
        let id: UUID
        let snapshot: Snapshot
        let disposition: Disposition
        var remotePackagePath: String { snapshot.record.submission!.remotePackagePath }
        var deviceCertificateSHA256: Data { snapshot.record.submission!.deviceCertificateSHA256 }
        var archiveSHA256: Data { snapshot.record.candidate!.sha256 }
        var archiveBytes: Int { snapshot.record.candidate!.byteCount }
        var bundleIdentifier: String { snapshot.record.bundleIdentifier }
        var bundleVersion: String { snapshot.record.bundleVersion }
        fileprivate init(snapshot: Snapshot, disposition: Disposition) {
            id = UUID(); self.snapshot = snapshot; self.disposition = disposition
        }
    }
    enum Limits {
        static let recordBytes = 65_536
        static let candidateBytes = SelfRenewalIPAArchiveValidator.Limits.archiveBytes
        static let chunkBytes = 65_536
    }
    private let rootURL: URL
    private let directory: Int32
    private let lockFile: Int32
    private let owner = UUID()
    private var streamingCandidate = false
    private var activeRemoteCleanup: UUID?
    private var closed = false
    private init(root: URL, directory: Int32, lockFile: Int32) {
        rootURL = root; self.directory = directory; self.lockFile = lockFile
    }
    deinit { if !closed { Darwin.close(lockFile); Darwin.close(directory) } }

    func close() throws {
        guard !streamingCandidate, activeRemoteCleanup == nil else { throw Failure.activeTransaction }
        if closed { return }
        closed = true
        Darwin.close(lockFile); Darwin.close(directory)
    }

    /// Caller supplies its dedicated App-support child, never an imported path.
    /// Construction does no I/O on App.init or the main executor.
    nonisolated static func open(at root: URL) async throws -> SelfRenewalTransactionJournal {
        let worker = Task.detached(priority: .utility) {
            precondition(!Thread.isMainThread)
            let started = SourcePerfTrace.now
            defer { SourcePerfTrace.record("renewal.transaction.open", "main=\(Thread.isMainThread)", since: started, thresholdMs: 0) }
            try Task.checkCancellation()
            guard root.isFileURL, root.lastPathComponent == "SelfRenewalTransactions" else { throw Failure.invalidDirectory }
            let parent = Darwin.open(root.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parent >= 0 else { throw Failure.invalidDirectory }
            defer { Darwin.close(parent) }
            var parentStat = stat()
            guard fstat(parent, &parentStat) == 0, parentStat.st_uid == getuid(),
                  parentStat.st_mode & 0o022 == 0 else { throw Failure.invalidDirectory }
            if mkdirat(parent, "SelfRenewalTransactions", 0o700) != 0, errno != EEXIST { throw Failure.storageIO }
            let directory = openat(parent, "SelfRenewalTransactions", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { throw Failure.invalidDirectory }
            var ownsDirectory = true
            defer { if ownsDirectory { Darwin.close(directory) } }
            var directoryStat = stat()
            guard fstat(directory, &directoryStat) == 0, directoryStat.st_uid == getuid(),
                  directoryStat.st_mode & 0o077 == 0 else { throw Failure.invalidDirectory }
            // Sync the parent even on reopen: a previous process may have died
            // after mkdir but before its parent-name durability boundary.
            guard fsync(parent) == 0 else { throw Failure.commitDurabilityUnknown }
            let lockFile = openat(directory, ".owner.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard lockFile >= 0 else { throw Failure.storageIO }
            var ownsLock = true
            defer { if ownsLock { Darwin.close(lockFile) } }
            try regular(lockFile, maximumBytes: Limits.recordBytes)
            guard flock(lockFile, LOCK_EX | LOCK_NB) == 0 else { throw Failure.ownerAlreadyOpen }
            try Task.checkCancellation()
            try removeAbandonedTemporaries(in: directory)
            let journal = SelfRenewalTransactionJournal(root: root, directory: directory, lockFile: lockFile)
            ownsDirectory = false; ownsLock = false
            return journal
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    func load() throws -> Snapshot? {
        let started = SourcePerfTrace.now
        defer { SourcePerfTrace.record("renewal.transaction.load", "limit=\(Limits.recordBytes) main=\(Thread.isMainThread)", since: started, thresholdMs: 50) }
        guard !closed else { throw Failure.storageIO }
        let descriptor = openat(directory, "transaction.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw Failure.storageIO
        }
        defer { Darwin.close(descriptor) }
        let raw = try readAll(descriptor, maximumBytes: Limits.recordBytes)
        let value = try JSONDecoder().decode(Record.self, from: raw)
        try validate(value)
        return Snapshot(record: value, encodedSHA256: Data(SHA256.hash(data: raw)), owner: owner)
    }

    func create(namespace: UUID, generation: UInt64, originalSHA256: Data, identitySHA256: Data,
        bundleIdentifier: String, bundleVersion: String, at date: Date,
        process: SelfRenewalInstalledMaterialObserver.ProcessIdentity = .current) throws -> Snapshot {
        guard !streamingCandidate, activeRemoteCleanup == nil else { throw Failure.activeTransaction }
        let previous = try load()
        let predecessor: PreviousRetirement?
        if let previous {
            guard previous.record.phase == .retired else { throw Failure.activeTransaction }
            predecessor = PreviousRetirement(try confirmRetirement(previous))
        } else {
            // A name with no checkpoint cannot be assumed to belong to this
            // new transaction. Never silently replace an orphan/foreign file.
            try requireCandidateAbsent()
            predecessor = nil
        }
        var record = Record(schema: 1, id: UUID(), revision: 0, createdAt: date, updatedAt: date,
            materialNamespace: namespace, materialGeneration: generation,
            originalArchiveSHA256: originalSHA256, identitySHA256: identitySHA256,
            bundleIdentifier: bundleIdentifier, bundleVersion: bundleVersion,
            preparationProcessID: process.id,
            phase: .created, candidate: nil, submission: nil, lookupReportedSameVersion: nil,
            installedMaterial: nil, userDataHandoff: nil, userDataRead: nil)
        record.previousRetirement = predecessor
        record.remoteHistory = .neverStarted
        return try publish(record)
    }

    /// A durable pending marker precedes destructive local cleanup. After that
    /// marker is acknowledged, cancellation cannot interrupt the synchronous
    /// admitted cleanup/commit; real I/O errors leave pending state for reopen.
    func retireUnsubmitted(_ expected: Snapshot, reason: RetirementReason, at date: Date) throws -> RetirementReceipt {
        let started = SourcePerfTrace.now
        defer { SourcePerfTrace.record("renewal.transaction.retire", "main=\(Thread.isMainThread)", since: started, thresholdMs: 0) }
        try Task.checkCancellation()
        var value = try current(expected)
        try authorizeRetirement(value, reason: reason)
        value.retirement = Retirement(originalPhase: value.phase, originalRevision: value.revision,
            originalRecordSHA256: expected.encodedSHA256, candidate: value.candidate,
            reason: reason, initiatedAt: date, localCandidateRemoval: nil, completedAt: nil)
        value.phase = .retirementPending
        let pending = try advance(value, at: date)
        return try finishRetirement(pending, at: date)
    }

    /// Actual recovery of the same pending CAS, not a caller-supplied safe Bool.
    /// Also re-syncs a loaded tombstone before acknowledging it or admitting a
    /// successor, including a previous rename whose directory fsync had failed.
    func resumeRetirement(_ expected: Snapshot, at date: Date) throws -> RetirementReceipt {
        let started = SourcePerfTrace.now
        defer { SourcePerfTrace.record("renewal.transaction.retirement.resume", "main=\(Thread.isMainThread)", since: started, thresholdMs: 0) }
        try Task.checkCancellation()
        let value = try current(expected)
        switch value.phase {
        case .retirementPending: return try finishRetirement(expected, at: date)
        case .retired: return try confirmRetirement(expected)
        default: throw Failure.invalidTransition
        }
    }

    private func authorizeRetirement(_ value: Record, reason: RetirementReason) throws {
        guard value.retirement == nil, value.submission == nil, value.lookupReportedSameVersion == nil,
              value.installedMaterial == nil, value.userDataHandoff == nil, value.userDataRead == nil,
              value.revision < UInt64.max - 1 else { throw Failure.retirementNotAuthorized }
        switch value.phase {
        case .created, .signing:
            guard value.candidate == nil, value.remoteHistory != .started,
                  reason == .preparationFailed || reason == .preparationInterrupted else { throw Failure.retirementNotAuthorized }
        case .candidateReady:
            guard value.candidate != nil else { throw Failure.retirementNotAuthorized }
            if value.remoteHistory == .neverStarted {
                guard value.safePreSubmissionCleanup == nil,
                      reason == .preparationFailed || reason == .supersededUnsubmittedCandidate else { throw Failure.retirementNotAuthorized }
            } else {
                guard value.remoteHistory == .started, value.safePreSubmissionCleanup != nil,
                      reason == .authenticatedUploadCleanup else { throw Failure.retirementNotAuthorized }
            }
        default: throw Failure.retirementNotAuthorized
        }
    }

    private func finishRetirement(_ expected: Snapshot, at date: Date) throws -> RetirementReceipt {
        var value = try current(expected)
        guard value.phase == .retirementPending, var retirement = value.retirement,
              value.revision < UInt64.max, date.timeIntervalSinceReferenceDate.isFinite,
              date >= value.updatedAt else { throw Failure.invalidTransition }
        // No suspension or second owner queue. Only the fixed existing owned
        // candidate name is touched; links, directories and foreign modes fail.
        retirement.localCandidateRemoval = try removeOwnedCandidate()
        retirement.completedAt = date
        value.retirement = retirement; value.candidate = nil; value.phase = .retired
        value.revision += 1; value.updatedAt = date
        let retired = try publish(value, checksCancellation: false)
        return try RetirementReceipt(retired)
    }

    private func confirmRetirement(_ expected: Snapshot) throws -> RetirementReceipt {
        let value = try current(expected)
        guard value.phase == .retired else { throw Failure.invalidTransition }
        try requireCandidateAbsent()
        guard fsync(directory) == 0 else { throw Failure.commitDurabilityUnknown }
        return try RetirementReceipt(expected)
    }

    private func requireCandidateAbsent() throws {
        var info = stat()
        if fstatat(directory, "candidate.ipa", &info, AT_SYMLINK_NOFOLLOW) == 0 { throw Failure.invalidCandidate }
        guard errno == ENOENT else { throw Failure.storageIO }
    }

    private func removeOwnedCandidate() throws -> LocalCandidateRemoval {
        var info = stat()
        let removal: LocalCandidateRemoval
        if fstatat(directory, "candidate.ipa", &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
                  info.st_mode & 0o077 == 0, info.st_size >= 0,
                  info.st_size <= Limits.candidateBytes else { throw Failure.storageIO }
            guard unlinkat(directory, "candidate.ipa", 0) == 0 else { throw Failure.storageIO }
            removal = .removed
        } else {
            guard errno == ENOENT else { throw Failure.storageIO }
            removal = .alreadyAbsent
        }
        // Sync even after ENOENT: a prior process may have died after unlink.
        guard fsync(directory) == 0 else { throw Failure.commitDurabilityUnknown }
        return removal
    }

    func beginSigning(_ expected: Snapshot, at date: Date) throws -> Snapshot {
        var value = try current(expected)
        guard value.phase == .created else { throw Failure.invalidTransition }
        value.phase = .signing
        return try advance(value, at: date)
    }

    /// The immutable signed archive is streamed to a fresh owned file, hashed,
    /// fsynced and renamed before the durable record can reference it. No private
    /// signing handle or mutable unpack directory is persisted in this journal.
    func storeCandidate(_ expected: Snapshot, archive: ArchiveInput, at date: Date) async throws -> Snapshot {
        let started = SourcePerfTrace.now
        defer { SourcePerfTrace.record("renewal.transaction.candidate", "bytes=\(archive.byteCount) main=\(Thread.isMainThread)", since: started, thresholdMs: 0) }
        var value = try current(expected)
        guard value.phase == .signing, value.candidate == nil, !streamingCandidate else { throw Failure.invalidTransition }
        guard (1...Limits.candidateBytes).contains(archive.byteCount), archive.sha256.count == 32 else { throw Failure.invalidCandidate }
        streamingCandidate = true
        defer { streamingCandidate = false }
        let temporary = ".candidate-" + UUID().uuidString.lowercased() + ".tmp"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.storageIO }
        var closed = false
        defer {
            if !closed { Darwin.close(descriptor) }
            if unlinkat(directory, temporary, 0) != 0, errno != ENOENT { AppLogger.error("Owned renewal candidate temporary cleanup failed") }
        }
        var hash = SHA256(); var offset = 0
        while offset < archive.byteCount {
            try Task.checkCancellation()
            let count = min(Limits.chunkBytes, archive.byteCount - offset)
            let raw = try await archive.read(offset, count)
            try Task.checkCancellation()
            guard raw.count == count else { throw Failure.invalidCandidate }
            try writeAll(raw, to: descriptor); hash.update(data: raw); offset += count
        }
        guard Data(hash.finalize()) == archive.sha256 else { throw Failure.invalidCandidate }
        _ = try current(expected, duringStream: true)
        guard fsync(descriptor) == 0 else { throw Failure.storageIO }
        closed = true
        guard Darwin.close(descriptor) == 0 else { throw Failure.storageIO }
        try replaceOwned(temporary, named: "candidate.ipa")
        value.candidate = Candidate(byteCount: archive.byteCount, sha256: archive.sha256)
        value.phase = .candidateReady
        return try advance(value, at: date)
    }

    /// Durable ownership of the exact planned path precedes AFC FileOpen.
    func noteUploadIntent(_ expected: Snapshot, intent: Installer.UploadIntent, at date: Date) throws -> Snapshot {
        var value = try current(expected)
        guard value.phase == .candidateReady, let candidate = value.candidate,
              candidate.sha256 == intent.expectedArchiveSHA256, candidate.byteCount == intent.expectedArchiveBytes,
              value.bundleIdentifier == intent.bundleIdentifier, value.bundleVersion == intent.bundleVersion else { throw Failure.invalidTransition }
        value.submission = Submission(remotePackagePath: intent.remotePackagePath, deviceCertificateSHA256: intent.deviceCertificateSHA256)
        value.remoteHistory = .started; value.safePreSubmissionCleanup = nil
        value.phase = .uploadIntent
        return try advance(value, at: date)
    }

    /// Called by the real install client's before-first-Upgrade-byte hook.
    func noteUpgradeIntent(_ expected: Snapshot, submission: Installer.UpgradeSubmission, at date: Date,
        handoff: SelfRenewalUserDataHandoff.Receipt? = nil) throws -> Snapshot {
        var value = try current(expected)
        guard value.phase == .uploadIntent, let candidate = value.candidate, let planned = value.submission,
              candidate.sha256 == submission.archiveSHA256, candidate.byteCount == submission.uploadedBytes,
              value.bundleIdentifier == submission.bundleIdentifier, value.bundleVersion == submission.bundleVersion,
              planned.deviceCertificateSHA256 == submission.deviceCertificateSHA256,
              planned.remotePackagePath == submission.remotePackagePath else { throw Failure.invalidTransition }
        value.userDataHandoff = try handoff.map(UserDataCheckpoint.init)
        value.phase = .upgradeIntent
        return try advance(value, at: date)
    }

    func noteTransportReceipt(_ expected: Snapshot, receipt: Installer.Receipt, at date: Date) throws -> Snapshot {
        var value = try current(expected)
        guard value.phase == .upgradeIntent, let candidate = value.candidate, let submission = value.submission,
              receipt.archiveSHA256 == candidate.sha256, receipt.uploadedBytes == candidate.byteCount,
              receipt.bundleIdentifier == value.bundleIdentifier, receipt.bundleVersion == value.bundleVersion,
              receipt.submission.remotePackagePath == submission.remotePackagePath,
              receipt.installationAuthentication.peerCertificateSHA256 == submission.deviceCertificateSHA256 else { throw Failure.invalidTransition }
        value.phase = .receiptObserved; value.lookupReportedSameVersion = true
        return try advance(value, at: date)
    }

    func noteSubmissionInterruption(_ expected: Snapshot, at date: Date) throws -> Snapshot {
        var value = try current(expected)
        guard value.phase == .upgradeIntent else { throw Failure.invalidTransition }
        value.phase = .installationUnknown
        return try advance(value, at: date)
    }

    /// Accepts only the observer's actual Bundle.main verification result.
    /// Does not erase an uncertain Upgrade, authorize remote deletion or assert
    /// that the kernel ran the new image or that user files survived an install.
    func noteCurrentProcessMaterial(_ expected: Snapshot,
        observation: SelfRenewalInstalledMaterialObserver.CurrentProcessObservation, at date: Date) throws -> Snapshot {
        var value = try current(expected)
        guard [.upgradeIntent, .installationUnknown, .receiptObserved, .lookupObserved].contains(value.phase),
              value.submission != nil, let candidate = value.candidate,
              observation.match.candidateArchiveSHA256 == candidate.sha256,
              observation.match.candidateArchiveBytes == candidate.byteCount,
              observation.match.bundleIdentifier == value.bundleIdentifier,
              observation.match.bundleVersion == value.bundleVersion,
              observation.match.authenticatedMaterialSHA256.count == 32,
              observation.observedAt >= value.createdAt, date >= observation.observedAt else { throw Failure.invalidTransition }
        if let old = value.installedMaterial, old.processID == observation.process.id,
           old.authenticatedMaterialSHA256 == observation.match.authenticatedMaterialSHA256,
           old.candidateArchiveSHA256 == candidate.sha256 { return expected }
        value.installedMaterial = InstalledMaterialObservation(candidateArchiveSHA256: candidate.sha256,
            authenticatedMaterialSHA256: observation.match.authenticatedMaterialSHA256,
            processID: observation.process.id, observedAt: observation.observedAt)
        return try advance(value, at: date)
    }

    /// The proof can only come from normal App file owners and actual checked
    /// position reads. Neither a version Lookup nor a supplied file hash fits.
    func noteNormalUserDataRead(_ expected: Snapshot,
        observation: SelfRenewalUserDataHandoff.NormalLoadObservation, at date: Date) throws -> Snapshot {
        var value = try current(expected)
        guard let handoff = value.userDataHandoff, handoff == observation.expected,
              [.upgradeIntent, .installationUnknown, .receiptObserved, .lookupObserved].contains(value.phase),
              observation.books.phase == .normalLoad,
              observation.books.files.map(\.role) == [.shelf, .reading],
              observation.positions.count == handoff.positions.count,
              observation.observedAt >= handoff.capturedAt, date >= observation.observedAt else { throw Failure.invalidTransition }
        if value.userDataRead?.processID == observation.processID { return expected }
        var files = try observation.books.files.map { file in
            UserDataCheckpoint.File(role: file.role.rawValue, operation: file.operation.rawValue,
                rawSHA256: try file.rawSHA256.map(UserDataCheckpoint.decodeHash), rawByteCount: file.rawByteCount)
        }
        let sourceOperation: String
        switch observation.sources.operation {
        case .normalFileRead: sourceOperation = "normalFileRead"
        case .normalMissingFile: sourceOperation = "normalMissingFile"
        case .normalBootstrapWrite: sourceOperation = "normalBootstrapWrite"
        case .atomicWriteCompleted: throw Failure.invalidTransition
        }
        files.append(.init(role: "sources", operation: sourceOperation,
            rawSHA256: observation.sources.rawSHA256, rawByteCount: observation.sources.rawByteCount))
        let positions = zip(handoff.positions, observation.positions).map { pair in
            UserDataReadObservation.Position(bookID: pair.0.bookID, position: pair.1?.position,
                rawSHA256: pair.1?.rawSHA256, rawByteCount: pair.1?.rawByteCount ?? 0)
        }
        value.userDataRead = UserDataReadObservation(processID: observation.processID,
            observedAt: observation.observedAt, files: files, positions: positions,
            selectedFilesMatch: observation.selectedFilesMatch,
            sourceWasBootstrapped: observation.sources.operation == .normalBootstrapWrite)
        return try advance(value, at: date)
    }

    /// The journal owns this grant across the actual fresh network operation.
    /// An old upload snapshot cannot authorize deletion after Upgrade commits.
    func acquireRemoteCleanup(_ expected: Snapshot) throws -> RemoteCleanupGrant {
        let value = try current(expected)
        guard value.candidate != nil, value.submission != nil else { throw Failure.invalidTransition }
        let disposition: RemoteCleanupGrant.Disposition
        switch value.phase {
        case .uploadIntent: disposition = .safeBeforeSubmission
        case .receiptObserved: disposition = .reportedComplete
        case .upgradeIntent, .installationUnknown, .lookupObserved: disposition = .unknownSubmission
        default: throw Failure.invalidTransition
        }
        let grant = RemoteCleanupGrant(snapshot: expected, disposition: disposition)
        activeRemoteCleanup = grant.id
        return grant
    }

    func releaseRemoteCleanup(_ grant: RemoteCleanupGrant) throws {
        if activeRemoteCleanup == nil, grant.snapshot.owner == owner { return }
        guard activeRemoteCleanup == grant.id, grant.snapshot.owner == owner else { throw Failure.staleSnapshot }
        activeRemoteCleanup = nil
    }

    /// Only the actual recovery implementation can construct Outcome. Cleanup
    /// publication and releasing its exclusion slot happen in one actor turn.
    func completeRemoteCleanup(_ grant: RemoteCleanupGrant, outcome: SelfRenewalInstallationRecovery.Outcome,
        at date: Date) throws -> Snapshot {
        guard activeRemoteCleanup == grant.id else { throw Failure.staleSnapshot }
        defer { activeRemoteCleanup = nil }
        var value = try current(grant.snapshot, duringCleanup: true)
        guard outcome.grantID == grant.id, outcome.remotePackagePath == grant.remotePackagePath,
              outcome.deviceCertificateSHA256 == grant.deviceCertificateSHA256,
              outcome.stopSessionAcknowledged else { throw Failure.invalidTransition }
        switch grant.disposition {
        case .safeBeforeSubmission:
            guard outcome.removalVerified, outcome.lookup == nil, value.phase == .uploadIntent else { throw Failure.invalidTransition }
            value.safePreSubmissionCleanup = try SafePreSubmissionCleanup(grant: grant, outcome: outcome, at: date)
            value.remoteHistory = .started
            value.phase = .candidateReady; value.submission = nil
        case .reportedComplete:
            guard outcome.removalVerified, outcome.lookup == nil, value.phase == .receiptObserved else { throw Failure.invalidTransition }
        case .unknownSubmission:
            guard !outcome.removalVerified, let lookup = outcome.lookup,
                  lookup.installationAuthentication.peerCertificateSHA256 == grant.deviceCertificateSHA256 else { throw Failure.invalidTransition }
            value.phase = .lookupObserved
            value.lookupReportedSameVersion = lookup.presence == .reported(bundleIdentifier: value.bundleIdentifier, bundleVersion: value.bundleVersion)
        }
        return try advance(value, at: date)
    }

    func candidateURL(_ expected: Snapshot) throws -> URL {
        let value = try current(expected)
        guard value.candidate != nil else { throw Failure.invalidCandidate }
        // This private owner URL is for re-running the existing IPA verifier.
        // Installer input remains chunked reads bound to candidateSHA256.
        return rootURL.appendingPathComponent("candidate.ipa")
    }

    func readCandidate(_ expected: Snapshot, at offset: Int, count: Int) throws -> Data {
        let value = try current(expected)
        guard let candidate = value.candidate, offset >= 0, count >= 0,
              count <= Limits.chunkBytes, offset <= candidate.byteCount,
              count <= candidate.byteCount - offset else { throw Failure.invalidCandidate }
        let descriptor = openat(directory, "candidate.ipa", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.storageIO }
        defer { Darwin.close(descriptor) }
        try Self.regular(descriptor, maximumBytes: Limits.candidateBytes)
        var info = stat(); guard fstat(descriptor, &info) == 0, info.st_size == candidate.byteCount else { throw Failure.invalidCandidate }
        var raw = Data(count: count)
        let read = raw.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, count, off_t(offset)) }
        guard read == count else { throw Failure.storageIO }
        return raw
    }

    private func current(_ expected: Snapshot, duringStream: Bool = false, duringCleanup: Bool = false) throws -> Record {
        guard !streamingCandidate || duringStream else { throw Failure.activeTransaction }
        guard activeRemoteCleanup == nil || duringCleanup else { throw Failure.activeTransaction }
        guard expected.owner == owner, let actual = try load(), actual.record == expected.record,
              actual.encodedSHA256 == expected.encodedSHA256 else { throw Failure.staleSnapshot }
        return actual.record
    }
    private func advance(_ input: Record, at date: Date) throws -> Snapshot {
        var value = input
        guard value.revision < UInt64.max, date >= value.updatedAt else { throw Failure.invalidTransition }
        value.revision += 1; value.updatedAt = date
        return try publish(value)
    }
    private func validate(_ value: Record) throws {
        guard value.schema == 1, value.originalArchiveSHA256.count == 32, value.identitySHA256.count == 32,
              !value.bundleIdentifier.isEmpty, value.bundleIdentifier.utf8.count <= 255,
              !value.bundleVersion.isEmpty, value.bundleVersion.utf8.count <= 64,
              value.createdAt.timeIntervalSinceReferenceDate.isFinite,
              value.updatedAt.timeIntervalSinceReferenceDate.isFinite, value.updatedAt >= value.createdAt else { throw Failure.malformedRecord }
        if let previous = value.previousRetirement {
            guard previous.transactionID != value.id, previous.revision >= 2, previous.recordSHA256.count == 32,
                  previous.retiredAt.timeIntervalSinceReferenceDate.isFinite,
                  previous.retiredAt <= value.createdAt else { throw Failure.malformedRecord }
        }
        if value.remoteHistory == .neverStarted {
            guard value.submission == nil, value.safePreSubmissionCleanup == nil,
                  ![.uploadIntent, .upgradeIntent, .installationUnknown, .receiptObserved, .lookupObserved].contains(value.phase) else { throw Failure.malformedRecord }
        }
        if [.created, .signing].contains(value.phase), value.remoteHistory == .started { throw Failure.malformedRecord }
        if let cleanup = value.safePreSubmissionCleanup {
            guard let originalCandidate = value.retirement?.candidate ?? value.candidate,
                  [.candidateReady, .retirementPending, .retired].contains(value.phase),
                  value.remoteHistory == .started, cleanup.candidate == originalCandidate,
                  cleanup.submission.deviceCertificateSHA256.count == 32,
                  cleanup.completedAt.timeIntervalSinceReferenceDate.isFinite,
                  cleanup.completedAt >= value.createdAt, cleanup.completedAt <= value.updatedAt,
                  ["removedAcknowledged", "alreadyAbsentAcknowledged"].contains(cleanup.removal),
                  value.submission == nil, value.lookupReportedSameVersion == nil else { throw Failure.malformedRecord }
            do { try SelfRenewalInstallationRecovery.validateOwnedPath(cleanup.submission.remotePackagePath) }
            catch { throw Failure.malformedRecord }
        }
        if value.phase == .candidateReady, value.remoteHistory == .started,
           value.safePreSubmissionCleanup == nil { throw Failure.malformedRecord }
        if let retirement = value.retirement {
            guard [.retirementPending, .retired].contains(value.phase),
                  retirement.originalRecordSHA256.count == 32,
                  retirement.originalRevision < UInt64.max - 1,
                  retirement.initiatedAt.timeIntervalSinceReferenceDate.isFinite,
                  retirement.initiatedAt >= value.createdAt, retirement.initiatedAt <= value.updatedAt,
                  value.submission == nil, value.lookupReportedSameVersion == nil,
                  value.installedMaterial == nil, value.userDataHandoff == nil, value.userDataRead == nil else { throw Failure.malformedRecord }
            if let candidate = retirement.candidate {
                guard (1...Limits.candidateBytes).contains(candidate.byteCount), candidate.sha256.count == 32 else { throw Failure.malformedRecord }
            }
            // Re-run the same authorization against the committed original
            // facts; no weak "safe" field or version observation is accepted.
            var original = value
            original.phase = retirement.originalPhase; original.candidate = retirement.candidate
            original.revision = retirement.originalRevision; original.retirement = nil
            do { try authorizeRetirement(original, reason: retirement.reason) }
            catch { throw Failure.malformedRecord }
            switch value.phase {
            case .retirementPending:
                guard value.revision == retirement.originalRevision + 1,
                      value.candidate == retirement.candidate, value.updatedAt == retirement.initiatedAt,
                      retirement.localCandidateRemoval == nil, retirement.completedAt == nil else { throw Failure.malformedRecord }
            case .retired:
                guard value.revision == retirement.originalRevision + 2, value.candidate == nil,
                      retirement.localCandidateRemoval != nil, let completed = retirement.completedAt,
                      completed.timeIntervalSinceReferenceDate.isFinite,
                      completed >= retirement.initiatedAt, completed == value.updatedAt else { throw Failure.malformedRecord }
            default: throw Failure.malformedRecord
            }
        } else if [.retirementPending, .retired].contains(value.phase) { throw Failure.malformedRecord }
        if let candidate = value.candidate {
            guard (1...Limits.candidateBytes).contains(candidate.byteCount), candidate.sha256.count == 32 else { throw Failure.malformedRecord }
        }
        if let submission = value.submission {
            let prefix = "PublicStaging/reader-renewal-", suffix = ".ipa"
            guard submission.deviceCertificateSHA256.count == 32,
                  submission.remotePackagePath.hasPrefix(prefix), submission.remotePackagePath.hasSuffix(suffix),
                  let id = UUID(uuidString: String(submission.remotePackagePath.dropFirst(prefix.count).dropLast(suffix.count))),
                  submission.remotePackagePath == prefix + id.uuidString.lowercased() + suffix else { throw Failure.malformedRecord }
        }
        if let observed = value.installedMaterial {
            guard [.upgradeIntent, .installationUnknown, .receiptObserved, .lookupObserved].contains(value.phase),
                  value.submission != nil, observed.candidateArchiveSHA256.count == 32,
                  observed.candidateArchiveSHA256 == value.candidate?.sha256,
                  observed.authenticatedMaterialSHA256.count == 32,
                  observed.observedAt.timeIntervalSinceReferenceDate.isFinite,
                  observed.observedAt >= value.createdAt, observed.observedAt <= value.updatedAt else { throw Failure.malformedRecord }
        }
        if let handoff = value.userDataHandoff {
            guard [.upgradeIntent, .installationUnknown, .receiptObserved, .lookupObserved].contains(value.phase),
                  value.submission != nil, handoff.capturedAt.timeIntervalSinceReferenceDate.isFinite,
                  handoff.capturedAt >= value.createdAt, handoff.capturedAt <= value.updatedAt,
                  handoff.sourceCount >= 0, handoff.sourceMutationRevision >= 0,
                  handoff.files.map(\.role) == ["shelf", "reading", "sources"],
                  handoff.positions.count <= 8,
                  Set(handoff.positions.map(\.bookID)).count == handoff.positions.count else { throw Failure.malformedRecord }
            for file in handoff.files {
                guard file.rawByteCount >= 0 else { throw Failure.malformedRecord }
                if file.role == "sources" {
                    guard file.operation == "atomicWriteCompleted", file.rawByteCount > 0,
                          file.rawSHA256?.count == 32 else { throw Failure.malformedRecord }
                } else if file.operation == "absent" {
                    guard file.rawByteCount == 0, file.rawSHA256 == nil else { throw Failure.malformedRecord }
                } else {
                    guard ["written", "unchanged"].contains(file.operation),
                          file.rawSHA256?.count == 32 else { throw Failure.malformedRecord }
                }
            }
            for position in handoff.positions {
                guard !position.bookID.isEmpty, position.bookID.utf8.count <= 128,
                      !position.bookID.contains("/"), !position.bookID.contains("\\"),
                      !position.bookID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                      position.rawSHA256.count == 32, (1...4096).contains(position.rawByteCount),
                      position.position.spineIndex >= 0, position.position.charOffset >= 0,
                      position.position.translationOffset.map({ $0 >= 0 }) ?? true else { throw Failure.malformedRecord }
            }
        }
        if let read = value.userDataRead {
            guard let handoff = value.userDataHandoff,
                  read.observedAt.timeIntervalSinceReferenceDate.isFinite,
                  read.observedAt >= handoff.capturedAt, read.observedAt <= value.updatedAt,
                  read.files.map(\.role) == ["shelf", "reading", "sources"],
                  read.positions.map(\.bookID) == handoff.positions.map(\.bookID),
                  !read.sourceWasBootstrapped || !read.selectedFilesMatch else { throw Failure.malformedRecord }
            for file in read.files {
                guard file.rawByteCount >= 0 else { throw Failure.malformedRecord }
                let allowed = file.role == "sources" ? ["normalFileRead", "normalMissingFile", "normalBootstrapWrite"] : ["read", "absent"]
                guard allowed.contains(file.operation) else { throw Failure.malformedRecord }
                let missing = file.operation == "absent" || file.operation == "normalMissingFile"
                if missing {
                    guard file.rawByteCount == 0, file.rawSHA256 == nil else { throw Failure.malformedRecord }
                } else {
                    guard ["read", "normalFileRead", "normalBootstrapWrite"].contains(file.operation),
                          file.rawSHA256?.count == 32 else { throw Failure.malformedRecord }
                }
            }
            for position in read.positions {
                if let actual = position.position {
                    guard actual.spineIndex >= 0, actual.charOffset >= 0,
                          actual.translationOffset.map({ $0 >= 0 }) ?? true,
                          position.rawSHA256?.count == 32, (1...4096).contains(position.rawByteCount) else { throw Failure.malformedRecord }
                } else {
                    guard position.rawSHA256 == nil, position.rawByteCount == 0 else { throw Failure.malformedRecord }
                }
            }
            let filesMatch = zip(handoff.files, read.files).allSatisfy { pair in
                let operationMatches = pair.1.role == "sources" ? pair.1.operation == "normalFileRead" : ["read", "absent"].contains(pair.1.operation)
                return operationMatches && pair.0.role == pair.1.role
                    && pair.0.rawSHA256 == pair.1.rawSHA256 && pair.0.rawByteCount == pair.1.rawByteCount
            }
            let positionsMatch = zip(handoff.positions, read.positions).allSatisfy { pair in
                pair.0.bookID == pair.1.bookID && pair.0.position == pair.1.position
                    && pair.0.rawSHA256 == pair.1.rawSHA256 && pair.0.rawByteCount == pair.1.rawByteCount
            }
            guard read.selectedFilesMatch == (filesMatch && positionsMatch),
                  read.sourceWasBootstrapped == (read.files.last?.operation == "normalBootstrapWrite") else { throw Failure.malformedRecord }
        }
        switch value.phase {
        case .created, .signing:
            guard value.candidate == nil, value.submission == nil, value.lookupReportedSameVersion == nil else { throw Failure.malformedRecord }
        case .candidateReady:
            guard value.candidate != nil, value.submission == nil, value.lookupReportedSameVersion == nil else { throw Failure.malformedRecord }
        case .uploadIntent, .upgradeIntent, .installationUnknown:
            guard value.candidate != nil, value.submission != nil, value.lookupReportedSameVersion == nil else { throw Failure.malformedRecord }
        case .receiptObserved:
            guard value.candidate != nil, value.submission != nil, value.lookupReportedSameVersion == true else { throw Failure.malformedRecord }
        case .lookupObserved:
            guard value.candidate != nil, value.submission != nil, value.lookupReportedSameVersion != nil else { throw Failure.malformedRecord }
        case .attentionRequired:
            guard value.lookupReportedSameVersion == nil || value.submission != nil else { throw Failure.malformedRecord }
        case .retirementPending, .retired:
            guard value.retirement != nil, value.submission == nil, value.lookupReportedSameVersion == nil else { throw Failure.malformedRecord }
        }
    }
    private func publish(_ record: Record, checksCancellation: Bool = true) throws -> Snapshot {
        let started = SourcePerfTrace.now
        defer { SourcePerfTrace.record("renewal.transaction.commit", "phase=\(record.phase.rawValue) main=\(Thread.isMainThread)", since: started, thresholdMs: 0) }
        if checksCancellation { try Task.checkCancellation() }
        try validate(record)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let raw = try encoder.encode(record)
        guard raw.count <= Limits.recordBytes else { throw Failure.limit }
        let temporary = ".journal-" + UUID().uuidString.lowercased() + ".tmp"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.storageIO }
        var closed = false
        defer {
            if !closed { Darwin.close(descriptor) }
            if unlinkat(directory, temporary, 0) != 0, errno != ENOENT { AppLogger.error("Owned renewal journal temporary cleanup failed") }
        }
        try writeAll(raw, to: descriptor, checksCancellation: checksCancellation)
        guard fsync(descriptor) == 0 else { throw Failure.storageIO }
        if checksCancellation { try Task.checkCancellation() }
        closed = true
        guard Darwin.close(descriptor) == 0 else { throw Failure.storageIO }
        try replaceOwned(temporary, named: "transaction.json")
        // A synchronous successful commit is acknowledged even if cancellation
        // arrives now. No error pretends the accepted rename was rolled back.
        return Snapshot(record: record, encodedSHA256: Data(SHA256.hash(data: raw)), owner: owner)
    }
    private func replaceOwned(_ temporary: String, named target: String) throws {
        var previous = stat()
        if fstatat(directory, target, &previous, AT_SYMLINK_NOFOLLOW) == 0 {
            guard previous.st_mode & S_IFMT == S_IFREG, previous.st_nlink == 1, previous.st_uid == getuid() else { throw Failure.storageIO }
        } else if errno != ENOENT { throw Failure.storageIO }
        guard renameat(directory, temporary, directory, target) == 0 else { throw Failure.storageIO }
        guard fsync(directory) == 0 else { throw Failure.commitDurabilityUnknown }
    }
    private static func regular(_ descriptor: Int32, maximumBytes: Int) throws {
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_uid == getuid(), value.st_nlink == 1, value.st_mode & 0o077 == 0,
              value.st_size >= 0, value.st_size <= maximumBytes else { throw Failure.storageIO }
    }
    /// Only after the exclusive owner lock: reclaim names generated by this
    /// journal before a previous process died. Scan this dedicated directory
    /// with a fixed entry budget, never the user's library or an imported path.
    private static func removeAbandonedTemporaries(in directory: Int32) throws {
        let duplicate = dup(directory)
        guard duplicate >= 0 else { throw Failure.storageIO }
        guard let iterator = fdopendir(duplicate) else { Darwin.close(duplicate); throw Failure.storageIO }
        defer { closedir(iterator) }
        var entries = 0; var removed = false
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(iterator) else {
                guard errno == 0 else { throw Failure.storageIO }
                break
            }
            entries += 1; guard entries <= 256 else { throw Failure.limit }
            let length = Int(entry.pointee.d_namlen)
            guard length > 0, length <= 255 else { throw Failure.storageIO }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: length + 1) { String(cString: $0) }
            }
            if [".", "..", ".owner.lock", "transaction.json", "candidate.ipa"].contains(name) { continue }
            guard let prefix = [".journal-", ".candidate-"].first(where: { name.hasPrefix($0) }), name.hasSuffix(".tmp"),
                  let identifier = UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(4))),
                  name == prefix + identifier.uuidString.lowercased() + ".tmp" else { throw Failure.invalidDirectory }
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
                  info.st_nlink == 1, info.st_mode & 0o077 == 0,
                  info.st_size >= 0, info.st_size <= Limits.candidateBytes else { throw Failure.storageIO }
            guard unlinkat(directory, name, 0) == 0 else { throw Failure.storageIO }
            removed = true
        }
        if removed, fsync(directory) != 0 { throw Failure.commitDurabilityUnknown }
    }
    private func readAll(_ descriptor: Int32, maximumBytes: Int) throws -> Data {
        try Self.regular(descriptor, maximumBytes: maximumBytes)
        var before = stat(); guard fstat(descriptor, &before) == 0 else { throw Failure.storageIO }
        var raw = Data(count: Int(before.st_size))
        let count = raw.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        var after = stat()
        guard count == raw.count, fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw Failure.storageIO }
        return raw
    }
    private func writeAll(_ raw: Data, to descriptor: Int32, checksCancellation: Bool = true) throws {
        try raw.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                if checksCancellation { try Task.checkCancellation() }
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                guard count > 0 else { throw Failure.storageIO }
                offset += count
            }
        }
    }
}
