import Foundation
import Testing
@testable import yuedu_app

@Suite("Reader source candidate reuse", .serialized)
@MainActor
struct ReaderSourceChangeCacheTests {
    @Test("switching A to B reuses every cached candidate and manual refresh still searches again")
    func completeCandidatesSurviveSourceSwitchAndManualRefresh() async throws {
        let saved = configureSettings()
        defer { restoreSettings(saved) }
        let sources = makeSources(2)
        let probe = CandidateSearchProbe()
        let fetcher = CandidateSearchFetcher(probe: probe)
        let first = makeModel(fetcher)
        let reopened = makeModel(fetcher)
        var book = ReadingBook(title: "Owned candidate reuse", author: "Author", contentFilename: "")
        book.bookInfoURL = sources[0].bookSourceUrl + "/book"
        defer {
            first.stopChangeSourceSearch()
            reopened.stopChangeSourceSearch()
            ChangeSourceCache.shared.clear(for: book.id)
        }

        first.loadOtherOrigins(book: book, currentSourceId: sources[0].id,
            enabledSources: sources, store: BookStore())
        try await finish(first)
        #expect(first.changeSourceOrigins.map(\.sourceId) == [sources[1].id])
        #expect(await probe.sourceIDs() == sources.map(\.id))
        let cached = try #require(ChangeSourceCache.shared.entry(for: book.id))
        #expect(cached.origins.map(\.sourceId) == sources.map(\.id), "the hidden active A must be persisted too")

        // Same book ID/title/author/configuration, now reading B in a new reader.
        book.bookInfoURL = sources[1].bookSourceUrl + "/book"
        reopened.loadOtherOrigins(book: book, currentSourceId: sources[1].id,
            enabledSources: sources, store: BookStore())
        try await finish(reopened)
        #expect(reopened.changeSourceOrigins.map(\.sourceId) == [sources[0].id])
        #expect(await probe.sourceIDs() == sources.map(\.id), "opening after a switch must issue no new search")
        #expect(ChangeSourceCache.shared.entry(for: book.id)?.timestamp == cached.timestamp)

        reopened.loadOtherOrigins(book: book, currentSourceId: sources[1].id,
            enabledSources: sources, store: BookStore(), forceRefresh: true)
        try await finish(reopened)
        #expect(await probe.sourceIDs() == sources.map(\.id) + sources.map(\.id))
        #expect(reopened.changeSourceOrigins.map(\.sourceId) == [sources[0].id])
        #expect(ChangeSourceCache.shared.entry(for: book.id)?.origins.map(\.sourceId) == sources.map(\.id))
    }

    @Test("a partial list keeps hidden origins when switching and resumes only unfinished sources")
    func partialCandidatesSurviveSourceSwitchAndResumeRemainingOnly() async throws {
        let saved = configureSettings()
        defer { restoreSettings(saved) }
        let sources = makeSources(3)
        let probe = CandidateSearchProbe(heldSourceID: sources[2].id)
        let model = makeModel(CandidateSearchFetcher(probe: probe))
        var book = ReadingBook(title: "Owned partial candidates", author: "Author", contentFilename: "")
        book.bookInfoURL = sources[0].bookSourceUrl + "/book"
        defer {
            model.stopChangeSourceSearch()
            Task { await probe.releaseAll() }
            ChangeSourceCache.shared.clear(for: book.id)
        }

        model.loadOtherOrigins(book: book, currentSourceId: sources[0].id,
            enabledSources: sources, store: BookStore())
        let oldTask = try #require(model.changeSourceSearchTaskForTesting())
        try await withDeadline { try await probe.waitForStarts(3) }
        #expect(model.changeSourceOrigins.map(\.sourceId) == [sources[1].id])
        model.stopChangeSourceSearch()
        book.bookInfoURL = sources[1].bookSourceUrl + "/book"
        model.loadOtherOrigins(book: book, currentSourceId: sources[1].id,
            enabledSources: sources, store: BookStore())
        try await withDeadline { try await probe.waitForStarts(4) }
        #expect(model.changeSourceLoading)
        #expect(model.changeSourceOrigins.map(\.sourceId) == [sources[0].id])
        #expect(await probe.sourceIDs() == [sources[0].id, sources[1].id, sources[2].id, sources[2].id])
        let partial = try #require(ChangeSourceCache.shared.entry(for: book.id))
        #expect(partial.origins.map(\.sourceId) == Array(sources.prefix(2)).map(\.id))
        #expect(partial.acceptedAttempts == [sources[0].id: .results, sources[1].id: .results])
        #expect(partial.scanCoverage?.completedAllAttempts == false)

        await probe.releaseAll()
        try await finish(model)
        try await finish(oldTask)
        #expect(model.changeSourceOrigins.map(\.sourceId) == [sources[0].id, sources[2].id])
        #expect(ChangeSourceCache.shared.entry(for: book.id)?.origins.map(\.sourceId) == sources.map(\.id))
        // B was hidden while resuming. Its original candidate must survive the
        // final write so switching back to A can display B without a new query.
        book.bookInfoURL = sources[0].bookSourceUrl + "/book"
        model.loadOtherOrigins(book: book, currentSourceId: sources[0].id,
            enabledSources: sources, store: BookStore())
        try await finish(model)
        #expect(model.changeSourceOrigins.map(\.sourceId) == [sources[1].id, sources[2].id])
        #expect(await probe.sourceIDs() == [sources[0].id, sources[1].id, sources[2].id, sources[2].id])
    }

