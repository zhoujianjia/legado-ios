import CryptoKit
import Darwin
import Foundation
import Testing
@testable import yuedu_app

struct SelfRenewalInstallationRecoveryTests {
    typealias Fixture = SelfRenewalAuthenticatedInstallationFixture
    typealias Recovery = SelfRenewalInstallationRecovery
    typealias Journal = SelfRenewalTransactionJournal
    typealias Client = SelfRenewalAuthenticatedInstallationClient
    typealias Transport = SelfRenewalAuthenticatedDeviceTransport
    enum TestFailure: Error, Equatable { case expectedFailure, originalInstallation, filesystem }

    @Test
    func removesPersistedOwnedUploadAfterFreshMutualTLSAndClearsJournalPhase() async throws {
        try await Fixture.withPeer(.partialUploadThenRecover) { c in
            try await Self.withJournal(c) { journal, state, root in
                let original = try await Self.interrupt(c, state: state, partial: false)
                let failure = try #require(original as? Client.OperationFailure)
                #expect(!failure.upgradeMayHaveExecuted)
                let before = await state.value()
                #expect(before.record.phase == .uploadIntent)
                try await journal.close()
                let reopened = try await Journal.open(at: root)
                do {
                    let loadedRecord1 = try await reopened.load()
                    let restored = try #require(loadedRecord1)
                    let outcome = try await Recovery.cleanup(journal: reopened, expected: restored, pairing: c.pairing,
                        lockdownEndpoint: c.endpoint, at: c.date, originalOperationError: failure)
                    #expect(outcome.removal == .removedAcknowledged && outcome.stopSessionAcknowledged)
                    #expect(outcome.afcChannelReleasedLocally && outcome.lockdownChannelReleasedLocally)
                    #expect(outcome.fileCloseAcknowledgement == .noRemoteFileOpenedInRecovery)
                    #expect(!outcome.selfRenewalVerified && !outcome.samePhysicalDeviceVerified && !outcome.noVPNRouteVerified)
                    let loadedRecord2 = try await reopened.load()
                    let saved = try #require(loadedRecord2)
                    #expect(saved.record.phase == .candidateReady && saved.record.submission == nil)
                    let o = c.observed.snapshot
                    #expect(o.uploaded.count == 65_536 && o.openedFileHandles == 1 && o.closedFileHandles == 0)
                    #expect(o.upgradeRequests == 0 && o.lookupRequests == 0 && o.removedPaths.count == 1)
                    #expect(o.authenticatedChannels == 5 && o.stoppedSessions == ["owned-recovery-session"])
                    try await reopened.close()
                } catch { try await reopened.close(); throw error }
            }
        }
        try await Fixture.withPeer(.cleanupAfterReportedComplete) { c in
            try await Self.withJournal(c) { journal, state, _ in
                let receipt = try await c.upgrade(beforeCreation: { try await state.plan($0) }, beforeSubmission: { try await state.submit($0) })
                try await state.receipt(receipt)
                let expected = await state.value()
                let result = try await Recovery.cleanup(journal: journal, expected: expected, pairing: c.pairing,
                    lockdownEndpoint: c.endpoint, at: c.date)
                #expect(result.removal == .alreadyAbsentAcknowledged)
                let loadedRecord3 = try await journal.load()
                let saved = try #require(loadedRecord3)
                #expect(saved.record.phase == .receiptObserved)
                #expect(c.observed.snapshot.upgradeRequests == 1 && c.observed.snapshot.openedFileHandles == 1)
            }
        }
    }

    @Test
    func acceptsActualMissingACKAndRetainsRemovalWhenStopDisconnects() async throws {
        for mode: Fixture.Mode in [.cleanupAlreadyAbsent, .cleanupStopDisconnectThenRetry] {
            try await Fixture.withPeer(mode) { c in
                try await Self.withJournal(c) { journal, state, _ in
                    _ = try await Self.interrupt(c, state: state)
                    let expected = await state.value()
                    if mode == .cleanupStopDisconnectThenRetry {
                        let error = await Self.rejected {
                            try await Recovery.cleanup(journal: journal, expected: expected, pairing: c.pairing,
                                lockdownEndpoint: c.endpoint, at: c.date)
                        }
                        let failure = try #require(error as? Recovery.RecoveryFailure)
                        #expect(failure.removal == .removedAcknowledged && !failure.stopSessionAcknowledged)
                        #expect(failure.grantReleaseError == nil && failure.networkOutcome == nil)
                        let loadedRecord4 = try await journal.load()
                        let unchanged = try #require(loadedRecord4)
                        #expect(unchanged.record == expected.record)
                    }
                    let result = try await Recovery.cleanup(journal: journal, expected: expected, pairing: c.pairing,
                        lockdownEndpoint: c.endpoint, at: c.date)
                    #expect(result.removal == .alreadyAbsentAcknowledged && result.stopSessionAcknowledged)
                    #expect(c.observed.snapshot.upgradeRequests == 0 && c.observed.snapshot.openedFileHandles == 1)
                }
            }
        }
    }

