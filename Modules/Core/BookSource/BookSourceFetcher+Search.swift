import Foundation
import LegadoRuntime

enum BookSourceSearchFailureMode: Sendable {
    /// Interactive search treats an unreachable source like an empty result so one
    /// broken site does not fail the whole aggregate search UI.
    case emptyResult
    /// Source validation needs the transport error itself so it can fail that source
    /// immediately, matching Legado's `checkSource` coroutine instead of continuing
    /// into discovery and holding a validation worker for another timeout window.
    case propagateTransportError
}

/// Why one source's search failed, for the log. Never carries the request URL: a search
/// URL contains the reader's keyword.
enum BookSourceSearchFailure: Error, Equatable, Sendable {
    case http(Int)
    case encoding
    case emptyContent
    case transport(String)
    case parse(String)
    /// The search was cancelled (a timeout or a newer search). Not the source's fault and
    /// not logged.
    case cancelled

    var logReason: String {
        switch self {
        case .http(let code): "HTTP \(code)"
        case .encoding: "page encoding not recognized"
        case .emptyContent: "empty response"
        case .transport(let description): "transport: \(description)"
        case .parse(let description): "parse: \(description)"
        case .cancelled: "cancelled"
        }
    }

    /// What the native search path does with an error from its request stage. This is the
    /// mapping `search` has always applied, in both failure modes: these errors come back
    /// as "no results" and every other one is thrown. `propagateTransportError` throws only
    /// the errors that are not `FetchError`s.
    enum Disposition: Equatable, Sendable {
        /// Reported to the caller as no results; recorded as this failure.
        case reportedAsEmpty(BookSourceSearchFailure)
        case thrown
    }

    static func disposition(of error: Error, mode: BookSourceSearchFailureMode) -> Disposition {
        if let fetchError = error as? FetchError {
            switch fetchError {
            case .encodingError:
                return .reportedAsEmpty(.encoding)
            case .httpError(let code) where [401, 403, 404, 429, 500, 502, 503].contains(code):
                return .reportedAsEmpty(.http(code))
            case .emptyContent:
                return .reportedAsEmpty(.emptyContent)
            default:
                return .thrown
            }
        }
        if mode == .propagateTransportError { return .thrown }
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return .reportedAsEmpty(.cancelled)
        }
        return .reportedAsEmpty(.transport(error.localizedDescription))
    }
}

/// One source's answer to one search page: books, a legitimately empty page, or a failure
/// that `search(…)` has always reported to its callers as an empty page.
enum BookSourceSearchOutcome: Sendable {
    case results([OnlineBook])
    case empty
    case failed(BookSourceSearchFailure)

    var books: [OnlineBook] {
        if case .results(let books) = self { return books }
        return []
    }

    var failure: BookSourceSearchFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }

    init(books: [OnlineBook]) {
        self = books.isEmpty ? .empty : .results(books)
    }
}

