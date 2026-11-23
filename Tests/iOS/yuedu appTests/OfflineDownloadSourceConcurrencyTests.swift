import Foundation
import LegadoRuntime
import Testing
@testable import yuedu_app

/// These probes verify source admission only. The separate native held-HTTP test
/// exercises the actual JVM, cache generations and durable App owners.
@Suite("Offline source admission", .serialized)
@MainActor
struct OfflineDownloadSourceConcurrencyTests {
    @Test("the audited template has two slots and queued cancellation does not leak one")
    func boundedReadersAndCancellation() async throws {
        let fixture = Fixture()
        let a = fixture.start("a"); let b = fixture.start("b")
        defer { a.cancel(); b.cancel() }
        try await fixture.probe.waitForEntries(2)
        let cancelled = fixture.start("cancelled")
        defer { cancelled.cancel() }
        try await fixture.service.waitUntilSourceOperationsQueued(fixture.source.bookSourceUrl, count: 1)
        cancelled.cancel()
        do { _ = try await finish(cancelled); Issue.record("Queued cancellation must throw") }
        catch { #expect(error is CancellationError) }
        let c = fixture.start("c")
        defer { c.cancel() }
        try await fixture.service.waitUntilSourceOperationsQueued(fixture.source.bookSourceUrl, count: 1)
        await fixture.probe.release("a")
        try await fixture.probe.waitForEntries(3)
        let entered = await fixture.probe.entries
        #expect(entered == ["a", "b", "c"] || entered == ["b", "a", "c"])
        #expect(await fixture.probe.peak == 2)
        #expect(await fixture.probe.staticURLFlags == ["a": true, "b": true, "c": true])
        await fixture.probe.releaseAll()
        _ = try await finish(a); _ = try await finish(b); _ = try await finish(c)
    }

    @Test("a different source revision waits even when one read slot is free")
    func sourceRevisionsNeverOverlap() async throws {
        let fixture = Fixture()
        let first = fixture.start("old")
        defer { first.cancel() }
        try await fixture.probe.waitForEntries(1)
        var revised = fixture.source
        revised.lastUpdateTime += 1
        revised.header = #"{"User-Agent":"Different static agent"}"#
        let second = fixture.start("new", source: revised)
        defer { second.cancel() }
        try await fixture.service.waitUntilSourceOperationsQueued(fixture.source.bookSourceUrl, count: 1)
        #expect(await fixture.probe.entries == ["old"])
        await fixture.probe.release("old")
        try await fixture.probe.waitForEntries(2)
        #expect(await fixture.probe.peak == 1)
        await fixture.probe.releaseAll()
        _ = try await finish(first); _ = try await finish(second)
    }

    @Test("a stateful writer cannot be overtaken by a later audited reader")
    func writersKeepFifoOrder() async throws {
        let fixture = Fixture()
        let first = fixture.start("reader")
        defer { first.cancel() }
        try await fixture.probe.waitForEntries(1)
        var writerSource = fixture.source
        writerSource.lastUpdateTime += 1
        writerSource.ruleContent.title = "@js:java.put('state','authored')"
        let writer = fixture.start("writer", source: writerSource)
        defer { writer.cancel() }
        try await fixture.service.waitUntilSourceOperationsQueued(fixture.source.bookSourceUrl, count: 1)
        var laterSource = fixture.source
        laterSource.lastUpdateTime += 2
        let later = fixture.start("later", source: laterSource)
        defer { later.cancel() }
        try await fixture.service.waitUntilSourceOperationsQueued(fixture.source.bookSourceUrl, count: 2)
        await fixture.probe.release("reader")
        try await fixture.probe.waitForEntries(2)
        #expect(await fixture.probe.entries == ["reader", "writer"])
        await fixture.probe.release("writer")
        try await fixture.probe.waitForEntries(3)
        #expect(await fixture.probe.entries == ["reader", "writer", "later"])
        #expect(await fixture.probe.peak == 1)
        await fixture.probe.releaseAll()
        _ = try await finish(first); _ = try await finish(writer); _ = try await finish(later)
        #expect(await fixture.probe.staticURLFlags == ["reader": true, "writer": false, "later": true])
    }

    @Test("a queued source deadline expires without waiting for the HTTP owner")
    func queuedDeadlineDoesNotLeakSlots() async throws {
        let fixture = Fixture()
        let first = fixture.start("held")
        defer { first.cancel() }
        try await fixture.probe.waitForEntries(1)
        var revised = fixture.source; revised.lastUpdateTime += 1
        revised.header = #"{"User-Agent":"Queued revision"}"#
        let expiring = fixture.start("expired", source: revised, deadline: Date().addingTimeInterval(0.1))
        defer { expiring.cancel() }
        do { _ = try await finish(expiring); Issue.record("Queued deadline must throw") }
        catch { #expect((error as? LegadoRuntimeError)?.code == "TIMEOUT") }
        let next = fixture.start("next")
        defer { next.cancel() }
        try await fixture.probe.waitForEntries(2)
        #expect(await fixture.probe.entries == ["held", "next"])
        await fixture.probe.releaseAll()
        _ = try await finish(first); _ = try await finish(next)
    }

    @Test("edited scripts, dynamic headers and URL options never enter the read-only template")
    func conservativeTemplateBoundary() {
        let fixture = Fixture()
        #expect(fixture.permits(fixture.source))
        var candidate = fixture.source
        candidate.ruleContent.nextContentUrl = OriginalContentReadPolicy.nextPage
        #expect(fixture.permits(candidate))
        candidate.ruleContent.nextContentUrl += " "
        #expect(!fixture.permits(candidate))
        candidate = fixture.source; candidate.jsLib = "java.put('side-effect','1')"
        #expect(!fixture.permits(candidate))
        candidate = fixture.source; candidate.eventListener = true
        #expect(!fixture.permits(candidate))
        candidate = fixture.source; candidate.header = "@js:({})"
        #expect(!fixture.permits(candidate))
        candidate = fixture.source; candidate.loginCheckJs = "result"
        #expect(!fixture.permits(candidate))
        candidate = fixture.source; candidate.ruleContent.replaceRegex = "@js:result"
        #expect(!fixture.permits(candidate))
        #expect(!fixture.permits(fixture.source, url: "https://fixture.invalid/c,{}"))
        #expect(!fixture.permits(fixture.source, url: "{{book.put('x','y')}}"))
    }

    @Test("static URL enforcement is an explicit embedding option and absent by default")
    func staticUrlsAreEmbeddingOnly() throws {
        let standard = LegadoSessionOptions(httpTransport: .jvmOkHttp)
        let standardJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(standard)) as? [String: Any]
        #expect(standardJSON?["staticHttpUrlsOnly"] == nil)
        let guarded = NativeLegadoOriginalPreviewExecutor.embeddingOptions(owner: "test-owner", staticHttpUrlsOnly: true)
        let guardedJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(guarded)) as? [String: Any]
        #expect(guardedJSON?["staticHttpUrlsOnly"] as? Bool == true)
    }

