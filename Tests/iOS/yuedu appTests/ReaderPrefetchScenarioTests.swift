import Combine
import CryptoKit
import Foundation
import Testing
@testable import yuedu_app

#if DEBUG
/// A descriptive Debug-simulator measurement of the existing reader/fetch/HTTP queue.
/// No website, imported source, user book, timing wait, or replacement queue is involved.
/// The UI's current-ready gate is called explicitly; this is not a hosted ReaderView or
/// a tap-to-visible/startup/memory benchmark.
@MainActor
@Suite("Reader prefetch scenarios", .serialized, .timeLimit(.minutes(1)))
struct ReaderPrefetchScenarioTests {
    @Test("Ten distant jumps retain HTTP request order, queue peaks, cancellation and recovery",
          arguments: [20, 100])
    func tenDistantJumpsWithHeldResponses(chapterCount: Int) async throws {
        let fixture = PrefetchScenarioFixture(chapterCount: chapterCount)
        let events = PrefetchScenarioEvents()
        let responses = HeldChapterResponses(events: events)
        HeldChapterURLProtocol.install(responses, for: fixture.host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldChapterURLProtocol.self]
        configuration.httpMaximumConnectionsPerHost = Self.httpPermitLimit
        let session = URLSession(configuration: configuration)
        let fetcher = BookSourceFetcher(webFetcher: WebFetcher(session: session))
        let source = fixture.source
        let manager = ChapterFetchManager(
            bookSourceFetcher: fetcher,
            webViewFetcher: WebViewFetcher.shared,
            sourceResolver: { id in id == source.id ? source : nil }
        )
        let coordinator = OnlineBookCoordinator(
            bookSourceFetcher: fetcher,
            chapterFetchManager: manager,
            webViewFetcher: WebViewFetcher.shared
        )
        let model = ReaderViewModel(
            chapterFetcher: LiveChapterFetcher(chapterFetchManager: manager),
            bookCoordinator: coordinator,
            bookSourceFetcher: LiveBookSourceFetcher(bookSourceFetcher: fetcher)
        )
        let observation = model.$chapterStates.sink { states in
            events.recordReadyChapters(Set(states.compactMap { $0.value == .ready ? $0.key : nil }))
        }
        await PerHostSemaphore.shared.setDebugStateObserver(for: fixture.host) { state in
            events.recordHTTPState(
                active: Self.httpPermitLimit - (state.availablePermitCount ?? Self.httpPermitLimit),
                queued: state.queuedRequestCount
            )
        }

        do {
            try await runScenario(
                fixture: fixture, responses: responses, events: events,
                manager: manager, coordinator: coordinator, model: model
            )
        } catch {
            await cleanUp(fixture: fixture, manager: manager, session: session)
            observation.cancel()
            throw error
        }
        await cleanUp(fixture: fixture, manager: manager, session: session)
        observation.cancel()
    }

    nonisolated private static let httpPermitLimit = 16 // WebFetcher.fetchPage's existing backstop.

    private func runScenario(
        fixture: PrefetchScenarioFixture,
        responses: HeldChapterResponses,
        events: PrefetchScenarioEvents,
        manager: ChapterFetchManager,
        coordinator: OnlineBookCoordinator,
        model: ReaderViewModel
    ) async throws {
        var pending = Set<Int>()
        var completed = Set<Int>()
        var drainedToReachTarget: [Int] = []
        var checkpoints: [PrefetchScenarioCheckpoint] = []

        for (jump, target) in fixture.jumpTargets.enumerated() {
            // This calls the real chapter-entry/cache-validation path. Repeated targets
            // in the 20-chapter fixture intentionally exercise actual cache hits.
            await model.ensureChapterReady(
                book: fixture.book, chapterIndex: target, priority: .jump, store: nil
            )
            if !completed.contains(target) {
                pending.insert(target)
                var state = try await waitForHeldWork(pending.count, events: events)

                // A jump does not preempt sibling work. If it queues behind held HTTP
                // requests, release those real responses in their observed start order.
                // This is test-owned network progress, not a new product retry/scheduler.
                while !state.activeRequests.values.contains(target) {
                    let oldest = try #require(state.requestStartOrder.first {
                        state.activeRequests.values.contains($0)
                    })
                    try await complete(
                        oldest, fixture: fixture, responses: responses, manager: manager
                    )
                    pending.remove(oldest)
                    completed.insert(oldest)
                    drainedToReachTarget.append(oldest)
                    state = try await waitForHeldWork(pending.count, events: events)
                }
                try await complete(
                    target, fixture: fixture, responses: responses, manager: manager
                )
                pending.remove(target)
                completed.insert(target)
            }
            _ = try await events.wait { $0.readyChapters.contains(target) }
            #expect(model.isChapterContentAvailable(at: target))

