// Port of Legado's BaseSource login system.
// Manages book-source authentication: login execution, cookie/header
// persistence, and login-check evaluation.

import Foundation
import Security
import JavaScriptCore

extension Notification.Name {
    /// Posted after a source's stored login information changes. Consumers use
    /// the source URL in `userInfo` to invalidate only that source's runtime.
    static let bookSourceLoginInfoDidChange = Notification.Name(
        "bookSourceLoginInfoDidChange"
    )
}

// MARK: - Login State

/// Represents the authentication state of a book source.
enum LoginState: Equatable {
    case notRequired
    case loggedIn
    case loggedOut
    case failed(String)

    static func == (lhs: LoginState, rhs: LoginState) -> Bool {
        switch (lhs, rhs) {
        case (.notRequired, .notRequired),
             (.loggedIn, .loggedIn),
             (.loggedOut, .loggedOut):
            return true
        case (.failed(let a), .failed(let b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - Login Field (Legado RowUi)

/// A single field in a login form, parsed from the source's `loginUi` JSON.
/// Mirrors Legado's `RowUi` data class. The one model behind both the book-source
/// and TTS login sheets.
struct LoginField: Identifiable, Equatable, Sendable {
    let name: String
    let type: LoginFieldType
    let action: String?
    let options: [String]
    let defaultValue: String?
    /// Grid/layout hints from the row's `style` object, `nil` when absent.
    let style: LoginFieldStyle?
    /// Legado's `viewName`: a quoted literal label, or a JS expression to evaluate.
    let viewName: String?

    var originalRowID: String? = nil
    var id: String { originalRowID ?? name }

    /// Locked Spinner.setSelectionSafely clamps an unmatched value to the first
    /// declared choice without mutating the dialog's working credential map.
    func originalSelectionDisplayValue(_ value: String) -> String? {
        guard originalRowID != nil, type == .select else { return nil }
        guard !options.isEmpty else { return "" }
        return options.first(where: { $0 == value }) ?? options[0]
    }

    enum LoginFieldType: String, Sendable {
        case text     = "text"
        case password = "password"
        case select   = "select"
        case button   = "button"
        case toggle   = "toggle"
    }

    /// The label Legado authors literally: a short `viewName` wrapped in single quotes
    /// (length 3...19, matching the Android app's check) is shown as-is.
    var literalViewName: String? {
        guard let viewName else { return nil }
        let length = viewName.utf16.count
        guard length >= 3, length <= 19,
              viewName.hasPrefix("'"), viewName.hasSuffix("'")
        else { return nil }
        return String(viewName.dropFirst().dropLast())
    }

    /// A `viewName` that is neither absent nor a quoted literal has to be evaluated as
    /// JS in the source's login context before it can be displayed.
    var hasDynamicViewName: Bool {
        viewName != nil && literalViewName == nil
    }
}

extension Array where Element == LoginField {
    /// Labels available without running JS, keyed by field name.
    var literalViewNames: [String: String] {
        Dictionary(
            compactMap { field in
                field.literalViewName.map { (field.name, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    var hasDynamicViewNames: Bool {
        contains { $0.hasDynamicViewName }
    }
}

// MARK: - Toggle chars (Legado `chars` on a `toggle` row)

/// The two strings a `toggle` row switches between, taken from its `chars`.
///
/// A `toggle` stores its current char as the field's value — nothing else. The
/// source reads it straight back: 同人小说网's `qdToggle()` fetches the value via
/// `source.getLoginInfoMap()` and calls the switch on when it equals `"✅"`
/// (its `chars` are `["🔳", "✅"]`, off first).
struct LoginToggleChars {
    let off: String
    let on: String

    /// Only a two-state `chars` is a switch; anything else has to be rendered as
    /// a list of choices instead.
    init?(options: [String]) {
        guard options.count == 2 else { return nil }
        off = options[0]
        on = options[1]
    }

    /// Whether the switch reads as on, given what is stored and what the source
    /// declared as `default`.
    ///
    /// The declared default is for display only — it must never be written back.
    /// 同人小说网 declares `default: "🔳"` for 段评开关 while its own
    /// `qdToggle("段评开关", true)` treats a *missing* value as on, so persisting
    /// the default would silently turn 段评 off for everyone who opens the menu.
    func isOn(stored: String?, default defaultValue: String?) -> Bool {
        let value = (stored?.isEmpty == false ? stored : defaultValue) ?? ""
        return value == on
    }

    func value(isOn: Bool) -> String { isOn ? on : off }
}

// MARK: - Login Error

enum LoginError: LocalizedError {
    case noLoginUrl
    case invalidLoginUrl(String)
    case networkError(Error)
    case loginFunctionMissing
    case javaScriptError(String)
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .noLoginUrl:
            return "Book source has no loginUrl configured."
        case .invalidLoginUrl(let url):
            return "Invalid login URL: \(url)"
        case .networkError(let err):
            return "Network error during login: \(err.localizedDescription)"
        case .loginFunctionMissing:
            return "loginUrl JS does not define a login() function."
        case .javaScriptError(let msg):
            return "Login JS error: \(msg)"
        case .httpError(let code):
            return "Login request returned HTTP \(code)."
        }
    }
}

// MARK: - LoginManager

protocol LoginCredentialStorage: Sendable {
    func load(account: String) -> String?
    func save(account: String, json: String) -> Bool
    func delete(account: String)
    func loadChecked(account: String, maximumBytes: Int) throws -> String?
    func saveChecked(account: String, raw: String) throws -> Bool
    func deleteChecked(account: String) throws -> Bool
    /// False means an existing item won; never overwrite it during migration.
    func insertLegacyIfMissing(account: String, raw: String) throws -> Bool
}

enum LoginCredentialOwnerFailure: Error { case checkedStorageUnavailable, valueLimit }

extension LoginCredentialStorage {
    // Existing lightweight fixtures/embedders must opt in to checked semantics.
    // A nil-returning legacy load cannot distinguish missing from locked data.
    func loadChecked(account: String, maximumBytes: Int) throws -> String? { throw LoginCredentialOwnerFailure.checkedStorageUnavailable }
    func saveChecked(account: String, raw: String) throws -> Bool { throw LoginCredentialOwnerFailure.checkedStorageUnavailable }
    func deleteChecked(account: String) throws -> Bool { throw LoginCredentialOwnerFailure.checkedStorageUnavailable }
    func insertLegacyIfMissing(account: String, raw: String) throws -> Bool { throw LoginCredentialOwnerFailure.checkedStorageUnavailable }
}

struct KeychainLoginCredentialStorage: LoginCredentialStorage {
    func load(account: String) -> String? {
        KeychainHelper.load(account: account, accessibility: kSecAttrAccessibleAfterFirstUnlock)
    }
    func save(account: String, json: String) -> Bool {
        KeychainHelper.save(account: account, data: json, accessibility: kSecAttrAccessibleAfterFirstUnlock)
    }
    func delete(account: String) { _ = KeychainHelper.delete(account: account) }
    func loadChecked(account: String, maximumBytes: Int) throws -> String? {
        try KeychainHelper.loadExistingLoginChecked(account: account, maximumBytes: maximumBytes)
    }
    func saveChecked(account: String, raw: String) throws -> Bool {
        KeychainHelper.save(account: account, data: raw, accessibility: kSecAttrAccessibleAfterFirstUnlock)
    }
    func deleteChecked(account: String) throws -> Bool { KeychainHelper.delete(account: account) }
    func insertLegacyIfMissing(account: String, raw: String) throws -> Bool {
        try KeychainHelper.insertExistingLoginIfMissing(account: account, raw: raw)
    }
}

/// Singleton that manages book-source authentication.
///
/// Mirrors Legado's `BaseSource` login helpers:
/// - `getLoginHeader` / `putLoginHeader` / `removeLoginHeader`
/// - `getLoginInfo` / `putLoginInfo`
/// - `login()` — evaluates loginUrl JS
/// - `loginCheckJs` — post-response check evaluated by the caller
///
/// Cookie and header data are persisted via UserDefaults keyed by the
/// source's `bookSourceUrl`.
final class LoginManager {

    static let shared = LoginManager()

    // MARK: - Storage Keys (mirrors Legado CacheManager keys)

    private static let loginHeaderPrefix = "loginHeader_"
    private static let loginInfoPrefix   = "userInfo_"
    private static let suiteName         = "com.yuedu.loginStore"

    /// Dedicated UserDefaults suite so login data is isolated.
    private let defaults: UserDefaults
    private let credentials: any LoginCredentialStorage

    /// In-memory cache of the raw `putLoginHeader` payload keyed by source URL.
    ///
    /// Legado's `BaseSource.putLoginHeader` stores the string *verbatim* and only
    /// `getLoginHeaderMap()` (a GSON object parse) turns it into request headers.
    /// That distinction matters: 书山聚合 stores a bare API key here and reads it
    /// back through `source.getLoginHeader()` to build `?key=` URLs — it must never
    /// be sent as an HTTP header, because guessing a header name for it overwrites
    /// the constant token the source's own `header` rule sends.
    private var headerCache: [String: String] = [:]

    /// Serial queue for thread-safe access to caches and defaults.
    private let queue = DispatchQueue(label: "com.yuedu.LoginManager", attributes: .concurrent)

    /// Monotonically increasing revision for credential-dependent JS rules.
    /// The revision is intentionally separate from the credential value so it
    /// can invalidate request-header caches without exposing the token.
    private var loginInfoRevisions: [String: UInt64] = [:]

    // MARK: - Init

    private convenience init() {
        self.init(defaults: UserDefaults(suiteName: LoginManager.suiteName) ?? .standard)
    }

    /// The production singleton and owned fixtures use the same header owner.
    init(defaults: UserDefaults, credentials: any LoginCredentialStorage = KeychainLoginCredentialStorage()) {
        self.defaults = defaults
        self.credentials = credentials
        loadAllHeaders()
    }

    // MARK: - Login Check

    /// Whether the source has a `loginUrl` configured (i.e., *could* require login).
    func requiresLogin(source: BookSource) -> Bool {
        return !source.loginUrl.isEmpty
    }

    /// Evaluate the source's `loginCheckJs` against a response body.
    ///
    /// Legado runs `loginCheckJs` after every network response; if it
    /// returns a *modified* response (e.g. with login-redirect handled)
    /// the caller should use that instead.
    ///
    /// - Parameters:
    ///   - source: The book source.
    ///   - responseBody: The raw HTTP response body.
    ///   - jsEngine: A configured `JSCoreEngine`.
    /// - Returns: Possibly-modified response body, or the original if
    ///   no loginCheckJs is configured.
    func evaluateLoginCheck(
        source: BookSource,
        responseBody: String,
        jsEngine: JSCoreEngine
    ) -> String {
        let checkJs = source.loginCheckJs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !checkJs.isEmpty else { return responseBody }

        let bindings: [String: Any] = [
            "result": responseBody,
            "baseUrl": source.bookSourceUrl,
            "source": sourceBindings(for: source)
        ]
        if let modified = jsEngine.evaluate(checkJs, bindings: bindings) {
            return modified
        }
        return responseBody
    }

    // MARK: - Login Execution

    /// Execute the source's login procedure.
    ///
    /// Legado's `login()` extracts JS from `loginUrl` (stripping the
    /// `@js:` or `<js>…</js>` wrapper), appends a call to a user-
    /// defined `login()` function, and evaluates the whole thing.
    ///
    /// For simple-URL sources the loginUrl is fetched directly via
    /// URLSession; for JS-based sources the JS engine handles everything.
    func login(
        source: BookSource,
        credentials: [String: String] = [:],
        jsEngine: JSCoreEngine
    ) async throws -> LoginState {
        let raw = source.loginUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .notRequired }

        // Store credential info so JS can access it via source.getLoginInfo()
        if !credentials.isEmpty {
            storeLoginInfo(sourceUrl: source.bookSourceUrl, info: credentials)
        }

        let loginJs = extractLoginJs(raw)

        if let loginJs = loginJs {
            // JS-based login (Legado convention)
            return try executeJsLogin(
                source: source,
                loginJs: loginJs,
                jsEngine: jsEngine
            )
        } else {
            // Simple URL login — substitute credentials and fetch
            return try await executeUrlLogin(
                source: source,
                rawUrl: raw,
                credentials: credentials
            )
        }
    }

    // MARK: - JS Login

    /// Execute a JS-based login.
    ///
    /// Mirrors Legado `BaseSource.login()`:
    /// ```kotlin
    /// val js = "$loginJs\nif(typeof login=='function'){ login.apply(this); }"
    /// evalJS(js)
    /// ```
    private func executeJsLogin(
        source: BookSource,
        loginJs: String,
        jsEngine: JSCoreEngine
    ) throws -> LoginState {
        let wrappedJs = """
        \(loginJs)
        if (typeof login === 'function') {
            login.apply(this);
        } else {
            throw('Function login not implements!!!');
        }
        """

        let bindings: [String: Any] = [
            "baseUrl": source.bookSourceUrl,
            "source": sourceBindings(for: source)
        ]

        let result = jsEngine.evaluate(wrappedJs, bindings: bindings)

        if let err = jsEngine.lastError {
            if err.contains("Function login not implements") {
                throw LoginError.loginFunctionMissing
            }
            throw LoginError.javaScriptError(err)
        }

        // If the JS set a login header we consider it successful.
        if let resultStr = result, !resultStr.isEmpty {
            // Attempt to store it as login header (Legado convention).
            if let data = resultStr.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                storeLoginHeaders(sourceUrl: source.bookSourceUrl, headers: dict)
            }
        }

        return .loggedIn
    }

    // MARK: - Simple URL Login

    /// Fetch a loginUrl directly (non-JS path).
    private func executeUrlLogin(
        source: BookSource,
        rawUrl: String,
        credentials: [String: String]
    ) async throws -> LoginState {
        var urlString = rawUrl

        // Replace `{{key}}` placeholders with credential values.
        for (key, value) in credentials {
            urlString = urlString.replacingOccurrences(
                of: "{{\(key)}}",
                with: value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            )
        }

        guard let url = URL(string: urlString) else {
            throw LoginError.invalidLoginUrl(urlString)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        // Apply source-level headers.
        if let headerData = source.header.data(using: .utf8),
           let headerDict = try? JSONSerialization.jsonObject(with: headerData) as? [String: String] {
            for (k, v) in headerDict {
                request.setValue(v, forHTTPHeaderField: k)
            }
        }

        let (_, response): (Data, URLResponse)
        do {
            (_, response) = try await CookieStore.shared.data(for: request, session: URLSession.shared, authoredCookie: request.value(forHTTPHeaderField: "Cookie"))
        } catch {
            throw LoginError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            return .failed("Non-HTTP response")
        }

        guard (200..<400).contains(http.statusCode) else {
            throw LoginError.httpError(http.statusCode)
        }

        // Capture Set-Cookie from the response.
        let cookies = extractCookies(from: http)
        if !cookies.isEmpty {
            var headers = getLoginHeaders(sourceUrl: source.bookSourceUrl)
            let cookieString = cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
            headers["Cookie"] = cookieString
            storeLoginHeaders(sourceUrl: source.bookSourceUrl, headers: headers)
        }

        return .loggedIn
    }

    // MARK: - Cookie Extraction

    /// Extract cookies from an HTTP response's `Set-Cookie` headers.
    private func extractCookies(from response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        guard let headerFields = response.allHeaderFields as? [String: String],
              let url = response.url else { return result }

        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
        for cookie in cookies {
            result[cookie.name] = cookie.value
        }
        return result
    }

    // MARK: - Login URL JS Extraction (mirrors Legado getLoginJs)

    /// Extract the JS body from a loginUrl string.
    /// Returns `nil` if the loginUrl is a plain URL (not JS).
    func extractLoginJs(_ loginUrl: String) -> String? {
        let trimmed = loginUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("@js:") {
            return String(trimmed.dropFirst(4))
        }
        if trimmed.hasPrefix("<js>") {
            if let endRange = trimmed.range(of: "</js>", options: .backwards) {
                return String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)..<endRange.lowerBound])
            }
            return String(trimmed.dropFirst(4))
        }
        if trimmed.hasPrefix("//"), trimmed.contains("\n") {
            return trimmed
        }
        // If it looks like JS code (contains function definitions / statements)
        // rather than a URL, treat it as JS. Legado does this implicitly.
        if !trimmed.hasPrefix("http://") && !trimmed.hasPrefix("https://") && !trimmed.hasPrefix("/") {
            // Heuristic: contains function keyword or multi-line
            if trimmed.contains("function ") || trimmed.contains("\n") {
                return trimmed
            }
        }
        return nil
    }

    // MARK: - Login UI Parsing

    /// Parse the source's `loginUi` JSON into an array of `LoginField`.
    ///
    /// Legado format. Example: `[{"name":"用户名(username)","type":"text"},{"name":"密码(password)","type":"password"}]`
    func parseLoginUi(_ loginUiJson: String) -> [LoginField] {
        parseLoginUiResult(loginUiJson) ?? []
    }

    /// The result-preserving variant: `nil` means the JSON itself was unusable, while
    /// a valid `[]` is an intentionally empty menu. Callers that must distinguish a
    /// parse failure from an empty form (the login sheets, and the tests) use this.
    func parseLoginUiResult(_ loginUiJson: String) -> [LoginField]? {
        guard let array = LoginManager.lenientJSONArray(loginUiJson) else { return nil }

        return array.compactMap { dict in
            guard let name = dict["name"] as? String, !name.isEmpty else { return nil }
            let typeStr = dict["type"] as? String ?? "text"
            let type = LoginField.LoginFieldType(rawValue: typeStr) ?? .text
            let action = dict["action"] as? String
            return LoginField(
                name: name,
                type: type,
                action: action,
                options: Self.stringArray(dict["chars"]),
                defaultValue: Self.stringValue(dict["default"]),
                style: LoginFieldStyle.parse(dict["style"]),
                viewName: dict["viewName"] as? String
            )
        }
    }

    private static func stringArray(_ value: Any?) -> [String] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap(stringValue)
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        case let value?:
            return String(describing: value)
        case nil:
            return nil
        }
    }

    /// Parse a possibly-lenient JSON array of objects.
    ///
    /// Legado's `loginUi` (and some other fields) are authored as JavaScript
    /// object literals rather than strict JSON — single-quoted keys/values and
    /// trailing commas are common (e.g. the 大灰狼/光遇 aggregation sources).
    /// Strict `JSONSerialization` rejects those, so we first try strict JSON and,
    /// on failure, normalize the literal through JavaScriptCore (mirroring the
    /// lenient GSON parsing Legado uses on Android).
    static func lenientJSONArray(_ raw: String) -> [[String: Any]]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let data = trimmed.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array
        }

        guard let normalized = normalizeJSLiteral(trimmed),
              let data = normalized.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return array
    }

