import Foundation
import LegadoRuntime
import WebKit

/// One admitted original Backstage request, not the legacy JSC runner contract.
/// The parent keeps its JVM session/owner; page children use that same session
/// without reacquiring the service gate held by the original parser.
struct LegadoOriginalHeadlessRequest: Sendable {
    let html: String?
    let url: String?
    let javaScript: String?
    let headers: [String: String]
    let userAgent: String?
    let additionalHeaders: [String: String]
    let cacheFirst: Bool
    let navigationCapture: Bool
    let delayMilliseconds: Int64
    let initialDelayMilliseconds: Int
    let resultJSON: String?
    let injectionString: String?
    let sourceName: String?
    let registeredSource: Bool
    let page: LegadoOriginalWebPageLease
    let deadline: Date
    let authorize: @Sendable () async throws -> Void
    let validateCommit: @Sendable () throws -> Void
    let recordEffect: @Sendable (String) -> Bool
    let evaluate: @Sendable (String) async throws -> LegadoOriginalHeadlessEvaluation
    let navigation: @Sendable (String) async throws -> Bool
    let publishCookies: @Sendable (String, String?) async throws -> Void
}

struct LegadoOriginalHeadlessEvaluation: Decodable, Sendable {
    let retry: Bool
    let delayMs: Int?
    let body: String?
}

struct LegadoOriginalHeadlessResult: Sendable {
    let url: String
    let body: String
    let redirected: Bool
    let originURL: String?
}

/// Offscreen WKWebView runner backing Legado's `java.webView(html, url, js)`.
///
/// Loads `url` (or raw `html`), waits for the navigation to finish, evaluates
/// `js`, and resolves with the string result. Cookies acquired during the load
/// are copied into `HTTPCookieStorage` so subsequent `java.ajax` /
/// `cookie.getCookie` calls reuse the freshly-issued session (e.g. CSRF tokens).
///
/// The WebView lives on the main actor. The bridge calls `run(...)` from a
/// `Task { @MainActor in … }` while blocking the JS serial queue on a semaphore,
/// mirroring the existing `startBrowserAwait` pattern.
@MainActor
final class LegadoHeadlessWebView: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply {

    private var original: LegadoOriginalHeadlessRequest?
    private var originalContinuation: CheckedContinuation<LegadoOriginalHeadlessResult, Error>?
    private var originalInitialWork: Task<Void, Never>?
    private var originalEvaluationWork: Task<Void, Never>?
    private var originalTimeoutWork: Task<Void, Never>?
    private var originalFinishing: Task<Void, Never>?
    private var originalChildren: [UUID: Task<Void, Never>] = [:]
    private var originalGeneration = UUID()
    private var originalStopped = false
    private var originalRedirected = false
    private var originalInitialNavigationPending = true
    private var originalEvaluationURL: String?
    private var originalUIDelegate: SourceWebUIDelegate?
    private var originalRuleListIdentifier: String?

