import Foundation
import LegadoRuntime
import Testing
@testable import yuedu_app

@Suite("Product mainJs source routing", .serialized)
struct LegadoMainJSSourceServiceTests {
    @Test("pure mainJs goes through search details TOC and native plain-text packaging after reload")
    func readingChainSurvivesContextReload() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = MainJSFixtureExecutor()
        let source = source()
        let fetcher = BookSourceFetcher(mainJSService: LegadoMainJSSourceService(executor: executor, contextDirectory: directory))
        let book = try #require(try await fetcher.search(query: "fixture", in: source).first)
        let details = try await fetcher.fetchBookInfoPackage(url: book.bookUrl, source: source,
            runtimeVariables: book.runtimeVariables, knownBook: book)
        let toc = try await fetcher.fetchTOCPackage(tocUrl: details.tocUrl, source: source, runtimeVariables: details.runtimeVariables)
        let persisted = try JSONDecoder().decode(TOCPackage.self, from: JSONEncoder().encode(toc))
        let chapter = try #require(persisted.chapters.first)

        let nextExecutor = MainJSFixtureExecutor()
        let reopened = BookSourceFetcher(mainJSService: LegadoMainJSSourceService(executor: nextExecutor, contextDirectory: directory))
        var readingBook = ReadingBook(title: book.name, source: source.bookSourceUrl, contentFilename: "")
        readingBook.isOnline = true
        readingBook.bookSourceId = source.id
        readingBook.onlineChapters = persisted.chapters
        let bookID = readingBook.id
        defer { reopened.clearAllChapterCache(bookId: bookID) }
        let package = try await reopened.fetchChapterPackage(ref: chapter, bookId: bookID, source: source)
        #expect(package.content == "Native text & preserved variables\nSecond line")
        #expect(package.rawHTMLFilename == nil)
        #expect(package.normalizedHTMLFilename == nil)
        let cached = try #require(reopened.loadChapterPackageSync(bookId: bookID, chapterIndex: 0,
            expectedSourceURL: chapter.url, expectedTOCTitle: chapter.title))
        #expect(cached.content == "Native text & preserved variables\nSecond line")
        #expect(cached.rawHTMLFilename == nil)
        #expect(cached.normalizedHTMLFilename == nil)
        #expect(OnlineChapterCacheWritePolicy.isReusableCachedPackage(cached, hasBookSource: true))

        // Exercise the same cache-only payload path used by the native reader.
        // Pure-text packages rebuild XHTML without claiming nonexistent source HTML.
        let reader = OnlineChapterContentService(book: readingBook, store: nil)
        let payload = try await reader.payload(at: 0, policy: .cacheOnly)
        #expect(payload.plainText == "Native text & preserved variables\nSecond line")
        #expect(payload.title == chapter.title)
        #expect(payload.sourceHref == chapter.url)
        if case .html(let html) = payload.body {
            #expect(html.contains("<article id=\"reader-content\">"))
            #expect(html.contains("Native text &amp; preserved variables"))
            #expect(html.contains("Second line"))
        } else {
            Issue.record("The reader must build escaped XHTML from the cached mainJs body")
        }
        let reopenedReader = OnlineChapterContentService(book: readingBook, store: nil)
        let reopenedPayload = try await reopenedReader.payload(at: 0, policy: .cacheOnly)
        #expect(reopenedPayload == payload)
        #expect(await executor.operations() == ["search", "details", "toc"])
        #expect(await nextExecutor.operations() == ["content"])

        let inputJSON = try await nextExecutor.lastInputJSON()
        let input = try #require(try JSONSerialization.jsonObject(with: Data(inputJSON.utf8)) as? [String: Any])
        let rawBook = try #require(input["book"] as? [String: Any])
        #expect((rawBook["time"] as? NSNumber)?.int64Value == Int64.max)
        #expect(rawBook["infoHtml"] as? String == "UNIQUE_BOOK_PAYLOAD")
        #expect(rawBook["variable"] as? String == #"{"token":"kept","detail":"yes"}"#)
        let rawChapter = try #require(input["chapter"] as? [String: Any])
        #expect(rawChapter["variable"] as? String == #"{"chapterToken":"one"}"#)
        #expect(rawChapter["resourceUrl"] as? String == "opaque-resource-metadata")
        #expect(input["nextChapterUrl"] as? String == "https://main-js.invalid/chapter/2")
    }

    @Test("streaming routes mainJs before the declarative searchUrl guard")
    func streamingUsesExplicitEngine() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = MainJSFixtureExecutor()
        let fetcher = BookSourceFetcher(mainJSService: LegadoMainJSSourceService(executor: executor, contextDirectory: directory))
        let result = try await fetcher.searchStreaming(query: "fixture", in: source()) { _ in
            Issue.record("A whole-array JVM result must not also be emitted as a streamed duplicate")
        }
        #expect(result.books.count == 1)
        #expect(!result.streamed)
        #expect(await executor.operations() == ["search"])
    }

    @Test("missing native runtime stays an error even with declarative rules available")
    func runtimeFailureDoesNotFallBack() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = MainJSFixtureExecutor(createFailure: "MISSING_RUNTIME")
        let fetcher = BookSourceFetcher(mainJSService: LegadoMainJSSourceService(executor: executor, contextDirectory: directory))
        var candidate = source()
        candidate.searchUrl = "data:text/plain,legacy"
        candidate.ruleSearch.bookList = "legacy"
        do {
            _ = try await fetcher.search(query: "fixture", in: candidate)
            Issue.record("mainJs must not silently execute declarative rules")
        } catch { #expect((error as? LegadoRuntimeError)?.code == "MISSING_RUNTIME") }
        #expect(await executor.operations().isEmpty)
    }

    @Test("details TOC and content reject missing original context")
    func missingContextIsExplicit() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = MainJSFixtureExecutor()
        let service = LegadoMainJSSourceService(executor: executor, contextDirectory: directory)
        let source = source()
        do { _ = try await service.details(url: "https://main-js.invalid/book", source: source, runtimeVariables: nil, knownBook: nil); Issue.record("Missing book context accepted") }
        catch { #expect((error as? LegadoRuntimeError)?.code == "CONTEXT_MISSING") }
        do { _ = try await service.toc(url: "https://main-js.invalid/toc", source: source, runtimeVariables: nil); Issue.record("Missing TOC context accepted") }
        catch { #expect((error as? LegadoRuntimeError)?.code == "CONTEXT_MISSING") }
        do { _ = try await service.content(ref: .init(index: 0, title: "One", url: "https://main-js.invalid/chapter/1"), source: source); Issue.record("Missing chapter context accepted") }
        catch { #expect((error as? LegadoRuntimeError)?.code == "CONTEXT_MISSING") }
        #expect(await executor.creationCount() == 0)
    }

    @Test("book references cannot be reused with edited source code")
    func sourceSignatureRejectsStaleContext() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = LegadoMainJSSourceService(executor: MainJSFixtureExecutor(), contextDirectory: directory)
        var source = source()
        let book = try #require(try await service.search(query: "fixture", page: 1, source: source).first)
        source.mainJs = "function search(){return [];} // changed"
        do { _ = try await service.details(url: book.bookUrl, source: source, runtimeVariables: book.runtimeVariables, knownBook: book); Issue.record("Stale DTO accepted") }
        catch { #expect((error as? LegadoRuntimeError)?.code == "CONTEXT_MISMATCH") }
    }

    @Test("a corrupted durable book record is rejected before calling the engine")
    func recordIntegrityIsChecked() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = source()
        let service = LegadoMainJSSourceService(executor: MainJSFixtureExecutor(), contextDirectory: directory)
        let book = try #require(try await service.search(query: "fixture", page: 1, source: source).first)
        let record = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try Data("tampered".utf8).write(to: record)
        let freshExecutor = MainJSFixtureExecutor()
        let reopened = LegadoMainJSSourceService(executor: freshExecutor, contextDirectory: directory)
        do { _ = try await reopened.details(url: book.bookUrl, source: source, runtimeVariables: book.runtimeVariables, knownBook: book); Issue.record("Corrupt record accepted") }
        catch { #expect((error as? LegadoRuntimeError)?.code == "CONTEXT_CORRUPT") }
        #expect(await freshExecutor.creationCount() == 0)
    }

    @Test("two thousand chapters reference one book record without copying its HTML")
    func largeTOCDoesNotDuplicateBookDTO() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = source()
        let largeHTML = String(repeating: "UNIQUE_BOOK_PAYLOAD", count: 5_000)
        let executor = MainJSFixtureExecutor(chapterCount: 2_000, infoHTML: largeHTML)
        let service = LegadoMainJSSourceService(executor: executor, contextDirectory: directory)
        let book = try #require(try await service.search(query: "fixture", page: 1, source: source).first)
        let toc = try await service.toc(url: book.tocUrl, source: source, runtimeVariables: book.runtimeVariables)
        #expect(toc.chapters.count == 2_000)
        let bytes = try JSONEncoder().encode(toc)
        #expect(bytes.count < 4_000_000, "TOC storage must grow with chapter DTOs, not bookBytes × chapters")
        #expect(!String(decoding: bytes, as: UTF8.self).contains("UNIQUE_BOOK_PAYLOAD"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
    }

    @Test("concurrent calls reuse one session and source edits close the previous session")
    func sessionsAreReusedAndRevised() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = MainJSFixtureExecutor()
        let service = LegadoMainJSSourceService(executor: executor, contextDirectory: directory)
        var source = source()
        source.lastUpdateTime = 1
        async let first = service.search(query: "a", page: 1, source: source)
        async let second = service.search(query: "b", page: 1, source: source)
        _ = try await (first, second)
        #expect(await executor.creationCount() == 1)
        source.mainJs = "function search(){return [];} // revision two"
        source.lastUpdateTime = 2
        _ = try await service.search(query: "c", page: 1, source: source)
        #expect(await executor.creationCount() == 2)
        #expect(await executor.closedSessions() == ["session-1"])
        try await service.closeSessions()
        #expect(await executor.closedSessions() == ["session-1", "session-2"])
    }

    @Test("an unchanged newer source clock prevents a delayed changed revision from replacing it")
    func sourceClockHighWaterRejectsDelayedRevision() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = MainJSFixtureExecutor()
        let service = LegadoMainJSSourceService(executor: executor, contextDirectory: directory)
        var source = source()
        source.lastUpdateTime = 1
        _ = try await service.search(query: "A1", page: 1, source: source)
        source.lastUpdateTime = 3
        _ = try await service.search(query: "A3 unchanged", page: 1, source: source)
        var delayed = source
        delayed.mainJs = "function search(){return [];} // delayed revision B"
        delayed.lastUpdateTime = 2
        do {
            _ = try await service.search(query: "B2 delayed", page: 1, source: delayed)
            Issue.record("An older changed revision replaced the newer unchanged source")
        } catch { #expect((error as? LegadoRuntimeError)?.code == "SOURCE_CHANGED") }
        #expect(await executor.creationCount() == 1)
        #expect(await executor.closedSessions().isEmpty)
        _ = try await service.search(query: "A3 remains usable", page: 1, source: source)
        #expect(await executor.creationCount() == 1)
        try await service.closeSessions()
        #expect(await executor.closedSessions() == ["session-1"])
    }

    @Test("cancelling an in-flight executor releases the source gate for the next request")
    func cancellationReleasesSourceGate() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = CancellableMainJSExecutor()
        let service = LegadoMainJSSourceService(executor: executor, contextDirectory: directory)
        let source = source()
        let pending = Task { try await service.search(query: "cancel", page: 1, source: source) }
        await executor.waitUntilExecuting()
        pending.cancel()
        do { _ = try await pending.value; Issue.record("Cancelled source operation returned success") }
        catch { #expect(error is CancellationError) }
        let recovered = try await service.search(query: "recovery", page: 1, source: source)
        #expect(recovered.count == 1)
        #expect(await executor.observedCancellation())
    }

    @Test("a queued operation times out before the first holder is released")
    func queuedDeadlineDoesNotDependOnHolderProgress() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = CancellableMainJSExecutor()
        let service = LegadoMainJSSourceService(executor: executor, contextDirectory: directory, operationTimeout: 0.25)
        let source = source()
        let holder = Task { try await service.search(query: "holder", page: 1, source: source) }
        await executor.waitUntilExecuting()
        do {
            _ = try await service.search(query: "waiter", page: 1, source: source)
            Issue.record("Queued operation ignored its deadline")
        } catch { #expect((error as? LegadoRuntimeError)?.code == "TIMEOUT") }
        // This assertion happens before the test permits the holder to finish.
        // There is no timing sleep to arrange or release the test's source gate.
        #expect(await executor.isHoldingRequest())
        await executor.releasePending()
        do { _ = try await holder.value; Issue.record("The expired holder returned success") }
        catch { #expect((error as? LegadoRuntimeError)?.code == "TIMEOUT") }
        let recovered = try await service.search(query: "recovery", page: 1, source: source)
        #expect(recovered.count == 1, "The expired waiter must be removed from the gate")
    }

    @Test("unsupported media sources and HTML content are explicit errors")
    func unsupportedFormatsDoNotInvokeJSC() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = MainJSFixtureExecutor(content: "<img src='deferred,{js:1}'>")
        let service = LegadoMainJSSourceService(executor: executor, contextDirectory: directory)
        var source = source()
        source.bookSourceType = 1
        do { _ = try await service.search(query: "fixture", page: 1, source: source); Issue.record("Audio source accepted") }
        catch { #expect((error as? LegadoRuntimeError)?.code == "UNSUPPORTED_CAPABILITY") }
        #expect(await executor.creationCount() == 0)
        source.bookSourceType = 0
        let book = try #require(try await service.search(query: "fixture", page: 1, source: source).first)
        let toc = try await service.toc(url: book.tocUrl, source: source, runtimeVariables: book.runtimeVariables)
        do { _ = try await service.content(ref: toc.chapters[0], source: source); Issue.record("Deferred HTML accepted") }
        catch { #expect((error as? LegadoRuntimeError)?.code == "UNSUPPORTED_CAPABILITY") }
    }

    @Test("a previously cached chapter cannot hide an explicit JVM failure")
    func oldChapterCacheDoesNotMaskFailure() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = source()
        let service = LegadoMainJSSourceService(executor: MainJSFixtureExecutor(), contextDirectory: directory)
        let book = try #require(try await service.search(query: "fixture", page: 1, source: source).first)
        let toc = try await service.toc(url: book.tocUrl, source: source, runtimeVariables: book.runtimeVariables)
        let bookID = UUID()
        let goodFetcher = BookSourceFetcher(mainJSService: service)
        defer { goodFetcher.clearAllChapterCache(bookId: bookID) }
        _ = try await goodFetcher.fetchChapterPackage(ref: toc.chapters[0], bookId: bookID, source: source)
        let failing = BookSourceFetcher(mainJSService: LegadoMainJSSourceService(
            executor: MainJSFixtureExecutor(createFailure: "MISSING_RUNTIME"), contextDirectory: directory))
        do { _ = try await failing.fetchChapterPackage(ref: toc.chapters[0], bookId: bookID, source: source); Issue.record("Legacy cache hid missing JVM") }
        catch { #expect((error as? LegadoRuntimeError)?.code == "MISSING_RUNTIME") }
    }

    private func source() -> BookSource {
        var value = BookSource(bookSourceUrl: "https://main-js.invalid", bookSourceName: "Synthetic mainJs")
        value.mainJs = "function search(key,page){return [];};"
        return value
    }
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LegadoMainJS-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private actor MainJSFixtureExecutor: LegadoMainJSExecuting {
    private let createFailure: String?
    private let chapterCount: Int
    private let infoHTML: String
    private let content: String
    private var created = 0
    private var closed: [String] = []
    private var calls: [(String, String)] = []

    init(createFailure: String? = nil, chapterCount: Int = 2, infoHTML: String = "UNIQUE_BOOK_PAYLOAD",
         content: String = "Native text & preserved variables\nSecond line") {
        self.createFailure = createFailure; self.chapterCount = chapterCount; self.infoHTML = infoHTML; self.content = content
    }
    func createSession(sourceJSON: String) async throws -> String {
        if let createFailure { throw LegadoRuntimeError(code: createFailure, message: "Synthetic runtime failure") }
        created += 1
        return "session-\(created)"
    }
    func execute(sessionID: String, operation: String, requestJSON: String) async throws -> String {
        calls.append((operation, requestJSON))
        let request = try #require(try JSONSerialization.jsonObject(with: Data(requestJSON.utf8)) as? [String: Any])
        let result: Any
        switch operation {
        case "search":
            result = [["bookUrl": "https://main-js.invalid/book", "tocUrl": "https://main-js.invalid/toc",
                       "name": "Fixture", "author": "Author", "type": 8, "infoHtml": infoHTML,
                       "time": NSNumber(value: Int64.max), "variable": #"{"token":"kept"}"#]]
        case "details":
            var book = try #require(request["book"] as? [String: Any])
            book["variable"] = #"{"token":"kept","detail":"yes"}"#
            result = book
        case "toc":
            result = (0..<chapterCount).map { index -> [String: Any] in
                ["url": "https://main-js.invalid/chapter/\(index + 1)", "title": "Chapter \(index + 1)", "index": index,
                 "bookUrl": "https://main-js.invalid/book", "baseUrl": "https://main-js.invalid/toc",
                 "isVip": false, "isPay": false, "isVolume": false,
                 "variable": #"{"chapterToken":"one"}"#, "resourceUrl": "opaque-resource-metadata"]
            }
        case "content": result = content
        default: throw LegadoRuntimeError(code: "UNSUPPORTED_OPERATION", message: operation)
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
    }
    func closeSession(id: String) async throws { closed.append(id) }
    func operations() -> [String] { calls.map(\.0) }
    func creationCount() -> Int { created }
    func closedSessions() -> [String] { closed }
    func lastInputJSON() throws -> String { try #require(calls.last?.1) }
}

/// Only a fake-executor cancellation test; this does not claim JNI/CPU cancellation evidence.
private actor CancellableMainJSExecutor: LegadoMainJSExecuting {
    private let delegate = MainJSFixtureExecutor()
    private var heldOnce = false
    private var cancelled = false
    private var pending: CheckedContinuation<Void, Error>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    func createSession(sourceJSON: String) async throws -> String { try await delegate.createSession(sourceJSON: sourceJSON) }
    func execute(sessionID: String, operation: String, requestJSON: String) async throws -> String {
        if !heldOnce {
            heldOnce = true
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    pending = continuation
                    observers.forEach { $0.resume() }
                    observers.removeAll()
                }
            } onCancel: { Task { await self.cancelPending() } }
        }
        return try await delegate.execute(sessionID: sessionID, operation: operation, requestJSON: requestJSON)
    }
    func closeSession(id: String) async throws { try await delegate.closeSession(id: id) }
    func waitUntilExecuting() async {
        if pending != nil { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func observedCancellation() -> Bool { cancelled }
    func isHoldingRequest() -> Bool { pending != nil }
    func releasePending() {
        pending?.resume()
        pending = nil
    }
    private func cancelPending() {
        cancelled = true
        pending?.resume(throwing: CancellationError())
        pending = nil
    }
}