            let center = try #require(ReaderChapterPresentation.adjacentPrefetchCenter(
                readyChapterIndex: target, currentChapterIndex: target
            ))
            #expect(ReaderChapterPresentation.adjacentPrefetchCenter(
                readyChapterIndex: (target + 1) % fixture.chapterCount,
                currentChapterIndex: target
            ) == nil)
            await coordinator.prefetchAround(book: fixture.book, center: center, store: nil)
            let neighbours = [center + 1, center + 2, center - 1, center - 2]
                .filter { (0..<fixture.chapterCount).contains($0) }
            pending.formUnion(neighbours.filter { !completed.contains($0) })
            let state = try await waitForHeldWork(pending.count, events: events)
            #expect(state.cancelledRequestOrder.isEmpty,
                    "distant jumps must not manufacture sibling cancellation")
            checkpoints.append(.init(
                jump: jump + 1, target: target,
                acquiredHTTPPermits: state.activeHTTPPermits,
                queuedHTTPRequests: state.queuedHTTPRequests,
                heldHTTPResponses: state.activeRequests.count,
                completedChapters: completed.count
            ))
        }

        let beforeCancellation = events.snapshot
        #expect(checkpoints.count == 10)
        #expect(beforeCancellation.peakActiveHTTPPermits == Self.httpPermitLimit)
        #expect(beforeCancellation.peakHeldHTTPResponses <= Self.httpPermitLimit)
        // Four disjoint five-chapter windows cover the 20-chapter book. The 100-chapter
        // fixture keeps reaching cold windows, proving that four per center is not a
        // global chapter-job cap. This records the existing FIFO policy, not a speedup.
        #expect(beforeCancellation.peakQueuedHTTPRequests == (fixture.chapterCount == 20 ? 0 : 4))
        #expect(Set(beforeCancellation.requestStartOrder).count == beforeCancellation.requestStartOrder.count)
        #expect(beforeCancellation.requestStartOrder.allSatisfy { (0..<fixture.chapterCount).contains($0) })

        // The reader's real close/book-change cancellation entry preserves downloads;
        // this scenario creates only reader work. Await actual stopLoading and permit/
        // waiter release signals before re-entering a cancelled neighbour.
        await model.cancelAll(for: fixture.book.id)
        let cancelled = try await waitForHeldWork(0, events: events)
        #expect(!cancelled.cancelledRequestOrder.isEmpty)
        #expect(Set(cancelled.cancelledRequestOrder).isSubset(of: pending))
        for chapter in pending {
            #expect(await manager.chapterState(bookId: fixture.book.id, chapterIndex: chapter) == .missing)
        }

        let recoveryTarget = try #require(pending.sorted().first)
        let requestsBeforeRecovery = cancelled.requestStartOrder.filter { $0 == recoveryTarget }.count
        model.resetAllChapterStates()
        await model.ensureChapterReady(
            book: fixture.book, chapterIndex: recoveryTarget, priority: .jump, store: nil
        )
        _ = try await waitForHeldWork(1, events: events)
        try await complete(
            recoveryTarget, fixture: fixture, responses: responses, manager: manager
        )
        let recovered = try await events.wait {
            $0.readyChapters.contains(recoveryTarget)
                && $0.activeHTTPPermits == 0 && $0.queuedHTTPRequests == 0
                && $0.activeRequests.isEmpty
        }
        #expect(model.isChapterContentAvailable(at: recoveryTarget))
        #expect(recovered.requestStartOrder.filter { $0 == recoveryTarget }.count == requestsBeforeRecovery + 1)
        #expect(await manager.chapterState(bookId: fixture.book.id, chapterIndex: recoveryTarget) == .cached)

        let result = PrefetchScenarioResult(
            schemaVersion: 1, fixtureChapterCount: fixture.chapterCount,
            bodyUTF8Bytes: PrefetchScenarioFixture.body.utf8.count,
            htmlSHA256: SHA256.hash(data: Data(PrefetchScenarioFixture.html.utf8))
                .map { String(format: "%02x", $0) }.joined(),
            httpPermitLimit: Self.httpPermitLimit, jumpTargets: fixture.jumpTargets,
            checkpoints: checkpoints,
            peakActiveHTTPPermits: recovered.peakActiveHTTPPermits,
            peakQueuedHTTPRequests: recovered.peakQueuedHTTPRequests,
            peakHeldHTTPResponses: recovered.peakHeldHTTPResponses,
            requestStartOrder: recovered.requestStartOrder,
            responseCompletionOrder: recovered.responseCompletionOrder,
            cancelledRequestOrder: recovered.cancelledRequestOrder,
            responsesDrainedToReachQueuedTargets: drainedToReachTarget,
            pendingChaptersAtCancellation: pending.sorted(),
            recoveredChapter: recoveryTarget,
            recoveredReady: model.chapterState(for: recoveryTarget) == .ready
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(result)
        print("READER_PREFETCH_SCENARIO " + String(decoding: data, as: UTF8.self))
    }

    private func waitForHeldWork(
        _ count: Int, events: PrefetchScenarioEvents
    ) async throws -> PrefetchScenarioEvents.Snapshot {
        try await events.wait {
            $0.activeHTTPPermits + $0.queuedHTTPRequests == count
                && $0.activeRequests.count == min(count, Self.httpPermitLimit)
        }
    }

    private func complete(
        _ chapter: Int,
        fixture: PrefetchScenarioFixture,
        responses: HeldChapterResponses,
        manager: ChapterFetchManager
    ) async throws {
        try #require(responses.complete(chapter: chapter, body: PrefetchScenarioFixture.html))
        // Join the real manager task so the response is parsed and persisted before it
        // counts as completed. This never changes the task's priority or creates a cache.
        let package = try await manager.fetchChapter(
            book: fixture.book, chapterIndex: chapter, priority: .immediate, store: nil
        )
        #expect(package.state == .cached)
        #expect(package.content.contains(PrefetchScenarioFixture.body))
    }

    private func cleanUp(
        fixture: PrefetchScenarioFixture, manager: ChapterFetchManager, session: URLSession
    ) async {
        await manager.cancelAll(for: fixture.book.id)
        session.invalidateAndCancel()
        // Success already awaited transport quiescence. A failing/cancelled test only
        // tears down owned work here; another wait could mask a leaked-permit regression
        // by defeating the suite time limit. Failure cleanup is therefore best effort.
        await PerHostSemaphore.shared.setDebugStateObserver(for: fixture.host, observer: nil)
        HeldChapterURLProtocol.uninstall(for: fixture.host)
        // The UUID book belongs only to this fixture; no imported source/store is touched.
        let bookId = fixture.book.id
        await Task.detached {
            BookSourceFetcher.chapterCacheRepository.clearAllChapterCache(bookId: bookId)
        }.value
    }
}