    static func runOriginal(_ request: LegadoOriginalHeadlessRequest) async throws -> LegadoOriginalHeadlessResult {
        let runner = LegadoHeadlessWebView(js: "", captureMode: .evaluatedJavaScript)
        runner.original = request
        retained.append(runner)
        let token = runner.cookieCancellation
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                runner.originalContinuation = continuation
                runner.beginOriginal()
            }
        } onCancel: {
            token.cancel()
            Task { @MainActor in runner.finishOriginal(.failure(CancellationError())) }
        }
    }

    private enum CaptureMode {
        case evaluatedJavaScript
        case resource(regex: String)
        case overrideURL(regex: String)
    }

    private var webView: WKWebView?
    private let js: String
    private let captureMode: CaptureMode
    private var initialURL: String?
    private var continuation: CheckedContinuation<String, Error>?
    private var finished = false
    private var cookieTask: Task<Void, Never>?
    private let cookieCancellation = OriginalRuntimeCommitCancellation()
    private var cookieDeadline = Date.distantFuture

    /// Strong references that keep in-flight runners alive until they resolve.
    private static var retained: [LegadoHeadlessWebView] = []

    private init(js: String, captureMode: CaptureMode) {
        self.js = js
        self.captureMode = captureMode
        super.init()
    }

    /// Run a headless load + JS evaluation. Owner errors, cancellation and timeout throw.
    static func run(
        html: String?,
        url: String?,
        js: String,
        userAgent: String?,
        timeout: TimeInterval,
        sourceRegex: String? = nil,
        overrideURLRegex: String? = nil
    ) async throws -> String {
        let mode: CaptureMode
        if let sourceRegex, !sourceRegex.isEmpty {
            mode = .resource(regex: sourceRegex)
        } else if let overrideURLRegex, !overrideURLRegex.isEmpty {
            mode = .overrideURL(regex: overrideURLRegex)
        } else {
            mode = .evaluatedJavaScript
        }
        let runner = LegadoHeadlessWebView(js: js, captureMode: mode)
        retained.append(runner)
        let cancellation = runner.cookieCancellation
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                runner.continuation = cont
                runner.begin(html: html, url: url, userAgent: userAgent, timeout: timeout)
            }
        } onCancel: {
            cancellation.cancel()
            Task { @MainActor in runner.finishFailure(CancellationError()) }
        }
    }

    private func begin(html: String?, url: String?, userAgent: String?, timeout: TimeInterval) {
        let config = WKWebViewConfiguration()
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 375, height: 667), configuration: config)
        if let ua = userAgent, !ua.isEmpty { wv.customUserAgent = ua }
        wv.navigationDelegate = self
        webView = wv
        initialURL = url
        cookieDeadline = Date().addingTimeInterval(timeout)

        // Hard timeout: never leave the JS queue blocked indefinitely.
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, !self.finished else { return }
            self.cookieCancellation.cancel()
            self.finishFailure(URLError(.timedOut))
        }

        if let urlStr = url, let u = URL(string: urlStr) {
            wv.load(URLRequest(url: u))
        } else if let html {
            wv.loadHTMLString(html, baseURL: url.flatMap { URL(string: $0) })
        } else {
            finish("")
        }
    }

    // MARK: - Original Backstage contract

    private func beginOriginal() {
        guard let original else { return }
        let generation = originalGeneration
        initialURL = original.url
        cookieDeadline = original.deadline
        originalInitialWork = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try self.checkOriginal(generation)
                try await original.authorize()
                try self.checkOriginal(generation)
                let configuration = WKWebViewConfiguration()
                // Public WebKit image blocking matches the original network
                // image setting. A run owns only this one temporary identifier.
                let ruleIdentifier = "YueduOriginalHeadlessImage-" + UUID().uuidString
                let rules: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
                    WKContentRuleListStore.default().compileContentRuleList(forIdentifier: ruleIdentifier,
                        encodedContentRuleList: "[{\"trigger\":{\"url-filter\":\".*\",\"resource-type\":[\"image\"]},\"action\":{\"type\":\"block\"}}]") { list, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let list { continuation.resume(returning: list) }
                        else { continuation.resume(throwing: LegadoRuntimeError(code: "STATE_IO", message: "Original image blocking was not compiled")) }
                    }
                }
                self.originalRuleListIdentifier = ruleIdentifier
                try self.checkOriginal(generation)
                configuration.userContentController.add(rules)
                let usesHTML = original.html?.isEmpty == false
                if usesHTML, original.injectionString != nil {
                    let bootstrap = try await Self.originalBootstrap(original)
                    configuration.userContentController.addUserScript(.init(source: bootstrap,
                        injectionTime: .atDocumentStart, forMainFrameOnly: true))
                    configuration.userContentController.addScriptMessageHandler(self,
                        contentWorld: .page, name: "yueduOriginalWebJS")
                }
                let view = SourcePerfTrace.span("legado.original.webview.create", "main=\(Thread.isMainThread) views=1") {
                    WKWebView(frame: .zero, configuration: configuration)
                }
                let delegate = SourceWebUIDelegate()
                delegate.sourceBridgePromptHandler = { [weak self] payload, completion in
                    self?.originalBridge(payload, completion: completion)
                }
                self.originalUIDelegate = delegate
                view.uiDelegate = delegate
                view.navigationDelegate = self
                self.webView = view
                if let userAgent = original.userAgent,
                   !userAgent.isEmpty { view.customUserAgent = userAgent }
                // Use the same native Cookie owner/HTTPCookieStorage projection
                // as the existing source page. Issued IPC is always drained.
                if let url = original.url.flatMap(URL.init(string:)) {
                    let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
                    guard cookies.count <= 16_384 else {
                        throw LegadoRuntimeError(code: "STATE_LIMIT", message: "Too many initial browser Cookies")
                    }
                    let group = DispatchGroup()
                    var issueError: Error?
                    var issued = 0
                    for cookie in cookies {
                        do {
                            try self.checkOriginal(generation)
                            try original.validateCommit()
                            if issued == 0 {
                                guard original.recordEffect("sourceWebViewCookieSeedIssued") else { throw CancellationError() }
                            }
                            group.enter(); issued += 1
                            view.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { group.leave() }
                        } catch { issueError = error; break }
                    }
                    await withCheckedContinuation { continuation in
                        group.notify(queue: .main) { continuation.resume() }
                    }
                    if issued > 0 { _ = original.recordEffect("sourceWebViewCookieSeedCompleted") }
                    if let issueError { throw issueError }
                }
                try self.checkOriginal(generation)
                try await original.authorize()
                try self.checkOriginal(generation)
                if usesHTML {
                    guard original.recordEffect("sourceWebViewLoadIssued") else { throw CancellationError() }
                    view.loadHTMLString(original.html!, baseURL: original.url.flatMap(URL.init(string:)))
                } else {
                    guard let raw = original.url, let url = URL(string: raw),
                          ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                        throw LegadoRuntimeError(code: "INVALID_STATE_REQUEST", message: "URL load requires its actual HTTP URL")
                    }
                    var request = URLRequest(url: url,
                        cachePolicy: original.cacheFirst ? .returnCacheDataElseLoad : .useProtocolCachePolicy)
                    for (key, value) in original.additionalHeaders {
                        request.setValue(value, forHTTPHeaderField: key)
                    }
                    guard original.recordEffect("sourceWebViewLoadIssued") else { throw CancellationError() }
                    view.load(request)
                }
            } catch { self.finishOriginal(.failure(error)) }
        }
        let remaining = max(0, original.deadline.timeIntervalSinceNow)
        originalTimeoutWork = Task { @MainActor [weak self] in
            // The original Backstage timeout, never a settle/retry workaround.
            do { try await Task.sleep(nanoseconds: UInt64(min(remaining, 300) * 1_000_000_000)) }
            catch { return }
            self?.finishOriginal(.failure(LegadoRuntimeError(code: "TIMEOUT", message: "Original WebView deadline elapsed")))
        }
    }

    private func checkOriginal(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard !originalStopped, generation == originalGeneration, let original else { throw CancellationError() }
        try cookieCancellation.check(deadline: original.deadline)
        try original.validateCommit()
    }

    private func originalDidFinish(_ view: WKWebView) {
        guard let original, view === webView, !originalStopped else { return }
        let previous = originalEvaluationWork
        previous?.cancel()
        let generation = originalGeneration
        if originalEvaluationURL == nil { originalEvaluationURL = view.url?.absoluteString ?? original.url ?? "" }
        originalEvaluationWork = Task { @MainActor [weak self, weak view] in
            if let previous { await previous.value }
            guard let self, let view else { return }
            do {
                try self.checkOriginal(generation)
                guard original.recordEffect("sourceWebViewCookieCaptureMayCommit") else { throw CancellationError() }
                let scope = view.url ?? original.url.flatMap(URL.init(string:))
                let token = self.cookieCancellation
                let confirming = ["http", "https"].contains(scope?.scheme?.lowercased() ?? "") ? scope : nil
                let cookies = try await CookieStore.shared.captureWebKit(view.configuration.websiteDataStore.httpCookieStore,
                    confirming: confirming, validate: {
                        try token.check(deadline: original.deadline)
                        try original.validateCommit()
                    })
                _ = original.recordEffect("sourceWebViewCookieCaptureCommitted")
                try self.checkOriginal(generation)
                if let scope {
                    let text = try await Self.originalCookieText(cookies, url: scope)
                    try await original.publishCookies(scope.absoluteString, text)
                    try self.checkOriginal(generation)
                }
                if let script = try await Self.originalResultScript(original) {
                    _ = try await self.evaluateOriginal(script, in: view)
                    try self.checkOriginal(generation)
                }
                // Exact external-page evaluation delay from Backstage onPageFinished.
                if original.navigationCapture, original.javaScript?.isEmpty != false { return }
                try await Task.sleep(nanoseconds: UInt64(original.initialDelayMilliseconds) * 1_000_000)
                if original.navigationCapture {
                    // Original SnifferWebClient loads authored JS for navigation
                    // side effects; its return value is not a captured result.
                    _ = try await self.evaluateOriginal(try await Self.originalEvaluationScript(original), in: view)
                    return
                }
                while true {
                    try self.checkOriginal(generation)
                    try await original.authorize()
                    try self.checkOriginal(generation)
                    let script = try await Self.originalEvaluationScript(original)
                    let raw = try await self.evaluateOriginal(script, in: view)
                    try self.checkOriginal(generation)
                    let decision = try await original.evaluate(raw)
                    try self.checkOriginal(generation)
                    if !decision.retry {
                        guard let body = decision.body else {
                            throw LegadoRuntimeError(code: "INVALID_RESULT", message: "Original evaluation omitted its accepted body")
                        }
                        self.finishOriginal(.success(.init(url: self.originalEvaluationURL ?? original.url ?? "",
                            body: body, redirected: self.originalRedirected, originURL: original.url)))
                        return
                    }
                    guard let interval = decision.delayMs, (1...1000).contains(interval) else {
                        throw LegadoRuntimeError(code: "INVALID_RESULT", message: "Original retry policy omitted its bounded interval")
                    }
                    // Locked raw-null/empty retry backoff, not UI settling.
                    try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000)
                }
            } catch {
                // A replacement navigation owns the next evaluation. Its cancelled
                // predecessor must not terminate that still-current page.
                if !Task.isCancelled { self.finishOriginal(.failure(error)) }
            }
        }
    }

    private func evaluateOriginal(_ script: String, in view: WKWebView) async throws -> String {
        guard original?.recordEffect("sourceWebViewEvaluateIssued") == true else { throw CancellationError() }
        let value: Any? = try await withCheckedThrowingContinuation { continuation in
            // Direct native execution preserves global completion and var state.
            // Page CSP/eval/JSON overrides do not select our evaluator.
            view.evaluateJavaScript(script) { value, error in
                if let error {
                    if let wk = error as? WKError, wk.code == .javaScriptExceptionOccurred {
                        continuation.resume(returning: nil) // Android's raw null retry.
                    } else { continuation.resume(throwing: error) }
                } else { continuation.resume(returning: value) }
            }
        }
        try await Self.validateOriginalCompletion(.init(value: value))
        return try await withCheckedThrowingContinuation { continuation in
            // Native fixed code in an isolated world preserves WebKit's own
            // number/null/array JSON encoding, independent of page overrides.
            view.callAsyncJavaScript("return JSON.stringify(value);",
                arguments: ["value": value ?? NSNull()], in: nil, in: .defaultClient) { result in
                switch result {
                case .success(let raw):
                    guard let raw = raw as? String else {
                        continuation.resume(throwing: LegadoRuntimeError(code: "INVALID_RESULT", message: "WebKit did not encode its native completion")); return
                    }
                    continuation.resume(returning: raw)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }

    /// WebKit supplies a completed immutable Foundation value. It is never
    /// mutated or exposed elsewhere while the bounded projection runs off main.
    private struct OriginalCompletion: @unchecked Sendable { let value: Any? }
    nonisolated private static func validateOriginalCompletion(_ completion: OriginalCompletion) async throws {
        try SourcePerfTrace.span("legado.original.webview.completion", "main=\(Thread.isMainThread) values=1") {
            var pending: [(Any?, Int)] = [(completion.value, 0)]
            var visited = 0
            while let (candidate, depth) = pending.popLast() {
                try Task.checkCancellation()
                visited += 1
                guard depth <= 64, visited <= 65_536 else {
                    throw LegadoRuntimeError(code: "STATE_LIMIT", message: "Original completion exceeds its native projection budget")
                }
                guard let candidate, !(candidate is NSNull) else { continue }
                if candidate is String || candidate is NSNumber { continue }
                if let array = candidate as? [Any] {
                    guard pending.count + array.count <= 65_536 else {
                        throw LegadoRuntimeError(code: "STATE_LIMIT", message: "Original completion array exceeds its projection budget")
                    }
                    pending.append(contentsOf: array.map { ($0, depth + 1) })
                    continue
                }
                // This is a pending compatibility gap, not a claim that no
                // future WK execution route can preserve original object order.
                throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY", message: "Ordered object completion requires an unimplemented original WebKit result route")
            }
        }
    }

    private func originalNavigation(_ action: WKNavigationAction,
                                    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let original, !originalStopped else { decisionHandler(.cancel); return }
        guard action.targetFrame?.isMainFrame != false, let url = action.request.url?.absoluteString else {
            decisionHandler(.allow); return
        }
        if originalInitialNavigationPending {
            originalInitialNavigationPending = false
            do { try checkOriginal(originalGeneration); decisionHandler(.allow) }
            catch { decisionHandler(.cancel); finishOriginal(.failure(error)) }
            return
        }
        let id = UUID(), generation = originalGeneration
        originalChildren[id] = Task { @MainActor [weak self] in
            guard let self else { decisionHandler(.cancel); return }
            defer { self.originalChildren.removeValue(forKey: id) }
            do {
                try self.checkOriginal(generation)
                if try await original.navigation(url) {
                    try self.checkOriginal(generation)
                    decisionHandler(.cancel)
                    self.finishOriginal(.success(.init(url: original.url ?? "", body: url,
                        redirected: false, originURL: nil)))
                } else {
                    try self.checkOriginal(generation)
                    guard ["http", "https", "about", "data", "blob", "javascript"].contains(URL(string: url)?.scheme?.lowercased() ?? "") else {
                        throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY", message: "Original WebView navigation has no admitted native scheme")
                    }
                    decisionHandler(.allow)
                }
            } catch { decisionHandler(.cancel); self.finishOriginal(.failure(error)) }
        }
    }

    private func originalBridge(_ payload: String, completion: @escaping (String?) -> Void) {
        guard let original, !originalStopped else { completion(nil); return }
        guard originalChildren.count < 32 else { completion("{\"error\":\"STATE_LIMIT\"}"); return }
        let id = UUID(), generation = originalGeneration
        originalChildren[id] = Task { @MainActor [weak self] in
            guard let self else { completion(nil); return }
            defer { self.originalChildren.removeValue(forKey: id) }
            do {
                let call = try await Self.decodeOriginalCall(payload)
                // Page script never selects native policy, even via java.request.
                guard !call.method.hasPrefix("policy."), !(call.function?.hasPrefix("policy.") ?? false) else {
                    throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY", message: "Native browser policy is not a page API")
                }
                try self.checkOriginal(generation)
                let reply = try await original.page.request(call)
                try self.checkOriginal(generation)
                completion(try await Self.encodeOriginalReply(reply))
            } catch {
                if self.originalStopped || Task.isCancelled { completion(nil) }
                else { completion(await Self.originalError(error)) }
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.name == "yueduOriginalWebJS", message.frameInfo.isMainFrame,
              let payload = message.body as? String else {
            replyHandler(nil, "INVALID_STATE_REQUEST"); return
        }
        originalBridge(payload) { replyHandler($0, nil) }
    }

    private func finishOriginal(_ result: Result<LegadoOriginalHeadlessResult, Error>) {
        guard originalFinishing == nil, original != nil else { return }
        originalStopped = true
        originalGeneration = UUID()
        cookieCancellation.cancel()
        webView?.stopLoading()
        originalTimeoutWork?.cancel()
        originalInitialWork?.cancel()
        originalEvaluationWork?.cancel()
        let initial = originalInitialWork, evaluation = originalEvaluationWork
        let children = Array(originalChildren.values)
        for child in children { child.cancel() }
        originalFinishing = Task { @MainActor in
            // Separate completion task never awaits its own evaluation/bridge task.
            if let initial { await initial.value }
            if let evaluation { await evaluation.value }
            for child in children { await child.value }
            self.webView?.configuration.userContentController.removeScriptMessageHandler(
                forName: "yueduOriginalWebJS", contentWorld: .page)
            self.webView?.navigationDelegate = nil
            self.webView?.uiDelegate = nil
            self.webView = nil; self.originalUIDelegate = nil
            var outcome = result
            if let identifier = self.originalRuleListIdentifier {
                let cleanup: Error? = await withCheckedContinuation { continuation in
                    WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier) { error in
                        continuation.resume(returning: error)
                    }
                }
                self.originalRuleListIdentifier = nil
                if cleanup != nil {
                    let primary: LegadoRuntimeError?
                    let cancelled: Bool
                    if case .failure(let error) = outcome { primary = error as? LegadoRuntimeError; cancelled = error is CancellationError }
                    else { primary = nil; cancelled = false }
                    outcome = .failure(LegadoRuntimeError(code: primary?.code ?? (cancelled ? "CANCELLED" : "STATE_IO"),
                        message: "Original WebView owned rule cleanup did not complete", completedEffects: primary?.completedEffects,
                        secondaryFailures: (primary?.secondaryFailures ?? []) + [.init(code: "STATE_IO", message: "Owned WebKit content rule cleanup failed")]))
                }
            }
            self.originalContinuation?.resume(with: outcome)
            self.originalContinuation = nil
            Self.retained.removeAll { $0 === self }
        }
    }

    nonisolated private static func originalEvaluationScript(_ request: LegadoOriginalHeadlessRequest) async throws -> String {
        try SourcePerfTrace.span("legado.original.webview.script", "main=\(Thread.isMainThread) bytes=\(request.javaScript?.utf8.count ?? 0)") {
            let js = request.javaScript?.isEmpty == false ? request.javaScript! : "document.documentElement.outerHTML"
            let script = (request.injectionString.map { $0 + "\n" } ?? "") + js
            return script
        }
    }

    nonisolated private static func originalResultScript(_ request: LegadoOriginalHeadlessRequest) async throws -> String? {
        guard request.resultJSON != nil else { return nil }
        return try SourcePerfTrace.span("legado.original.webview.result", "main=\(Thread.isMainThread) values=1") {
            let cache = String(decoding: try JSONEncoder().encode(request.page.descriptor.cacheName), as: UTF8.self)
            // Original onPageFinished assigns once, independently from each
            // later retry. An absent native interface leaves the assignment
            // ineffective just like its original ignored JS callback.
            return "try{window.result=window[\(cache)].getFromMemory('webview_result');}catch(e){}"
        }
    }

    private static func originalBootstrap(_ request: LegadoOriginalHeadlessRequest) async throws -> String {
        try SourcePerfTrace.span("legado.original.webview.bridge", "main=\(Thread.isMainThread) interfaces=3") {
            var script = JsBridgeBrowserRepresentable.originalPageBootstrap(request.page.descriptor)
            // Capture native bridge JSON intrinsics at document start. Page
            // scripts may still intentionally use their own overridden JSON.
            script = script.replacingOccurrences(of: "JSON.stringify", with: "nativeStringify")
                .replacingOccurrences(of: "JSON.parse", with: "nativeParse")
                .replacingOccurrences(of: "(function() {", with: "(function() {\nconst nativeStringify=JSON.stringify.bind(JSON),nativeParse=JSON.parse.bind(JSON);")
            let java = String(decoding: try JSONEncoder().encode(request.page.descriptor.javaName), as: UTF8.self)
            if !request.registeredSource { script += "\ndelete window[\(java)];" }
            else if let sourceName = request.sourceName {
                let name = String(decoding: try JSONEncoder().encode(sourceName), as: UTF8.self)
                script += """
                \n(function(){const nativeStringify=JSON.stringify.bind(JSON),nativeParse=JSON.parse.bind(JSON);
                window[\(name)] = new Proxy({}, {get:function(_,name){
                    if(typeof name!=='string'||name==='then')return undefined;
                    return function(){const raw=window.prompt('__yuedu_source_java_bridge__',nativeStringify({method:'source.'+name,params:Array.from(arguments,v=>v==null?null:String(v))}));
                        if(raw===null)throw new Error('BROWSER_CANCELLED');const r=nativeParse(raw);if(r.error)throw new Error(r.error);if(r.kind==='void')return undefined;return r.value==null?null:r.value;};
                }});})();
                """
            }
            return script
        }
    }

    nonisolated private static func decodeOriginalCall(_ payload: String) async throws -> LegadoOriginalWebJSCall {
        try SourcePerfTrace.span("legado.original.webview.decode", "main=\(Thread.isMainThread) bytes=\(payload.utf8.count)") {
            guard payload.utf8.count <= 6 * 4 * 1024 * 1024 + 65_536 else {
                throw LegadoRuntimeError(code: "STATE_LIMIT", message: "Original page request is oversized")
            }
            return try JSONDecoder().decode(LegadoOriginalWebJSCall.self, from: Data(payload.utf8))
        }
    }
    nonisolated private static func encodeOriginalReply(_ reply: LegadoOriginalWebJSReply) async throws -> String {
        try SourcePerfTrace.span("legado.original.webview.encode", "main=\(Thread.isMainThread) values=\(reply.values?.count ?? 0)") {
            String(decoding: try JSONEncoder().encode(reply), as: UTF8.self)
        }
    }
    nonisolated private static func originalError(_ error: Error) async -> String {
        let code = (error as? LegadoRuntimeError)?.code ?? "STATE_IO"
        do { return String(decoding: try JSONEncoder().encode(["error":code]), as: UTF8.self) }
        catch { return "{\"error\":\"STATE_IO\"}" }
    }
    nonisolated private static func originalCookieText(_ cookies: [HTTPCookie], url: URL) async throws -> String? {
        try SourcePerfTrace.span("legado.original.webview.cookies", "main=\(Thread.isMainThread) cookies=\(cookies.count)") {
            guard cookies.count <= 16_384 else { throw LegadoRuntimeError(code: "STATE_LIMIT", message: "Too many WebKit Cookies") }
            let host = url.host?.lowercased() ?? "", path = url.path.isEmpty ? "/" : url.path
            let matching = cookies.filter { cookie in
                let domain = cookie.domain.lowercased(), suffix = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
                let pathMatches = path == cookie.path || (path.hasPrefix(cookie.path)
                    && (cookie.path.hasSuffix("/") || path.dropFirst(cookie.path.count).first == "/"))
                return (host == suffix || (domain.hasPrefix(".") && host.hasSuffix("." + suffix)))
                    && pathMatches && (!cookie.isSecure || url.scheme?.lowercased() == "https")
                    && (cookie.expiresDate == nil || cookie.expiresDate! > Date())
            }
            return matching.isEmpty ? nil : HTTPCookie.requestHeaderFields(with: matching)["Cookie"]
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if original != nil { originalNavigation(navigationAction, decisionHandler: decisionHandler); return }
        if case .overrideURL(let pattern) = captureMode,
           let candidate = navigationAction.request.url?.absoluteString,
           candidate != initialURL,
           Self.fullyMatches(candidate, pattern: pattern) {
            persistCookies(from: webView) { [weak self] in self?.finish(candidate) }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if original != nil { originalDidFinish(webView); return }
        switch captureMode {
        case .evaluatedJavaScript:
            webView.evaluateJavaScript(js) { [weak self] value, _ in
                guard let self else { return }
                self.persistCookies(from: webView) {
                    self.finish(Self.stringify(value))
                }
            }
        case .resource(let pattern):
            evaluateSnifferJavaScriptIfNeeded(in: webView) { [weak self] in
                guard let self else { return }
                webView.evaluateJavaScript(Self.resourceURLScript) { value, _ in
                    let candidates = (value as? [Any])?.compactMap { $0 as? String } ?? []
                    let matched = candidates.first { Self.fullyMatches($0, pattern: pattern) } ?? ""
                    self.persistCookies(from: webView) { self.finish(matched) }
                }
            }
        case .overrideURL:
            evaluateSnifferJavaScriptIfNeeded(in: webView) { [weak self] in
                guard let self else { return }
                self.persistCookies(from: webView) { self.finish("") }
            }
        }
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        if original != nil, webView === self.webView, !originalStopped { originalRedirected = true }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if original != nil { finishOriginal(.failure(error)); return }
        finish("")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if original != nil { finishOriginal(.failure(error)); return }
        finish("")
    }

    // MARK: - Helpers

    private func evaluateSnifferJavaScriptIfNeeded(
        in webView: WKWebView,
        completion: @escaping () -> Void
    ) {
        guard !js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion()
            return
        }
        webView.evaluateJavaScript(js) { _, _ in completion() }
    }

    private func persistCookies(from webView: WKWebView, completion: @escaping () -> Void) {
        guard !finished else { return }
        cookieTask?.cancel()
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let scope = webView.url
        let cancellation = cookieCancellation
        let deadline = cookieDeadline
        cookieTask = Task { @MainActor in
            do {
                _ = try await CookieStore.shared.captureWebKit(store, confirming: scope) {
                    try cancellation.check(deadline: deadline)
                }
                guard !self.finished else { return }
                completion()
            } catch {
                guard !self.finished else { return }
                AppLogger.error("Headless browser cookies were not persisted", error: error)
                self.finishFailure(error)
            }
        }
    }

    private static func fullyMatches(_ value: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range) else { return false }
        return match.range == range
    }

    private static let resourceURLScript = """
    (() => {
      const urls = [];
      try { performance.getEntriesByType('resource').forEach(e => urls.push(String(e.name || ''))); } catch (_) {}
      try { document.querySelectorAll('[src],[href]').forEach(e => urls.push(String(e.src || e.href || ''))); } catch (_) {}
      return Array.from(new Set(urls.filter(Boolean)));
    })()
    """

    private func finish(_ value: String) {
        finishResult(.success(value))
    }

    private func finishFailure(_ error: Error) {
        finishResult(.failure(error))
    }

    private func finishResult(_ result: Result<String, Error>) {
        guard !finished else { return }
        finished = true
        cookieTask?.cancel()
        cookieTask = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        continuation?.resume(with: result)
        continuation = nil
        Self.retained.removeAll { $0 === self }
    }

    private static func stringify(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        if let arr = value as? [Any] {
            return arr.map { stringify($0) }.joined(separator: "\n")
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "\(value)"
    }
}
