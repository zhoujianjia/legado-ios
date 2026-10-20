import CryptoKit
import Foundation
import Testing
import YueduCoreText
@testable import yuedu_app

@Suite("Actual App metadata position and source owners before the first Upgrade byte", .serialized)
struct SelfRenewalUserDataHandoffTests {
    typealias Package = SelfRenewalControlledPackageSignerTests
    typealias Peer = SelfRenewalAuthenticatedInstallationFixture
    typealias Journal = SelfRenewalTransactionJournal
    typealias Coordinator = SelfRenewalControlledRenewalCoordinator

    @Test("real file acknowledgments become durable Upgrade intent through the actual installer")
    func submitsOnlyAfterActualAppOwnerReceiptsAreDurable() async throws {
        try await Package.fixture { fixture in
            let owners = try await Self.owners(in: fixture.directory, date: fixture.date)
            let handoff = await owners.handoff
            let journal = try await Journal.open(at: fixture.directory.appendingPathComponent("SelfRenewalTransactions"))
            do {
                let coordinator = Coordinator(journal: journal, vault: fixture.vault,
                    namespace: fixture.namespace, clock: { fixture.date })
                let ready = try await coordinator.prepare(ipa: fixture.input, lease: fixture.lease,
                    originalCodeAnchors: [fixture.oldAnchor], originalProfileAnchors: [fixture.oldAnchor])
                let raw = try await Self.candidate(journal, ready)
                try await Peer.withPeer(bytes: raw, bundle: ready.record.bundleIdentifier,
                    version: ready.record.bundleVersion, at: fixture.date) { peer in
                    let completed = try await coordinator.submitWithAppDataHandoff(pairing: peer.pairing,
                        endpoint: peer.endpoint, handoff: handoff, timeoutSeconds: 12)
                    let proof = try #require(completed.snapshot.record.userDataHandoff)
                    #expect(proof.files.map(\.role) == ["shelf", "reading", "sources"])
                    #expect(proof.positions.count == 1)
                    #expect(proof.positions.first?.position == Self.position)
                    #expect(proof.processID == SelfRenewalInstalledMaterialObserver.ProcessIdentity.current.id)
                    #expect(!proof.allUserDataPreservationVerified && !completed.snapshot.record.renewalVerified)
                    let files = ["shelf": "books_meta.json", "reading": "books_meta.reading.json", "sources": "book_sources.json"]
                    for file in proof.files {
                        let name = try #require(files[file.role])
                        let data = try Data(contentsOf: fixture.directory.appendingPathComponent("app/" + name))
                        #expect(file.rawSHA256 == Data(SHA256.hash(data: data)))
                        #expect(file.rawByteCount == data.count)
                    }
                    let position = try #require(proof.positions.first)
                    let data = try Data(contentsOf: fixture.directory.appendingPathComponent("app/positions/" + position.bookID + ".json"))
                    #expect(position.rawSHA256 == Data(SHA256.hash(data: data)))
                    #expect(position.rawByteCount == data.count)
                    let decoded = try JSONDecoder().decode(CoreTextReadingPosition.self, from: data)
                    #expect(decoded == Self.position)
                    #expect(peer.observed.snapshot.upgradeRequests == 1)
                }
                let reopened = try await journal.load()
                #expect(reopened?.record.phase == .receiptObserved && reopened?.record.userDataHandoff != nil)
                // A real new owner can observe the actual saved bytes. It is
                // still the same test process, so this is not a cold launch.
                let app = fixture.directory.appendingPathComponent("app")
                let newBooks = try await BookStore.openForRenewalHandoff(metadataFileURL: app.appendingPathComponent("books_meta.json"))
                let newSources = BookSourceStore(directory: app)
                let newPositions = JSONFileReadingPositionStore(baseURL: app.appendingPathComponent("positions"), onSave: { _, _ in })
                let newHandoff = try await MainActor.run {
                    let useCase = SelfRenewalUserDataHandoff(clock: { fixture.date })
                    try useCase.bind(books: newBooks, sources: newSources, positions: newPositions)
                    return useCase
                }
                let observed = try await coordinator.observeUserDataAfterNormalLoad(handoff: newHandoff)
                #expect(observed?.record.userDataRead?.selectedFilesMatch == true)
                #expect(observed?.record.userDataReadInDifferentProcess == false)
                #expect(observed?.record.renewalVerified == false)
                try await coordinator.close()
            } catch {
                do { try await journal.close() } catch { Issue.record(error) }
                throw error
            }
        }
    }