    private func configureSettings() -> (Int, Int, Bool) {
        let settings = GlobalSettings.shared
        let saved = (settings.searchCacheDays, settings.searchConcurrency, settings.changeSourceLoadToc)
        settings.searchCacheDays = 1
        settings.searchConcurrency = 1
        settings.changeSourceLoadToc = false
        return saved
    }

    private func restoreSettings(_ saved: (Int, Int, Bool)) {
        GlobalSettings.shared.searchCacheDays = saved.0
        GlobalSettings.shared.searchConcurrency = saved.1
        GlobalSettings.shared.changeSourceLoadToc = saved.2
    }

    private func makeSources(_ count: Int) -> [BookSource] {
        (0..<count).map { index in
            var source = BookSource(bookSourceUrl: "https://candidate-\(UUID()).invalid/\(index)",
                bookSourceName: "Owned \(index)")
            source.searchUrl = "/search?key={{key}}"
            source.ruleSearch.bookList = ".item"
            return source
        }
    }

    private func makeModel(_ fetcher: CandidateSearchFetcher) -> ReaderViewModel {
        ReaderViewModel(chapterFetcher: CandidateNoopChapterFetcher(),
            bookCoordinator: CandidateNoopBookCoordinator(), bookSourceFetcher: fetcher)
    }

    private func finish(_ model: ReaderViewModel) async throws {
        let task = try #require(model.changeSourceSearchTaskForTesting())
        try await finish(task)
        #expect(!model.changeSourceLoading)
    }

    private func finish(_ task: Task<Void, Never>) async throws {
        try await withDeadline {
            await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        }
    }

    private func withDeadline(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                // Failure deadline only; successful ordering uses probe events.
                try await Task.sleep(for: .seconds(5))
                throw CandidateTestFailure.deadline
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}

private enum CandidateTestFailure: Error { case deadline, unused }

/// Every blocked query and observer releases its continuation on cancellation.
private actor CandidateSearchProbe {
    private let heldSourceID: UUID?
    private var started: [UUID] = []
    private var isOpen = false
    private var queries: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var observers: [UUID: (count: Int, continuation: CheckedContinuation<Void, Error>)] = [:]

    init(heldSourceID: UUID? = nil) { self.heldSourceID = heldSourceID }

    func begin(_ sourceID: UUID) async throws {
        try Task.checkCancellation()
        started.append(sourceID)
        for (id, waiter) in observers.filter({ started.count >= $0.value.count }) {
            observers.removeValue(forKey: id)
            waiter.continuation.resume()
        }
        guard sourceID == heldSourceID, !isOpen else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { queries[id] = continuation }
            }
        } onCancel: { Task { await self.cancelQuery(id) } }
    }

    func waitForStarts(_ count: Int) async throws {
        if started.count >= count { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { observers[id] = (count, continuation) }
            }
        } onCancel: { Task { await self.cancelObserver(id) } }
    }

    func sourceIDs() -> [UUID] { started }
    func releaseAll() {
        isOpen = true
        let waiting = Array(queries.values)
        queries.removeAll()
        waiting.forEach { $0.resume() }
    }
    private func cancelQuery(_ id: UUID) { queries.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    private func cancelObserver(_ id: UUID) { observers.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError()) }
}

private final class CandidateSearchFetcher: BookSourceFetching, @unchecked Sendable {
    let probe: CandidateSearchProbe
    init(probe: CandidateSearchProbe) { self.probe = probe }
    func search(query: String, in source: BookSource) async throws -> [OnlineBook] {
        try await probe.begin(source.id)
        return [OnlineBook(name: query, author: "Author", intro: "", coverUrl: "",
            bookUrl: source.bookSourceUrl + "/book", tocUrl: source.bookSourceUrl + "/toc",
            wordCount: "", lastChapter: "", kind: "", sourceId: source.id, sourceName: source.bookSourceName)]
    }
    func fetchBookInfoPackage(url: String, source: BookSource, runtimeVariables: [String: String]?,
        knownBook: OnlineBook?) async throws -> BookInfoPackage { throw CandidateTestFailure.unused }
    func fetchTOCPackage(tocUrl: String, source: BookSource, runtimeVariables: [String: String]?,
        onFirstPageReady: (([OnlineChapterRef]) -> Void)?, forceRefresh: Bool) async throws -> TOCPackage {
        throw CandidateTestFailure.unused
    }
    func isChapterCached(bookId: UUID, chapterIndex: Int, expectedSourceURL: String?, expectedTOCTitle: String?) -> Bool { false }
    func clearChapterCache(bookId: UUID, chapterIndex: Int) {}
    func clearAllChapterCache(bookId: UUID) {}
    func loadChapterPackageSync(bookId: UUID, chapterIndex: Int, expectedSourceURL: String?, expectedTOCTitle: String?) -> ChapterPackage? { nil }
    func loadNormalizedChapterHTMLSync(bookId: UUID, chapterIndex: Int, expectedSourceURL: String?, expectedTOCTitle: String?) -> String? { nil }
}

private struct CandidateNoopChapterFetcher: ChapterFetching {
    func isChapterCached(book: ReadingBook, chapterIndex: Int) async -> Bool { false }
    func fetchChapter(book: ReadingBook, chapterIndex: Int, priority: ChapterFetchPriority, store: BookStore?) async throws -> ChapterPackage {
        throw CandidateTestFailure.unused
    }
    func cancelChapter(bookId: UUID, chapterIndex: Int) async {}
    func cancelAll(for bookId: UUID) async {}
}

private final class CandidateNoopBookCoordinator: OnlineBookCoordinating {
    func prefetchAround(book: ReadingBook, center: Int, store: BookStore?) async {}
}
