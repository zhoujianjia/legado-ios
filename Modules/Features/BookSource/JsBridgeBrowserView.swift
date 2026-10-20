import SwiftUI
import WebKit
import Combine
import ObjectiveC
import LegadoRuntime

/// Paragraph-review sheets deliberately use only the source page's own UI.
/// Login and other source browsers keep `JsBridgeBrowserView`'s normal toolbar.
enum ParagraphReviewBrowserPresentationPolicy {
    static let hidesToolbar = true
}

struct SourceBrowserPresentationConfiguration: Equatable {
    var heightPercentage: Double?
    var skipCollapsed = false
    var isHideable = true
    var expandedCornersRadius: Double?

    init(json: String) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        if let value = object["heightPercentage"] as? NSNumber,
           value.doubleValue > 0,
           value.doubleValue <= 1 {
            heightPercentage = value.doubleValue
        }
        if let value = object["skipCollapsed"] as? Bool { skipCollapsed = value }
        if let value = object["isHideable"] as? Bool { isHideable = value }
        if let value = object["expandedCornersRadius"] as? NSNumber,
           value.doubleValue >= 0,
           value.doubleValue <= 120 {
            expandedCornersRadius = value.doubleValue
        }
        // `hardwareAccelerated` is accepted as a no-op: WKWebView already uses
        // accelerated compositing and iOS exposes no per-page switch for it.
    }

    var detents: Set<PresentationDetent> {
        guard let heightPercentage else { return [.medium, .large] }
        let expanded: PresentationDetent = heightPercentage >= 1
            ? .large
            : .fraction(heightPercentage)
        return skipCollapsed ? [expanded] : [.medium, expanded]
    }
}

// Modal WebView launched by `java.startBrowser` / `java.startBrowserAwait`.
// Shows a loading state (spinner + top progress bar) while the page loads so
// slow login/key servers don't appear as a frozen blank sheet, plus an error
// state with retry. Syncs WKWebView cookies into CookieStore and
// HTTPCookieStorage when the user taps "Done" (and on each navigation finish).

/// A single awaited page borrows the existing task/source grant. No page data
/// or credential state is persisted here; Cookie writes use the existing owner.
struct OriginalBrowserAwaitPolicy: Sendable {
    let refetchAfterSuccess: Bool
    let deadline: Date
    let authorize: @Sendable () async throws -> Void
    let validateCommit: @Sendable () throws -> Void
    let recordEffect: @Sendable (String) -> Bool
}

/// Handles only the mounted Coordinator's existing task and page-close event.
/// The Presenter retains these until the actual controller has disappeared.
struct OriginalBrowserPageControls {
    let requestClose: @MainActor () -> Void
    let stopLoading: @MainActor () -> Void
    let cancelAndDrain: @MainActor () async -> Void
}

struct JsBridgeBrowserView: View {
    let urlString: String
    let title: String
    let onDismiss: (_ body: String?) -> Void
    let hidesToolbar: Bool
    let initialHTML: String?
    let initialRequest: URLRequest?
    let injectedJavaScript: String
    let sourceRunHandler: ((String) async throws -> String)?
    let sourceConfigurationUpdateHandler: ((String) -> Void)?
    /// The source's User-Agent. Legado opens a source's page with it, and Cloudflare ties
    /// `cf_clearance` to the User-Agent that solved the challenge: cleared under any other,
    /// the cookie is useless to the source's own requests. nil keeps `SourceWebIdentity`.
    let userAgent: String?
    /// Legado's `sourceVerificationEnable` (a page `java.startBrowserAwait` waits for): once
    /// a Cloudflare challenge on the page clears, the page finishes as if ✓ were tapped.
    let finishesWhenChallengeClears: Bool
    let originalAwaitPolicy: OriginalBrowserAwaitPolicy?
    let originalPageLoadCheck: (@Sendable () throws -> Void)?
    let onOriginalAwaitCompletion: ((Result<LegadoOriginalBrowserCompletion, any Error>) -> Void)?
    let onOriginalPageReady: ((OriginalBrowserPageControls) -> Void)?
    let onOriginalPageLoaded: (() -> Void)?

    init(
        urlString: String,
        title: String = "",
        hidesToolbar: Bool = false,
        initialHTML: String? = nil,
        initialRequest: URLRequest? = nil,
        injectedJavaScript: String = "",
        sourceRunHandler: ((String) async throws -> String)? = nil,
        sourceConfigurationUpdateHandler: ((String) -> Void)? = nil,
        userAgent: String? = nil,
        finishesWhenChallengeClears: Bool = false,
        originalAwaitPolicy: OriginalBrowserAwaitPolicy? = nil,
        originalPageLoadCheck: (@Sendable () throws -> Void)? = nil,
        onOriginalAwaitCompletion: ((Result<LegadoOriginalBrowserCompletion, any Error>) -> Void)? = nil,
        onOriginalPageReady: ((OriginalBrowserPageControls) -> Void)? = nil,
        onOriginalPageLoaded: (() -> Void)? = nil,
        onDismiss: @escaping (_ body: String?) -> Void
    ) {
        self.urlString = urlString
        self.title = title
        self.hidesToolbar = hidesToolbar
        self.initialHTML = initialHTML
        self.initialRequest = initialRequest
        self.injectedJavaScript = injectedJavaScript
        self.sourceRunHandler = sourceRunHandler
        self.sourceConfigurationUpdateHandler = sourceConfigurationUpdateHandler
        self.userAgent = userAgent
        self.finishesWhenChallengeClears = finishesWhenChallengeClears
        self.originalAwaitPolicy = originalAwaitPolicy
        self.originalPageLoadCheck = originalPageLoadCheck
        self.onOriginalAwaitCompletion = onOriginalAwaitCompletion
        self.onOriginalPageReady = onOriginalPageReady
        self.onOriginalPageLoaded = onOriginalPageLoaded
        self.onDismiss = onDismiss
    }

    @StateObject private var bridge = JsBridgeBrowserBridge()
    @State private var isSyncing = false

    private var navTitle: String { title.isEmpty ? localized("瀏覽器") : title }

