import Foundation
import LegadoRuntime
import Testing
@testable import yuedu_app

@Suite("Original runtime bound App book owner", .serialized)
@MainActor
struct LegadoBookStateOwnerTests {
    private struct NoSourceState: LegadoOwnedStateBacking {
        func read(sourceURL: String, domain: LegadoOwnedStateDomain, fields: Set<String>) throws -> LegadoOwnedStateSnapshot {
            throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY", message: "No unrelated fixture source owner")
        }
        func commit(sourceURL: String, domain: LegadoOwnedStateDomain, expected: LegadoOwnedStateSnapshot, changes: [String: Data?]) throws -> Bool {
            throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY", message: "No unrelated fixture source owner")
        }
    }
    private struct Fixture {
        let root: URL
        let metadata: URL
        let store: BookStore
        let book: ReadingBook
        let chapter: OnlineChapterRef
        let sourceID: UUID
        let sourceURL = "https://owned-state.invalid/source"
        let generation: OriginalRuntimeChapterGeneration
        let host: LegadoPersistentStateHost
    }
    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let metadata = root.appendingPathComponent("books_meta.json")
        let store = BookStore(metadataFileURL: metadata); let sourceID = UUID()
        let chapter = OnlineChapterRef(index: 0, title: "Owned chapter", url: "https://owned-state.invalid/book/one/chapter")
        var book = ReadingBook(title: "Owned book", author: "Fixture", source: "https://owned-state.invalid/book/one", contentFilename: "")
        book.isOnline = true; book.bookSourceId = sourceID; book.bookInfoURL = book.source
        book.tocURL = book.source + "/toc"; book.runtimeVariables = ["book": "existing"]
        book.onlineChapters = [chapter, OnlineChapterRef(index: 1, title: "Other chapter",
            url: "https://owned-state.invalid/book/one/other", runtimeVariables: ["other": "unchanged"])]
        store.replaceBooksFromSync([book])
        return Fixture(root: root, metadata: metadata, store: store, book: book, chapter: chapter,
            sourceID: sourceID, generation: OriginalRuntimeChapterGeneration(bookID: book.id, chapter: chapter, token: UUID()),
            host: LegadoPersistentStateHost(backing: NoSourceState()))
    }
    private func cleanup(_ fixture: Fixture) {
        do {
            let chapters = fixture.metadata.deletingPathExtension().appendingPathExtension("chapters")
            if FileManager.default.fileExists(atPath: chapters.path) {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: chapters.path)
            }
            try FileManager.default.removeItem(at: fixture.root)
        } catch { Issue.record("Owned fixture cleanup failed: \(error)") }
    }
    private func owner(_ fixture: Fixture) async throws -> String {
        try await fixture.host.bindBook(sourceURL: fixture.sourceURL, sourceRevision: "owned-r1", store: fixture.store,
            bookID: fixture.book.id, sourceID: fixture.sourceID, bookURL: fixture.book.source,
            chapter: fixture.chapter, generation: fixture.generation)
    }
    private func key(_ f: Fixture, chapter: Bool, large: String? = nil) throws -> String {
        var parts = [f.sourceURL, large == nil ? "variables" : "big-variable", chapter ? "chapter" : "book", f.book.source, chapter ? f.chapter.url : ""]
        if let large { parts.append(large) }
        return String(decoding: try JSONSerialization.data(withJSONObject: parts), as: UTF8.self)
    }
    private func call(_ host: LegadoPersistentStateHost, operation: String, task: String = "owned-task", input: [String: Any]) async throws -> [String: Any] {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
        let result = try await host.dispatch(.init(taskID: task, operation: operation, requestJSON: json))
        return try #require(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
    }
    private func read(_ f: Fixture, owner: String, keys: [String]) async throws -> Int64 {
        let result = try await call(f.host, operation: "state.read", input: ["owner": owner, "keys": keys])
        return try #require((result["revision"] as? NSNumber)?.int64Value)
    }
    private func commit(_ f: Fixture, owner: String, revision: Int64, changes: [String: Any]) async throws -> Bool {
        let result = try await call(f.host, operation: "state.commit", input: ["owner": owner, "revision": revision, "changes": changes])
        return try #require(result["committed"] as? Bool)
    }
    private func error(_ code: String, _ operation: () async throws -> Void) async {
        do { try await operation(); Issue.record("Expected \(code)") }
        catch let error as LegadoRuntimeError { #expect(error.code == code) }
        catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test("state callback commits the real App chapter file and a new BookStore restores short and large values")
    func hostCommitUsesOriginalChapterFileAndRestart() async throws {
        let f = try fixture(); defer { cleanup(f) }
        let grant = try await owner(f); let small = try key(f, chapter: true); let big = try key(f, chapter: true, large: "large")
        let revision = try await read(f, owner: grant, keys: [small, big])
        let large = String(repeating: "𠮷", count: 5_000) // exactly 10,000 original Java UTF-16 units
        let shortJSON = try JSONEncoder().encode(["short": "owned"])
        #expect(try await commit(f, owner: grant, revision: revision, changes: [small: shortJSON.base64EncodedString(), big: Data(large.utf8).base64EncodedString()]))
        let chapters = try await f.store.originalRuntimeChapters(bookID: f.book.id)
        #expect(chapters.first?.id == f.chapter.id)
        #expect(chapters.first?.runtimeVariables == ["short": "owned", "large": large])
        #expect(chapters.count == 2)
        #expect(chapters[1].runtimeVariables == ["other": "unchanged"])
        let reopened = BookStore(metadataFileURL: f.metadata)
        #expect(reopened.chapters(for: f.book.id)?.first?.runtimeVariables == ["short": "owned", "large": large])
        #expect(reopened.readingBook(id: f.book.id)?.runtimeVariables == ["book": "existing"])
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("runtime-state.json").path))
    }

    @Test("a new TOC and cancelled task reject old host proofs without changing their real chapter owner")
    func staleTocAndTaskCancellationRejectOldHostProofs() async throws {
        let f = try fixture(); defer { cleanup(f) }
        let grant = try await owner(f); let small = try key(f, chapter: true)
        let proof = try await read(f, owner: grant, keys: [small])
        var next = f.chapter
        next.title = "New TOC identity"
        next.url = "https://owned-state.invalid/book/one/new"
        next.runtimeVariables = ["app": "new toc"]
        f.store.updateOnlineChapters(bookId: f.book.id, chapters: [next])
        #expect(try await !commit(f, owner: grant, revision: proof, changes: [small: Data("{\"stale\":\"must not apply\"}".utf8).base64EncodedString()]))
        f.store.flushPendingMetadataSave()
        await BookStore.queuedWritesLanded()
        #expect(try await f.store.originalRuntimeChapters(bookID: f.book.id) == [next])
        let reopened = BookStore(metadataFileURL: f.metadata)
        #expect(reopened.chapters(for: f.book.id) == [next])
        await f.host.cancel(taskID: "cancelled-owned")
        do {
            _ = try await call(f.host, operation: "state.read", task: "cancelled-owned", input: ["owner": grant, "keys": [small]])
            Issue.record("Cancelled tasks must not enter a state owner")
        } catch is CancellationError { }
    }

    @Test("source grants cannot invent book UUIDs and cross-owner transactions are rejected before I/O")
    func rejectsUnmappedIdentityAndUnsupportedTransactions() async throws {
        let f = try fixture(); defer { cleanup(f) }
        await error("UNSUPPORTED_CAPABILITY") {
            _ = try await f.host.bindBook(sourceURL: f.sourceURL, sourceRevision: "owned-r1", store: f.store,
                bookID: UUID(), sourceID: f.sourceID, bookURL: f.book.source)
        }
        let grant = try await owner(f); let bookKey = try key(f, chapter: false); let chapterKey = try key(f, chapter: true)
        await error("UNSUPPORTED_CAPABILITY") { _ = try await read(f, owner: grant, keys: [bookKey, chapterKey]) }
        let proof = try await read(f, owner: grant, keys: [bookKey])
        #expect(try await commit(f, owner: grant, revision: proof,
            changes: [bookKey: Data("{\"book\":\"owned metadata\"}".utf8).base64EncodedString()]))
        #expect(f.store.originalRuntimeBookSnapshot(id: f.book.id, sourceID: f.sourceID, bookURL: f.book.source)?.variables == ["book": "owned metadata"])
        await f.host.revoke(owner: grant)
        await error("INVALID_STATE_OWNER") { _ = try await read(f, owner: grant, keys: [chapterKey]) }
    }

    @Test("corrupt and unreadable existing chapter files are STATE_IO and never become an empty owner")
    func corruptAndUnreadableChapterOwnersRemainErrors() async throws {
        let f = try fixture(); defer { cleanup(f) }
        let file = f.metadata.deletingPathExtension().appendingPathExtension("chapters").appendingPathComponent(f.book.id.uuidString + ".json")
        let before = try Data(contentsOf: file)
        let corrupt = Data("{ owned invalid JSON".utf8)
        try corrupt.write(to: file, options: .atomic)
        let broken = BookStore(metadataFileURL: f.metadata)
        await error("STATE_IO") {
            _ = try await f.host.bindBook(sourceURL: f.sourceURL, sourceRevision: "owned-r1", store: broken,
                bookID: f.book.id, sourceID: f.sourceID, bookURL: f.book.source,
                chapter: f.chapter, generation: f.generation)
        }
        #expect(try Data(contentsOf: file) == corrupt)
        try before.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer {
            do { try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
            catch { Issue.record("Owned fixture read permissions could not be restored: \(error)") }
        }
        let unreadable = BookStore(metadataFileURL: f.metadata)
        await error("STATE_IO") {
            _ = try await f.host.bindBook(sourceURL: f.sourceURL, sourceRevision: "owned-r1", store: unreadable,
                bookID: f.book.id, sourceID: f.sourceID, bookURL: f.book.source,
                chapter: f.chapter, generation: f.generation)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(try Data(contentsOf: file) == before)
    }

    @Test("failed actual atomic writes retain disk and memory and generation revocation forbids later writes")
    func hostWriteFailureAndGenerationRevocationPreserveOldState() async throws {
        let f = try fixture(); defer { cleanup(f) }
        let grant = try await owner(f); let small = try key(f, chapter: true)
        let file = f.metadata.deletingPathExtension().appendingPathExtension("chapters").appendingPathComponent(f.book.id.uuidString + ".json")
        let before = try Data(contentsOf: file)
        let proof = try await read(f, owner: grant, keys: [small])
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: file.deletingLastPathComponent().path)
        await error("STATE_IO") { _ = try await commit(f, owner: grant, revision: proof, changes: [small: Data("{\"new\":\"failed\"}".utf8).base64EncodedString()]) }
        #expect(try Data(contentsOf: file) == before)
        #expect(try await f.store.originalRuntimeChapters(bookID: f.book.id).first?.runtimeVariables == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.deletingLastPathComponent().path)
        let next = try await read(f, owner: grant, keys: [small])
        f.generation.revoke()
        do {
            _ = try await commit(f, owner: grant, revision: next, changes: [small: Data("{}".utf8).base64EncodedString()])
            Issue.record("A revoked generation must not write")
        } catch is CancellationError { }
        #expect(try Data(contentsOf: file) == before)
    }
}