    /// Evaluate a JS array/object literal and re-emit it as canonical JSON.
    private static func normalizeJSLiteral(_ literal: String) -> String? {
        let context = JSContext()
        context?.exceptionHandler = { _, _ in }
        context?.setObject(literal, forKeyedSubscript: "__legadoLiteral" as NSString)
        // Wrap in parens so a leading `[`/`{` parses as an expression, and stringify.
        let script = "(function(){try{return JSON.stringify(eval('('+__legadoLiteral+')'));}catch(e){return '';}})()"
        guard let value = context?.evaluateScript(script),
              value.isString,
              let result = value.toString(),
              !result.isEmpty, result != "undefined", result != "null" else {
            return nil
        }
        return result
    }

    // MARK: - Login Header Management (mirrors Legado BaseSource)

    /// Headers to attach to requests — the stored payload parsed as a JSON object.
    /// A non-object payload (bare token) contributes nothing, matching Legado.
    func getLoginHeaders(sourceUrl: String) -> [String: String] {
        getLoginHeaderMap(sourceUrl: sourceUrl) ?? [:]
    }

    /// Retrieve the raw stored payload (Legado `getLoginHeader()`).
    func getLoginHeader(sourceUrl: String) -> String? {
        var result: String?
        queue.sync {
            result = headerCache[sourceUrl]
        }
        return result
    }

