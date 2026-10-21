import Foundation
import WebKit

extension CookieStore {
    /// Begin on the Cookie actor, perform WebKit IPC on main, and commit back on
    /// the same actor. No main thread waits for persistence or copies the jar.
    func captureWebKit(_ store: WKHTTPCookieStore, confirming scope: URL? = nil,
                       requireCurrent: Bool = true,
                       validate: @escaping @Sendable () throws -> Void = {}) async throws -> [HTTPCookie] {
        let observation = try await beginWebKitObservation()
        try Task.checkCancellation()
        let cookies = try await Self.readWebKit(store)
        try Task.checkCancellation()
        try await ingestWebKitSnapshot(cookies, observation: observation, confirming: scope,
            requireCurrent: requireCurrent, validate: validate)
        return cookies
    }

    @MainActor
    private static func readWebKit(_ store: WKHTTPCookieStore) async throws -> [HTTPCookie] {
        try await originalWebCookieIPC { (wait: OriginalWebCookieIPCWait<[HTTPCookie]>) in
            store.getAllCookies { wait.finish(.success($0)) }
        }
    }
}

/// This is a Cookie-store operation lease, never a WKWebView navigation lease.
/// Once WebKit IPC has been issued cancellation cannot retract its native side
/// effect; the error retains that fact instead of claiming rollback.
struct OriginalCookieWebKitFailure: Error, LocalizedError, @unchecked Sendable {
    let underlying: Error
    let completedEffects: [String]
    var errorDescription: String? { "WebKit Cookie mutation was issued; earlier browser effects may already exist" }
}

enum OriginalCookieWebKitMutation: Sendable {
    case set(baseURL: String, pieces: [String])
    case remove(domains: [String])
}

