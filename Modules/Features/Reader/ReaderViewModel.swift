import Combine
import Foundation
import LegadoRuntime
import SwiftUI

@MainActor
final class ReaderViewModel: ObservableObject {
    @Published private(set) var chapterStates: [Int: ChapterLoadState] = [:]
    /// The book shows paragraph-review bubbles — a review link or a bubble SVG in a
    /// chapter loaded so far. Gates 閱讀設定 › 段評氣泡.
    @Published private(set) var hasParagraphReviews = false

    /// Chapter cache availability validated by the loading pipeline. This is deliberately
    /// kept in memory so SwiftUI presentation code never re-opens and re-validates chapter
    /// files during `body` evaluation.
    private var availableChapterIndexes: Set<Int> = []

    // MARK: - Source Change State

    @Published private(set) var changeSourceOrigins: [BookOrigin] = []
    @Published private(set) var changeSourceLoading: Bool = false
    @Published private(set) var changeSourceError: String? = nil
    /// Normalized source-qualified keys of origins that failed to switch (TOC fetch threw),
    /// so the 換源 list can flag them. Backed by `ChangeSourceCache`.
    @Published private(set) var changeSourceFailedKeys: Set<String> = []
    /// Non-nil while a tapped source is being switched to. The sheet renders a cancellable
    /// "正在載入目錄…" over the row instead of looking frozen — Legado shows a `WaitDialog`
    /// on the same event, and its cancel listener aborts the fetch.
    @Published private(set) var changeSourcePendingOrigin: BookOrigin?

    private struct InFlightRequest {
        let token: UUID
        let priority: ChapterFetchPriority
        let task: Task<Void, Never>
    }

    private var chapterFetcher: ChapterFetching
    private var bookCoordinator: OnlineBookCoordinating
    private var bookSourceFetcher: BookSourceFetching
    private var offlineDownloadManager: (any OfflineDownloadManaging)?
    private var inFlightRequests: [Int: InFlightRequest] = [:]
    /// Books already checked for auto manga detection this session (cached-chapter path),
    /// so a genuine text book is not re-probed on every `ensureChapterReady`.
    private var mangaDetectionAttempted: Set<UUID> = []
    private struct CachedChapterInspectionKey: Hashable {
        let bookId: UUID
        let chapterIndex: Int
    }
    /// Cached chapters already inspected for paragraph-review capability. The inspection
    /// uses `ChapterFetching` asynchronously instead of synchronously reading files from a
    /// SwiftUI update callback.
    private var paragraphReviewInspectionAttempted: Set<CachedChapterInspectionKey> = []
    /// The current 換源 (source switch) search, so a re-open cancels the previous run.
    private var changeSourceSearchTask: Task<Void, Never>?
    private var changeSourceGeneration = UUID()
    private var changeSourceWork: ReaderSourceChangeWork?
    /// Only the closing work's actor snapshot/cache write, never the old network
    /// task. Immediate reopens await it before reading the same cache record.
    private var changeSourceCheckpointTask: Task<Void, Never>?
    /// The switch the user just tapped, while its TOC is being prepared. Drives the sheet's
    /// cancellable loading state (Legado's `WaitDialog`), and holding the task is what makes
    /// cancelling possible at all.
    private var changeSourceSwitchTask: Task<Void, Never>?
    /// Background TOC warm-up feeding `searchTOCCache` (see `warmSearchTOCCacheIfEnabled`).
    private var tocWarmTask: Task<Void, Never>?
    /// TOCs captured during the search fan-out when 搜索時載入目錄 is on — Legado's `tocMap`.
    /// A tap that hits this switches with no network round trip at all.
    private var searchTOCCache: [String: TOCPackage] = [:]
    /// Total chapters held in `searchTOCCache`. Legado caps the same map at 30 000 chapters
    /// so a few long 萬章 novels can't pin the whole TOC set in memory.
    private var searchTOCChapterCount = 0
    private static let searchTOCChapterLimit = 30_000

    convenience init() {
        self.init(
            chapterFetcher: AppDependencies.live.chapterFetcher,
            bookCoordinator: AppDependencies.live.onlineBookCoordinator,
            bookSourceFetcher: AppDependencies.live.bookSourceFetcher,
            offlineDownloadManager: AppDependencies.live.offlineDownloadManager
        )
    }

    init(
        chapterFetcher: ChapterFetching,
        bookCoordinator: OnlineBookCoordinating,
        bookSourceFetcher: BookSourceFetching,
        offlineDownloadManager: (any OfflineDownloadManaging)? = nil
    ) {
        self.chapterFetcher = chapterFetcher
        self.bookCoordinator = bookCoordinator
        self.bookSourceFetcher = bookSourceFetcher
        self.offlineDownloadManager = offlineDownloadManager
    }

    func chapterState(for chapterIndex: Int) -> ChapterLoadState {
        chapterStates[chapterIndex] ?? .idle
    }

    func isChapterContentAvailable(at chapterIndex: Int) -> Bool {
        availableChapterIndexes.contains(chapterIndex)
    }

    func configure(
        chapterFetcher: ChapterFetching,
        offlineDownloadManager: any OfflineDownloadManaging
    ) {
        self.chapterFetcher = chapterFetcher
        self.offlineDownloadManager = offlineDownloadManager
    }

    func resetChapterState(for chapterIndex: Int) {
        if let existing = inFlightRequests.removeValue(forKey: chapterIndex) {
            existing.task.cancel()
        }
        availableChapterIndexes.remove(chapterIndex)
        chapterStates.removeValue(forKey: chapterIndex)
    }

