import CryptoKit
import Foundation
import Security
import Testing
import YueduCoreText
@testable import yuedu_app

#if DEBUG
@Suite("Actual App prepare and submit through the one renewal session", .serialized)
struct SelfRenewalAppExecutionTests {
    typealias Package = SelfRenewalControlledPackageSignerTests
    typealias Session = SelfRenewalAppSession
    typealias Journal = SelfRenewalTransactionJournal
    typealias Coordinator = SelfRenewalControlledRenewalCoordinator
    typealias Peer = SelfRenewalAuthenticatedInstallationFixture

    @Test("explicit current-App preparation signs without a device or remote work and cancellation preserves the candidate")
    func preparesCurrentApplicationWithoutDeviceOrRemoteWork() async throws {
        let observations = CurrentPreparationObservations()
        try await Package.fixture { f in
            let application = try await Self.application(f)
            let root = f.directory.appendingPathComponent("SelfRenewalApp")
            let probe = PreparationRemoteProbe()
            let services = Session.DeveloperServices(transport: probe, storage: probe,
                freshAnisette: { try probe.freshAnisette() })
            let owner = await MainActor.run {
                SelfRenewalAppOwner(root: root, currentApplicationRoot: application,
                    developerServices: services, clock: { f.date })
            }
            let owners = try await Self.library(in: f.directory, at: f.date, handoff: owner.handoff)
            do {
                await owner.start(books: owners.books, sources: owners.sources, positions: owners.positions, automatically: false)
                let configuration = try Self.configuration(f, device: nil)
                let input = try Session.decodeConfiguration(Data(contentsOf: configuration))
                await owner.importConfiguration(configuration)
                // The new route must use the actual installation, not a saved
                // imported IPA or a previous signed candidate.
                try FileManager.default.removeItem(at: f.input)
                await owner.prepareCurrentApplicationRenewal()
                let ready = await MainActor.run {
                    (owner.status, owner.problem == nil && owner.operationFailure == nil && !owner.isWorking)
                }
                let record = try Self.record(root)
                let candidate = try Self.candidate(root, record: record)
                let independent = f.directory.appendingPathComponent("current-app-independent.ipa")
                try candidate.write(to: independent, options: .withoutOverwriting)
                let verified = try await SelfRenewalIPAUnpacker.verify(ipa: independent,
                    codeAnchors: f.issuer.certificateChainDER, profileAnchors: f.issuer.certificateChainDER, at: f.date)
                let journalURL = root.appendingPathComponent("SelfRenewalTransactions/transaction.json")
                let journalBytes = try Data(contentsOf: journalURL)
                let cancelled = Task {
                    withUnsafeCurrentTask { $0?.cancel() }
                    await owner.prepareCurrentApplicationRenewal()
                }
                await cancelled.value
                let refused = await MainActor.run {
                    (owner.status?.phase == .candidateReady && owner.status?.problem == .cancelled,
                     owner.problem == .cancelled && owner.operationFailure?.operation == .packagePreparation && !owner.isWorking)
                }
                let cancelledJournalBytes = try Data(contentsOf: journalURL)
                let cancelledCandidate = try Self.candidate(root, record: Self.record(root))
                let info = application.appendingPathComponent("Info.plist")
                guard var properties = try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any] else {
                    throw CocoaError(.coderInvalidValue)
                }
                properties["CFBundleIdentifier"] = "owned.changed.current.preparation"
                try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0).write(to: info, options: .atomic)
                await owner.prepareCurrentApplicationRenewal()
                let changedRefused = await MainActor.run {
                    owner.status?.access == nil && owner.status?.state == .unavailable
                        && owner.status?.phase == .candidateReady && owner.status?.problem == .signingMaterials
                        && owner.problem == .signingMaterials && owner.operationFailure?.operation == .packagePreparation
                        && !owner.isWorking
                }
                let changedJournalBytes = try Data(contentsOf: journalURL)
                let changedCandidate = try Self.candidate(root, record: Self.record(root))
                await observations.store(CurrentPreparationFacts(
                    status: ready.0, ownerReady: ready.1, noDevice: input.device == nil,
                    recapturedCurrentApplication: record.originalArchiveSHA256 != Data(SHA256.hash(data: f.originalBytes)),
                    candidateDigestMatched: verified.archiveSHA256 == record.candidate?.sha256
                        && verified.archiveBytes == record.candidate?.byteCount,
                    bundleCount: verified.application.bundles.count,
                    profileCount: verified.application.profiles.profiles.count,
                    signaturesVerified: verified.application.resources.resourceEnvelopesVerified
                        && verified.application.profileAndCodeIdentityConsistencyVerified,
                    neverSubmitted: record.remoteHistory == .neverStarted && record.submission == nil && record.userDataHandoff == nil,
                    remoteCalls: probe.calls, cancellationObserved: refused.0 && refused.1,
                    cancelledCandidateUnchanged: cancelledJournalBytes == journalBytes && cancelledCandidate == candidate,
                    changedCurrentApplicationRejected: changedRefused && changedJournalBytes == journalBytes && changedCandidate == candidate))
                try await owner.close()
            } catch {
                do { try await owner.close() } catch { Issue.record(error) }
                throw error
            }
        }
        // Package.fixture owns a detached archive/PKI worker. Keep every new
        // verdict in this parent @Test after its actual facts have returned.
        let facts = try #require(await observations.facts)
        #expect(facts.status?.state == .candidateReady && facts.status?.phase == .candidateReady)
        #expect(facts.ownerReady && facts.noDevice)
        #expect(facts.recapturedCurrentApplication && facts.candidateDigestMatched)
        #expect(facts.bundleCount == 3 && facts.profileCount == 3 && facts.signaturesVerified)
        #expect(facts.neverSubmitted && facts.remoteCalls == 0)
        #expect(facts.cancellationObserved && facts.cancelledCandidateUnchanged)
        #expect(facts.changedCurrentApplicationRejected)
    }

    @Test("cold bootstrap restores only the already validated material lease and clears it when that proof expires")
    func restoresValidatedMaterialObservationAfterColdBootstrap() async throws {
        let observations = ColdMaterialObservations()
        try await Package.fixture { f in
            let application = try await Self.application(f)
            let root = f.directory.appendingPathComponent("SelfRenewalApp")
            let clock = Clock(f.date)
            let probe = PreparationRemoteProbe()
            let services = Session.DeveloperServices(transport: probe, storage: probe,
                freshAnisette: { try probe.freshAnisette() })
            let first = await MainActor.run {
                SelfRenewalAppOwner(root: root, currentApplicationRoot: application,
                    developerServices: services, clock: { clock.value })
            }
            let owners = try await Self.library(in: f.directory, at: f.date, handoff: first.handoff)
            do {
                await first.start(books: owners.books, sources: owners.sources, positions: owners.positions, automatically: false)
                await first.importConfiguration(try Self.configuration(f, device: nil))
                let before = await MainActor.run { (first.developerMaterial, first.developerSession == nil) }
                try await first.close()
                let reopened = await MainActor.run {
                    SelfRenewalAppOwner(root: root, currentApplicationRoot: application,
                        developerServices: services, clock: { clock.value })
                }
                do {
                    await reopened.start(books: owners.books, sources: owners.sources, positions: owners.positions, automatically: false)
                    let restored = await MainActor.run {
                        (reopened.developerMaterial, reopened.developerSession == nil,
                         reopened.status?.access == .signing && reopened.problem == nil)
                    }
                    clock.set(f.date.addingTimeInterval(366 * 86_400))
                    await reopened.bootstrap()
                    let failed = await MainActor.run {
                        reopened.developerMaterial == nil && reopened.developerSession == nil
                            && reopened.status?.access == nil && reopened.status?.state == .unavailable
                            && reopened.problem == .signingMaterials && !reopened.isWorking
                    }
                    await observations.store(ColdMaterialFacts(before: before.0, restored: restored.0,
                        expectedGeneration: f.lease.generation,
                        expectedExpiry: f.lease.profiles.map(\.summary.expiresAt).min(),
                        signingAccessRestored: restored.2, remoteLoginStillUnverified: before.1 && restored.1,
                        staleObservationCleared: failed, remoteCalls: probe.calls,
                        noTransactionCreated: !FileManager.default.fileExists(atPath: root.appendingPathComponent("SelfRenewalTransactions/transaction.json").path)))
                    try await reopened.close()
                } catch {
                    do { try await reopened.close() } catch { Issue.record(error) }
                    throw error
                }
            } catch {
                do { try await first.close() } catch { Issue.record(error) }
                throw error
            }
        }
        let facts = try #require(await observations.facts)
        #expect(facts.before != nil && facts.before == facts.restored)
        #expect(facts.restored?.generation == facts.expectedGeneration)
        #expect(facts.restored?.profileExpiresAt == facts.expectedExpiry && facts.expectedExpiry != nil)
        #expect(facts.signingAccessRestored && facts.staleObservationCleared)
        #expect(facts.remoteLoginStillUnverified && facts.remoteCalls == 0 && facts.noTransactionCreated)
        #expect(facts.restored?.appleAuthorizationEstablished == false && facts.restored?.installedApplicationRenewed == false)
    }

    @Test("App owner prepares actual imported bytes then explicitly submits with real owner acknowledgements")
    func appOwnerPreparesAndSubmitsActualCandidateWithoutAutomaticRetry() async throws {
        let currentEntryRefusal = PreparationRefusalObservation()
        try await Package.fixture { f in
            let application = try await Self.application(f)
            let root = f.directory.appendingPathComponent("SelfRenewalApp")
            let owner = await MainActor.run {
                SelfRenewalAppOwner(root: root, currentApplicationRoot: application, clock: { f.date })
            }
            let owners = try await Self.library(in: f.directory, at: f.date, handoff: owner.handoff)
            do {
                let foreground = await MainActor.run {
                    owner.noteScenePhase(.inactive)
                    return owner.noteScenePhase(.active)
                }
                await owner.start(books: owners.books, sources: owners.sources, positions: owners.positions,
                    foregroundGeneration: foreground)
                await owner.importConfiguration(try Self.configuration(f, device: nil))
                await owner.prepareRenewal(from: f.input)
                let ready = await MainActor.run { (owner.status, owner.problem, owner.isWorking) }
                #expect(ready.0?.state == .candidateReady && ready.0?.phase == .candidateReady)
                #expect(ready.1 == nil && !ready.2)
                let initial = try Self.record(root)
                let raw = try Self.candidate(root, record: initial)
                #expect(initial.originalArchiveSHA256 == Data(SHA256.hash(data: f.originalBytes)))
                #expect(initial.remoteHistory == .neverStarted && initial.submission == nil)
                try await Peer.withPeer(bytes: raw, bundle: initial.bundleIdentifier,
                    version: initial.bundleVersion, at: f.date) { peer in
                    await owner.importConfiguration(try Self.configuration(f, device: Self.device(peer)))
                    await owner.submitPreparedRenewal()
                    let status = await MainActor.run { (owner.status, owner.problem, owner.recoveryAvailable) }
                    #expect(status.0?.phase == .receiptObserved && status.0?.state == .recoveryRequired)
                    #expect(status.1 == nil && status.2)
                    #expect(status.0?.automaticRenewalVerified == false && status.0?.coldLaunchVerified == false)
                    let completed = try Self.record(root)
                    let handoff = try #require(completed.userDataHandoff)
                    #expect(handoff.capturedAt == f.date)
                    #expect(handoff.files.map(\.role) == ["shelf", "reading", "sources"])
                    #expect(handoff.positions.count == 1 && handoff.positions.first?.position == Self.position)
                    #expect(!handoff.allUserDataPreservationVerified && !completed.renewalVerified)
                    #expect(peer.observed.snapshot.upgradeRequests == 1)
                    #expect(peer.observed.snapshot.uploaded == raw)
                    let before = try Data(contentsOf: root.appendingPathComponent("SelfRenewalTransactions/transaction.json"))
                    await owner.submitPreparedRenewal()
                    await owner.prepareRenewal(from: f.input)
                    await owner.prepareCurrentApplicationRenewal()
                    #expect(peer.observed.snapshot.upgradeRequests == 1)
                    #expect(try Data(contentsOf: root.appendingPathComponent("SelfRenewalTransactions/transaction.json")) == before)
                    let refused = await MainActor.run { (owner.problem, owner.recoveryAvailable, owner.status?.phase) }
                    #expect(refused.0 != nil && refused.1 && refused.2 == .receiptObserved)
                    let operation = await MainActor.run { owner.operationFailure?.operation }
                    let afterCurrentEntry = try Data(contentsOf: root.appendingPathComponent("SelfRenewalTransactions/transaction.json"))
                    await currentEntryRefusal.store(operation == .packagePreparation && refused.2 == .receiptObserved
                        && peer.observed.snapshot.upgradeRequests == 1
                        && afterCurrentEntry == before)
                }
                try await owner.close()
            } catch {
                do { try await owner.close() } catch { Issue.record(error) }
                throw error
            }
        }
        #expect(await currentEntryRefusal.refused == true)
    }

    @Test("actual source persistence failure prevents Upgrade through the App owner entry")
    func appSubmissionKeepsUploadIntentWhenActualSourceSaveFails() async throws {
        try await Package.fixture { f in
            let application = try await Self.application(f)
            let root = f.directory.appendingPathComponent("SelfRenewalApp")
            let owner = await MainActor.run {
                SelfRenewalAppOwner(root: root, currentApplicationRoot: application, clock: { f.date })
            }
            let owners = try await Self.library(in: f.directory, at: f.date, handoff: owner.handoff)
            do {
                let foreground = await MainActor.run {
                    owner.noteScenePhase(.inactive)
                    return owner.noteScenePhase(.active)
                }
                await owner.start(books: owners.books, sources: owners.sources, positions: owners.positions,
                    foregroundGeneration: foreground)
                await owner.importConfiguration(try Self.configuration(f, device: nil))
                await owner.prepareRenewal(from: f.input)
                let ready = try Self.record(root)
                let raw = try Self.candidate(root, record: ready)
                let source = f.directory.appendingPathComponent("library/book_sources.json")
                try FileManager.default.removeItem(at: source)
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
                try await Peer.withPeer(.unusedInput, bytes: raw, bundle: ready.bundleIdentifier,
                    version: ready.bundleVersion, at: f.date) { peer in
                    await owner.importConfiguration(try Self.configuration(f, device: Self.device(peer)))
                    await owner.submitPreparedRenewal()
                    let pending = try Self.record(root)
                    #expect(pending.phase == .uploadIntent && pending.userDataHandoff == nil)
                    #expect(peer.observed.snapshot.uploaded == raw)
                    #expect(peer.observed.snapshot.upgradeRequests == 0)
                    let failed = await MainActor.run { (owner.problem, owner.recoveryAvailable, owner.isWorking, owner.status?.problem) }
                    #expect(failed.0 == .localStorage && failed.1 && !failed.2 && failed.3 == .storage)
                    let before = try Data(contentsOf: root.appendingPathComponent("SelfRenewalTransactions/transaction.json"))
                    await owner.submitPreparedRenewal()
                    await owner.prepareRenewal(from: f.input)
                    #expect(try Data(contentsOf: root.appendingPathComponent("SelfRenewalTransactions/transaction.json")) == before)
                    #expect(peer.observed.snapshot.upgradeRequests == 0)
                }
                try await owner.close()
            } catch {
                do { try await owner.close() } catch { Issue.record(error) }
                throw error
            }
        }
    }

    @Test("Session cancellation awaits actual TLS drain and durable status before releasing busy")
    func appSessionCancellationDrainsActualTransportAndKeepsCandidate() async throws {
        let currentEntryRefusal = PreparationRefusalObservation()
        try await Package.fixture { f in
            let application = try await Self.application(f)
            let root = f.directory.appendingPathComponent("SelfRenewalApp")
            let owners = try await Self.library(in: f.directory, at: f.date)
            let handoff = await owners.handoff
            let session = Session(root: root, currentApplicationRoot: application, clock: { f.date })
            do {
                _ = try await session.bootstrap(handoff: handoff)
                _ = try await session.configure(from: Self.configuration(f, device: nil), handoff: handoff)
                let prepared = try await session.prepareRenewal(from: f.input)
                #expect(prepared.state == .candidateReady)
                let ready = try Self.record(root)
                let raw = try Self.candidate(root, record: ready)
                try await Peer.withPeer(.stallSession, bytes: raw, bundle: ready.bundleIdentifier,
                    version: ready.bundleVersion, at: f.date) { peer in
                    _ = try await session.configure(from: Self.configuration(f, device: Self.device(peer)), handoff: handoff)
                    let operation = Task { try await session.submitPreparedRenewal(handoff: handoff) }
                    var signal = peer.sessionRequestReceived.makeAsyncIterator()
                    let received = await signal.next()
                    #expect(received != nil)
                    do { try await session.close(); Issue.record("Busy session released its journal during live TLS") }
                    catch let error as Session.Failure { #expect(error == .busy) }
                    do { _ = try await session.prepareRenewal(from: f.input); Issue.record("Busy session admitted another preparation") }
                    catch let error as Session.Failure { #expect(error == .busy) }
                    var currentEntryWasBusy = false
                    do { _ = try await session.prepareCurrentApplicationRenewal() }
                    catch let error as Session.Failure { currentEntryWasBusy = error == .busy }
                    await currentEntryRefusal.store(currentEntryWasBusy)
                    operation.cancel()
                    do { _ = try await operation.value; Issue.record("Cancelled TLS returned a submission success") }
                    catch let error as Session.RenewalExecutionFailure {
                        let interrupted = try #require(error.underlying as? Coordinator.Interrupted)
                        #expect(interrupted.persistedIntent == nil && interrupted.persistedUpload == nil)
                        #expect(error.completedSubmission == nil && error.statusPersistenceError == nil)
                    }
                    let cancelled = await session.status()
                    #expect(cancelled?.state == .candidateReady && cancelled?.phase == .candidateReady)
                    #expect(cancelled?.problem == .cancelled)
                    #expect(peer.observed.snapshot.upgradeRequests == 0 && peer.observed.snapshot.uploaded.isEmpty)
                    #expect(try Self.candidate(root, record: Self.record(root)) == raw)
                }
                try await session.close()
                let reopened = Session(root: root, currentApplicationRoot: application, clock: { f.date })
                let status = try await reopened.bootstrap(handoff: handoff)
                #expect(status.state == .candidateReady && status.phase == .candidateReady)
                #expect(!status.automaticRenewalVerified)
                try await reopened.close()
            } catch {
                do { try await session.close() } catch { Issue.record(error) }
                throw error
            }
        }
        #expect(await currentEntryRefusal.refused == true)
    }

    @Test("expired or actually changed current Bundle revokes cached signing access and retains candidate bytes")
    func appOwnerRevokesFailedFreshSigningProofAndKeepsActualCandidate() async throws {
        for expire in [true, false] {
            try await Package.fixture { f in
                let application = try await Self.application(f)
                let root = f.directory.appendingPathComponent("SelfRenewalApp")
                let clock = Clock(f.date)
                let owner = await MainActor.run {
                    SelfRenewalAppOwner(root: root, currentApplicationRoot: application, clock: { clock.value })
                }
                let owners = try await Self.library(in: f.directory, at: f.date, handoff: owner.handoff)
                do {
                    let foreground = await MainActor.run {
                        owner.noteScenePhase(.inactive)
                        return owner.noteScenePhase(.active)
                    }
                    await owner.start(books: owners.books, sources: owners.sources, positions: owners.positions,
                        foregroundGeneration: foreground)
                    await owner.importConfiguration(try Self.configuration(f, device: nil))
                    await owner.prepareRenewal(from: f.input)
                    let ready = try Self.record(root)
                    let candidate = try Self.candidate(root, record: ready)
                    let record = try Data(contentsOf: root.appendingPathComponent("SelfRenewalTransactions/transaction.json"))
                    let info = application.appendingPathComponent("Info.plist")
                    let originalInfo = try Data(contentsOf: info)
                    if expire { clock.set(f.date.addingTimeInterval(366 * 86_400)) }
                    else {
                        var value = try #require(PropertyListSerialization.propertyList(from: originalInfo, format: nil) as? [String: Any])
                        value["CFBundleIdentifier"] = "owned.changed.after.bootstrap"
                        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: info, options: .atomic)
                    }
                    await owner.prepareRenewal(from: f.input)
                    let refused = await MainActor.run { (owner.status, owner.problem, owner.signingMaterialProblem, owner.isWorking) }
                    #expect(refused.0?.access == nil && refused.0?.state == .unavailable)
                    #expect(refused.0?.phase == .candidateReady && refused.0?.problem == .signingMaterials)
                    #expect(refused.1 == .signingMaterials && refused.2 == .signingMaterials && !refused.3)
                    #expect(try Data(contentsOf: root.appendingPathComponent("SelfRenewalTransactions/transaction.json")) == record)
                    #expect(try Self.candidate(root, record: Self.record(root)) == candidate)
                    // Restoring test inputs is not a new verified session. The
                    // rejected cached coordinator must remain inaccessible.
                    clock.set(f.date)
                    try originalInfo.write(to: info, options: .atomic)
                    await owner.prepareRenewal(from: f.input)
                    let stillRevoked = await MainActor.run { (owner.status?.access, owner.status?.state) }
                    #expect(stillRevoked.0 == nil && stillRevoked.1 == .unavailable)
                    #expect(try Self.candidate(root, record: Self.record(root)) == candidate)
                    #expect(try Data(contentsOf: root.appendingPathComponent("SelfRenewalTransactions/transaction.json")) == record)
                    try await owner.close()
                } catch {
                    do { try await owner.close() } catch { Issue.record(error) }
                    throw error
                }
            }
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date
        init(_ date: Date) { self.date = date }
        var value: Date { lock.lock(); defer { lock.unlock() }; return date }
        func set(_ date: Date) { lock.lock(); defer { lock.unlock() }; self.date = date }
    }

    private struct CurrentPreparationFacts: Sendable {
        let status: Session.Status?
        let ownerReady: Bool
        let noDevice: Bool
        let recapturedCurrentApplication: Bool
        let candidateDigestMatched: Bool
        let bundleCount: Int
        let profileCount: Int
        let signaturesVerified: Bool
        let neverSubmitted: Bool
        let remoteCalls: Int
        let cancellationObserved: Bool
        let cancelledCandidateUnchanged: Bool
        let changedCurrentApplicationRejected: Bool
    }
    private actor CurrentPreparationObservations {
        private(set) var facts: CurrentPreparationFacts?
        func store(_ value: CurrentPreparationFacts) { facts = value }
    }
    private struct ColdMaterialFacts: Sendable {
        let before: Session.DeveloperMaterialObservation?
        let restored: Session.DeveloperMaterialObservation?
        let expectedGeneration: UInt64
        let expectedExpiry: Date?
        let signingAccessRestored: Bool
        let remoteLoginStillUnverified: Bool
        let staleObservationCleared: Bool
        let remoteCalls: Int
        let noTransactionCreated: Bool
    }
    private actor ColdMaterialObservations {
        private(set) var facts: ColdMaterialFacts?
        func store(_ value: ColdMaterialFacts) { facts = value }
    }
    private actor PreparationRefusalObservation {
        private(set) var refused: Bool?
        func store(_ value: Bool) { refused = value }
    }
    /// Every configured account/provider hook fails closed if preparation tries
    /// to use it. There is no URLSession or real Apple endpoint in this fixture.
    private final class PreparationRemoteProbe: SelfRenewalDeveloperAccountTransport, SelfRenewalDeveloperSessionStorage, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var calls: Int { lock.withLock { count } }
        private func attempted() { lock.withLock { count += 1 } }
        func send(_ request: URLRequest) async throws -> SelfRenewalDeveloperAccountResponse {
            attempted(); throw SelfRenewalDeveloperAccountTransportFailure.wrongEndpoint
        }
        func sendAnisette(_ request: SelfRenewalAnisetteRequest) async throws -> SelfRenewalDeveloperAccountResponse {
            attempted(); throw SelfRenewalDeveloperAccountTransportFailure.wrongEndpoint
        }
        func openAnisetteProvisioning(_ configuration: SelfRenewalAnisetteV3Configuration) async throws -> any SelfRenewalAnisetteProvisioningSocket {
            attempted(); throw SelfRenewalDeveloperAccountTransportFailure.wrongEndpoint
        }
        func freshAnisette() throws -> SelfRenewalDeveloperAccountClient.Anisette {
            attempted(); throw SelfRenewalDeveloperAccountTransportFailure.wrongEndpoint
        }
        func load(namespace: UUID) throws -> String? { attempted(); return nil }
        func save(namespace: UUID, value: String) throws { attempted(); throw SelfRenewalDeveloperAccountClient.Failure.storage }
        func loadAnisetteRegistration(namespace: UUID) throws -> String? { attempted(); return nil }
        func saveAnisetteRegistration(namespace: UUID, value: String) throws { attempted(); throw SelfRenewalDeveloperAccountClient.Failure.storage }
    }

    /// Re-create only the fixture's checked public files for the DEBUG current
    /// application verifier. This test root cannot be a current-process proof.
    nonisolated static func application(_ f: Package.Fixture) async throws -> URL {
        let destination = f.directory.appendingPathComponent("Current.app")
        try await SelfRenewalIPAUnpacker.withOwnedApplication(ipa: f.input,
            codeAnchors: [f.oldAnchor], profileAnchors: [f.oldAnchor], at: f.date) { scope in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            for fact in scope.original.resources.executableMaterials.inventory.files {
                guard fact.byteCount <= 1_048_576 else { throw CocoaError(.fileReadTooLarge) }
                let file = destination.appendingPathComponent(fact.relativePath)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                let bytes = try await scope.read(fact.relativePath, maximumBytes: 1_048_576)
                try bytes.write(to: file, options: .withoutOverwriting)
            }
        }
        return destination
    }

    static let position = CoreTextReadingPosition(spineIndex: 2, charOffset: 31, translationOffset: 4)
    @MainActor final class Owners {
        let books: BookStore
        let sources: BookSourceStore
        let positions: JSONFileReadingPositionStore
        let handoff: SelfRenewalUserDataHandoff
        let navigator: ReaderNavigator
        init(books: BookStore, sources: BookSourceStore, positions: JSONFileReadingPositionStore,
            handoff: SelfRenewalUserDataHandoff, navigator: ReaderNavigator) {
            self.books = books; self.sources = sources; self.positions = positions
            self.handoff = handoff; self.navigator = navigator
        }
    }
    nonisolated static func library(in directory: URL, at date: Date,
        handoff existingHandoff: SelfRenewalUserDataHandoff? = nil) async throws -> Owners {
        let app = directory.appendingPathComponent("library")
        let book = try await Task.detached {
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
            var book = ReadingBook(title: "Owned renewal execution", author: "Owned", contentFilename: "owned.txt")
            book.isInBookshelf = true
            try JSONEncoder().encode([book]).write(to: app.appendingPathComponent("books_meta.json"))
            try Data("[]".utf8).write(to: app.appendingPathComponent("books_meta.reading.json"))
            try Data("[]".utf8).write(to: app.appendingPathComponent("book_sources.json"))
            return book
        }.value
        let books = try await BookStore.openForRenewalHandoff(metadataFileURL: app.appendingPathComponent("books_meta.json"))
        let sources = BookSourceStore(directory: app)
        _ = try await sources.normalLoadReceiptForRenewalHandoff()
        return try await MainActor.run {
            let positions = JSONFileReadingPositionStore(baseURL: app.appendingPathComponent("positions"), onSave: { _, _ in })
            let handoff = existingHandoff ?? SelfRenewalUserDataHandoff(clock: { date })
            try handoff.bind(books: books, sources: sources, positions: positions)
            let appearance = ReaderAppearance(theme: .sepia, fontSize: 18, lineHeightMultiple: 1.4,
                lineSpacing: 2, paragraphSpacing: 6, letterSpacing: 0, marginH: 24, marginV: 28,
                footerHeight: 20, writingMode: .horizontal)
            let state = ReaderPresentationState(location: ReaderLocation(position), direction: .ltr,
                spreadMode: .singlePage, viewportSize: CGSize(width: 320, height: 480), appearance: appearance, pagingStyle: .slide)
            let navigator = ReaderNavigator(initialState: state, positionStore: positions,
                bookId: book.id.uuidString, renewalHandoff: handoff)
            return Owners(books: books, sources: sources, positions: positions, handoff: handoff, navigator: navigator)
        }
    }
    nonisolated static func configuration(_ f: Package.Fixture, device: Session.DeviceConfiguration?) throws -> URL {
        let anchors = [f.oldAnchor] + f.issuer.certificateChainDER
        let value = Session.Configuration(schema: 1, namespaceID: f.namespace.id,
            codeAnchors: anchors, profileAnchors: anchors, device: device)
        let file = f.directory.appendingPathComponent("public-execution-configuration.json")
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        return file
    }
    nonisolated static func device(_ peer: Peer.Context) throws -> Session.DeviceConfiguration {
        var reference: CFTypeRef?
        guard SecItemCopyMatching([kSecClass as String: kSecClassIdentity,
            kSecValueRef as String: peer.pairing.hostIdentity, kSecReturnPersistentRef as String: true] as CFDictionary,
            &reference) == errSecSuccess, let reference = reference as? Data else { throw CocoaError(.coderInvalidValue) }
        return Session.DeviceConfiguration(identityPersistentReference: reference,
            deviceCertificateDER: peer.pairing.deviceCertificateDER, rootCertificateDER: peer.pairing.rootCertificateDER,
            hostID: peer.pairing.hostID, systemBUID: peer.pairing.systemBUID,
            numericAddress: peer.endpoint.numericAddress, port: peer.endpoint.port, interfaceIndex: peer.endpoint.interfaceIndex)
    }
    nonisolated static func record(_ root: URL) throws -> Journal.Record {
        let raw = try Data(contentsOf: root.appendingPathComponent("SelfRenewalTransactions/transaction.json"))
        guard raw.count <= Journal.Limits.recordBytes else { throw CocoaError(.fileReadTooLarge) }
        return try JSONDecoder().decode(Journal.Record.self, from: raw)
    }
    nonisolated static func candidate(_ root: URL, record: Journal.Record) throws -> Data {
        let candidate = try #require(record.candidate)
        let raw = try Data(contentsOf: root.appendingPathComponent("SelfRenewalTransactions/candidate.ipa"))
        #expect(raw.count == candidate.byteCount && raw.count <= 1_048_576)
        #expect(Data(SHA256.hash(data: raw)) == candidate.sha256)
        return raw
    }
}
#endif
