import Foundation
import LegadoRuntime
import Testing
@testable import yuedu_app

private struct CookieTextNoOtherOwner: LegadoOwnedStateBacking {
    func read(sourceURL: String, domain: LegadoOwnedStateDomain, fields: Set<String>) throws -> LegadoOwnedStateSnapshot {
        throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY", message: "No other fixture owner was granted")
    }
    func commit(sourceURL: String, domain: LegadoOwnedStateDomain, expected: LegadoOwnedStateSnapshot, changes: [String: Data?]) throws -> Bool {
        throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY", message: "No other fixture owner was granted")
    }
}

private final class CookieTextWriteGate: @unchecked Sendable {
    private let lock = NSLock(), released = DispatchSemaphore(value: 0)
    private var armed = false, entered = false, fail = false
    private var waiter: CheckedContinuation<Void, Never>?
    func arm(failing: Bool = false) { lock.withLock { armed = true; fail = failing } }
    func beforeWrite() throws {
        let action = lock.withLock { () -> (Bool, Bool) in
            guard armed else { return (false, false) }
            armed = false; entered = true; waiter?.resume(); waiter = nil
            return (true, fail)
        }
        guard action.0 else { return }
        dispatchPrecondition(condition: .notOnQueue(.main))
        if action.1 { throw CookieOwnerError(code: "STATE_IO", message: "Injected owned write failure") }
        released.wait()
    }
    func waitUntilEntered() async {
        await withCheckedContinuation { pending in lock.withLock { if entered { pending.resume() } else { waiter = pending } } }
    }
    func release() { released.signal() }
}

