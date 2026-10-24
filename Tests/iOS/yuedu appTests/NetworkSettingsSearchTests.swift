import CryptoKit
import Foundation
import LegadoRuntime
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
    @Test("complete reader cache is bound to ordered configuration and adding a source starts a scan")
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
        #expect(fetcher.searchCallCount == 4)
        #expect(viewModel.changeSourceOrigins.map(\.sourceId) == [sources[1].id, sources[0].id])
        viewModel.loadOtherOrigins(book: book, currentSourceId: currentSourceId,
            enabledSources: [sources[2], sources[1], sources[0]], store: BookStore())
        await viewModel.waitForChangeSourceSearchForTesting()
        #expect(fetcher.searchCallCount == 7)
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
    @Test("immediate reopen displays partial origins and queries only unfinished sources without awaiting old network")
    func changeSourceReopensPartialAndResumesRemainingOnly() async throws {
        let previousDays = GlobalSettings.shared.searchCacheDays
        let previousConcurrency = GlobalSettings.shared.searchConcurrency
        let previousWarm = GlobalSettings.shared.changeSourceLoadToc
        defer {
            GlobalSettings.shared.searchCacheDays = previousDays
            GlobalSettings.shared.searchConcurrency = previousConcurrency
            GlobalSettings.shared.changeSourceLoadToc = previousWarm
        }
        GlobalSettings.shared.searchCacheDays = 5
        GlobalSettings.shared.searchConcurrency = 1
        GlobalSettings.shared.changeSourceLoadToc = false
        let sources = (0..<3).map { makeSource(name: "Resume \($0)", url: "https://resume-\(UUID()).invalid/\($0)") }
        let oldGate = SourceSearchGate(), resumedGate = SourceSearchGate()
        defer { Task { await oldGate.release(); await resumedGate.release() } }
        let fetcher = CountingBookSourceFetcher(gate: oldGate, heldSourceId: sources[1].id, resumedGate: resumedGate)
        let viewModel = ReaderViewModel(chapterFetcher: NoopChapterFetcher(),
            bookCoordinator: NoopOnlineBookCoordinator(), bookSourceFetcher: fetcher)
        let book = ReadingBook(title: "Owned resume", author: "Author", contentFilename: "")
        let current = UUID()
        defer { ChangeSourceCache.shared.clear(for: book.id) }
        viewModel.loadOtherOrigins(book: book, currentSourceId: current, enabledSources: sources, store: BookStore())
        let oldTask = try #require(viewModel.changeSourceSearchTaskForTesting())
        await oldGate.waitUntilHeld()
        #expect(viewModel.changeSourceOrigins.map(\.sourceId) == [sources[0].id])
        viewModel.stopChangeSourceSearch()
        viewModel.loadOtherOrigins(book: book, currentSourceId: current, enabledSources: sources, store: BookStore())
        await resumedGate.waitUntilHeld()
        #expect(viewModel.changeSourceOrigins.map(\.sourceId) == [sources[0].id])
        #expect(viewModel.changeSourceLoading, "partial display must not finish the resumed search")
        let partial = try #require(ChangeSourceCache.shared.entry(for: book.id))
        #expect(partial.acceptedAttempts == [sources[0].id: .results])
        #expect(partial.scanCoverage?.completedAllAttempts == false)
        #expect(partial.completedAttemptSourceIDs == nil)
        await resumedGate.release()
        await viewModel.waitForChangeSourceSearchForTesting()
        #expect(!viewModel.changeSourceLoading)
        #expect(viewModel.changeSourceOrigins.map(\.sourceId) == sources.map(\.id))
        #expect(fetcher.queriedSourceIDs == [sources[0].id, sources[1].id, sources[1].id, sources[2].id])
        #expect(fetcher.cacheBypassFlags == [true, true, true, true])
        #expect(ChangeSourceCache.shared.entry(for: book.id)?.scanCoverage?.attemptedSourceCount == 3)
        // The old, cancellation-ignoring request is still held. Releasing it
        // cannot publish or replace the resumed complete cache.
        await oldGate.release()
        await oldTask.value
        #expect(viewModel.changeSourceOrigins.map(\.sourceId) == sources.map(\.id))
        #expect(ChangeSourceCache.shared.entry(for: book.id)?.completedAttemptSourceIDs == Set(sources.map(\.id)))
        viewModel.loadOtherOrigins(book: book, currentSourceId: current, enabledSources: sources,
            store: BookStore(), forceRefresh: true)
        await viewModel.waitForChangeSourceSearchForTesting()
        #expect(fetcher.searchCallCount == 7, "manual refresh queries all three sources again")
    }

    @MainActor
    @Test("manual partial refresh and disabled caching both query every source on reopen")
    func changeSourceRefreshAndDisabledCacheDoNotResumePartial() async throws {
        let previousDays = GlobalSettings.shared.searchCacheDays
        let previousConcurrency = GlobalSettings.shared.searchConcurrency
        let previousWarm = GlobalSettings.shared.changeSourceLoadToc
        defer {
            GlobalSettings.shared.searchCacheDays = previousDays
            GlobalSettings.shared.searchConcurrency = previousConcurrency
            GlobalSettings.shared.changeSourceLoadToc = previousWarm
        }
        GlobalSettings.shared.searchConcurrency = 1
        GlobalSettings.shared.changeSourceLoadToc = false
        for days in [5, 0] {
            GlobalSettings.shared.searchCacheDays = days
            let sources = (0..<2).map { makeSource(name: "Refresh \($0)", url: "https://refresh-\(UUID()).invalid/\($0)") }
            let oldGate = SourceSearchGate()
            defer { Task { await oldGate.release() } }
            let fetcher = CountingBookSourceFetcher(gate: oldGate, heldSourceId: sources[1].id)
            let viewModel = ReaderViewModel(chapterFetcher: NoopChapterFetcher(),
                bookCoordinator: NoopOnlineBookCoordinator(), bookSourceFetcher: fetcher)
            let book = ReadingBook(title: "Owned refresh", author: "Author", contentFilename: "")
            defer { ChangeSourceCache.shared.clear(for: book.id) }
            let current = UUID()
            viewModel.loadOtherOrigins(book: book, currentSourceId: current, enabledSources: sources, store: BookStore())
            let oldTask = try #require(viewModel.changeSourceSearchTaskForTesting())
            await oldGate.waitUntilHeld()
            viewModel.stopChangeSourceSearch()
            viewModel.loadOtherOrigins(book: book, currentSourceId: current, enabledSources: sources,
                store: BookStore(), forceRefresh: days > 0)
            await viewModel.waitForChangeSourceSearchForTesting()
            #expect(fetcher.queriedSourceIDs == [sources[0].id, sources[1].id, sources[0].id, sources[1].id])
            #expect(viewModel.changeSourceOrigins.map(\.sourceId) == sources.map(\.id))
            #expect(!viewModel.changeSourceLoading)
            if days == 0 { #expect(ChangeSourceCache.shared.entry(for: book.id) == nil) }
            await oldGate.release()
            await oldTask.value
        }
    }

    @MainActor
    @Test("source-change bypass crosses the original executor and cached preview references retain their identity fence")
    func sourceChangeBypassesGeneralCacheAndPreservesPreviewFence() async throws {
        let previousDays = GlobalSettings.shared.searchCacheDays
        GlobalSettings.shared.searchCacheDays = 5
        defer { GlobalSettings.shared.searchCacheDays = previousDays }
        let query = "owned-bypass-\(UUID())"
        var source = makeSource(name: "Owned bypass", url: "https://bypass-\(UUID()).invalid")
        source.lastUpdateTime = 1
        let directory = try makeTemporaryDirectory()
        let executor = SourceChangeCacheOwnedExecutor(query: query)
        let service = LegadoMainJSSourceService(contextDirectory: directory, originalExecutor: executor)
        let live = LiveBookSourceFetcher(bookSourceFetcher: BookSourceFetcher(mainJSService: service))
        defer {
            SearchResultCache.shared.clear(query: query, source: source)
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
        let first = try #require(try await live.searchOutcome(query: query, in: source,
            earlyFilter: nil, bypassCache: true).books.first)
        let originalVariables = try #require(first.runtimeVariables)
        SearchResultCache.shared.store(books: [first], query: query, source: source, days: 5)
        SearchResultCache.shared.waitForPendingWritesForTesting()
        var changed = source
        changed.ruleToc.chapterList = ".changed-owned-toc"
        // The general cache key does not include this TOC rule. Demonstrate the
        // real cache hit before asserting that source-change bypass avoids it.
        let general = try await live.searchOutcome(query: query, in: changed, earlyFilter: nil)
        #expect(general.books.first?.runtimeVariables == originalVariables)
        #expect(await executor.callCount() == 1)
        let fresh = try #require(try await live.searchOutcome(query: query, in: changed,
            earlyFilter: { _, _ in true }, bypassCache: true).books.first)
        #expect(await executor.callCount() == 2)
        #expect(fresh.runtimeVariables != originalVariables)
        let cache = ChangeSourceCache(directory: directory.appendingPathComponent("reader-cache"))
        let context = try await Task.detached {
            try ChangeSourceCache.SearchContext.make(title: query, author: "Author", sources: [source],
                excludingOriginKey: "current")
        }.value
        let cachedOrigin = BookOrigin(sourceId: source.id, sourceName: source.bookSourceName,
            bookUrl: first.bookUrl, tocUrl: first.tocUrl, coverUrl: "", intro: "", lastChapter: "", wordCount: "", kind: "",
            runtimeVariables: originalVariables)
        let bookId = UUID(), timestamp = Date()
        await cache.storePartial(origins: [cachedOrigin], for: bookId, sourceIDs: [source.id],
            excludingOriginKey: "current", context: context, acceptedAttempts: [source.id: .results], timestamp: timestamp)
        let snapshot = await cache.readForSearch(for: bookId, days: 5, sourceIDs: [source.id],
            excludingOriginKey: "current", allowCached: true, context: context, now: timestamp)
        let restored = try #require(snapshot.displayOrigins.first)
        #expect(restored.runtimeVariables == originalVariables)
        #expect(!snapshot.canEndSearch)
        do {
            _ = try await service.originalDetails(url: restored.bookUrl, source: changed,
                runtimeVariables: restored.runtimeVariables, knownBook: first)
            Issue.record("A cached reference must not cross the changed source signature")
        } catch let error as LegadoRuntimeError {
            #expect(error.code == "CONTEXT_MISMATCH")
        }
        #expect(await executor.callCount() == 2, "identity failure cannot call another executor route")
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
        let excluded = ChangeSourceCache.originKey(sourceId: currentSourceId, bookUrl: book.bookInfoURL)
        let context = try await Task.detached {
            try ChangeSourceCache.SearchContext.make(title: "Warm", author: "Author", sources: [source],
                excludingOriginKey: excluded)
        }.value
        await ChangeSourceCache.shared.storeCompleted(origins: [origin], for: bookId,
            sourceIDs: [source.id], excludingOriginKey: excluded,
            coverage: BookOriginSearchCoverage(sourceCount: 1, completedAllAttempts: true, attemptedSourceCount: 1, resultSourceCount: 1),
            context: context, acceptedAttempts: [source.id: .results])

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
    private let resumedGate: SourceSearchGate?
    private var callsBySource: [UUID: Int] = [:]
    private var bypassFlags: [Bool] = []

    init(gate: SourceSearchGate? = nil, heldSourceId: UUID? = nil, resumedGate: SourceSearchGate? = nil) {
        self.gate = gate; self.heldSourceId = heldSourceId
        self.resumedGate = resumedGate
    }

    var queriedSourceIDs: [UUID] { lock.withLock { queried } }
    var cacheBypassFlags: [Bool] { lock.withLock { bypassFlags } }

    func searchOutcome(query: String, in source: BookSource,
        earlyFilter: ((_ name: String, _ author: String) -> Bool)?, bypassCache: Bool) async throws -> BookSourceSearchOutcome {
        lock.withLock { bypassFlags.append(bypassCache) }
        return BookSourceSearchOutcome(books: try await search(query: query, in: source, earlyFilter: earlyFilter))
    }

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
        let occurrence = lock.withLock {
            calls += 1; queried.append(source.id)
            callsBySource[source.id, default: 0] += 1
            return callsBySource[source.id]!
        }
        if source.id == heldSourceId {
            if occurrence == 1 { await gate?.hold() }
            else { await resumedGate?.hold() }
        }
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