    @Test
    func retainsUnknownSubmittedUpgradeAndUsesOnlyAuthenticatedLookup() async throws {
        for mode: Fixture.Mode in [.disconnectAfterUpgradeThenRecover, .disconnectAfterUpgradeThenLookupMissing] {
            try await Fixture.withPeer(mode) { c in
                try await Self.withJournal(c) { journal, state, root in
                    let error = await Self.rejected {
                        try await c.upgrade(beforeCreation: { try await state.plan($0) }, beforeSubmission: { try await state.submit($0) })
                    }
                    let failure = try #require(error as? Client.OperationFailure)
                    #expect(failure.upgradeMayHaveExecuted)
                    try await journal.close()
                    let reopened = try await Journal.open(at: root)
                    do {
                        let loadedRecord5 = try await reopened.load()
                        let expected = try #require(loadedRecord5)
                        let result = try await Recovery.cleanup(journal: reopened, expected: expected, pairing: c.pairing,
                            lockdownEndpoint: c.endpoint, at: c.date, originalOperationError: failure)
                        #expect(result.retainedForUnknownSubmission && !result.removalVerified)
                        #expect(result.stopSessionAcknowledged && !result.afcChannelReleasedLocally)
                        let observed = try #require(result.lookup)
                        let wanted: Client.LookupObservation.Presence = mode == .disconnectAfterUpgradeThenLookupMissing
                            ? .notFound : .reported(bundleIdentifier: c.bundle, bundleVersion: c.version)
                        #expect(observed.presence == wanted)
                        let loadedRecord6 = try await reopened.load()
                        let saved = try #require(loadedRecord6)
                        #expect(saved.record.phase == .lookupObserved && saved.record.submission == expected.record.submission)
                        #expect(c.observed.snapshot.upgradeRequests == 1 && c.observed.snapshot.lookupRequests == 1)
                        #expect(c.observed.snapshot.removeAttempts == 0 && c.observed.snapshot.authenticatedChannels == 5)
                        try await reopened.close()
                    } catch { try await reopened.close(); throw error }
                }
            }
        }
    }

    @Test
    func rejectsStaleMalformedAndWrongDeviceGrantsBeforeAnyRemoval() async throws {
        try await Fixture.withPeer(.cleanupAfterInterruptedUpload) { c in
            try await Self.withJournal(c) { journal, state, root in
                let stale = await state.value()
                _ = try await Self.interrupt(c, state: state)
                let expected = await state.value()
                let staleError = await Self.rejected {
                    try await Recovery.cleanup(journal: journal, expected: stale, pairing: c.pairing, lockdownEndpoint: c.endpoint, at: c.date)
                }
                #expect((staleError as? Recovery.RecoveryFailure)?.underlying as? Journal.Failure == .staleSnapshot)
                let wrong = try Transport.PairingIdentity(hostIdentity: c.pairing.hostIdentity,
                    deviceCertificateDER: c.wrongDeviceCertificateDER, rootCertificateDER: c.pairing.rootCertificateDER,
                    hostID: c.pairing.hostID, systemBUID: c.pairing.systemBUID)
                let wrongError = await Self.rejected {
                    try await Recovery.cleanup(journal: journal, expected: expected, pairing: wrong, lockdownEndpoint: c.endpoint, at: c.date)
                }
                #expect((wrongError as? Recovery.RecoveryFailure)?.underlying as? Recovery.Failure == .wrongDevice)
                // An on-disk record is not delete authority just because its JSON
                // and UUID syntax decode. No Grant or Outcome is constructed here.
                let recordURL = root.appendingPathComponent("transaction.json")
                let original = try Data(contentsOf: recordURL)
                let submission = try #require(expected.record.submission)
                var changed = expected.record
                changed.submission = Journal.Submission(remotePackagePath: "PublicStaging/reader-renewal-00000000-0000-1000-8000-000000000000.ipa",
                    deviceCertificateSHA256: submission.deviceCertificateSHA256)
                try Self.replaceRecord(try JSONEncoder().encode(changed), at: recordURL)
                do {
                    let loadedRecord7 = try await journal.load()
                    let forged = try #require(loadedRecord7)
                    let malformed = await Self.rejected {
                        try await Recovery.cleanup(journal: journal, expected: forged, pairing: c.pairing, lockdownEndpoint: c.endpoint, at: c.date)
                    }
                    #expect((malformed as? Recovery.RecoveryFailure)?.underlying as? Recovery.Failure == .invalidOwnedPath)
                    try Self.replaceRecord(original, at: recordURL)
                } catch { try Self.replaceRecord(original, at: recordURL); throw error }
                #expect(c.observed.snapshot.removeAttempts == 0 && c.observed.snapshot.authenticatedChannels == 3)
                _ = try await Recovery.cleanup(journal: journal, expected: expected, pairing: c.pairing, lockdownEndpoint: c.endpoint, at: c.date)
            }
        }
        try await Fixture.withPeer(.cleanupWrongServerCertificate) { c in
            try await Self.withJournal(c) { journal, state, _ in
                _ = try await Self.interrupt(c, state: state)
                let expected = await state.value()
                let error = await Self.rejected {
                    try await Recovery.cleanup(journal: journal, expected: expected, pairing: c.pairing, lockdownEndpoint: c.endpoint, at: c.date)
                }
                let failure = try #require(error as? Recovery.RecoveryFailure)
                #expect(failure.underlying as? Transport.Failure == .peerMismatch)
                #expect(!failure.removalAcknowledged && c.observed.snapshot.removeAttempts == 0)
            }
        }
    }