    @Test("real source replacement failure leaves the remote upload owned and sends zero Upgrade frames")
    func actualSourceWriteFailurePreventsUpgradeAndKeepsPendingOwnership() async throws {
        try await Package.fixture { fixture in
            let owners = try await Self.owners(in: fixture.directory, date: fixture.date)
            let handoff = await owners.handoff
            let sourceURL = fixture.directory.appendingPathComponent("app/book_sources.json")
            try FileManager.default.removeItem(at: sourceURL)
            try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: false)
            let journal = try await Journal.open(at: fixture.directory.appendingPathComponent("SelfRenewalTransactions"))
            do {
                let coordinator = Coordinator(journal: journal, vault: fixture.vault,
                    namespace: fixture.namespace, clock: { fixture.date })
                let ready = try await coordinator.prepare(ipa: fixture.input, lease: fixture.lease,
                    originalCodeAnchors: [fixture.oldAnchor], originalProfileAnchors: [fixture.oldAnchor])
                let raw = try await Self.candidate(journal, ready)
                // Same real protocol peer; this mode permits the deliberately
                // rejected client to close without a positive Upgrade verdict.
                try await Peer.withPeer(.unusedInput, bytes: raw, bundle: ready.record.bundleIdentifier,
                    version: ready.record.bundleVersion, at: fixture.date) { peer in
                    do {
                        _ = try await coordinator.submitWithAppDataHandoff(pairing: peer.pairing,
                            endpoint: peer.endpoint, handoff: handoff, timeoutSeconds: 12)
                        Issue.record("Failed source write allowed Upgrade")
                    } catch let error as Coordinator.Interrupted {
                        guard error.underlying is BookSourcePersistenceFailure else { throw error }
                        #expect(!error.mayHaveSubmittedUpgrade)
                        #expect(error.persistedUpload?.record.phase == .uploadIntent)
                    }
                    let pending = try await journal.load()
                    #expect(pending?.record.phase == .uploadIntent && pending?.record.userDataHandoff == nil)
                    #expect(peer.observed.snapshot.uploaded == raw)
                    #expect(peer.observed.snapshot.upgradeRequests == 0)
                }
                let target = try sourceURL.resourceValues(forKeys: [.isDirectoryKey])
                #expect(target.isDirectory == true)
                try await coordinator.close()
            } catch {
                do { try await journal.close() } catch { Issue.record(error) }
                throw error
            }
        }
    }

    @Test("an unbound or foreign position owner cannot mint an App handoff proof")
    func rejectsUnboundAndForeignPositionOwnersBeforeSaving() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            let owners = try await Self.owners(in: root, date: Date())
            await MainActor.run {
                let unbound = SelfRenewalUserDataHandoff()
                let foreign = JSONFileReadingPositionStore(baseURL: root.appendingPathComponent("foreign"), onSave: { _, _ in })
                let navigator = Self.navigator(bookID: UUID().uuidString, store: foreign, handoff: unbound)
                // Kept alive through both async validations below.
                owners.extraNavigator = navigator
            }
            let unbound = await MainActor.run { SelfRenewalUserDataHandoff() }
            do { _ = try await unbound.prepareForSubmission(); Issue.record("Unbound owners acknowledged") }
            catch SelfRenewalUserDataHandoff.Failure.notBound {}
            await MainActor.run {
                guard let foreign = owners.extraNavigator else { preconditionFailure() }
                owners.handoff.register(foreign)
            }
            let handoff = await owners.handoff
            do { _ = try await handoff.prepareForSubmission(); Issue.record("Foreign progress owner acknowledged") }
            catch SelfRenewalUserDataHandoff.Failure.wrongOwner {}
            let paths = try await Task.detached {
                try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("app").path)
            }.value
            #expect(!paths.contains("positions") && !FileManager.default.fileExists(atPath: root.appendingPathComponent("foreign").path))
            try await Task.detached { try FileManager.default.removeItem(at: root) }.value
        } catch {
            do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) }
            throw error
        }
    }

    private static let position = CoreTextReadingPosition(spineIndex: 7, charOffset: 113, translationOffset: 19)
    @MainActor private final class Owners {
        let books: BookStore
        let sources: BookSourceStore
        let positions: JSONFileReadingPositionStore
        let handoff: SelfRenewalUserDataHandoff
        let navigator: ReaderNavigator
        var extraNavigator: ReaderNavigator?
        init(books: BookStore, sources: BookSourceStore, positions: JSONFileReadingPositionStore,
            handoff: SelfRenewalUserDataHandoff, navigator: ReaderNavigator) {
            self.books = books; self.sources = sources; self.positions = positions
            self.handoff = handoff; self.navigator = navigator
        }
    }
    private static func owners(in root: URL, date: Date) async throws -> Owners {
        let app = root.appendingPathComponent("app")
        let book = try await Task.detached {
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            var book = ReadingBook(title: "Owned handoff", author: "Owned", contentFilename: "owned.txt")
            book.isInBookshelf = true
            try JSONEncoder().encode([book]).write(to: app.appendingPathComponent("books_meta.json"))
            try Data("[]".utf8).write(to: app.appendingPathComponent("books_meta.reading.json"))
            try Data("[]".utf8).write(to: app.appendingPathComponent("book_sources.json"))
            return book
        }.value
        let books = try await BookStore.openForRenewalHandoff(metadataFileURL: app.appendingPathComponent("books_meta.json"))
        let sources = BookSourceStore(directory: app)
        let owners = try await MainActor.run {
            let positions = JSONFileReadingPositionStore(baseURL: app.appendingPathComponent("positions"), onSave: { _, _ in })
            let handoff = SelfRenewalUserDataHandoff(clock: { date })
            try handoff.bind(books: books, sources: sources, positions: positions)
            return Owners(books: books, sources: sources, positions: positions, handoff: handoff,
                navigator: Self.navigator(bookID: book.id.uuidString, store: positions, handoff: handoff))
        }
        _ = try await owners.sources.normalLoadReceiptForRenewalHandoff()
        return owners
    }
    @MainActor private static func navigator(bookID: String, store: any ReadingPositionStore,
        handoff: SelfRenewalUserDataHandoff) -> ReaderNavigator {
        let appearance = ReaderAppearance(theme: .sepia, fontSize: 18, lineHeightMultiple: 1.4,
            lineSpacing: 2, paragraphSpacing: 6, letterSpacing: 0, marginH: 24, marginV: 28,
            footerHeight: 20, writingMode: .horizontal)
        let state = ReaderPresentationState(location: ReaderLocation(position), direction: .ltr,
            spreadMode: .singlePage, viewportSize: CGSize(width: 320, height: 480), appearance: appearance, pagingStyle: .slide)
        return ReaderNavigator(initialState: state, positionStore: store, bookId: bookID, renewalHandoff: handoff)
    }
    private static func candidate(_ journal: Journal, _ snapshot: Journal.Snapshot) async throws -> Data {
        let candidate = try #require(snapshot.record.candidate)
        var raw = Data(); var offset = 0
        while offset < candidate.byteCount {
            let count = min(Journal.Limits.chunkBytes, candidate.byteCount - offset)
            raw.append(try await journal.readCandidate(snapshot, at: offset, count: count)); offset += count
        }
        return raw
    }
}
