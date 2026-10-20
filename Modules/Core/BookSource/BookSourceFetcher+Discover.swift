import Foundation
import LegadoRuntime

extension BookSourceFetcher {
    func discoverItems(page: Int = 1, in source: BookSource) async -> [ModernParserBridge.DiscoverItem] {
        await discoverItems(page: page, in: source, variableOverlay: [:])
    }

    func discoverItems(page: Int = 1, in source: BookSource,
                       variableOverlay: [String: String]) async -> [ModernParserBridge.DiscoverItem] {
        do { return try await discoverItemsOriginal(page: page, in: source, variableOverlay: variableOverlay) }
        catch { AppLogger.error("Original explore categories did not load", error: error); return [] }
    }

    /// Pure DTO decoding follows execution in the sole retained runtime. Nothing
    /// here runs old JSC to evaluate source expressions or issue network requests.
    func discoverItemsOriginal(page: Int = 1, in source: BookSource,
                               variableOverlay: [String: String] = [:]) async throws -> [ModernParserBridge.DiscoverItem] {
        guard source.enabledExplore else { return [] }
        let raw = source.exploreUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [] }
        guard variableOverlay.isEmpty else { throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY",
            message: "Original explore source-variable overlays need an explicit scoped original contract") }
        let result: String
        if ModernParserBridge.isJSExploreRule(raw) {
            let script = ModernParserBridge.jsCode(fromExploreRule: raw)
            if source.isJsSource {
                result = try await mainJSService.evaluateMainJSExplore(script: script, page: page, source: source)
            } else {
                _ = try await mainJSService.openOriginalExploreContext(source: source)
                result = try await mainJSService.evaluateOriginalExploreContext(script: "var page = \(page);\n" + script, source: source).result ?? ""
            }
        } else {
            if !source.isJsSource { _ = try await mainJSService.openOriginalExploreContext(source: source) }
            result = raw
        }
        return try await SourcePerfTrace.spanAsync("legado.original.explore.categories",
            "main=\(Thread.isMainThread) bytes=\(result.utf8.count)") {
            try Self.decodeOriginalExploreKinds(result)
        }
    }

    static func decodeOriginalExploreKinds(_ raw: String) throws -> [ModernParserBridge.DiscoverItem] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 1_048_576 else { throw LegadoRuntimeError(code: "STATE_LIMIT", message: "Explore categories exceed their byte budget") }
        if text.hasPrefix("[") { return try JSONDecoder().decode([ModernParserBridge.DiscoverItem].self, from: Data(text.utf8)) }
        if text.hasPrefix("{") { return [try JSONDecoder().decode(ModernParserBridge.DiscoverItem.self, from: Data(text.utf8))] }
        return text.replacingOccurrences(of: #"(&&|\r?\n)+"#, with: "\n", options: .regularExpression)
            .split(separator: "\n").compactMap { line in
                let entry = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !entry.isEmpty else { return nil }
                if let split = entry.range(of: "::") {
                    let title = String(entry[..<split.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let url = String(entry[split.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty, !ModernParserBridge.containsHTMLTag(title) else { return nil }
                    return .init(title: title, url: url.isEmpty ? nil : url)
                }
                return ModernParserBridge.containsHTMLTag(entry) ? nil : .init(title: entry)
            }
    }

    /// Original AnalyzeUrl owns request cookies. A page load must not prime or
    /// remove tokens by entering another parser/HTTP session.
    func primeDiscoverCookies(in source: BookSource) async {}

    func discoverBooks(from item: ModernParserBridge.DiscoverItem, page: Int = 1,
                       in source: BookSource) async throws -> [OnlineBook] {
        guard let url = item.url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        if source.isJsSource { return try await mainJSService.explore(url: url, page: page, source: source) }
        guard let originalPage = Int32(exactly: page), originalPage > 0 else {
            throw LegadoRuntimeError(code: "INVALID_REQUEST", message: "Explore page exceeds the original Int range")
        }
        return try await mainJSService.originalExplore(url: url, page: originalPage, source: source)
    }
}
