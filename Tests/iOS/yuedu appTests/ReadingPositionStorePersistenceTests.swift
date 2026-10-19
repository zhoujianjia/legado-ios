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
