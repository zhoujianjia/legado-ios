import Foundation
import Observation

/// The App injects one use case beside its existing file owners. These receipts
/// describe selected real persistence boundaries; they do not freeze downloads,
/// sync, future user edits, Keychain, source pins, content files or all user data.
@MainActor @Observable
final class SelfRenewalUserDataHandoff {
    enum Failure: Error, Sendable, Equatable {
        case notBound, wrongOwner, readerCoverageExceeded, duplicateBook, busy, changedDuringSave, invalidCheckpoint
    }
    struct Receipt: Sendable {
        let processID: UUID
        let capturedAt: Date
        let books: BookMetadataPersistenceReceipt
        let sources: BookSourcePersistenceReceipt
        let positions: [ReadingPositionPersistenceReceipt]
        var allUserDataPreservationVerified: Bool { false }
        fileprivate init(books: BookMetadataPersistenceReceipt, sources: BookSourcePersistenceReceipt,
            positions: [ReadingPositionPersistenceReceipt], at date: Date) {
            processID = SelfRenewalInstalledMaterialObserver.ProcessIdentity.current.id
            capturedAt = date; self.books = books; self.sources = sources; self.positions = positions
        }
    }
    struct NormalLoadObservation: Sendable {
        let expected: SelfRenewalTransactionJournal.UserDataCheckpoint
        let processID: UUID
        let observedAt: Date
        let books: BookMetadataPersistenceReceipt
        let sources: BookSourcePersistenceReceipt
        let positions: [ReadingPositionPersistenceReceipt?]
        var differentProcess: Bool { processID != expected.processID }
        /// Initial normal book/source reads and these later bounded position
        /// reads are distinct observations, not one atomic cold-launch instant.
        var selectedFilesMatch: Bool {
            guard books.phase == .normalLoad,
                  books.files.map(\.role) == [.shelf, .reading],
                  sources.operation == .normalFileRead,
                  positions.count == expected.positions.count else { return false }
            for file in books.files {
                guard [.read, .absent].contains(file.operation),
                      let before = expected.files.first(where: { $0.role == file.role.rawValue }),
                      before.rawByteCount == file.rawByteCount,
                      before.rawSHA256.map(Self.hex) == file.rawSHA256 else { return false }
            }
            guard let source = expected.files.first(where: { $0.role == "sources" }),
                  source.rawSHA256 == sources.rawSHA256, source.rawByteCount == sources.rawByteCount else { return false }
            return zip(expected.positions, positions).allSatisfy { pair in
                guard let actual = pair.1 else { return false }
                return actual.operation == .existingFileRead && pair.0.bookID == actual.bookId
                    && pair.0.position == actual.position && pair.0.rawSHA256 == actual.rawSHA256
                    && pair.0.rawByteCount == actual.rawByteCount
            }
        }
        var allUserDataPreservationVerified: Bool { false }
        fileprivate init(expected: SelfRenewalTransactionJournal.UserDataCheckpoint,
            books: BookMetadataPersistenceReceipt, sources: BookSourcePersistenceReceipt,
            positions: [ReadingPositionPersistenceReceipt?], at date: Date) {
            self.expected = expected; self.books = books; self.sources = sources; self.positions = positions
            processID = SelfRenewalInstalledMaterialObserver.ProcessIdentity.current.id; observedAt = date
        }
        private static func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
    }
    static let maximumReaders = 8
    private final class Reader {
        weak var navigator: ReaderNavigator?
        init(_ navigator: ReaderNavigator) { self.navigator = navigator }
    }
    private var readers: [ObjectIdentifier: Reader] = [:]
    private var readerRevision: UInt64 = 0
    private var coverageExceeded = false
    private var busy = false
    private weak var bookStore: BookStore?
    private weak var sourceStore: BookSourceStore?
    private var positionStore: (any ReadingPositionStore)?
    private let clock: () -> Date

    init(clock: @escaping () -> Date = { Date() }) { self.clock = clock }

