import Foundation
import Testing
@testable import yuedu_app

@Suite("Network settings search", .serialized)
struct NetworkSettingsSearchTests {
    @Test("issue 32 source pack decodes into searchable sources")
    func issue32SourcePackDecodes() throws {
        let path = "/Users/zhangruilin/Desktop/Test document/RULE/a8adf570-e115-4b99-87e3-ccaf298ae361.json"
        guard FileManager.default.fileExists(atPath: path) else { return }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let sources = try JSONDecoder().decode([BookSource].self, from: data)

        #expect(sources.count == 459)
        #expect(sources.contains { !$0.searchUrl.isEmpty && !$0.ruleSearch.bookList.isEmpty })
    }

    @Test("large 11780 source pack decodes into enabled searchable sources")
    func large11780SourcePackDecodes() throws {
        let path = "/Users/zhangruilin/Desktop/Test document/RULE/11780_51b655a48db62802c20dcb56a8802d4d.json"
        guard FileManager.default.fileExists(atPath: path) else { return }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let sources = try JSONDecoder().decode([BookSource].self, from: data)

        #expect(sources.count == 1607)
        #expect(sources.filter(\.enabled).count == 1607)
        #expect(sources.contains { !$0.searchUrl.isEmpty && !$0.ruleSearch.bookList.isEmpty })
    }

    @Test("search cache reuses fresh results and remaps to current source identity")
    func searchCacheReusesFreshResults() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = SearchResultCache(directory: directory)
        var source = makeSource(name: "Original", url: "https://example.com/source")
        let oldSourceId = source.id
        let book = makeOnlineBook(name: "Issue32", source: source)

        cache.store(
            books: [book],
            query: "Issue32",
            source: source,
            days: 5,
            now: Date(timeIntervalSince1970: 1_000)
        )
        cache.waitForPendingWritesForTesting()