extension CookieStore {
    /// Uses the existing default website Cookie store directly. No WebView,
    /// navigation, JS context, HTTP session or replacement jar is constructed.
    /// The optional store is the actual existing owned WK store in SDK fixtures.
    func performOriginalWebCookieMutation(_ operation: OriginalCookieWebKitMutation,
                                          storeProvider: @MainActor @Sendable () -> WKHTTPCookieStore = { WKWebsiteDataStore.default().httpCookieStore },
                                          recordPossibleEffect: @escaping @Sendable (String) -> Bool = { _ in true },
                                          validate: @escaping @Sendable () throws -> Void) async throws {
        let started = SourcePerfTrace.now
        var observedCount = 0
        defer { SourcePerfTrace.record("cookie.original.web", "cookies=\(observedCount) main=\(Thread.isMainThread)", since: started) }
        let store = await storeProvider()
        let observation = try await beginWebKitObservation()
        let effects = OriginalWebCookieIssuedEffects(record: recordPossibleEffect)
        var authoritative: [HTTPCookie] = []
        var deleted = Set<Data>(), expected: [Data: HTTPCookie] = [:]
        func mark(_ value: String) { effects.mark(value) }
        func check() async throws {
            try Task.checkCancellation(); try validate()
            try await validateWebKitObservation(observation, validate: validate)
        }
        do {
            try await check()
            var cookies = try await Self.readOriginalWebCookies(store)
            observedCount = cookies.count
            try await check()
            guard cookies.count <= 16_384 else { throw CookieOwnerError(code: "STATE_LIMIT", message: "Too many browser Cookies") }
            switch operation {
            case .set(let rawURL, let pieces):
                guard let baseURL = URL(string: rawURL), baseURL.host != nil,
                      ["http", "https"].contains(baseURL.scheme?.lowercased() ?? "") else {
                    throw CookieOwnerError(code: "INVALID_STATE_REQUEST", message: "Original Web Cookie base URL is invalid")
                }
                // Locked setWebCookie first removes ALL browser session Cookies,
                // then submits each already split/trimmed piece in source order.
                for cookie in cookies where cookie.isSessionOnly || cookie.expiresDate == nil {
                    try await check()
                    try await Self.deleteWebCookie(cookie, store: store) { try effects.begin("webKitCookieMutationIssued") }
                    authoritative.append(cookie); deleted.insert(Self.webCookieIdentity(cookie))
                    mark("webSessionCookiesRemoved"); try await check()
                }
                for piece in pieces {
                    try await check()
                    let parsed = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": piece], for: baseURL)
                    guard parsed.count <= 1 else { throw CookieOwnerError(code: "UNSUPPORTED_CAPABILITY", message: "One original Web Cookie piece produced multiple native Cookies") }
                    // WebKit's platform parser may reject a malformed piece just
                    // as the original platform setter can; no raw attribute is
                    // converted into guessed rich metadata or another parser.
                    for cookie in parsed {
                        try await check()
                        try await Self.setWebCookie(cookie, store: store) { try effects.begin("webKitCookieMutationIssued") }
                        authoritative.append(cookie); expected[Self.webCookieIdentity(cookie)] = cookie
                        mark("webCookiesApplied"); try await check()
                    }
                }
            case .remove(let domains):
                // The locked extension expires root-path names at exactly its
                // getDomain and getSubDomain targets. It does not purge every
                // child/parent domain or other paths merely sharing that name.
                for domain in domains {
                    try await check()
                    let host = Self.webCookieDomain(domain)
                    for cookie in cookies where Self.webCookieDomain(cookie.domain) == host && cookie.path == "/" {
                        try await check()
                        // Match the locked expired name=value setter, rather
                        // than broadly deleting a domain Cookie with unknown
                        // hostOnly provenance. A separate .domain Cookie may
                        // legitimately survive the host-only expiration.
                        guard let expired = HTTPCookie(properties: [.name: cookie.name, .value: "",
                            .domain: host, .path: "/", .expires: Date(timeIntervalSince1970: 978_307_199)]) else {
                            throw CookieOwnerError(code: "UNSUPPORTED_CAPABILITY", message: "Original browser expiration cannot be represented")
                        }
                        try await Self.setWebCookie(expired, store: store) { try effects.begin("webKitCookieMutationIssued") }
                        authoritative.append(expired); expected[Self.webCookieIdentity(expired)] = expired
                        mark("webCookiesRemoved"); try await check()
                    }
                    // The original second target observes changes from the
                    // first, including duplicate target no-op behavior.
                    cookies = try await Self.readOriginalWebCookies(store); try await check()
                }
            }
            try await check()
            let actual = try await Self.readOriginalWebCookies(store)
            try await check()
            var values: [Data: HTTPCookie] = [:]
            for cookie in actual {
                guard values.updateValue(cookie, forKey: Self.webCookieIdentity(cookie)) == nil else {
                    throw CookieOwnerError(code: "STATE_IO", message: "WebKit returned duplicate Cookie identities")
                }
            }
            for identity in deleted where expected[identity] == nil {
                guard values[identity] == nil else { throw CookieOwnerError(code: "STATE_IO", message: "WebKit did not acknowledge a requested Cookie removal") }
            }
            for (identity, cookie) in expected {
                if cookie.expiresDate.map({ $0 <= Date() }) == true {
                    guard values[identity] == nil else { throw CookieOwnerError(code: "STATE_IO", message: "WebKit retained an expired Cookie") }
                } else {
                    guard let value = values[identity], value.value == cookie.value,
                          value.isSecure == cookie.isSecure, value.isHTTPOnly == cookie.isHTTPOnly else {
                        throw CookieOwnerError(code: "STATE_IO", message: "WebKit did not acknowledge an applied Cookie")
                    }
                }
            }
            // Publish only for this still-current operation. Unrelated initial
            // WK values do not acquire authority over newer HTTP values. Raw DB
            // and original CacheManager text are not altered by setWebCookie.
            try await ingestWebKitSnapshot(actual, observation: observation, requireCurrent: false,
                preservingOriginalRaw: true, authoritativeCookies: authoritative, validate: validate)
        } catch {
            let issued = effects.snapshot()
            if issued.isEmpty { throw error }
            throw OriginalCookieWebKitFailure(underlying: error, completedEffects: issued)
        }
    }