    private func finish<T: Sendable>(_ task: Task<T, Error>) async throws -> T {
        defer { task.cancel() }
        return try await withThrowingTaskGroup(of: T.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5)) // An assertion deadline, never a state-settling delay.
                throw URLError(.timedOut)
            }
            return try await group.next()!
        }
    }

    private struct Fixture {
        let probe = AdmissionProbe()
        let store: BookStore
        let service: LegadoMainJSSourceService
        let source: BookSource
        let book: LegadoOriginalBook
        let bookID = UUID()

        init() {
            var source = BookSource(bookSourceUrl: "https://fixture.invalid", bookSourceName: "Audited fixture")
            source.lastUpdateTime = 1
            source.header = "{}"
            source.ruleContent.content = OriginalContentReadPolicy.content
            source.ruleContent.nextContentUrl = ""
            self.source = source
            book = .init(bookURL: "https://fixture.invalid/book", origin: source.bookSourceUrl,
                tocURL: "https://fixture.invalid/toc")
            store = BookStore(metadataFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("Admission-\(UUID().uuidString)/books_meta.json"), legacyMetadataDefaults: nil)
            service = LegadoMainJSSourceService(contentBatchExecutor: probe)
        }
        func chapter(url: String = "https://fixture.invalid/c") -> OriginalRuntimeBatchChapter {
            let ref = OnlineChapterRef(index: 0, title: "Fixture", url: url)
            return .init(chapter: ref, generation: .init(bookID: bookID, chapter: ref, token: UUID()),
                dto: .init(bookURL: book.bookURL, url: url, index: 0, title: ref.title, baseURL: book.tocURL))
        }
        func permits(_ source: BookSource, url: String = "https://fixture.invalid/c") -> Bool {
            OriginalContentReadPolicy.permits(source: source, book: book, chapters: [chapter(url: url)], singleChapter: true)
        }
        func start(_ id: String, source: BookSource? = nil,
                   deadline: Date = Date().addingTimeInterval(15)) -> Task<LegadoOriginalContentBatchResult, Error> {
            let source = source ?? self.source
            let chapter = chapter()
            return Task {
                try await service.originalContentBatch(source: source, store: store, bookID: bookID,
                    book: book, chapters: [chapter], taskID: id, deadline: deadline, singleChapter: true)
            }
        }
    }
}

