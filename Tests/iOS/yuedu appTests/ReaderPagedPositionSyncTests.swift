import Foundation
import SwiftUI
import Testing
import UIKit
import YueduCoreText
@testable import yuedu_app

@Suite("Paged position synchronization", .serialized)
@MainActor
struct ReaderPagedPositionSyncTests {
    @Test("an old page number cannot become a new chapter-start commit")
    func queuedPageReindexDoesNotCommitAReadingPosition() async {
        let fixture = PagedPositionSyncFixture(chapterStartPage: 95)
        defer { fixture.removeTemporaryDirectory() }

        // The first neighbour rebuild emits page 105 for offset 500. Before its
        // queued delivery, another rebuild makes that number the chapter's first
        // page. This is a numbering change, never a new reading position.
        fixture.engine.chapterStartPage = 100
        fixture.engine.onNavigateToPage?(105)
        fixture.engine.chapterStartPage = 105
        #expect(fixture.engine.readingPosition(forPage: 105) == .chapterStart(2))
        await drainPageCallbackQueue()

        #expect(fixture.probe.page == 110)
        #expect(fixture.probe.callbacks.isEmpty)
        #expect(fixture.navigator.currentLocation == fixture.initialPosition)
        #expect(fixture.engine.anchor == fixture.initialPosition)
    }

    @Test("a queued reindex cannot undo a later real page turn")
    func queuedPageReindexUsesTheLatestSettledPosition() async {
        let fixture = PagedPositionSyncFixture(chapterStartPage: 95)
        defer { fixture.removeTemporaryDirectory() }
        let next = CoreTextReadingPosition(spineIndex: 2, charOffset: 600)

        fixture.engine.chapterStartPage = 100
        fixture.engine.onNavigateToPage?(105)
        fixture.engine.chapterStartPage = 105
        fixture.coordinator.syncStablePosition(
            afterShowing: PagedPositionTestPage(page: 111, position: next),
            notifyFallback: true,
            readerDriven: true
        )
        await drainPageCallbackQueue()

        #expect(fixture.probe.page == 111)
        #expect(fixture.probe.callbacks.count == 1)
        #expect(fixture.probe.callbacks.first?.position == next)
        #expect(fixture.navigator.currentLocation == next)
        #expect(fixture.engine.anchor == next)
        await fixture.navigator.flush()
        #expect(await fixture.positions.load(for: fixture.bookID) == next)
    }

    @Test("an older queued settle cannot replace the newest settled page")
    func supersededPositionPublicationIsDropped() async {
        let fixture = PagedPositionSyncFixture()
        defer { fixture.removeTemporaryDirectory() }
        let next = CoreTextReadingPosition(spineIndex: 2, charOffset: 600)

        fixture.coordinator.syncStablePosition(
            afterShowing: PagedPositionTestPage(page: 105, position: fixture.initialPosition),
            notifyFallback: true,
            readerDriven: true
        )
        fixture.coordinator.syncStablePosition(
            afterShowing: PagedPositionTestPage(page: 106, position: next),
            notifyFallback: true,
            readerDriven: true
        )
        // Even real settlements carry content positions: a second offset rebuild
        // before their queued publication must only change the displayed number.
        fixture.engine.chapterStartPage = 107
        await drainPageCallbackQueue()

        #expect(fixture.probe.page == 113)
        #expect(fixture.probe.callbacks.count == 1)
        #expect(fixture.probe.callbacks.first?.page == 113)
        #expect(fixture.probe.callbacks.first?.position == next)
        #expect(fixture.navigator.currentLocation == next)
        await fixture.navigator.flush()
        #expect(await fixture.positions.load(for: fixture.bookID) == next)
    }

