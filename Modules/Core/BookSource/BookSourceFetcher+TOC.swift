import Foundation

// MARK: - Fetch TOC

extension BookSourceFetcher {

    /// Private metadata carried with the first chapter so content JS receives
    /// Legado's `nextChapterUrl` binding without changing the public TOC model.
    static let nextChapterRuntimeVariableKey = "__legado.nextChapterUrl"

    private func normalizedChaptersWithNextURL(
        _ chapters: [OnlineChapterRef]
    ) -> [OnlineChapterRef] {
        chapters.enumerated().map { index, ref in
            var normalized = ref
            normalized.index = index
            if chapters.indices.contains(index + 1) {
                var variables = normalized.runtimeVariables ?? [:]
                variables[Self.nextChapterRuntimeVariableKey] = chapters[index + 1].url
                normalized.runtimeVariables = variables
            }
            return normalized
        }
    }

    /// Fetch TOC for source validation. Legado's checker calls `getChapterListAwait`
    /// with its default `runPerJs = false`, so validation must not execute
    /// `ruleToc.preUpdateJs` or open a WebView for it.
    func fetchTOC(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) async throws -> [OnlineChapterRef] {
        let package = try await fetchTOCPackage(
            tocUrl: tocUrl,
            source: source,
            runtimeVariables: runtimeVariables,
            runPreUpdateJs: false
        )
        return package.chapters
    }

    /// - Parameter forceRefresh: when `true`, the on-disk TOC cache is ignored and
    ///   the table of contents is always re-fetched from the network. Used by the
    ///   "update online books" path (launch / foreground / pull-to-refresh) so that
    ///   serial novels actually pick up newly-published chapters instead of replaying
    ///   the stale cached list. Normal reading paths leave it `false` for speed.
    /// Cached TOC for this URL if a usable one is on disk (same validity rules
    /// as `fetchTOCPackage`'s fast path). Lets UI layers render a previously
    /// fetched chapter list instantly while fresh data loads.
    func cachedTOCPackage(tocUrl: String, source: BookSource) -> TOCPackage? {
        // Legacy TOC cache entries are display data, not original entity leases.
        // The existing shelf/chapter cache remains available for offline reading.
        nil
    }

    func fetchTOCPackage(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil,
        onFirstPageReady: ((_ chapters: [OnlineChapterRef]) -> Void)? = nil,
        forceRefresh: Bool = false,
        runPreUpdateJs: Bool = true
    ) async throws -> TOCPackage {
        if source.isJsSource {
            let package = try await mainJSService.toc(url: tocUrl, source: source, runtimeVariables: runtimeVariables)
            if !package.chapters.isEmpty { onFirstPageReady?(package.chapters) }
            return package
        }
        let package = try await mainJSService.originalTOC(url: tocUrl, source: source,
            runtimeVariables: runtimeVariables, runPreUpdateJS: runPreUpdateJs)
        if !package.chapters.isEmpty { onFirstPageReady?(package.chapters) }
        return package
    }
}
