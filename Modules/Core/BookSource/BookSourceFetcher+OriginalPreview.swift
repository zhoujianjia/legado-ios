import Foundation
import LegadoRuntime

/// The retained original business entry points and explicit owner handoff used by
/// public search/detail/TOC consumers. Context references identify preview state;
/// only the real library/chapter owners authorize durable reading content.
extension BookSourceFetcher {
    func exploreOriginalPreview(url: String, page: Int32? = 1, source: BookSource) async throws -> [OnlineBook] {
        try await mainJSService.originalExplore(url: url, page: page, source: source)
    }
    func openOriginalExploreContext(source: BookSource) async throws -> LegadoOriginalExploreContextResult {
        try await mainJSService.openOriginalExploreContext(source: source)
    }
    func evaluateOriginalExploreContext(script: String, source: BookSource) async throws -> LegadoOriginalExploreContextResult {
        try await mainJSService.evaluateOriginalExploreContext(script: script, source: source)
    }
    func savePendingOriginalExploreContext(source: BookSource) async throws -> LegadoOriginalExploreContextResult {
        try await mainJSService.savePendingOriginalExploreContext(source: source)
    }

    /// One stored task for this existing DI fetcher. Repeated inactive/background
    /// signals queue another sweep after the one in flight, so a late dirty source
    /// is not lost and no scene callback blocks the main thread or creates a VM.
    @MainActor
    func noteOriginalExploreAppPause() {
        originalExplorePauseRequested = true
        guard originalExplorePauseTask == nil else { return }
        let hold = BackgroundTaskHold(name: "legado.explore.pause")
        originalExplorePauseTask = Task { @MainActor [self] in
            defer { hold.release(); originalExplorePauseTask = nil }
            while originalExplorePauseRequested {
                originalExplorePauseRequested = false
                do {
                    let report = try await mainJSService.savePendingOriginalExploreContexts()
                    if !report.failures.isEmpty {
                        AppLogger.cache("Original exploration pause retained failed source saves", context: [
                            "acknowledged": report.acknowledgedSourceIDs.count, "failed": report.failures.count
                        ])
                    }
                } catch {
                    AppLogger.error("Original exploration pause did not finish", error: error)
                    if Task.isCancelled { break }
                }
            }
        }
    }

    func searchOriginalPreview(query: String, page: Int32? = 1, source: BookSource) async throws -> [OnlineBook] {
        try await mainJSService.originalSearch(query: query, page: page, source: source)
    }
    func fetchOriginalPreviewBookInfo(url: String, source: BookSource,
                                      runtimeVariables: [String: String]?, knownBook: OnlineBook? = nil) async throws -> BookInfoPackage {
        try await mainJSService.originalDetails(url: url, source: source, runtimeVariables: runtimeVariables, knownBook: knownBook)
    }
    func fetchOriginalPreviewTOC(url: String, source: BookSource, runtimeVariables: [String: String]?,
                                 runPreUpdateJS: Bool = false) async throws -> TOCPackage {
        try await mainJSService.originalTOC(url: url, source: source, runtimeVariables: runtimeVariables, runPreUpdateJS: runPreUpdateJS)
    }
    func fetchOriginalPreviewContent(ref: OnlineChapterRef, source: BookSource) async throws -> String {
        try await mainJSService.originalContent(ref: ref, source: source)
    }
    func transferOriginalPreview(source: BookSource, runtimeVariables: [String: String]?,
                                 to store: BookStore, bookID: UUID) async throws -> LegadoOriginalPreviewTransferReceipt {
        try await mainJSService.transferOriginalPreview(source: source, runtimeVariables: runtimeVariables, to: store, bookID: bookID)
    }
    func revokeOriginalPreview(source: BookSource, runtimeVariables: [String: String]?) async throws {
        try await mainJSService.revokeOriginalPreview(source: source, runtimeVariables: runtimeVariables)
    }
}

/// Context identifiers are presentation references, not original book/chapter
/// variables. Adoption keeps business values and all existing UUID/cache fields.
enum OriginalBookAdoption {
    struct Projection: Sendable { let variables: [String: String]?; let chapters: [OnlineChapterRef] }
    nonisolated static func prepare(_ input: [String: String]?, chapters: [OnlineChapterRef]) async -> Projection {
        await Task.detached(priority: .userInitiated) {
            SourcePerfTrace.span("legado.original.adopt", "main=\(Thread.isMainThread) chapters=\(chapters.count)") {
                Projection(variables: variables(input), chapters: Self.chapters(chapters))
            }
        }.value
    }
    static func variables(_ input: [String: String]?) -> [String: String]? {
        guard let input else { return nil }
        return input.filter { $0.key != LegadoMainJSSourceService.originalPreviewContextKey }
    }
    static func chapters(_ input: [OnlineChapterRef]) -> [OnlineChapterRef] {
        input.map { original in var value = original; value.runtimeVariables = variables(original.runtimeVariables); return value }
    }
}

extension BookSourceFetching {
    /// A stored book supplies its actual current chapter projection to an
    /// isolated metadata preview. This grants neither a cache writer nor an App
    /// UUID; its normal BookStore commit and explicit transfer still own adoption.
    func prepareOriginalStoredBookPreview(source: BookSource, knownBook: OnlineBook,
                                         chapters: [OnlineChapterRef]) async throws -> [String: String]? {
        guard !source.isJsSource, let live = self as? LiveBookSourceFetcher else { return knownBook.runtimeVariables }
        return try await live.bookSourceFetcher.mainJSService.prepareOriginalBookPreview(url: knownBook.bookUrl,
            source: source, runtimeVariables: knownBook.runtimeVariables, knownBook: knownBook, storedChapters: chapters)
    }

    /// The live dependency forwards to the same existing concrete fetcher. A
    /// presentation/mock dependency cannot synthesize an original App handoff.
    func transferOriginalPreview(source: BookSource, runtimeVariables: [String: String]?,
                                 to store: BookStore, bookID: UUID) async throws -> LegadoOriginalPreviewTransferReceipt {
        guard let live = self as? LiveBookSourceFetcher else {
            throw LegadoRuntimeError(code: "INVALID_STATE_OWNER", message: "Preview handoff needs the existing live source dependency")
        }
        return try await live.bookSourceFetcher.transferOriginalPreview(source: source,
            runtimeVariables: runtimeVariables, to: store, bookID: bookID)
    }
}
