import Foundation
import XCTest
@testable import yuedu_app

@MainActor
final class ReadingPositionStorePersistenceTests: XCTestCase {
    func testSavingRecreatesAReadingPositionDirectoryRemovedAfterInitialization() async throws {
        let root = temporaryRoot()
        defer { removeTemporaryRoot(root) }
        let directory = root.appendingPathComponent("positions", isDirectory: true)
        let saves = SaveRecorder()
        let store = JSONFileReadingPositionStore(baseURL: directory, onSave: { saves.record($0, for: $1) })
        let first = CoreTextReadingPosition(spineIndex: 2, charOffset: 18)
        let latest = CoreTextReadingPosition(spineIndex: 3, charOffset: 92)

        await store.save(first, for: "book")
        XCTAssertEqual(store.loadSync(for: "book"), first)
        try FileManager.default.removeItem(at: directory)

        await store.save(latest, for: "book")
        await store.flush(for: "book")

        let reopened = JSONFileReadingPositionStore(baseURL: directory, onSave: { saves.record($0, for: $1) })
        XCTAssertEqual(reopened.loadSync(for: "book"), latest)
        XCTAssertEqual(saves.positions, [first, latest])
        XCTAssertEqual(saves.bookIDs, ["book", "book"])
    }

    func testFailedWritePreservesPreviousFileAndDoesNotPublishASuccess() async throws {
        let root = temporaryRoot()
        defer { removeTemporaryRoot(root) }
        let writer = FaultInjectingWriter()
        let saves = SaveRecorder()
        let store = JSONFileReadingPositionStore(
            baseURL: root,
            writeData: { try writer.write($0, to: $1) },
            onSave: { saves.record($0, for: $1) }
        )
        let old = CoreTextReadingPosition(spineIndex: 4, charOffset: 61, translationOffset: 9)
        let latest = CoreTextReadingPosition(spineIndex: 5, charOffset: 84)
        let file = root.appendingPathComponent("book.json", isDirectory: false)
        await store.save(old, for: "book")
        let oldBytes = try Data(contentsOf: file)

        // Simulate the filesystem rejecting the replacement, without chmod or
        // simulator-specific assumptions about atomic-renaming permissions.
        writer.failWrites = true
        await store.save(latest, for: "book")
        await store.flush(for: "book")

        XCTAssertEqual(try Data(contentsOf: file), oldBytes)
        XCTAssertEqual(store.loadSync(for: "book"), old)
        XCTAssertEqual(saves.positions, [old])
        XCTAssertEqual(saves.bookIDs, ["book"])
        XCTAssertEqual(writer.attemptCount, 2)
        XCTAssertFalse(writer.wasCalledOnMainThread)
    }

