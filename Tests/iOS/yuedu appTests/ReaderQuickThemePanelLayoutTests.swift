import SwiftUI
import XCTest
@testable import yuedu_app

@MainActor
final class ReaderQuickThemePanelLayoutTests: XCTestCase {
    func testPresentedPanelDoesNotAddEmptySpaceBelowMeasuredContent() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }

        for appearance in [UIUserInterfaceStyle.light, .dark] {
            let appeared = expectation(description: "Quick panel finished presentation")
            var measuredHeight: CGFloat = 0
            let root = Color.gray.sheet(isPresented: .constant(true)) {
                ReaderQuickThemePanelView(
                    fontSize: .constant(18), readerTheme: .constant(.white),
                    pageTurnOption: .fastFade, isVerticalWritingMode: false,
                    onSelectPageTurnOption: { _ in }, onStartAutoRead: {}, onCustomize: {}
                )
                .environment(\.dynamicTypeSize, .large)
                .onPreferenceChange(ReaderQuickPanelContentHeightKey.self) { measuredHeight = $0 }
                .background(QuickPanelAppearanceProbe { appeared.fulfill() })
            }
            let host = UIHostingController(rootView: root)
            window.overrideUserInterfaceStyle = appearance
            window.rootViewController = host
            window.makeKeyAndVisible()
            await fulfillment(of: [appeared], timeout: 10)
            window.layoutIfNeeded()
            let sheet = try XCTUnwrap(host.presentedViewController)
            let navigation = try XCTUnwrap(navigationController(in: sheet))
            XCTAssertGreaterThan(measuredHeight, 0)
            XCTAssertFalse(navigation.isNavigationBarHidden)
            XCTAssertFalse(navigation.navigationBar.topItem?.leftBarButtonItems?.isEmpty ?? true,
                           "The panel needs a visible close action as an alternative to dragging")
            XCTAssertEqual(sheet.view.bounds.height, measuredHeight + navigation.navigationBar.bounds.height, accuracy: 2,
                           "The sheet must fit its content and native navigation; do not reserve the bottom safe area twice")
            let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = "quick-panel-\(appearance == .dark ? "dark" : "light")"
            attachment.lifetime = .keepAlways
            add(attachment)
            print("QUICK_PANEL_LAYOUT content=\(measuredHeight) navigation=\(navigation.navigationBar.bounds.height) sheet=\(sheet.view.bounds.height) safeBottom=\(sheet.view.safeAreaInsets.bottom)")
            await withCheckedContinuation { continuation in
                host.dismiss(animated: false) { continuation.resume() }
            }
        }
    }

    func testLargestAccessibilityTextKeepsNativeCloseAndCanReachBottom() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }

        let appeared = expectation(description: "Large-text quick panel finished presentation")
        let bottomActionVisible = expectation(description: "The complete final action is visible")
        var bottomActionFrame = CGRect.null
        var visibleViewport: CGRect?
        var reportedBottomActionVisible = false
        let root = Color.gray.sheet(isPresented: .constant(true)) {
            ReaderQuickThemePanelView(
                fontSize: .constant(GlobalSettings.readerFontSizeRange.upperBound),
                readerTheme: .constant(.night),
                pageTurnOption: .fastFade, isVerticalWritingMode: false,
                onSelectPageTurnOption: { _ in }, onStartAutoRead: {}, onCustomize: {}
            )
            .environment(\.dynamicTypeSize, .accessibility5)
            .environment(\.accessibilityReduceMotion, true)
            .onPreferenceChange(ReaderQuickPanelBottomActionFrameKey.self) { frame in
                bottomActionFrame = frame
                if !reportedBottomActionVisible, let visibleViewport,
                   !frame.isNull, visibleViewport.contains(frame) {
                    reportedBottomActionVisible = true
                    bottomActionVisible.fulfill()
                }
            }
            .background(QuickPanelAppearanceProbe { appeared.fulfill() })
        }
        let host = UIHostingController(rootView: root)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = host
        window.makeKeyAndVisible()
        await fulfillment(of: [appeared], timeout: 10)
        window.layoutIfNeeded()

        let sheet = try XCTUnwrap(host.presentedViewController)
        let navigation = try XCTUnwrap(navigationController(in: sheet))
        XCTAssertFalse(navigation.isNavigationBarHidden)
        XCTAssertEqual(navigation.navigationBar.topItem?.title, localized("Themes & Settings"))
        XCTAssertFalse(navigation.navigationBar.topItem?.leftBarButtonItems?.isEmpty ?? true)
        let scroll = try XCTUnwrap(verticalScrollView(in: sheet.view))
        let viewport = scroll.convert(scroll.bounds, to: window).insetBy(dx: -1, dy: -1)
        visibleViewport = viewport
        attachScreenshot(window, name: "quick-panel-accessibility5-top")

        // A tall iPad may fit all controls. Where they exceed the viewport, the
        // bottom must remain reachable without dragging the sheet itself.
        let bottomOffset = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        scroll.setContentOffset(
            CGPoint(x: 0, y: bottomOffset),
            animated: false
        )
        window.layoutIfNeeded()
        if !reportedBottomActionVisible, !bottomActionFrame.isNull, viewport.contains(bottomActionFrame) {
            reportedBottomActionVisible = true
            bottomActionVisible.fulfill()
        }
        await fulfillment(of: [bottomActionVisible], timeout: 10)
        XCTAssertFalse(bottomActionFrame.isNull)
        XCTAssertTrue(viewport.contains(bottomActionFrame), "The whole Customize button must be inside the visible scroll viewport")
        XCTAssertGreaterThanOrEqual(bottomActionFrame.height, DSLayout.minimumTapTarget)
        XCTAssertEqual(scroll.contentOffset.y, bottomOffset, accuracy: 1)
        XCTAssertFalse(navigation.isNavigationBarHidden, "Closing must stay available when the controls are scrolled")
        attachScreenshot(window, name: "quick-panel-accessibility5-bottom")
        await withCheckedContinuation { continuation in
            host.dismiss(animated: false) { continuation.resume() }
        }
    }

    private func navigationController(in root: UIViewController) -> UINavigationController? {
        if let navigation = root as? UINavigationController { return navigation }
        return root.children.lazy.compactMap { navigationController(in: $0) }.first
    }

    private func verticalScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView,
           scroll.contentSize.height > 0,
           scroll.contentSize.width <= scroll.bounds.width + 1 { return scroll }
        return view.subviews.lazy.compactMap { verticalScrollView(in: $0) }.first
    }

    private func attachScreenshot(_ window: UIWindow, name: String) {
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private struct QuickPanelAppearanceProbe: UIViewControllerRepresentable {
    let onAppear: () -> Void
    func makeUIViewController(context: Context) -> ProbeController {
        ProbeController(onAppear: onAppear)
    }
    func updateUIViewController(_ controller: ProbeController, context: Context) {}

    final class ProbeController: UIViewController {
        let onAppear: () -> Void
        init(onAppear: @escaping () -> Void) {
            self.onAppear = onAppear
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onAppear()
        }
    }
}
