import Combine
import CryptoKit
import Foundation
import LegadoRuntime
import Testing
@testable import yuedu_app

@Suite("Source picker respects the user's source order", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct BookSourceSearchOrderTests {
    @Test("source rank keeps channels and unknown sources stable without changing identities")
    func stableSourceOrder() async {
        let first = source("first"), second = source("second")
        let unknownA = source("unknown-a"), unknownB = source("unknown-b")
        let incoming = [origin(second, "1"), origin(unknownA, "1"), origin(first, "1"),
                        origin(second, "2"), origin(unknownB, "1"), origin(first, "2")]
        let facts = await Task.detached {
            let order = BookSourceSearchOrder(sources: [first, second, first])
            return (order.ordered(incoming).map(\.id), order.sourceIDs,
                    order.includes(unknownA.id), Thread.isMainThread)
        }.value
        #expect(facts.0 == [incoming[2], incoming[5], incoming[0], incoming[3], incoming[1], incoming[4]].map(\.id))
        #expect(facts.1 == [first.id, second.id])
        #expect(!facts.2)
        #expect(!facts.3)
    }

    @Test("a 50,000-source order index and result ordering stay in the worker")
    func largeOrderSnapshot() async {
        let facts = await Task.detached {
            var sources: [BookSource] = []
            sources.reserveCapacity(50_000)
            for _ in 0..<50_000 { sources.append(BookSource()) }
            let expected = sources.map(\.id)
            let incoming = sources.reversed().map { source in
                BookOrigin(sourceId: source.id, sourceName: "synthetic", bookUrl: "https://order.test/book",
                           tocUrl: "", coverUrl: "", intro: "", lastChapter: "", wordCount: "",
                           kind: "", runtimeVariables: nil)
            }
            let order = BookSourceSearchOrder(sources: sources)
            return (order.sourceIDs.count, order.ordered(incoming).map(\.sourceId) == expected,
                    Thread.isMainThread)
        }.value
        #expect(facts.0 == 50_000)
        #expect(facts.1)
        #expect(!facts.2)
    }

    @Test("a picker exhausts a 301-source cached pack with the large-pack pause setting unset")
    func largePackDoesNotSilentlyStopAtTen() async throws {
        let sources = (0..<301).map { source("pack-\($0)") }
        let site = try SourceOrderStubSite(sources: sources)
        let query = site.query
        let settings = GlobalSettings.shared
        let saved = (settings.searchConcurrency, settings.searchAutoPauseCount, settings.searchCacheDays)
        settings.searchConcurrency = 30
        settings.searchAutoPauseCount = 0
        settings.searchCacheDays = 1
        let cache = SearchResultCache.shared
        for source in sources {
            let book = OnlineBook(name: query, author: "Author", intro: "", coverUrl: "",
                                  bookUrl: source.bookSourceUrl + "/book", tocUrl: "", wordCount: "",
                                  lastChapter: "", kind: "", sourceId: source.id,
                                  sourceName: source.bookSourceName)
            cache.store(books: [book], query: query, source: source, days: 1)
        }
        cache.waitForPendingWritesForTesting()
        let aggregator = SearchAggregator(fetcher: site.fetcher)
        defer {
            aggregator.cancelAndClear()
            site.finish()
            for source in sources { cache.clear(query: query, source: source) }
            settings.searchConcurrency = saved.0
            settings.searchAutoPauseCount = saved.1
            settings.searchCacheDays = saved.2
        }
        aggregator.search(query: query, sources: sources, origin: .changeSource)
        await published(aggregator) { !$0.isSearching }
        #expect(!aggregator.isPaused)
        #expect(aggregator.progress.completed == 301)
        #expect(aggregator.results.first?.origins.map(\.sourceId) == sources.map(\.id))
        #expect(site.requestCounts.isEmpty, "the pack answers from cache; its owned executor is never called")
    }

    @Test("a late pinned source stays first; a picker asks cooled-down sources past the hit threshold")
    func latePrioritySourceIsNotCancelledOrOvertaken() async throws {
        let first = source("pinned"), second = source("ordinary")
        let site = try SourceOrderStubSite(sources: [first, second], heldSource: first.id)
        let settings = GlobalSettings.shared
        let saved = (settings.searchConcurrency, settings.searchAutoPauseCount, settings.searchCacheDays)
        settings.searchConcurrency = 2
        settings.searchAutoPauseCount = 1
        settings.searchCacheDays = 0
        let health = SourceHealthStore.shared
        for _ in 0..<3 { health.recordFailure(first.id) }
        let aggregator = SearchAggregator(fetcher: site.fetcher)
        defer {
            aggregator.cancelAndClear()
            site.finish()
            settings.searchConcurrency = saved.0
            settings.searchAutoPauseCount = saved.1
            settings.searchCacheDays = saved.2
        }

        aggregator.search(query: site.query, sources: [first, second], origin: .changeSource)
        await published(aggregator) { $0.results.first?.origins.contains { $0.sourceId == second.id } == true }
        #expect(aggregator.isSearching)
        #expect(!aggregator.isPaused)
        #expect(aggregator.progress.skipped == 0)
        site.releaseFirst()
        await published(aggregator) { !$0.isSearching }

        let result = aggregator.results.first
        #expect(result?.origins.map(\.sourceId) == [first.id, second.id])
        #expect(result?.origins.map(\.sourceName) == [first.bookSourceName, second.bookSourceName])
        #expect(aggregator.progress.completed == 2)
        #expect(site.requestCounts == [first.id: 1, second.id: 1])
        let origins = try #require(result?.origins)
        try #require(origins.count == 2)
        #expect(result?.contentKind(for: origins[0]) == .text)
        #expect(result?.contentKind(for: origins[1]) == .text)
        #expect(result?.detailIntro(for: origins[0]) == "pinned intro")
        #expect(result?.detailIntro(for: origins[1]) == "ordinary intro")

        // Native traditional execution admits text sources only. Exercise the
        // original audio presentation/alignment assertion through its legitimate
        // immutable cache boundary, after both uncached source calls completed.
        var audio = second
        audio.bookSourceType = 1
        let cache = SearchResultCache.shared
        settings.searchCacheDays = 1
        for source in [first, audio] {
            cache.store(books: [OnlineBook(name: site.query, author: "Author", intro: source.bookSourceName + " intro",
                coverUrl: "", bookUrl: source.bookSourceUrl + "/book", tocUrl: "", wordCount: "",
                lastChapter: "", kind: "", sourceId: source.id, sourceName: source.bookSourceName)],
                query: site.query, source: source, days: 1)
        }
        cache.waitForPendingWritesForTesting()
        let cached = SearchAggregator(fetcher: site.fetcher)
        defer {
            cached.cancelAndClear()
            for source in [first, audio] { cache.clear(query: site.query, source: source) }
        }
        cached.search(query: site.query, sources: [first, audio], origin: .changeSource)
        await published(cached) { !$0.isSearching }
        let presented = try #require(cached.results.first)
        let presentedOrigins = presented.origins
        #expect(presentedOrigins.map(\.sourceId) == [first.id, second.id])
        try #require(presentedOrigins.count == 2)
        #expect(presented.contentKind(for: presentedOrigins[0]) == .text)
        #expect(presented.contentKind(for: presentedOrigins[1]) == .audio)
        #expect(presented.detailIntro(for: presentedOrigins[0]) == "pinned intro")
        #expect(presented.detailIntro(for: presentedOrigins[1]) == "ordinary intro")
        #expect(site.requestCounts == [first.id: 1, second.id: 1], "cached audio presentation adds no native execution")
    }

    @Test("the search tab still skips cooldowns and pauses at its configured threshold")
    func searchTabRetainsItsPolicy() async throws {
        let cooled = source("cooled"), first = source("first"), remaining = source("remaining")
        let site = try SourceOrderStubSite(sources: [cooled, first, remaining])
        let settings = GlobalSettings.shared
        let saved = (settings.searchConcurrency, settings.searchAutoPauseCount, settings.searchCacheDays)
        settings.searchConcurrency = 1
        settings.searchAutoPauseCount = 1
        settings.searchCacheDays = 0
        for _ in 0..<3 { SourceHealthStore.shared.recordFailure(cooled.id) }
        let aggregator = SearchAggregator(fetcher: site.fetcher)
        defer {
            aggregator.cancelAndClear()
            site.finish()
            settings.searchConcurrency = saved.0
            settings.searchAutoPauseCount = saved.1
            settings.searchCacheDays = saved.2
        }

        aggregator.search(query: site.query, sources: [cooled, first, remaining], origin: .searchTab)
        await published(aggregator) { !$0.isSearching }
        #expect(aggregator.isPaused)
        #expect(aggregator.progress.skipped == 1)
        #expect(aggregator.results.first?.origins.map(\.sourceId) == [first.id])
        #expect(site.requestCounts == [first.id: 1])
    }

    @Test("the search tab keeps its original arrival order instead of the picker's rank")
    func searchTabKeepsArrivalOrder() async throws {
        let first = source("first"), second = source("second")
        let site = try SourceOrderStubSite(sources: [first, second], heldSource: first.id, allowsSecondPage: true)
        let settings = GlobalSettings.shared
        let saved = (settings.searchConcurrency, settings.searchAutoPauseCount, settings.searchCacheDays)
        settings.searchConcurrency = 2
        settings.searchAutoPauseCount = 0
        settings.searchCacheDays = 0
        let aggregator = SearchAggregator(fetcher: site.fetcher)
        defer {
            aggregator.cancelAndClear()
            site.finish()
            settings.searchConcurrency = saved.0
            settings.searchAutoPauseCount = saved.1
            settings.searchCacheDays = saved.2
        }
        aggregator.search(query: site.query, sources: [first, second], origin: .searchTab)
        await published(aggregator) { $0.results.first?.origins.first?.sourceId == second.id }
        site.releaseFirst()
        await published(aggregator) { !$0.isSearching }
        #expect(aggregator.results.first?.origins.map(\.sourceId) == [second.id, first.id])
        // The original DTO has no hasMore verdict. Search-tab paging therefore
        // asks page 2 once; its explicit empty answer terminates further rounds.
        #expect(site.firstPageRequestCounts == [first.id: 1, second.id: 1])
        #expect(site.secondPageRequestCounts == [first.id: 1, second.id: 1])
        #expect(site.requestCounts == [first.id: 2, second.id: 2])
    }

    @Test("an inactive picker publishes its ordered final snapshot only after becoming active")
    func sceneGateStillOwnsPublication() async throws {
        let first = source("first"), second = source("second")
        let site = try SourceOrderStubSite(sources: [first, second])
        let settings = GlobalSettings.shared
        let savedCacheDays = settings.searchCacheDays
        settings.searchCacheDays = 0
        let aggregator = SearchAggregator(fetcher: site.fetcher)
        defer {
            aggregator.cancelAndClear()
            site.finish()
            settings.searchCacheDays = savedCacheDays
        }
        aggregator.setResultPresentationActive(false)
        aggregator.search(query: site.query, sources: [first, second], origin: .changeSource)
        await published(aggregator) { !$0.isSearching }
        #expect(aggregator.results.isEmpty)
        aggregator.setResultPresentationActive(true)
        await published(aggregator) { $0.results.first?.origins.count == 2 }
        #expect(aggregator.results.first?.origins.map(\.sourceId) == [first.id, second.id])
        aggregator.cancelAndClear()
        #expect(aggregator.results.isEmpty)
    }

    private func published(_ aggregator: SearchAggregator,
                           until predicate: (SearchAggregator) -> Bool) async {
        // Subscribe before checking state. The sink owns unlimited demand and
        // the bounded stream coalesces bursts; the main-actor consumer reads
        // the actual state after each synchronous publication has finished.
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let subscription = aggregator.objectWillChange.sink { _ in continuation.yield(()) }
        defer {
            subscription.cancel()
            continuation.finish()
        }
        if predicate(aggregator) { return }
        for await _ in events {
            if predicate(aggregator) { return }
        }
    }

    private func source(_ name: String, type: Int = 0) -> BookSource {
        var source = BookSource()
        source.bookSourceName = name
        source.bookSourceUrl = "https://order-\(UUID().uuidString.lowercased()).test"
        source.bookSourceType = type
        source.searchUrl = source.bookSourceUrl + "/search?q={{key}}"
        source.ruleSearch.bookList = "li.book"
        source.ruleSearch.name = "a@text"
        source.ruleSearch.bookUrl = "a@href"
        source.ruleSearch.author = ".author@text"
        source.ruleSearch.intro = ".intro@text"
        source.ruleSearch.hasMoreRule = "@js:false"
        return source
    }

    private func origin(_ source: BookSource, _ channel: String) -> BookOrigin {
        BookOrigin(sourceId: source.id, sourceName: source.bookSourceName,
                   bookUrl: source.bookSourceUrl + "/" + channel, tocUrl: "", coverUrl: "",
                   intro: "", lastChapter: "", wordCount: "", kind: "", runtimeVariables: nil)
    }
}

/// Replace the native invocation boundary, not the unrelated WebFetcher.
/// Every unexpected route fails closed; the held pin needs explicit release.
@MainActor
private final class SourceOrderStubSite {
    let query = "order\(UUID().uuidString.prefix(8))"
    let fetcher: BookSourceFetcher
    private let executor: SourceOrderOwnedExecutor
    private let directory: URL
    private let session: URLSession

    init(sources: [BookSource], heldSource: UUID? = nil, allowsSecondPage: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("source-order-\(UUID())", isDirectory: true)
        executor = try SourceOrderOwnedExecutor(sources: sources, query: query,
            heldSource: heldSource, allowsSecondPage: allowsSecondPage)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SourceOrderRejectNetwork.self]
        session = URLSession(configuration: config)
        fetcher = BookSourceFetcher(webFetcher: WebFetcher(session: session), mainJSService:
            LegadoMainJSSourceService(executor: SourceOrderRejectMainJS(), contextDirectory: directory,
                originalExecutor: executor))
    }

    var requestCounts: [UUID: Int] { executor.requestCounts(page: nil) }
    var firstPageRequestCounts: [UUID: Int] { executor.requestCounts(page: 1) }
    var secondPageRequestCounts: [UUID: Int] { executor.requestCounts(page: 2) }
    func releaseFirst() { executor.release() }
    func finish() {
        executor.finish()
        session.invalidateAndCancel()
        if FileManager.default.fileExists(atPath: directory.path) {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record(error) }
        }
    }
}

