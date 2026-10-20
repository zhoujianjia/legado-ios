import AVKit
import LegadoRuntime
import SwiftUI
import UIKit

/// Opens what source JS asks the reader for — a page (`java.startBrowser` /
/// `java.startBrowserAwait`) or an image captcha (`java.getVerificationCode`) — from wherever
/// the script runs: search, a chapter, 書源驗證, a login menu. Legado's
/// `SourceVerificationHelp` does the same from any thread, in both Legado-E and MD3.
///
/// One sheet at a time: a request that arrives while one is up waits until it is gone, as
/// Legado's `getVerificationResult` is `@Synchronized`. Several sources checked in parallel
/// therefore queue their sheets instead of stacking them.
@MainActor
enum SourceBrowserPresenter {
    /// State-only signal from actual UIKit completion; no page text or secrets.
    static let originalPageDidPresent = Notification.Name("YueduOriginalBrowserPageDidPresent")
    /// Installs this as `LegadoJSBridge.sharedBrowserPresenter` and
    /// `sharedCaptchaPresenter`. Called once at launch.
    static func install() {
        LegadoJSBridge.sharedBrowserPresenter = { request, completion in
            Task { @MainActor in
                present(request, completion: completion)
            }
        }
        LegadoJSBridge.sharedCaptchaPresenter = { request, completion in
            Task { @MainActor in
                presentCaptcha(request, completion: completion)
            }
        }
        LegadoJSBridge.sharedVideoPresenter = { request, title in
            Task { @MainActor in
                presentVideo(request, title: title)
            }
        }
    }

    /// `java.openVideoPlayer`: the system player, full screen, playing at once — legado-E's
    /// `VideoPlayerActivity`. Not queued with the sheets: nothing waits on it.
    static func presentVideo(_ request: URLRequest, title: String) {
        guard let url = request.url, let topVC = BookSourceFormLoginView.topViewController() else {
            AppLogger.parse("⟐ openVideoPlayer: nowhere to present", context: [:])
            return
        }
        AudioSessionActivator.activate(category: .playback, mode: .moviePlayback)
        let player = AVPlayer(playerItem: AVPlayerItem(
            asset: HeaderedMediaAsset.make(url: url, headers: request.allHTTPHeaderFields ?? [:])
        ))
        let controller = AVPlayerViewController()
        controller.player = player
        controller.title = title
        controller.modalPresentationStyle = .fullScreen
        topVC.present(controller, animated: true) { player.play() }
    }

    /// Shows `request`'s page. `completion` runs exactly once: with the page's HTML when the
    /// user confirms it (✓, or a Cloudflare challenge on it clearing), with nil when the page
    /// goes away any other way — ✕, a swipe, or nowhere to present it.
    static func present(_ request: SourceBrowserRequest, completion: @escaping (String?) -> Void) {
        waiting.append(Pending(completion: completion, content: .page(request)))
        presentNextIfIdle()
    }

    /// Shows `request`'s captcha. `completion` runs exactly once: with the code the user
    /// entered, or nil when the sheet goes away without one.
    static func presentCaptcha(_ request: SourceCaptchaRequest, completion: @escaping (String?) -> Void) {
        waiting.append(Pending(completion: completion, content: .captcha(request)))
        presentNextIfIdle()
    }