    /// Drops every chapter's load state. Required on 換源, where the states describe the
    /// *previous* source's chapters while `book.onlineChapters` — and therefore every cache
    /// lookup the reader makes — has already been replaced. Keeping them made
    /// `ReaderChapterPresentation.overlayState` compare a stale `.ready` against the new
    /// source's (necessarily empty) cache and render the 資料不一致 failure overlay on
    /// every source switch.
    func resetAllChapterStates() {
        for (_, request) in inFlightRequests {
            request.task.cancel()
        }
        inFlightRequests.removeAll()
        chapterStates.removeAll()
        // The single-chapter form (`resetChapterState`) drops this too. Leaving it behind
        // made every chapter keep claiming "content available" against a cache that 移除下載
        // had just emptied, and `overlayState` consults it first — so the reader painted
        // 資料不一致 over chapters it could simply have refetched.
        availableChapterIndexes.removeAll()
    }

    // MARK: - Chapter Loading

    /// The book the chapter states currently describe.
    ///
    /// `setChapterState` is reached from paths that never carried the book
    /// (`finishFetch`, `clearInFlight`), and the retry log keys on it. Recorded here,
    /// at the one entry point every chapter request passes through, rather than
    /// widening four signatures for a diagnostic.
    private var currentBookId: String?

    func ensureChapterReady(
        book: ReadingBook?,
        chapterIndex: Int,
        priority: ChapterFetchPriority,
        store: BookStore?
    ) async {
        guard let book, let refs = book.onlineChapters, refs.indices.contains(chapterIndex) else {
            return
        }
        currentBookId = book.id.uuidString

        // Volume headers (作品相关 / 第N卷 …) have no fetchable content. Mark ready immediately so
        // the builder renders a divider page instead of spinning forever on an empty fetch.
        if refs[chapterIndex].shouldRenderAsVolumeSeparator {
            if let existing = inFlightRequests.removeValue(forKey: chapterIndex) {
                existing.task.cancel()
                await chapterFetcher.cancelChapter(bookId: book.id, chapterIndex: chapterIndex)
            }
            setChapterState(.ready, for: chapterIndex, contentAvailable: true)
            return
        }

        // A previous failure is about to be re-evaluated. The cache probe below is an actor
        // hop plus metadata/artifact reads and a checksum, and the reader renders the failure
        // overlay straight off this state — leaving `.failed` in place paints "章節載入失敗"
        // over a chapter that is actively being loaded again.
        if case .failed = chapterStates[chapterIndex] {
            chapterStates[chapterIndex] = .loading
        }
        if chapterStates[chapterIndex] == .cancelled {
            chapterStates[chapterIndex] = .loading
        }

        if await chapterFetcher.isChapterCached(book: book, chapterIndex: chapterIndex) {
            setChapterState(.ready, for: chapterIndex, contentAvailable: true)
            if let existing = inFlightRequests.removeValue(forKey: chapterIndex) {
                existing.task.cancel()
                await chapterFetcher.cancelChapter(bookId: book.id, chapterIndex: chapterIndex)
            }
            inspectCachedChapter(
                book: book, chapterIndex: chapterIndex, store: store)
            return
        }

        if let existing = inFlightRequests[chapterIndex] {
            guard priority == .jump, existing.priority.rawValue < priority.rawValue else {
                return
            }

            existing.task.cancel()
            let token = UUID()
            inFlightRequests[chapterIndex] = InFlightRequest(
                token: token,
                priority: priority,
                task: Task<Void, Never> {}
            )
            setChapterState(.loading, for: chapterIndex, contentAvailable: false)
            await chapterFetcher.cancelChapter(bookId: book.id, chapterIndex: chapterIndex)
            guard inFlightRequests[chapterIndex]?.token == token else {
                return
            }
            let task = startFetchTask(
                book: book,
                chapterIndex: chapterIndex,
                priority: priority,
                store: store,
                token: token
            )
            inFlightRequests[chapterIndex] = InFlightRequest(token: token, priority: priority, task: task)
            return
        }

        setChapterState(.loading, for: chapterIndex, contentAvailable: false)
        let token = UUID()
        let task = startFetchTask(
            book: book,
            chapterIndex: chapterIndex,
            priority: priority,
            store: store,
            token: token
        )
        inFlightRequests[chapterIndex] = InFlightRequest(token: token, priority: priority, task: task)
    }

    // MARK: - Chapter Cancellation

    /// Cancels the reader's in-flight chapter requests for the given book.
    ///
    /// Offline downloads are deliberately spared: the reader and the downloader share one
    /// fetch manager, so closing the reader used to cancel a download running on the same
    /// book. `runBook` treats cancellation as a clean exit, so the download simply stopped —
    /// no error, no queue, state still `.downloading`.
    func cancelAll(for bookId: UUID) async {
        await chapterFetcher.cancelAll(for: bookId, includingDownloads: false)
    }

    // MARK: - Download Actions

    /// Delegates download selection, pause, resume, and retry to the single offline queue.
    func handleDownloadAction(
        book: ReadingBook,
        store: BookStore,
        startChapterIndex: Int = 0,
        chapterCount: Int? = nil
    ) {
        guard let offlineDownloadManager else { return }
        switch book.offlineDownloadState {
        case .none, .available, .partial:
            guard let refs = book.onlineChapters, !refs.isEmpty else { return }
            let start = min(max(startChapterIndex, 0), refs.count - 1)
            let count = max(1, chapterCount ?? (refs.count - start))
            let end = min(refs.count - 1, start + count - 1)
            Task {
                await offlineDownloadManager.start(
                    book: book,
                    selection: .range(start...end),
                    store: store
                )
            }
        case .failed:
            Task { await offlineDownloadManager.retryFailed(book: book, store: store) }
        case .paused:
            Task { await offlineDownloadManager.resume(book: book, store: store) }
        case .downloading:
            Task { await offlineDownloadManager.pause(bookId: book.id, store: store) }
        }
    }

