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

    @Test("cold same-revision App owner siblings both complete their real metadata proofs")
    func coldOwnerSiblingsKeepIndependentGrants() async throws {
        try await withHostFixture { fixture in
            let first = fixture.start("first", index: 0)
            let second = fixture.start("second", index: 1)
            defer { first.cancel(); second.cancel() }
            try await fixture.probe.waitForEntries(2)
            await fixture.probe.release("first")
            let firstOwner = try await finish(first)
            // Finish one initial registration while the sibling still prepares.
            // A nil -> same-revision transition must not invalidate that sibling.
            await fixture.probe.release("second")
            let secondOwner = try await finish(second)
            #expect(firstOwner != secondOwner)
            #expect(try await fixture.host.finishContentBatchResult(owner: firstOwner, taskID: "first",
                book: fixture.book, deadline: Date().addingTimeInterval(5)) == false)
            #expect(try await fixture.host.finishContentBatchResult(owner: secondOwner, taskID: "second",
                book: fixture.book, deadline: Date().addingTimeInterval(5)) == false)
            let counts = await fixture.host.ownershipCounts()
            #expect(counts.bindings == 2)
            #expect(counts.sourceRevisions == 1)
        }
    }

    @Test("pending App grants reject revision changes, ABA, revocation and cancellation without leaking owners")
    func pendingOwnersCannotReviveAfterInvalidation() async throws {
        for scenario in ["change", "aba", "revoke", "cancel", "cancel-rpc"] {
            try await withHostFixture { fixture in
                let pending = fixture.start("pending", index: 0)
                defer { pending.cancel() }
                try await fixture.probe.waitForEntries(1)
                let oldOwner = try #require(await fixture.probe.boundOwners["pending"])
                var otherOwners: [String] = []
                do {
                    switch scenario {
                    case "change", "aba":
                        otherOwners.append(try await fixture.host.bind(sourceURL: fixture.sourceURL, sourceRevision: "r2"))
                        if scenario == "aba" {
                            otherOwners.append(try await fixture.host.bind(sourceURL: fixture.sourceURL, sourceRevision: "r1"))
                        }
                    case "revoke":
                        await fixture.host.revoke(owner: oldOwner)
                        otherOwners.append(try await fixture.host.bind(sourceURL: fixture.sourceURL, sourceRevision: "r1"))
                    case "cancel-rpc":
                        await fixture.host.cancel(taskID: "pending")
                        // Host RPC cancellation must reject publication even
                        // though Swift Task.checkCancellation still succeeds.
                        #expect(!pending.isCancelled)
                    default: pending.cancel()
                    }
                    await fixture.probe.release("pending")
                    do {
                        _ = try await finish(pending)
                        Issue.record("An invalidated pending owner must not be published: \(scenario)")
                    } catch {
                        if scenario == "cancel" || scenario == "cancel-rpc" { #expect(error is CancellationError) }
                        else { #expect((error as? LegadoRuntimeError)?.code == "SOURCE_CHANGED") }
                    }
                } catch {
                    for owner in otherOwners { await fixture.host.revoke(owner: owner) }
                    throw error
                }
                for owner in otherOwners { await fixture.host.revoke(owner: owner) }
                let counts = await fixture.host.ownershipCounts()
                #expect(counts.bindings == 0)
                #expect(counts.sourceRevisions == 0)
                #expect(counts.leases == 0)
            }
        }
    }

    @Test("independent chapter variables and cache publication preserve the sibling's exact owner proof")
    func siblingChapterWritesKeepTargetProofCurrent() async throws {
        try await withChapterFixture { fixture in
            let first = try #require(try await onChapterOwner(fixture.queue) {
                try fixture.owner.runtimeVariablesSnapshot(bookID: fixture.bookID, index: 0, url: fixture.chapters[0].url)
            })
            let second = try #require(try await onChapterOwner(fixture.queue) {
                try fixture.owner.runtimeVariablesSnapshot(bookID: fixture.bookID, index: 1, url: fixture.chapters[1].url)
            })
            #expect(try await onChapterOwner(fixture.queue) {
                try fixture.owner.publishCachedFiles(bookID: fixture.bookID,
                    updates: [.init(index: 0, chapterID: first.chapterID, url: first.url, filename: "0.txt")], beforeWrite: {})
            })
            let unchangedSibling = try #require(try await onChapterOwner(fixture.queue) {
                try fixture.owner.runtimeVariablesSnapshot(bookID: fixture.bookID, index: 1, url: second.url)
            })
            #expect(unchangedSibling == second)
            #expect(try await onChapterOwner(fixture.queue) {
                try fixture.owner.compareRuntimeVariables(expected: second, variables: nil)
            })
            #expect(try await onChapterOwner(fixture.queue) {
                try fixture.owner.compareRuntimeVariables(expected: second, variables: ["sibling": "accepted"])
            })
            #expect(try await onChapterOwner(fixture.queue) {
                try !fixture.owner.compareRuntimeVariables(expected: first, variables: ["stale": "denied"])
            })
            let refreshedFirst = try #require(try await onChapterOwner(fixture.queue) {
                try fixture.owner.runtimeVariablesSnapshot(bookID: fixture.bookID, index: 0, url: first.url)
            })
            #expect(try await onChapterOwner(fixture.queue) {
                try fixture.owner.compareRuntimeVariables(expected: refreshedFirst, variables: ["target": "accepted"])
            })
            // The publication must use the current whole-entry basis revision,
            // rather than skipping the UI view because this proof is older.
            #expect(fixture.owner.chapters(for: fixture.bookID)?[0].runtimeVariables == ["target": "accepted"])
            #expect(fixture.owner.chapters(for: fixture.bookID)?[0].cachedFilename == "0.txt")
            #expect(fixture.owner.chapters(for: fixture.bookID)?[1].runtimeVariables == ["sibling": "accepted"])
            #expect(try await onChapterOwner(fixture.queue) {
                let reopened = BookChapterStore(directoryURL: fixture.root, persistenceQueue: fixture.queue)
                return try reopened.ownerChapters(for: fixture.bookID)?[1].runtimeVariables == ["sibling": "accepted"]
            })
        }
    }

    @Test("same-target ABA, coalesced TOC reset, stale capture and eviction cannot revive a chapter proof")
    func chapterProofsRejectABAResetAndReload() async throws {
        try await withChapterFixture { fixture in
            let resetProof = try await onChapterOwner(fixture.queue) {
                let first = try #require(try fixture.owner.runtimeVariablesSnapshot(bookID: fixture.bookID,
                    index: 0, url: fixture.chapters[0].url))
                #expect(try fixture.owner.compareRuntimeVariables(expected: first, variables: ["state": "B"]))
                let middle = try #require(try fixture.owner.runtimeVariablesSnapshot(bookID: fixture.bookID, index: 0, url: first.url))
                #expect(middle.revision != first.revision)
                #expect(try fixture.owner.compareRuntimeVariables(expected: middle, variables: first.variables))
                #expect(try !fixture.owner.compareRuntimeVariables(expected: first, variables: ["stale": "denied"]))
                let beforeReset = try #require(try fixture.owner.runtimeVariablesSnapshot(bookID: fixture.bookID, index: 0, url: first.url))
                var edited = fixture.chapters; edited[0].title = "Temporary title"
                let replacement = edited
                var injected = false
                #expect(try fixture.owner.compareRuntimeVariables(expected: beforeReset, variables: ["writer": "ordered"], beforeWrite: {
                    guard !injected else { return }; injected = true
                    // committing=true forces both immediate edits to coalesce
                    // behind this real writer turn, including an equal restore.
                    fixture.owner.setChapters(replacement, for: fixture.bookID)
                    fixture.owner.setChapters(fixture.chapters, for: fixture.bookID)
                    do {
                        _ = try fixture.owner.runtimeVariablesSnapshot(bookID: fixture.bookID, index: 0, url: first.url)
                        Issue.record("An unaligned immediate view must not mint a proof")
                    } catch { #expect((error as? LegadoRuntimeError)?.code == "STATE_CONFLICT") }
                }))
                return beforeReset
            }
            // The queued restore runs before this next writer turn.
            try await onChapterOwner(fixture.queue) {
                #expect(try !fixture.owner.compareRuntimeVariables(expected: resetProof, variables: ["coalesced": "denied"]))
                let current = try #require(try fixture.owner.runtimeVariablesSnapshot(bookID: fixture.bookID,
                    index: 0, url: fixture.chapters[0].url))
                fixture.owner.removeChapters(for: fixture.bookID)
                fixture.owner.setChapters(fixture.chapters, for: fixture.bookID)
                #expect(try !fixture.owner.compareRuntimeVariables(expected: current, variables: ["cleared": "denied"]))
                try fixture.owner.flushReportingFailure(for: fixture.bookID)
                let beforeEviction = try #require(try fixture.owner.runtimeVariablesSnapshot(bookID: fixture.bookID,
                    index: 0, url: fixture.chapters[0].url))
                for _ in 0..<9 {
                    let other = UUID()
                    fixture.owner.setChapters(fixture.chapters, for: other)
                    try fixture.owner.flushReportingFailure(for: other)
                }
                let reloaded = try #require(try fixture.owner.runtimeVariablesSnapshot(bookID: fixture.bookID,
                    index: 0, url: fixture.chapters[0].url))
                #expect(reloaded != beforeEviction)
                #expect(try !fixture.owner.compareRuntimeVariables(expected: beforeEviction, variables: ["evicted": "denied"]))
                #expect(try fixture.owner.compareRuntimeVariables(expected: reloaded, variables: ["fresh": "accepted"]))
            }
            let afterDirectChange = try await onChapterOwner(fixture.queue) {
                let before = try #require(try fixture.owner.runtimeVariablesSnapshot(bookID: fixture.bookID,
                    index: 0, url: fixture.chapters[0].url))
                var queued = fixture.chapters; queued[1].title = "Queued ordinary change"
                let pendingList = queued
                var injected = false
                #expect(try fixture.owner.compareRuntimeVariables(expected: before, variables: ["writer": "accepted"], beforeWrite: {
                    guard !injected else { return }; injected = true
                    fixture.owner.setChapters(pendingList, for: fixture.bookID)
                }))
                // A direct owner turn consumes the pending value before its
                // already queued callback runs. That empty callback is no edit.
                fixture.owner.setChapters(fixture.chapters, for: fixture.bookID)
                return try #require(try fixture.owner.runtimeVariablesSnapshot(bookID: fixture.bookID,
                    index: 0, url: fixture.chapters[0].url))
            }
            #expect(try await onChapterOwner(fixture.queue) {
                try fixture.owner.runtimeVariablesSnapshot(bookID: fixture.bookID, index: 0,
                    url: fixture.chapters[0].url) == afterDirectChange
            })
        }
    }

    private struct ChapterFixture: @unchecked Sendable {
        let root: URL
        let queue: DispatchQueue
        let owner: BookChapterStore
        let bookID: UUID
        let chapters: [OnlineChapterRef]
    }

    private func withChapterFixture(_ body: (ChapterFixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChapterProof-\(UUID().uuidString)", isDirectory: true)
        let queue = DispatchQueue(label: "test.chapter.proof.\(UUID().uuidString)")
        let owner = BookChapterStore(directoryURL: root, persistenceQueue: queue)
        let fixture = ChapterFixture(root: root, queue: queue, owner: owner, bookID: UUID(), chapters: (0..<2).map {
            OnlineChapterRef(index: $0, title: "Chapter \($0)", url: "https://chapter-proof.invalid/c\($0)")
        })
        var problem: Error?
        do {
            try await onChapterOwner(queue) {
                owner.setChapters(fixture.chapters, for: fixture.bookID)
                try owner.flushReportingFailure(for: fixture.bookID)
            }
            try await body(fixture)
        } catch { problem = error }
        do { try await onChapterOwner(queue) { try FileManager.default.removeItem(at: root) } }
        catch { if problem == nil { problem = error } }
        if let problem { throw problem }
    }

    private func onChapterOwner<T: Sendable>(_ queue: DispatchQueue, _ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                let gate = ChapterOwnerQueueResult<T>()
                return try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        guard gate.attach(continuation) else { return }
                        queue.async {
                            guard !gate.isCancelled else { return }
                            gate.finish(Result { try operation() })
                        }
                    }
                } onCancel: { gate.cancel() }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5)) // Assertion deadline, not state settling.
                throw URLError(.timedOut)
            }
            return try await group.next()!
        }
    }

    private func withHostFixture(_ body: (HostFixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OwnerAdmission-\(UUID().uuidString)", isDirectory: true)
        let store = await Task.detached { BookStore(metadataFileURL: root.appendingPathComponent("books_meta.json"), legacyMetadataDefaults: nil) }.value
        let sourceID = UUID(), sourceURL = "https://owner-\(UUID().uuidString).invalid"
        let refs = (0..<2).map { OnlineChapterRef(index: $0, title: "Chapter \($0)", url: sourceURL + "/c\($0)") }
        var value = ReadingBook(title: "Owned admission", author: "Owned author", contentFilename: "")
        value.isOnline = true; value.isInBookshelf = false; value.bookSourceId = sourceID
        value.bookInfoURL = sourceURL + "/book"; value.tocURL = sourceURL + "/toc"; value.onlineChapters = refs
        store.saveReadingBook(value)
        await BookStore.queuedWritesLanded()
        let book = LegadoOriginalBook(bookURL: sourceURL + "/book", origin: sourceURL,
            name: value.title, author: value.author, tocURL: sourceURL + "/toc")
        let chapters = refs.map { ref in OriginalRuntimeBatchChapter(chapter: ref,
            generation: .init(bookID: value.id, chapter: ref, token: UUID()),
            dto: .init(bookURL: book.bookURL, url: ref.url, index: Int32(ref.index), title: ref.title, baseURL: book.tocURL)) }
        let host = LegadoPersistentStateHost(backing: AppLegadoOwnedStateBacking(sources: .shared, login: .shared))
        let probe = AdmissionProbe()
        await host.setContentBatchPreparationForTesting { task, owner in try await probe.holdBinding(task, owner: owner) }
        let fixture = HostFixture(host: host, probe: probe, store: store, bookID: value.id,
            sourceID: sourceID, sourceURL: sourceURL, book: book, chapters: chapters,
            cache: ChapterCacheRepository(rootDirectory: root.appendingPathComponent("cache", isDirectory: true)))
        var problem: Error?
        do { try await body(fixture) } catch { problem = error }
        await probe.releaseAll()
        for owner in await probe.boundOwners.values { await host.revoke(owner: owner) }
        await host.setContentBatchPreparationForTesting(nil)
        for chapter in chapters { chapter.generation.revoke() }
        await BookStore.queuedWritesLanded()
        do { try await Task.detached { try FileManager.default.removeItem(at: root) }.value }
        catch { if problem == nil { problem = error } }
        if let problem { throw problem }
    }

    private struct HostFixture {
        let host: LegadoPersistentStateHost
        let probe: AdmissionProbe
        let store: BookStore
        let bookID: UUID
        let sourceID: UUID
        let sourceURL: String
        let book: LegadoOriginalBook
        let chapters: [OriginalRuntimeBatchChapter]
        let cache: ChapterCacheRepository
        func start(_ task: String, index: Int) -> Task<String, Error> {
            Task {
                try await host.bindContentBatch(sourceURL: sourceURL, sourceRevision: "r1", taskID: task,
                    store: store, bookID: bookID, sourceID: sourceID, book: book, chapters: [chapters[index]],
                    deadline: Date().addingTimeInterval(10), cache: cache, singleChapter: true)
            }
        }
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

private final class ChapterOwnerQueueResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func attach(_ value: CheckedContinuation<Value, Error>) -> Bool {
        let accepted = lock.withLock { () -> Bool in
            guard !cancelled else { return false }
            continuation = value; return true
        }
        if !accepted { value.resume(throwing: CancellationError()) }
        return accepted
    }
    func finish(_ result: Result<Value, Error>) {
        let pending = lock.withLock { let value = continuation; continuation = nil; return value }
        pending?.resume(with: result)
    }
    func cancel() {
        let pending = lock.withLock { cancelled = true; let value = continuation; continuation = nil; return value }
        pending?.resume(throwing: CancellationError())
    }
}

private actor AdmissionProbe: LegadoOriginalContentBatchExecuting {
    private(set) var entries: [String] = []
    private(set) var peak = 0
    private(set) var staticURLFlags: [String: Bool] = [:]
    private(set) var boundOwners: [String: String] = [:]
    private var running = 0
    private struct Gate {
        let continuation: CheckedContinuation<Void, Error>
        let timer: Task<Void, Never>
    }
    private var gates: [String: Gate] = [:]
    private var observers: [UUID: (Int, Gate)] = [:]
    func execute(_ request: LegadoContentBatchExecutionRequest) async throws -> LegadoOriginalContentBatchResult {
        staticURLFlags[request.taskID] = request.staticHttpUrlsOnly
        try await hold(request.taskID)
        return .init(book: request.book, missingChapters: [])
    }
    func holdBinding(_ id: String, owner: String) async throws {
        boundOwners[id] = owner
        try await hold(id)
    }
    private func hold(_ id: String) async throws {
        entries.append(id); running += 1; peak = max(peak, running)
        defer { running -= 1 }
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