    var body: some View {
        if hidesToolbar {
            contentView
        } else {
            NavigationStack {
                contentView
                    .navigationTitle(navTitle)
                    .toolbarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button {
                                if originalAwaitPolicy != nil {
                                    isSyncing = true
                                    if let cancel = bridge.cancelOriginalAwait { cancel() }
                                    else { onDismiss(nil) }
                                    return
                                }
                                // XHR-based login can set cookies after the last
                                // navigation finished. Persist that final jar even
                                // on cancellation; nil still tells source JS that
                                // the browser was dismissed without confirmation.
                                isSyncing = true
                                guard let sync = bridge.syncCookiesAndDismiss else {
                                    onDismiss(nil)
                                    return
                                }
                                sync { _ in onDismiss(nil) }
                            } label: {
                                Label(localized("取消"), systemImage: "xmark")
                                    .labelStyle(.iconOnly)
                            }
                            .accessibilityLabel(localized("取消"))
                            .disabled(isSyncing)
                        }
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button {
                                bridge.reload?()
                            } label: {
                                Label(localized("網頁：重新整理"), systemImage: "arrow.clockwise")
                                    .labelStyle(.iconOnly)
                            }
                            .accessibilityLabel(localized("網頁：重新整理"))
                            .disabled(isSyncing)
                        }
                        ToolbarItem(placement: .navigationBarTrailing) {
                            if isSyncing {
                                ProgressView().scaleEffect(0.85)
                            } else {
                                Button {
                                    confirm()
                                } label: {
                                    Label(localized("完成"), systemImage: "checkmark")
                                        .labelStyle(.iconOnly)
                                }
                                .accessibilityLabel(localized("完成"))
                            }
                        }
                    }
                    .onChange(of: bridge.challengeCleared) { _, cleared in
                        if cleared, !isSyncing { confirm() }
                    }
                    .onChange(of: bridge.originalCloseRequested) { _, requested in
                        if requested, !isSyncing { confirm() }
                    }
            }
        }
    }

    /// ✓: keep the page's cookies and hand its HTML back.
    private func confirm() {
        guard !isSyncing else { return }
        isSyncing = true
        if originalAwaitPolicy != nil {
            guard let complete = bridge.completeOriginalAwait else {
                onOriginalAwaitCompletion?(.failure(LegadoRuntimeError(code: "BROWSER_NOT_PRESENTED",
                    message: "The awaited browser is not available")))
                return
            }
            complete()
            return
        }
        guard let sync = bridge.syncCookiesAndDismiss else {
            onDismiss(nil)
            return
        }
        sync { body in onDismiss(body) }
    }

    private var contentView: some View {
        ZStack(alignment: .top) {
            JsBridgeBrowserRepresentable(
                urlString: urlString,
                initialHTML: initialHTML,
                injectedJavaScript: injectedJavaScript,
                sourceRunHandler: sourceRunHandler,
                sourceConfigurationUpdateHandler: sourceConfigurationUpdateHandler,
                bridge: bridge,
                initialRequest: initialRequest,
                userAgent: userAgent,
                finishesWhenChallengeClears: finishesWhenChallengeClears,
                originalAwaitPolicy: originalAwaitPolicy,
                originalPageLoadCheck: originalPageLoadCheck,
                onOriginalAwaitCompletion: onOriginalAwaitCompletion,
                onOriginalPageReady: onOriginalPageReady,
                onOriginalPageLoaded: onOriginalPageLoaded
            )
                .edgesIgnoringSafeArea(hidesToolbar ? .all : [])

            // Full-screen state until the page delivers its first content.
            switch bridge.phase {
            case .loading:
                loadingOverlay
            case .failed:
                errorOverlay
            case .committed, .finished:
                EmptyView()
            }

            // Safari-style thin progress bar across the top while loading.
            if (bridge.phase == .loading || bridge.phase == .committed), bridge.progress < 1 {
                ProgressView(value: max(bridge.progress, 0.03))
                    .progressViewStyle(.linear)
                    .tint(DSColor.accent)
                    .transition(.opacity)
            }
        }
        .animation(DSAnimation.fast, value: bridge.phase)
        .animation(DSAnimation.fast, value: bridge.progress)
    }

    // MARK: - Overlays

    private var loadingOverlay: some View {
        ZStack {
            DSColor.background.ignoresSafeArea()
            VStack(spacing: DSSpacing.md) {
                ProgressView()
                    .controlSize(.large)
                Text(localized("載入中…"))
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textSecondary)
            }
        }
        .transition(.opacity)
    }

    private var errorOverlay: some View {
        ZStack {
            DSColor.background.ignoresSafeArea()
            VStack(spacing: DSSpacing.md) {
                Image(systemName: "wifi.exclamationmark")
                    .font(DSFont.largeTitle)
                    .foregroundStyle(DSColor.textSecondary)
                Text(localized("載入失敗"))
                    .font(DSFont.headline)
                    .foregroundStyle(DSColor.textPrimary)
                if let detail = bridge.errorText, !detail.isEmpty {
                    Text(detail)
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.textSecondary)
                        .multilineTextAlignment(.center)
                }
                Button(localized("重試")) { bridge.reload?() }
                    .buttonStyle(.bordered)
                    .tint(DSColor.accent)
            }
            .padding(DSSpacing.lg)
        }
        .transition(.opacity)
    }
}

/// Presents a decoded paragraph-review target. Source-authored pages keep the same native
/// sheet/browser shell as ordinary review URLs, but receive the `window.run` bridge they need
/// to call back into their own shared Legado runtime.
struct LegadoReviewBrowserView: View {
    let target: ReaderHTMLUtilities.ReviewTarget
    let onDismiss: (_ body: String?) -> Void
    @State private var configurationJSON: String

    init(
        target: ReaderHTMLUtilities.ReviewTarget,
        onDismiss: @escaping (_ body: String?) -> Void
    ) {
        self.target = target
        self.onDismiss = onDismiss
        _configurationJSON = State(initialValue: target.sourceBrowserPage?.configurationJSON ?? "")
    }

