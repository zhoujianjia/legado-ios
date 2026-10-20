import Foundation
import LegadoRuntime
import Testing
import SwiftSoup
@testable import yuedu_app

private struct BatchNoSourceBacking: LegadoOwnedStateBacking {
    func read(sourceURL: String, domain: LegadoOwnedStateDomain, fields: Set<String>) throws -> LegadoOwnedStateSnapshot {
        throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY", message: "Unrelated fixture owner")
    }
    func commit(sourceURL: String, domain: LegadoOwnedStateDomain, expected: LegadoOwnedStateSnapshot, changes: [String: Data?]) throws -> Bool {
        throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY", message: "Unrelated fixture owner")
    }
}

private enum BatchHostFixture {
    static func key(_ source: String, _ book: String, index: Int?) throws -> String {
        var parts = [source, index == nil ? "toc" : "content", book]
        if let index { parts.append(String(index)) }
        return String(decoding: try JSONSerialization.data(withJSONObject: parts), as: UTF8.self)
    }
    static func call(_ host: LegadoPersistentStateHost, task: String, operation: String, input: [String: Any]) async throws -> [String: Any] {
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
        let value = try await host.dispatch(.init(taskID: task, operation: operation, requestJSON: raw))
        return try #require(try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
    }
    static func read(_ host: LegadoPersistentStateHost, owner: String, task: String, source: String, book: String, index: Int) async throws -> (Int64, String, [String: Any]) {
        let content = try key(source, book, index: index)
        let toc = try key(source, book, index: nil)
        let snapshot = try await call(host, task: task, operation: "state.read", input: ["owner": owner, "keys": [content, toc]])
        let revision = try #require(snapshot["revision"] as? NSNumber)
        let values = try #require(snapshot["values"] as? [String: String])
        let encoded = try #require(values[content])
        let bytes = try #require(Data(base64Encoded: encoded))
        let row = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        return (revision.int64Value, content, row)
    }
    static func commit(_ host: LegadoPersistentStateHost, owner: String, task: String,
                       snapshot: (Int64, String, [String: Any]), body: String) async throws -> Bool {
        var row = snapshot.2; row["body"] = body
        let encoded = try JSONSerialization.data(withJSONObject: row).base64EncodedString()
        let response = try await call(host, task: task, operation: "state.commit",
            input: ["owner": owner, "revision": snapshot.0, "changes": [snapshot.1: encoded]])
        return try #require(response["committed"] as? Bool)
    }
}

/// Controlled callback fixture for the App half only. It uses the actual Host and
/// real file writer, not fake write receipts. The public JVM half runs separately.
private struct OwnedBatchCallbackExecutor: LegadoOriginalContentBatchExecuting {
    let failAfterFirst: Bool
    func execute(_ request: LegadoContentBatchExecutionRequest) async throws -> LegadoOriginalContentBatchResult {
        let host = LegadoPersistentStateHost(backing: BatchNoSourceBacking())
        let owner = try await host.bindContentBatch(sourceURL: request.sourceURL, sourceRevision: request.sourceRevision,
            taskID: request.taskID, store: request.store, bookID: request.bookID, sourceID: request.sourceID,
            book: request.book, chapters: request.chapters, deadline: request.deadline, cache: request.cache)
        do {
            _ = try await BatchHostFixture.call(host, task: request.taskID, operation: "content.batch.authorize",
                input: ["owner": owner, "sourceURL": request.sourceURL, "bookURL": request.book.bookURL,
                    "chapters": request.chapters.map { ["index": $0.chapter.index, "url": $0.chapter.url] as [String: Any] }])
            for value in request.chapters.prefix(2) {
                let snapshot = try await BatchHostFixture.read(host, owner: owner, task: request.taskID,
                    source: request.sourceURL, book: request.book.bookURL, index: value.chapter.index)
                let saved = try await BatchHostFixture.commit(host, owner: owner, task: request.taskID,
                    snapshot: snapshot, body: "Actual owned chapter body at index \(value.chapter.index).")
                #expect(saved)
                if failAfterFirst { throw LegadoRuntimeError(code: "SCRIPT_ERROR", message: "After first real save", completedEffects: ["chapterContentCommitted"]) }
            }
            _ = try await host.finishContentBatchResult(owner: owner, taskID: request.taskID, book: request.book, deadline: request.deadline)
            await host.revoke(owner: owner)
            return .init(book: request.book, missingChapters: request.chapters.dropFirst(2).map(\.dto))
        } catch {
            await host.revoke(owner: owner); throw error
        }
    }
}