private struct PrefetchScenarioFixture {
    let chapterCount: Int
    let host: String
    let source: BookSource
    let book: ReadingBook
    let jumpTargets: [Int]

    init(chapterCount: Int) {
        self.chapterCount = chapterCount
        let host = "prefetch-\(UUID().uuidString.lowercased()).example.com"
        self.host = host
        var source = BookSource(bookSourceUrl: "https://\(host)", bookSourceName: "Owned prefetch fixture")
        source.ruleContent.content = "#content@text"
        self.source = source
        var book = ReadingBook(
            title: "Synthetic \(chapterCount)-chapter prefetch", author: "Fixture",
            source: source.bookSourceUrl, contentFilename: ""
        )
        book.isOnline = true
        book.bookSourceId = source.id
        book.onlineChapters = (0..<chapterCount).map {
            OnlineChapterRef(index: $0, title: "Chapter \($0)", url: "https://\(host)/chapter/\($0)")
        }
        self.book = book
        jumpTargets = chapterCount == 20
            ? [2, 17, 7, 12, 2, 17, 7, 12, 2, 17]
            : [2, 97, 12, 87, 22, 77, 32, 67, 42, 57]
    }

    static let body = String(repeating: "这是自有预取测量正文，章节响应由测试明确释放。", count: 12)
    static let html = "<html><body><div id='content'>\(body)</div></body></html>"
}