    @MainActor
    private static func readOriginalWebCookies(_ store: WKHTTPCookieStore) async throws -> [HTTPCookie] {
        let cookies = try await originalWebCookieIPC { (wait: OriginalWebCookieIPCWait<[HTTPCookie]>) in
            store.getAllCookies { wait.finish(.success($0)) }
        }
        guard cookies.count <= 16_384 else { throw CookieOwnerError(code: "STATE_LIMIT", message: "Too many browser Cookies") }
        return cookies
    }
    @MainActor
    private static func deleteWebCookie(_ cookie: HTTPCookie, store: WKHTTPCookieStore,
                                        issued: @Sendable () throws -> Void) async throws {
        try await originalWebCookieIPC(beforeIssue: issued) { (wait: OriginalWebCookieIPCWait<Void>) in
            // Record immediately before issuing the real IPC, including the
            // cancellation window in which its completion never comes back.
            store.delete(cookie) { wait.finish(.success(Void())) }
        }
    }
    @MainActor
    private static func setWebCookie(_ cookie: HTTPCookie, store: WKHTTPCookieStore,
                                     issued: @Sendable () throws -> Void) async throws {
        try await originalWebCookieIPC(beforeIssue: issued) { (wait: OriginalWebCookieIPCWait<Void>) in
            store.setCookie(cookie) { wait.finish(.success(Void())) }
        }
    }
    @MainActor
    private static func originalWebCookieIPC<Value>(beforeIssue: @Sendable () throws -> Void = {},
                                                   _ issue: (OriginalWebCookieIPCWait<Value>) -> Void) async throws -> Value {
        let wait = OriginalWebCookieIPCWait<Value>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard wait.install(continuation) else { return }
                do { if try wait.beginIssue(beforeIssue) { issue(wait) } }
                catch { wait.finish(.failure(error)) }
            }
        } onCancel: { wait.finish(.failure(CancellationError())) }
    }
    private static func webCookieIdentity(_ cookie: HTTPCookie) -> Data {
        Data((cookie.domain.lowercased() + "\u{0}" + cookie.path + "\u{0}" + cookie.name).utf8)
    }
    private static func webCookieDomain(_ domain: String) -> String {
        (domain.hasPrefix(".") ? String(domain.dropFirst()) : domain).lowercased()
    }
}

/// Only owns one Cookie IPC continuation. Finishing cancellation is immediate;
/// WebKit itself remains outside this lease and a late callback becomes a no-op.
private final class OriginalWebCookieIPCWait<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        let early: Result<Value, Error>? = lock.withLock {
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let early { continuation.resume(with: early); return false }
        return true
    }
    func finish(_ result: Result<Value, Error>) {
        let pending: CheckedContinuation<Value, Error>? = lock.withLock {
            guard self.result == nil else { return nil }
            self.result = result
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
    }
    func beginIssue(_ record: () throws -> Void) throws -> Bool {
        try lock.withLock {
            guard result == nil else { return false }
            // Cancellation cannot resume before conservative issued facts are
            // visible, then let an unreported IPC escape immediately after it.
            try record()
            return true
        }
    }
}

/// Request-local bounded control facts, shared safely across the worker doing
/// Cookie planning and the main-actor IPC issue. No Cookie values live here.
private final class OriginalWebCookieIssuedEffects: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    private let record: @Sendable (String) -> Bool
    init(record: @escaping @Sendable (String) -> Bool) { self.record = record }
    func begin(_ value: String) throws {
        // This registration and the native timeout's close share one lock. A
        // denied old child cannot issue IPC after the response already escaped.
        guard record(value) else { throw CancellationError() }
        lock.withLock { if !values.contains(value) { values.append(value) } }
    }
    func mark(_ value: String) {
        lock.withLock { if !values.contains(value) { values.append(value) } }
        _ = record(value)
    }
    func snapshot() -> [String] { lock.withLock { values } }
}
