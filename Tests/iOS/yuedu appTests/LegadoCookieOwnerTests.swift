import Foundation
import Network
import Testing
import WebKit
@testable import yuedu_app

private final class CookieFixtureCredentials: @unchecked Sendable, LoginCredentialStorage {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func load(account: String) -> String? { lock.withLock { values[account] } }
    func save(account: String, json: String) -> Bool { lock.withLock { values[account] = json }; return true }
    func delete(account: String) { lock.withLock { _ = values.removeValue(forKey: account) } }
    func loadChecked(account: String, maximumBytes: Int) throws -> String? {
        try lock.withLock {
            guard (values[account]?.utf8.count ?? 0) <= maximumBytes else { throw LoginCredentialOwnerFailure.valueLimit }
            return values[account]
        }
    }
    func saveChecked(account: String, raw: String) throws -> Bool { save(account: account, json: raw) }
    func deleteChecked(account: String) throws -> Bool { delete(account: account); return true }
    func insertLegacyIfMissing(account: String, raw: String) throws -> Bool {
        lock.withLock {
            guard values[account] == nil else { return false }
            values[account] = raw; return true
        }
    }
}

private final class CookieOwnerWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private let released = DispatchSemaphore(value: 0)
    private var armed = false
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    func arm() { lock.withLock { armed = true } }
    func beforeWrite() {
        let shouldWait = lock.withLock { () -> Bool in
            guard armed else { return false }
            armed = false; entered = true
            waiter?.resume(); waiter = nil
            return true
        }
        if shouldWait {
            dispatchPrecondition(condition: .notOnQueue(.main))
            released.wait()
        }
    }
    func waitUntilEntered() async {
        await withCheckedContinuation { pending in
            lock.withLock { if entered { pending.resume() } else { waiter = pending } }
        }
    }
    func release() { released.signal() }
}

private actor CookieOwnerDecisionGate {
    private var entered = false
    private var released = false
    private var fail = false
    private var entryFailure: Error?
    private var entryWaiter: CheckedContinuation<Void, Error>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func pauseOnce() async throws {
        guard !entered else { return }
        entered = true
        entryWaiter?.resume(); entryWaiter = nil
        if !released { await withCheckedContinuation { releaseWaiter = $0 } }
        if fail { throw CookieOwnerError(code: "STATE_IO", message: "Injected old Cookie decision failure") }
    }
    func waitUntilEntered() async throws {
        if entered { return }
        if let entryFailure { throw entryFailure }
        try await withCheckedThrowingContinuation { entryWaiter = $0 }
    }
    /// The actual navigation must reach this boundary or publish its original
    /// terminal error. A failed WK/Cookie operation cannot strand this waiter.
    func navigationFinished(error: Error?) {
        guard !entered else { return }
        let failure = error ?? CookieOwnerError(code: "TEST_NAVIGATION_FINISHED",
            message: "The owned navigation finished before its Cookie response commit gate")
        entryFailure = failure
        entryWaiter?.resume(throwing: failure); entryWaiter = nil
    }
    func release(failing: Bool) {
        fail = failing; released = true
        releaseWaiter?.resume(); releaseWaiter = nil
    }
}

