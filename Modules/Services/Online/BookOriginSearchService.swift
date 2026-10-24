import Foundation

/// Coverage describes finished attempts, never a claim that every source worked.
struct BookOriginSearchCoverage: Codable, Sendable {
    let sourceCount: Int
    var completedAllAttempts = false
    var attemptedSourceCount = 0
    var resultSourceCount = 0
    var emptySourceCount = 0
    var failedSourceCount = 0
    var timedOutSourceCount = 0
    var cancelledSourceCount = 0
}

/// The single cross-source "find this exact book in every enabled source" fan-out.
///
/// 換源 and 封面搜索 ask the same question of the same sources — Legado runs both
/// through `WebBook.searchBookAwait` for the same reason — so the search lives
/// here and each screen only decides what to do with the origins it receives.
/// A second copy of this loop is how the two would drift apart on matching,
/// dedup, timeout and health accounting.
///
/// Results stream per source rather than arriving as one array: a shelf with 400+
/// sources takes minutes to exhaust, and both screens fill in as matches arrive.
@MainActor
enum BookOriginSearchService {

    /// Runs the fan-out until every source has answered, `shouldStop` reports that
    /// enough matches are in (搜索自動暫停), or the surrounding task is cancelled.
    ///
    /// - Parameters:
    ///   - title: the book's title; also the search query, as Legado does.
    ///   - author: used for same-book matching only.
    ///   - concurrency: active sources at a time (網路設定 → 搜索並發數).
    ///   - excludingOriginKey: an origin to hide — 換源 excludes the one in use.
    ///   - sourceFilter: decides whether a source is worth querying at all;
    ///     封面搜索 skips sources whose search rule has no cover field.
    ///   - requiresAuthor: keep only results whose source gave an author, so title and author
    ///     both match (the design's level B; the metadata filler, Phase 3b).
    ///   - shouldStop: given the running match count, returns true to stop early.
    ///   - onBatch: one source's matches, already deduped, on the main actor.
    ///   - onSourceAnswered: called for each source that answered within its time, matches
    ///     or not, so a caller can tell "nobody has it" from "nobody answered".
    @discardableResult
    static func stream(
        title: String,
        author: String,
        sources: [BookSource],
        concurrency: Int,
        fetcher: BookSourceFetching,
        excludingOriginKey: String? = nil,
        sourceFilter: ((BookSource) -> Bool)? = nil,
        requiresAuthor: Bool = false,
        sourceTimeout: UInt64 = 20,
        shouldStop: ((Int) -> Bool)? = nil,
        onSourceAnswered: () -> Void = {},
        onBatch: @MainActor ([BookOrigin]) async -> Void
    ) async -> BookOriginSearchCoverage {
        let queried = sourceFilter.map { filter in sources.filter(filter) } ?? sources
        guard !queried.isEmpty else {
            return BookOriginSearchCoverage(sourceCount: 0, completedAllAttempts: !Task.isCancelled)
        }

        var emittedCount = 0
        let matcher = OriginMatcher(title: title, author: author, requiresAuthor: requiresAuthor,
            excludingOriginKey: excludingOriginKey)

        return await withTaskGroup(of: SourceAnswer.self) { group in
            var nextSourceIndex = 0
            var coverage = BookOriginSearchCoverage(sourceCount: queried.count)
            let started = SourcePerfTrace.now
            defer {
                SourcePerfTrace.record("changeSource.scan", "sources=\(queried.count) attempted=\(coverage.attemptedSourceCount) results=\(coverage.resultSourceCount) empty=\(coverage.emptySourceCount) failed=\(coverage.failedSourceCount) timedOut=\(coverage.timedOutSourceCount) completed=\(coverage.completedAllAttempts) main=\(Thread.isMainThread)", since: started)
            }
            let activeLimit = min(max(concurrency, 1), queried.count)

            func enqueueNextSource() {
                guard nextSourceIndex < queried.count else { return }
                let source = queried[nextSourceIndex]
                nextSourceIndex += 1
                group.addTask {
                    guard !Task.isCancelled else { return SourceAnswer(books: nil, outcome: .cancelled) }
                    return await searchSourceAnswer(
                        query: title,
                        bookTitle: title,
                        bookAuthor: author,
                        source: source,
                        bookSourceFetcher: fetcher,
                        seconds: sourceTimeout
                    )
                }
            }

            for _ in 0..<activeLimit {
                enqueueNextSource()
            }

            while let answer = await group.next() {
                guard !Task.isCancelled else { group.cancelAll(); return coverage }
                coverage.attemptedSourceCount += 1
                switch answer.outcome {
                case .results: coverage.resultSourceCount += 1
                case .empty: coverage.emptySourceCount += 1
                case .failed, .reportedFailure: coverage.failedSourceCount += 1
                case .timedOut: coverage.timedOutSourceCount += 1
                case .cancelled: coverage.cancelledSourceCount += 1
                }
                guard let list = answer.books else {
                    // Timed out or failed: its slot goes to the next source.
                    enqueueNextSource()
                    continue
                }
                onSourceAnswered()
                var shouldPause = false
                var batchOrigins = await matcher.origins(from: list)
                guard !Task.isCancelled else { group.cancelAll(); return coverage }
                // Cover/metadata callers retain their explicit stop policy. The
                // reader omits it, so no candidate count can truncate its scan.
                if let shouldStop {
                    for offset in batchOrigins.indices {
                        if shouldStop(emittedCount + offset + 1) {
                            batchOrigins = Array(batchOrigins.prefix(offset + 1))
                            shouldPause = true
                            break
                        }
                    }
                }
                if !batchOrigins.isEmpty {
                    emittedCount += batchOrigins.count
                    await onBatch(batchOrigins)
                    guard !Task.isCancelled else { group.cancelAll(); return coverage }
                    // Asked again after the batch is handed over: a caller deciding by what
                    // the matches carry (the metadata filler stops at a description) knows
                    // only now.
                    if shouldStop?(emittedCount) == true { shouldPause = true }
                }
                if shouldPause {
                    group.cancelAll()
                    return coverage
                }
                enqueueNextSource()
            }
            coverage.completedAllAttempts = coverage.attemptedSourceCount == queried.count && !Task.isCancelled
            return coverage
        }
    }

