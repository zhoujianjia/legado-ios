import Foundation
import LegadoRuntime

/// Explicit embedding APIs for the retained original business implementation. Product
/// route selection is deliberately separate: existing search/detail/reader calls retain
/// their current engine. A caller must carry the returned context to the next operation.
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