        source.id = UUID()
        source.bookSourceName = "Current"
        let cached = try #require(cache.freshBooks(
            query: "Issue32",
            source: source,
            days: 5,
            now: Date(timeIntervalSince1970: 1_000 + 60)
        ))

        #expect(cached.count == 1)
        #expect(cached[0].name == "Issue32")
        #expect(cached[0].sourceId == source.id)
        #expect(cached[0].sourceId != oldSourceId)
        #expect(cached[0].sourceName == "Current")
        #expect(cache.freshBooks(query: "Issue32", source: source, days: 0) == nil)
        #expect(cache.freshBooks(
            query: "Issue32",
            source: source,
            days: 5,
            now: Date(timeIntervalSince1970: 1_000 + 6 * 86_400)
        ) == nil)
    }

    @Test("auto pause policy follows exact and fuzzy thresholds")
    func autoPausePolicyThresholds() {
        let disabled = SearchAutoPausePolicy(count: 0)
        #expect(!disabled.shouldPause(exactCount: 100, fuzzyCount: 100))

        let policy = SearchAutoPausePolicy(count: 2)
        #expect(!policy.shouldPause(exactCount: 1, fuzzyCount: 9))
        #expect(policy.shouldPause(exactCount: 2, fuzzyCount: 0))
        #expect(policy.shouldPause(exactCount: 0, fuzzyCount: 10))
    }

    @Test("large source packs get a safety auto pause when unset")
    func largeSourcePackSafetyAutoPause() {
        #expect(NetworkSearchSettings.effectiveAutoPauseCount(
            configured: 0,
            sourceCount: NetworkSearchSettings.largeSourcePackThreshold - 1
        ) == 0)
        #expect(NetworkSearchSettings.effectiveAutoPauseCount(
            configured: 0,
            sourceCount: NetworkSearchSettings.largeSourcePackThreshold
        ) == NetworkSearchSettings.largeSourcePackAutoPauseCount)
        #expect(NetworkSearchSettings.effectiveAutoPauseCount(
            configured: 3,
            sourceCount: 1607
        ) == 3)
    }

    @Test("runtime template search sources get aggregate timeout budget")
    func runtimeTemplateSearchSourcesGetAggregateTimeoutBudget() {
        var runtimeSource = makeSource(name: "Runtime", url: "https://example.com/source")
        runtimeSource.jsLib = "const CONFIG = { api: { baseUrl: 'https://api.example.com' } };"
        runtimeSource.searchUrl = "{{CONFIG.api.baseUrl}}/search.php?keyword={{key}}&page={{page}}"

        var fastSource = makeSource(name: "Fast", url: "https://example.com/fast")
        fastSource.jsLib = "function noop() { return ''; }"
        fastSource.searchUrl = "https://example.com/search?q={{key}}&page={{page}}"

        #expect(BookSourceSearchFanOut.timeout(for: runtimeSource, normal: 12, aggregate: 30) == 30)
        #expect(BookSourceSearchFanOut.timeout(for: fastSource, normal: 12, aggregate: 30) == 12)
    }

    @MainActor
    @Test("reader source change attempts all enabled sources despite search auto pause")
    func changeSourceDoesNotAutoPause() async throws {
        let previousConcurrency = GlobalSettings.shared.searchConcurrency
        let previousAutoPauseCount = GlobalSettings.shared.searchAutoPauseCount
        let previousWarm = GlobalSettings.shared.changeSourceLoadToc
        let previousDays = GlobalSettings.shared.searchCacheDays
        defer {
            GlobalSettings.shared.searchConcurrency = previousConcurrency
            GlobalSettings.shared.searchAutoPauseCount = previousAutoPauseCount
            GlobalSettings.shared.changeSourceLoadToc = previousWarm
            GlobalSettings.shared.searchCacheDays = previousDays
        }
        GlobalSettings.shared.searchConcurrency = 1
        GlobalSettings.shared.changeSourceLoadToc = false
        GlobalSettings.shared.searchCacheDays = 5
        for pauseCount in [0, 1] {
            GlobalSettings.shared.searchAutoPauseCount = pauseCount
            let sources = (0..<301).map { makeSource(name: "Ordered \($0)", url: "https://example.com/source-\($0)") }
            var disabled = makeSource(name: "Disabled", url: "https://example.com/disabled")
            disabled.enabled = false
            let fetcher = CountingBookSourceFetcher()
            let viewModel = ReaderViewModel(chapterFetcher: NoopChapterFetcher(),
                bookCoordinator: NoopOnlineBookCoordinator(), bookSourceFetcher: fetcher)
            var book = ReadingBook(title: "Issue32", author: "Author", contentFilename: "")
            book.isOnline = true
            book.bookInfoURL = "https://example.com/current"
            defer { ChangeSourceCache.shared.clear(for: book.id) }
            if pauseCount == 0 {
                let legacy = sources.prefix(10).map { source in
                    BookOrigin(sourceId: source.id, sourceName: source.bookSourceName,
                        bookUrl: "\(source.bookSourceUrl)/book", tocUrl: "\(source.bookSourceUrl)/toc",
                        coverUrl: "", intro: "", lastChapter: "", wordCount: "", kind: "", runtimeVariables: nil)
                }
                ChangeSourceCache.shared.store(origins: legacy, for: book.id)
            }
            viewModel.loadOtherOrigins(book: book, currentSourceId: sources[0].id,
                enabledSources: sources + [disabled], store: BookStore(), forceRefresh: pauseCount != 0)
            await viewModel.waitForChangeSourceSearchForTesting()
            #expect(!viewModel.changeSourceLoading)
            #expect(viewModel.changeSourceOrigins.map(\.sourceId) == sources.map(\.id))
            #expect(fetcher.queriedSourceIDs == sources.map(\.id))
            let cached = try #require(ChangeSourceCache.shared.entry(for: book.id))
            #expect(cached.completedAttemptSourceIDs == Set(sources.map(\.id)))
            #expect(cached.scanCoverage?.completedAllAttempts == true)
            #expect(cached.scanCoverage?.attemptedSourceCount == 301)
        }
    }

    @MainActor
    @Test("complete reader cache follows reordered sources and adding a source starts a scan")
    func changeSourceCacheRespectsCurrentOrderAndCoverage() async throws {
        let previousConcurrency = GlobalSettings.shared.searchConcurrency
        let previousDays = GlobalSettings.shared.searchCacheDays
        let previousWarm = GlobalSettings.shared.changeSourceLoadToc
        defer {
            GlobalSettings.shared.searchConcurrency = previousConcurrency
            GlobalSettings.shared.searchCacheDays = previousDays
            GlobalSettings.shared.changeSourceLoadToc = previousWarm
        }
        GlobalSettings.shared.searchConcurrency = 2
        GlobalSettings.shared.searchCacheDays = 5
        GlobalSettings.shared.changeSourceLoadToc = false
        let sources = (0..<3).map { makeSource(name: "Order \($0)", url: "https://example.com/order-\($0)") }
        let fetcher = CountingBookSourceFetcher()
        let viewModel = ReaderViewModel(chapterFetcher: NoopChapterFetcher(),
            bookCoordinator: NoopOnlineBookCoordinator(), bookSourceFetcher: fetcher)
        let book = ReadingBook(title: "Cached", author: "Author", contentFilename: "")
        let currentSourceId = UUID()
        defer { ChangeSourceCache.shared.clear(for: book.id) }
        viewModel.loadOtherOrigins(book: book, currentSourceId: currentSourceId,
            enabledSources: Array(sources.prefix(2)), store: BookStore(), forceRefresh: true)
        await viewModel.waitForChangeSourceSearchForTesting()
        #expect(fetcher.searchCallCount == 2)
        viewModel.loadOtherOrigins(book: book, currentSourceId: currentSourceId,
            enabledSources: [sources[1], sources[0]], store: BookStore())
        await viewModel.waitForChangeSourceSearchForTesting()
        #expect(fetcher.searchCallCount == 2)
        #expect(viewModel.changeSourceOrigins.map(\.sourceId) == [sources[1].id, sources[0].id])
        viewModel.loadOtherOrigins(book: book, currentSourceId: currentSourceId,
            enabledSources: [sources[2], sources[1], sources[0]], store: BookStore())
        await viewModel.waitForChangeSourceSearchForTesting()
        #expect(fetcher.searchCallCount == 5)
        #expect(viewModel.changeSourceOrigins.map(\.sourceId) == [sources[2].id, sources[1].id, sources[0].id])
    }

    @MainActor
    @Test("a cancelled old source scan cannot replace the restarted scan or its complete cache")
    func changeSourceRestartRejectsLateOldResult() async throws {
        let previousDays = GlobalSettings.shared.searchCacheDays
        let previousWarm = GlobalSettings.shared.changeSourceLoadToc
        defer {
            GlobalSettings.shared.searchCacheDays = previousDays
            GlobalSettings.shared.changeSourceLoadToc = previousWarm
        }
        GlobalSettings.shared.searchCacheDays = 5
        GlobalSettings.shared.changeSourceLoadToc = false
        let oldSource = makeSource(name: "Old", url: "https://example.com/old")
        let newSource = makeSource(name: "New", url: "https://example.com/new")
        let gate = SourceSearchGate()
        let fetcher = CountingBookSourceFetcher(gate: gate, heldSourceId: oldSource.id)
        let viewModel = ReaderViewModel(chapterFetcher: NoopChapterFetcher(),
            bookCoordinator: NoopOnlineBookCoordinator(), bookSourceFetcher: fetcher)
        let book = ReadingBook(title: "Restart", author: "Author", contentFilename: "")
        defer { ChangeSourceCache.shared.clear(for: book.id) }
        let current = UUID()
        viewModel.loadOtherOrigins(book: book, currentSourceId: current,
            enabledSources: [oldSource], store: BookStore(), forceRefresh: true)
        guard let oldTask = viewModel.changeSourceSearchTaskForTesting() else { Issue.record("Missing old search task"); return }
        await gate.waitUntilHeld()
        viewModel.loadOtherOrigins(book: book, currentSourceId: current,
            enabledSources: [newSource], store: BookStore(), forceRefresh: true)
        await viewModel.waitForChangeSourceSearchForTesting()
        #expect(viewModel.changeSourceOrigins.map(\.sourceId) == [newSource.id])
        await gate.release()
        await oldTask.value
        #expect(viewModel.changeSourceOrigins.map(\.sourceId) == [newSource.id])
        #expect(ChangeSourceCache.shared.entry(for: book.id)?.completedAttemptSourceIDs == [newSource.id])
    }

    @MainActor
    @Test("stopping source search also cancels background TOC warm-up")
    func stoppingSearchCancelsTOCWarmup() async throws {
        let previousLoadTOC = GlobalSettings.shared.changeSourceLoadToc
        let previousCacheDays = GlobalSettings.shared.searchCacheDays
        let previousSources = BookSourceStore.shared.sources
        var book = ReadingBook(title: "Warm", author: "Author", contentFilename: "")
        book.isOnline = true
        let bookId = book.id
        defer {
            GlobalSettings.shared.changeSourceLoadToc = previousLoadTOC
            GlobalSettings.shared.searchCacheDays = previousCacheDays
            BookSourceStore.shared.sources = previousSources
            ChangeSourceCache.shared.clear(for: bookId)
        }

        GlobalSettings.shared.changeSourceLoadToc = true
        GlobalSettings.shared.searchCacheDays = 1
        let source = makeSource(name: "Warm", url: "https://example.com/warm")
        BookSourceStore.shared.sources = [source]
        let origin = BookOrigin(
            sourceId: source.id,
            sourceName: source.bookSourceName,
            bookUrl: "https://example.com/warm/book",
            tocUrl: "https://example.com/warm/toc",
            coverUrl: "",
            intro: "",
            lastChapter: "",
            wordCount: "",
            kind: "",
            runtimeVariables: nil
        )
        let currentSourceId = UUID()
        await ChangeSourceCache.shared.storeCompleted(origins: [origin], for: bookId,
            sourceIDs: [source.id], excludingOriginKey: ChangeSourceCache.originKey(sourceId: currentSourceId, bookUrl: book.bookInfoURL),
            coverage: BookOriginSearchCoverage(sourceCount: 1, completedAllAttempts: true, attemptedSourceCount: 1, resultSourceCount: 1))

        let fetcher = CancellableTOCFetcher()
        let viewModel = ReaderViewModel(
            chapterFetcher: NoopChapterFetcher(),
            bookCoordinator: NoopOnlineBookCoordinator(),
            bookSourceFetcher: fetcher
        )
        viewModel.loadOtherOrigins(
            book: book,
            currentSourceId: currentSourceId,
            enabledSources: [source],
            store: BookStore()
        )
        try await waitUntilAsync { await fetcher.didStartTOCRequest }

        viewModel.stopChangeSourceSearch()

        try await waitUntilAsync { await fetcher.didCancelTOCRequest }
        #expect(await fetcher.didCancelTOCRequest)
    }

    private func makeSource(name: String, url: String) -> BookSource {
        var source = BookSource()
        source.bookSourceName = name
        source.bookSourceUrl = url
        source.searchUrl = "/search?q={{key}}"
        source.ruleSearch.bookList = ".item"
        source.ruleSearch.name = ".title"
        source.ruleSearch.author = ".author"
        source.ruleSearch.bookUrl = "a@href"
        return source
    }

    private func makeOnlineBook(name: String, source: BookSource) -> OnlineBook {
        OnlineBook(
            name: name,
            author: "Author",
            intro: "",
            coverUrl: "",
            bookUrl: "\(source.bookSourceUrl)/book",
            tocUrl: "\(source.bookSourceUrl)/toc",
            wordCount: "",
            lastChapter: "",
            kind: "",
            sourceId: source.id,
            sourceName: source.bookSourceName
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchResultCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @MainActor @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("Timed out waiting for condition")
    }

    private func waitUntilAsync(
        timeout: TimeInterval = 2,
        condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("Timed out waiting for async condition")
    }
}

