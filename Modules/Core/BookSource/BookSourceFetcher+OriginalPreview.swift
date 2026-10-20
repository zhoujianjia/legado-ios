import Foundation

/// Explicit embedding APIs for the retained original business implementation. Product
/// route selection is deliberately separate: existing search/detail/reader calls retain
/// their current engine. A caller must carry the returned context to the next operation.
extension BookSourceFetcher {
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
