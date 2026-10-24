import Combine
import Foundation
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
    func largePackDoesNotSilentlyStopAtTen() async {
        let sources = (0..<301).map { source("pack-\($0)") }
        let site = SourceOrderStubSite(sources: sources)
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
        _ = await aggregator.$isSearching.values.first { !$0 }
        #expect(!aggregator.isPaused)
        #expect(aggregator.progress.completed == 301)
        #expect(aggregator.results.first?.origins.map(\.sourceId) == sources.map(\.id))
        #expect(site.requestCounts.isEmpty, "the pack answers from cache; its injected protocol never leaves the test")
    }

    @Test("a late pinned source stays first; a picker asks cooled-down sources past the hit threshold")
    func latePrioritySourceIsNotCancelledOrOvertaken() async {
        let first = source("pinned"), second = source("ordinary", type: 1)
        let site = SourceOrderStubSite(sources: [first, second], heldSource: first.id)
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
        _ = await aggregator.$isSearching.values.first { !$0 }

        let result = aggregator.results.first
        #expect(result?.origins.map(\.sourceId) == [first.id, second.id])
        #expect(result?.origins.map(\.sourceName) == [first.bookSourceName, second.bookSourceName])
        #expect(aggregator.progress.completed == 2)
        #expect(site.requestCounts == [first.id: 1, second.id: 1])
        if let origins = result?.origins, origins.count == 2 {
            #expect(result?.contentKind(for: origins[0]) == .text)
            #expect(result?.contentKind(for: origins[1]) == .audio)
            #expect(result?.detailIntro(for: origins[0]) == "pinned intro")
            #expect(result?.detailIntro(for: origins[1]) == "ordinary intro")
        }
    }

    @Test("the search tab still skips cooldowns and pauses at its configured threshold")
    func searchTabRetainsItsPolicy() async {
        let cooled = source("cooled"), first = source("first"), remaining = source("remaining")
        let site = SourceOrderStubSite(sources: [cooled, first, remaining])
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
        _ = await aggregator.$isSearching.values.first { !$0 }
        #expect(aggregator.isPaused)
        #expect(aggregator.progress.skipped == 1)
        #expect(aggregator.results.first?.origins.map(\.sourceId) == [first.id])
        #expect(site.requestCounts == [first.id: 1])
    }

    @Test("the search tab keeps its original arrival order instead of the picker's rank")
    func searchTabKeepsArrivalOrder() async {
        let first = source("first"), second = source("second")
        let site = SourceOrderStubSite(sources: [first, second], heldSource: first.id)
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
        _ = await aggregator.$isSearching.values.first { !$0 }
        #expect(aggregator.results.first?.origins.map(\.sourceId) == [second.id, first.id])
        #expect(site.requestCounts == [first.id: 1, second.id: 1])
    }

    @Test("an inactive picker publishes its ordered final snapshot only after becoming active")
    func sceneGateStillOwnsPublication() async {
        let first = source("first"), second = source("second")
        let site = SourceOrderStubSite(sources: [first, second])
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
        _ = await aggregator.$isSearching.values.first { !$0 }
        #expect(aggregator.results.isEmpty)
        aggregator.setResultPresentationActive(true)
        await published(aggregator) { $0.results.first?.origins.count == 2 }
        #expect(aggregator.results.first?.origins.map(\.sourceId) == [first.id, second.id])
        aggregator.cancelAndClear()
        #expect(aggregator.results.isEmpty)
    }

    private func published(_ aggregator: SearchAggregator,
                           until predicate: (SearchAggregator) -> Bool) async {
        if predicate(aggregator) { return }
        // The observable event wakes this main-actor consumer after the synchronous
        // assignment. No timer or network timing is used to decide when to release a source.
        for await _ in aggregator.objectWillChange.values {
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

/// Every URL is handled by the injected protocol. The pinned response is explicitly
/// released only after the ordinary source's result has reached the picker.
@MainActor
private final class SourceOrderStubSite {
    let query = "order\(UUID().uuidString.prefix(8))"
    let fetcher: BookSourceFetcher
    private let sources: [BookSource]
    private let session: URLSession

    init(sources: [BookSource], heldSource: UUID? = nil) {
        self.sources = sources
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SourceOrderURLProtocol.self]
        session = URLSession(configuration: config)
        fetcher = BookSourceFetcher(webFetcher: WebFetcher(session: session))
        for source in sources {
            SourceOrderURLProtocol.register(source: source, title: query, held: source.id == heldSource)
        }
    }

    var requestCounts: [UUID: Int] { SourceOrderURLProtocol.requestCounts(for: sources) }
    func releaseFirst() { for source in sources { SourceOrderURLProtocol.release(source) } }
    func finish() {
        session.invalidateAndCancel()
        for source in sources { SourceOrderURLProtocol.remove(source) }
    }
}

private final class SourceOrderURLProtocol: URLProtocol {
    private struct Page {
        let sourceID: UUID
        let title: String
        let intro: String
        var held: Bool
        var requests = 0
        var pending: SourceOrderURLProtocol?
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pages: [String: Page] = [:]

    static func register(source: BookSource, title: String, held: Bool) {
        lock.withLock { pages[URL(string: source.bookSourceUrl)!.host!] = Page(
            sourceID: source.id, title: title, intro: source.bookSourceName + " intro", held: held) }
    }

    static func requestCounts(for sources: [BookSource]) -> [UUID: Int] {
        lock.withLock {
            var result: [UUID: Int] = [:]
            for source in sources {
                if let page = pages[URL(string: source.bookSourceUrl)!.host!], page.requests > 0 {
                    result[page.sourceID] = page.requests
                }
            }
            return result
        }
    }

    static func release(_ source: BookSource) {
        let pending: (SourceOrderURLProtocol, Page)? = lock.withLock {
            let host = URL(string: source.bookSourceUrl)!.host!
            pages[host]?.held = false
            guard let page = pages[host], let request = page.pending else { return nil }
            pages[host]?.pending = nil
            return (request, page)
        }
        if let (request, page) = pending { request.respond(page) }
    }

    static func remove(_ source: BookSource) {
        lock.withLock { _ = pages.removeValue(forKey: URL(string: source.bookSourceUrl)!.host!) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let host = request.url?.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let reply: (page: Page?, registered: Bool) = Self.lock.withLock {
            guard Self.pages[host] != nil else { return (nil, false) }
            Self.pages[host]?.requests += 1
            if Self.pages[host]?.held == true {
                Self.pages[host]?.pending = self
                return (nil, true)
            }
            return (Self.pages[host], true)
        }
        if let page = reply.page { respond(page) }
        else if !reply.registered { client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost)) }
    }

    override func stopLoading() {
        guard let host = request.url?.host else { return }
        Self.lock.withLock {
            if Self.pages[host]?.pending === self { Self.pages[host]?.pending = nil }
        }
    }

    private func respond(_ page: Page) {
        let body = Data("<html><li class='book'><a href='/book'>\(page.title)</a><span class='author'>Author</span><span class='intro'>\(page.intro)</span></li></html>".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