    func resumeOfflineDownload(book: ReadingBook, store: BookStore) {
        guard let offlineDownloadManager else { return }
        Task { await offlineDownloadManager.resume(book: book, store: store) }
    }

    func retryFailedOfflineDownload(book: ReadingBook, store: BookStore) {
        guard let offlineDownloadManager else { return }
        Task { await offlineDownloadManager.retryFailed(book: book, store: store) }
    }

    func skipFailedOfflineDownload(bookId: UUID, store: BookStore) {
        guard let offlineDownloadManager else { return }
        Task { await offlineDownloadManager.skipFailed(bookId: bookId, store: store) }
    }

    // MARK: - Neighbour Prefetch

    /// Prefetches chapters around the given center index through the injected coordinator.
    func prefetchAround(book: ReadingBook, center: Int, store: BookStore) {
        Task {
            await bookCoordinator.prefetchAround(book: book, center: center, store: store)
        }
    }

    // MARK: - Source Change Search

    /// Searches for alternative book sources with the same title. Results update changeSourceOrigins.
    ///
    /// Honors 網路設定 →「搜索結果快取天數」: unless `forceRefresh` is set, a fresh cached
    /// result for this book is reused instead of re-running the full cross-source search.
    func loadOtherOrigins(
        book: ReadingBook,
        currentSourceId: UUID,
        enabledSources: [BookSource],
        store: BookStore,
        forceRefresh: Bool = false
    ) {
        checkpointAndCancelChangeSourceSearch()
        tocWarmTask?.cancel()
        let generation = UUID()
        changeSourceGeneration = generation
        let work = ReaderSourceChangeWork()
        changeSourceWork = work
        let bookId = book.id
        let cacheDays = GlobalSettings.shared.searchCacheDays
        let concurrency = NetworkSearchSettings.clampedConcurrency(GlobalSettings.shared.searchConcurrency)
        changeSourceLoading = true
        changeSourceError = nil
        changeSourceOrigins = []
        changeSourceFailedKeys = []
        let bookTitle = book.title
        let bookAuthor = book.author
        let currentOriginKey = ChangeSourceCache.originKey(
            sourceId: currentSourceId, bookUrl: book.bookInfoURL)
        let fetcher = bookSourceFetcher
        let checkpoint = changeSourceCheckpointTask
        changeSourceSearchTask = Task { [weak self] in
            await checkpoint?.value
            guard !Task.isCancelled else { return }
            let prepared = await work.prepare(sources: enabledSources, bookId: bookId,
                title: bookTitle, author: bookAuthor, cacheDays: cacheDays,
                excludingOriginKey: currentOriginKey, forceRefresh: forceRefresh)
            guard let self, !Task.isCancelled, self.changeSourceGeneration == generation else { return }
            self.changeSourceFailedKeys = prepared.failedKeys
            self.changeSourceOrigins = prepared.displayOrigins
            if prepared.canEndSearch {
                self.changeSourceLoading = false
                self.warmSearchTOCCacheIfEnabled()
                return
            }
            // Try every enabled source in user order, including the current
            // source's other channels. The search-page pause setting does not
            // truncate a reader's list of switchable origins.
            let coverage = await BookOriginSearchService.stream(
                title: bookTitle,
                author: bookAuthor,
                sources: prepared.sources,
                concurrency: concurrency,
                fetcher: fetcher,
                excludingOriginKey: currentOriginKey,
                bypassSearchCache: true,
                onAttemptFinished: { [weak self] attempt in
                    guard let self, !Task.isCancelled, self.changeSourceGeneration == generation else { return }
                    let origins = await work.accept(attempt)
                    guard !Task.isCancelled, self.changeSourceGeneration == generation else { return }
                    if let origins { self.changeSourceOrigins = origins }
                },
                onBatch: { _ in }
            )
            guard coverage.completedAllAttempts, !Task.isCancelled, self.changeSourceGeneration == generation else { return }
            await work.storeCompleted(coverage: coverage)
            guard !Task.isCancelled, self.changeSourceGeneration == generation else { return }
            self.changeSourceLoading = false
            self.warmSearchTOCCacheIfEnabled()
        }
    }

    #if DEBUG
    /// Tests await the actual search task instead of sleeping for publication.
    func waitForChangeSourceSearchForTesting() async {
        await changeSourceSearchTask?.value
    }
    func changeSourceSearchTaskForTesting() -> Task<Void, Never>? { changeSourceSearchTask }
    #endif

    /// Background-fetches the TOC of the first few switchable origins into
    /// `BookSourceFetcher`'s cache-first TOC store (Legado's tocMap idea), so the
    /// actual switch (`updateOnlineBookSource` → `fetchTOCPackage`) is a cache hit
    /// instead of a network round-trip the user waits on. Serial and low-priority;
    /// already-cached TOCs return immediately.
    // MARK: - Source Switch

