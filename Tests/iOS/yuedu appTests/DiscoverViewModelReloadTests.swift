import Foundation
import LegadoRuntime
import Testing
@testable import yuedu_app

/// Characterization tests (unified library, Phase 0a) for `DiscoverViewModel.reload`.
///
/// The cache path runs without network: the category list is stored in
/// `DiscoverKindsCache.shared` first, under the key `reload()` computes for a source with
/// no runtime variable. Entries use fixed keys under `phase0-discover.test`, so a rerun
/// overwrites them instead of adding more.
///
/// The existing injected fetcher owns context open/save on cache hits too. These
/// characterization fixtures replace only the native invocation boundary; actual
/// JNI/loopback coverage remains in LegadoNativeOriginalReaderTests.
@MainActor
@Suite("Discover reload (characterization)", .serialized)
struct DiscoverViewModelReloadTests {
    @Test("a cached category list becomes the page's categories, sections and page links")
    func cachedCategoriesBuildThePage() async throws {
        let source = makeSource("cached", exploreEnabled: true)
        let hot = item("熱門", path: "hot")
        let raw: [ModernParserBridge.DiscoverItem] = [
            .init(title: "☆ 排行榜 ☆", url: ""),
            hot,
            item("新書", path: "new"),
            hot,
            .init(title: "官網", url: "java.startBrowser('https://phase0-discover.test/site','官網')"),
        ]
        DiscoverKindsCache.shared.store(raw, forKey: cacheKey(for: source))

        let executor = ReloadExploreExecutor()
        let model = model(source: source, executor: executor)
        await model.reload()?.value

        #expect(await executor.openCount() == 1, "Cached categories must open the original context before publication")
        #expect(model.rawItems.count == raw.count)
        // The label is not a category; the repeated 熱門 is one category; the page link
        // is an item but not a section.
        #expect(model.items.map(\.title) == ["熱門", "新書", "熱門", "官網"])
        #expect(model.sections.map(\.title) == ["熱門", "新書"])
        #expect(model.sections.allSatisfy { $0.phase == .idle && $0.books.isEmpty })
        #expect(model.pageItems.map(\.title) == ["官網"])
        #expect(model.filters.isEmpty)
        #expect(model.sourceNotice == nil)
    }

    @Test("a reload maps fresh items, so every section starts anew")
    func reloadStartsSectionsAnew() async throws {
        let source = makeSource("fresh-sections", exploreEnabled: true)
        DiscoverKindsCache.shared.store([item("熱門", path: "hot")], forKey: cacheKey(for: source))

        let executor = ReloadExploreExecutor()
        let model = model(source: source, executor: executor)
        await model.reload()?.value
        let firstID = try #require(model.sections.first?.id)

        await model.reload()?.value

        #expect(model.sections.map(\.title) == ["熱門"])
        #expect(model.sections.first?.id != firstID)
    }

    @Test("with explore off, reload ends with an empty page and no notice")
    func exploreOffGivesAnEmptyPage() async throws {
        let source = makeSource("explore-off", exploreEnabled: false)

        let executor = ReloadExploreExecutor()
        let model = model(source: source, executor: executor)
        await model.reload()?.value

        #expect(model.rawItems.isEmpty)
        #expect(model.items.isEmpty)
        #expect(model.sections.isEmpty)
        #expect(model.sourceNotice == nil)
    }

    @Test("with no selected source, reload clears the page at once")
    func noSelectedSourceClears() {
        let model = DiscoverViewModel(source: makeSource("cleared", exploreEnabled: true))
        model.selectedSourceId = nil

        model.reload()

        #expect(model.items.isEmpty)
        #expect(model.sections.isEmpty)
        #expect(model.rawItems.isEmpty)
        #expect(model.filters.isEmpty)
        #expect(!model.isLoadingItems)
    }

    @Test("a failed original context open cannot publish a valid cached categories list")
    func failedContextOpenDoesNotPublishCachedCategories() async throws {
        let source = makeSource("failed-open", exploreEnabled: true)
        DiscoverKindsCache.shared.store([item("Cached", path: "hot")], forKey: cacheKey(for: source))
        let executor = ReloadExploreExecutor(failOpen: true)
        let model = model(source: source, executor: executor)
        let load = try #require(model.reload())
        await load.value
        #expect(await executor.openCount() == 1)
        #expect(!model.isLoadingItems)
        #expect(model.items.isEmpty && model.rawItems.isEmpty && model.sections.isEmpty)
        #expect(DiscoverKindsCache.shared.items(forKey: cacheKey(for: source))?.count == 1)
    }

    // MARK: - Helpers

    private func model(source: BookSource, executor: ReloadExploreExecutor) -> DiscoverViewModel {
        DiscoverViewModel(source: source,
            fetcher: BookSourceFetcher(mainJSService: LegadoMainJSSourceService(originalExecutor: executor)),
            sourceResolver: { $0 == source.id ? source : nil })
    }


    private func makeSource(_ name: String, exploreEnabled: Bool) -> BookSource {
        var source = BookSource()
        source.bookSourceName = "Phase 0 \(name)"
        source.bookSourceUrl = "https://phase0-discover.test/\(name)"
        source.enabledExplore = exploreEnabled
        source.exploreUrl = exploreEnabled ? "https://phase0-discover.test/\(name)/explore" : ""
        return source
    }

    private func item(_ title: String, path: String) -> ModernParserBridge.DiscoverItem {
        .init(title: title, url: "https://phase0-discover.test/category/\(path)/{{page}}")
    }

    /// The key `reload()` uses for a source that has no runtime variable.
    private func cacheKey(for source: BookSource) -> String {
        DiscoverKindsCache.key(sourceUrl: source.bookSourceUrl, exploreUrl: source.exploreUrl, variableJSON: nil)
    }


}

private actor ReloadExploreExecutor: LegadoOriginalPreviewExecuting {
    private var opens = 0
    private let failOpen: Bool
    init(failOpen: Bool = false) { self.failOpen = failOpen }
    func openCount() -> Int { opens }
    func execute(sourceJSON: String, sourceURL: String, sourceRevision: String,
                 grant: OriginalRuntimePreviewGrant?, operation: LegadoOriginalPreviewOperation,
                 deadline: Date) async throws -> LegadoOriginalPreviewResult {
        guard case .openExploreContext = operation else {
            throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY", message: "Reload fixture only opens the existing context")
        }
        opens += 1
        if failOpen { throw LegadoRuntimeError(code: "STATE_IO", message: "Controlled open failure") }
        return .exploreContext(try JSONDecoder().decode(LegadoOriginalExploreContextResult.self,
            from: Data("{\"infoMap\":{},\"needSave\":false,\"result\":null}".utf8)))
    }
}