private actor CancellableTOCFetcher: BookSourceFetching {
    private(set) var didStartTOCRequest = false
    private(set) var didCancelTOCRequest = false

    nonisolated func fetchBookInfoPackage(
        url: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        knownBook: OnlineBook?
    ) async throws -> BookInfoPackage {
        throw NSError(domain: "CancellableTOCFetcher", code: 1)
    }

    nonisolated func fetchTOCPackage(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        onFirstPageReady: (([OnlineChapterRef]) -> Void)?,
        forceRefresh: Bool
    ) async throws -> TOCPackage {
        await markTOCStarted()
        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        } catch {
            if Task.isCancelled || error is CancellationError {
                await markTOCCancelled()
            }
            throw error
        }
        throw NSError(domain: "CancellableTOCFetcher", code: 2)
    }

    private func markTOCStarted() {
        didStartTOCRequest = true
    }

    private func markTOCCancelled() {
        didCancelTOCRequest = true
    }

    nonisolated func isChapterCached(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String?,
        expectedTOCTitle: String?
    ) -> Bool {
        false
    }

    nonisolated func clearChapterCache(bookId: UUID, chapterIndex: Int) {}
    nonisolated func clearAllChapterCache(bookId: UUID) {}
    nonisolated func search(query: String, in source: BookSource) async throws -> [OnlineBook] {
        []
    }

    nonisolated func loadChapterPackageSync(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String?,
        expectedTOCTitle: String?
    ) -> ChapterPackage? {
        nil
    }

    nonisolated func loadNormalizedChapterHTMLSync(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String?,
        expectedTOCTitle: String?
    ) -> String? {
        nil
    }
}