private final class SourceOrderOwnedExecutor: LegadoOriginalPreviewExecuting, @unchecked Sendable {
    private struct Page {
        let sourceID: UUID
        let sourceBytes: Data
        let signature: String
        let book: LegadoOriginalBook
        var held: Bool
        var calls: [Int32: Int] = [:]
    }
    private struct Pending {
        let book: LegadoOriginalBook
        let continuation: CheckedContinuation<LegadoOriginalPreviewResult, Error>
    }
    private let lock = NSLock()
    private let query: String
    private let allowsSecondPage: Bool
    private var pages: [String: Page] = [:]
    private var pending: [UUID: Pending] = [:]
    private var closed = false

    init(sources: [BookSource], query: String, heldSource: UUID?, allowsSecondPage: Bool) throws {
        self.query = query
        self.allowsSecondPage = allowsSecondPage
        guard Set(sources.map(\.id)).count == sources.count,
              heldSource.map({ held in sources.contains { $0.id == held } }) ?? true else {
            throw LegadoRuntimeError(code: "INVALID_ARGUMENT", message: "Owned source-order registration lost its unique or held identity")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for source in sources {
            guard !source.isJsSource, source.bookSourceType == 0, !source.bookSourceUrl.isEmpty,
                  pages[source.bookSourceUrl] == nil else {
                throw LegadoRuntimeError(code: "INVALID_ARGUMENT", message: "Owned source-order execution requires unique traditional text sources")
            }
            var stable = source
            stable.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            stable.lastUpdateTime = 0; stable.respondTime = 180000
            let signature = SHA256.hash(data: try encoder.encode(stable)).map { String(format: "%02x", $0) }.joined()
            var book = LegadoOriginalBook(bookURL: source.bookSourceUrl + "/book", origin: source.bookSourceUrl,
                name: query, author: "Author")
            book.intro = source.bookSourceName + " intro"
            book.originName = source.bookSourceName
            pages[source.bookSourceUrl] = Page(sourceID: source.id, sourceBytes: try encoder.encode(source),
                signature: signature, book: book, held: source.id == heldSource)
        }
    }

    func execute(sourceJSON: String, sourceURL: String, sourceRevision: String,
                 grant: OriginalRuntimePreviewGrant?, operation: LegadoOriginalPreviewOperation,
                 deadline: Date) async throws -> LegadoOriginalPreviewResult {
        guard grant == nil, case .search(let key, let page) = operation, key == query,
              let page, page == 1 || (allowsSecondPage && page == 2), deadline.timeIntervalSinceNow > 0 else {
            throw LegadoRuntimeError(code: "INVALID_ARGUMENT", message: "Unexpected owned source-order operation")
        }
        try Task.checkCancellation()
        let ticket = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let immediate: Result<LegadoOriginalPreviewResult, Error>? = lock.withLock {
                    guard !closed, !Task.isCancelled else { return .failure(CancellationError()) }
                    guard let admitted = pages[sourceURL], admitted.sourceBytes == Data(sourceJSON.utf8),
                          admitted.signature == sourceRevision else {
                        return .failure(LegadoRuntimeError(code: "INVALID_STATE_OWNER", message: "Unregistered owned source-order identity"))
                    }
                    pages[sourceURL]?.calls[page, default: 0] += 1
                    if page == 2 { return .success(.search([])) }
                    if admitted.held {
                        pending[ticket] = Pending(book: admitted.book, continuation: continuation)
                        return nil
                    }
                    return .success(.search([admitted.book]))
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        }, onCancel: { self.cancel(ticket) })
    }

