import CryptoKit
import Darwin
import Foundation
import Testing
@testable import yuedu_app

@Suite("Durable retirement of provably unsubmitted renewals", .serialized)
struct SelfRenewalTransactionRetirementTests {
    typealias Journal = SelfRenewalTransactionJournal
    typealias Coordinator = SelfRenewalControlledRenewalCoordinator
    typealias Package = SelfRenewalControlledPackageSignerTests
    typealias Peer = SelfRenewalAuthenticatedInstallationFixture
    private static let date = Date(timeIntervalSince1970: 1_792_540_800)
    private static let bytes = Data(repeating: 0x53, count: 131_073)

    @Test("actual new-record history permits local retirement and a fixed-size successor commitment")
    func retiresNeverUploadedCandidateAndCreatesOneBoundedSuccessor() async throws {
        try await Self.root { _, root in
            var journal = try await Journal.open(at: root)
            do {
                var ready = try await Self.ready(journal)
                #expect(ready.record.remoteHistory == .neverStarted)
                for _ in 0..<3 {
                    let old = ready
                    let receipt = try await journal.retireUnsubmitted(old, reason: .supersededUnsubmittedCandidate, at: Self.date)
                    #expect(receipt.transactionID == old.record.id && receipt.localCandidateRemoval == .removed)
                    #expect(!receipt.renewalVerified && receipt.safePreSubmissionCleanup == nil)
                    let raw = try Data(contentsOf: root.appendingPathComponent("transaction.json"))
                    #expect(receipt.recordSHA256 == Data(SHA256.hash(data: raw)))
                    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("candidate.ipa").path))
                    try await journal.close()
                    journal = try await Journal.open(at: root)
                    let loaded = try await journal.load(); let retired = try #require(loaded)
                    let confirmed = try await journal.resumeRetirement(retired, at: Self.date)
                    #expect(confirmed.recordSHA256 == receipt.recordSHA256)
                    let next = try await Self.create(journal)
                    #expect(next.record.id != old.record.id)
                    #expect(next.record.previousRetirement?.transactionID == old.record.id)
                    #expect(next.record.previousRetirement?.recordSHA256 == receipt.recordSHA256)
                    #expect(next.record.previousRetirement?.revision == receipt.revision)
                    do { _ = try await journal.beginSigning(old, at: Self.date); Issue.record("Retired/old-owner CAS was accepted") }
                    catch Journal.Failure.staleSnapshot {}
                    let signing = try await journal.beginSigning(next, at: Self.date)
                    ready = try await Self.store(journal, signing)
                    let nextRaw = try Data(contentsOf: root.appendingPathComponent("transaction.json"))
                    let object = try #require(JSONSerialization.jsonObject(with: nextRaw) as? [String: Any])
                    #expect(object["previousRetirement"] is [String: Any])
                    #expect(nextRaw.count < 4096)
                }
                try await journal.close()
            } catch { try await journal.close(); throw error }
        }
    }

    @Test("legacy ready without actual upload-history proof stays active and unchanged")
    func preservesLegacyReadyWithUnknownRemoteHistory() async throws {
        try await Self.root { _, root in
            let journal = try await Journal.open(at: root)
            _ = try await Self.ready(journal)
            try await journal.close()
            let path = root.appendingPathComponent("transaction.json")
            let raw = try Data(contentsOf: path)
            var object = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
            object.removeValue(forKey: "remoteHistory")
            let legacy = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try Self.replaceRecord(legacy, at: path)
            let reopened = try await Journal.open(at: root)
            do {
                let loaded = try await reopened.load(); let state = try #require(loaded)
                #expect(state.record.remoteHistory == nil && state.record.submission == nil)
                do { _ = try await reopened.retireUnsubmitted(state, reason: .supersededUnsubmittedCandidate, at: Self.date)
                    Issue.record("A nil legacy path became negative remote-history proof")
                } catch Journal.Failure.retirementNotAuthorized {}
                do { _ = try await Self.create(reopened); Issue.record("Legacy active transaction was overwritten") }
                catch Journal.Failure.activeTransaction {}
                let after = try Data(contentsOf: path)
                #expect(after == legacy)
                try await reopened.close()
            } catch { try await reopened.close(); throw error }
        }
    }

    @Test("reopen handles real pending bytes before unlink, after unlink and after directory sync")
    func resumesActualPendingCandidateRemovalWindows() async throws {
        for window in 0..<3 {
            try await Self.root { _, root in
                let journal = try await Journal.open(at: root)
                let ready = try await Self.ready(journal)
                let original = try Data(contentsOf: root.appendingPathComponent("transaction.json"))
                let candidate = root.appendingPathComponent("candidate.ipa")
                guard chmod(candidate.path, 0o644) == 0 else { throw Journal.Failure.storageIO }
                do { _ = try await journal.retireUnsubmitted(ready, reason: .supersededUnsubmittedCandidate, at: Self.date)
                    Issue.record("Unsafe candidate permissions were deleted")
                } catch Journal.Failure.storageIO {}
                let loaded = try await journal.load(); let pending = try #require(loaded)
                #expect(pending.record.phase == .retirementPending)
                #expect(pending.record.retirement?.originalRecordSHA256 == Data(SHA256.hash(data: original)))
                do { _ = try await Self.create(journal); Issue.record("Pending cleanup admitted another transaction") }
                catch Journal.Failure.activeTransaction {}
                try await journal.close()
                guard chmod(candidate.path, 0o600) == 0 else { throw Journal.Failure.storageIO }
                // Actual owned file operations prepare the distinct crash-window
                // states. This is reopening persisted bytes, not a power-loss test.
                if window > 0, unlink(candidate.path) != 0 { throw Journal.Failure.storageIO }
                if window == 2 { try Self.syncDirectory(root) }
                let reopened = try await Journal.open(at: root)
                do {
                    let loadedAgain = try await reopened.load(); let restored = try #require(loadedAgain)
                    let receipt = try await reopened.resumeRetirement(restored, at: Self.date)
                    #expect(receipt.localCandidateRemoval == (window == 0 ? .removed : .alreadyAbsent))
                    let after = try await reopened.load()
                    #expect(after?.record.phase == .retired && after?.record.candidate == nil)
                    let next = try await Self.create(reopened)
                    #expect(next.record.previousRetirement?.transactionID == ready.record.id)
                    try await reopened.close()
                } catch { try await reopened.close(); throw error }
            }
        }
    }

    @Test("actual file failures and cancelled admissions preserve the previous or pending durable CAS")
    func retainsCheckpointOnWriteFailureAndCancelledRetirement() async throws {
        try await Self.root { _, root in
            let journal = try await Journal.open(at: root)
            do {
                let ready = try await Self.ready(journal)
                let path = root.appendingPathComponent("transaction.json")
                let before = try Data(contentsOf: path)
                let cancelled = Task.detached {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return try await journal.retireUnsubmitted(ready, reason: .supersededUnsubmittedCandidate, at: Self.date)
                }
                do { _ = try await cancelled.value; Issue.record("Cancelled retirement returned success") }
                catch is CancellationError {}
                let afterCancel = try Data(contentsOf: path)
                #expect(before == afterCancel)
                guard chmod(root.path, 0o500) == 0 else { throw Journal.Failure.storageIO }
                do { _ = try await journal.retireUnsubmitted(ready, reason: .supersededUnsubmittedCandidate, at: Self.date)
                    Issue.record("Unwritable directory published a pending marker")
                } catch Journal.Failure.storageIO {}
                guard chmod(root.path, 0o700) == 0 else { throw Journal.Failure.storageIO }
                let afterWriteFailure = try Data(contentsOf: path)
                #expect(before == afterWriteFailure)
                let candidate = root.appendingPathComponent("candidate.ipa")
                guard chmod(candidate.path, 0o644) == 0 else { throw Journal.Failure.storageIO }
                do { _ = try await journal.retireUnsubmitted(ready, reason: .supersededUnsubmittedCandidate, at: Self.date) }
                catch Journal.Failure.storageIO {}
                let loaded = try await journal.load(); let pending = try #require(loaded)
                let pendingRaw = try Data(contentsOf: path)
                let cancelledResume = Task.detached {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return try await journal.resumeRetirement(pending, at: Self.date)
                }
                do { _ = try await cancelledResume.value; Issue.record("Cancelled pending recovery returned success") }
                catch is CancellationError {}
                let afterResumeCancel = try Data(contentsOf: path)
                #expect(afterResumeCancel == pendingRaw)
                guard chmod(candidate.path, 0o600) == 0 else { throw Journal.Failure.storageIO }
                _ = try await journal.resumeRetirement(pending, at: Self.date)
                try await journal.close()
            } catch {
                _ = chmod(root.path, 0o700)
                try await journal.close(); throw error
            }
        }
    }

    @Test("real whole-package prepare retires its new never-uploaded predecessor before preparing again")
    func nextActualPreparationRetiresOnlyProvenUnsubmittedCandidate() async throws {
        try await Package.fixture { fixture in
            let journal = try await Journal.open(at: fixture.directory.appendingPathComponent("SelfRenewalTransactions"))
            do {
                let coordinator = Coordinator(journal: journal, vault: fixture.vault, namespace: fixture.namespace, clock: { fixture.date })
                // This original archive has real valid signatures/profile but
                // an unresolved nested Apple predicate the signer cannot issue.
                let unsupported = try SelfRenewalControlledPackageFixture.data(SelfRenewalControlledPackageFixture.unresolvedRequirementBase64)
                let failedInput = fixture.directory.appendingPathComponent("unresolved-for-retirement.ipa")
                try unsupported.write(to: failedInput, options: .withoutOverwriting)
                let validOriginal = try await SelfRenewalIPAUnpacker.verify(ipa: failedInput,
                    codeAnchors: [fixture.oldAnchor], profileAnchors: [fixture.oldAnchor], at: fixture.date)
                let hasUnresolved = validOriginal.application.resources.components.contains { !$0.resources.unresolvedRequirementCapabilities.isEmpty }
                #expect(hasUnresolved)
                do { _ = try await coordinator.prepare(ipa: failedInput, lease: fixture.lease,
                    originalCodeAnchors: [fixture.oldAnchor], originalProfileAnchors: [fixture.oldAnchor])
                    Issue.record("Unsupported nested signing unexpectedly produced a candidate")
                } catch let failure as Coordinator.PreparationFailure {
                    let actual = try #require(failure.underlying as? SelfRenewalControlledPackageSigner.Failure)
                    guard case .unresolvedRequirement = actual else { throw actual }
                    #expect(failure.lastAcknowledgedCheckpoint.record.phase == .signing)
                    #expect(failure.retirement?.reason == .preparationFailed && failure.retirementError == nil)
                }
                let failedState = try await journal.load()
                #expect(failedState?.record.phase == .retired && failedState?.record.remoteHistory == .neverStarted)
                let first = try await Self.prepare(coordinator, fixture)
                #expect(first.record.previousRetirement?.transactionID == failedState?.record.id)
                let second = try await Self.prepare(coordinator, fixture)
                #expect(first.record.remoteHistory == .neverStarted && second.record.remoteHistory == .neverStarted)
                #expect(first.record.id != second.record.id)
                #expect(second.record.previousRetirement?.transactionID == first.record.id)
                #expect(second.record.previousRetirement?.recordSHA256.count == 32)
                #expect(second.record.phase == .candidateReady && !second.record.renewalVerified)
                let local = try await journal.candidateURL(second)
                let checked = try await SelfRenewalIPAUnpacker.verify(ipa: local,
                    codeAnchors: fixture.issuer.certificateChainDER, profileAnchors: fixture.issuer.certificateChainDER, at: fixture.date)
                #expect(checked.archiveSHA256 == second.record.candidate?.sha256)
                try await coordinator.close()
            } catch { try await journal.close(); throw error }
        }
    }

    @Test("actual partial upload cleanup persists sealed facts and permits a new signed transaction after reopen")
    func retiresAuthenticatedCleanupAfterRealUploadInterruptionAndReopen() async throws {
        try await Package.fixture { fixture in
            let root = fixture.directory.appendingPathComponent("SelfRenewalTransactions")
            let journal = try await Journal.open(at: root)
            do {
                let coordinator = Coordinator(journal: journal, vault: fixture.vault, namespace: fixture.namespace, clock: { fixture.date })
                let ready = try await Self.prepare(coordinator, fixture)
                let candidateURL = try await journal.candidateURL(ready)
                let archive = try Data(contentsOf: candidateURL)
                try await Peer.withPeer(.partialUploadThenRecover, bytes: archive,
                    bundle: ready.record.bundleIdentifier, version: ready.record.bundleVersion, at: fixture.date) { peer in
                    do { _ = try await coordinator.submit(pairing: peer.pairing, endpoint: peer.endpoint, timeoutSeconds: 12)
                        Issue.record("Deliberately truncated AFC upload succeeded")
                    } catch let failure as Coordinator.Interrupted { #expect(!failure.mayHaveSubmittedUpgrade) }
                    let recovery = try await coordinator.recover(pairing: peer.pairing, endpoint: peer.endpoint, timeoutSeconds: 12)
                    guard case .remoteCleanup(let cleaned, let outcome) = recovery else {
                        Issue.record("Actual safe cleanup did not complete"); return
                    }
                    let summary = try #require(cleaned.record.safePreSubmissionCleanup)
                    #expect(cleaned.record.remoteHistory == .started && outcome.removalVerified)
                    #expect(summary.submission.remotePackagePath == outcome.remotePackagePath)
                    #expect(summary.submission.deviceCertificateSHA256 == outcome.deviceCertificateSHA256)
                    #expect(summary.candidate == cleaned.record.candidate)
                    try await coordinator.close()
                    let reopened = try await Journal.open(at: root)
                    do {
                        let resumed = Coordinator(journal: reopened, vault: fixture.vault, namespace: fixture.namespace, clock: { fixture.date })
                        let retired = try await resumed.recover(pairing: peer.pairing, endpoint: peer.endpoint, timeoutSeconds: 12)
                        guard case .retiredUnsubmitted(let receipt) = retired else { Issue.record("Sealed cleanup facts did not authorize local retirement"); try await resumed.close(); return }
                        #expect(receipt.transactionID == ready.record.id && receipt.reason == .authenticatedUploadCleanup)
                        let next = try await Self.prepare(resumed, fixture)
                        #expect(next.record.id != ready.record.id && next.record.previousRetirement?.transactionID == ready.record.id)
                        let observed = peer.observed.snapshot
                        #expect(observed.upgradeRequests == 0 && observed.lookupRequests == 0)
                        #expect(observed.removedPaths.count == 1 && observed.authenticatedChannels == 5)
                        try await resumed.close()
                    } catch { try await reopened.close(); throw error }
                }
            } catch { try await journal.close(); throw error }
        }
    }

    @Test("real Complete and uncertain Upgrade/Lookup never authorize retirement or another prepare")
    func preservesActualSubmittedReceiptAndLookupWithoutAutomaticResubmission() async throws {
        for mode: Peer.Mode in [.normal, .disconnectAfterUpgradeThenRecover, .disconnectAfterUpgradeThenLookupMissing] {
            try await Package.fixture { fixture in
                let journal = try await Journal.open(at: fixture.directory.appendingPathComponent("SelfRenewalTransactions"))
                do {
                    let coordinator = Coordinator(journal: journal, vault: fixture.vault, namespace: fixture.namespace, clock: { fixture.date })
                    let ready = try await Self.prepare(coordinator, fixture)
                    let url = try await journal.candidateURL(ready); let bytes = try Data(contentsOf: url)
                    try await Peer.withPeer(mode, bytes: bytes, bundle: ready.record.bundleIdentifier,
                        version: ready.record.bundleVersion, at: fixture.date) { peer in
                        do { _ = try await coordinator.submit(pairing: peer.pairing, endpoint: peer.endpoint, timeoutSeconds: 12) }
                        catch let failure as Coordinator.Interrupted { #expect(mode != .normal && failure.mayHaveSubmittedUpgrade) }
                        if mode != .normal {
                            _ = try await coordinator.recover(pairing: peer.pairing, endpoint: peer.endpoint, timeoutSeconds: 12)
                        }
                        let loaded = try await journal.load(); let submitted = try #require(loaded)
                        #expect(submitted.record.remoteHistory == .started && submitted.record.safePreSubmissionCleanup == nil)
                        #expect(submitted.record.phase == (mode == .normal ? .receiptObserved : .lookupObserved))
                        do { _ = try await journal.retireUnsubmitted(submitted, reason: .authenticatedUploadCleanup, at: fixture.date)
                            Issue.record("Submitted/Lookup state was automatically retired")
                        } catch Journal.Failure.retirementNotAuthorized {}
                        do { _ = try await Self.prepare(coordinator, fixture); Issue.record("A new transaction overwrote a submitted Upgrade") }
                        catch Journal.Failure.activeTransaction {}
                        let final = try await journal.load()
                        #expect(final?.record == submitted.record)
                        #expect(peer.observed.snapshot.upgradeRequests == 1 && peer.observed.snapshot.lookupRequests == 1)
                        #expect(!submitted.record.renewalVerified)
                    }
                    try await coordinator.close()
                } catch { try await journal.close(); throw error }
            }
        }
    }

    nonisolated private static func create(_ journal: Journal) async throws -> Journal.Snapshot {
        try await journal.create(namespace: UUID(), generation: 1,
            originalSHA256: Data(repeating: 0x11, count: 32), identitySHA256: Data(repeating: 0x22, count: 32),
            bundleIdentifier: "owned.reader", bundleVersion: "42", at: date)
    }
    nonisolated private static func store(_ journal: Journal, _ signing: Journal.Snapshot) async throws -> Journal.Snapshot {
        try await journal.storeCandidate(signing, archive: .init(byteCount: bytes.count,
            sha256: Data(SHA256.hash(data: bytes)), read: { offset, count in Data(bytes[offset..<(offset+count)]) }), at: date)
    }
    nonisolated private static func ready(_ journal: Journal) async throws -> Journal.Snapshot {
        let created = try await create(journal)
        let signing = try await journal.beginSigning(created, at: date)
        return try await store(journal, signing)
    }
    nonisolated private static func prepare(_ coordinator: Coordinator, _ fixture: Package.Fixture) async throws -> Journal.Snapshot {
        try await coordinator.prepare(ipa: fixture.input, lease: fixture.lease,
            originalCodeAnchors: [fixture.oldAnchor], originalProfileAnchors: [fixture.oldAnchor])
    }
    nonisolated private static func replaceRecord(_ raw: Data, at path: URL) throws {
        precondition(!Thread.isMainThread)
        try raw.write(to: path, options: .atomic)
        guard chmod(path.path, 0o600) == 0 else { throw Journal.Failure.storageIO }
        let descriptor = Darwin.open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Journal.Failure.storageIO }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw Journal.Failure.storageIO }
        try syncDirectory(path.deletingLastPathComponent())
    }
    nonisolated private static func syncDirectory(_ root: URL) throws {
        let descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Journal.Failure.storageIO }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw Journal.Failure.storageIO }
    }
    nonisolated private static func root(_ action: @escaping @Sendable (URL, URL) async throws -> Void) async throws {
        let worker = Task.detached(priority: .utility) {
            precondition(!Thread.isMainThread)
            let parent = FileManager.default.temporaryDirectory.appendingPathComponent("owned-retirement-"+UUID().uuidString)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            do { try await action(parent, parent.appendingPathComponent("SelfRenewalTransactions")); try FileManager.default.removeItem(at: parent) }
            catch { do { try FileManager.default.removeItem(at: parent) } catch { Issue.record(error) }; throw error }
        }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