    /// Legado `ChangeBookSourceViewModel.getToc`: the search-phase cache first, the network
    /// only on a miss. The resulting package is handed to the commit path, so a switch fetches
    /// its TOC exactly once — the commit used to fetch it a second time.
    func prepareTOCPackage(for origin: BookOrigin) async throws -> TOCPackage {
        let key = ChangeSourceCache.originKey(sourceId: origin.sourceId, bookUrl: origin.bookUrl)
        if let cached = searchTOCCache[key] {
            Self.recordPreparedTOC(chapters: cached.chapters.count, cacheHit: true)
            return cached
        }
        guard let source = BookSourceStore.shared.source(id: origin.sourceId)
        else {
            let error = NSError(
                domain: "ReaderViewModel", code: -1,
                userInfo: [NSLocalizedDescriptionKey: localized("找不到來源配置")])
            Self.recordSourceTOCFailure(error, phase: .sourceLookup)
            throw error
        }
        // A search result almost never carries a tocUrl: it belongs to the book's
        // DETAIL page, so `parseSearchResults` leaves it empty on purpose (an empty
        // rule would otherwise resolve to the site root and we'd scrape the homepage
        // as a TOC — see the guard in `ModernParserBridge.parseBookInfo`). Handing
        // that empty string to `fetchTOCPackage` fails `safeURL` and every tapped
        // origin came back as `Invalid URL:` with nothing after the colon.
        //
        // Legado closes the same gap in `ChangeBookSourceViewModel.getToc`:
        //
        //     if (book.tocUrl.isEmpty()) { WebBook.getBookInfoAwait(source, book) }
        //     val toc = WebBook.getChapterListAwait(source, book).getOrThrow()
        //
        // Same shape here — fetch the detail page only when the TOC url is missing,
        // and carry its runtime variables forward, because that request is what a
        // source's bookInfo JS uses to stash chapter-list state.
        var tocUrl = origin.tocUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        var tocRuntimeVariables = origin.runtimeVariables
        if tocUrl.isEmpty {
            // Hand over what the 換源 search already established, so a detail page that omits a
            // field keeps the origin's value instead of blanking it. name/author are deliberately
            // left empty: `BookOrigin` carries none (a source switch keeps the book's identity,
            // which lives on the ReadingBook, not on the origin), and this path exists only to
            // resolve a missing tocUrl — the switch must never rename the book being read.
            let knownBook = OnlineBook(
                name: "",
                author: "",
                intro: origin.intro,
                coverUrl: origin.coverUrl,
                bookUrl: origin.bookUrl,
                tocUrl: origin.tocUrl,
                wordCount: origin.wordCount,
                lastChapter: origin.lastChapter,
                kind: origin.kind,
                sourceId: origin.sourceId,
                sourceName: origin.sourceName,
                runtimeVariables: origin.runtimeVariables
            )
            let info: BookInfoPackage
            do {
                info = try await bookSourceFetcher.fetchBookInfoPackage(
                    url: origin.bookUrl,
                    source: source,
                    runtimeVariables: origin.runtimeVariables,
                    knownBook: knownBook
                )
            } catch {
                Self.recordSourceTOCFailure(error, phase: .detail)
                throw error
            }
            tocUrl = info.tocUrl
            tocRuntimeVariables = info.runtimeVariables ?? tocRuntimeVariables
        }
        let package: TOCPackage
        do {
            package = try await bookSourceFetcher.fetchTOCPackage(
                tocUrl: tocUrl,
                source: source,
                runtimeVariables: tocRuntimeVariables
            )
        } catch {
            Self.recordSourceTOCFailure(error, phase: .toc)
            throw error
        }
        // An empty TOC means this source's rules matched nothing. Fail here, before the
        // commit: the sheet stays open, the origin gets flagged, and the book keeps the
        // source it already had. Committing an empty list instead left the book with no
        // chapters at all — see the same guard in `BookStore.updateOnlineBookSource`.
        guard !package.chapters.isEmpty else {
            let error = NSError(
                domain: "ReaderViewModel", code: -2,
                userInfo: [NSLocalizedDescriptionKey: localized("此來源配置取不到目錄")])
            Self.recordSourceTOCFailure(error, phase: .empty)
            throw error
        }
        cacheSearchTOC(package, forKey: key)
        Self.recordPreparedTOC(chapters: package.chapters.count, cacheHit: false)
        return package
    }

    private static func recordPreparedTOC(chapters: Int, cacheHit: Bool) {
        AppLogger.parse("ChangeSource TOC prepared cacheHit=\(cacheHit) chapters=\(chapters) taskCancelled=\(Task.isCancelled)", level: .info)
    }

    enum SourceSwitchFailurePhase: String { case prepare, commit, postCommit }

    /// The outer boundary includes cancellation and commit errors that the TOC
    /// probe deliberately omits. Fixed facts only, including sub-millisecond exits.
    static func recordSourceSwitchFailure(_ error: Error, phase: SourceSwitchFailurePhase) {
        let fields = sourceChangeFailureFields(error)
        var line = "ChangeSource switch unavailable phase=\(phase.rawValue) kind=\(fields.kind) code=\(fields.code) taskCancelled=\(Task.isCancelled) httpStatusKnown=\(fields.httpStatus != nil)"
        if let status = fields.httpStatus { line += " httpStatus=\(status)" }
        AppLogger.parse(line, level: .error)
    }

    static func recordSourceSwitchCompleted() {
        AppLogger.parse("ChangeSource switch finished outcome=completed taskCancelled=\(Task.isCancelled)", level: .info)
    }

    /// Call-site phases only: neither this label nor a runtime HTTP_ERROR proves
    /// that a network request was sent or an HTTP response was received.
    private enum SourceTOCFailurePhase: String {
        case sourceLookup, detail, toc, empty
    }

    private static let sourceTOCRuntimeCodes = [
        "HTTP_ERROR", "RULE_ERROR", "TOC_EMPTY", "SOURCE_CHANGED", "CONTEXT_MISSING",
        "CONTEXT_MISMATCH", "INVALID_RESULT", "STATE_LIMIT", "INVALID_ARGUMENT",
        "INVALID_STATE_OWNER", "INVALID_STATE_REQUEST", "STATE_IO", "STATE_CONFLICT",
        "UNSUPPORTED_CAPABILITY", "CANCELLED", "TIMEOUT", "MISSING_RUNTIME", "PAYLOAD_TOO_LARGE",
        "invalid_response", "invalid_json", "runtime_error",
    ]

