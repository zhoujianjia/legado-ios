import CryptoKit
import Foundation
import Testing
@testable import yuedu_app

@Suite("Actual owned package to durable renewal transaction and authenticated peer", .serialized)
struct SelfRenewalControlledRenewalCoordinatorTests {
    typealias Package = SelfRenewalControlledPackageSignerTests
    typealias Coordinator = SelfRenewalControlledRenewalCoordinator
    typealias Journal = SelfRenewalTransactionJournal
    typealias Peer = SelfRenewalAuthenticatedInstallationFixture
    typealias Vault = SelfRenewalSigningMaterialVault

    @Test("real whole-package signer persisted archive TLS Upgrade and original user-store bytes")
    func persistsAndSubmitsActualVerifiedPackageWithoutTouchingUserStores() async throws {
        try await Package.fixture { fixture in
            let sentinels = ["books.json": Data("[{\"id\":\"book-A\"}]".utf8),
                "book-sources.json": Data("[{\"id\":\"source-A\"}]".utf8),
                "reading-progress.json": Data("{\"spineIndex\":7,\"charOffset\":113}".utf8)]
            for (name, bytes) in sentinels { try bytes.write(to: fixture.directory.appendingPathComponent(name)) }
            try await Self.withJournal(fixture.directory) { journal in
                let coordinator = Coordinator(journal: journal, vault: fixture.vault,
                    namespace: fixture.namespace, clock: { fixture.date })
                let ready = try await Self.prepare(coordinator, fixture)
                let actual = try await Self.candidateBytes(journal, ready)
                #expect(actual != fixture.originalBytes)
                #expect(Data(SHA256.hash(data: actual)) == ready.record.candidate?.sha256)
                try await Peer.withPeer(bytes: actual, bundle: ready.record.bundleIdentifier,
                    version: ready.record.bundleVersion, at: fixture.date) { peer in
                    let completed = try await coordinator.submit(pairing: peer.pairing, endpoint: peer.endpoint, timeoutSeconds: 12)
                    #expect(completed.snapshot.record.phase == .receiptObserved)
                    #expect(completed.snapshot.record.lookupReportedSameVersion == true)
                    #expect(!completed.snapshot.record.renewalVerified)
                    #expect(!completed.installedRenewedProfileVerified)
                    #expect(!completed.coldLaunchAndUserDataPreservationVerified)
                    #expect(!completed.automaticSelfRenewalImplemented)
                    let observed = peer.observed.snapshot
                    #expect(observed.uploaded == actual)
                    #expect(observed.upgradeRequests == 1 && observed.lookupRequests == 1)
                    #expect(observed.removedPaths.count == 1 && observed.stoppedSessions.count == 1)
                }
                for (name, bytes) in sentinels {
                    let reloaded = try Data(contentsOf: fixture.directory.appendingPathComponent(name))
                    #expect(reloaded == bytes)
                }
            }
        }
    }

    @Test("lost actual Upgrade response reopens durable owner and fresh vault for Lookup only")
    func recoversUnknownUpgradeWithoutUploadingOrSubmittingTwice() async throws {
        try await Package.fixture { fixture in
            let directory = fixture.directory.appendingPathComponent("SelfRenewalTransactions")
            let originalJournal = try await Journal.open(at: directory)
            do {
                let coordinator = Coordinator(journal: originalJournal, vault: fixture.vault,
                    namespace: fixture.namespace, clock: { fixture.date })
                let ready = try await Self.prepare(coordinator, fixture)
                let actual = try await Self.candidateBytes(originalJournal, ready)
                try await Peer.withPeer(.disconnectAfterUpgradeThenRecover, bytes: actual,
                    bundle: ready.record.bundleIdentifier, version: ready.record.bundleVersion, at: fixture.date) { peer in
                    do { _ = try await coordinator.submit(pairing: peer.pairing, endpoint: peer.endpoint, timeoutSeconds: 12)
                        Issue.record("A deliberately lost install response was accepted")
                    } catch let failure as Coordinator.Interrupted {
                        #expect(failure.mayHaveSubmittedUpgrade)
                        #expect(failure.persistedIntent?.record.phase == .upgradeIntent)
                    }
                    let loadedInterrupted = try await originalJournal.load()
                    let interrupted = try #require(loadedInterrupted)
                    #expect(interrupted.record.phase == .installationUnknown)
                    try await coordinator.close()
                    let reopened = try await Journal.open(at: directory)
                    do {
                        let baseline = try await SelfRenewalIPAUnpacker.verify(ipa: fixture.input,
                            codeAnchors: [fixture.oldAnchor], profileAnchors: [fixture.oldAnchor], at: fixture.date)
                        let freshVault = Vault(codeAnchors: fixture.issuer.certificateChainDER,
                            profileAnchors: fixture.issuer.certificateChainDER, clock: { fixture.date })
                        let resumedNamespace = try await freshVault.resume(namespaceID: fixture.namespace.id, identity: baseline.application)
                        let resumed = Coordinator(journal: reopened, vault: freshVault,
                            namespace: resumedNamespace, clock: { fixture.date })
                        let recovery = try await resumed.recover(pairing: peer.pairing, endpoint: peer.endpoint, timeoutSeconds: 12)
                        guard case .authenticatedLookup(let state, let observation) = recovery else {
                            Issue.record("Unknown submission did not use authenticated Lookup"); try await resumed.close(); return
                        }
                        #expect(state.record.phase == .lookupObserved)
                        #expect(state.record.lookupReportedSameVersion == true && !state.record.renewalVerified)
                        #expect(!observation.installedArchiveDigestVerified && !observation.installedProfileOrEntitlementsVerified)
                        do { _ = try await resumed.submit(pairing: peer.pairing, endpoint: peer.endpoint)
                            Issue.record("Unknown previous Upgrade was submitted a second time")
                        } catch Coordinator.Failure.candidateNotReady {}
                        let observed = peer.observed.snapshot
                        #expect(observed.upgradeRequests == 1 && observed.lookupRequests == 1)
                        #expect(observed.uploaded == actual && observed.removedPaths.isEmpty)
                        #expect(observed.authenticatedChannels == 5)
                        try await resumed.close()
                    } catch { try await reopened.close(); throw error }
                }
            } catch {
                do { try await originalJournal.close() } catch { Issue.record(error) }
                throw error
            }
        }
    }