@Suite("Single existing Cookie file owner", .serialized)
struct LegadoCookieOwnerTests {
    private struct Fixture {
        let directory: URL
        let file: URL
        let storage: HTTPCookieStorage
        let owner: CookieStore
    }
    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storage = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let file = directory.appendingPathComponent("legado_cookies.json")
        return .init(directory: directory, file: file, storage: storage, owner: CookieStore(fileURL: file, storage: storage))
    }
    private func cleanup(_ f: Fixture) {
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.directory.path)
            try FileManager.default.removeItem(at: f.directory)
        } catch { Issue.record("Owned Cookie fixture cleanup failed: \(error)") }
    }

    @Test("the existing raw file migrates in place without claiming rich Cookie provenance")
    func legacyFileMigratesWithoutInventedProofs() async throws {
        let f = try fixture(); defer { cleanup(f) }
        let old = try JSONEncoder().encode(["legacy-cookie.invalid": "old=owned"])
        try old.write(to: f.file, options: .atomic)
        try await f.owner.prepare()
        #expect(try await f.owner.getOwned(url: "https://legacy-cookie.invalid") == "old=owned")
        #expect(try await f.owner.snapshot().cookies.isEmpty)
        #expect(try Data(contentsOf: f.file) == old)
        try await f.owner.setOwned(url: "https://legacy-cookie.invalid", cookie: "new=value")
        let persisted = try JSONDecoder().decode(CookiePersistenceOwner.Document.self, from: Data(contentsOf: f.file))
        #expect(persisted.version == 2)
        #expect(persisted.legacyHeaders["legacy-cookie.invalid"]?.contains("old=owned") == true)
        #expect(persisted.cookies.first?.provenance == .scriptHeader)
        let fresh = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let reopened = CookieStore(fileURL: f.file, storage: fresh)
        try await reopened.prepare()
        let restored = try await reopened.getOwned(url: "https://legacy-cookie.invalid")
        #expect(restored.contains("old=owned") && restored.contains("new=value"))
    }

    @Test("native browser Cookie arrays keep paths security expiry and unknown host-only provenance after restart")
    func nativeAttributesSurviveActualFileRestart() async throws {
        let f = try fixture(); defer { cleanup(f) }
        let url = try #require(URL(string: "https://cookie-owned.invalid/private/chapter"))
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: [
            "Set-Cookie": "session=owned; Path=/private; Secure; HttpOnly; Max-Age=3600"
        ], for: url)
        let cookie = try #require(cookies.first)
        let observation = try await f.owner.beginWebKitObservation()
        try await f.owner.ingestWebKitSnapshot(cookies, observation: observation)
        let snapshot = try await f.owner.snapshot()
        #expect(snapshot.cookies.count == 1)
        #expect(snapshot.cookies[0].hostOnly == nil && snapshot.cookies[0].originURL == nil)
        #expect(snapshot.cookies[0].provenance == .webKit)
        let fresh = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let reopened = CookieStore(fileURL: f.file, storage: fresh)
        try await reopened.prepare()
        let restored = try #require(fresh.cookies(for: url)?.first)
        #expect(restored.path == cookie.path && restored.domain == cookie.domain)
        #expect(restored.isSecure && restored.isHTTPOnly)
        #expect(restored.expiresDate == cookie.expiresDate)
        let http = try #require(URL(string: "http://cookie-owned.invalid/private/chapter"))
        #expect(fresh.cookies(for: http)?.isEmpty != false)
        let publicURL = try #require(URL(string: "https://cookie-owned.invalid/public"))
        #expect(fresh.cookies(for: publicURL)?.isEmpty != false)
    }

    @Test("corrupt unreadable and unwritable Cookie files remain errors and failed writes preserve native and disk state")
    func failedOwnerIOPreservesOldCookieState() async throws {
        let f = try fixture(); defer { cleanup(f) }
        try Data("[broken".utf8).write(to: f.file)
        do { try await f.owner.prepare(); Issue.record("Corrupt Cookie bytes must not become missing state") }
        catch let error as CookieOwnerError { #expect(error.code == "STATE_IO") }
        #expect(try Data(contentsOf: f.file) == Data("[broken".utf8))
        try FileManager.default.removeItem(at: f.file)
        try FileManager.default.createDirectory(at: f.file, withIntermediateDirectories: false)
        do { try await f.owner.prepare(); Issue.record("An unreadable Cookie path must remain an error") }
        catch let error as CookieOwnerError { #expect(error.code == "STATE_IO") }
        try FileManager.default.removeItem(at: f.file)
        let blocker = f.directory.appendingPathComponent("not-a-directory")
        let blockedBytes = Data("owned parent file".utf8)
        try blockedBytes.write(to: blocker)
        let blockedStorage = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let blockedOwner = CookieStore(fileURL: blocker.appendingPathComponent("cookies.json"), storage: blockedStorage)
        do { try await blockedOwner.prepare(); Issue.record("ENOTDIR must not be treated as an absent Cookie file") }
        catch let error as CookieOwnerError { #expect(error.code == "STATE_IO") }
        let blockedURL = try #require(URL(string: "https://blocked-cookie.invalid"))
        do { _ = try await blockedOwner.requestHeader(url: blockedURL); Issue.record("An invalid owner path cannot authorize an empty request header") }
        catch let error as CookieOwnerError { #expect(error.code == "STATE_IO") }
        #expect(try Data(contentsOf: blocker) == blockedBytes)
        #expect(blockedStorage.cookies?.isEmpty != false)
        #expect(FileManager.default.createFile(atPath: f.file.path, contents: nil))
        let oversized = try FileHandle(forWritingTo: f.file)
        try oversized.truncate(atOffset: 16_777_217)
        try oversized.close()
        do { try await f.owner.prepare(); Issue.record("The owner must reject an oversized file before reading or decoding it") }
        catch let error as CookieOwnerError { #expect(error.code == "STATE_LIMIT") }
        do { _ = try await f.owner.requestHeader(url: blockedURL); Issue.record("An oversized owner file cannot authorize an empty request header") }
        catch let error as CookieOwnerError { #expect(error.code == "STATE_LIMIT") }
        let oversizedAttributes = try FileManager.default.attributesOfItem(atPath: f.file.path)
        #expect((oversizedAttributes[.size] as? NSNumber)?.int64Value == 16_777_217)
        #expect(f.storage.cookies?.isEmpty != false)
        try FileManager.default.removeItem(at: f.file)
        try await f.owner.setOwned(url: "https://failure-cookie.invalid", cookie: "token=old")
        let before = try Data(contentsOf: f.file)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.directory.path)
        do { try await f.owner.setOwned(url: "https://failure-cookie.invalid", cookie: "token=new"); Issue.record("Atomic Cookie replacement must report disk failure") }
        catch let error as CookieOwnerError { #expect(error.code == "STATE_IO") }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.directory.path)
        #expect(try Data(contentsOf: f.file) == before)
        #expect(try await f.owner.getKeyOwned(url: "failure-cookie.invalid", key: "token") == "old")
    }

    @Test("the existing JS Cookie bridge exposes typed durable-write errors to try-catch")
    func scriptWritesExposeTypedOwnerFailure() async throws {
        let f = try fixture(); defer { cleanup(f) }
        try await f.owner.setOwned(url: "https://script-cookie.invalid", cookie: "token=old")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.directory.path)
        let result = await SourceScriptThread.run {
            let engine = JSCoreEngine()
            return engine.evaluate("try { ownedCookie.set('https://script-cookie.invalid', 'token=new'); 'false ack' } catch (error) { error.code }",
                bindings: ["ownedCookie": LegadoCookieBridge(store: f.owner)])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.directory.path)
        #expect(result == "STATE_IO")
        #expect(try await f.owner.getKeyOwned(url: "script-cookie.invalid", key: "token") == "old")
    }

    @Test("fresh WK observations reject late captures and never replay unchanged browser values over newer HTTP state")
    func browserObservationKeepsNewerHTTPState() async throws {
        let f = try fixture(); defer { cleanup(f) }
        let url = try #require(URL(string: "https://observed-cookie.invalid/chapter"))
        func native(_ value: String) throws -> HTTPCookie {
            try #require(HTTPCookie(properties: [.domain: "observed-cookie.invalid", .path: "/", .name: "sid", .value: value]))
        }
        let old = try native("browser-old")
        let first = try await f.owner.beginWebKitObservation()
        try await f.owner.ingestWebKitSnapshot([old], observation: first, requireCurrent: false)
        let late = try await f.owner.beginWebKitObservation()
        try await f.owner.ingest([try native("http-new")], provenance: .httpResponse, originURL: url)
        let accepted = try Data(contentsOf: f.file)
        do {
            try await f.owner.ingestWebKitSnapshot([old], observation: late)
            Issue.record("An older IPC capture must not overwrite accepted HTTP Cookies")
        } catch let error as CookieOwnerError { #expect(error.code == "STATE_CONFLICT") }
        let unchanged = try await f.owner.beginWebKitObservation()
        try await f.owner.ingestWebKitSnapshot([old], observation: unchanged, requireCurrent: false)
        #expect(try Data(contentsOf: f.file) == accepted)
        #expect(try await f.owner.getKeyOwned(url: url.absoluteString, key: "sid") == "http-new")
        let confirming = try await f.owner.beginWebKitObservation()
        do {
            try await f.owner.ingestWebKitSnapshot([old], observation: confirming, confirming: url)
            Issue.record("A user confirmation cannot acknowledge a conflicting stale browser jar")
        } catch let error as CookieOwnerError { #expect(error.code == "STATE_CONFLICT") }
        let changed = try await f.owner.beginWebKitObservation()
        try await f.owner.ingestWebKitSnapshot([try native("browser-new")], observation: changed, confirming: url)
        #expect(try await f.owner.getKeyOwned(url: url.absoluteString, key: "sid") == "browser-new")
        try await f.owner.removeOwned(url: url.absoluteString, key: "sid")
        let afterRemove = try await f.owner.beginWebKitObservation()
        try await f.owner.ingestWebKitSnapshot([try native("browser-new")], observation: afterRemove, requireCurrent: false)
        #expect(try await f.owner.requestHeader(url: url) == nil)
        let fresh = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let reopened = CookieStore(fileURL: f.file, storage: fresh)
        let restartObservation = try await reopened.beginWebKitObservation()
        try await reopened.ingestWebKitSnapshot([try native("browser-new")], observation: restartObservation, requireCurrent: false)
        #expect(try await reopened.requestHeader(url: url) == nil)
    }

    @Test("confirmed WK deletion and known HTTP expiry never revive legacy text at get request or restart")
    func browserRemovalDoesNotReviveLegacyText() async throws {
        for changeBrowserValue in [false, true] {
            let f = try fixture(); defer { cleanup(f) }
            let url = try #require(URL(string: "https://removed-cookie.invalid/chapter"))
            try await f.owner.setOwned(url: url.absoluteString, cookie: "sid=old; unrelated=kept")
            try await f.owner.setOwned(url: "https://other-removed-cookie.invalid", cookie: "sid=other")
            let baseline = try await f.owner.beginWebKitObservation()
            let native = try await f.owner.nativeCookies(url: url)
            try await f.owner.ingestWebKitSnapshot(native, observation: baseline, requireCurrent: false)
            let sid = try #require(native.first { $0.name == "sid" })
            if changeBrowserValue {
                var properties = try #require(sid.properties)
                properties[.value] = "browser-new"
                let changed = try #require(HTTPCookie(properties: properties))
                let change = try await f.owner.beginWebKitObservation()
                try await f.owner.ingestWebKitSnapshot(native.map { $0.name == "sid" ? changed : $0 }, observation: change, confirming: url)
            }
            let deletion = try await f.owner.beginWebKitObservation()
            try await f.owner.ingestWebKitSnapshot(native.filter { $0.name != sid.name }, observation: deletion, confirming: url)
            #expect(try await f.owner.getKeyOwned(url: url.absoluteString, key: "sid").isEmpty)
            #expect(try await f.owner.getKeyOwned(url: url.absoluteString, key: "unrelated") == "kept")
            #expect(try await f.owner.getKeyOwned(url: "https://other-removed-cookie.invalid", key: "sid") == "other")
            let header = try await f.owner.requestHeader(url: url)
            #expect(header?.contains("sid=") != true && header?.contains("unrelated=kept") == true)
            let fresh = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
            let reopened = CookieStore(fileURL: f.file, storage: fresh)
            #expect(try await reopened.getKeyOwned(url: url.absoluteString, key: "sid").isEmpty)
            let restored = try await reopened.requestHeader(url: url)
            #expect(restored?.contains("sid=") != true && restored?.contains("unrelated=kept") == true)
            #expect(try await reopened.getKeyOwned(url: "https://other-removed-cookie.invalid", key: "sid") == "other")
        }
        for expiry in ["Max-Age=0", "Expires=Thu, 01 Jan 1970 00:00:01 GMT"] {
            let f = try fixture(); defer { cleanup(f) }
            // This unknown v1 value has no rich expiry proof and must survive.
            try JSONEncoder().encode(["legacy-unknown.invalid": "sid=unknown"]).write(to: f.file)
            let url = try #require(URL(string: "https://expired-cookie.invalid/chapter"))
            try await f.owner.setOwned(url: url.absoluteString, cookie: "sid=old")
            try await f.owner.setOwned(url: "https://other-expired-cookie.invalid", cookie: "other=kept")
            let expired = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": "sid=http-new; Path=/; " + expiry], for: url)
            let cookie = try #require(expired.first)
            let expiredAt = try #require(cookie.expiresDate)
            #expect(expiredAt < Date())
            try await f.owner.ingest(expired, provenance: .httpResponse, originURL: url)
            let accepted = try Data(contentsOf: f.file)
            #expect(try await f.owner.snapshot().legacyHeaders["expired-cookie.invalid"] == "sid=old")
            #expect(try await f.owner.getOwned(url: url.absoluteString).isEmpty)
            #expect(try await f.owner.getOwned(url: "expired-cookie.invalid").isEmpty)
            #expect(try await f.owner.getKeyOwned(url: url.absoluteString, key: "sid").isEmpty)
            #expect(try await f.owner.requestHeader(url: url) == nil)
            let fresh = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
            let reopened = CookieStore(fileURL: f.file, storage: fresh)
            #expect(try await reopened.getOwned(url: url.absoluteString).isEmpty)
            #expect(try await reopened.getOwned(url: "expired-cookie.invalid").isEmpty)
            #expect(try await reopened.getKeyOwned(url: url.absoluteString, key: "sid").isEmpty)
            #expect(try await reopened.requestHeader(url: url) == nil)
            #expect(try await reopened.getKeyOwned(url: "https://other-expired-cookie.invalid", key: "other") == "kept")
            #expect(try await reopened.getOwned(url: "legacy-unknown.invalid") == "sid=unknown")
            #expect(try Data(contentsOf: f.file) == accepted)
        }
    }

    @Test("the actual existing HTTP pool persists redirect and final Cookies before returning and restores the same file", .timeLimit(.minutes(1)))
    func actualHTTPRedirectAndRestart() async throws {
        let f = try fixture(); defer { cleanup(f) }
        let server = try CookieOwnerHTTPServer()
        let root = try await server.start(); defer { server.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = f.storage
        configuration.httpShouldSetCookies = true
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let fetcher = WebFetcher(session: session, cookies: f.owner, webViewCookies: nil)
        let page = try await fetcher.fetchPage(url: root.appendingPathComponent("start"), method: "GET", body: nil, headers: [:], baseURL: "")
        #expect(page.statusCode == 200)
        #expect(String(data: page.data, encoding: .utf8) == "sid=redirect")
        #expect(server.requests.map(\.path) == ["/start", "/private/final"])
        let snapshot = try await f.owner.snapshot()
        #expect(snapshot.cookies.count == 2)
        #expect(snapshot.cookies.allSatisfy { $0.provenance == .httpResponse && $0.originURL != nil })
        let fresh = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let reopened = CookieStore(fileURL: f.file, storage: fresh)
        let restored = try await reopened.requestHeader(url: root.appendingPathComponent("private/chapter"))
        #expect(restored?.contains("sid=redirect") == true && restored?.contains("final=durable") == true)
        #expect(try await reopened.requestHeader(url: root.appendingPathComponent("public")) == nil)
    }

    @Test("actual HTTP cannot return success or follow a redirect when its Cookie file replacement fails", .timeLimit(.minutes(1)))
    func actualHTTPWriteFailureDoesNotAcknowledge() async throws {
        let f = try fixture(); defer { cleanup(f) }
        let server = try CookieOwnerHTTPServer()
        let root = try await server.start(); defer { server.stop() }
        try await f.owner.setOwned(url: root.absoluteString, cookie: "stable=old")
        let before = try Data(contentsOf: f.file)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.directory.path)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = f.storage
        configuration.httpShouldSetCookies = true
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        do {
            _ = try await f.owner.data(for: URLRequest(url: root.appendingPathComponent("start")), session: session)
            Issue.record("A failed redirect Cookie commit cannot acknowledge or follow")
        } catch let error as CookieOwnerError { #expect(error.code == "STATE_IO") }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.directory.path)
        #expect(server.requests.map(\.path) == ["/start"])
        #expect(try Data(contentsOf: f.file) == before)
        #expect(try await f.owner.getKeyOwned(url: root.absoluteString, key: "stable") == "old")
        #expect(try await f.owner.getKeyOwned(url: root.absoluteString, key: "sid").isEmpty)
    }

    @Test("cancelling an actual HTTP response before atomic Cookie replacement leaves old disk and native values", .timeLimit(.minutes(1)))
    func cancelledHTTPCommitKeepsOldCookieState() async throws {
        let f = try fixture(); defer { cleanup(f) }
        let server = try CookieOwnerHTTPServer()
        let root = try await server.start(); defer { server.stop() }
        let gate = CookieOwnerWriteGate()
        let owner = CookieStore(fileURL: f.file, storage: f.storage, beforeWrite: { gate.beforeWrite() })
        try await owner.setOwned(url: root.absoluteString, cookie: "stable=old")
        let before = try Data(contentsOf: f.file)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = f.storage
        configuration.httpShouldSetCookies = true
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        gate.arm()
        let operation = Task { try await owner.data(for: URLRequest(url: root.appendingPathComponent("private/final")), session: session) }
        await gate.waitUntilEntered()
        operation.cancel()
        gate.release()
        do { _ = try await operation.value; Issue.record("A cancelled Cookie commit must not acknowledge") }
        catch is CancellationError {}
        #expect(try Data(contentsOf: f.file) == before)
        #expect(try await owner.getKeyOwned(url: root.absoluteString, key: "stable") == "old")
        #expect(try await owner.getKeyOwned(url: root.appendingPathComponent("private/final").absoluteString, key: "final").isEmpty)
        #expect(server.requests.count == 1)
    }

    @Test("actual automatic browser and captcha request headers respect Cookie path and Secure while preserving explicit headers")
    func actualBrowserRequestRespectsCookieScope() async throws {
        let f = try fixture(); defer { cleanup(f) }
        let secure = try #require(URL(string: "https://browser-cookie.invalid/private/chapter"))
        let values = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": "sid=private; Secure; HttpOnly; Path=/private"], for: secure)
        try await f.owner.ingest(values, provenance: .httpResponse, originURL: secure)
        let prepared = await SourceScriptThread.run { () -> [URLRequest?] in
            let bridge = LegadoJSBridge()
            let insecurePublic = bridge.sourceBrowserRequest(urlString: "http://browser-cookie.invalid/public", cookieOwner: f.owner)
            let securePublic = bridge.sourceBrowserRequest(urlString: "https://browser-cookie.invalid/public", cookieOwner: f.owner)
            let securePrivate = bridge.sourceBrowserRequest(urlString: secure.absoluteString, cookieOwner: f.owner)
            let explicit = bridge.sourceBrowserRequest(urlString: #"http://browser-cookie.invalid/public,{"headers":{"Cookie":"explicit=authored"}}"#, cookieOwner: f.owner)
            return [insecurePublic, securePublic, securePrivate, explicit]
        }
        #expect(prepared.count == 4 && prepared.allSatisfy { $0 != nil })
        #expect(prepared[0]?.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(prepared[1]?.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(prepared[2]?.value(forHTTPHeaderField: "Cookie") == "sid=private")
        #expect(prepared[3]?.value(forHTTPHeaderField: "Cookie") == "explicit=authored")
        // The explicit JS text API keeps its existing broad related-domain contract.
        #expect(try await f.owner.getKeyOwned(url: "http://browser-cookie.invalid/public", key: "sid") == "private")
    }

    @MainActor
    @Test("a late Cookie response success or failure cannot stop the next real pooled WebView lease", .timeLimit(.minutes(1)))
    func staleWebViewCookieDecisionCannotEndReusedLease() async throws {
        try await cancelledResponsePolicyCompletesOnlyOnce()
        for failOldDecision in [false, true] {
            let f = try fixture(); defer { cleanup(f) }
            let server = try CookieOwnerHTTPServer()
            let root = try await server.start(); defer { server.stop() }
            let gate = CookieOwnerDecisionGate()
            let stageStarted = SourcePerfTrace.now
            let fetcher = WebViewFetcher(cookieOwner: f.owner, poolSize: 1, websiteDataStore: .nonPersistent(),
                afterResponseCookieCommit: { try await gate.pauseOnce() })
            let old = Task { @MainActor in
                do {
                    let body = try await fetcher.fetchHTML(url: root.appendingPathComponent("private/final"), timeout: 20, jsWait: 0)
                    await gate.navigationFinished(error: nil)
                    return body
                } catch {
                    await gate.navigationFinished(error: error)
                    throw error
                }
            }
            SourcePerfTrace.record("cookie-owner.stale-webview", "stage=old-issued", since: stageStarted, thresholdMs: 0)
            do {
                try await gate.waitUntilEntered()
                SourcePerfTrace.record("cookie-owner.stale-webview", "stage=gate-entered", since: stageStarted, thresholdMs: 0)
                old.cancel()
                do { _ = try await old.value; Issue.record("The old navigation was cancelled") }
                catch is CancellationError {}
                catch let error as NSError { #expect(error.code == NSURLErrorCancelled) }
                SourcePerfTrace.record("cookie-owner.stale-webview", "stage=oldcancel-returned", since: stageStarted, thresholdMs: 0)
                let newer = Task { @MainActor in
                    do {
                        let body = try await fetcher.fetchHTML(url: root.appendingPathComponent("held"), timeout: 20, jsWait: 0)
                        server.navigationFinished(beforeRequest: "/held", error: nil)
                        return body
                    } catch {
                        server.navigationFinished(beforeRequest: "/held", error: error)
                        throw error
                    }
                }
                do {
                    try await server.waitForRequest("/held")
                    SourcePerfTrace.record("cookie-owner.stale-webview", "stage=new-held", since: stageStarted, thresholdMs: 0)
                    await gate.release(failing: failOldDecision)
                    server.releaseHeldResponse()
                    let body = try await newer.value
                    #expect(body.contains("held-next-lease"))
                    #expect(server.requests.map(\.path) == ["/private/final", "/held"])
                    #expect(fetcher.performanceSnapshot().peakActiveCount == 1)
                } catch {
                    newer.cancel()
                    await gate.release(failing: false)
                    _ = await newer.result
                    throw error
                }
            } catch {
                old.cancel()
                await gate.release(failing: false)
                _ = await old.result
                throw error
            }
        }
    }

    @MainActor private func cancelledResponsePolicyCompletesOnlyOnce() async throws {
        let wait = WebViewNavigationWait()
        var policies: [WKNavigationResponsePolicy] = []
        do {
            _ = try await wait.value {
                let token = wait.registerResponseDecision { policies.append($0) }
                #expect(token != nil)
                wait.cancel()
                #expect(policies == [.cancel])
                if let token {
                    wait.completeResponseDecision(token, policy: .allow)
                    wait.completeResponseDecision(token, policy: .cancel)
                }
                #expect(policies == [.cancel])
            }
            Issue.record("The cancelled real navigation wait must throw")
        } catch is CancellationError { }
        #expect(policies == [.cancel])
    }

    @Test("native browser preparation carries the typed owner error through its actual async source worker")
    func nativeBrowserPreparationFailureRemainsTyped() async throws {
        let f = try fixture(); defer { cleanup(f) }
        try Data("not-json".utf8).write(to: f.file)
        do {
            _ = try await SourceScriptThread.run { () throws -> URLRequest? in
                try LegadoJSBridge().prepareSourceBrowserRequest(urlString: "https://typed-browser-cookie.invalid/chapter", cookieOwner: f.owner)
            }
            Issue.record("The async native caller cannot receive nil or a bare URL on owner failure")
        } catch let error as CookieOwnerError { #expect(error.code == "STATE_IO") }
        #expect(try Data(contentsOf: f.file) == Data("not-json".utf8))
    }

    @Test("the actual form-login engine removes only header data and retains its owned credentials")
    func formLoginRemovalPreservesCredentials() async throws {
        let name = "CookieFormLogin-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let login = LoginManager(defaults: defaults, credentials: CookieFixtureCredentials())
        let sourceURL = "https://form-login-owned.invalid"
        login.storeLoginInfo(sourceUrl: sourceURL, info: ["password": "owned-only"])
        login.storeLoginHeader(sourceUrl: sourceURL, raw: "owned-header")
        let result = await SourceScriptThread.run {
            var source = BookSource(); source.bookSourceUrl = sourceURL
            let engine = BookSourceFormLoginView.makeLoginEngine(source: source, loginOwner: login)
            return engine.evaluate("source.removeLoginHeader(); source.getLoginInfoMap().password")
        }
        #expect(result == "owned-only")
        #expect(login.getLoginHeader(sourceUrl: sourceURL) == nil)
        #expect(login.getLoginInfo(sourceUrl: sourceURL)?["password"] == "owned-only")
    }
}

/// Owned loopback fixture: the platform URLSession receives actual HTTP redirect
/// and Set-Cookie bytes. It never contacts an external site or reads real state.
private final class CookieOwnerHTTPServer: @unchecked Sendable {
    struct Request: Sendable { let path: String; let cookie: String? }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "CookieOwnerHTTPFixture")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var connections: [NWConnection] = []
    private var received: [Request] = []
    private var requestWaiters: [String: [CheckedContinuation<Void, Error>]] = [:]
    private var requestFailures: [String: Error] = [:]
    private var heldConnection: NWConnection?
    var requests: [Request] { lock.withLock { received } }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = self.listener.port, let url = URL(string: "http://127.0.0.1:\(port.rawValue)") else { return }
                    self.finishStart(.success(url))
                case .failed(let error): self.finishStart(.failure(error))
                case .cancelled: self.finishStart(.failure(CancellationError()))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.lock.withLock { self.connections.append(connection) }
                connection.start(queue: self.queue)
                self.receive(connection, data: Data())
            }
            listener.start(queue: queue)
        }
    }
    func stop() {
        listener.cancel()
        lock.withLock { connections }.forEach { $0.cancel() }
        let pending = lock.withLock {
            let value = requestWaiters.values.flatMap { $0 }
            requestWaiters.removeAll()
            return value
        }
        pending.forEach { $0.resume(throwing: CancellationError()) }
    }
    func waitForRequest(_ path: String) async throws {
        try await withCheckedThrowingContinuation { pending in
            lock.withLock {
                if received.contains(where: { $0.path == path }) { pending.resume() }
                else if let failure = requestFailures[path] { pending.resume(throwing: failure) }
                else { requestWaiters[path, default: []].append(pending) }
            }
        }
    }
    /// Race the real request callback against the real navigation's terminal
    /// result, including failures before WebKit has issued any HTTP request.
    func navigationFinished(beforeRequest path: String, error: Error?) {
        let failure = error ?? CookieOwnerError(code: "TEST_NAVIGATION_FINISHED",
            message: "The owned navigation finished before its expected loopback request")
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            guard !received.contains(where: { $0.path == path }) else { return [] }
            requestFailures[path] = failure
            return requestWaiters.removeValue(forKey: path) ?? []
        }
        pending.forEach { $0.resume(throwing: failure) }
    }
    func releaseHeldResponse() {
        let connection = lock.withLock { let value = heldConnection; heldConnection = nil; return value }
        guard let connection else { Issue.record("The owned next-lease request was not held"); return }
        let body = "<html><body>held-next-lease</body></html>"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() })
    }
    private func finishStart(_ result: Result<URL, Error>) {
        let pending = lock.withLock { let value = continuation; continuation = nil; return value }
        pending?.resume(with: result)
    }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, done, error in
            guard let self else { return }
            var data = data
            if let chunk { data.append(chunk) }
            guard data.count <= 65536 else { connection.cancel(); return }
            guard let text = String(data: data, encoding: .utf8), text.contains("\r\n\r\n") else {
                if error == nil && !done { self.receive(connection, data: data) } else { connection.cancel() }
                return
            }
            let lines = text.components(separatedBy: "\r\n")
            let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let cookie = lines.first { $0.lowercased().hasPrefix("cookie:") }.map { String($0.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            let waiting = self.lock.withLock { () -> [CheckedContinuation<Void, Error>] in
                self.received.append(Request(path: path, cookie: cookie))
                if path == "/held" { self.heldConnection = connection }
                return self.requestWaiters.removeValue(forKey: path) ?? []
            }
            waiting.forEach { $0.resume() }
            if path == "/held" { return }
            let status: String, fields: String, body: String
            if path == "/start" {
                status = "302 Found"; fields = "Location: /private/final\r\nSet-Cookie: sid=redirect; Path=/private; HttpOnly\r\n"; body = "redirect"
            } else {
                status = "200 OK"; fields = "Set-Cookie: final=durable; Path=/private; HttpOnly\r\n"; body = cookie ?? "no-cookie"
            }
            let response = "HTTP/1.1 \(status)\r\n\(fields)Content-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
