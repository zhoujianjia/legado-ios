import SwiftUI
import Testing
import UIKit
import XCTest
@testable import yuedu_app

@Suite("Reader viewport size", .serialized)
@MainActor
struct ReaderViewportSizeObserverTests {
    @Test("window resizing preserves actual width and height without an orientation change")
    func reportsActualBoundsDuringWindowResizing() async throws {
        var sizes: [CGSize] = []
        let view = ReaderViewportSizeObserver.MeasuringView { sizes.append($0) }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1200, height: 900))
        defer { withExtendedLifetime(window) { view.removeFromSuperview() } }
        view.frame = CGRect(x: 0, y: 0, width: 430, height: 900)
        window.addSubview(view)
        await view.pendingDelivery?.value

        // Neither resize needs a device-orientation notification. In particular,
        // a tall split-view viewport must stay tall on a landscape iPad.
        for size in [CGSize(width: 430, height: 650), CGSize(width: 900, height: 430)] {
            view.frame.size = size
            view.setNeedsLayout()
            view.layoutIfNeeded()
            let delivery = try #require(view.pendingDelivery)
            await delivery.value
        }

        #expect(sizes == [
            CGSize(width: 430, height: 900),
            CGSize(width: 430, height: 650),
            CGSize(width: 900, height: 430),
        ])
    }

    @Test("unchanged layout does not publish another viewport")
    func unchangedLayoutDoesNotPublish() async {
        var sizes: [CGSize] = []
        let view = ReaderViewportSizeObserver.MeasuringView { sizes.append($0) }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 900))
        defer { withExtendedLifetime(window) { view.removeFromSuperview() } }
        view.frame = window.bounds
        window.addSubview(view)
        await view.pendingDelivery?.value

        for _ in 0..<3 {
            view.setNeedsLayout()
            view.layoutIfNeeded()
            #expect(view.pendingDelivery == nil)
        }
        #expect(sizes == [window.bounds.size])
    }

    @Test("zero bounds are ignored until a valid layout exists")
    func zeroBoundsAreIgnored() async throws {
        var sizes: [CGSize] = []
        let view = ReaderViewportSizeObserver.MeasuringView { sizes.append($0) }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 900))
        defer { withExtendedLifetime(window) { view.removeFromSuperview() } }
        window.addSubview(view)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        #expect(view.pendingDelivery == nil)
        #expect(sizes.isEmpty)

        view.frame = window.bounds
        view.setNeedsLayout()
        view.layoutIfNeeded()
        let delivery = try #require(view.pendingDelivery)
        await delivery.value
        #expect(sizes == [window.bounds.size])
    }

    @Test("queued layouts use the newest bounds and callback")
    func deliveryCoalescesLiveBoundsAndUsesLatestCallback() async throws {
        var oldCallbackSizes: [CGSize] = []
        var currentCallbackSizes: [CGSize] = []
        let view = ReaderViewportSizeObserver.MeasuringView { oldCallbackSizes.append($0) }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 900))
        defer { withExtendedLifetime(window) { view.removeFromSuperview() } }
        view.frame = window.bounds
        window.addSubview(view)
        let delivery = try #require(view.pendingDelivery)

        view.frame.size = CGSize(width: 650, height: 700)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        view.onSizeChange = { currentCallbackSizes.append($0) }
        await delivery.value

        #expect(oldCallbackSizes.isEmpty)
        #expect(currentCallbackSizes == [CGSize(width: 650, height: 700)])
        #expect(view.pendingDelivery == nil)
    }

    @Test("leaving the window cancels delivery and reattachment measures again")
    func detachingCancelsPendingDelivery() async throws {
        var sizes: [CGSize] = []
        let view = ReaderViewportSizeObserver.MeasuringView { sizes.append($0) }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 900))
        defer { withExtendedLifetime(window) { view.removeFromSuperview() } }
        view.frame = window.bounds
        window.addSubview(view)
        let detachedDelivery = try #require(view.pendingDelivery)
        view.removeFromSuperview()
        await detachedDelivery.value
        #expect(sizes.isEmpty)
        #expect(view.pendingDelivery == nil)

        window.addSubview(view)
        let attachedDelivery = try #require(view.pendingDelivery)
        await attachedDelivery.value
        #expect(sizes == [window.bounds.size])
    }

    @Test("dismantling cancels delivery and prevents later layout callbacks")
    func invalidatingStopsDelivery() async throws {
        var sizes: [CGSize] = []
        let view = ReaderViewportSizeObserver.MeasuringView { sizes.append($0) }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 900))
        defer { withExtendedLifetime(window) { view.removeFromSuperview() } }
        view.frame = window.bounds
        window.addSubview(view)
        let delivery = try #require(view.pendingDelivery)
        ReaderViewportSizeObserver.dismantleUIView(view, coordinator: ())
        await delivery.value

        view.frame.size = CGSize(width: 650, height: 700)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        #expect(sizes.isEmpty)
        #expect(view.pendingDelivery == nil)
        #expect(view.onSizeChange == nil)
    }
}

@MainActor
final class ReaderViewportSizeObserverHostingTests: XCTestCase {
    func testBackgroundMeasuresReaderSurfaceInsteadOfWindowAndReportsResize() async {
        let initialSize = CGSize(width: 330, height: 520)
        let resizedSize = CGSize(width: 398, height: 350)
        let firstReport = expectation(description: "initial reader surface bounds")
        let resizedReport = expectation(description: "resized reader surface bounds")
        var reports: [CGSize] = []
        var reportedInitial = false
        var reportedResize = false
        let host = UIHostingController(rootView:
            Color.clear
                .background(ReaderViewportSizeObserver { size in
                    reports.append(size)
                    if size == initialSize, !reportedInitial {
                        reportedInitial = true
                        firstReport.fulfill()
                    }
                    if size == resizedSize, !reportedResize {
                        reportedResize = true
                        resizedReport.fulfill()
                    }
                })
                .ignoresSafeArea()
        )
        let container = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        window.rootViewController = container
        window.isHidden = false
        container.addChild(host)
        container.view.addSubview(host.view)
        host.didMove(toParent: container)
        // The fixed reader surface is deliberately smaller than, and offset
        // inside, its window. Reporting window bounds would fail this test.
        host.view.frame = CGRect(origin: CGPoint(x: 31, y: 59), size: initialSize)
        defer {
            withExtendedLifetime((window, container, host)) {
                host.willMove(toParent: nil)
                host.view.removeFromSuperview()
                host.removeFromParent()
                window.isHidden = true
            }
        }

        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        // This is a bound on the real observer callback, not a layout delay.
        await fulfillment(of: [firstReport], timeout: 5)
        XCTAssertEqual(reports.last, initialSize)
        XCTAssertNotEqual(initialSize, window.bounds.size)

        host.view.frame.size = resizedSize
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await fulfillment(of: [resizedReport], timeout: 5)
        XCTAssertEqual(reports.last, resizedSize)
        XCTAssertEqual(host.view.bounds.size, resizedSize)
    }
}