    @Test("actual corrupted persisted candidate is rejected before any connection")
    func rejectsChangedCandidateBeforeOpeningAuthenticatedTransport() async throws {
        try await Package.fixture { fixture in
            try await Self.withJournal(fixture.directory) { journal in
                let coordinator = Coordinator(journal: journal, vault: fixture.vault,
                    namespace: fixture.namespace, clock: { fixture.date })
                let ready = try await Self.prepare(coordinator, fixture)
                var raw = try await Self.candidateBytes(journal, ready)
                raw[0] ^= 1
                let path = try await journal.candidateURL(ready)
                try raw.write(to: path)
                try await Peer.withPeer(.unusedInput, at: fixture.date) { peer in
                    do { _ = try await coordinator.submit(pairing: peer.pairing, endpoint: peer.endpoint)
                        Issue.record("Corrupted persisted IPA was submitted")
                    } catch is SelfRenewalIPAArchiveValidator.Failure {}
                    #expect(peer.observed.snapshot.authenticatedChannels == 0)
                    #expect(peer.observed.snapshot.upgradeRequests == 0)
                }
                let loadedCurrent = try await journal.load()
                let current = try #require(loadedCurrent)
                #expect(current.record.phase == .candidateReady)
            }
        }
    }

    @Test("a revoked real namespace lease cannot initiate upload")
    func rejectsRevokedMaterialBeforeAnyUploadOrUpgrade() async throws {
        try await Package.fixture { fixture in
            try await Self.withJournal(fixture.directory) { journal in
                let coordinator = Coordinator(journal: journal, vault: fixture.vault,
                    namespace: fixture.namespace, clock: { fixture.date })
                _ = try await Self.prepare(coordinator, fixture)
                try await fixture.vault.revoke(fixture.lease.keyID, in: fixture.namespace, expectedGeneration: fixture.lease.generation)
                try await Peer.withPeer(.unusedInput, at: fixture.date) { peer in
                    do { _ = try await coordinator.submit(pairing: peer.pairing, endpoint: peer.endpoint)
                        Issue.record("Revoked signing material was submitted")
                    } catch is Vault.Failure {} catch Coordinator.Failure.leaseChanged {}
                    #expect(peer.observed.snapshot.authenticatedChannels == 0)
                    #expect(peer.observed.snapshot.openedFileHandles == 0)
                }
            }
        }
    }

    @Test("actual partial upload persists its random planned path and is never auto-resubmitted")
    func retainsUploadOwnershipAfterActualPartialAFCFailure() async throws {
        try await Package.fixture { fixture in
            try await Self.withJournal(fixture.directory) { journal in
                let coordinator = Coordinator(journal: journal, vault: fixture.vault,
                    namespace: fixture.namespace, clock: { fixture.date })
                let ready = try await Self.prepare(coordinator, fixture)
                let actual = try await Self.candidateBytes(journal, ready)
                try await Peer.withPeer(.midUploadError, bytes: actual, bundle: ready.record.bundleIdentifier,
                    version: ready.record.bundleVersion, at: fixture.date) { peer in
                    do { _ = try await coordinator.submit(pairing: peer.pairing, endpoint: peer.endpoint, timeoutSeconds: 12)
                        Issue.record("Rejected partial AFC upload was accepted")
                    } catch let interrupted as Coordinator.Interrupted {
                        #expect(!interrupted.mayHaveSubmittedUpgrade)
                        #expect(interrupted.persistedUpload?.record.phase == .uploadIntent)
                        #expect(interrupted.persistedUpload?.record.submission != nil)
                    }
                    let loadedState = try await journal.load()
                    let state = try #require(loadedState)
                    #expect(state.record.phase == .uploadIntent)
                    #expect(peer.observed.snapshot.upgradeRequests == 0)
                    #expect(peer.observed.snapshot.uploaded == Data(actual.prefix(65_536)))
                    do { _ = try await coordinator.submit(pairing: peer.pairing, endpoint: peer.endpoint)
                        Issue.record("An uncleaned partial upload was retried")
                    } catch Coordinator.Failure.candidateNotReady {}
                    #expect(peer.observed.snapshot.upgradeRequests == 0)
                }
            }
        }
    }

