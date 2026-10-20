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

    @Test("App owner prepares actual imported bytes then explicitly submits with real owner acknowledgements")
    func appOwnerPreparesAndSubmitsActualCandidateWithoutAutomaticRetry() async throws {
        try await Package.fixture { f in
            let application = try await Self.application(f)
            let root = f.directory.appendingPathComponent("SelfRenewalApp")
            let owner = await MainActor.run {
                SelfRenewalAppOwner(root: root, currentApplicationRoot: application, clock: { f.date })
            }
            let owners = try await Self.library(in: f.directory, at: f.date, handoff: owner.handoff)
            do {
                await owner.start(books: owners.books, sources: owners.sources, positions: owners.positions)
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
                    #expect(handoff.files.map(\.role) == ["shelf", "reading", "sources"])
                    #expect(handoff.positions.count == 1 && handoff.positions.first?.position == Self.position)
                    #expect(!handoff.allUserDataPreservationVerified && !completed.renewalVerified)
                    #expect(peer.observed.snapshot.upgradeRequests == 1)
                    #expect(peer.observed.snapshot.uploaded == raw)
                    let before = try Data(contentsOf: root.appendingPathComponent("SelfRenewalTransactions/transaction.json"))
                    await owner.submitPreparedRenewal()
                    await owner.prepareRenewal(from: f.input)
                    #expect(peer.observed.snapshot.upgradeRequests == 1)
                    #expect(try Data(contentsOf: root.appendingPathComponent("SelfRenewalTransactions/transaction.json")) == before)
                    let refused = await MainActor.run { (owner.problem, owner.recoveryAvailable, owner.status?.phase) }
                    #expect(refused.0 != nil && refused.1 && refused.2 == .receiptObserved)
                }
                try await owner.close()
            } catch {
                do { try await owner.close() } catch { Issue.record(error) }
                throw error
            }
        }
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
                await owner.start(books: owners.books, sources: owners.sources, positions: owners.positions)
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
                    await owner.start(books: owners.books, sources: owners.sources, positions: owners.positions)
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