    /// Binding only retains the actual owners; it performs no disk work. A
    /// second scene can repeat the identical binding, never swap in a new store.
    func bind(books: BookStore, sources: BookSourceStore, positions: any ReadingPositionStore) throws {
        if let bookStore, bookStore !== books { throw Failure.wrongOwner }
        if let sourceStore, sourceStore !== sources { throw Failure.wrongOwner }
        if let positionStore, positionStore !== positions { throw Failure.wrongOwner }
        bookStore = books; sourceStore = sources; positionStore = positions
    }

    /// Called synchronously by the actual Navigator constructor. Weak entries
    /// do not prolong closed reader sessions; coverage cannot silently truncate.
    func register(_ navigator: ReaderNavigator) {
        let identity = ObjectIdentifier(navigator)
        if readers[identity]?.navigator === navigator { return }
        readers = readers.filter { $0.value.navigator != nil }
        readerRevision &+= 1
        guard readers.count < Self.maximumReaders else {
            coverageExceeded = true
            AppLogger.error("Renewal handoff exceeded the supported active reader count")
            return
        }
        readers[identity] = Reader(navigator)
    }

    /// The real before-Upgrade hook awaits this use case. It checks revisions
    /// after awaits rather than sleeping/retrying or pausing the reader's UI.
    func prepareForSubmission() async throws -> Receipt {
        guard !busy else { throw Failure.busy }
        guard !coverageExceeded else { throw Failure.readerCoverageExceeded }
        guard let bookStore, let sourceStore, let positionStore else { throw Failure.notBound }
        busy = true; defer { busy = false }
        try Task.checkCancellation()
        readers = readers.filter { $0.value.navigator != nil }
        let revision = readerRevision
        let active = readers.values.compactMap(\.navigator)
        guard active.allSatisfy({ $0.usesPositionStore(positionStore) }) else { throw Failure.wrongOwner }
        guard Set(active.map(\.persistenceBookIdentity)).count == active.count else { throw Failure.duplicateBook }
        var positions: [ReadingPositionPersistenceReceipt] = []
        for navigator in active {
            try Task.checkCancellation()
            positions.append(try await navigator.flushForRenewalHandoff())
        }
        guard Set(positions.map(\.bookId)).count == positions.count else { throw Failure.duplicateBook }
        let books = try await bookStore.saveForRenewalHandoff()
        try Task.checkCancellation()
        let sources = try await sourceStore.saveForRenewalHandoff()
        try Task.checkCancellation()
        guard revision == readerRevision, !coverageExceeded,
              books.localRevision == bookStore.mutationRevision,
              sources.mutationRevision == sourceStore.mutationRevision,
              zip(active, positions).allSatisfy({ pair in pair.0.currentLocation == pair.1.position }) else {
            throw Failure.changedDuringSave
        }
        return Receipt(books: books, sources: sources,
            positions: positions.sorted { $0.bookId < $1.bookId }, at: clock())
    }

    /// Uses each existing store's original normal-load proof and the one
    /// position owner. No reload/repair or whole metadata reread is performed.
    func observeNormalLoad(expected: SelfRenewalTransactionJournal.UserDataCheckpoint) async throws -> NormalLoadObservation {
        guard !busy else { throw Failure.busy }
        guard let bookStore, let sourceStore, let positionStore else { throw Failure.notBound }
        guard expected.files.map(\.role) == ["shelf", "reading", "sources"],
              expected.positions.count <= Self.maximumReaders else { throw Failure.invalidCheckpoint }
        busy = true; defer { busy = false }
        try Task.checkCancellation()
        let books = try await bookStore.normalLoadReceiptForRenewalHandoff()
        let sources = try await sourceStore.normalLoadReceiptForRenewalHandoff()
        var positions: [ReadingPositionPersistenceReceipt?] = []
        for position in expected.positions {
            try Task.checkCancellation()
            positions.append(try await positionStore.loadChecked(for: position.bookID))
        }
        try Task.checkCancellation()
        return NormalLoadObservation(expected: expected, books: books, sources: sources,
            positions: positions, at: clock())
    }
}