private final class CountingBookSourceFetcher: BookSourceFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var queried: [UUID] = []
    private let gate: SourceSearchGate?
    private let heldSourceId: UUID?

    init(gate: SourceSearchGate? = nil, heldSourceId: UUID? = nil) {
        self.gate = gate; self.heldSourceId = heldSourceId
    }

    var queriedSourceIDs: [UUID] { lock.withLock { queried } }

    var searchCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func fetchBookInfoPackage(
        url: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        knownBook: OnlineBook?
    ) async throws -> BookInfoPackage {
        throw NSError(domain: "CountingBookSourceFetcher", code: 1)
    }

    func fetchTOCPackage(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        onFirstPageReady: (([OnlineChapterRef]) -> Void)?,
        forceRefresh: Bool
    ) async throws -> TOCPackage {
        throw NSError(domain: "CountingBookSourceFetcher", code: 2)
    }

    func isChapterCached(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String?,
        expectedTOCTitle: String?
    ) -> Bool {
        false
    }

    func clearChapterCache(bookId: UUID, chapterIndex: Int) {}
    func clearAllChapterCache(bookId: UUID) {}

    func search(query: String, in source: BookSource) async throws -> [OnlineBook] {
        lock.withLock { calls += 1; queried.append(source.id) }
        if source.id == heldSourceId { await gate?.hold() }
        return [
            OnlineBook(
                name: query,
                author: "Author",
                intro: "",
                coverUrl: "",
                bookUrl: "\(source.bookSourceUrl)/book",
                tocUrl: "\(source.bookSourceUrl)/toc",
                wordCount: "",
                lastChapter: "",
                kind: "",
                sourceId: source.id,
                sourceName: source.bookSourceName
            )
        ]
    }

    func loadChapterPackageSync(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String?,
        expectedTOCTitle: String?
    ) -> ChapterPackage? {
        nil
    }

    func loadNormalizedChapterHTMLSync(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String?,
        expectedTOCTitle: String?
    ) -> String? {
        nil
    }
}