    var body: some View {
        Group {
            if let page = target.sourceBrowserPage {
            JsBridgeBrowserView(
                urlString: page.baseURL,
                title: target.title,
                hidesToolbar: ParagraphReviewBrowserPresentationPolicy.hidesToolbar,
                initialHTML: page.html,
                initialRequest: target.browserRequest,
                injectedJavaScript: page.injectedJavaScript,
                sourceRunHandler: { script in
                    try await LegadoReviewActionRunner.shared.runSourcePageScript(
                        script,
                        sourceURL: page.sourceURL,
                        actionContext: page.actionContext
                    )
                },
                sourceConfigurationUpdateHandler: { configurationJSON = $0 },
                onDismiss: onDismiss
            )
            } else {
                JsBridgeBrowserView(
                    urlString: target.url,
                    title: target.title,
                    hidesToolbar: ParagraphReviewBrowserPresentationPolicy.hidesToolbar,
                    initialRequest: target.browserRequest,
                    onDismiss: onDismiss
                )
            }
        }
        .presentationDetents(presentationConfiguration.detents)
        .presentationDragIndicator(
            presentationConfiguration.skipCollapsed ? .hidden : .visible
        )
        .interactiveDismissDisabled(!presentationConfiguration.isHideable)
        .presentationCornerRadius(
            presentationConfiguration.expandedCornersRadius.map { CGFloat($0) }
        )
    }

    private var presentationConfiguration: SourceBrowserPresentationConfiguration {
        SourceBrowserPresentationConfiguration(
            json: configurationJSON
        )
    }
}

// MARK: - JsBridgeBrowserBridge

final class JsBridgeBrowserBridge: ObservableObject {
    enum Phase { case loading, committed, finished, failed }

    var syncCookiesAndDismiss: ((@escaping (String?) -> Void) -> Void)?
    var reload: (() -> Void)?
    var completeOriginalAwait: (() -> Void)?
    var cancelOriginalAwait: (() -> Void)?

    @Published var progress: Double = 0
    @Published var phase: Phase = .loading
    @Published var errorText: String?
    /// A Cloudflare challenge on the page has cleared (see `finishesWhenChallengeClears`).
    @Published var challengeCleared = false
    @Published var originalCloseRequested = false
}

// MARK: - UIViewRepresentable

struct JsBridgeBrowserRepresentable: UIViewRepresentable {
    let urlString: String
    let initialHTML: String?
    let injectedJavaScript: String
    let sourceRunHandler: ((String) async throws -> String)?
    let sourceConfigurationUpdateHandler: ((String) -> Void)?
    let bridge: JsBridgeBrowserBridge
    var initialRequest: URLRequest? = nil
    var userAgent: String? = nil
    var finishesWhenChallengeClears = false
    var originalAwaitPolicy: OriginalBrowserAwaitPolicy? = nil
    var originalPageLoadCheck: (@Sendable () throws -> Void)? = nil
    var onOriginalAwaitCompletion: ((Result<LegadoOriginalBrowserCompletion, any Error>) -> Void)? = nil
    var onOriginalPageReady: ((OriginalBrowserPageControls) -> Void)? = nil
    var onOriginalPageLoaded: (() -> Void)? = nil

    static let sourceJavaPromptName = SourceWebUIDelegate.sourceBridgePromptName

    static func sourcePageBootstrap(injectedJavaScript: String) -> String {
        let unavailableMessage = javaScriptStringLiteral(
            localized("段評執行環境不可用")
        )
        return """
        window.java = window.java || {};
        window.cache = window.cache || {};
        window.source = window.source || {};
        (function () {
            if (window.java.__yueduSourceNetworkInstalled) return;
            function callNative(method, args) {
                var payload = JSON.stringify({
                    method: method,
                    arguments: Array.prototype.slice.call(args)
                });
                var value = window.prompt('\(sourceJavaPromptName)', payload);
                if (value === null) {
                    throw new Error(\(unavailableMessage) + ': java.' + method);
                }
                return value;
            }
            ['ajax', 'get', 'post', 'head', 'connect', 'upConfig'].forEach(function (method) {
                Object.defineProperty(window.java, method, {
                    configurable: true,
                    value: function () { return callNative(method, arguments); }
                });
            });
            window.java.__yueduSourceNetworkInstalled = true;
        })();
        window.run = function (script) {
            return window.webkit.messageHandlers.\(Coordinator.sourceRunMessageName)
                .postMessage(String(script == null ? '' : script));
        };
        \(injectedJavaScript)
        """
    }