private struct PrefetchScenarioCheckpoint: Codable {
    let jump: Int
    let target: Int
    let acquiredHTTPPermits: Int
    let queuedHTTPRequests: Int
    let heldHTTPResponses: Int
    let completedChapters: Int
}

private struct PrefetchScenarioResult: Codable {
    let schemaVersion: Int
    let fixtureChapterCount: Int
    let bodyUTF8Bytes: Int
    let htmlSHA256: String
    let httpPermitLimit: Int
    let jumpTargets: [Int]
    let checkpoints: [PrefetchScenarioCheckpoint]
    let peakActiveHTTPPermits: Int
    let peakQueuedHTTPRequests: Int
    let peakHeldHTTPResponses: Int
    let requestStartOrder: [Int]
    let responseCompletionOrder: [Int]
    let cancelledRequestOrder: [Int]
    let responsesDrainedToReachQueuedTargets: [Int]
    let pendingChaptersAtCancellation: [Int]
    let recoveredChapter: Int
    let recoveredReady: Bool
}

/// Every await subscribes to actual state changes. A cancelled test terminates the stream;
/// there are no yield loops, guessed delays, or unbounded checked-continuation waiters.
private final class PrefetchScenarioEvents: @unchecked Sendable {
    struct Snapshot: Sendable {
        var activeHTTPPermits = 0
        var queuedHTTPRequests = 0
        var peakActiveHTTPPermits = 0
        var peakQueuedHTTPRequests = 0
        var peakHeldHTTPResponses = 0
        var activeRequests: [UUID: Int] = [:]
        var requestStartOrder: [Int] = []
        var responseCompletionOrder: [Int] = []
        var cancelledRequestOrder: [Int] = []
        var readyChapters: Set<Int> = []
    }

    private let lock = NSLock()
    private var state = Snapshot()
    private var observers: [UUID: AsyncStream<Snapshot>.Continuation] = [:]

    var snapshot: Snapshot { lock.withLock { state } }

    func recordHTTPState(active: Int, queued: Int) {
        update {
            $0.activeHTTPPermits = active
            $0.queuedHTTPRequests = queued
            $0.peakActiveHTTPPermits = max($0.peakActiveHTTPPermits, active)
            $0.peakQueuedHTTPRequests = max($0.peakQueuedHTTPRequests, queued)
        }
    }

    func recordStart(id: UUID, chapter: Int) {
        update {
            $0.activeRequests[id] = chapter
            $0.requestStartOrder.append(chapter)
            $0.peakHeldHTTPResponses = max($0.peakHeldHTTPResponses, $0.activeRequests.count)
        }
    }