/// Legado aggregate sources accept qualified searches such as
/// `m:book name@source`. The full expression must reach the source's search JS,
/// while local result matching must compare against the book-name portion only.
enum LegadoSearchKeyword {
    static func matchingTitle(from rawQuery: String) -> String {
        var value = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2 {
            let prefix = value.prefix(2).lowercased()
            if ["x:", "t:", "m:", "d:", "x：", "t：", "m：", "d："].contains(prefix) {
                value.removeFirst(2)
            }
        }
        if let separator = value.firstIndex(of: "@") {
            value = String(value[..<separator])
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Search Books

extension BookSourceFetcher {

    struct SearchStreamingOutcome {
        let books: [OnlineBook]
        let streamed: Bool
        /// Set when the native path failed and reported the failure as no results. Nil for
        /// cache hits and the JS runtime, whose errors are thrown.
        var failure: BookSourceSearchFailure? = nil
        /// The native page's own verdict. Cache hits and JS runtime paths remain unknown.
        var hasMore: Bool? = nil
    }

    /// - Parameters:
    ///   - page: 1-based result page (載入更多 passes 2+; only page 1 is cached).
    ///   - earlyFilter: applied at parse time right after name/author extraction
    ///     so rejected items skip the remaining rule evaluations (換源 strict
    ///     matching). Filtered runs never write the shared search cache.
    ///   - onHasMore: reports the source's own next-page verdict (`hasMoreRule`,
    ///     native path only). nil = unknown → caller uses heuristics.
    func search(
        query: String,
        in source: BookSource,
        page: Int = 1,
        earlyFilter: ((_ name: String, _ author: String) -> Bool)? = nil,
        onHasMore: ((Bool?) -> Void)? = nil,
        failureMode: BookSourceSearchFailureMode = .emptyResult
    ) async throws -> [OnlineBook] {
        try await searchOutcome(
            query: query, in: source, page: page,
            earlyFilter: earlyFilter, onHasMore: onHasMore, failureMode: failureMode
        ).books
    }

    /// `search(…)` with the difference between a legitimately empty page and a failure kept.
    /// Throws exactly what `search(…)` throws; a failure it has always reported as no results
    /// comes back as `.failed` and is logged once, here.
    func searchOutcome(
        query: String,
        in source: BookSource,
        page: Int = 1,
        earlyFilter: ((_ name: String, _ author: String) -> Bool)? = nil,
        onHasMore: ((Bool?) -> Void)? = nil,
        failureMode: BookSourceSearchFailureMode = .emptyResult
    ) async throws -> BookSourceSearchOutcome {
        try await searchPageOutcome(
            query: query, in: source, page: page, earlyFilter: earlyFilter,
            evaluateHasMore: onHasMore != nil, onHasMore: onHasMore, failureMode: failureMode
        ).outcome
    }

    /// Returns the verdict with the books rather than transporting it through a
    /// mutable capture in a callback from the source-script worker.
    private func searchPageOutcome(
        query: String,
        in source: BookSource,
        page: Int = 1,
        earlyFilter: ((_ name: String, _ author: String) -> Bool)? = nil,
        evaluateHasMore: Bool,
        onHasMore: ((Bool?) -> Void)? = nil,
        failureMode: BookSourceSearchFailureMode = .emptyResult
    ) async throws -> (outcome: BookSourceSearchOutcome, hasMore: Bool?) {
        if source.isJsSource {
            var books = try await mainJSService.search(query: query, page: page, source: source)
            if let earlyFilter { books = books.filter { earlyFilter($0.name, $0.author) } }
            onHasMore?(nil)
            return (BookSourceSearchOutcome(books: books), nil)
        }
        guard !source.searchUrl.isEmpty else { throw FetchError.noSearchURL }
        let cacheDays = GlobalSettings.shared.searchCacheDays
        let cacheEligible = page == 1 && earlyFilter == nil
        if page == 1, let cached = SearchResultCache.shared.freshBooks(
            query: query,
            source: source,
            days: cacheDays
        ) {
            onHasMore?(nil)
            guard let earlyFilter else { return (BookSourceSearchOutcome(books: cached), nil) }
            return (BookSourceSearchOutcome(books: cached.filter { earlyFilter($0.name, $0.author) }), nil)
        }

        // Every traditional source uses the retained WebBook implementation. A
        // cache hit is an existing immutable preview reference; a failure never
        // selects another parser or repeats a request through the old JS bridge.
        guard let originalPage = Int32(exactly: page), originalPage > 0 else {
            throw FetchError.sourceAPIError("Search page exceeds the original Int range")
        }
        var books: [OnlineBook]
        do { books = try await mainJSService.originalSearch(query: query, page: originalPage, source: source) }
        catch let error as LegadoRuntimeError where failureMode == .emptyResult
            && (error.code == "HTTP_ERROR" || error.code == "RULE_ERROR") {
            let failure: BookSourceSearchFailure = error.code == "HTTP_ERROR"
                ? .transport("Original WebBook HTTP error") : .parse("Original WebBook rule error")
            Self.logReportedAsEmpty(failure, source: source,
                host: URL(string: source.bookSourceUrl)?.host, mode: failureMode)
            return (.failed(failure), nil)
        }
        if let earlyFilter { books = books.filter { earlyFilter($0.name, $0.author) } }
        let filtered = Self.filterSearchResultsByCheckKeyWord(
            books, query: query, checkKeyWord: source.ruleSearch.checkKeyWord)
        if cacheEligible {
            SearchResultCache.shared.store(books: filtered, query: query, source: source, days: cacheDays)
        }
        // WebBook's result DTO does not invent a next-page verdict.
        onHasMore?(nil)
        return (BookSourceSearchOutcome(books: filtered), nil)
    }

    /// One line per failed source, so a source that keeps failing can be found in the log
    /// instead of looking like a source without the book. Source name, host and reason only:
    /// the URL and the query carry what the reader searched for.
    ///
    /// Only for searches that show the reader a failure as "no results". 書源驗證
    /// (`.propagateTransportError`) already lists every source's failure in its own results,
    /// and a run over tens of thousands of sources would push everything else out of the
    /// diagnostic log (maintainer's choice, 2026-10-10).
    private static func logReportedAsEmpty(
        _ failure: BookSourceSearchFailure,
        source: BookSource,
        host: String?,
        mode: BookSourceSearchFailureMode
    ) {
        guard mode == .emptyResult, failure != .cancelled else { return }
        let message = "search failed; shown as no results: \(source.bookSourceName) (\(host ?? "")) \(failure.logReason)"
        if case .parse = failure {
            AppLogger.parse(message, level: .warning)
        } else {
            AppLogger.network(message, level: .warning)
        }
    }

    /// Page fetch for 載入更多: books plus the source's own next-page verdict.
    func searchPage(
        query: String,
        in source: BookSource,
        page: Int
    ) async throws -> (books: [OnlineBook], hasMore: Bool?) {
        let result = try await searchPageOutcome(
            query: query, in: source, page: page, evaluateHasMore: true
        )
        return (result.outcome.books, result.hasMore)
    }

    func searchStreaming(
        query: String,
        in source: BookSource,
        onBatch: @escaping @Sendable ([OnlineBook]) async -> Void
    ) async throws -> SearchStreamingOutcome {
        if source.isJsSource {
            let books = try await mainJSService.search(query: query, page: 1, source: source)
            return SearchStreamingOutcome(books: books, streamed: false)
        }
        guard !source.searchUrl.isEmpty else { throw FetchError.noSearchURL }
        let cacheDays = GlobalSettings.shared.searchCacheDays
        if let cached = SearchResultCache.shared.freshBooks(
            query: query,
            source: source,
            days: cacheDays
        ) {
            return SearchStreamingOutcome(books: cached, streamed: false)
        }


        let result = try await searchPageOutcome(query: query, in: source, evaluateHasMore: true)
        return SearchStreamingOutcome(books: result.outcome.books, streamed: false,
                                      failure: result.outcome.failure, hasMore: result.hasMore)
    }

    /// Legado compatible: filter search results by checkKeyWord (keep only items matching keyword in title/author)
    private static func filterSearchResultsByCheckKeyWord(
        _ books: [OnlineBook], query: String, checkKeyWord: String
    ) -> [OnlineBook] {
        guard !checkKeyWord.isEmpty, !query.isEmpty else { return books }
        let key = LegadoSearchKeyword.matchingTitle(from: query).lowercased()
        guard !key.isEmpty else { return books }
        return books.filter { book in
            book.name.localizedCaseInsensitiveContains(key)
                || book.author.localizedCaseInsensitiveContains(key)
        }
    }
}
