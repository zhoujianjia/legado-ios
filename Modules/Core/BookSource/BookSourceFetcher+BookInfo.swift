import Foundation

// MARK: - Fetch Book Details

extension BookSourceFetcher {

    func fetchBookInfo(
        url: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil,
        knownBook: OnlineBook? = nil
    ) async throws -> OnlineBook {
        let package = try await fetchBookInfoPackage(
            url: url,
            source: source,
            runtimeVariables: runtimeVariables,
            knownBook: knownBook
        )
        return package.onlineBook
    }

    /// - Parameter knownBook: the book as the search/discover stage knew it, when the caller came
    ///   from there. Detail rules routinely omit fields the search result already carried — 431 of
    ///   1912 real sources have an empty `ruleBookInfo.name` — and legado's `analyzeBookInfo`
    ///   updates the book it was handed rather than building a new one. Passing it here reproduces
    ///   that contract; see `BookInfoPackage.merging(searchResult:canReName:)`.
    func fetchBookInfoPackage(
        url: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil,
        knownBook: OnlineBook? = nil
    ) async throws -> BookInfoPackage {
        if source.isJsSource {
            return try await mainJSService.details(url: url, source: source,
                runtimeVariables: runtimeVariables, knownBook: knownBook)
        }
        // Old HTML/parser packages contain no current original entity ownership.
        // Retained previews are read by their actor; they are never reconstructed
        // from a cached legacy DTO or used as a BookStore body grant.
        let variables = try await mainJSService.prepareOriginalBookPreview(
            url: url, source: source, runtimeVariables: runtimeVariables, knownBook: knownBook)
        return try await mainJSService.originalDetails(url: url, source: source,
            runtimeVariables: variables, knownBook: knownBook)
    }
}
