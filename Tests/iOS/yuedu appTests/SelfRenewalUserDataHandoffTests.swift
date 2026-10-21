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

// Test-only bridge into the existing two real C5 hosts. These facts are not an
// installed-material observation, a replacement proof, or Apple authorization.
extension SelfRenewalUserDataHandoffTests {
    struct ColdNull: Codable, Sendable {
        init() {}
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            guard container.decodeNil() else { throw ColdFailure.invalid("Expected absent installation observation") }
        }
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer(); try container.encodeNil()
        }
    }
    struct ColdProducerFacts: Codable, Sendable {
        let schemaVersion: Int; let transactionID: UUID; let phase: String; let revision: UInt64
        let recordSHA256: String; let candidateBytes: Int; let candidateSHA256: String
        let preparationProcessID: UUID; let handoffProcessID: UUID; let clockEpochSeconds: Double
        let files: [String: String]; let positionSHA256: String; let positionBytes: Int
        let uploadBytes: Int; let uploadSHA256: String; let upgradeRequests: Int; let lookupRequests: Int
        let reportedCompleteCleanup: Bool; let installedMaterial: ColdNull; let installedDifferentProcess: ColdNull
        let renewalVerified: Bool
    }
    struct ColdConsumerFacts: Codable, Sendable {
        let schemaVersion: Int; let transactionID: UUID; let phase: String; let beforeRevision: UInt64; let revision: UInt64
        let beforeRecordSHA256: String; let recordSHA256: String; let candidateBytes: Int; let candidateSHA256: String
        let handoffProcessID: UUID; let normalReadProcessID: UUID; let clockEpochSeconds: Double
        let dataReadInDifferentProcess: Bool; let selectedFilesMatch: Bool; let sourceWasBootstrapped: Bool
        let unchangedExceptDataRead: Bool; let candidateFileUnchanged: Bool; let recoveryOnly: Bool
        let installedMaterial: ColdNull; let installedDifferentProcess: ColdNull; let renewalVerified: Bool
    }
    private enum ColdFailure: Error { case invalid(String) }
    private struct ColdCleanupFailure: Error { let underlying: Error; let cleanup: Error }
    private actor ColdResult {
        private var value: ColdProducerFacts?
        func store(_ value: ColdProducerFacts) { self.value = value }
        func require() throws -> ColdProducerFacts {
            guard let value else { throw ColdFailure.invalid("Controlled submission produced no receipt") }
            return value
        }
    }
    @MainActor private final class ColdOwners {
        let sources: BookSourceStore
        let handoff: SelfRenewalUserDataHandoff
        let navigator: ReaderNavigator
        init(sources: BookSourceStore, handoff: SelfRenewalUserDataHandoff, navigator: ReaderNavigator) {
            self.sources = sources; self.handoff = handoff; self.navigator = navigator
        }
    }

    nonisolated static func coldSubmit(in data: URL, bookID: UUID, books: BookStore,
        source: BookSource, positions: JSONFileReadingPositionStore,
        position: CoreTextReadingPosition) async throws -> ColdProducerFacts {
        let result = ColdResult()
        try await Package.fixture { fixture in
            let parent = data.appendingPathComponent("renewal", isDirectory: true)
            try await Task.detached {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
                // An explicitly empty owned normal library avoids built-in
                // bootstrap; the source itself enters through the normal owner.
                try Data("[]".utf8).write(to: data.appendingPathComponent("book_sources.json"), options: .withoutOverwriting)
            }.value
            let owners = try await MainActor.run {
                let sources = BookSourceStore(directory: data)
                let handoff = SelfRenewalUserDataHandoff(clock: { fixture.date })
                try handoff.bind(books: books, sources: sources, positions: positions)
                let appearance = ReaderAppearance(theme: .sepia, fontSize: 18, lineHeightMultiple: 1.4,
                    lineSpacing: 2, paragraphSpacing: 6, letterSpacing: 0, marginH: 24, marginV: 28,
                    footerHeight: 20, writingMode: .horizontal)
                let state = ReaderPresentationState(location: ReaderLocation(position), direction: .ltr,
                    spreadMode: .singlePage, viewportSize: CGSize(width: 320, height: 480),
                    appearance: appearance, pagingStyle: .slide)
                let navigator = ReaderNavigator(initialState: state, positionStore: positions,
                    bookId: bookID.uuidString, renewalHandoff: handoff)
                return ColdOwners(sources: sources, handoff: handoff, navigator: navigator)
            }
            _ = try await owners.sources.normalLoadReceiptForRenewalHandoff()
            await MainActor.run { owners.sources.add(source) }
            let handoffOwner = await owners.handoff
            let root = parent.appendingPathComponent("SelfRenewalTransactions", isDirectory: true)
            let journal = try await Journal.open(at: root)
            do {
                let coordinator = Coordinator(journal: journal, vault: fixture.vault,
                    namespace: fixture.namespace, clock: { fixture.date })
                let ready = try await coordinator.prepare(ipa: fixture.input, lease: fixture.lease,
                    originalCodeAnchors: [fixture.oldAnchor], originalProfileAnchors: [fixture.oldAnchor])
                let raw = try await coldCandidate(journal, ready)
                try await Peer.withPeer(bytes: raw, bundle: ready.record.bundleIdentifier,
                    version: ready.record.bundleVersion, at: fixture.date) { peer in
                    let completed = try await coordinator.submitWithAppDataHandoff(pairing: peer.pairing,
                        endpoint: peer.endpoint, handoff: handoffOwner, timeoutSeconds: 12)
                    let record = completed.snapshot.record
                    guard let handoff = record.userDataHandoff, let candidate = record.candidate,
                          let preparation = record.preparationProcessID, let seal = record.reportedCompleteCleanup else {
                        throw ColdFailure.invalid("Real submission omitted its persisted checkpoints")
                    }
                    let process = SelfRenewalInstalledMaterialObserver.ProcessIdentity.current.id
                    try coldCheck(record.phase == .receiptObserved && handoff.processID == process
                        && preparation == process && record.installedMaterial == nil && record.userDataRead == nil
                        && record.observedDifferentProcess == nil && !record.renewalVerified
                        && seal.origin == .installerReceipt && seal.candidate == candidate
                        && handoff.files.map(\.role) == ["shelf", "reading", "sources"] && handoff.sourceCount == 1,
                        "Submission cannot manufacture an installation or cold-read proof")
                    guard handoff.positions.count == 1, let saved = handoff.positions.first else {
                        throw ColdFailure.invalid("The real active navigator was not checkpointed")
                    }
                    try coldCheck(saved.bookID == bookID.uuidString && saved.position == position,
                        "The actual navigator checkpoint differs from reader progress")
                    // A strong use after submit ensures the weak registration
                    // remained live for the whole actual before-Upgrade hook.
                    let retained = await MainActor.run { owners.navigator.persistenceBookIdentity }
                    try coldCheck(retained == bookID.uuidString, "The active reader owner changed")
                    var files: [String: String] = [:]
                    let paths = ["shelf": "books_meta.json", "reading": "books_meta.reading.json", "sources": "book_sources.json"]
                    for file in handoff.files {
                        guard let path = paths[file.role], let hash = file.rawSHA256 else {
                            throw ColdFailure.invalid("A selected normal owner acknowledged no actual file")
                        }
                        let bytes = try coldBytes(data.appendingPathComponent(path), maximum: 16_777_216)
                        try coldCheck(bytes.count == file.rawByteCount && Data(SHA256.hash(data: bytes)) == hash,
                            "Handoff file differs from its real write receipt")
                        files[file.role] = coldHex(hash)
                    }
                    let positionBytes = try coldBytes(data.appendingPathComponent("positions/" + bookID.uuidString + ".json"), maximum: 65_536)
                    try coldCheck(positionBytes.count == saved.rawByteCount
                        && Data(SHA256.hash(data: positionBytes)) == saved.rawSHA256,
                        "Position checkpoint differs from its real write receipt")
                    let observed = peer.observed.snapshot
                    try coldCheck(observed.upgradeRequests == 1 && observed.lookupRequests == 1
                        && observed.uploaded == raw && raw.count == candidate.byteCount
                        && Data(SHA256.hash(data: raw)) == candidate.sha256,
                        "The controlled real TLS peer did not receive exactly this candidate")
                    let recordBytes = try coldBytes(root.appendingPathComponent("transaction.json"), maximum: Journal.Limits.recordBytes)
                    await result.store(ColdProducerFacts(schemaVersion: 1, transactionID: record.id,
                        phase: record.phase.rawValue, revision: record.revision, recordSHA256: coldHash(recordBytes),
                        candidateBytes: candidate.byteCount, candidateSHA256: coldHex(candidate.sha256),
                        preparationProcessID: preparation, handoffProcessID: handoff.processID,
                        clockEpochSeconds: fixture.date.timeIntervalSince1970, files: files,
                        positionSHA256: coldHex(saved.rawSHA256), positionBytes: saved.rawByteCount,
                        uploadBytes: observed.uploaded.count, uploadSHA256: coldHash(observed.uploaded),
                        upgradeRequests: observed.upgradeRequests, lookupRequests: observed.lookupRequests,
                        reportedCompleteCleanup: record.reportedCompleteCleanup != nil,
                        installedMaterial: ColdNull(), installedDifferentProcess: ColdNull(), renewalVerified: record.renewalVerified))
                }
                try await coordinator.close()
            } catch {
                let underlying = error
                do { try await journal.close() } catch { throw ColdCleanupFailure(underlying: underlying, cleanup: error) }
                throw underlying
            }
        }
        // Package.fixture has now removed only its temporary material/Keychain
        // namespace. The journal is outside that directory and remains on disk.
        return try await result.require()
    }

    nonisolated static func coldObserve(in data: URL, bookID: UUID, books: BookStore,
        sources: BookSourceStore, positions: JSONFileReadingPositionStore,
        producer: ColdProducerFacts) async throws -> ColdConsumerFacts {
        let root = data.appendingPathComponent("renewal/SelfRenewalTransactions", isDirectory: true)
        let journal = try await Journal.open(at: root)
        do {
            guard let before = try await journal.load(), let candidate = before.record.candidate,
                  let handoff = before.record.userDataHandoff else { throw ColdFailure.invalid("Cold checkpoint is absent") }
            let beforeBytes = try await Task.detached { try coldBytes(root.appendingPathComponent("transaction.json"), maximum: Journal.Limits.recordBytes) }.value
            let raw = try await coldCandidate(journal, before)
            let current = SelfRenewalInstalledMaterialObserver.ProcessIdentity.current.id
            try coldCheck(producer.schemaVersion == 1 && before.record.id == producer.transactionID
                && before.record.phase == .receiptObserved && before.record.phase.rawValue == producer.phase
                && before.record.revision == producer.revision && coldHash(beforeBytes) == producer.recordSHA256
                && candidate.byteCount == producer.candidateBytes && coldHex(candidate.sha256) == producer.candidateSHA256
                && handoff.processID == producer.handoffProcessID && current != handoff.processID
                && before.record.preparationProcessID == producer.preparationProcessID
                && handoff.positions.count == 1 && handoff.positions.first?.bookID == bookID.uuidString
                && before.record.userDataRead == nil && before.record.installedMaterial == nil
                && before.record.reportedCompleteCleanup != nil && before.record.observedDifferentProcess == nil
                && !before.record.renewalVerified, "Cold journal does not belong to this producer/checkpoint")
            let date = Date(timeIntervalSince1970: producer.clockEpochSeconds)
            let useCase = try await MainActor.run {
                let value = SelfRenewalUserDataHandoff(clock: { date })
                try value.bind(books: books, sources: sources, positions: positions)
                return value
            }
            let coordinator = try await Coordinator.recoveryOnly(journal: journal, clock: { date })
            let recoveryOnly = await coordinator.isRecoveryOnly()
            guard let after = try await coordinator.observeUserDataAfterNormalLoad(handoff: useCase),
                  let read = after.record.userDataRead else { throw ColdFailure.invalid("Normal owners produced no data-read observation") }
            var expected = before.record
            expected.userDataRead = read; expected.revision = after.record.revision; expected.updatedAt = after.record.updatedAt
            let unchanged = expected == after.record
            let kept = try await coldCandidate(journal, after)
            let candidateUnchanged = kept == raw
            try coldCheck(recoveryOnly && unchanged && candidateUnchanged
                && after.record.revision == before.record.revision + 1 && after.record.phase == .receiptObserved
                && read.processID == current && after.record.userDataReadInDifferentProcess == true
                && read.selectedFilesMatch && !read.sourceWasBootstrapped && after.record.installedMaterial == nil
                && after.record.observedDifferentProcess == nil && !after.record.renewalVerified,
                "Cold observation changed more than selected data-read facts or lost normal owner bytes")
            let afterBytes = try await Task.detached { try coldBytes(root.appendingPathComponent("transaction.json"), maximum: Journal.Limits.recordBytes) }.value
            let result = ColdConsumerFacts(schemaVersion: 1, transactionID: after.record.id, phase: after.record.phase.rawValue,
                beforeRevision: before.record.revision, revision: after.record.revision,
                beforeRecordSHA256: coldHash(beforeBytes), recordSHA256: coldHash(afterBytes),
                candidateBytes: candidate.byteCount, candidateSHA256: coldHex(candidate.sha256),
                handoffProcessID: handoff.processID, normalReadProcessID: read.processID,
                clockEpochSeconds: producer.clockEpochSeconds, dataReadInDifferentProcess: after.record.userDataReadInDifferentProcess == true,
                selectedFilesMatch: read.selectedFilesMatch, sourceWasBootstrapped: read.sourceWasBootstrapped,
                unchangedExceptDataRead: unchanged, candidateFileUnchanged: candidateUnchanged, recoveryOnly: recoveryOnly,
                installedMaterial: ColdNull(), installedDifferentProcess: ColdNull(), renewalVerified: after.record.renewalVerified)
            try await coordinator.close()
            return result
        } catch {
            let underlying = error
            do { try await journal.close() } catch { throw ColdCleanupFailure(underlying: underlying, cleanup: error) }
            throw underlying
        }
    }
    nonisolated private static func coldCandidate(_ journal: Journal, _ snapshot: Journal.Snapshot) async throws -> Data {
        guard let candidate = snapshot.record.candidate, candidate.byteCount > 0, candidate.byteCount <= 1_048_576 else {
            throw ColdFailure.invalid("Controlled fixture candidate exceeded its test-only bound")
        }
        var raw = Data(); var offset = 0
        while offset < candidate.byteCount {
            let count = min(Journal.Limits.chunkBytes, candidate.byteCount - offset)
            raw.append(try await journal.readCandidate(snapshot, at: offset, count: count)); offset += count
        }
        try coldCheck(raw.count == candidate.byteCount && Data(SHA256.hash(data: raw)) == candidate.sha256,
            "The persisted candidate differs from its journal commitment")
        return raw
    }
    nonisolated private static func coldBytes(_ url: URL, maximum: Int) throws -> Data {
        precondition(!Thread.isMainThread)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue >= 0, size.intValue <= maximum else {
            throw ColdFailure.invalid("Cold evidence is not a bounded actual regular file")
        }
        return try SourcePerfTrace.span("renewal.cold.fixture.read", "main=\(Thread.isMainThread) bytes=\(size.intValue)") {
            try Data(contentsOf: url)
        }
    }
    nonisolated private static func coldCheck(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ColdFailure.invalid(message) }
    }
    nonisolated private static func coldHex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    nonisolated private static func coldHash(_ data: Data) -> String { coldHex(Data(SHA256.hash(data: data))) }
}