    func requestCounts(page: Int32?) -> [UUID: Int] {
        lock.withLock {
            Dictionary(uniqueKeysWithValues: pages.values.compactMap { entry in
                let count = page.map { entry.calls[$0] ?? 0 } ?? entry.calls.values.reduce(0, +)
                return count > 0 ? (entry.sourceID, count) : nil
            })
        }
    }

    func release() {
        let released = lock.withLock {
            for key in Array(pages.keys) { pages[key]?.held = false }
            let released = Array(pending.values)
            pending.removeAll()
            return released
        }
        for value in released { value.continuation.resume(returning: .search([value.book])) }
    }

    private func cancel(_ ticket: UUID) {
        let value = lock.withLock { pending.removeValue(forKey: ticket) }
        value?.continuation.resume(throwing: CancellationError())
    }

    func finish() {
        let cancelled = lock.withLock {
            closed = true
            let cancelled = Array(pending.values)
            pending.removeAll()
            return cancelled
        }
        for value in cancelled { value.continuation.resume(throwing: CancellationError()) }
    }
}

private struct SourceOrderRejectMainJS: LegadoMainJSExecuting {
    func createSession(sourceJSON: String) async throws -> String {
        throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY", message: "Unexpected mainJs route in original source-order fixture")
    }
    func execute(sessionID: String, operation: String, requestJSON: String) async throws -> String {
        throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY", message: "Unexpected mainJs execution in original source-order fixture")
    }
    func closeSession(id: String) async throws {
        throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY", message: "Unexpected mainJs session in original source-order fixture")
    }
}

private final class SourceOrderRejectNetwork: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }
    override func stopLoading() {}
}