    /// Fixed facts only. Never pass `error:` to AppLogger here: its funnel would
    /// append localizedDescription, including source-controlled URLs/messages.
    private static func recordSourceTOCFailure(_ error: Error, phase: SourceTOCFailurePhase) {
        let cause = SourceFailure.loggable(error)
        guard !Task.isCancelled, !(error is CancellationError), !(cause is CancellationError),
              (cause as? URLError)?.code != .cancelled else { return }
        var fields = sourceChangeFailureFields(error)
        switch phase {
        case .sourceLookup:
            fields = ("reader", "missingSource", nil)
        case .empty:
            fields = ("reader", "emptyTOC", nil)
        case .detail, .toc: break
        }
        var line = "ChangeSource TOC unavailable phase=\(phase.rawValue) kind=\(fields.kind) code=\(fields.code) httpStatusKnown=\(fields.httpStatus != nil)"
        if let status = fields.httpStatus { line += " httpStatus=\(status)" }
        AppLogger.parse(line, level: .error)
    }

    private static func sourceChangeFailureFields(_ error: Error) -> (kind: String, code: String, httpStatus: Int?) {
        let cause = SourceFailure.loggable(error)
        var kind = "other", code = "other"
        var httpStatus: Int? = nil
        if error is CancellationError || cause is CancellationError {
            kind = "task"; code = "cancelled"
        } else if let value = cause as? LegadoRuntimeError {
            kind = "runtime"
            // The runtime's code is an arbitrary String, not an enum. Emit
            // our matched literal, never its free message or unknown code.
            if value.code.utf8.prefix(41).count <= 40,
               let known = sourceTOCRuntimeCodes.first(where: { $0 == value.code }) {
                code = known
            }
        } else if let value = cause as? FetchError {
            kind = "fetch"
            switch value {
            case .noSearchURL: code = "noSearchURL"
            case .invalidURL: code = "invalidURL"
            case .httpError(let status):
                code = "httpError"
                if (100...599).contains(status) { httpStatus = status }
            case .cloudflareChallengeRequired: code = "cloudflareChallengeRequired"
            case .encodingError: code = "encodingError"
            case .emptyContent: code = "emptyContent"
            case .sourceAPIError: code = "sourceAPIError"
            case .volumeSeparator: code = "volumeSeparator"
            }
        } else if let value = cause as? URLError {
            kind = "url"
            switch value.code {
            case .cancelled: code = "cancelled"
            case .timedOut: code = "timedOut"
            case .badURL: code = "badURL"
            case .unsupportedURL: code = "unsupportedURL"
            case .cannotFindHost: code = "cannotFindHost"
            case .cannotConnectToHost: code = "cannotConnectToHost"
            case .dnsLookupFailed: code = "dnsLookupFailed"
            case .notConnectedToInternet: code = "notConnectedToInternet"
            case .networkConnectionLost: code = "networkConnectionLost"
            case .secureConnectionFailed: code = "secureConnectionFailed"
            case .badServerResponse: code = "badServerResponse"
            default: break
            }
        }
        return (kind, code, httpStatus)
    }

    /// Runs a tapped source switch as a cancellable unit, publishing the pending origin so the
    /// sheet can show progress. Legado does the same with a `WaitDialog` whose cancel listener
    /// cancels the coroutine.
    func beginSourceSwitch(
        to origin: BookOrigin,
        work: @escaping @MainActor () async -> Void
    ) {
        changeSourceSwitchTask?.cancel()
        changeSourcePendingOrigin = origin
        changeSourceSwitchTask = Task { @MainActor [weak self] in
            await work()
            guard !Task.isCancelled else { return }
            self?.finishSourceSwitch()
        }
    }

    func finishSourceSwitch() {
        changeSourceSwitchTask = nil
        changeSourcePendingOrigin = nil
    }

    func cancelPendingSourceSwitch() {
        changeSourceSwitchTask?.cancel()
        finishSourceSwitch()
    }

    /// Stops the cross-source fan-out. Called the moment a source is tapped: the search holds
    /// the connection pool and the JS bridge, and from that point it is competing with the one
    /// fetch the user is actually waiting on (Legado's `getToc` opens with `stopSearch()`).
    func stopChangeSourceSearch() {
        checkpointAndCancelChangeSourceSearch()
        tocWarmTask?.cancel()
        tocWarmTask = nil
        changeSourceLoading = false
    }

    private func checkpointAndCancelChangeSourceSearch() {
        changeSourceGeneration = UUID()
        changeSourceSearchTask?.cancel()
        changeSourceSearchTask = nil
        let oldWork = changeSourceWork
        changeSourceWork = nil
        if let oldWork {
            let previous = changeSourceCheckpointTask
            changeSourceCheckpointTask = Task.detached(priority: .utility) {
                await previous?.value
                await oldWork.checkpoint()
            }
        }
    }

    private func cacheSearchTOC(_ package: TOCPackage, forKey key: String) {
        // Never cache an empty TOC: `prepareTOCPackage` returns cache hits verbatim, so one
        // stored here would slip past its empty-TOC guard on every later tap.
        guard !package.chapters.isEmpty else { return }
        guard !key.isEmpty, searchTOCCache[key] == nil else { return }
        guard searchTOCChapterCount < Self.searchTOCChapterLimit else { return }
        searchTOCChapterCount += package.chapters.count
        searchTOCCache[key] = package
    }