@Suite("Original public batch App owner", .serialized)
@MainActor
struct LegadoContentBatchOwnerTests {

    @Test("actual Host keeps rule output bytes and persists the ordinary image and embedded-media render artifacts")
    func markupCallbackUsesExistingArtifactsAndReopensWithoutRefetch() async throws {
        let f = try await fixture(); defer { cleanup(f.root) }
        let host = LegadoPersistentStateHost(backing: BatchNoSourceBacking()); let task = "owned-markup"
        let owner = try await host.bindContentBatch(sourceURL: f.source.bookSourceUrl, sourceRevision: "r1", taskID: task,
            store: f.store, bookID: f.book.id, sourceID: f.source.id, book: f.dto, chapters: grants(f),
            deadline: Date().addingTimeInterval(60), cache: f.cache)
        let body = "<usehtml><p>Original &amp; retained prose.</p><img src='../image.png'><img src='../protected.png,{\"headers\":{\"Referer\":\"https://owned.invalid/protected\"}}'><audio controls src='/a.m4a,{\"headers\":{\"Referer\":\"https://owned.invalid/audio\"}}'></audio><video poster='/poster.png' src='https://owned.invalid/v.mp4'></video><iframe src='https://owned.invalid/player'></iframe><script>ownedMustNotRun()</script></usehtml>"
        let snapshot = try await BatchHostFixture.read(host, owner: owner, task: task,
            source: f.source.bookSourceUrl, book: f.dto.bookURL, index: 0)
        #expect(try await BatchHostFixture.commit(host, owner: owner, task: task, snapshot: snapshot, body: body))
        let reopened = ChapterCacheRepository(rootDirectory: f.root.appendingPathComponent("body"))
        let persisted = try await BookStore.chapterCachePersistence {
            let package = try #require(reopened.loadChapterPackageSync(bookId: f.book.id, chapterIndex: 0,
                expectedSourceURL: f.chapters[0].url, expectedTOCTitle: f.chapters[0].title))
            let html = try #require(reopened.loadNormalizedChapterHTMLSync(bookId: f.book.id, chapterIndex: 0,
                expectedSourceURL: f.chapters[0].url, expectedTOCTitle: f.chapters[0].title))
            let raw = try String(contentsOf: f.root.appendingPathComponent("body").appendingPathComponent(f.book.id.uuidString).appendingPathComponent("0.raw.html"), encoding: .utf8)
            return (package, html, raw)
        }
        #expect(persisted.0.content == body && persisted.2 == body)
        #expect(persisted.0.rawHTMLFilename == "0.raw.html" && persisted.0.normalizedHTMLFilename == "0.normalized.xhtml")
        #expect(OnlineChapterCacheWritePolicy.isReusableCachedPackage(persisted.0, hasBookSource: true))
        for tag in ["<img", "<audio", "<video", "<iframe"] { #expect(persisted.1.contains(tag)) }
        #expect(persisted.1.contains("https://batch-owned.invalid/image.png"))
        #expect(persisted.1.contains("https://batch-owned.invalid/a.m4a"))
        #expect(!persisted.1.contains("<usehtml") && !persisted.1.contains("ownedMustNotRun"))
        let resources = try await Task.detached {
            let document = try SwiftSoup.parse(persisted.1)
            return try document.select("img[src],audio[src]").array().map { try $0.attr("src") }
        }.value
        let decoded = resources.map { OnlineImageRequestOptions.decode($0) }
        #expect(decoded.contains { $0.src == "https://batch-owned.invalid/protected.png" && $0.headers["Referer"] == "https://owned.invalid/protected" })
        #expect(decoded.contains { $0.src == "https://batch-owned.invalid/a.m4a" && $0.headers["Referer"] == "https://owned.invalid/audio" })
        #expect(persisted.1.contains("https://batch-owned.invalid/poster.png"))
        let restored = try await BatchHostFixture.read(host, owner: owner, task: task,
            source: f.source.bookSourceUrl, book: f.dto.bookURL, index: 0)
        #expect(restored.2["body"] as? String == body)
        let exported = try await CachedBookTXTExportService.export(
            .init(bookID: f.book.id, title: f.book.title, author: f.book.author, chapters: f.chapters),
            repository: reopened, temporaryDirectory: f.root)
        let text = try await Task.detached { try String(contentsOf: exported.fileURL, encoding: .utf8) }.value
        #expect(text.contains("Original & retained prose.") && !text.contains("<usehtml"))
        await host.revoke(owner: owner)
    }

    @Test("equal callback text upgrades missing render files but an identical complete package writes nothing")
    func sameBodyUpgradesRenderArtifactsThenKeepsAllBytesUnchanged() async throws {
        let f = try await fixture(); defer { cleanup(f.root) }
        let body = "<p>Original batch image.</p><img src='https://owned.invalid/one.png'>"
        _ = try await f.cache.saveToCache(content: body, bookId: f.book.id, chapterIndex: 0,
            sourceURL: f.chapters[0].url, tocTitle: f.chapters[0].title, storeNormalizedHTML: false)
        let host = LegadoPersistentStateHost(backing: BatchNoSourceBacking()); let task = "owned-upgrade"
        let owner = try await host.bindContentBatch(sourceURL: f.source.bookSourceUrl, sourceRevision: "r1", taskID: task,
            store: f.store, bookID: f.book.id, sourceID: f.source.id, book: f.dto, chapters: grants(f),
            deadline: Date().addingTimeInterval(60), cache: f.cache)
        let before = try await f.cache.originalBatchSnapshot(bookID: f.book.id, index: 0,
            sourceURL: f.chapters[0].url, tocTitle: f.chapters[0].title, validateGrant: {})
        #expect(before.fingerprints[".raw.html"] == "missing" && before.fingerprints[".normalized.xhtml"] == "missing")
        var firstRenderProof: [String: String] = [:]
        for iteration in 0..<2 {
            let read = try await BatchHostFixture.read(host, owner: owner, task: task,
                source: f.source.bookSourceUrl, book: f.dto.bookURL, index: 0)
            #expect(try await BatchHostFixture.commit(host, owner: owner, task: task, snapshot: read, body: body))
            let current = try await f.cache.originalBatchSnapshot(bookID: f.book.id, index: 0,
                sourceURL: f.chapters[0].url, tocTitle: f.chapters[0].title, validateGrant: {})
            #expect(current.fingerprints[".raw.html"] != "missing" && current.fingerprints[".normalized.xhtml"] != "missing")
            if iteration == 0 { firstRenderProof = current.fingerprints }
            else { #expect(current.fingerprints == firstRenderProof) }
        }
        let complete = try await f.cache.originalBatchSnapshot(bookID: f.book.id, index: 0,
            sourceURL: f.chapters[0].url, tocTitle: f.chapters[0].title, validateGrant: {})
        let package = try #require(complete.package)
        await #expect(throws: CancellationError.self) {
            _ = try await f.cache.compareOriginalBatchSnapshot(complete, package: package,
                rawHTML: body, normalizedHTML: "<html><body>Unacknowledged replacement.</body></html>",
                validateGrant: {}, claimCommit: { false })
        }
        let refused = try await f.cache.originalBatchSnapshot(bookID: f.book.id, index: 0,
            sourceURL: f.chapters[0].url, tocTitle: f.chapters[0].title, validateGrant: {})
        #expect(refused.fingerprints == complete.fingerprints)
        await host.revoke(owner: owner)
    }

    @Test("unresolved original image JS refuses before writes while direct audio URLs retain their existing playback contract")
    func deferredImageDoesNotBorrowLegacyEngineAndAudioUrlStaysExact() async throws {
        let f = try await fixture(); defer { cleanup(f.root) }
        _ = try await f.cache.saveToCache(content: "Previously accepted prose.", bookId: f.book.id, chapterIndex: 0,
            sourceURL: f.chapters[0].url, tocTitle: f.chapters[0].title, storeNormalizedHTML: false)
        let before = try await f.cache.originalBatchSnapshot(bookID: f.book.id, index: 0,
            sourceURL: f.chapters[0].url, tocTitle: f.chapters[0].title, validateGrant: {})
        let host = LegadoPersistentStateHost(backing: BatchNoSourceBacking()); let task = "owned-media-refusal"
        let owner = try await host.bindContentBatch(sourceURL: f.source.bookSourceUrl, sourceRevision: "r1", taskID: task,
            store: f.store, bookID: f.book.id, sourceID: f.source.id, book: f.dto, chapters: grants(f),
            deadline: Date().addingTimeInterval(60), cache: f.cache)
        let read = try await BatchHostFixture.read(host, owner: owner, task: task,
            source: f.source.bookSourceUrl, book: f.dto.bookURL, index: 0)
        do {
            _ = try await BatchHostFixture.commit(host, owner: owner, task: task, snapshot: read,
                body: "<img src=\"data:image/png;base64,,{\"js\":\"result='must-use-original-task'\"}\">")
            Issue.record("A deferred image cannot borrow another JS session")
        } catch let error as LegadoRuntimeError { #expect(error.code == "UNSUPPORTED_CAPABILITY" && (error.completedEffects ?? []).isEmpty) }
        let unchanged = try await f.cache.originalBatchSnapshot(bookID: f.book.id, index: 0,
            sourceURL: f.chapters[0].url, tocTitle: f.chapters[0].title, validateGrant: {})
        #expect(unchanged.fingerprints == before.fingerprints)
        let audio = "https://owned.invalid/a.m4a,{\"headers\":{\"Referer\":\"https://owned.invalid/book\"}}"
        let audioRead = try await BatchHostFixture.read(host, owner: owner, task: task,
            source: f.source.bookSourceUrl, book: f.dto.bookURL, index: 1)
        #expect(try await BatchHostFixture.commit(host, owner: owner, task: task, snapshot: audioRead, body: audio))
        let request = try #require(DirectChapterAudioResolver.request(from: audio))
        #expect(request.url?.absoluteString == "https://owned.invalid/a.m4a")
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://owned.invalid/book")
        let saved = try await f.cache.originalBatchSnapshot(bookID: f.book.id, index: 1,
            sourceURL: f.chapters[1].url, tocTitle: f.chapters[1].title, validateGrant: {})
        #expect(saved.package?.content == audio && saved.package?.normalizedHTMLFilename == nil)
        await host.revoke(owner: owner)
    }
    private struct Fixture {
        let root: URL
        let store: BookStore
        let metadata: URL
        let source: BookSource
        let book: ReadingBook
        let dto: LegadoOriginalBook
        let chapters: [OnlineChapterRef]
        let cache: ChapterCacheRepository
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let metadata = root.appendingPathComponent("books_meta.json")
        let store = BookStore(metadataFileURL: metadata)
        var source = BookSource(bookSourceUrl: "https://batch-owned.invalid/source", bookSourceName: "Owned batch")
        source.ruleContent.contentBatch = "java.cacheContent(chapters[0],'owned')"
        var book = ReadingBook(title: "Owned batch", author: "Author", source: "https://batch-owned.invalid/book", contentFilename: "")
        book.isOnline = true; book.bookSourceId = source.id; book.bookInfoURL = book.source; book.tocURL = book.source + "/toc"
        let chapters = (0..<3).map { OnlineChapterRef(index: $0, title: "Chapter \($0)", url: "https://batch-owned.invalid/duplicate") }
        book.onlineChapters = chapters
        store.replaceBooksFromSync([book])
        await BookStore.queuedWritesLanded()
        let dto = LegadoOriginalBook(bookURL: book.source, origin: source.bookSourceUrl, name: book.title, author: book.author, tocURL: book.tocURL!)
        return .init(root: root, store: store, metadata: metadata, source: source, book: book, dto: dto,
            chapters: chapters, cache: .init(rootDirectory: root.appendingPathComponent("body")))
    }
    private func cleanup(_ root: URL) {
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Owned batch cleanup failed: \(error)") }
    }
    private func grants(_ f: Fixture) -> [OriginalRuntimeBatchChapter] {
        f.chapters.map { ref in
            let generation = OriginalRuntimeChapterGeneration(bookID: f.book.id, chapter: ref, token: UUID(),
                validateCacheIdentity: { try f.store.validateOriginalRuntimeCacheChapter(bookID: f.book.id, chapterID: ref.id, index: ref.index, url: ref.url) })
            return .init(chapter: ref, generation: generation,
                dto: .init(bookURL: f.dto.bookURL, url: ref.url, index: Int32(ref.index), title: ref.title, baseURL: f.dto.tocURL))
        }
    }
    @Test("actual manager jobs pass bounded grants and publish two real saved indexes once")
    func managerToHostToChapterFilesAndRestartPreservesDuplicateUrlIndexes() async throws {
        let f = try await fixture(); defer { cleanup(f.root) }
        let service = LegadoMainJSSourceService(contentBatchExecutor: OwnedBatchCallbackExecutor(failAfterFirst: false))
        let manager = ChapterFetchManager(bookSourceFetcher: .init(mainJSService: service), webViewFetcher: .shared, sourceResolver: { _ in f.source })
        let result = try await manager.fetchOriginalContentBatch(bookID: f.book.id, sourceID: f.source.id,
            book: f.dto, chapterIndexes: [0,1,2], store: f.store, cache: f.cache)
        #expect(result.missingChapters.map(\.index) == [2])
        for index in 0...1 {
            #expect(f.cache.loadChapterPackageSync(bookId: f.book.id, chapterIndex: index)?.content == "Actual owned chapter body at index \(index).")
        }
        #expect(f.cache.loadChapterPackageSync(bookId: f.book.id, chapterIndex: 2) == nil)
        let restarted = BookStore(metadataFileURL: f.metadata)
        let actual = try await restarted.originalRuntimeChapters(bookID: f.book.id)
        #expect(actual.map(\.id) == f.chapters.map(\.id))
        #expect(actual.map(\.cachedFilename) == ["0.txt", "1.txt", nil])
        #expect(await manager.originalRuntimeGeneration(bookID: f.book.id, chapter: f.chapters[0]) == nil)
    }
    @Test("ordinary failure preserves the real prefix and its metadata receipt")
    func managerFailureCarriesSavedPrefixWithoutRollingItBack() async throws {
        let f = try await fixture(); defer { cleanup(f.root) }
        let service = LegadoMainJSSourceService(contentBatchExecutor: OwnedBatchCallbackExecutor(failAfterFirst: true))
        let manager = ChapterFetchManager(bookSourceFetcher: .init(mainJSService: service), webViewFetcher: .shared, sourceResolver: { _ in f.source })
        do {
            _ = try await manager.fetchOriginalContentBatch(bookID: f.book.id, sourceID: f.source.id,
                book: f.dto, chapterIndexes: [0,1,2], store: f.store, cache: f.cache)
            Issue.record("Ordinary callback failure cannot become batch success")
        } catch let error as OriginalContentBatchFailure {
            #expect((error.executionError as? LegadoRuntimeError)?.code == "SCRIPT_ERROR")
            #expect(error.publicationError == nil); #expect(error.verifiedSavedIndexes == [0])
        }
        let actual = try await BookStore(metadataFileURL: f.metadata).originalRuntimeChapters(bookID: f.book.id)
        #expect(actual.map(\.cachedFilename) == ["0.txt", nil, nil])
        #expect(f.cache.loadChapterPackageSync(bookId: f.book.id, chapterIndex: 0)?.content.contains("index 0") == true)
    }
    @Test("foreign file replacement rejects a stale lease and cannot be legitimized by retry")
    func bodyCasCannotOverwriteOrAdoptAnotherWriter() async throws {
        let f = try await fixture(); defer { cleanup(f.root) }
        let host = LegadoPersistentStateHost(backing: BatchNoSourceBacking()); let task = "owned-cas"
        let owner = try await host.bindContentBatch(sourceURL: f.source.bookSourceUrl, sourceRevision: "r1", taskID: task,
            store: f.store, bookID: f.book.id, sourceID: f.source.id, book: f.dto, chapters: grants(f),
            deadline: Date().addingTimeInterval(60), cache: f.cache)
        let snapshot = try await BatchHostFixture.read(host, owner: owner, task: task, source: f.source.bookSourceUrl, book: f.dto.bookURL, index: 0)
        _ = try await f.cache.saveToCache(content: "Foreign successful writer prose.", bookId: f.book.id, chapterIndex: 0,
            sourceURL: f.chapters[0].url, tocTitle: f.chapters[0].title, storeNormalizedHTML: false)
        let staleCommitted = try await BatchHostFixture.commit(host, owner: owner, task: task, snapshot: snapshot, body: "Stale body")
        #expect(!staleCommitted)
        do {
            _ = try await BatchHostFixture.read(host, owner: owner, task: task, source: f.source.bookSourceUrl, book: f.dto.bookURL, index: 0)
            Issue.record("Foreign proof cannot be adopted on CAS retry")
        } catch let error as LegadoRuntimeError { #expect(error.code == "STATE_CONFLICT") }
        #expect(f.cache.loadChapterPackageSync(bookId: f.book.id, chapterIndex: 0)?.content == "Foreign successful writer prose.")
        await host.revoke(owner: owner)
    }
    @Test("wrong task, revoked grant and changed TOC refuse any body mutation")
    func bodyOwnerUsesTaskGenerationAndCurrentActualToc() async throws {
        let f = try await fixture(); defer { cleanup(f.root) }
        let host = LegadoPersistentStateHost(backing: BatchNoSourceBacking()); let task = "owned-current"
        let current = grants(f)
        let owner = try await host.bindContentBatch(sourceURL: f.source.bookSourceUrl, sourceRevision: "r1", taskID: task,
            store: f.store, bookID: f.book.id, sourceID: f.source.id, book: f.dto, chapters: current,
            deadline: Date().addingTimeInterval(60), cache: f.cache)
        do {
            _ = try await BatchHostFixture.read(host, owner: owner, task: "wrong", source: f.source.bookSourceUrl, book: f.dto.bookURL, index: 0)
            Issue.record("Another task cannot borrow this body grant")
        } catch let error as LegadoRuntimeError { #expect(error.code == "INVALID_STATE_OWNER") }
        let snapshot = try await BatchHostFixture.read(host, owner: owner, task: task, source: f.source.bookSourceUrl, book: f.dto.bookURL, index: 0)
        var changed = f.chapters
        changed[0] = OnlineChapterRef(index: 0, title: "Replacement", url: "https://batch-owned.invalid/new")
        f.store.updateOnlineChapters(bookId: f.book.id, chapters: changed)
        await BookStore.queuedWritesLanded()
        do {
            _ = try await BatchHostFixture.commit(host, owner: owner, task: task, snapshot: snapshot, body: "Old request body")
            Issue.record("TOC replacement cannot receive an old body")
        } catch let error as LegadoRuntimeError { #expect(error.code == "STATE_CONFLICT") }
        current[1].generation.revoke()
        await #expect(throws: CancellationError.self) {
            _ = try await BatchHostFixture.read(host, owner: owner, task: task, source: f.source.bookSourceUrl, book: f.dto.bookURL, index: 1)
        }
        #expect(f.cache.loadChapterPackageSync(bookId: f.book.id, chapterIndex: 0) == nil)
        await host.revoke(owner: owner)
        #expect(await host.ownershipCounts().leases == 0)
    }
    @Test("final direct small-map assignment follows the exact accepted large-variable proof")
    func finalBookSetterPersistsSmallAndPreservesAcceptedLargeCompanion() async throws {
        let f = try await fixture(); defer { cleanup(f.root) }
        let host = LegadoPersistentStateHost(backing: BatchNoSourceBacking()); let task = "owned-finish"
        let owner = try await host.bindContentBatch(sourceURL: f.source.bookSourceUrl, sourceRevision: "r1", taskID: task,
            store: f.store, bookID: f.book.id, sourceID: f.source.id, book: f.dto, chapters: grants(f),
            deadline: Date().addingTimeInterval(60), cache: f.cache)
        let variableOwner = try AppLegadoBookStateOwner(store: f.store, bookID: f.book.id, sourceID: f.source.id,
            bookURL: f.dto.bookURL, chapter: nil, generation: nil)
        let smallKey = String(decoding: try JSONSerialization.data(withJSONObject:
            [f.source.bookSourceUrl, "variables", "book", f.dto.bookURL, ""]), as: UTF8.self)
        let keys = [LegadoEntityStateKey(wire: smallKey, chapterURL: nil, largeVariable: nil)]
        let cancellation = OriginalRuntimeCommitCancellation()
        let beforeGate = try Data(contentsOf: f.metadata)
        let realProof = try await variableOwner.read(keys: keys, deadline: Date().addingTimeInterval(30), cancellation: cancellation)
        await #expect(throws: CancellationError.self) {
            _ = try await variableOwner.commit(snapshot: realProof, keys: keys,
                changes: [smallKey: Data("{\"sealed\":\"forbidden\"}".utf8)], deadline: Date().addingTimeInterval(30),
                cancellation: cancellation, claimCommit: { false })
        }
        #expect(try Data(contentsOf: f.metadata) == beforeGate)
        let largeKey = String(decoding: try JSONSerialization.data(withJSONObject:
            [f.source.bookSourceUrl, "big-variable", "book", f.dto.bookURL, "", "large"]), as: UTF8.self)
        let snapshot = try await BatchHostFixture.call(host, task: task, operation: "state.read", input: ["owner": owner, "keys": [largeKey]])
        let revision = try #require(snapshot["revision"] as? NSNumber)
        let large = String(repeating: "x", count: 10_000)
        let saved = try await BatchHostFixture.call(host, task: task, operation: "state.commit",
            input: ["owner": owner, "revision": revision, "changes": [largeKey: Data(large.utf8).base64EncodedString()]])
        #expect(saved["committed"] as? Bool == true)
        var result = f.dto; result.variable = "{\"direct\":\"accepted\"}"
        let changed = try await host.finishContentBatchResult(owner: owner, taskID: task, book: result, deadline: Date().addingTimeInterval(30))
        #expect(changed)
        let reopened = BookStore(metadataFileURL: f.metadata)
        let actual = await reopened.prepareOriginalRuntimeBookSnapshot(id: f.book.id, sourceID: f.source.id, bookURL: f.dto.bookURL)
        #expect(actual?.variables == ["direct": "accepted", "large": large])
        let before = try Data(contentsOf: f.metadata)
        let repeatedChanged = try await host.finishContentBatchResult(owner: owner, taskID: task, book: result, deadline: Date().addingTimeInterval(30))
        #expect(!repeatedChanged)
        #expect(try Data(contentsOf: f.metadata) == before)
        await host.revoke(owner: owner)
    }
    @Test("App edits or actual final-book write failure retain body prefix and never get success")
    func finalBookCasRejectsUserEditAndFailedIoWithoutLosingBodyPrefix() async throws {
        for failsIO in [false, true] {
            let f = try await fixture()
            defer {
                do { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.root.path) }
                catch { Issue.record("Fixture permissions could not be restored: \(error)") }
                cleanup(f.root)
            }
            let host = LegadoPersistentStateHost(backing: BatchNoSourceBacking()); let task = "owned-finish-conflict"
            let owner = try await host.bindContentBatch(sourceURL: f.source.bookSourceUrl, sourceRevision: "r1", taskID: task,
                store: f.store, bookID: f.book.id, sourceID: f.source.id, book: f.dto, chapters: grants(f),
                deadline: Date().addingTimeInterval(60), cache: f.cache)
            let snapshot = try await BatchHostFixture.read(host, owner: owner, task: task, source: f.source.bookSourceUrl, book: f.dto.bookURL, index: 0)
            #expect(try await BatchHostFixture.commit(host, owner: owner, task: task, snapshot: snapshot, body: "Real body saved before final metadata failure."))
            if failsIO {
                try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.root.path)
            } else {
                f.store.updateBookRuntimeVariables(bookId: f.book.id, variables: ["user": "current"])
                f.store.flushPendingMetadataSave()
                await BookStore.queuedWritesLanded()
            }
            let before = try Data(contentsOf: f.metadata)
            var result = f.dto; result.variable = "{\"stale\":\"forbidden\"}"
            do {
                _ = try await host.finishContentBatchResult(owner: owner, taskID: task, book: result, deadline: Date().addingTimeInterval(30))
                Issue.record("Final metadata conflict/I/O failure cannot be acknowledged")
            } catch let error as LegadoRuntimeError where !failsIO { #expect(error.code == "STATE_CONFLICT") }
            catch { #expect(failsIO) }
            #expect(try Data(contentsOf: f.metadata) == before)
            #expect(f.cache.loadChapterPackageSync(bookId: f.book.id, chapterIndex: 0)?.content.contains("saved before") == true)
            await host.revoke(owner: owner)
        }
    }
}