@Suite("Actual original Cookie text owner callback", .serialized)
struct LegadoCookieTextHostTests {
    private struct Fixture {
        let directory: URL, file: URL
        let storage: HTTPCookieStorage
        let cookies: CookieStore
        let host: LegadoPersistentStateHost
        let owner: String
    }
    private func fixture(gate: CookieTextWriteGate? = nil) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("legado_cookies.json")
        let storage = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let cookies = CookieStore(fileURL: file, storage: storage, beforeWrite: { try gate?.beforeWrite() })
        let host = LegadoPersistentStateHost(backing: CookieTextNoOtherOwner(), cookieOwner: cookies)
        let owner = try await host.bind(sourceURL: "https://reader.example.co.uk", sourceRevision: "owned-r1")
        return .init(directory: directory, file: file, storage: storage, cookies: cookies, host: host, owner: owner)
    }
    private func cleanup(_ f: Fixture) {
        do { try FileManager.default.removeItem(at: f.directory) }
        catch { Issue.record("Owned text Cookie cleanup failed: \(error)") }
    }
    private func request(owner: String, action: String, domain: String = "example.co.uk", url: String = "https://reader.example.co.uk/chapter",
                         task: String = UUID().uuidString, extra: [String: Any] = [:]) throws -> LegadoHostRequest {
        var input: [String: Any] = ["owner": owner, "action": action, "domain": domain, "url": url]
        input.merge(extra) { _, latest in latest }
        return .init(taskID: task, operation: "cookie.owner.text", requestJSON: String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self))
    }
    private func result(_ f: Fixture, action: String, domain: String = "example.co.uk", extra: [String: Any] = [:]) async throws -> String {
        struct Reply: Decodable { let cookie: String }
        let json = try await f.host.dispatch(request(owner: f.owner, action: action, domain: domain, extra: extra))
        return try JSONDecoder().decode(Reply.self, from: Data(json.utf8)).cookie
    }
    private func parsedCookie(name: String = "sid", value: String, domain: String = "example.co.uk", path: String,
                              persistent: Bool, expiry: Int64, hostOnly: Bool, secure: Bool = false, httpOnly: Bool = false) -> [String: Any] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let expires = formatter.string(from: Date(timeIntervalSince1970: Double(expiry) / 1000))
        let raw = "\(name)=\(value); Path=\(path)" + (hostOnly ? "" : "; Domain=\(domain)")
            + (secure ? "; Secure" : "") + (httpOnly ? "; HttpOnly" : "")
            + (persistent ? "; Expires=\(expires)" : "")
        return ["name": name, "value": value, "domain": domain, "path": path, "persistent": persistent,
                "expiresAtMs": expiry, "hostOnly": hostOnly, "secure": secure, "httpOnly": httpOnly, "setCookieHeader": raw]
    }
    private func response(owner: String, cookies: [[String: Any]], url: String = "https://reader.example.co.uk/private/chapter") throws -> LegadoHostRequest {
        let persistent = cookies.filter { ($0["persistent"] as? Bool) == true }.map { "\($0["name"] as! String)=\($0["value"] as! String)" }.joined(separator: "; ")
        let session = cookies.filter { ($0["persistent"] as? Bool) == false }.map { "\($0["name"] as! String)=\($0["value"] as! String)" }.joined(separator: "; ")
        return try request(owner: owner, action: "response", url: url, extra: ["cookies": cookies,
            "headers": cookies.map { $0["setCookieHeader"] as! String }, "persistentText": persistent, "sessionText": session])
    }

    @Test("set keeps raw DB bytes and original replace/get preserve case duplicates blank classes and empty-old input")
    func rawTextMethodsUseTheExistingFileAndOriginalStringSemantics() async throws {
        let f = try await fixture(); defer { cleanup(f) }
        let raw = " Case =one; case=two; dup=first; dup=last; eq=left=right; empty=; blank=\u{A0}; nel=\u{85}; null=null; =empty-key;comb=\u{301}v;semi=\u{37E};\u{E9}=one;e\u{301}=two;;"
        _ = try await f.host.dispatch(request(owner: f.owner, action: "set", extra: ["cookie": raw]))
        #expect(try await f.cookies.snapshot().legacyHeaders["example.co.uk"] == raw)
        #expect(try await result(f, action: "get") == "Case=one; case=two; dup=last; eq=left=right; nel=\u{85}; null=null; =empty-key; comb=\u{301}v; semi=\u{37E}; \u{E9}=one; e\u{301}=two")
        _ = try await f.host.dispatch(request(owner: f.owner, action: "replace", extra: ["cookie": "dup=new; extra=three; blank= ; eq=a=b=c"]))
        #expect(try await result(f, action: "get") == "Case=one; case=two; dup=new; eq=a=b=c; nel=\u{85}; null=null; =empty-key; comb=\u{301}v; semi=\u{37E}; \u{E9}=one; e\u{301}=two; extra=three")
        _ = try await f.host.dispatch(request(owner: f.owner, action: "replace", domain: "javascript:owned", extra: ["cookie": " incoming = raw;;"]))
        #expect(try await f.cookies.snapshot().legacyHeaders["javascript:owned"] == " incoming = raw;;")
        _ = try await f.host.dispatch(request(owner: f.owner, action: "remove"))
        #expect(try await result(f, action: "get").isEmpty)
        #expect(try await result(f, action: "get", domain: "javascript:owned") == "incoming=raw")
        // Room/JVM strings keep distinct UTF-8 identities that Swift String
        // Dictionary would canonically equate, both as keys and as raw values.
        let composed = "raw-\u{E9}", decomposed = "raw-e\u{301}"
        for (domain, value) in [(composed, "v=first"), (decomposed, "v=second"), ("raw-\u{212A}", "v=kelvin"), ("raw-K", "v=ascii")] {
            _ = try await f.host.dispatch(request(owner: f.owner, action: "set", domain: domain, extra: ["cookie": value]))
        }
        _ = try await f.host.dispatch(request(owner: f.owner, action: "set", domain: "raw-value", extra: ["cookie": "v=\u{E9}"]))
        _ = try await f.host.dispatch(request(owner: f.owner, action: "set", domain: "raw-value", extra: ["cookie": "v=e\u{301}"]))
        #expect(try await f.cookies.originalRawText(domain: composed).utf8.elementsEqual("v=first".utf8))
        #expect(try await f.cookies.originalRawText(domain: decomposed).utf8.elementsEqual("v=second".utf8))
        let fresh = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let reopened = CookieStore(fileURL: f.file, storage: fresh)
        #expect(try await reopened.originalRawText(domain: composed).utf8.elementsEqual("v=first".utf8))
        #expect(try await reopened.originalRawText(domain: decomposed).utf8.elementsEqual("v=second".utf8))
        #expect(try await reopened.originalRawText(domain: "raw-\u{212A}").utf8.elementsEqual("v=kelvin".utf8))
        #expect(try await reopened.originalRawText(domain: "raw-K").utf8.elementsEqual("v=ascii".utf8))
        #expect(try await reopened.originalRawText(domain: "raw-value").utf8.elementsEqual("v=e\u{301}".utf8))
        #expect(try await reopened.originalText(domain: "javascript:owned") == "incoming=raw")
        #expect(try await reopened.originalText(domain: "example.co.uk").isEmpty)
    }

    @Test("response text uses last-name update across path/subdomain while rich RFC attributes and DB/session restart lifetimes stay distinct")
    func responseTextPrecedenceAndNativeMetadataSurviveTheirCorrectLifetimes() async throws {
        let f = try await fixture(); defer { cleanup(f) }
        let expiry: Int64 = 4_071_686_400_000 // 2099-01-10; fixed, no settling waits.
        let persistent = parsedCookie(value: "persistent", path: "/private", persistent: true, expiry: expiry, hostOnly: false, secure: true, httpOnly: true)
        _ = try await f.host.dispatch(response(owner: f.owner, cookies: [persistent]))
        let first = parsedCookie(value: "first-session", domain: "reader.example.co.uk", path: "/a", persistent: false, expiry: 253_402_300_799_999, hostOnly: true)
        _ = try await f.host.dispatch(response(owner: f.owner, cookies: [first]))
        let last = parsedCookie(value: "last-session", domain: "other.example.co.uk", path: "/b", persistent: false, expiry: 253_402_300_799_999, hostOnly: true)
        _ = try await f.host.dispatch(response(owner: f.owner, cookies: [last], url: "https://other.example.co.uk/b/page"))
        #expect(try await result(f, action: "get") == "sid=last-session")
        let accepted = try await f.cookies.snapshot()
        #expect(accepted.legacyHeaders["example.co.uk"] == "sid=persistent")
        #expect(accepted.cookies.count == 3)
        #expect(accepted.cookies.first?.hostOnly == false)
        #expect(accepted.cookies.first?.originalDomain == "example.co.uk")
        #expect(accepted.cookies.first?.originalExpiresAtMs == expiry)
        #expect(accepted.cookies.first?.originalSetCookieHeader == (persistent["setCookieHeader"] as? String))
        let firstRecord = try #require(accepted.cookies.first)
        let nativePersistent = try firstRecord.native()
        #expect(nativePersistent.isSecure && nativePersistent.isHTTPOnly && !nativePersistent.isSessionOnly)
        #expect(nativePersistent.domain == ".example.co.uk" && nativePersistent.path == "/private")
        #expect(firstRecord.originalExpirationDate == Date(timeIntervalSince1970: Double(expiry) / 1000))
        let capturedProjection = try #require(firstRecord.expiresAt)
        #expect(nativePersistent.expiresDate == capturedProjection)
        #expect(capturedProjection.timeIntervalSince1970.rounded(.down) == capturedProjection.timeIntervalSince1970)
        #expect(capturedProjection <= Date(timeIntervalSince1970: Double(expiry) / 1000))
        #expect(capturedProjection > Date())
        let sessionRecord = try #require(accepted.cookies.dropFirst().first)
        let nativeSession = try sessionRecord.native()
        #expect(nativeSession.isSessionOnly && nativeSession.expiresDate == nil)
        #expect(!nativeSession.isSecure && !nativeSession.isHTTPOnly)
        let privateURL = try #require(URL(string: "https://reader.example.co.uk/private/chapter"))
        #expect(try await f.cookies.requestHeader(url: privateURL)?.contains("sid=persistent") == true)
        let publicHTTP = try #require(URL(string: "http://reader.example.co.uk/public"))
        #expect(try await f.cookies.requestHeader(url: publicHTTP) == nil)
        let fresh = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let reopened = CookieStore(fileURL: f.file, storage: fresh)
        #expect(try await reopened.originalText(domain: "example.co.uk") == "sid=persistent")
        #expect(try await reopened.snapshot().cookies.count == 3)
        // Native/App session records may remain durable; they never reconstruct
        // the original per-owner CacheManager session-text memory after restart.
        #expect(try await reopened.originalSession(domain: "example.co.uk").isEmpty)
        // The original parsed millisecond deadline stays absolute even when
        // Foundation's response parser also sees a relative Max-Age attribute.
        let absolute = Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000
        var maxAge = parsedCookie(name: "relative", value: "absolute", domain: "reader.example.co.uk", path: "/private",
            persistent: true, expiry: absolute, hostOnly: true, secure: true, httpOnly: true)
        maxAge["setCookieHeader"] = "relative=absolute; Path=/private; Secure; HttpOnly; Max-Age=3600"
        _ = try await f.host.dispatch(response(owner: f.owner, cookies: [maxAge]))
        let afterRelative = try await f.cookies.snapshot()
        let relativeRecord = try #require(afterRelative.cookies.first { $0.originalExpiresAtMs == absolute })
        let relativeNative = try relativeRecord.native()
        #expect(relativeRecord.originalExpiresAtMs == absolute)
        #expect(relativeRecord.originalExpirationDate == Date(timeIntervalSince1970: Double(absolute) / 1000))
        #expect(relativeNative.expiresDate == Date(timeIntervalSince1970: Double(absolute / 1000)))
        #expect(relativeNative.isHTTPOnly && relativeNative.isSecure && !relativeNative.isSessionOnly)

        // Synthetic durable input: an old platform projection has expired,
        // while its unchanged original2099 deadline remains alive. Native
        // creation uses the real public initializer; no Created/clock is set.
        var expiredProperties = try #require(nativePersistent.properties)
        expiredProperties.removeValue(forKey: .maximumAge)
        expiredProperties[.expires] = Date(timeIntervalSince1970: 1)
        let expiredNative = try #require(HTTPCookie(properties: expiredProperties))
        let expiredProjection = try CookiePersistenceOwner.Record(cookie: expiredNative, provenance: .httpResponse,
            originURL: firstRecord.originURL, hostOnly: firstRecord.hostOnly, originalExpiresAtMs: expiry,
            originalDomain: firstRecord.originalDomain, originalSetCookieHeader: firstRecord.originalSetCookieHeader)
        let syntheticFile = f.directory.appendingPathComponent("synthetic-expired-projection.json")
        let syntheticDocument = CookiePersistenceOwner.Document(legacyHeaders: ["example.co.uk": "sid=persistent"], cookies: [expiredProjection])
        let syntheticBytes = try JSONEncoder().encode(syntheticDocument)
        try syntheticBytes.write(to: syntheticFile)
        let projectionStorage = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let projectionGate = CookieTextWriteGate()
        let projectionOwner = CookieStore(fileURL: syntheticFile, storage: projectionStorage,
            beforeWrite: { try projectionGate.beforeWrite() })
        projectionGate.arm(failing: true)
        do { _ = try await projectionOwner.snapshot(); Issue.record("A failed projection refresh must not publish") }
        catch let error as CookieOwnerError { #expect(error.code == "STATE_IO") }
        #expect(try Data(contentsOf: syntheticFile) == syntheticBytes)
        #expect(projectionStorage.cookies?.isEmpty != false)
        let refreshed = try await projectionOwner.snapshot()
        let refreshedRecord = try #require(refreshed.cookies.first)
        #expect(refreshedRecord.originalExpiresAtMs == expiry)
        #expect(refreshedRecord.originalExpirationDate == firstRecord.originalExpirationDate)
        #expect(refreshedRecord.originalSetCookieHeader == firstRecord.originalSetCookieHeader)
        #expect(refreshedRecord.originalDomain == firstRecord.originalDomain)
        #expect(refreshedRecord.originURL == firstRecord.originURL && refreshedRecord.hostOnly == firstRecord.hostOnly)
        #expect(refreshed.legacyHeaders == syntheticDocument.legacyHeaders && refreshed.cookies.count == 1)
        let refreshedExpiration = try #require(refreshedRecord.expiresAt)
        #expect(refreshedExpiration > Date())
        #expect(try refreshedRecord.native().expiresDate == refreshedRecord.expiresAt)
        let refreshedBytes = try Data(contentsOf: syntheticFile)
        #expect(refreshedBytes != syntheticBytes)
        #expect(try JSONDecoder().decode(CookiePersistenceOwner.Document.self, from: refreshedBytes) == refreshed)
        let publishedProjection = try #require(projectionStorage.cookies?.first { $0.path == "/private" && $0.name == "sid" })
        #expect(publishedProjection.expiresDate == refreshedExpiration && publishedProjection.value == "persistent")
        #expect(try await projectionOwner.requestHeader(url: privateURL)?.contains("sid=persistent") == true)
        projectionGate.arm(failing: true)
        #expect(try await projectionOwner.snapshot() == refreshed)
        #expect(try Data(contentsOf: syntheticFile) == refreshedBytes)

        // A real refresh cannot overwrite an independently live native value
        // sharing the old projection identity. The owner file still retains its
        // accepted original deadline; this is not an external-jar CAS claim.
        let foreignFile = f.directory.appendingPathComponent("synthetic-foreign-projection.json")
        try syntheticBytes.write(to: foreignFile)
        let foreignStorage = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        var foreignProperties = try #require(nativePersistent.properties)
        foreignProperties[.value] = "foreign"
        let foreign = try #require(HTTPCookie(properties: foreignProperties))
        foreignStorage.setCookie(foreign)
        let foreignOwner = CookieStore(fileURL: foreignFile, storage: foreignStorage)
        let foreignAccepted = try await foreignOwner.snapshot()
        #expect(foreignAccepted.cookies.first?.originalExpiresAtMs == expiry)
        #expect(foreignAccepted.cookies.first?.originalExpirationDate == firstRecord.originalExpirationDate)
        let preservedForeign = try #require(foreignStorage.cookies?.first { $0.path == "/private" && $0.name == "sid" })
        #expect(preservedForeign.value == "foreign" && preservedForeign.expiresDate == foreign.expiresDate)
        #expect(try await foreignOwner.requestHeader(url: privateURL)?.contains("sid=foreign") == true)

        // A pure selection fixture exercises the final fractional window and
        // exact expiry boundary without advancing/injecting a platform clock.
        let fractionalMs = expiry + 250
        let fractionalRecord = try CookiePersistenceOwner.Record(cookie: expiredNative, provenance: .httpResponse,
            originURL: firstRecord.originURL, hostOnly: firstRecord.hostOnly, originalExpiresAtMs: fractionalMs,
            originalDomain: firstRecord.originalDomain, originalSetCookieHeader: firstRecord.originalSetCookieHeader)
        let inside = Date(timeIntervalSince1970: Double(expiry) / 1000 + 0.125)
        let deadline = Date(timeIntervalSince1970: Double(fractionalMs) / 1000)
        let tail = try CookiePersistenceOwner.requestCookies([fractionalRecord], native: [], url: privateURL, at: inside)
        #expect(HTTPCookie.requestHeaderFields(with: tail)["Cookie"] == "sid=persistent")
        #expect(try CookiePersistenceOwner.requestCookies([fractionalRecord], native: [], url: privateURL, at: deadline).isEmpty)
        #expect(try CookiePersistenceOwner.requestCookies([fractionalRecord], native: [], url: publicHTTP, at: inside).isEmpty)
        let encodedPath = try #require(URL(string: "https://reader.example.co.uk/private%2Fchapter"))
        #expect(try CookiePersistenceOwner.requestCookies([fractionalRecord], native: [], url: encodedPath, at: inside).isEmpty)
        try await f.cookies.clearAllOwned()
        #expect(try await result(f, action: "get").isEmpty)
    }

    @Test("original DB strings keep their original expiry semantics while native RFC headers suppress known expired records")
    func originalRawExpiryAndRandomPruningBoundaryRemainExplicit() async throws {
        let f = try await fixture(); defer { cleanup(f) }
        let expired = parsedCookie(value: "expired-text", path: "/", persistent: true, expiry: 1_000, hostOnly: true)
        var rootCookie = expired; rootCookie["domain"] = "example.co.uk"
        _ = try await f.host.dispatch(response(owner: f.owner, cookies: [rootCookie], url: "https://example.co.uk/chapter"))
        #expect(try await result(f, action: "get") == "sid=expired-text")
        let url = try #require(URL(string: "https://example.co.uk/chapter"))
        #expect(try await f.cookies.requestHeader(url: url) == nil)
        let fresh = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let reopened = CookieStore(fileURL: f.file, storage: fresh)
        #expect(try await reopened.originalText(domain: "example.co.uk") == "sid=expired-text")
        #expect(try await reopened.requestHeader(url: url) == nil)
        let giant = "giant=" + String(repeating: "x", count: 5_000)
        _ = try await f.host.dispatch(request(owner: f.owner, action: "set", domain: "prune.invalid", extra: ["cookie": giant]))
        _ = try await f.host.dispatch(request(owner: f.owner, action: "removeKey", domain: "prune.invalid", extra: ["cookie": "giant"]))
        // The original remove-key helper declines to persist an empty map.
        #expect(try await f.cookies.snapshot().legacyHeaders["prune.invalid"] == giant)
    }

    @Test("write failure and a cancelled or revoked queued owner commit retain prior actual file state")
    func failedCancelledAndRevokedMutationsKeepOldBytes() async throws {
        for phase in ["failure", "cancel", "revoke"] {
            let gate = CookieTextWriteGate(), f = try await fixture(gate: gate); defer { cleanup(f) }
            _ = try await f.host.dispatch(request(owner: f.owner, action: "set", extra: ["cookie": "sid=old"]))
            let before = try Data(contentsOf: f.file)
            gate.arm(failing: phase == "failure")
            let input = try request(owner: f.owner, action: "set", task: "held-text-write", extra: ["cookie": "sid=new"])
            let pending = Task { try await f.host.dispatch(input) }
            await gate.waitUntilEntered()
            if phase == "cancel" { await f.host.cancel(taskID: "held-text-write") }
            if phase == "revoke" { _ = try await f.host.bind(sourceURL: "https://reader.example.co.uk", sourceRevision: "owned-r2") }
            gate.release()
            do { _ = try await pending.value; Issue.record("The held Cookie text mutation must fail before replacement") }
            catch is CancellationError { #expect(phase != "failure") }
            catch let error as LegadoRuntimeError { #expect(phase == "failure" && error.code == "STATE_IO") }
            #expect(try Data(contentsOf: f.file) == before)
            #expect(try await f.cookies.originalText(domain: "example.co.uk") == "sid=old")
            let fresh = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
            let reopened = CookieStore(fileURL: f.file, storage: fresh)
            #expect(try await reopened.originalText(domain: "example.co.uk") == "sid=old")
        }
    }

    @Test("unknown actions malformed metadata and outward cross-owner batches reject before any Cookie write")
    func unsupportedAndMalformedRequestsPreflightTheWholeOperation() async throws {
        let f = try await fixture(); defer { cleanup(f) }
        _ = try await f.host.dispatch(request(owner: f.owner, action: "set", extra: ["cookie": "sid=old"]))
        let before = try Data(contentsOf: f.file)
        let bad = [
            try request(owner: f.owner, action: "writeEverything"),
            try request(owner: f.owner, action: "set", extra: ["cookie": 42]),
            try request(owner: f.owner, action: "set", extra: ["cookie": "sid=new", "deadlineEpochMs": true]),
            try request(owner: f.owner, action: "response", extra: ["cookies": [], "headers": []])
        ]
        for input in bad {
            do { _ = try await f.host.dispatch(input); Issue.record("Malformed Cookie text request cannot acknowledge") }
            catch let error as LegadoRuntimeError { #expect(["INVALID_STATE_REQUEST", "UNSUPPORTED_CAPABILITY"].contains(error.code)) }
        }
        let source = "https://reader.example.co.uk"
        let keys = [try JSONSerialization.data(withJSONObject: [source, "cache-text", "loginHeader_" + source]),
                    try JSONSerialization.data(withJSONObject: [source, "cookies"])]
            .map { String(decoding: $0, as: UTF8.self) }
        let json = try JSONSerialization.data(withJSONObject: ["owner": f.owner, "keys": keys])
        do { _ = try await f.host.dispatch(.init(taskID: "atomic-batch", operation: "state.read", requestJSON: String(decoding: json, as: UTF8.self))); Issue.record("Cross-owner atomic Cookie batch must reject") }
        catch let error as LegadoRuntimeError { #expect(error.code == "UNSUPPORTED_CAPABILITY") }
        // Native HttpOnly metadata cannot be silently dropped to fit a false
        // producer flag. The failed response cannot replace old owner bytes.
        var wrongHTTPOnly = parsedCookie(value: "must-not-commit", path: "/private", persistent: true,
            expiry: 4_071_686_400_000, hostOnly: false, secure: true, httpOnly: true)
        wrongHTTPOnly["httpOnly"] = false
        do { _ = try await f.host.dispatch(response(owner: f.owner, cookies: [wrongHTTPOnly])); Issue.record("HttpOnly mismatch must reject") }
        catch let error as LegadoRuntimeError {
            #expect(error.code == "UNSUPPORTED_CAPABILITY")
            #expect(error.message.contains("httpOnly"))
            #expect(!error.message.contains("must-not-commit") && !error.message.contains("example.co.uk"))
        }
        #expect(try Data(contentsOf: f.file) == before)
        #expect(try await f.cookies.originalText(domain: "example.co.uk") == "sid=old")
    }
}
