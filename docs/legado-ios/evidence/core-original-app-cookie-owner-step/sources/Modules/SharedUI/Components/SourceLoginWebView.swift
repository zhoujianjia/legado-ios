import SwiftUI
import WebKit
import Combine

/// Interactive WebView login for any source that authenticates with a cookie — book sources and
/// voice sources both, via `SourceWebLogin`.
///
/// Cookies are captured **when the user taps "Done"** — NOT on `didFinish` — so that Cloudflare
/// `cf_clearance` and other async-set cookies are captured after all JS challenges have resolved.
struct SourceLoginWebView: View {
    let login: SourceWebLogin
    let onDismiss: () -> Void

    private let gs = GlobalSettings.shared
/// Bridge object shared with the UIViewRepresentable; wires the "Done" button to the
/// cookie sync routine running inside the Coordinator.
    @StateObject private var bridge = LoginWebBridge()
    @State private var isSyncing = false
    @State private var cookieSyncFailed = false
    /// Some sites answer a phone user-agent with an app-download page and no way to sign in at
    /// all — bot.n.cn (纳米AI TTS's `loginUrl`) is one, so its 网页登录 mode was unreachable from
    /// here however the rest of the plumbing behaved. The desktop identity is a user's escape
    /// hatch from that, not a default: a phone UA is still the right first try.
    @State private var usesDesktopSite = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SourceLoginWebViewRepresentable(
                    login: login,
                    usesDesktopSite: usesDesktopSite,
                    bridge: bridge
                )
                    .overlay(alignment: .top) {
                        // md3's `LinearProgressIndicator` — visible while the page loads.
                        if bridge.progress > 0 && bridge.progress < 1 {
                            ProgressView(value: bridge.progress)
                                .progressViewStyle(.linear)
                                .tint(DSColor.accent)
                                .transition(.opacity)
                        }
                    }
            }
            .navigationTitle(loginTitle)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(localized("取消"))
                    .disabled(isSyncing)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Toggle(isOn: $usesDesktopSite) {
                        Image(systemName: usesDesktopSite ? "desktopcomputer" : "iphone")
                    }
                    .toggleStyle(.button)
                    .accessibilityLabel(localized("電腦版網頁"))
                    .accessibilityValue(usesDesktopSite ? localized("開啟") : localized("狀態：關閉"))
                    .accessibilityHint(localized("網站只給手機版下載頁時改用電腦版"))
                    .disabled(isSyncing)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        bridge.reload?()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel(localized("網頁：重新整理"))
                    .disabled(isSyncing)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isSyncing {
                        ProgressView().scaleEffect(0.85)
                    } else {
                        Button {
                            isSyncing = true
                            bridge.syncCookiesAndDismiss? { result in
                                isSyncing = false
                                switch result {
                                case .success: onDismiss()
                                case .failure: cookieSyncFailed = true
                                }
                            }
                        } label: {
                            Image(systemName: "checkmark")
                        }
                        .accessibilityLabel(localized("完成"))
                    }
                }
            }
        }
        .alert(localized("無法儲存"), isPresented: $cookieSyncFailed) {
            Button(localized("確定"), role: .cancel) {}
        }
    }

    /// Same 「登入：源名稱」 title format as the form login sheet.
    private var loginTitle: String {
        String(format: localized("登入：%@"), login.name)
    }
}

// MARK: - LoginWebBridge

/// Reference-type bridge that lets the SwiftUI "Done" button trigger the WKWebView's
/// cookie extraction inside the UIKit Coordinator, and publishes the page-load
/// progress for the top linear indicator (md3's LinearProgressIndicator).
final class LoginWebBridge: ObservableObject {
    /// Set by the Coordinator after the WKWebView is created.
    /// Calling it triggers a full cookie sync and then invokes `completion`.
    var syncCookiesAndDismiss: ((@escaping (Result<Void, Error>) -> Void) -> Void)?
    /// Reloads the page. A sign-in flow that stalls, a captcha that expired, or a site that
    /// half-loaded has no other way back without abandoning the sheet and starting over.
    var reload: (() -> Void)?
    /// 0…1 while the page loads; 1 (hidden) once loaded.
    @Published var progress: Double = 0
}

// MARK: - UIViewRepresentable

struct SourceLoginWebViewRepresentable: UIViewRepresentable {
    let login: SourceWebLogin
    let usesDesktopSite: Bool
    let bridge: LoginWebBridge