    /// Same-book folding, origin construction and dedup grow with a source's
    /// result count. This actor keeps that work off the reader's main actor.
    private actor OriginMatcher {
        let title: String
        let author: String
        let requiresAuthor: Bool
        let excludingOriginKey: String?
        var target: SearchWorkKeys?
        var seenOriginKeys = Set<String>()

        init(title: String, author: String, requiresAuthor: Bool, excludingOriginKey: String?) {
            self.title = title; self.author = author
            self.requiresAuthor = requiresAuthor; self.excludingOriginKey = excludingOriginKey
        }

        func origins(from books: [OnlineBook]) -> [BookOrigin] {
            SourcePerfTrace.span("changeSource.match", "books=\(books.count) main=\(Thread.isMainThread)") {
                if target == nil { target = SearchWorkKeys(name: title, author: author) }
                guard let target else { return [] }
                return books.compactMap { book in
                    if requiresAuthor && book.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
                    guard SearchBook.isLikelySameBook(target, SearchWorkKeys(name: book.name, author: book.author)) else { return nil }
                    let key = ChangeSourceCache.originKey(sourceId: book.sourceId, bookUrl: book.bookUrl)
                    guard key != excludingOriginKey, seenOriginKeys.insert(key).inserted else { return nil }
                    return BookOrigin(sourceId: book.sourceId, sourceName: book.sourceName,
                        bookUrl: book.bookUrl, tocUrl: book.tocUrl, coverUrl: book.coverUrl,
                        intro: book.intro, lastChapter: book.lastChapter, wordCount: book.wordCount,
                        kind: book.kind, runtimeVariables: book.runtimeVariables)
                }
            }
        }
    }

    /// One source's search, abandoned after `seconds`. A source that never answers
    /// must not hold an active slot for the whole session.
    nonisolated static func searchSourceWithTimeout(
        query: String,
        bookTitle: String,
        bookAuthor: String,
        source: BookSource,
        bookSourceFetcher: BookSourceFetching,
        seconds: UInt64 = 20
    ) async -> [OnlineBook]? {
        await searchSourceAnswer(query: query, bookTitle: bookTitle, bookAuthor: bookAuthor,
            source: source, bookSourceFetcher: bookSourceFetcher, seconds: seconds).books
    }

    private enum SourceOutcome: Sendable { case results, empty, reportedFailure, failed, timedOut, cancelled }
    private struct SourceAnswer: Sendable {
        let books: [OnlineBook]?
        let outcome: SourceOutcome
    }

    private nonisolated static func searchSourceAnswer(
        query: String, bookTitle: String, bookAuthor: String, source: BookSource,
        bookSourceFetcher: BookSourceFetching, seconds: UInt64 = 20
    ) async -> SourceAnswer {
        let startedAt = ProcessInfo.processInfo.systemUptime
        // Folded once per source, off the main actor; the filter runs per parsed item.
        let target = SearchWorkKeys(name: bookTitle, author: bookAuthor)
        let answer = await withTaskGroup(of: SourceAnswer.self) { group in
            group.addTask {
                // Early filter (Legado BookList idea): reject non-matching items
                // right after their name/author rules run, so the remaining field
                // rules (cover/intro/kind/wordCount/lastChapter/bookUrl) are never
                // evaluated — both callers only keep exact same-book candidates.
                do {
                    let outcome = try await bookSourceFetcher.searchOutcome(query: query, in: source,
                        earlyFilter: { name, author in
                            SearchBook.isLikelySameBook(target, SearchWorkKeys(name: name, author: author))
                        })
                    switch outcome {
                    case .results(let books): return SourceAnswer(books: books, outcome: .results)
                    case .empty: return SourceAnswer(books: [], outcome: .empty)
                    case .failed(.cancelled): return SourceAnswer(books: nil, outcome: .cancelled)
                    case .failed: return SourceAnswer(books: nil, outcome: .reportedFailure)
                    }
                } catch is CancellationError { return SourceAnswer(books: nil, outcome: .cancelled) }
                catch let error as URLError where error.code == .cancelled { return SourceAnswer(books: nil, outcome: .cancelled) }
                catch {
                    AppLogger.parse("ChangeSource source search failed type=\(String(reflecting: type(of: error)))")
                    return SourceAnswer(books: nil, outcome: .failed)
                }
            }
            group.addTask {
                // Existing per-source timeout; never a wait for state to settle.
                do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) }
                catch { return SourceAnswer(books: nil, outcome: .cancelled) }
                return SourceAnswer(books: nil, outcome: .timedOut)
            }
            let first = await group.next() ?? SourceAnswer(books: nil, outcome: .cancelled)
            group.cancelAll()
            return first
        }
        if answer.books != nil {
            // Only a real result or a legitimate empty page clears health strikes.
            // Reported failures keep their coverage fact and never masquerade as an answer.
            let elapsedMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
            let sourceId = source.id
            await MainActor.run {
                SourceHealthStore.shared.recordSuccess(sourceId, responseMs: elapsedMs)
            }
        }
        return answer
    }
}