    /// Nonawait returns only a real presentation receipt. Await holds the same
    /// ticket until a real confirmation or cancellation and UIKit dismissal.
    static func presentOriginal(_ presentation: LegadoOriginalBrowserPresentation) async throws -> LegadoOriginalBrowserCompletion {
        let ticket = OriginalPageTicket(presentation)
        let id = ticket.id
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (receipt: CheckedContinuation<LegadoOriginalBrowserCompletion, any Error>) in
                ticket.receipt = receipt
                waiting.append(Pending(completion: { _ in }, content: .originalPage(ticket)))
                presentNextIfIdle()
            }
        } onCancel: {
            Task { @MainActor in cancelOriginal(id: id) }
        }
    }

    /// Cancellation is explicit. Normal Host revocation after producer success does
    /// not call this and must not close an already accepted nonawait page.
    static func cancelOriginal(taskID: String) async {
        var tickets = waiting.compactMap { pending -> OriginalPageTicket? in
            if case .originalPage(let ticket) = pending.content,
               ticket.presentation.taskID == taskID { return ticket }
            return nil
        }
        if let ticket = activeOriginal, ticket.presentation.taskID == taskID { tickets.append(ticket) }
        for ticket in tickets { cancelOriginal(id: ticket.id) }
        // Wait for the actual dismissal callback, never a timing estimate. This
        // also lets the next original action observe a fully drained UI owner.
        for ticket in tickets { await ticket.waitUntilEnded() }
    }

    /// Presentation-lifetime fact only; no source data or credential authority.
    static func isOriginalPageActive(taskID: String) -> Bool {
        guard let ticket = activeOriginal, ticket.presentation.taskID == taskID else { return false }
        return ticket.completedPresentation && !ticket.ended
    }

    /// Same page-authored close path as WKUIDelegate, including challenge
    /// suppression and the mounted View's real checked confirmation flow.
    static func requestOriginalPageClose(taskID: String) {
        guard let ticket = activeOriginal, ticket.presentation.taskID == taskID,
              ticket.presentation.awaitsResult, ticket.completedPresentation,
              !ticket.ended, !ticket.closing,
              let controller = ticket.controller as? OriginalPageController else { return }
        controller.pageControls?.requestClose()
    }

    @MainActor
    private final class OriginalPageTicket {
        let id = UUID()
        let presentation: LegadoOriginalBrowserPresentation
        var receipt: CheckedContinuation<LegadoOriginalBrowserCompletion, any Error>?
        var work: Task<Void, Never>?
        let cookieCancellation = OriginalRuntimeCommitCancellation()
        var terminal: Result<LegadoOriginalBrowserCompletion, any Error>?
        weak var controller: UIViewController?
        var cancelled = false
        var startedPresentation = false
        var completedPresentation = false
        var closing = false
        var closeRequested = false
        var ended = false
        var finishing = false
        var drain: Task<Void, Never>?
        private var endedWaiters: [CheckedContinuation<Void, Never>] = []

        func waitUntilEnded() async {
            guard !ended else { return }
            await withCheckedContinuation { endedWaiters.append($0) }
        }
        func end() {
            guard !ended else { return }
            ended = true
            let waiters = endedWaiters
            endedWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }

        init(_ presentation: LegadoOriginalBrowserPresentation) { self.presentation = presentation }
        func acceptPresentation() {
            guard !presentation.awaitsResult else { return }
            resolve(.success(.presented))
        }
        func resolve(_ result: Result<LegadoOriginalBrowserCompletion, any Error>) {
            guard let receipt else { return }
            self.receipt = nil
            receipt.resume(with: result)
        }
        func setTerminal(_ result: Result<LegadoOriginalBrowserCompletion, any Error>) {
            guard terminal == nil, !ended else { return }
            terminal = result
        }
    }

    @MainActor
    private final class OriginalPageController: UIHostingController<JsBridgeBrowserView> {
        var removed: (() -> Void)?
        var pageControls: OriginalBrowserPageControls?
        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            if isBeingDismissed || presentingViewController == nil { removed?() }
        }
    }

    private static var activeOriginal: OriginalPageTicket?

    private static func cancelOriginal(id: UUID) {
        if let index = waiting.firstIndex(where: { pending in
            if case .originalPage(let ticket) = pending.content { return ticket.id == id }
            return false
        }), case .originalPage(let ticket) = waiting.remove(at: index).content {
            ticket.cancelled = true
            ticket.cookieCancellation.cancel()
            ticket.resolve(.failure(CancellationError()))
            ticket.end()
            return
        }
        guard let ticket = activeOriginal, ticket.id == id, !ticket.ended else { return }
        ticket.cancelled = true
        ticket.cookieCancellation.cancel()
        (ticket.controller as? OriginalPageController)?.pageControls?.stopLoading()
        ticket.work?.cancel()
        // A task cancellation always wins over an unfinished confirmation.
        ticket.terminal = .failure(CancellationError())
        if !ticket.presentation.awaitsResult { ticket.resolve(.failure(CancellationError())) }
        // UIKit owns an in-flight transition until its completion signal.
        // Closing it from that callback avoids releasing the shared queue early.
        if !ticket.startedPresentation { finishOriginal(ticket) }
        else if ticket.completedPresentation || ticket.controller?.presentingViewController == nil {
            closeOriginal(ticket)
        }
    }

    private static func finishOriginal(_ ticket: OriginalPageTicket) {
        guard !ticket.ended, !ticket.finishing else { return }
        ticket.finishing = true
        ticket.cookieCancellation.cancel()
        ticket.work?.cancel()
        ticket.work = nil
        let controls = (ticket.controller as? OriginalPageController)?.pageControls
        // This separate owned drain never awaits the Coordinator from its own
        // completion callback. Release the shared queue only after both owners end.
        ticket.drain = Task { @MainActor in
            await controls?.cancelAndDrain()
            ticket.end()
            if let terminal = ticket.terminal { ticket.resolve(terminal) }
            else {
                ticket.resolve(.failure(LegadoRuntimeError(
                    code: ticket.completedPresentation && ticket.presentation.awaitsResult ? "BROWSER_CANCELLED" : "BROWSER_NOT_PRESENTED",
                    message: "The original browser page ended without a result")))
            }
            ticket.drain = nil
            guard activeOriginal?.id == ticket.id else { return }
            activeOriginal = nil
            isShowingSheet = false
            presentNextIfIdle()
        }
    }

    private static func closeOriginal(_ ticket: OriginalPageTicket) {
        guard !ticket.ended, !ticket.closing else { return }
        (ticket.controller as? OriginalPageController)?.pageControls?.stopLoading()
        if ticket.startedPresentation && !ticket.completedPresentation {
            ticket.closeRequested = true
            return
        }
        guard let controller = ticket.controller, controller.presentingViewController != nil else {
            finishOriginal(ticket)
            return
        }
        ticket.closing = true
        controller.dismiss(animated: true) { finishOriginal(ticket) }
    }

    private static func completeOriginal(_ ticket: OriginalPageTicket,
        result: Result<LegadoOriginalBrowserCompletion, any Error>) {
        guard ticket.presentation.awaitsResult, !ticket.cancelled, !ticket.ended,
              ticket.terminal == nil else { return }
        // The await continuation is resumed by finishOriginal only after the
        // actual controller disappearance/dismissal, never by this UI callback.
        ticket.setTerminal(result)
        closeOriginal(ticket)
    }

    private static func userCancelledOriginal(_ ticket: OriginalPageTicket) {
        if ticket.presentation.awaitsResult {
            ticket.cookieCancellation.cancel()
            ticket.setTerminal(.failure(LegadoRuntimeError(code: "BROWSER_CANCELLED",
                message: "The awaited browser was cancelled")))
        }
        closeOriginal(ticket)
    }

    private static func startOriginal(_ ticket: OriginalPageTicket) {
        activeOriginal = ticket
        ticket.work = Task { @MainActor in
            do {
                try await ticket.presentation.authorize()
                try Task.checkCancellation()
                guard !ticket.cancelled, !ticket.ended else { throw CancellationError() }
                // Resolve the presenter after authorization, not before an actor hop.
                guard let topVC = BookSourceFormLoginView.topViewController(),
                      topVC.viewIfLoaded?.window != nil, !topVC.isBeingDismissed,
                      topVC.presentedViewController == nil,
                      let url = URL(string: ticket.presentation.url) else {
                    throw LegadoRuntimeError(code: "BROWSER_NOT_PRESENTED", message: "There is no active browser presenter")
                }
                let request = SourcePerfTrace.span("legado.original.browser.request",
                    "main=\(Thread.isMainThread) headers=\(ticket.presentation.headers.count)") {
                    var request = URLRequest(url: url)
                    for (name, value) in ticket.presentation.headers { request.setValue(value, forHTTPHeaderField: name) }
                    return request
                }
                let userAgent = request.value(forHTTPHeaderField: "User-Agent")
                let packet = ticket.presentation
                let cancellation = ticket.cookieCancellation
                let awaitPolicy: OriginalBrowserAwaitPolicy? = packet.awaitsResult ? .init(
                    refetchAfterSuccess: packet.refetchAfterSuccess, deadline: packet.deadline,
                    authorize: {
                        try await packet.authorize()
                        try cancellation.check(deadline: packet.deadline)
                    }, validateCommit: {
                        try packet.validateCommit()
                        try cancellation.check(deadline: packet.deadline)
                    }, recordEffect: packet.recordEffect) : nil
                let controller = OriginalPageController(rootView: JsBridgeBrowserView(
                    urlString: url.absoluteString, title: ticket.presentation.title,
                    initialRequest: request, sourceRunHandler: nil,
                    userAgent: userAgent?.isEmpty == false ? userAgent : nil,
                    finishesWhenChallengeClears: packet.awaitsResult,
                    originalAwaitPolicy: awaitPolicy,
                    originalPageLoadCheck: {
                        // Normal nonawait producer cleanup does not revoke the
                        // accepted page; only its explicit UI lifetime cancels it.
                        try cancellation.check(deadline: packet.awaitsResult ? packet.deadline : .distantFuture)
                    },
                    onOriginalAwaitCompletion: { completeOriginal(ticket, result: $0) },
                    onOriginalPageReady: { [weak ticket] controls in
                        (ticket?.controller as? OriginalPageController)?.pageControls = controls
                    },
                    onDismiss: { _ in userCancelledOriginal(ticket) }
                ))
                controller.removed = {
                    // Owned dismissal uses its completion callback; external
                    // removal still has this actual UIKit lifecycle signal.
                    if !ticket.closing { finishOriginal(ticket) }
                }
                // A native full-screen browser keeps the parent form mounted.
                // Removing that form's view would trigger its real exit/cancel
                // handler while this child presentation is still in flight.
                controller.modalPresentationStyle = .overFullScreen
                ticket.controller = controller
                guard ticket.presentation.recordEffect("sourceBrowserMayPresent") else { throw CancellationError() }
                ticket.startedPresentation = true
                topVC.present(controller, animated: true) {
                    ticket.completedPresentation = true
                    // This effect describes an actual page, even if authorization
                    // was revoked while UIKit was presenting it.
                    let recorded = ticket.presentation.recordEffect("sourceBrowserPresented")
                    if ticket.cancelled || ticket.ended || !recorded || ticket.closeRequested {
                        if ticket.terminal == nil { ticket.terminal = .failure(CancellationError()) }
                        if !ticket.presentation.awaitsResult { ticket.resolve(.failure(CancellationError())) }
                        closeOriginal(ticket)
                        return
                    }
                    NotificationCenter.default.post(name: originalPageDidPresent, object: nil,
                        userInfo: ["taskID": ticket.presentation.taskID])
                    ticket.work = Task { @MainActor in
                        do {
                            try await ticket.presentation.authorize()
                            try Task.checkCancellation()
                            guard !ticket.cancelled, !ticket.ended else { throw CancellationError() }
                            ticket.acceptPresentation()
                            ticket.work = nil
                        } catch {
                            ticket.setTerminal(.failure(error))
                            if !ticket.presentation.awaitsResult { ticket.resolve(.failure(error)) }
                            closeOriginal(ticket)
                        }
                    }
                }
            } catch {
                ticket.setTerminal(.failure(error))
                if !ticket.presentation.awaitsResult { ticket.resolve(.failure(error)) }
                if ticket.startedPresentation { closeOriginal(ticket) }
                else { finishOriginal(ticket) }
            }
        }
    }

    private struct Pending {
        enum Content {
            case page(SourceBrowserRequest)
            case captcha(SourceCaptchaRequest)
            case originalPage(OriginalPageTicket)
        }

        let completion: (String?) -> Void
        let content: Content
    }

    private static var waiting: [Pending] = []
    private static var isShowingSheet = false

    private static func presentNextIfIdle() {
        guard !isShowingSheet, !waiting.isEmpty else { return }
        let pending = waiting.removeFirst()
        if case .originalPage(let ticket) = pending.content {
            isShowingSheet = true
            startOriginal(ticket)
            return
        }
        guard let topVC = BookSourceFormLoginView.topViewController() else {
            pending.completion(nil)
            presentNextIfIdle()
            return
        }
        isShowingSheet = true
        // The awaiting script is blocked until this fires; the box guarantees it does,
        // including when the sheet is swiped away instead of dismissed by a button.
        let awaitBox = BrowserAwaitBox { answer in
            pending.completion(answer)
            Task { @MainActor in
                isShowingSheet = false
                presentNextIfIdle()
            }
        }
        // `topVC` weakly: a strong capture would form a presenter ⇄ presented cycle that
        // outlives dismissal, and the box's deinit is what releases the script when the
        // sheet goes away without a button tap.
        let finish: (String?) -> Void = { [weak topVC] answer in
            guard let topVC else { awaitBox.finish(answer); return }
            topVC.dismiss(animated: true) {
                awaitBox.finish(answer)
            }
        }
        let hostVC: UIViewController
        switch pending.content {
        case .page(let request):
            let userAgent = request.urlRequest?.value(forHTTPHeaderField: "User-Agent")
            hostVC = UIHostingController(
                rootView: JsBridgeBrowserView(
                    // The request's URL, not the source's string: `url,{options}` is not a URL.
                    urlString: request.urlRequest?.url?.absoluteString ?? request.url,
                    title: request.title,
                    initialHTML: request.html,
                    initialRequest: request.urlRequest,
                    userAgent: userAgent?.isEmpty == false ? userAgent : nil,
                    finishesWhenChallengeClears: request.awaitsResult,
                    onDismiss: finish
                )
            )
            // Phone-oriented login pages need the full iPad viewport; a nested form sheet
            // can clip the submit controls below its fixed height.
            if topVC.traitCollection.userInterfaceIdiom == .pad {
                hostVC.modalPresentationStyle = .fullScreen
            }
        case .originalPage:
            // Handled before the legacy page/captcha path above.
            return
        case .captcha(let request):
            hostVC = UIHostingController(
                rootView: SourceCaptchaView(request: request, onFinish: finish)
            )
            hostVC.sheetPresentationController?.detents = [.medium(), .large()]
        }
        topVC.present(hostVC, animated: true)
    }
}