    @Test("actual interrupted package upload reopens its journal and only cleans its owned path")
    func recoversActualPackageUploadWithFreshAuthenticatedCleanup() async throws {
        try await Package.fixture { fixture in
            let directory = fixture.directory.appendingPathComponent("SelfRenewalTransactions")
            let journal = try await Journal.open(at: directory)
            do {
                let coordinator = Coordinator(journal: journal, vault: fixture.vault,
                    namespace: fixture.namespace, clock: { fixture.date })
                let ready = try await Self.prepare(coordinator, fixture)
                let actual = try await Self.candidateBytes(journal, ready)
                try await Peer.withPeer(.partialUploadThenRecover, bytes: actual, bundle: ready.record.bundleIdentifier,
                    version: ready.record.bundleVersion, at: fixture.date) { peer in
                    do { _ = try await coordinator.submit(pairing: peer.pairing, endpoint: peer.endpoint, timeoutSeconds: 12)
                        Issue.record("AFC acknowledgement disconnect was accepted")
                    } catch let failure as Coordinator.Interrupted {
                        #expect(!failure.mayHaveSubmittedUpgrade && failure.persistedUpload != nil)
                    }
                    let beforeRestart = try await journal.load()
                    #expect(beforeRestart?.record.phase == .uploadIntent)
                    try await coordinator.close()
                    let reopened = try await Journal.open(at: directory)
                    do {
                        let resumed = Coordinator(journal: reopened, vault: fixture.vault,
                            namespace: fixture.namespace, clock: { fixture.date })
                        let recovered = try await resumed.recover(pairing: peer.pairing, endpoint: peer.endpoint, timeoutSeconds: 12)
                        guard case .remoteCleanup(let state, let cleanup) = recovered else {
                            Issue.record("Durable upload ownership did not use authenticated cleanup"); try await resumed.close(); return
                        }
                        #expect(cleanup.removalVerified && cleanup.stopSessionAcknowledged)
                        #expect(cleanup.lookup == nil && !cleanup.selfRenewalVerified)
                        #expect(state.record.phase == .candidateReady && state.record.submission == nil)
                        #expect(state.record.id == ready.record.id && state.record.candidate == ready.record.candidate)
                        let observed = peer.observed.snapshot
                        #expect(observed.upgradeRequests == 0 && observed.lookupRequests == 0)
                        #expect(observed.openedFileHandles == 1 && observed.closedFileHandles == 0)
                        #expect(observed.uploaded == Data(actual.prefix(65_536)))
                        #expect(observed.removedPaths.count == 1 && observed.stoppedSessions.count == 1)
                        #expect(observed.authenticatedChannels == 5)
                        try await resumed.close()
                    } catch { try await reopened.close(); throw error }
                }
            } catch { try await journal.close(); throw error }
        }
    }

    nonisolated private static func prepare(_ coordinator: Coordinator, _ fixture: Package.Fixture) async throws -> Journal.Snapshot {
        try await coordinator.prepare(ipa: fixture.input, lease: fixture.lease,
            originalCodeAnchors: [fixture.oldAnchor], originalProfileAnchors: [fixture.oldAnchor])
    }
    nonisolated private static func candidateBytes(_ journal: Journal, _ snapshot: Journal.Snapshot) async throws -> Data {
        let candidate = try #require(snapshot.record.candidate)
        guard candidate.byteCount <= 4_194_304 else { throw Journal.Failure.limit }
        var raw = Data(); var offset = 0
        while offset < candidate.byteCount {
            let count = min(65_536, candidate.byteCount - offset)
            raw.append(try await journal.readCandidate(snapshot, at: offset, count: count)); offset += count
        }
        return raw
    }
    nonisolated private static func withJournal(_ parent: URL,
        action: @escaping @Sendable (Journal) async throws -> Void) async throws {
        let journal = try await Journal.open(at: parent.appendingPathComponent("SelfRenewalTransactions"))
        do { try await action(journal); try await journal.close() }
        catch { do { try await journal.close() } catch { Issue.record(error) }; throw error }
    }
}