private actor AdmissionProbe: LegadoOriginalContentBatchExecuting {
    private(set) var entries: [String] = []
    private(set) var peak = 0
    private(set) var staticURLFlags: [String: Bool] = [:]
    private var running = 0
    private struct Gate {
        let continuation: CheckedContinuation<Void, Error>
        let timer: Task<Void, Never>
    }
    private var gates: [String: Gate] = [:]
    private var observers: [UUID: (Int, Gate)] = [:]
    func execute(_ request: LegadoContentBatchExecutionRequest) async throws -> LegadoOriginalContentBatchResult {
        entries.append(request.taskID); running += 1; peak = max(peak, running)
        staticURLFlags[request.taskID] = request.staticHttpUrlsOnly
        defer { running -= 1 }
        let id = request.taskID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    await self?.cancelRun(id, error: URLError(.timedOut))
                }
                gates[id] = .init(continuation: continuation, timer: timer)
                let ready = observers.filter { entries.count >= $0.value.0 }
                for (key, value) in ready {
                    observers.removeValue(forKey: key); value.1.timer.cancel(); value.1.continuation.resume()
                }
            }
        } onCancel: { Task { await self.cancelRun(id, error: CancellationError()) } }
        return .init(book: request.book, missingChapters: [])
    }
    func waitForEntries(_ count: Int) async throws {
        try Task.checkCancellation()
        if entries.count >= count { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    await self?.cancelObserver(id, error: URLError(.timedOut))
                }
                observers[id] = (count, .init(continuation: continuation, timer: timer))
            }
        } onCancel: { Task { await self.cancelObserver(id, error: CancellationError()) } }
    }
    private func cancelObserver(_ id: UUID, error: Error) {
        guard let value = observers.removeValue(forKey: id) else { return }
        value.1.timer.cancel(); value.1.continuation.resume(throwing: error)
    }
    private func cancelRun(_ id: String, error: Error) {
        guard let gate = gates.removeValue(forKey: id) else { return }
        gate.timer.cancel(); gate.continuation.resume(throwing: error)
    }
    func release(_ id: String) {
        guard let gate = gates.removeValue(forKey: id) else { return }
        gate.timer.cancel(); gate.continuation.resume()
    }
    func releaseAll() {
        let pending = gates.values; gates = [:]
        for gate in pending { gate.timer.cancel(); gate.continuation.resume() }
    }
}