/// Only the native invocation is replaced; the real original-search record and
/// preview identity path still produce and validate the cached reference.
private actor SourceChangeCacheOwnedExecutor: LegadoOriginalPreviewExecuting {
    private let query: String
    private var calls = 0
    init(query: String) { self.query = query }
    func execute(sourceJSON: String, sourceURL: String, sourceRevision: String,
        grant: OriginalRuntimePreviewGrant?, operation: LegadoOriginalPreviewOperation,
        deadline: Date) async throws -> LegadoOriginalPreviewResult {
        try Task.checkCancellation()
        let source = try JSONDecoder().decode(BookSource.self, from: Data(sourceJSON.utf8))
        var stable = source
        stable.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        stable.lastUpdateTime = 0; stable.respondTime = 180000
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let expected = SHA256.hash(data: try encoder.encode(stable)).map { String(format: "%02x", $0) }.joined()
        guard grant == nil, !source.isJsSource, source.bookSourceType == 0, source.bookSourceUrl == sourceURL,
              expected == sourceRevision, case .search(let key, let page) = operation, key == query, page == 1,
              deadline.timeIntervalSinceNow > 0 else {
            throw LegadoRuntimeError(code: "INVALID_ARGUMENT", message: "Unexpected owned cache-bypass invocation")
        }
        calls += 1
        return .search([LegadoOriginalBook(bookURL: sourceURL + "/book", origin: sourceURL, name: query, author: "Author")])
    }
    func callCount() -> Int { calls }
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