    /// Retrieve login headers as a map (Legado `getLoginHeaderMap()`):
    /// `nil` unless the stored payload is a JSON object of string values.
    func getLoginHeaderMap(sourceUrl: String) -> [String: String]? {
        guard let raw = getLoginHeader(sourceUrl: sourceUrl),
              let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              !dict.isEmpty
        else { return nil }
        return dict
    }

    /// Store the raw `putLoginHeader` payload verbatim (Legado semantics).
    func storeLoginHeader(sourceUrl: String, raw: String) {
        var changed = false
        queue.sync(flags: .barrier) {
            changed = headerCache[sourceUrl] != raw
            guard changed else { return }
            headerCache[sourceUrl] = raw
            persistHeader(sourceUrl: sourceUrl, raw: raw)
            loginInfoRevisions[sourceUrl, default: 0] &+= 1
        }
        if changed {
            // Source JS commonly calls `putLoginHeader()` and immediately issues
            // `java.ajax()` in the same evaluation (书旗's Token/GetUrl flow).
            // Keep the write synchronous and invalidate credential-dependent
            // header rules before that next request is constructed.
            notifyLoginInfoChanged(sourceUrl: sourceUrl)
        }
    }

    /// Store a header dictionary (serialized to the JSON form Legado expects).
    func storeLoginHeaders(sourceUrl: String, headers: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: headers),
              let json = String(data: data, encoding: .utf8) else { return }
        storeLoginHeader(sourceUrl: sourceUrl, raw: json)
    }

    /// Remove all login data for an explicit sign-out.
    func clearLogin(sourceUrl: String) {
        queue.sync(flags: .barrier) {
            headerCache.removeValue(forKey: sourceUrl)
            defaults.removeObject(
                forKey: LoginManager.loginHeaderPrefix + sourceUrl
            )
            // loginInfo is stored in Keychain; also clear any legacy UserDefaults entry
            credentials.delete(account: LoginManager.loginInfoPrefix + sourceUrl)
            defaults.removeObject(
                forKey: LoginManager.loginInfoPrefix + sourceUrl
            )
            loginInfoRevisions[sourceUrl, default: 0] &+= 1
        }
        notifyLoginInfoChanged(sourceUrl: sourceUrl)
    }

    /// Removes only the stored login header payload for a source, keeping the
    /// credentials (Legado `source.removeLoginHeader()` — the 删除登录头 menu item).
    func removeLoginHeader(sourceUrl: String) {
        var changed = false
        queue.sync(flags: .barrier) {
            changed = headerCache[sourceUrl] != nil
            guard changed else { return }
            headerCache.removeValue(forKey: sourceUrl)
            defaults.removeObject(
                forKey: LoginManager.loginHeaderPrefix + sourceUrl
            )
            loginInfoRevisions[sourceUrl, default: 0] &+= 1
        }
        if changed { notifyLoginInfoChanged(sourceUrl: sourceUrl) }
    }

    func runtimeHeaderSnapshot(sourceUrl: String) -> LegadoOwnedStateSnapshot {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return queue.sync {
            .init(revision: loginInfoRevisions[sourceUrl] ?? 0,
                  values: headerCache[sourceUrl].map { ["value": Data($0.utf8)] } ?? [:])
        }
    }

    /// Compare and update under the same barrier used by existing writers.
    /// Header removal never clears the user's separately owned Keychain entry.
    func compareRuntimeHeader(sourceUrl: String, expected: LegadoOwnedStateSnapshot, value: Data?) -> Bool {
        dispatchPrecondition(condition: .notOnQueue(.main))
        var changed = false
        let committed: Bool = queue.sync(flags: .barrier) {
            guard (loginInfoRevisions[sourceUrl] ?? 0) == expected.revision,
                  headerCache[sourceUrl].map({ Data($0.utf8) }) == expected.values["value"] else { return false }
            let text = value.flatMap { String(data: $0, encoding: .utf8) }
            guard value == nil || text != nil else { return false }
            guard headerCache[sourceUrl] != text else { return true }
            if let text {
                headerCache[sourceUrl] = text
                persistHeader(sourceUrl: sourceUrl, raw: text)
            } else {
                headerCache.removeValue(forKey: sourceUrl)
                defaults.removeObject(forKey: LoginManager.loginHeaderPrefix + sourceUrl)
            }
            loginInfoRevisions[sourceUrl, default: 0] &+= 1
            changed = true
            return true
        }
        if changed {
            NotificationCenter.default.post(name: .bookSourceLoginInfoDidChange, object: nil,
                userInfo: ["sourceURL": sourceUrl])
        }
        return committed
    }

    /// Checked immediate raw-header mutation for the original runtime. This is
    /// the same cache/defaults owner as existing form/legacy writers. Its ACK
    /// proves owner acceptance; UserDefaults does not expose a durable I/O ACK.
    /// Cookie ordering belongs to the calling original source operation.
    func storeRuntimeLoginHeader(sourceUrl: String, value: String?, validate: () throws -> Void,
        recordEffect: (String) -> Bool) throws -> Bool {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let started = SourcePerfTrace.now
        defer { SourcePerfTrace.record("legado.login-header.write",
            "bytes=\(value?.utf8.count ?? 0) main=\(Thread.isMainThread)", since: started, thresholdMs: 0) }
        guard (value?.utf8.count ?? 0) <= 65_536 else { throw LoginCredentialOwnerFailure.valueLimit }
        var changed = false
        let accepted = try queue.sync(flags: .barrier) {
            try validate()
            // Java raw Strings distinguish canonically equivalent spellings.
            // Compare their actual UTF-8 bytes, preserving nil versus empty.
            guard headerCache[sourceUrl].map({ Data($0.utf8) }) != value.map({ Data($0.utf8) }) else {
                try validate(); return true
            }
            guard recordEffect("sourceLoginHeaderMayCommit") else { throw CancellationError() }
            try validate()
            if let value {
                persistHeader(sourceUrl: sourceUrl, raw: value)
                headerCache[sourceUrl] = value
            } else {
                defaults.removeObject(forKey: LoginManager.loginHeaderPrefix + sourceUrl)
                headerCache.removeValue(forKey: sourceUrl)
            }
            loginInfoRevisions[sourceUrl, default: 0] &+= 1
            changed = true
            // Publish the irreversible accepted owner fact before notification
            // observers can cancel this task. No Keychain item is touched.
            recordEffect("sourceLoginHeaderCommitted")
            return true
        }
        if changed { notifyLoginInfoChanged(sourceUrl: sourceUrl) }
        return accepted
    }

    /// Apply stored login headers to a URLRequest.
    func applyLoginHeaders(to request: inout URLRequest, sourceUrl: String) {
        let headers = getLoginHeaders(sourceUrl: sourceUrl)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }

    // MARK: - Login Info (Credential) Storage

    /// Original BaseSource returns the stored String verbatim, including empty
    /// or non-JSON text. iOS protects this same existing userInfo_ account with
    /// Keychain; it does not derive/store a second Android-ID AES key or write a
    /// plaintext userInfo_ entry into the generic Legado cache.
    func runtimeLoginInfo(sourceUrl: String, validate: () throws -> Void,
        recordEffect: (String) -> Bool) throws -> String? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let started = SourcePerfTrace.now
        defer { SourcePerfTrace.record("legado.login-info.read", "main=\(Thread.isMainThread)", since: started, thresholdMs: 0) }
        return try readRawLoginInfo(sourceUrl: sourceUrl, validate: validate, recordEffect: recordEffect)
    }

    /// The same missing/present proof and add-only migration serve both the raw
    /// runtime API and the existing synchronous Map getter. A non-Map String is
    /// still a present credential and must never authorize migration/upsert.
    private func readRawLoginInfo(sourceUrl: String, validate: () throws -> Void,
        recordEffect: (String) -> Bool) throws -> String? {
        try validate()
        let account = LoginManager.loginInfoPrefix + sourceUrl
        if let raw = try credentials.loadChecked(account: account, maximumBytes: 65_536) {
            try validate(); return raw
        }
        guard let legacy = defaults.string(forKey: account) else { try validate(); return nil }
        guard legacy.utf8.count <= 65_536 else { throw LoginCredentialOwnerFailure.valueLimit }
        try validate()
        guard recordEffect("sourceLoginInfoMigrationMayCommit") else { throw CancellationError() }
        let inserted = try credentials.insertLegacyIfMissing(account: account, raw: legacy)
        if inserted {
            // Remove only the exact legacy value we migrated. A concurrent
            // Keychain writer wins rather than being overwritten by migration.
            if defaults.string(forKey: account) == legacy { defaults.removeObject(forKey: account) }
            // Migration changes protection/storage, not the logical credential
            // value. Do not add synchronous revision-queue work to the old form
            // getter; its existing synchronous I/O boundary is unchanged here.
            recordEffect("sourceLoginInfoMigrationCommitted")
            try validate(); return legacy
        }
        // A competing insert may contain newer credentials; return the actual
        // Keychain owner, never the stale legacy snapshot.
        let actual = try credentials.loadChecked(account: account, maximumBytes: 65_536)
        try validate(); return actual
    }

    /// Single Keychain-item last-writer-wins mutation, matching BaseSource's
    /// immediate put/remove. False is a known rejected write, never cancellation
    /// or an unreadable owner. An accepted write remains an accepted effect even
    /// if its caller is cancelled before the host response reaches Rhino.
    func storeRuntimeLoginInfo(sourceUrl: String, value: String?, validate: () throws -> Void,
        recordEffect: (String) -> Bool) throws -> Bool {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let started = SourcePerfTrace.now
        defer { SourcePerfTrace.record("legado.login-info.write", "bytes=\(value?.utf8.count ?? 0) main=\(Thread.isMainThread)", since: started, thresholdMs: 0) }
        guard (value?.utf8.count ?? 0) <= 65_536 else { throw LoginCredentialOwnerFailure.valueLimit }
        try validate()
        let account = LoginManager.loginInfoPrefix + sourceUrl
        let previous = try credentials.loadChecked(account: account, maximumBytes: 65_536)
        if previous == value, value != nil || defaults.object(forKey: account) == nil { try validate(); return true }
        try validate()
        guard recordEffect("sourceLoginInfoMayCommit") else { throw CancellationError() }
        let accepted = try value.map { try credentials.saveChecked(account: account, raw: $0) }
            ?? credentials.deleteChecked(account: account)
        guard accepted else { return false }
        defaults.removeObject(forKey: account)
        // The accepted Keychain write is already irreversible. Publish that
        // fact before a synchronous revision notification can cancel its caller.
        recordEffect("sourceLoginInfoCommitted")
        advanceRuntimeLoginInfoRevision(sourceUrl: sourceUrl)
        return true
    }

    private func advanceRuntimeLoginInfoRevision(sourceUrl: String) {
        queue.sync(flags: .barrier) { loginInfoRevisions[sourceUrl, default: 0] &+= 1 }
        notifyLoginInfoChanged(sourceUrl: sourceUrl)
    }

    /// Store user-provided login credentials in the **Keychain** (Legado `putLoginInfo`).
    /// Passwords are never stored in UserDefaults — Keychain is the only accepted location
    /// for sensitive data on iOS.
    func storeLoginInfo(sourceUrl: String, info: [String: String]) {
        let json: String
        do {
            json = String(decoding: try JSONSerialization.data(withJSONObject: info), as: UTF8.self)
        } catch {
            AppLogger.error("Source credentials could not be encoded", error: error)
            return
        }
        guard getLoginInfo(sourceUrl: sourceUrl) != info else { return }
        // Keep Keychain I/O outside the header queue, as in the existing login
        // path. A completed credential change advances the same revision proof.
        guard credentials.save(account: LoginManager.loginInfoPrefix + sourceUrl, json: json) else {
            AppLogger.error("Source credential owner rejected a save")
            return
        }
        queue.sync(flags: .barrier) {
            loginInfoRevisions[sourceUrl, default: 0] &+= 1
        }
        notifyLoginInfoChanged(sourceUrl: sourceUrl)
    }

    /// Revision of the credentials used by a source's dynamic header rule.
    /// This is safe to read from request workers and never returns credential data.
    func loginInfoRevision(sourceUrl: String) -> UInt64 {
        queue.sync { loginInfoRevisions[sourceUrl] ?? 0 }
    }

    private func notifyLoginInfoChanged(sourceUrl: String) {
        NotificationCenter.default.post(
            name: .bookSourceLoginInfoDidChange,
            object: nil,
            userInfo: ["sourceURL": sourceUrl]
        )
    }

    /// Retrieve stored login credentials (Legado `getLoginInfo`).
    /// Reads from Keychain; migrates legacy UserDefaults data transparently on first access.
    func getLoginInfo(sourceUrl: String) -> [String: String]? {
        let raw: String
        do {
            guard let value = try readRawLoginInfo(sourceUrl: sourceUrl, validate: {}, recordEffect: { _ in true }) else { return nil }
            raw = value
        } catch {
            // The legacy optional Map signature cannot expose a typed error.
            // Preserve/log failure without treating locked data as missing or
            // starting migration. The original runtime API still throws it.
            AppLogger.error("Source credential Map owner could not be read", context: ["errorType": String(reflecting: type(of: error))])
            return nil
        }
        do { return try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: String] }
        catch { return nil } // A present raw non-JSON/empty String is valid for the raw API, not a Map.
    }

    // MARK: - Persistence Helpers

    private func persistHeader(sourceUrl: String, raw: String) {
        defaults.set(raw, forKey: LoginManager.loginHeaderPrefix + sourceUrl)
    }

    private func loadAllHeaders() {
        let dict = defaults.dictionaryRepresentation()
        for (key, value) in dict {
            guard key.hasPrefix(LoginManager.loginHeaderPrefix),
                  let raw = value as? String
            else { continue }
            let sourceUrl = String(key.dropFirst(LoginManager.loginHeaderPrefix.count))
            headerCache[sourceUrl] = raw
        }
    }

    // MARK: - Source Bindings for JS

    /// Build a lightweight dictionary that JS can access as `source.*`.
    private func sourceBindings(for source: BookSource) -> [String: Any] {
        var bindings: [String: Any] = [
            "bookSourceUrl": source.bookSourceUrl,
            "bookSourceName": source.bookSourceName,
            "loginUrl": source.loginUrl,
            "header": source.header
        ]
        if let info = getLoginInfo(sourceUrl: source.bookSourceUrl) {
            bindings["loginInfo"] = info
        }
        if let headerJson = getLoginHeader(sourceUrl: source.bookSourceUrl) {
            bindings["loginHeader"] = headerJson
        }
        return bindings
    }
}
