import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

@Suite("Cover turns preserve their destination", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct ReaderCoverPositionTests {
    @Test("a tapped cover turn lands on its destination without a speculative binding write", arguments: [-1, 1])
    func tappedCoverTurnCommitsItsTarget(delta: Int) async throws {
        try await assertCoverLanding(delta: delta, prefixShift: 0)
    }

    @Test("repagination before a cover turn settles changes its page number, not its content", arguments: [-1, 1])
    func coverTurnSurvivesPageReindex(delta: Int) async throws {
        try await assertCoverLanding(delta: delta, prefixShift: 7)
    }

    @Test("cover taps keep the latest content target while a neighbour renumbers pages", arguments: [-1, 3])
    func coverBurstKeepsItsLatestTarget(lastDelta: Int) async throws {
        try await assertCoverLanding(delta: 1, prefixShift: 7, burstDeltas: [2, lastDelta])
    }

    private func assertCoverLanding(delta: Int, prefixShift: Int, burstDeltas: [Int] = []) async throws {
        let engine = PagedPositionTestEngine()
        defer { try? FileManager.default.removeItem(at: engine.temporaryDirectory) }
        let probe = CoverPositionProbe()
        let coordinator = CoreTextPageEngineView.Coordinator(
            engine: engine,
            pageTurnStyle: .cover,
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
                probe.landings.append((page, position))
                probe.completion?()
                probe.completion = nil
            },
            onTapZone: { _ in }
        )
        let pageViewController = UIPageViewController(
            transitionStyle: .scroll, navigationOrientation: .horizontal
        )
        pageViewController.view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        let initial = engine.pageViewController(at: 105)
        pageViewController.setViewControllers([initial], direction: .forward, animated: false)
        ReaderPositionSentry.shared.beginBook(label: "cover-position-test")
        coordinator.captureStablePosition(from: initial)
        coordinator.setupCoverOverlay(on: pageViewController.view)

        // The snapshot hook changes the prefix after the turn chose its target,
        // before it settles. This makes the interleaving deterministic even when
        // UIKit completes offscreen animations immediately in the test host.
        var didReindex = false
        var snapshotCount = 0
        engine.onSnapshot = { [weak engine, weak coordinator] _ in
            guard let engine, let coordinator else { return }
            snapshotCount += 1
            // The second snapshot is requested after the first cover turn owns
            // the animation gate. Feed later intents through the real entry point
            // before that animation can complete, without depending on wall time.
            guard snapshotCount >= (burstDeltas.isEmpty ? 1 : 2) else { return }
            guard !didReindex else { return }
            didReindex = true
            for queuedDelta in burstDeltas {
                probe.page = 105 + queuedDelta
                coordinator.animateCoverTransition(
                    from: 105,
                    to: 105 + queuedDelta,
                    direction: queuedDelta > 0 ? .forward : .reverse,
                    on: pageViewController,
                    targetPosition: .init(spineIndex: 2, charOffset: 500 + 100 * queuedDelta)
                )
            }
            engine.chapterStartPage += prefixShift
        }
        await withCheckedContinuation { (completion: CheckedContinuation<Void, Never>) in
            probe.completion = { completion.resume() }
            coordinator.animateCoverTransition(
                from: 105,
                to: 105 + delta,
                direction: delta > 0 ? .forward : .reverse,
                on: pageViewController
            )
        }

        let finalDelta = burstDeltas.last ?? delta
        let expected = CoreTextReadingPosition(spineIndex: 2, charOffset: 500 + 100 * finalDelta)
        let visible = try #require(pageViewController.viewControllers?.first as? PagedPositionTestPage)
        #expect(didReindex)
        #expect(visible.coreTextReadingPosition == expected)
        #expect(visible.globalPageIndex == 105 + finalDelta + prefixShift)
        #expect(probe.page == 105 + finalDelta + prefixShift)
        #expect(probe.landings.count == 1)
        #expect(probe.landings.first?.position == expected)
        #expect(probe.landings.first?.page == probe.page)
    }
}

@MainActor
private final class CoverPositionProbe {
    var page = 105
    var landings: [(page: Int, position: CoreTextReadingPosition?)] = []
    var completion: (() -> Void)?
}