    /// Fills `searchTOCCache` for the found candidates when 搜索時載入目錄 is on, so tapping one
    /// switches with no network wait.
    ///
    /// Legado fetches each TOC inline inside that source's search coroutine, which makes the
    /// result list itself appear slowly. Warming after the list is already sorted keeps the
    /// list fast and still has most TOCs ready by the time a source is picked; a tap that
    /// lands first simply fetches normally through `prepareTOCPackage`.
    private func warmSearchTOCCacheIfEnabled() {
        guard GlobalSettings.shared.changeSourceLoadToc, let work = changeSourceWork else { return }
        tocWarmTask?.cancel()
        let generation = changeSourceGeneration
        let failedKeys = changeSourceFailedKeys
        let sources = BookSourceStore.shared.sources
        let cached = searchTOCCache
        let fetcher = bookSourceFetcher
        tocWarmTask = Task { @MainActor [weak self] in
            let jobs = await work.warmJobs(sources: sources, failedKeys: failedKeys, cached: cached)
            guard let self, !Task.isCancelled, self.changeSourceGeneration == generation, !jobs.isEmpty else { return }
            await withTaskGroup(of: (String, TOCPackage)?.self) { group in
                var next = 0
                // Bounded window: the warm-up must stay in the background of whatever the
                // user does next, not saturate the pool the way the fan-out does.
                let active = min(4, jobs.count)

                func enqueue() {
                    guard next < jobs.count else { return }
                    let (key, origin, source) = jobs[next]
                    next += 1
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        do {
                            let package = try await fetcher.fetchTOCPackage(tocUrl: origin.tocUrl,
                                source: source, runtimeVariables: origin.runtimeVariables)
                            return (key, package)
                        } catch is CancellationError { return nil }
                        catch let error as URLError where error.code == .cancelled { return nil }
                        catch {
                            AppLogger.parse("ChangeSource TOC warm failed type=\(String(reflecting: type(of: error)))")
                            return nil
                        }
                    }
                }

                for _ in 0..<active { enqueue() }
                while let result = await group.next() {
                    if Task.isCancelled || self.changeSourceGeneration != generation { group.cancelAll(); break }
                    if let (key, package) = result {
                        self.cacheSearchTOC(package, forKey: key)
                    }
                    enqueue()
                }
            }
        }
    }

    /// Reports an error from a source change operation.
    func reportChangeSourceError(_ message: String?) {
        changeSourceError = message
    }

    /// Flags an origin that failed to switch (its TOC fetch threw), persisting the
    /// flag so it stays marked across reopen/re-search of the same book.
    func markOriginFailed(bookId: UUID, sourceId: UUID, bookUrl: String) {
        let key = ChangeSourceCache.originKey(sourceId: sourceId, bookUrl: bookUrl)
        guard !key.isEmpty else { return }
        changeSourceFailedKeys.insert(key)
        ChangeSourceCache.shared.markFailed(originKey: key, for: bookId)
    }

    /// Drops an origin's failure flag once it has switched successfully, so the row stops
    /// showing 載入失敗. `markFailed` only ever appended, so without this a source that
    /// failed once stayed badged for good — the flag is persisted, so even relaunching
    /// kept it.
    func clearOriginFailure(bookId: UUID, sourceId: UUID, bookUrl: String) {
        let key = ChangeSourceCache.originKey(sourceId: sourceId, bookUrl: bookUrl)
        let legacyKey = ChangeSourceCache.urlKey(bookUrl)
        guard !key.isEmpty else { return }
        changeSourceFailedKeys.remove(key)
        changeSourceFailedKeys.remove(legacyKey)
        ChangeSourceCache.shared.clearFailure(originKeys: [key, legacyKey], for: bookId)
    }

    /// Searches one source with a timeout, off the main actor. Returns nil on error
    /// or timeout so a slow/hung source can't stall the whole 換源 search.
    /// `nonisolated` so concurrent tasks don't serialize back onto the MainActor.
    // MARK: - Private

    /// Reads an already-validated cached package off the main presentation path. Besides the
    /// one-shot media probe, each cached text chapter is inspected until paragraph-review
    /// capability is found. `ChapterFetching` returns the existing package here; no network
    /// fallback is introduced because this method is called only after `isChapterCached`.
    private func inspectCachedChapter(
        book: ReadingBook,
        chapterIndex: Int,
        store: BookStore?
    ) {
        let inspectionKey = CachedChapterInspectionKey(
            bookId: book.id,
            chapterIndex: chapterIndex
        )
        let shouldInspectParagraphReviews = !hasParagraphReviews
            && paragraphReviewInspectionAttempted.insert(inspectionKey).inserted
        let shouldDetectMedia = book.isOnline
            && book.contentPipelineKind != .manga
            && store != nil
            && mangaDetectionAttempted.insert(book.id).inserted

        guard shouldInspectParagraphReviews || shouldDetectMedia else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let package = await self.chapterFetcher.cachedChapterPackage(
                book: book, chapterIndex: chapterIndex),
                  !package.content.isEmpty
            else { return }

            if shouldInspectParagraphReviews {
                self.recordParagraphReviewsIfPresent(in: package.content)
            }
            if shouldDetectMedia, let store,
               !store.upgradeToMangaIfDetected(bookId: book.id, content: package.content) {
                store.upgradeToAudioIfDetected(bookId: book.id, content: package.content)
            }
        }
    }

    /// Links are a string search, so they are checked here. A bubble without one takes
    /// decoding the chapter's SVGs until one is recognized, which is off the main actor.
    private func recordParagraphReviewsIfPresent(in content: String) {
        guard !hasParagraphReviews else { return }
        if ReaderHTMLUtilities.containsParagraphReviewLinks(in: content) {
            hasParagraphReviews = true
            return
        }
        guard content.range(of: "data:image/svg+xml", options: .caseInsensitive) != nil else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard CommentBubbleSVGRecognizer.containsRecognizedBubble(inChapterHTML: content) else { return }
            await MainActor.run { self?.hasParagraphReviews = true }
        }
    }

    private func setChapterState(
        _ state: ChapterLoadState,
        for chapterIndex: Int,
        contentAvailable: Bool
    ) {
        if contentAvailable {
            availableChapterIndexes.insert(chapterIndex)
        } else {
            availableChapterIndexes.remove(chapterIndex)
        }
        let previous = chapterStates[chapterIndex]
        chapterStates[chapterIndex] = state
        recordChapterStateTransition(
            from: previous, to: state, chapter: chapterIndex, contentAvailable: contentAvailable
        )
    }

    /// The chapter-supply story, in the log.
    ///
    /// Every long-running complaint in this area — 無限加載中, 莫名其妙章節載入失敗,
    /// 鎖屏聽書停止 — was a question about which state a chapter ended up in and how it
    /// got there (`Technotes/ReaderChapterSupply.md`). That was only answerable with a
    /// Mac attached. This is the single funnel every state change passes through.
    private func recordChapterStateTransition(
        from previous: ChapterLoadState?,
        to state: ChapterLoadState,
        chapter: Int,
        contentAvailable: Bool
    ) {
        guard previous != state else { return }
        let severity: DiagnosticSeverity
        switch state {
        case .failed:    severity = .error
        case .cancelled: severity = .notice
        default:         severity = .trace
        }
        AppLogger.render(
            "⟐ chapterState ch=\(chapter) \(previous.map { "\($0)" } ?? "nil") → \(state) content=\(contentAvailable)",
            level: severity
        )
        // A chapter that finally arrived is no longer retrying, so its history must not
        // carry into an unrelated later failure.
        if state == .ready, contentAvailable {
            ChapterRetryLog.noteSuccess(chapter: chapter, bookId: currentBookId)
        }
    }

    private func startFetchTask(
        book: ReadingBook,
        chapterIndex: Int,
        priority: ChapterFetchPriority,
        store: BookStore?,
        token: UUID
    ) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            do {
                let package = try await self.chapterFetcher.fetchChapter(
                    book: book,
                    chapterIndex: chapterIndex,
                    priority: priority,
                    store: store
                )
                guard !Task.isCancelled else {
                    self.clearInFlight(chapterIndex: chapterIndex, token: token)
                    return
                }
                let result: ChapterLoadState = package.state == .cached && !package.content.isEmpty
                    ? .ready
                    : .failed(reason: package.failureReason ?? "empty")
                if case .ready = result {
                    self.recordParagraphReviewsIfPresent(in: package.content)
                }
                if case .ready = result, let store {
                    // Aggregation sources serve manga under a text (type-0) source; once the
                    // first chapter comes back as an image list, flip the book to the manga
                    // reader. `BookReaderView` swaps reactively.
                    #if DEBUG
                    if book.isOnline {
                        let imgs = MangaChapterParser.imageURLs(from: package.content)
                        let head = package.content.prefix(600)
                            .replacingOccurrences(of: "\n", with: "⏎")
                        print("[MangaDetect] ch=\(chapterIndex) len=\(package.content.count) imgURLs=\(imgs.count) looksManga=\(MangaChapterParser.looksLikeMangaContent(package.content)) looksAudio=\(DirectChapterAudioResolver.looksLikeAudioContent(package.content)) audioURL=\(DirectChapterAudioResolver.request(from: package.content)?.url?.absoluteString ?? "nil") head=\(head)")
                    }
                    #endif
                    if !store.upgradeToMangaIfDetected(bookId: book.id, content: package.content) {
                        store.upgradeToAudioIfDetected(bookId: book.id, content: package.content)
                    }
                }
                self.finishFetch(chapterIndex: chapterIndex, token: token, result: result)
            } catch {
                // Cancellation is not a verdict on the chapter, and it arrives in more than
                // one shape: `CancellationError` thrown directly, and `URLError.cancelled`
                // (-999) from a URLSession or WKWebView navigation torn down mid-flight.
                // Only the first was recognised, so the second reached the catch-all below
                // and surfaced as 章節載入失敗 on a chapter that fetched fine the moment it
                // was asked again — the failure users worked around by refreshing.
                if Self.isCancellation(error) || Task.isCancelled {
                    self.clearInFlight(chapterIndex: chapterIndex, token: token)
                    return
                }
                // os_log, not print: this is the end of the online chapter pipeline,
                // and on a device it's the only record of *why* a chapter failed.
                AppLogger.parse("⟐ chapter fetch failed", error: error, context: [
                    "chapter": chapterIndex,
                    "book": book.title,
                    "online": book.isOnline
                ])
                self.finishFetch(
                    chapterIndex: chapterIndex,
                    token: token,
                    result: .failed(reason: error.localizedDescription)
                )
            }
        }
    }

    private func finishFetch(
        chapterIndex: Int,
        token: UUID,
        result: ChapterLoadState
    ) {
        guard inFlightRequests[chapterIndex]?.token == token else { return }
        inFlightRequests.removeValue(forKey: chapterIndex)
        setChapterState(result, for: chapterIndex, contentAvailable: result == .ready)
    }

    /// Errors that mean "this request was torn down", not "this chapter cannot be read".
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    private func clearInFlight(chapterIndex: Int, token: UUID) {
        guard inFlightRequests[chapterIndex]?.token == token else { return }
        inFlightRequests.removeValue(forKey: chapterIndex)
        if chapterStates[chapterIndex] == .loading {
            // `.idle` reads as "never asked" and had nothing driving a retry, so a preempted
            // chapter sat on the loading surface forever. `.cancelled` says a re-request is
            // owed; `handleChapterStateChanges` issues it.
            setChapterState(.cancelled, for: chapterIndex, contentAvailable: false)
        }
    }
}

