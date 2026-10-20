import Foundation
import LegadoRuntime
import Testing
@testable import yuedu_app

private struct MetadataFixtureNoSourceBacking: LegadoOwnedStateBacking {
    func read(sourceURL: String, domain: LegadoOwnedStateDomain, fields: Set<String>) throws -> LegadoOwnedStateSnapshot {
        throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY", message: "Only explicitly bound fixture book owners")
    }
    func commit(sourceURL: String, domain: LegadoOwnedStateDomain, expected: LegadoOwnedStateSnapshot, changes: [String: Data?]) throws -> Bool {
        throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY", message: "Only explicitly bound fixture book owners")
    }
}

/// Only the owned writer waits. The main test executor observes an AsyncStream and
/// releases the writer; no view/main-thread semaphore wait or timing sleep is used.
private final class MetadataWriteGate: @unchecked Sendable {
    let entered: AsyncStream<Bool>
    private let event: AsyncStream<Bool>.Continuation
    private let release = DispatchSemaphore(value: 0)
    init() { let pair = AsyncStream<Bool>.makeStream(); entered = pair.stream; event = pair.continuation }
    func wait() throws {
        precondition(!Thread.isMainThread)
        event.yield(true)
        guard release.wait(timeout: .now() + 30) == .success else { throw CocoaError(.userCancelled) }
    }
    func open() { release.signal() }
    func finish() { event.finish() }
}