    @Test
    func cancellationAndDeadlineReleaseGrantForFreshAuthenticatedRetry() async throws {
        for cancel in [true, false] {
            try await Fixture.withPeer(.cleanupStallThenRetry) { c in
                try await Self.withJournal(c) { journal, state, _ in
                    _ = try await Self.interrupt(c, state: state)
                    let expected = await state.value()
                    let running = Task {
                        try await Recovery.cleanup(journal: journal, expected: expected, pairing: c.pairing,
                            lockdownEndpoint: c.endpoint, at: c.date, timeoutSeconds: cancel ? 8 : 3)
                    }
                    var events = c.recoveryRemoveRequestReceived.makeAsyncIterator()
                    let event = await events.next()
                    if event != true { running.cancel(); _ = await running.result }
                    try #require(event == true)
                    let closeError = await Self.rejected { try await journal.close() }
                    #expect(closeError as? Journal.Failure == .activeTransaction)
                    let grantError = await Self.rejected { try await journal.acquireRemoteCleanup(expected) }
                    #expect(grantError as? Journal.Failure == .activeTransaction)
                    if cancel { running.cancel() }
                    let error = await Self.rejected { try await running.value }
                    let failure = try #require(error as? Recovery.RecoveryFailure)
                    #expect(failure.underlying as? Transport.Failure == (cancel ? .cancelled : .deadlineExceeded))
                    #expect(!failure.removalAcknowledged && failure.grantReleaseError == nil)
                    let result = try await Recovery.cleanup(journal: journal, expected: expected, pairing: c.pairing,
                        lockdownEndpoint: c.endpoint, at: c.date, timeoutSeconds: 8)
                    #expect(result.removal == .removedAcknowledged && result.stopSessionAcknowledged)
                    #expect(c.observed.snapshot.openedFileHandles == 1 && c.observed.snapshot.upgradeRequests == 0)
                }
            }
        }
    }

    @Test
    func keepsOriginalErrorSeparateFromRemoteCleanupAndJournalFailures() async throws {
        try await Fixture.withPeer(.cleanupRemoveDeniedThenRetry) { c in
            try await Self.withJournal(c) { journal, state, _ in
                _ = try await Self.interrupt(c, state: state)
                let expected = await state.value()
                let error = await Self.rejected {
                    try await Recovery.cleanup(journal: journal, expected: expected, pairing: c.pairing, lockdownEndpoint: c.endpoint,
                        at: c.date, originalOperationError: TestFailure.originalInstallation)
                }
                let failure = try #require(error as? Recovery.RecoveryFailure)
                #expect(failure.underlying as? Client.Failure == .afcStatus(10))
                #expect(failure.originalOperationError as? TestFailure == .originalInstallation)
                #expect(!failure.removalAcknowledged && failure.grantReleaseError == nil)
                _ = try await Recovery.cleanup(journal: journal, expected: expected, pairing: c.pairing, lockdownEndpoint: c.endpoint, at: c.date)
            }
        }
        let fault = WriteFault()
        try await Fixture.withPeer(.cleanupAfterInterruptedUpload, beforeRecoveryRemoveReply: { try fault.denyWrite() }) { c in
            try await Self.withJournal(c) { journal, state, root in
                _ = try await Self.interrupt(c, state: state)
                let expected = await state.value()
                fault.arm(root)
                let error = await Self.rejected {
                    try await Recovery.cleanup(journal: journal, expected: expected, pairing: c.pairing, lockdownEndpoint: c.endpoint,
                        at: c.date, originalOperationError: TestFailure.originalInstallation)
                }
                try fault.restore()
                let failure = try #require(error as? Recovery.RecoveryFailure)
                #expect(failure.underlying as? Journal.Failure == .storageIO)
                #expect(failure.originalOperationError as? TestFailure == .originalInstallation)
                #expect(failure.removalAcknowledged && failure.stopSessionAcknowledged && failure.networkOutcome != nil)
                #expect(failure.grantReleaseError == nil)
                let loadedRecord8 = try await journal.load()
                let saved = try #require(loadedRecord8)
                #expect(saved.record == expected.record)
                // Lock release is real even though publication failed.
                let grant = try await journal.acquireRemoteCleanup(saved)
                try await journal.releaseRemoteCleanup(grant)
                #expect(c.observed.snapshot.upgradeRequests == 0 && c.observed.snapshot.removedPaths.count == 1)
            }
        }
    }