    private static func javaScriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return encoded
    }

    /// Android exposes `upConfig` on `WebJsExtensions`, not on the parser's
    /// `JsExtensions`. A source-authored page calls it to update the active
    /// four-argument `showBrowser` sheet configuration (for example, resizing a
    /// comments panel after it has measured its content).
    static func sourceConfigurationJSON(forPromptPayload payload: String) throws -> String? {
        guard payload.utf8.count <= 256 * 1024,
              let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String else {
            throw sourcePageBridgeError()
        }
        guard method == "upConfig" else { return nil }
        guard let arguments = object["arguments"] as? [Any],
              arguments.count == 1,
              let configurationJSON = arguments[0] as? String,
              configurationJSON.utf8.count <= 64 * 1024,
              let configurationData = configurationJSON.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: configurationData)) is [String: Any] else {
            throw sourcePageBridgeError()
        }
        return configurationJSON
    }

    private static func sourcePageBridgeError() -> NSError {
        NSError(
            domain: "SourcePageJavaBridge",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: localized("段評執行環境不可用")]
        )
    }

    /// Turns a bounded WebView request into source-runtime JS. Only Android's browser-page
    /// network surface is accepted; the method name is never interpolated before allowlisting,
    /// and argument JSON is re-encoded before it reaches JavaScriptCore. The evaluated call then
    /// travels through the same `ModernParserBridge` / `BookSourceSession` request pipeline as
    /// chapter parsing, preserving source headers, login headers, cookies, and AnalyzeUrl options.
    static func sourceJavaScript(forPromptPayload payload: String) throws -> String {
        guard payload.utf8.count <= 256 * 1024,
              let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String,
              ["ajax", "get", "post", "head", "connect"].contains(method),
              let arguments = object["arguments"] as? [Any],
              !arguments.isEmpty,
              arguments.count <= 4,
              arguments[0] is String,
              JSONSerialization.isValidJSONObject(arguments),
              let argumentsData = try? JSONSerialization.data(
                withJSONObject: arguments,
                options: [.withoutEscapingSlashes]
              ),
              let argumentsJSON = String(data: argumentsData, encoding: .utf8) else {
            throw sourcePageBridgeError()
        }

        let call = "java.\(method).apply(java, \(argumentsJSON))"
        if method == "head" {
            return """
            (function () {
                var response = \(call);
                var headers = response && typeof response.headers === 'function'
                    ? response.headers() : response;
                if (!headers) return '{}';
                if (typeof headers.keySet === 'function' && typeof headers.get === 'function') {
                    var object = {};
                    var keys = headers.keySet();
                    for (var i = 0; i < keys.length; i++) object[String(keys[i])] = headers.get(keys[i]);
                    return JSON.stringify(object);
                }
                return JSON.stringify(headers);
            })()
            """
        }
        if method == "connect" {
            return """
            (function () {
                var response = \(call);
                if (response == null) return '';
                return typeof response.toString === 'function'
                    ? String(response.toString()) : String(response);
            })()
            """
        }
        return """
        (function () {
            var response = \(call);
            if (response == null) return '';
            if (typeof response.body === 'function') {
                var body = response.body();
                return String(body == null ? '' : body);
            }
            return String(response);
        })()
        """
    }

    func makeUIView(context: Context) -> WKWebView {
        // Let JavaScript-driven input focus raise the keyboard (SMS 验证码 fields focus a hidden
        // <input> on tap; the 番茄 验证码 step couldn't open the keyboard otherwise). One-time,
        // process-wide WKContentView patch.
        _ = WKWebView.patchKeyboardFocusOnce

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        prefs.preferredContentMode = SourceWebIdentity.contentMode(desktop: false)
        config.defaultWebpagePreferences = prefs
        // A captcha/OAuth widget that opens itself (not from a tap) is blocked before
        // the UI delegate is ever consulted unless script-opened windows are allowed.
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        context.coordinator.clipboardBridge.install(in: config.userContentController)
        context.coordinator.sourceRunHandler = sourceRunHandler
        context.coordinator.sourceConfigurationUpdateHandler = sourceConfigurationUpdateHandler
        if sourceRunHandler != nil {
            context.coordinator.uiDelegate.sourceBridgePromptHandler = { [weak coordinator = context.coordinator] payload, completion in
                guard let coordinator else {
                    completion(nil)
                    return
                }
                coordinator.handleSourceJavaPrompt(payload, completion: completion)
            }
            config.userContentController.addScriptMessageHandler(
                context.coordinator,
                contentWorld: .page,
                name: Coordinator.sourceRunMessageName
            )
            let bootstrap = Self.sourcePageBootstrap(injectedJavaScript: injectedJavaScript)
            config.userContentController.addUserScript(
                WKUserScript(source: bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }

        let wv = WKWebView(frame: .zero, configuration: config)
        SourceWebIdentity.apply(desktop: false, to: wv)
        if let userAgent {
            wv.customUserAgent = userAgent
        }
        context.coordinator.finishesWhenChallengeClears = finishesWhenChallengeClears
        context.coordinator.originalAwaitPolicy = originalAwaitPolicy
        context.coordinator.originalPageLoadCheck = originalPageLoadCheck
        context.coordinator.onOriginalAwaitCompletion = onOriginalAwaitCompletion
        context.coordinator.onOriginalPageLoaded = onOriginalPageLoaded
        if originalAwaitPolicy != nil {
            context.coordinator.uiDelegate.onCloseRequested = { [weak coordinator = context.coordinator] in
                coordinator?.requestOriginalPageClose()
            }
            // Locked basicJs overrides only the page's close function here.
            // This finite signal installs no source Java/cache/run evaluator.
            config.userContentController.addScriptMessageHandler(context.coordinator,
                contentWorld: .page, name: Coordinator.originalCloseMessageName)
            config.userContentController.addUserScript(WKUserScript(source: """
                window.close = function() {
                    window.webkit.messageHandlers.\(Coordinator.originalCloseMessageName).postMessage(null);
                };
                """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        wv.navigationDelegate = context.coordinator
        // `uiDelegate` is weak — the Coordinator owns it. Without it the page's
        // `window.open` / `alert` / `confirm` are dropped without a trace.
        wv.uiDelegate = context.coordinator.uiDelegate
        context.coordinator.webView = wv
        context.coordinator.bridge = bridge

        // Drive the progress bar from the live load estimate.
        context.coordinator.progressObservation = wv.observe(\.estimatedProgress, options: [.new]) { [weak bridge] web, _ in
            DispatchQueue.main.async { bridge?.progress = web.estimatedProgress }
        }

        context.coordinator.installKeyboardReFocusWorkaround()

        let coordinator = context.coordinator
        bridge.syncCookiesAndDismiss = { [weak coordinator] completion in
            guard let wv = coordinator?.webView else { completion(nil); return }
            coordinator?.syncCookiesAndDismiss(from: wv, completion: completion)
        }
        bridge.completeOriginalAwait = { [weak coordinator] in
            guard let coordinator, let webView = coordinator.webView else { return }
            coordinator.completeOriginalAwait(from: webView)
        }
        bridge.cancelOriginalAwait = { [weak coordinator] in
            guard let coordinator, let webView = coordinator.webView else { return }
            coordinator.cancelOriginalAwait(from: webView)
        }
        onOriginalPageReady?(coordinator.originalPageControls())
        bridge.reload = { [weak coordinator, weak bridge] in
            guard let coordinator, let wv = coordinator.webView else { return }
            bridge?.phase = .loading
            bridge?.errorText = nil
            bridge?.progress = 0
            coordinator.loadInitial(
                urlString: urlString,
                html: initialHTML,
                request: initialRequest,
                in: wv
            )
        }

        context.coordinator.loadInitial(urlString: urlString, html: initialHTML, request: initialRequest, in: wv)
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stopPageLoading()
        coordinator.uiDelegate.onCloseRequested = nil
        uiView.configuration.userContentController.removeScriptMessageHandler(
            forName: Coordinator.sourceRunMessageName,
            contentWorld: .page
        )
        uiView.configuration.userContentController.removeScriptMessageHandler(
            forName: Coordinator.originalCloseMessageName, contentWorld: .page)
        coordinator.clipboardBridge.remove(from: uiView.configuration.userContentController)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
        static let sourceRunMessageName = "yueduSourceRun"
        static let originalCloseMessageName = "yueduOriginalBrowserClose"

        weak var webView: WKWebView?
        weak var bridge: JsBridgeBrowserBridge?
        var progressObservation: NSKeyValueObservation?
        var sourceRunHandler: ((String) async throws -> String)?
        var sourceConfigurationUpdateHandler: ((String) -> Void)?
        var finishesWhenChallengeClears = false
        var originalAwaitPolicy: OriginalBrowserAwaitPolicy?
        var originalPageLoadCheck: (@Sendable () throws -> Void)?
        var onOriginalAwaitCompletion: ((Result<LegadoOriginalBrowserCompletion, any Error>) -> Void)?
        var onOriginalPageLoaded: (() -> Void)?
        var originalAwaitWork: Task<Void, Never>?
        private var initialLoadWork: Task<Void, Never>?
        private var initialLoadGeneration = UUID()
        private var pageLoadStopped = false
        /// Tests may hold delivery only after this same real WK operation calls
        /// back. Production always uses the actual existing Cookie store.
        var initialCookieSeeder: @MainActor (WKHTTPCookieStore, HTTPCookie, @escaping @Sendable () -> Void) -> Void = {
            store, cookie, completion in store.setCookie(cookie, completionHandler: completion)
        }
        /// A page of this navigation history was a Cloudflare challenge.
        private(set) var sawChallenge = false
        /// Strongly held: `WKWebView.uiDelegate` is weak.
        let uiDelegate = SourceWebUIDelegate()
        let clipboardBridge = SourceWebClipboardBridge()
        private var keyboardHideObserver: NSObjectProtocol?

        /// WKWebView keeps the tapped `<input>` as `document.activeElement` after the keyboard is
        /// dismissed, so tapping it again fires no new focus event and the keyboard never returns
        /// (e.g. you collapse the 番茄 验证码 keyboard, then can't reopen it). Blur the active
        /// element once the keyboard is fully gone so the next tap is a fresh focus.
        func installKeyboardReFocusWorkaround() {
            keyboardHideObserver = NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardDidHideNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.webView?.evaluateJavaScript(
                    "if (document.activeElement && document.activeElement.blur) { document.activeElement.blur(); }",
                    completionHandler: nil
                )
            }
        }

        deinit {
            if let keyboardHideObserver {
                NotificationCenter.default.removeObserver(keyboardHideObserver)
            }
        }

        private func setPhase(_ phase: JsBridgeBrowserBridge.Phase, error: String? = nil) {
            DispatchQueue.main.async { [weak self] in
                self?.bridge?.phase = phase
                if let error { self?.bridge?.errorText = error }
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            do {
                guard !pageLoadStopped else { decisionHandler(.cancel); return }
                try originalPageLoadCheck?()
            } catch { decisionHandler(.cancel); return }
            // Intercept book-source import deep links so WKWebView doesn't try to
            // navigate to them (an unhandled custom scheme fails as "unsupported URL").
            // We handle our own `yuedu://` scheme (來源配置 and module links) plus Legado's
            // `legado://import/...`, which most 書源 update pages emit (e.g. the 更新書源
            // download button).
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            let scheme = url.scheme?.lowercased()
            let isImportDeepLink = scheme == "yuedu"
                || (scheme == "legado" && url.host?.lowercased() == "import")
            guard isImportDeepLink else {
                decisionHandler(.allow)
                return
            }

            handleImportURL(url, webView: webView)
            decisionHandler(.cancel)
        }

        @MainActor
        func load(url: URL, request initialRequest: URLRequest? = nil, html: String? = nil, in webView: WKWebView) {
            guard !pageLoadStopped else { return }
            // Attach source credentials only to the exact destination prepared by its runtime.
            let request: URLRequest
            if let initialRequest, initialRequest.url == url {
                request = initialRequest
            } else {
                request = URLRequest(url: url)
            }
            let previous = initialLoadWork
            previous?.cancel()
            let generation = UUID()
            initialLoadGeneration = generation
            // Each replacement drains its predecessor, including native Cookie
            // callbacks that cannot be retracted by cancelling a Swift Task.
            initialLoadWork = Task { @MainActor [weak self, weak webView] in
                if let previous { await previous.value }
                guard let self, let webView else { return }
                let started = SourcePerfTrace.now
                var seededCookieCount = 0
                defer {
                    SourcePerfTrace.record("legado.original.browser.initial",
                        "main=\(Thread.isMainThread) cookies=\(seededCookieCount)", since: started)
                    if self.initialLoadGeneration == generation { self.initialLoadWork = nil }
                }
                var effects: [String] = []
                do {
                    try self.checkInitialLoad(generation)
                    if let policy = self.originalAwaitPolicy {
                        try await policy.authorize()
                        try policy.validateCommit()
                        try self.checkInitialLoad(generation)
                    }
                    let cookies = Self.cookiesForInitialLoad(url: url)
                    seededCookieCount = cookies.count
                    if self.originalAwaitPolicy != nil, cookies.count > 16_384 {
                        throw LegadoRuntimeError(code: "STATE_LIMIT", message: "Too many initial browser Cookies")
                    }
                    let store = webView.configuration.websiteDataStore.httpCookieStore
                    let group = DispatchGroup()
                    var issued = 0
                    var issueError: (any Error)?
                    for cookie in cookies {
                        do {
                            try self.checkInitialLoad(generation)
                            if let policy = self.originalAwaitPolicy {
                                try policy.validateCommit()
                                if issued == 0 {
                                    guard policy.recordEffect("sourceBrowserCookieSeedIssued") else { throw CancellationError() }
                                    effects.append("sourceBrowserCookieSeedIssued")
                                }
                            }
                            group.enter()
                            issued += 1
                            self.initialCookieSeeder(store, cookie) { group.leave() }
                        } catch { issueError = error; break }
                    }
                    // Cancellation never short-circuits this continuation. All
                    // issued setCookie callbacks must finish before the task ends.
                    await withCheckedContinuation { continuation in
                        group.notify(queue: .main) { continuation.resume() }
                    }
                    if issued > 0, issued == cookies.count, let policy = self.originalAwaitPolicy {
                        effects.append("sourceBrowserCookieSeedCompleted")
                        _ = policy.recordEffect("sourceBrowserCookieSeedCompleted")
                    }
                    if let issueError { throw issueError }
                    try self.checkInitialLoad(generation)
                    if let policy = self.originalAwaitPolicy {
                        try await policy.authorize()
                        try policy.validateCommit()
                        try self.checkInitialLoad(generation)
                    }
                    if let html {
                        // Same owned generation/token and real Cookie callback
                        // drain as URL loads. This HTML is a JVM POST response,
                        // not a new HTTP transport or a local source JS bridge.
                        webView.loadHTMLString(html, baseURL: url)
                    } else {
                        webView.load(request)
                    }
                } catch {
                    guard self.initialLoadGeneration == generation, !self.pageLoadStopped else { return }
                    if self.originalAwaitPolicy != nil {
                        let typed = error as? LegadoRuntimeError
                        let retained = (effects + (typed?.completedEffects ?? [])).reduce(into: [String]()) {
                            if !$0.contains($1) { $0.append($1) }
                        }
                        self.onOriginalAwaitCompletion?(.failure(LegadoRuntimeError(
                            code: error is CancellationError ? "CANCELLED" : (typed?.code ?? "STATE_IO"),
                            message: "The awaited browser could not start", completedEffects: retained)))
                    } else { self.setPhase(.failed, error: localized("載入失敗")) }
                }
            }
        }

        @MainActor
        func loadInitial(urlString: String, html: String?, request: URLRequest? = nil, in webView: WKWebView) {
            guard !pageLoadStopped else { return }
            if let html, originalPageLoadCheck != nil, let url = URL(string: urlString) {
                load(url: url, request: request, html: html, in: webView)
            } else if let html {
                webView.loadHTMLString(html, baseURL: URL(string: urlString))
            } else if let url = URL(string: urlString) {
                load(url: url, request: request, in: webView)
            }
        }

        @MainActor
        private func checkInitialLoad(_ generation: UUID) throws {
            try Task.checkCancellation()
            guard !pageLoadStopped, initialLoadGeneration == generation else { throw CancellationError() }
            try originalPageLoadCheck?()
        }

        @MainActor
        func stopPageLoading() {
            // Seal future reload/notify/navigation admission before touching
            // handles; the latest task still retains its complete reload chain.
            pageLoadStopped = true
            initialLoadGeneration = UUID()
            webView?.stopLoading()
            initialLoadWork?.cancel()
            originalAwaitWork?.cancel()
        }

        @MainActor
        func originalPageControls() -> OriginalBrowserPageControls {
            .init(requestClose: { [weak self] in self?.requestOriginalPageClose() },
                stopLoading: { [weak self] in self?.stopPageLoading() },
                cancelAndDrain: { [weak self] in
                    guard let self else { return }
                    let initial = self.initialLoadWork
                    let confirmation = self.originalAwaitWork
                    self.stopPageLoading()
                    if let initial { await initial.value }
                    if let confirmation { await confirmation.value }
                    self.initialLoadWork = nil
                    self.originalAwaitWork = nil
                })
        }

        // Matches the SDK requirement exactly (`WK_SWIFT_UI_ACTOR` on the protocol and the reply
        // block). Without the annotations, complete concurrency checking rejects the conformance.
        @MainActor
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage,
            replyHandler: @escaping @MainActor (Any?, String?) -> Void
        ) {
            if message.name == Self.originalCloseMessageName {
                guard originalAwaitPolicy != nil, message.frameInfo.isMainFrame else {
                    replyHandler(nil, "BROWSER_CLOSE_UNAVAILABLE")
                    return
                }
                requestOriginalPageClose()
                replyHandler(nil, nil)
                return
            }
            guard message.name == Self.sourceRunMessageName,
                  let script = message.body as? String,
                  let sourceRunHandler else {
                replyHandler(nil, localized("段評執行環境不可用"))
                return
            }
            Task {
                do {
                    replyHandler(try await sourceRunHandler(script), nil)
                } catch {
                    replyHandler(nil, error.localizedDescription)
                }
            }
        }

        func handleSourceJavaPrompt(
            _ payload: String,
            completion: @escaping (String?) -> Void
        ) {
            do {
                if let configurationJSON = try JsBridgeBrowserRepresentable
                    .sourceConfigurationJSON(forPromptPayload: payload) {
                    sourceConfigurationUpdateHandler?(configurationJSON)
                    completion("")
                    return
                }
            } catch {
                AppLogger.parse("source page upConfig rejected request", context: [
                    "error": error.localizedDescription
                ])
                completion(nil)
                return
            }
            guard let sourceRunHandler else {
                completion(nil)
                return
            }
            let script: String
            do {
                script = try JsBridgeBrowserRepresentable.sourceJavaScript(
                    forPromptPayload: payload
                )
            } catch {
                AppLogger.parse("source page java bridge rejected request", context: [
                    "error": error.localizedDescription
                ])
                completion(nil)
                return
            }
            Task { @MainActor in
                do {
                    completion(try await sourceRunHandler(script))
                } catch {
                    AppLogger.parse("source page java bridge failed", context: [
                        "error": error.localizedDescription
                    ])
                    completion(nil)
                }
            }
        }

        // MARK: Navigation phases (drive the loading / error UI)

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            setPhase(.loading)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            setPhase(.committed)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // A real load observation is useful to consumers, but is never the
            // original confirmation/result. Explicit cancellation seals it.
            if !pageLoadStopped { onOriginalPageLoaded?() }
            DispatchQueue.main.async { [weak self] in
                self?.bridge?.progress = 1
                self?.bridge?.phase = .finished
            }
            // An awaited page must not launch an unguarded Cookie write from
            // didFinish. Its checked confirmation owns the terminal capture.
            if originalAwaitPolicy == nil { syncCookiesAndDismiss(from: webView, completion: nil) }
            if finishesWhenChallengeClears {
                checkCloudflareChallenge(in: webView)
            }
        }

        /// Legado-E and MD3 both ask every finished page `!!window._cf_chl_opt` — the object
        /// Cloudflare's challenge script defines — and finish the verification on the first
        /// page after a challenge that no longer has it.
        private func checkCloudflareChallenge(in webView: WKWebView) {
            webView.evaluateJavaScript("!!window._cf_chl_opt") { [weak self] result, error in
                guard let self else { return }
                if let error {
                    if self.originalAwaitPolicy == nil {
                        AppLogger.parse("source page Cloudflare check failed", context: [
                            "error": error.localizedDescription
                        ])
                    } else {
                        AppLogger.parse("original browser challenge check failed", context: ["code": "BROWSER_EVALUATION_FAILED"])
                    }
                    return
                }
                if (result as? Bool) == true {
                    self.sawChallenge = true
                } else if self.sawChallenge {
                    self.sawChallenge = false
                    self.bridge?.challengeCleared = true
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            setPhase(.failed, error: error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            // Ignore the benign "cancelled" that follows decidePolicy(.cancel) for
            // intercepted yuedu:// / legado:// import links.
            if (error as NSError).code == NSURLErrorCancelled { return }
            setPhase(.failed, error: error.localizedDescription)
        }

        func syncCookiesAndDismiss(from webView: WKWebView, completion: ((String?) -> Void)?) {
            webView.evaluateJavaScript("document.documentElement.outerHTML") { body, _ in
                let pageBody = body as? String
                let store = webView.configuration.websiteDataStore.httpCookieStore
                let scope = webView.url
                Task { @MainActor in
                    do {
                        _ = try await CookieStore.shared.captureWebKit(store, confirming: scope)
                        completion?(pageBody)
                    } catch {
                        AppLogger.error("Source browser cookies were not persisted", error: error)
                        self.setPhase(.failed, error: localized("無法儲存"))
                        // Do not return a page as successfully confirmed.
                        completion?(nil)
                    }
                }
            }
        }

        /// Real confirmation only. A normal navigation finish never calls this.
        @MainActor
        func requestOriginalPageClose() {
            // Locked Activity.close ignores page-authored close while the
            // current page remains a challenge. User Cancel is separate.
            guard originalAwaitPolicy != nil, !sawChallenge else { return }
            bridge?.originalCloseRequested = true
        }

        @MainActor
        func completeOriginalAwait(from webView: WKWebView) {
            runOriginalAwait(from: webView, confirmed: true)
        }

        @MainActor
        func cancelOriginalAwait(from webView: WKWebView) {
            runOriginalAwait(from: webView, confirmed: false)
        }

        @MainActor
        private func runOriginalAwait(from webView: WKWebView, confirmed: Bool) {
            guard let policy = originalAwaitPolicy, originalAwaitWork == nil else { return }
            originalAwaitWork = Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                var effects: [String] = []
                do {
                    try await policy.authorize()
                    try Task.checkCancellation()
                    try policy.validateCommit()
                    let completion: LegadoOriginalBrowserCompletion?
                    if !confirmed {
                        // User Cancel keeps the existing page's Cookie capture,
                        // but is never a successful empty browser response.
                        completion = nil
                    } else if policy.refetchAfterSuccess {
                        // Locked true branch requires confirmation/Cookies, not DOM.
                        completion = .refetchConfirmed
                    } else {
                        completion = try await self.originalSnapshot(from: webView)
                    }
                    try await policy.authorize()
                    try Task.checkCancellation()
                    try policy.validateCommit()
                    guard policy.recordEffect("sourceBrowserCookieCaptureIssued") else { throw CancellationError() }
                    effects.append("sourceBrowserCookieCaptureIssued")
                    let scope: URL?
                    if case .response(let finalURL, _)? = completion { scope = URL(string: finalURL) }
                    else { scope = webView.url }
                    _ = try await CookieStore.shared.captureWebKit(
                        webView.configuration.websiteDataStore.httpCookieStore, confirming: scope,
                        validate: policy.validateCommit)
                    effects.append("sourceBrowserCookieCaptureCompleted")
                    _ = policy.recordEffect("sourceBrowserCookieCaptureCompleted")
                    try await policy.authorize()
                    try Task.checkCancellation()
                    try policy.validateCommit()
                    if let completion { self.onOriginalAwaitCompletion?(.success(completion)) }
                    else {
                        self.onOriginalAwaitCompletion?(.failure(LegadoRuntimeError(code: "BROWSER_CANCELLED",
                            message: "The awaited browser was cancelled", completedEffects: effects)))
                    }
                } catch {
                    let typed = error as? LegadoRuntimeError
                    let code: String
                    if error is CancellationError { code = "CANCELLED" }
                    else if let typed { code = typed.code }
                    else if let owner = error as? CookieOwnerError { code = owner.code }
                    else { code = "STATE_IO" }
                    let retained = (effects + (typed?.completedEffects ?? [])).reduce(into: [String]()) {
                        if !$0.contains($1) { $0.append($1) }
                    }
                    self.onOriginalAwaitCompletion?(.failure(LegadoRuntimeError(code: code,
                        message: "The awaited browser could not complete", completedEffects: retained)))
                }
                self.originalAwaitWork = nil
            }
        }

        @MainActor
        private func originalSnapshot(from webView: WKWebView) async throws -> LegadoOriginalBrowserCompletion {
            let encoded: String = try await withCheckedThrowingContinuation { continuation in
                // One page-side evaluation pairs URL and HTML before navigation
                // can make two separate WebKit callbacks describe different pages.
                webView.evaluateJavaScript("JSON.stringify({finalURL:window.location.href,body:document.documentElement.outerHTML})") { value, error in
                    guard error == nil, let encoded = value as? String else {
                        continuation.resume(throwing: LegadoRuntimeError(code: "BROWSER_EVALUATION_FAILED",
                            message: "The awaited browser page could not be read"))
                        return
                    }
                    continuation.resume(returning: encoded)
                }
            }
            try Task.checkCancellation()
            return try await Self.decodeOriginalSnapshot(encoded)
        }

        nonisolated private static func decodeOriginalSnapshot(_ encoded: String) async throws -> LegadoOriginalBrowserCompletion {
            try SourcePerfTrace.span("legado.original.browser.snapshot",
                "main=\(Thread.isMainThread) bytes=\(encoded.utf8.count)") {
                struct Snapshot: Decodable { let finalURL: String; let body: String }
                let maximumBodyBytes = 4 * 1024 * 1024
                guard encoded.utf8.count <= maximumBodyBytes * 6 + 65_536 * 6 + 128 else {
                    throw LegadoRuntimeError(code: "STATE_LIMIT", message: "The awaited browser page exceeds its budget")
                }
                let snapshot: Snapshot
                do { snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(encoded.utf8)) }
                catch { throw LegadoRuntimeError(code: "BROWSER_EVALUATION_FAILED", message: "The awaited browser page is invalid") }
                guard snapshot.finalURL.utf8.count < 65_536, !snapshot.body.isEmpty,
                      snapshot.body.utf8.count <= maximumBodyBytes else {
                    throw LegadoRuntimeError(code: snapshot.body.isEmpty ? "BROWSER_EMPTY_RESULT" : "STATE_LIMIT",
                        message: "The awaited browser page is empty or exceeds its budget")
                }
                return .response(finalURL: snapshot.finalURL, body: snapshot.body)
            }
        }

        private func handleImportURL(_ url: URL, webView: WKWebView) {
            // A module link (Phase 6e-2) opens the module import, over this page.
            if case .module(let address) = BookSourceImportDeepLink.target(from: url) {
                RuleModuleLinkPresenter.present(address)
                return
            }
            guard let sourceURL = Self.onlineImportSourceURL(from: url) else {
                presentImportResult(localized("無效的來源配置導入連結"), in: webView)
                return
            }

            URLSession.shared.dataTask(with: sourceURL) { data, _, error in
                DispatchQueue.main.async {
                    if let error {
                        self.presentImportResult(error.localizedDescription, in: webView)
                        return
                    }
                    guard let data else {
                        self.presentImportResult(localized("無法讀取來源配置資料"), in: webView)
                        return
                    }
                    do {
                        let ext = sourceURL.pathExtension.isEmpty ? "json" : sourceURL.pathExtension
                        // Parse only; the confirmation list decides what gets written.
                        let sources = try BookSourceStore.shared.parseForImport(
                            data: data,
                            fileExtension: ext
                        )
                        self.presentImportReview(sources, in: webView)
                    } catch {
                        self.presentImportResult(error.localizedDescription, in: webView)
                    }
                }
            }.resume()
        }

        private func presentImportResult(_ message: String, in webView: WKWebView) {
            guard let top = Self.topPresenter(in: webView) else { return }
            let alert = UIAlertController(title: localized("來源配置導入"), message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: localized("完成"), style: .default))
            top.present(alert, animated: true)
        }

        /// Shows the import confirmation list over the in-page browser. This importer lives in
        /// a `WKWebView` coordinator with no SwiftUI sheet host, so the list is hosted in a
        /// UIKit controller presented from the same presenter the result alert uses.
        private func presentImportReview(_ sources: [BookSource], in webView: WKWebView) {
            guard let top = Self.topPresenter(in: webView) else { return }
            // The dismiss callbacks need the controller that does not exist yet when its own
            // `rootView` is built. The box holds it weakly, so nothing retains a cycle.
            final class PresentedControllerBox {
                weak var controller: UIViewController?
            }
            let box = PresentedControllerBox()
            let host = UIHostingController(
                rootView: BookSourceImportReviewHost(
                    sources: sources,
                    onFinish: { [weak self] count in
                        box.controller?.dismiss(animated: true) {
                            self?.presentImportResult(
                                String(format: localized("成功匯入 %d 個來源配置"), count),
                                in: webView
                            )
                        }
                    },
                    onCancel: { box.controller?.dismiss(animated: true) }
                )
            )
            box.controller = host
            top.present(host, animated: true)
        }

        private static func topPresenter(in webView: WKWebView) -> UIViewController? {
            guard let root = webView.window?.rootViewController else { return nil }
            var top = root
            while let presented = top.presentedViewController {
                top = presented
            }
            return top
        }

        static func onlineImportSourceURL(from url: URL) -> URL? {
            // Single source of truth: shared with the system-level deep-link
            // handler in `yuedu_appApp`. One path for this concern.
            BookSourceImportDeepLink.sourceURL(from: url)
        }

        static func cookiesForInitialLoad(url: URL) -> [HTTPCookie] {
            HTTPCookieStorage.shared.cookies(for: url) ?? []
        }
    }
}

// MARK: - Keyboard-on-programmatic-focus patch
//
// WKWebView suppresses the on-screen keyboard when a web page focuses an `<input>` via JavaScript
// instead of a direct tap. SMS login pages (番茄 included) render the 验证码 field as styled boxes
// whose tap handler calls `input.focus()` — so the phone-number field (a real `<input>` you tap)
// raises the keyboard, but the 验证码 boxes never do. There is no public API for this, so we
// swizzle the private `WKContentView` focus callback ONCE to always report user interaction.
// Runtime-only: no private symbols are linked (looked up via NSClassFromString / sel_getUid).
extension WKWebView {
    /// Lazily-evaluated, thread-safe one-shot patch. Touch `WKWebView.patchKeyboardFocusOnce`
    /// from any web view's `makeUIView` to install it process-wide.
    static let patchKeyboardFocusOnce: Void = {
        guard let contentViewClass = NSClassFromString("WKContentView") else { return }

        // (self, _cmd, focusedElementInfo, userIsInteracting, blurPreviousNode,
        //  activityStateChanges, userObject)
        typealias FocusIMP = @convention(c) (Any, Selector, UnsafeRawPointer, Bool, Bool, UInt, Any?) -> Void

        // iOS 13+ uses `activityStateChanges`; the older `changingActivityState` name is kept as a
        // defensive fallback. Patch whichever exists.
        let selectorNames = [
            "_elementDidFocus:userIsInteracting:blurPreviousNode:activityStateChanges:userObject:",
            "_elementDidFocus:userIsInteracting:blurPreviousNode:changingActivityState:userObject:",
        ]

        for name in selectorNames {
            let selector = sel_getUid(name)
            guard let method = class_getInstanceMethod(contentViewClass, selector) else { continue }
            let originalIMP = method_getImplementation(method)
            let original = unsafeBitCast(originalIMP, to: FocusIMP.self)
            let override: @convention(block) (Any, UnsafeRawPointer, Bool, Bool, UInt, Any?) -> Void = {
                received, element, _, blurPreviousNode, activityStateChanges, userObject in
                // Force `userIsInteracting` = true so the keyboard appears for JS-driven focus.
                original(received, selector, element, true, blurPreviousNode, activityStateChanges, userObject)
            }
            method_setImplementation(method, imp_implementationWithBlock(override))
            return
        }
    }()
}

// MARK: - Preview

#Preview {
    JsBridgeBrowserView(
        urlString: "https://example.com",
        title: "密鑰獲取",
        onDismiss: { _ in }
    )
}