    func testCorruptProgressIsPreservedAndNeverPublishedAsASuccess() async throws {
        let root = temporaryRoot()
        defer { removeTemporaryRoot(root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("book.json", isDirectory: false)
        let original = Data("{\"spineIndex\":4,\"charOffset\":".utf8)
        try original.write(to: file, options: .atomic)
        let saves = SaveRecorder()
        let store = JSONFileReadingPositionStore(baseURL: root, onSave: { saves.record($0, for: $1) })

        XCTAssertNil(store.loadSync(for: "book"))
        let asynchronouslyLoaded = await store.load(for: "book")
        XCTAssertNil(asynchronouslyLoaded)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["book.json"])
        XCTAssertTrue(saves.positions.isEmpty)
    }

    func testCompletedSaveIsRestoredByANewStoreIncludingTranslationOffset() async throws {
        let root = temporaryRoot()
        defer { removeTemporaryRoot(root) }
        let saves = SaveRecorder()
        let store = JSONFileReadingPositionStore(baseURL: root, onSave: { saves.record($0, for: $1) })
        let position = CoreTextReadingPosition(spineIndex: 6, charOffset: 142, translationOffset: 37)

        await store.save(position, for: "book")
        await store.flush(for: "book")

        let reopened = JSONFileReadingPositionStore(baseURL: root, onSave: { saves.record($0, for: $1) })
        XCTAssertEqual(reopened.loadSync(for: "book"), position)
        let asynchronouslyLoaded = await reopened.load(for: "book")
        XCTAssertEqual(asynchronouslyLoaded, position)
        XCTAssertEqual(saves.positions, [position])
    }

    func testMissingProgressDoesNotCreateOrPublishAReplacement() async {
        let root = temporaryRoot()
        defer { removeTemporaryRoot(root) }
        let saves = SaveRecorder()
        let store = JSONFileReadingPositionStore(baseURL: root, onSave: { saves.record($0, for: $1) })

        XCTAssertNil(store.loadSync(for: "book"))
        let asynchronouslyLoaded = await store.load(for: "book")
        XCTAssertNil(asynchronouslyLoaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(saves.positions.isEmpty)
    }

    func testCheckedAtomicReceiptMatchesRawFileAndReopenedOwner() async throws {
        let root = temporaryRoot()
        defer { removeTemporaryRoot(root) }
        let saves = SaveRecorder()
        let store = JSONFileReadingPositionStore(baseURL: root, onSave: { saves.record($0, for: $1) })
        let position = CoreTextReadingPosition(spineIndex: 6, charOffset: 142, translationOffset: 37)
        let saved = try await store.saveChecked(position, for: "book-A")
        let file = root.appendingPathComponent("book-A.json")
        let raw = try await Task.detached { try Data(contentsOf: file) }.value
        XCTAssertEqual(saved.bookId, "book-A")
        XCTAssertEqual(saved.position, position)
        XCTAssertEqual(saved.operation, .atomicWriteCompleted)
        XCTAssertEqual(saved.rawSHA256, Data(SHA256.hash(data: raw)))
        XCTAssertEqual(saved.rawByteCount, raw.count)
        XCTAssertEqual(saves.positions, [position])
        let reopened = JSONFileReadingPositionStore(baseURL: root, onSave: { saves.record($0, for: $1) })
        let loadedReceipt1 = try await reopened.loadChecked(for: "book-A")
        let read = try XCTUnwrap(loadedReceipt1)
        XCTAssertEqual(read.bookId, saved.bookId)
        XCTAssertEqual(read.position, saved.position)
        XCTAssertEqual(read.rawSHA256, saved.rawSHA256)
        XCTAssertEqual(read.rawByteCount, saved.rawByteCount)
        XCTAssertEqual(read.operation, .existingFileRead)
        let different = try await reopened.saveChecked(.chapterStart(9), for: "book-B")
        XCTAssertEqual(different.bookId, "book-B")
        XCTAssertEqual(saved.position, position)
        let loadedReceipt2 = try await reopened.loadChecked(for: "book-A")
        let original = try XCTUnwrap(loadedReceipt2)
        XCTAssertEqual(original.rawSHA256, saved.rawSHA256)
        XCTAssertEqual(original.position, saved.position)
    }

    func testCheckedLoadHashesOriginalJSONAndDistinguishesMissingCorruptAndBounds() async throws {
        let root = temporaryRoot()
        defer { removeTemporaryRoot(root) }
        let store = JSONFileReadingPositionStore(baseURL: root, onSave: { _, _ in XCTFail("Read must not publish a save") })
        let missing = try await store.loadChecked(for: "book")
        XCTAssertNil(missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let file = root.appendingPathComponent("book.json")
        let raw = Data("{ \n\"charOffset\": 142, \"spineIndex\": 6, \"translationOffset\": 37 }\n".utf8)
        try await Task.detached {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try raw.write(to: file, options: .atomic)
        }.value
        let loadedReceipt3 = try await store.loadChecked(for: "book")
        let receipt = try XCTUnwrap(loadedReceipt3)
        // Python hashlib over the owned literal above, independently frozen.
        XCTAssertEqual(receipt.rawSHA256.map { String(format: "%02x", $0) }.joined(), "e8aba37aa93342aabf5d5cf1d7ff54f8b6ff0ea8f010943e20f7e0284392e99b")
        XCTAssertEqual(receipt.rawByteCount, raw.count)
        XCTAssertEqual(receipt.position, CoreTextReadingPosition(spineIndex: 6, charOffset: 142, translationOffset: 37))
        let corrupt = Data("{\"spineIndex\":4,".utf8)
        try await Task.detached { try corrupt.write(to: file, options: .atomic) }.value
        do { _ = try await store.loadChecked(for: "book"); XCTFail("Corrupt progress became missing") }
        catch ReadingPositionPersistenceFailure.corruptJSON {}
        let afterCorruption = try await Task.detached { try Data(contentsOf: file) }.value
        XCTAssertEqual(afterCorruption, corrupt)
        let oversized = Data(repeating: 0x20, count: JSONFileReadingPositionStore.Limits.positionBytes + 1)
        try await Task.detached { try oversized.write(to: file, options: .atomic) }.value
        do { _ = try await store.loadChecked(for: "book"); XCTFail("Oversized file was loaded") }
        catch ReadingPositionPersistenceFailure.fileTooLarge {}
        let afterBounds = try await Task.detached { try Data(contentsOf: file) }.value
        XCTAssertEqual(afterBounds, oversized)
        try await Task.detached {
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        }.value
        do { _ = try await store.loadChecked(for: "book"); XCTFail("A directory became missing") }
        catch ReadingPositionPersistenceFailure.invalidFileType {}
    }

    func testCheckedWriteFailureAndUnsupportedBackendsNeverReturnSuccess() async throws {
        let root = temporaryRoot()
        defer { removeTemporaryRoot(root) }
        let file = root.appendingPathComponent("book.json")
        try await Task.detached { try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true) }.value
        let saves = SaveRecorder()
        let real = JSONFileReadingPositionStore(baseURL: root, onSave: { saves.record($0, for: $1) })
        do { _ = try await real.saveChecked(.chapterStart(2), for: "book"); XCTFail("A failed atomic replacement returned a receipt") }
        catch ReadingPositionPersistenceFailure.writeFailed {}
        XCTAssertTrue(saves.positions.isEmpty)
        let contents = try await Task.detached { try FileManager.default.contentsOfDirectory(atPath: file.path) }.value
        XCTAssertTrue(contents.isEmpty)
        let injected = JSONFileReadingPositionStore(baseURL: root,
            writeData: { _, _ in XCTFail("Strict receipt must not use an arbitrary injected writer") },
            onSave: { _, _ in XCTFail("Unsupported write reported success") })
        do { _ = try await injected.saveChecked(.chapterStart(3), for: "other"); XCTFail("Legacy writer manufactured a receipt") }
        catch ReadingPositionPersistenceFailure.unsupported {}
        let legacy = PositionHandoffLegacyStore()
        do { _ = try await legacy.saveChecked(.chapterStart(3), for: "other"); XCTFail("Legacy mock manufactured a receipt") }
        catch ReadingPositionPersistenceFailure.unsupported {}
        do { _ = try await legacy.loadChecked(for: "other"); XCTFail("Legacy nil load became proven missing") }
        catch ReadingPositionPersistenceFailure.unsupported {}
        do { _ = try await real.saveChecked(.chapterStart(0), for: "../outside"); XCTFail("Path identity was accepted") }
        catch ReadingPositionPersistenceFailure.invalidBookIdentity {}
        let invalidRoot = JSONFileReadingPositionStore(baseURL: URL(string: "https://owned.invalid/positions")!, onSave: { _, _ in XCTFail("Invalid root reported success") })
        do { _ = try await invalidRoot.loadChecked(for: "book"); XCTFail("Non-file URL became a local-file observation") }
        catch ReadingPositionPersistenceFailure.invalidRoot {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("other.json").path))
    }

    func testNavigatorHandoffPersistsCapturedTranslationAndRejectsLegacyOwner() async throws {
        let root = temporaryRoot()
        defer { removeTemporaryRoot(root) }
        let saved = SaveRecorder()
        let store = JSONFileReadingPositionStore(baseURL: root, onSave: { saved.record($0, for: $1) })
        let position = CoreTextReadingPosition(spineIndex: 8, charOffset: 321, translationOffset: 27)
        let navigator = handoffNavigator(position: .chapterStart(0), store: store)
        navigator.scrollCommit(to: position)
        let receipt = try await navigator.flushForRenewalHandoff()
        XCTAssertEqual(receipt.position, position)
        XCTAssertEqual(receipt.bookId, "navigator-book")
        let reopened = JSONFileReadingPositionStore(baseURL: root, onSave: { _, _ in XCTFail("Load published a save") })
        let loadedReceipt4 = try await reopened.loadChecked(for: "navigator-book")
        let restored = try XCTUnwrap(loadedReceipt4)
        XCTAssertEqual(restored.position, position)
        XCTAssertEqual(restored.rawSHA256, receipt.rawSHA256)
        XCTAssertEqual(saved.positions, [position])
        let legacy = handoffNavigator(position: position, store: PositionHandoffLegacyStore())
        do { _ = try await legacy.flushForRenewalHandoff(); XCTFail("Navigator accepted void legacy persistence") }
        catch ReadingPositionPersistenceFailure.unsupported {}
        let missing = handoffNavigator(position: position, store: nil)
        do { _ = try await missing.flushForRenewalHandoff(); XCTFail("Navigator without a store returned success") }
        catch ReadingPositionPersistenceFailure.unsupported {}
    }

    private func handoffNavigator(position: CoreTextReadingPosition, store: (any ReadingPositionStore)?) -> ReaderNavigator {
        let appearance = ReaderAppearance(theme: .sepia, fontSize: 18, lineHeightMultiple: 1.4,
            lineSpacing: 2, paragraphSpacing: 6, letterSpacing: 0, marginH: 24, marginV: 28,
            footerHeight: 20, writingMode: .horizontal)
        return ReaderNavigator(initialState: ReaderPresentationState(location: ReaderLocation(position), direction: .ltr,
            spreadMode: .singlePage, viewportSize: CGSize(width: 320, height: 480), appearance: appearance, pagingStyle: .slide),
            positionStore: store, bookId: "navigator-book")
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadingPositionStorePersistenceTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func removeTemporaryRoot(_ root: URL) {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        do { try FileManager.default.removeItem(at: root) }
        catch { XCTFail("Could not clean temporary progress files: \(error)") }
    }
}

private final class PositionHandoffLegacyStore: ReadingPositionStore, @unchecked Sendable {
    func save(_ position: CoreTextReadingPosition, for bookId: String) async {}
    func load(for bookId: String) async -> CoreTextReadingPosition? { nil }
    func loadSync(for bookId: String) -> CoreTextReadingPosition? { nil }
    func flush(for bookId: String) async {}
}

private final class SaveRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var savedPositions: [CoreTextReadingPosition] = []
    private var savedBookIDs: [String] = []

    var positions: [CoreTextReadingPosition] { lock.withLock { savedPositions } }
    var bookIDs: [String] { lock.withLock { savedBookIDs } }

    func record(_ position: CoreTextReadingPosition, for bookId: String) {
        lock.withLock {
            savedPositions.append(position)
            savedBookIDs.append(bookId)
        }
    }
}

private final class FaultInjectingWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = false
    private var attempts = 0
    private var calledOnMain = false

    var failWrites: Bool {
        get { lock.withLock { shouldFail } }
        set { lock.withLock { shouldFail = newValue } }
    }
    var attemptCount: Int { lock.withLock { attempts } }
    var wasCalledOnMainThread: Bool { lock.withLock { calledOnMain } }

    func write(_ data: Data, to url: URL) throws {
        let fail = lock.withLock {
            attempts += 1
            calledOnMain = calledOnMain || Thread.isMainThread
            return shouldFail
        }
        if fail { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: url, options: .atomic)
    }
}
import CryptoKit