    private actor State {
        let journal: Journal
        var snapshot: Journal.Snapshot
        let date: Date
        init(_ journal: Journal, _ snapshot: Journal.Snapshot, at date: Date) { self.journal = journal; self.snapshot = snapshot; self.date = date }
        func value() -> Journal.Snapshot { snapshot }
        func plan(_ intent: Client.UploadIntent) async throws { snapshot = try await journal.noteUploadIntent(snapshot, intent: intent, at: date) }
        func submit(_ submission: Client.UpgradeSubmission) async throws { snapshot = try await journal.noteUpgradeIntent(snapshot, submission: submission, at: date) }
        func receipt(_ receipt: Client.Receipt) async throws { snapshot = try await journal.noteTransportReceipt(snapshot, receipt: receipt, at: date) }
    }
    private static func withJournal(_ context: Fixture.Context,
        _ operation: @escaping @Sendable (Journal, State, URL) async throws -> Void) async throws {
        let parent = try await Task.detached(priority: .utility) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("reader-cleanup-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            return url
        }.value
        let root = parent.appendingPathComponent("SelfRenewalTransactions", isDirectory: true)
        do {
            let journal = try await Journal.open(at: root)
            do {
                var snapshot = try await journal.create(namespace: UUID(), generation: 0, originalSHA256: context.archive.sha256,
                    identitySHA256: Data(SHA256.hash(data: context.pairing.hostCertificateDER)),
                    bundleIdentifier: context.bundle, bundleVersion: context.version, at: context.date)
                snapshot = try await journal.beginSigning(snapshot, at: context.date)
                snapshot = try await journal.storeCandidate(snapshot, archive: Journal.ArchiveInput(byteCount: context.bytes.count,
                    sha256: context.archive.sha256, read: context.archive.read), at: context.date)
                try await operation(journal, State(journal, snapshot, at: context.date), root)
                try await journal.close()
            } catch { try await journal.close(); throw error }
            try await removeOwnedParent(parent)
        } catch { try await removeOwnedParent(parent); throw error }
    }
    private static func removeOwnedParent(_ parent: URL) async throws {
        try await Task.detached(priority: .utility) {
            precondition(!Thread.isMainThread)
            guard parent.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL,
                  parent.lastPathComponent.hasPrefix("reader-cleanup-") else { throw TestFailure.filesystem }
            try FileManager.default.removeItem(at: parent)
        }.value
    }
    private static func interrupt(_ c: Fixture.Context, state: State, partial: Bool = true) async throws -> Error {
        let archive = partial ? Client.ArchiveInput(byteCount: c.bytes.count, sha256: c.archive.sha256) { offset, count in
            if offset > 0 { withUnsafeCurrentTask { $0?.cancel() }; throw CancellationError() }
            return Data(c.bytes[offset..<(offset + count)])
        } : c.archive
        let error = await rejected { try await c.upgrade(archive: archive, beforeCreation: { try await state.plan($0) }) }
        // Recovery checks require a real owned remote intent. A prior TLS or
        // service failure is a failed precondition, not cleanup/delete authority.
        let current = await state.value()
        try #require(current.record.phase == .uploadIntent)
        _ = try #require(current.record.submission)
        return error
    }
    private static func rejected<T>(_ action: () async throws -> T) async -> Error {
        do { _ = try await action(); Issue.record("Expected a rejected real operation"); return TestFailure.expectedFailure }
        catch { return error }
    }
    private static func replaceRecord(_ bytes: Data, at url: URL) throws {
        precondition(!Thread.isMainThread)
        try bytes.write(to: url, options: .atomic)
        guard chmod(url.path, 0o600) == 0 else { throw TestFailure.filesystem }
    }
    private final class WriteFault: @unchecked Sendable {
        let lock = NSLock()
        private var root: URL?
        func arm(_ root: URL) { lock.lock(); defer { lock.unlock() }; self.root = root }
        func denyWrite() throws {
            lock.lock(); defer { lock.unlock() }
            guard let root, chmod(root.path, 0o500) == 0 else { throw TestFailure.filesystem }
        }
        func restore() throws {
            lock.lock(); defer { lock.unlock() }
            guard let root, chmod(root.path, 0o700) == 0 else { throw TestFailure.filesystem }
        }
    }
}