@Suite("Original bound book metadata owner", .serialized)
@MainActor
struct LegadoBookMetadataOwnerTests {
    private struct Fixture {
        let root: URL
        let shelfURL: URL
        let readingURL: URL
        let store: BookStore
        let shelf: ReadingBook
        let reading: ReadingBook
        let sourceID: UUID
        let sourceURL = "https://metadata-owned.invalid/source"
        let host = LegadoPersistentStateHost(backing: MetadataFixtureNoSourceBacking())
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let shelfURL = root.appendingPathComponent("books_meta.json")
        let store = BookStore(metadataFileURL: shelfURL); let sourceID = UUID()
        func book(_ name: String, shelf: Bool) -> ReadingBook {
            var value = ReadingBook(title: name, author: "Owned", source: "https://metadata-owned.invalid/" + name, contentFilename: "")
            value.isOnline = true; value.isInBookshelf = shelf; value.bookSourceId = sourceID
            value.bookInfoURL = value.source; value.tocURL = value.source + "/toc"; value.runtimeVariables = ["initial": name]
            return value
        }
        let a = book("shelf", shelf: true); let b = book("reading", shelf: false)
        store.replaceBooksFromSync([a]); store.saveReadingBook(b)
        await BookStore.queuedWritesLanded()
        return .init(root: root, shelfURL: shelfURL, readingURL: shelfURL.deletingPathExtension().appendingPathExtension("reading.json"),
            store: store, shelf: a, reading: b, sourceID: sourceID)
    }
    private func cleanup(_ f: Fixture) {
        do { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.root.path); try FileManager.default.removeItem(at: f.root) }
        catch { Issue.record("Owned metadata fixture cleanup failed: \(error)") }
    }
    private func bind(_ f: Fixture, book: ReadingBook) async throws -> String {
        try await f.host.bindBook(sourceURL: f.sourceURL, sourceRevision: "owned-code-r1", store: f.store,
            bookID: book.id, sourceID: f.sourceID, bookURL: book.source)
    }
    private func key(_ f: Fixture, book: ReadingBook, large: String? = nil) throws -> String {
        var parts = [f.sourceURL, large == nil ? "variables" : "big-variable", "book", book.source, ""]
        if let large { parts.append(large) }
        return String(decoding: try JSONSerialization.data(withJSONObject: parts), as: UTF8.self)
    }
    private func call(_ f: Fixture, operation: String, input: [String: Any]) async throws -> [String: Any] {
        let result = try await f.host.dispatch(.init(taskID: UUID().uuidString, operation: operation,
            requestJSON: String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)))
        return try #require(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
    }
    private func commit(_ f: Fixture, owner: String, changes: [String: Data]) async throws -> Bool {
        let proof = try await call(f, operation: "state.read", input: ["owner": owner, "keys": Array(changes.keys)])
        let revision = try #require(proof["revision"] as? NSNumber)
        let result = try await call(f, operation: "state.commit", input: ["owner": owner, "revision": revision,
            "changes": changes.mapValues { $0.base64EncodedString() }])
        return try #require(result["committed"] as? Bool)
    }

    @Test("actual state callbacks update only the original shelf or reading file and restore both books after restart")
    func actualBookCallbacksRestoreShelfAndReadingVariables() async throws {
        let f = try await fixture(); defer { cleanup(f) }
        let a = try await bind(f, book: f.shelf); let b = try await bind(f, book: f.reading)
        let readingBefore = try Data(contentsOf: f.readingURL)
        let large = String(repeating: "𠮷", count: 5_000)
        #expect(try await commit(f, owner: a, changes: [key(f, book: f.shelf): Data("{\"short\":\"shelf\"}".utf8),
            key(f, book: f.shelf, large: "large"): Data(large.utf8)]))
        #expect(try Data(contentsOf: f.readingURL) == readingBefore)
        let shelfAfter = try Data(contentsOf: f.shelfURL)
        #expect(try await commit(f, owner: b, changes: [key(f, book: f.reading): Data("{\"short\":\"reading\"}".utf8)]))
        #expect(try Data(contentsOf: f.shelfURL) == shelfAfter)
        let reopened = BookStore(metadataFileURL: f.shelfURL)
        #expect(reopened.readingBook(id: f.shelf.id)?.runtimeVariables == ["short": "shelf", "large": large])
        #expect(reopened.readingBook(id: f.reading.id)?.runtimeVariables == ["short": "reading"])
    }

    @Test("an actual older queued full-record save preserves accepted runtime variables and newer reading progress")
    func olderQueuedMetadataCannotEraseAcceptedVariables() async throws {
        let f = try await fixture(); defer { cleanup(f) }
        _ = try await bind(f, book: f.shelf)
        let expected = try await f.store.originalRuntimeBookVariableSnapshot(bookID: f.shelf.id, sourceID: f.sourceID, bookURL: f.shelf.source)
        let gate = MetadataWriteGate(); defer { gate.open() }
        let task = Task {
            defer { gate.finish() }
            return try await f.store.compareOriginalRuntimeBook(expected: expected, expectedView: expected.book,
                variables: ["accepted": "must survive old full payload"], deadline: Date().addingTimeInterval(30),
                cancellation: OriginalRuntimeCommitCancellation(), beforeWrite: { try gate.wait() }, validateGrant: {})
        }
        var events = gate.entered.makeAsyncIterator()
        #expect(await events.next() == true)
        // This captures an ordinary full-record payload with the old variable map and
        // queues it behind the runtime transaction while that transaction is in I/O.
        f.store.updatePosition(bookId: f.shelf.id, position: 0.61, forceSave: true)
        gate.open()
        #expect(try await task.value)
        await BookStore.queuedWritesLanded()
        let reopened = BookStore(metadataFileURL: f.shelfURL)
        #expect(reopened.readingBook(id: f.shelf.id)?.runtimeVariables == ["accepted": "must survive old full payload"])
        #expect(reopened.readingBook(id: f.shelf.id)?.currentPosition == 0.61)
    }

    @Test("a real offline TXT migration queued behind runtime CAS preserves another book's accepted variables and its own bookmarks")
    func queuedTXTBookmarksKeepOtherBookVariables() async throws {
        let f = try await fixture(); defer { cleanup(f) }
        var offline = ReadingBook(title: "Local TXT", author: "Owned", contentFilename: "owned.txt")
        let original = Bookmark(chapterIndex: 0, chapterTitle: "old", position: .chapterStart(0))
        let migrated = Bookmark(chapterIndex: 1, chapterTitle: "new", position: .chapterStart(1), id: original.id, date: original.date)
        offline.bookmarks = [original]
        f.store.saveReadingBook(offline)
        await BookStore.queuedWritesLanded()
        _ = try await bind(f, book: f.shelf)
        let expected = try await f.store.originalRuntimeBookVariableSnapshot(bookID: f.shelf.id, sourceID: f.sourceID, bookURL: f.shelf.source)
        let gate = MetadataWriteGate(); defer { gate.open() }
        let cas = Task {
            defer { gate.finish() }
            return try await f.store.compareOriginalRuntimeBook(expected: expected, expectedView: expected.book,
                variables: ["accepted": "must survive unrelated TXT migration"], deadline: Date().addingTimeInterval(30),
                cancellation: OriginalRuntimeCommitCancellation(), beforeWrite: { try gate.wait() }, validateGrant: {})
        }
        var started = gate.entered.makeAsyncIterator(); #expect(await started.next() == true)
        let enqueued = AsyncStream<Bool>.makeStream()
        let txt = Task {
            try await f.store.commitTXTBookmarks(bookId: offline.id, original: [original], migrated: [migrated],
                onEnqueued: { enqueued.continuation.yield(true) })
        }
        var queued = enqueued.stream.makeAsyncIterator(); #expect(await queued.next() == true)
        enqueued.continuation.finish()
        // Captured before bookmark publication, this normal whole-record payload
        // has the old marks. It follows the bookmark writer on the same queue.
        f.store.updatePosition(bookId: offline.id, position: 0.52, forceSave: true)
        gate.open()
        #expect(try await cas.value)
        try await txt.value
        await BookStore.queuedWritesLanded()
        let reopened = BookStore(metadataFileURL: f.shelfURL)
        #expect(reopened.readingBook(id: f.shelf.id)?.runtimeVariables == ["accepted": "must survive unrelated TXT migration"])
        #expect(reopened.readingBook(id: offline.id)?.bookmarks == [migrated])
        #expect(reopened.readingBook(id: offline.id)?.currentPosition == 0.52)
        #expect(f.store.readingBook(id: offline.id)?.bookmarks == [migrated])
    }

    @Test("failed TXT atomic replacement preserves the old file and does not publish migrated bookmarks")
    func failedTXTBookmarkWriteKeepsOldMetadata() async throws {
        let f = try await fixture(); defer { cleanup(f) }
        var offline = ReadingBook(title: "Local TXT", author: "Owned", contentFilename: "owned.txt")
        let original = Bookmark(chapterIndex: 0, chapterTitle: "old", position: .chapterStart(0))
        let migrated = Bookmark(chapterIndex: 1, chapterTitle: "new", position: .chapterStart(1), id: original.id, date: original.date)
        offline.bookmarks = [original]; f.store.saveReadingBook(offline)
        await BookStore.queuedWritesLanded()
        let shelf = try Data(contentsOf: f.shelfURL); let reading = try Data(contentsOf: f.readingURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.root.path)
        do {
            try await f.store.commitTXTBookmarks(bookId: offline.id, original: [original], migrated: [migrated])
            Issue.record("Expected failed TXT metadata replacement")
        } catch { #expect((error as NSError).domain == NSCocoaErrorDomain) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.root.path)
        #expect(try Data(contentsOf: f.shelfURL) == shelf)
        #expect(try Data(contentsOf: f.readingURL) == reading)
        #expect(f.store.readingBook(id: offline.id)?.bookmarks == [original])
        try await f.store.commitTXTBookmarks(bookId: offline.id, original: [original], migrated: [migrated])
        let reopened = BookStore(metadataFileURL: f.shelfURL)
        #expect(reopened.readingBook(id: offline.id)?.bookmarks == [migrated])
    }

    @Test("four real publication conflicts permit exact journal takeover and restart, while new user bookmarks reject the old journal")
    func exactTXTJournalRecoversPublicationConflicts() async throws {
        for newUserEdit in [false, true] {
            let f = try await fixture(); defer { cleanup(f) }
            var offline = ReadingBook(title: "Local TXT", author: "Owned", contentFilename: "owned.txt")
            let original = Bookmark(chapterIndex: 0, chapterTitle: "old", position: .chapterStart(0))
            let migrated = Bookmark(chapterIndex: 1, chapterTitle: "new", position: .chapterStart(1), id: original.id, date: original.date)
            offline.bookmarks = [original]; f.store.saveReadingBook(offline)
            await BookStore.queuedWritesLanded()
            let id = offline.id
            do {
                try await f.store.commitTXTBookmarks(bookId: id, original: [original], migrated: [migrated], beforePublication: { attempt in
                    await MainActor.run {
                        f.store.updatePosition(bookId: id, position: Double(attempt + 1) / 10, forceSave: true)
                    }
                })
                Issue.record("Four revision conflicts must not acknowledge un-published bookmarks")
            } catch TXTLocationMigration.Failure.missingSourceIdentity { }
            await BookStore.queuedWritesLanded()
            #expect(f.store.readingBook(id: id)?.bookmarks == [original])
            // Actual old full-record payloads have run, but the accepted projection
            // still protects the new marks in the original file after all four conflicts.
            let reopened = BookStore(metadataFileURL: f.shelfURL)
            #expect(reopened.readingBook(id: id)?.bookmarks == [migrated])
            if newUserEdit {
                let added = Bookmark(chapterIndex: 2, chapterTitle: "user", position: .chapterStart(2))
                f.store.addBookmark(bookId: id, bookmark: added)
                f.store.flushPendingMetadataSave()
                await BookStore.queuedWritesLanded()
                do {
                    try await f.store.commitTXTBookmarks(bookId: id, original: [original], migrated: [migrated])
                    Issue.record("An old journal must not overwrite the user's newer bookmarks")
                } catch TXTLocationMigration.Failure.missingSourceIdentity { }
                let afterUser = BookStore(metadataFileURL: f.shelfURL)
                #expect(afterUser.readingBook(id: id)?.bookmarks.contains(where: { $0.id == added.id }) == true)
            } else {
                let wrong = Bookmark(chapterIndex: 3, chapterTitle: "different journal", position: .chapterStart(3))
                do {
                    try await f.store.commitTXTBookmarks(bookId: id, original: [original], migrated: [wrong])
                    Issue.record("A different journal cannot consume the protected projection")
                } catch let error as LegadoRuntimeError { #expect(error.code == "STATE_LIMIT") }
                try await f.store.commitTXTBookmarks(bookId: id, original: [original], migrated: [migrated])
                #expect(f.store.readingBook(id: id)?.bookmarks == [migrated])
                // Replaying this exact original journal in a fresh store remains
                // idempotent, even though its durable metadata already has the target.
                let fresh = BookStore(metadataFileURL: f.shelfURL)
                try await fresh.commitTXTBookmarks(bookId: id, original: [original], migrated: [migrated])
                #expect(fresh.readingBook(id: id)?.bookmarks == [migrated])
            }
        }
    }

    @Test("failed atomic metadata writes and queued caller cancellation retain both original files and variable owner")
    func failedWritesAndCancellationKeepOldMetadata() async throws {
        let f = try await fixture(); defer { cleanup(f) }
        let owner = try await bind(f, book: f.shelf)
        let beforeShelf = try Data(contentsOf: f.shelfURL); let beforeReading = try Data(contentsOf: f.readingURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.root.path)
        do { _ = try await commit(f, owner: owner, changes: [key(f, book: f.shelf): Data("{\"bad\":\"not visible\"}".utf8)]); Issue.record("Expected failed atomic metadata write") }
        catch let error as LegadoRuntimeError { #expect(error.code == "STATE_IO") }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.root.path)
        #expect(try Data(contentsOf: f.shelfURL) == beforeShelf)
        #expect(try Data(contentsOf: f.readingURL) == beforeReading)
        #expect(f.store.originalRuntimeBookSnapshot(id: f.shelf.id, sourceID: f.sourceID, bookURL: f.shelf.source)?.variables == f.shelf.runtimeVariables)
        let expected = try await f.store.originalRuntimeBookVariableSnapshot(bookID: f.shelf.id, sourceID: f.sourceID, bookURL: f.shelf.source)
        let gate = MetadataWriteGate(); defer { gate.open() }
        let task = Task {
            defer { gate.finish() }
            return try await f.store.compareOriginalRuntimeBook(expected: expected, expectedView: expected.book,
                variables: ["cancelled": "must not commit"], deadline: Date().addingTimeInterval(30),
                cancellation: OriginalRuntimeCommitCancellation(), beforeWrite: { try gate.wait() }, validateGrant: {})
        }
        var events = gate.entered.makeAsyncIterator(); #expect(await events.next() == true)
        task.cancel(); gate.open()
        do { _ = try await task.value; Issue.record("Expected cancellation before atomic replacement") } catch is CancellationError { }
        #expect(try Data(contentsOf: f.shelfURL) == beforeShelf)
        #expect(try Data(contentsOf: f.readingURL) == beforeReading)
    }

    @Test("failed shelf replacement keeps reading copies during simultaneous promotion and demotion, then retries safely")
    func failedShelfReplacementKeepsBothDurableBookCopies() async throws {
        let f = try await fixture(); defer { cleanup(f) }
        let saved = f.root.appendingPathComponent("owned-shelf-before.json")
        let shelfBefore = try Data(contentsOf: f.shelfURL)
        try FileManager.default.moveItem(at: f.shelfURL, to: saved)
        try FileManager.default.createDirectory(at: f.shelfURL, withIntermediateDirectories: false)
        var demoted = f.shelf; demoted.isInBookshelf = false
        f.store.saveReadingBook(demoted)
        _ = f.store.addReadingBookToShelf(id: f.reading.id)
        await BookStore.queuedWritesLanded()
        let protected = try JSONDecoder().decode([ReadingBook].self, from: Data(contentsOf: f.readingURL))
        #expect(Set(protected.map(\.id)) == Set([f.shelf.id, f.reading.id]))
        #expect(try Data(contentsOf: saved) == shelfBefore)
        try FileManager.default.removeItem(at: f.shelfURL)
        try FileManager.default.moveItem(at: saved, to: f.shelfURL)
        f.store.updatePosition(bookId: f.reading.id, position: 0.2, forceSave: true)
        await BookStore.queuedWritesLanded()
        let finalShelf = try JSONDecoder().decode([ReadingBook].self, from: Data(contentsOf: f.shelfURL))
        let finalReading = try JSONDecoder().decode([ReadingBook].self, from: Data(contentsOf: f.readingURL))
        #expect(finalShelf.map(\.id) == [f.reading.id])
        #expect(finalReading.map(\.id) == [f.shelf.id])
    }
}