/// Ephemeral work for one reader search. Only immutable snapshots cross back
/// to MainActor; the source-sized index, sorting and cache work stay here.
private actor ReaderSourceChangeWork {
    struct Prepared {
        let sources: [BookSource]
        let displayOrigins: [BookOrigin]
        let canEndSearch: Bool
        let failedKeys: Set<String>
    }

    private var order: BookSourceSearchOrder?
    private var origins: [BookOrigin] = []
    private var seenOriginKeys: Set<String> = []
    private var acceptedAttempts: [UUID: BookOriginSearchAttempt.Outcome] = [:]
    private var context: ChangeSourceCache.SearchContext?
    private var bookID: UUID?
    private var excludedOriginKey = ""
    private var cacheDays = 0
    private var timestamp = Date()
    private var hasNewAttempts = false
    private var completed = false

    func prepare(sources snapshot: [BookSource], bookId: UUID, title: String, author: String, cacheDays: Int,
        excludingOriginKey: String, forceRefresh: Bool) async -> Prepared {
        let started = SourcePerfTrace.now
        defer { SourcePerfTrace.record("changeSource.prepare", "sources=\(snapshot.count) main=\(Thread.isMainThread)", since: started) }
        let sources = snapshot.filter(\.enabled)
        let order = BookSourceSearchOrder(sources: sources)
        self.order = order
        self.bookID = bookId
        self.excludedOriginKey = excludingOriginKey
        self.cacheDays = cacheDays
        if cacheDays > 0, order.sourceIDs.count == sources.count {
            do {
                context = try ChangeSourceCache.SearchContext.make(title: title, author: author,
                    sources: sources, excludingOriginKey: excludingOriginKey)
            } catch is CancellationError {
                return Prepared(sources: sources, displayOrigins: [], canEndSearch: false, failedKeys: [])
            } catch {
                // An unencodable configuration cannot authorize reuse. The same
                // normal search still runs, with the general search cache bypassed.
                AppLogger.cache("ChangeSource context unavailable type=\(String(reflecting: type(of: error)))")
            }
        }
        let cached = await ChangeSourceCache.shared.readForSearch(for: bookId, days: cacheDays,
            sourceIDs: order.sourceIDs, excludingOriginKey: excludingOriginKey,
            allowCached: !forceRefresh && context != nil, context: context)
        origins = order.ordered(cached.displayOrigins)
        seenOriginKeys = Set(origins.map { ChangeSourceCache.originKey(sourceId: $0.sourceId, bookUrl: $0.bookUrl) })
        acceptedAttempts = cached.acceptedAttempts
        timestamp = cached.timestamp ?? Date()
        completed = cached.canEndSearch
        return Prepared(sources: sources.filter { acceptedAttempts[$0.id] == nil },
            displayOrigins: origins, canEndSearch: cached.canEndSearch, failedKeys: cached.failedKeys)
    }

    func accept(_ attempt: BookOriginSearchAttempt) -> [BookOrigin]? {
        let started = SourcePerfTrace.now
        defer { SourcePerfTrace.record("changeSource.order", "origins=\(origins.count) batch=\(attempt.origins.count) main=\(Thread.isMainThread)", since: started) }
        guard !Task.isCancelled, let order, order.includes(attempt.sourceID), acceptedAttempts[attempt.sourceID] == nil,
              attempt.origins.allSatisfy({ $0.sourceId == attempt.sourceID }) else { return nil }
        // No await between adding this source's results and its finished fact.
        // A checkpoint sees both or neither; preview references stay verbatim.
        let added = attempt.origins.filter {
            seenOriginKeys.insert(ChangeSourceCache.originKey(sourceId: $0.sourceId, bookUrl: $0.bookUrl)).inserted
        }
        origins.append(contentsOf: added)
        acceptedAttempts[attempt.sourceID] = attempt.outcome
        // Only actual new search progress advances freshness. Merely reopening
        // or closing the same partial snapshot never extends its five minutes.
        timestamp = Date()
        hasNewAttempts = true
        guard !added.isEmpty else { return nil }
        origins = order.ordered(origins)
        return origins
    }

    func storeCompleted(coverage: BookOriginSearchCoverage) async {
        guard !Task.isCancelled, coverage.completedAllAttempts, let order, let bookId = bookID,
              Set(acceptedAttempts.keys) == order.sourceIDs else { return }
        guard cacheDays > 0, let context else { completed = true; return }
        let combined = ChangeSourceCache.coverage(sourceIDs: order.sourceIDs, attempts: acceptedAttempts, completed: true)
        await ChangeSourceCache.shared.storeCompleted(origins: origins, for: bookId,
            sourceIDs: order.sourceIDs, excludingOriginKey: excludedOriginKey, coverage: combined,
            context: context, acceptedAttempts: acceptedAttempts)
        if !Task.isCancelled { completed = true }
    }

    func checkpoint() async {
        guard cacheDays > 0, !completed, hasNewAttempts, let order, let context, let bookId = bookID else { return }
        await ChangeSourceCache.shared.storePartial(origins: origins, for: bookId,
            sourceIDs: order.sourceIDs, excludingOriginKey: excludedOriginKey, context: context,
            acceptedAttempts: acceptedAttempts, timestamp: timestamp)
    }

    func warmJobs(sources: [BookSource], failedKeys: Set<String>, cached: [String: TOCPackage]) -> [(String, BookOrigin, BookSource)] {
        SourcePerfTrace.span("changeSource.toc.prepare", "sources=\(sources.count) origins=\(origins.count) main=\(Thread.isMainThread)") {
            var byID: [UUID: BookSource] = [:]
            for source in sources where byID[source.id] == nil { byID[source.id] = source }
            return origins.compactMap { origin in
                let key = ChangeSourceCache.originKey(sourceId: origin.sourceId, bookUrl: origin.bookUrl)
                guard cached[key] == nil, !failedKeys.contains(key),
                      !failedKeys.contains(ChangeSourceCache.urlKey(origin.bookUrl)),
                      let source = byID[origin.sourceId] else { return nil }
                return (key, origin, source)
            }
        }
    }
}