    private func drainPageCallbackQueue() async {
        // The engine callback and its binding publication each enqueue once. Wait
        // for those real queue boundaries; no timer or animation delay is needed.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}

@MainActor
private final class PagedPositionSyncFixture {
    let initialPosition: CoreTextReadingPosition
    let bookID: String
    let engine: PagedPositionTestEngine
    let probe: PagedPositionSyncProbe
    let positions: PagedPositionSyncStore
    let navigator: ReaderNavigator
    let coordinator: CoreTextPageEngineView.Coordinator
    let pageViewController: UIPageViewController

    init(chapterStartPage: Int = 100) {
        let initialPosition = CoreTextReadingPosition(spineIndex: 2, charOffset: 500)
        let bookID = "paged-position-sync"
        let engine = PagedPositionTestEngine(chapterStartPage: chapterStartPage)
        let probe = PagedPositionSyncProbe()
        let initialPage = chapterStartPage + 5
        engine.currentPage = initialPage
        probe.page = initialPage
        let positions = PagedPositionSyncStore()
        let pageViewController = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal
        )
        self.initialPosition = initialPosition
        self.bookID = bookID
        self.engine = engine
        self.probe = probe
        self.positions = positions
        self.pageViewController = pageViewController
        let navigator = ReaderNavigator(
            initialState: ReaderPresentationState(
                location: ReaderLocation(initialPosition),
                direction: .ltr,
                spreadMode: .singlePage,
                viewportSize: CGSize(width: 320, height: 480),
                appearance: ReaderAppearance(settings: EPUBTestFixtures.renderSettings(), theme: .white),
                pagingStyle: .none
            ),
            positionStore: positions,
            bookId: bookID
        )
        self.navigator = navigator
        coordinator = CoreTextPageEngineView.Coordinator(
            engine: engine,
            pageTurnStyle: .none,
            theme: .white,
            playbackHighlight: nil,
            isRTL: false,
            isDoublePageSpread: false,
            spreadGutter: 0,
            sessionCoordinator: nil,
            externalTargetPosition: nil,
            clearExternalTargetPosition: {},
            currentPage: Binding(get: { probe.page }, set: { probe.page = $0 }),
            onPageChanged: { page, position in
                probe.callbacks.append(.init(page: page, position: position))
                if let position {
                    engine.updateReadingPosition(position)
                    navigator.settle(at: position, pageIndex: page, totalPages: engine.totalPages, persist: false)
                }
            },
            onTapZone: { _ in }
        )
        ReaderPositionSentry.shared.beginBook(label: bookID)
        let visible = PagedPositionTestPage(page: initialPage, position: initialPosition)
        pageViewController.setViewControllers([visible], direction: .forward, animated: false)
        coordinator.captureStablePosition(from: visible)
        coordinator.bindEngineCallbacks(to: engine, pageViewController: pageViewController)
    }

    func removeTemporaryDirectory() {
        try? FileManager.default.removeItem(at: engine.temporaryDirectory)
    }
}

@MainActor
private final class PagedPositionSyncProbe {
    struct Callback {
        let page: Int
        let position: CoreTextReadingPosition?
    }

    var page = 105
    var callbacks: [Callback] = []
}

private final class PagedPositionSyncStore: ReadingPositionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: CoreTextReadingPosition] = [:]

    func save(_ position: CoreTextReadingPosition, for bookId: String) async {
        lock.withLock { values[bookId] = position }
    }

    func load(for bookId: String) async -> CoreTextReadingPosition? { loadSync(for: bookId) }
    func loadSync(for bookId: String) -> CoreTextReadingPosition? { lock.withLock { values[bookId] } }
    func flush(for bookId: String) async {}
}

/// Test-only page space whose prefix changes when a neighbouring chapter loads.
/// The source positions and page contents remain unchanged across that reindex.
@MainActor
final class PagedPositionTestEngine: PageRenderingProvider {
    var chapterStartPage: Int
    var currentPage = 105
    var totalPages = 200
    var renderSize = CGSize(width: 320, height: 480)
    var layouts: [Int: CoreTextPaginator.ChapterLayout] { [:] }
    let temporaryDirectory: URL
    let offsetStore: CharOffsetStore
    private(set) var anchor = CoreTextReadingPosition(spineIndex: 2, charOffset: 500)