/// A controlled late reply, intentionally independent of cancellation so the
/// reader's generation barrier is exercised without sleeping for publication.
private actor SourceSearchGate {
    private var held = false
    private var released = false
    private var answer: CheckedContinuation<Void, Never>?
    private var started: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        held = true
        let waiters = started; started.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { answer = $0 }
    }
    func waitUntilHeld() async {
        guard !held else { return }
        await withCheckedContinuation { started.append($0) }
    }
    func release() {
        released = true
        let continuation = answer; answer = nil
        continuation?.resume()
    }
}

private struct NoopChapterFetcher: ChapterFetching {
    func isChapterCached(book: ReadingBook, chapterIndex: Int) async -> Bool { false }

    func fetchChapter(
        book: ReadingBook,
        chapterIndex: Int,
        priority: ChapterFetchPriority,
        store: BookStore?
    ) async throws -> ChapterPackage {
        throw NSError(domain: "NoopChapterFetcher", code: 1)
    }

    func cancelChapter(bookId: UUID, chapterIndex: Int) async {}
    func cancelAll(for bookId: UUID) async {}
}

private final class NoopOnlineBookCoordinator: OnlineBookCoordinating {
    func downloadBook(_ book: ReadingBook, store: BookStore?) {}
    func downloadBook(
        _ book: ReadingBook,
        store: BookStore?,
        startChapterIndex: Int,
        chapterCount: Int?
    ) {}
    func pauseDownload(book: ReadingBook, store: BookStore?) {}
    func prefetchAround(book: ReadingBook, center: Int, store: BookStore?) async {}
}