    func recordEnd(id: UUID, chapter: Int, cancelled: Bool) {
        update {
            $0.activeRequests.removeValue(forKey: id)
            if cancelled { $0.cancelledRequestOrder.append(chapter) }
            else { $0.responseCompletionOrder.append(chapter) }
        }
    }

    func recordReadyChapters(_ chapters: Set<Int>) {
        update { $0.readyChapters = chapters }
    }

    func wait(until predicate: @Sendable (Snapshot) -> Bool) async throws -> Snapshot {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Snapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        lock.withLock {
            observers[id] = continuation
            continuation.yield(state)
        }
        defer {
            let removed = lock.withLock { observers.removeValue(forKey: id) }
            removed?.finish()
        }
        for await value in stream {
            try Task.checkCancellation()
            if predicate(value) { return value }
        }
        throw CancellationError()
    }

    private func update(_ change: (inout Snapshot) -> Void) {
        // Yield under the short lock to preserve ordering across URLProtocol and actor
        // callbacks. AsyncStream.yield does not run its consumer inline or block a thread.
        lock.withLock {
            change(&state)
            for observer in observers.values { observer.yield(state) }
        }
    }
}

/// The session's URLProtocol owns the responses, rather than bypassing WebFetcher,
/// BookSourceSession, source rules, cache persistence, or the real host semaphore.
private final class HeldChapterResponses: @unchecked Sendable {
    private let lock = NSLock()
    private let events: PrefetchScenarioEvents
    private var held: [UUID: (chapter: Int, request: HeldChapterURLProtocol)] = [:]

    init(events: PrefetchScenarioEvents) { self.events = events }

    func start(_ request: HeldChapterURLProtocol, chapter: Int) {
        lock.withLock {
            held[request.requestID] = (chapter, request)
            events.recordStart(id: request.requestID, chapter: chapter)
        }
    }

    func stop(_ request: HeldChapterURLProtocol) {
        lock.withLock {
            guard let entry = held.removeValue(forKey: request.requestID) else { return }
            events.recordEnd(id: request.requestID, chapter: entry.chapter, cancelled: true)
        }
    }

    func complete(chapter: Int, body: String) -> Bool {
        let entry = lock.withLock { () -> (UUID, HeldChapterURLProtocol)? in
            guard let pair = held.first(where: { $0.value.chapter == chapter }) else { return nil }
            held.removeValue(forKey: pair.key)
            events.recordEnd(id: pair.key, chapter: chapter, cancelled: false)
            return (pair.key, pair.value.request)
        }
        guard let (_, request) = entry, let url = request.request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                  headerFields: ["Content-Type": "text/html; charset=utf-8"]) else { return false }
        request.client?.urlProtocol(request, didReceive: response, cacheStoragePolicy: .notAllowed)
        request.client?.urlProtocol(request, didLoad: Data(body.utf8))
        request.client?.urlProtocolDidFinishLoading(request)
        return true
    }
}

private final class HeldChapterURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var controllers: [String: HeldChapterResponses] = [:]
    let requestID = UUID()
    private let lifecycleLock = NSLock()
    private var controller: HeldChapterResponses?
    private var stopped = false

    static func install(_ controller: HeldChapterResponses, for host: String) {
        lock.withLock { controllers[host] = controller }
    }

    static func uninstall(for host: String) {
        _ = lock.withLock { controllers.removeValue(forKey: host) }
    }

    // This class is installed only on the fixture's ephemeral session. Reject a request
    // without an owned controller below, so even an unexpected URL cannot reach a site.
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let chapter = Int(url.lastPathComponent),
              let host = url.host, let controller = Self.lock.withLock({ Self.controllers[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        lifecycleLock.withLock {
            guard !stopped else { return }
            self.controller = controller
            controller.start(self, chapter: chapter)
        }
    }

    override func stopLoading() {
        lifecycleLock.withLock {
            stopped = true
            controller?.stop(self)
        }
    }
}
#endif