    static func userAgent(desktop: Bool) -> String? {
        SourceWebIdentity.userAgent(desktop: desktop)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        prefs.preferredContentMode = SourceWebIdentity.contentMode(desktop: usesDesktopSite)
        config.defaultWebpagePreferences = prefs
        // Same reason as JsBridgeBrowserView: a widget that opens its own window
        // (captcha / OAuth) is blocked before the UI delegate is consulted.
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        context.coordinator.clipboardBridge.install(in: config.userContentController)

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = Self.userAgent(desktop: usesDesktopSite)
        context.coordinator.usesDesktopSite = usesDesktopSite
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator.uiDelegate  // weak on WKWebView

        // Give the Coordinator a weak reference so the bridge closure can reach it
        context.coordinator.webView = wv
        context.coordinator.observeProgress(publishingTo: bridge)

        // Wire the "Done" button to the Coordinator's authoritative sync
        let coordinator = context.coordinator
        bridge.syncCookiesAndDismiss = { completion in
            guard let wv = coordinator.webView else { completion(.failure(CookieOwnerError(code: "STATE_OWNER_CLOSED", message: "Login browser was closed"))); return }
            coordinator.syncCookies(from: wv, completion: completion)
        }
        bridge.reload = { [weak coordinator] in coordinator?.webView?.reload() }

        wv.load(URLRequest(url: login.url))
        return wv
    }

    /// Switching identity means reloading — the page the site already served was chosen for the
    /// previous one. Guarded on the coordinator's own record rather than on `customUserAgent`,
    /// which is nil in desktop mode and so cannot distinguish the two. Without the guard an
    /// unrelated SwiftUI update would reload the page out from under a half-finished sign-in.
    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard context.coordinator.usesDesktopSite != usesDesktopSite else { return }
        context.coordinator.usesDesktopSite = usesDesktopSite
        SourceWebIdentity.apply(desktop: usesDesktopSite, to: uiView)
        uiView.reload()
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.clipboardBridge.remove(from: uiView.configuration.userContentController)
    }

    func makeCoordinator() -> Coordinator { Coordinator(login: login) }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let login: SourceWebLogin
        /// Mirrors the SwiftUI toggle so each navigation is decided in the right content mode,
        /// and so `updateUIView` can tell a real switch from any other view update.
        var usesDesktopSite = false
        /// Weak reference set in makeUIView; used by the bridge closure.
        weak var webView: WKWebView?
        /// Strongly held: `WKWebView.uiDelegate` is weak.
        let uiDelegate = SourceWebUIDelegate()
        let clipboardBridge = SourceWebClipboardBridge()
        private var progressObservation: NSKeyValueObservation?
        private weak var progressBridge: LoginWebBridge?

        init(login: SourceWebLogin) { self.login = login }

        /// KVO on `estimatedProgress` → publishes into the SwiftUI bridge for the
        /// top linear loading indicator (md3's LinearProgressIndicator).
        func observeProgress(publishingTo bridge: LoginWebBridge) {
            progressBridge = bridge
            guard let webView else { return }
            progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak bridge] wv, _ in
                Task { @MainActor in
                    bridge?.progress = wv.estimatedProgress
                }
            }
        }

        /// Content mode is per navigation: a redirect, or a link the sign-in flow follows, must
        /// stay in the mode the user chose instead of reverting to the configuration default.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            preferences: WKWebpagePreferences,
            decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
        ) {
            preferences.preferredContentMode =
                SourceWebIdentity.contentMode(desktop: usesDesktopSite)
            preferences.allowsContentJavaScript = true
            decisionHandler(.allow, preferences)
        }

        /// Intermediate sync on each page load — catches non-Cloudflare cookies early.
        /// The definitive sync always happens when the user taps "Done".
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in progressBridge?.progress = 1 }
            syncCookies(from: webView, completion: nil)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in progressBridge?.progress = 0 }
        }

        /// Pull all WKWebView cookies (including async-set Cloudflare `cf_clearance`)
        /// into CookieStore, HTTPCookieStorage, and LoginManager. Calls `completion`
        /// after the async cookie fetch completes.
        func syncCookies(from webView: WKWebView, completion: ((Result<Void, Error>) -> Void)?) {
            let userAgent = webView.customUserAgent
            let store = webView.configuration.websiteDataStore.httpCookieStore
            let scope = webView.url
            Task { @MainActor [login] in
                do {
                    let cookies = try await CookieStore.shared.captureWebKit(store, confirming: scope)
                        // Cookie and LoginManager are still separate owners. Do
                        // not present this legacy sequence as an atomic JVM CAS.
                        await SourceScriptThread.run {
                            let cookieString = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                            guard !cookieString.isEmpty else { return }
                            var headers = LoginManager.shared.getLoginHeaders(sourceUrl: login.storageKey)
                            headers["Cookie"] = cookieString
                            if let userAgent, !userAgent.isEmpty { headers["User-Agent"] = userAgent }
                            LoginManager.shared.storeLoginHeaders(sourceUrl: login.storageKey, headers: headers)
                        }
                        completion?(Result<Void, Error>(catching: {}))
                    } catch {
                        AppLogger.error("Login cookies were not persisted", error: error)
                        completion?(.failure(error))
                }
            }
        }
    }
}