    var onChapterReady: ((Int?) -> Void)?
    var onNavigateToPage: ((Int) -> Void)?
    var onChapterLayoutUnresolved: ((Int, ChapterLayoutOutcome) -> Void)?
    var onSnapshot: ((Int) -> Void)?

    init(chapterStartPage: Int = 100) {
        self.chapterStartPage = chapterStartPage
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        self.temporaryDirectory = temporaryDirectory
        offsetStore = CharOffsetStore(directoryURL: temporaryDirectory)
    }

    func pageIndex(for position: CoreTextReadingPosition) -> Int? {
        guard position.spineIndex == 2, position.charOffset >= 0 else { return nil }
        return chapterStartPage + position.charOffset / 100
    }

    func pageIndex(forSpine spineIndex: Int, charOffset: Int) -> Int {
        pageIndex(for: .init(spineIndex: spineIndex, charOffset: charOffset)) ?? 0
    }

    func estimatedGlobalPage(for position: CoreTextReadingPosition) -> Int? { pageIndex(for: position) }
    func readingPosition(forPage page: Int) -> CoreTextReadingPosition? {
        .init(spineIndex: 2, charOffset: max(0, page - chapterStartPage) * 100)
    }

    func charOffset(forPage page: Int) -> (spineIndex: Int, charOffset: Int) {
        (2, max(0, page - chapterStartPage) * 100)
    }

    func localPosition(for globalPage: Int) -> (spineIndex: Int, localPage: Int) {
        (2, max(0, globalPage - chapterStartPage))
    }

    func lastPageIndex(ofChapter spineIndex: Int) -> Int? { totalPages - 1 }
    func chapterPagination(forSpine spineIndex: Int, charOffset: Int) -> ChapterPagination? {
        .init(localPageIndex: charOffset / 100, displayPageCount: totalPages - chapterStartPage)
    }

    func chapterText(forSpine spineIndex: Int) -> String? { String(repeating: "正文", count: 1_000) }
    func chapterAnchorOffsets(forSpine spineIndex: Int) -> [String: Int]? { [:] }
    func plainText(forPage page: Int) -> String { "正文" }
    func totalProgress(forSpine spineIndex: Int, charOffset: Int) -> Double { Double(charOffset) / 2_000 }
    func position(forProgress progress: Double) -> (spineIndex: Int, charOffset: Int) { (2, Int(progress * 2_000)) }
    func resolveInternalLink(_ href: String, fromSpineIndex spineIndex: Int) async -> Int? { nil }
    func start(renderSize: CGSize, bookId: String) async { self.renderSize = renderSize }
    func preloadChapter(at spineIndex: Int) async -> ChapterLayoutOutcome { .alreadyLaidOut }
    func invalidateLayout(newSize: CGSize) async { renderSize = newSize }
    func warmUpNext(currentGlobalPage: Int) {}
    func cancelPendingWork(cause: LayoutInvalidationCause) {}
    func notifyChapterDataChanged(at spineIndex: Int) async {}
    func updateReadingPosition(_ position: CoreTextReadingPosition) { anchor = position }
    func applyThemeChange(textColor: UIColor, backgroundColor: UIColor) {}
    func updateRenderSettings(_ settings: ReaderRenderSettings) {}
    func setTextAnnotations(_ annotations: [CoreTextTextAnnotation]) {}

    func pageViewController(at index: Int) -> UIViewController {
        PagedPositionTestPage(page: index, position: readingPosition(forPage: index)!)
    }

    func pageViewController(for position: CoreTextReadingPosition) -> UIViewController {
        PagedPositionTestPage(page: pageIndex(for: position)!, position: position)
    }

    func renderSnapshot(forPage globalPage: Int) -> UIImage? {
        onSnapshot?(globalPage)
        return UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
    }
}

@MainActor
final class PagedPositionTestPage: UIViewController, PageIndexProviding, CoreTextReadingPositionProviding {
    let globalPageIndex: Int
    let coreTextReadingPosition: CoreTextReadingPosition?

    init(page: Int, position: CoreTextReadingPosition) {
        globalPageIndex = page
        coreTextReadingPosition = position
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
