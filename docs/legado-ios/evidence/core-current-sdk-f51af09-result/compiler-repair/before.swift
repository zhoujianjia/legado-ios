import Foundation
import LegadoRuntime
import Testing
import WebKit
@testable import yuedu_app

private struct BrowserNoOtherOwner: LegadoOwnedStateBacking {
    func read(sourceURL: String, domain: LegadoOwnedStateDomain, fields: Set<String>) throws -> LegadoOwnedStateSnapshot {
        throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY", message: "Only this fixture Cookie owner was granted")
    }
    func commit(sourceURL: String, domain: LegadoOwnedStateDomain, expected: LegadoOwnedStateSnapshot, changes: [String: Data?]) throws -> Bool {
        throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY", message: "Only this fixture Cookie owner was granted")
    }
}

private final class BrowserOwnerWriteGate: @unchecked Sendable {
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
        if action.1 { throw CookieOwnerError(code: "STATE_IO", message: "Owned browser snapshot write failed") }
        released.wait()
    }
    func waitUntilEntered() async {
        await withCheckedContinuation { pending in
            lock.withLock { if entered { pending.resume() } else { waiter = pending } }
        }
    }
    func release() { released.signal() }
}

@Suite("Original Cookie SQL and actual WK store callback", .serialized)
struct LegadoCookieBrowserHostTests {
    private struct Fixture: @unchecked Sendable {
        let directory: URL, file: URL
        let cookies: CookieStore, host: LegadoPersistentStateHost, owner: String
        let website: WKWebsiteDataStore
    }
    private func fixture(gate: BrowserOwnerWriteGate? = nil) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("legado_cookies.json")
        let native = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let cookies = CookieStore(fileURL: file, storage: native, beforeWrite: { try gate?.beforeWrite() })
        let website = await MainActor.run { WKWebsiteDataStore.nonPersistent() }
        let host = LegadoPersistentStateHost(backing: BrowserNoOtherOwner(), cookieOwner: cookies,
            originalWebCookieStore: { website.httpCookieStore })
        let owner = try await host.bind(sourceURL: "https://reader.example.co.uk", sourceRevision: "browser-r1")
        return .init(directory: directory, file: file, cookies: cookies, host: host, owner: owner, website: website)
    }
    private func cleanup(_ f: Fixture) {
        do { try FileManager.default.removeItem(at: f.directory) }
        catch { Issue.record("Browser owner fixture cleanup failed: \(error)") }
    }
    private func request(owner: String, action: String, domain: String = "example.co.uk", task: String = UUID().uuidString,
                         extra: [String: Any] = [:]) throws -> LegadoHostRequest {
        var input: [String: Any] = ["owner": owner, "action": action, "domain": domain, "url": "https://reader.example.co.uk/chapter"]
        input.merge(extra) { _, new in new }
        return .init(taskID: task, operation: "cookie.owner.text", requestJSON: String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self))
    }
    @MainActor private func seed(_ f: Fixture, _ header: String, url: String = "https://reader.example.co.uk/") async throws {
        let target = try #require(URL(string: url))
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": header], for: target)
        #expect(cookies.count == 1)
        for cookie in cookies {
            await withCheckedContinuation { (pending: CheckedContinuation<Void, Never>) in
                f.website.httpCookieStore.setCookie(cookie) { pending.resume() }
            }
        }
    }
    @MainActor private func browserCookies(_ f: Fixture) async -> [HTTPCookie] {
        await withCheckedContinuation { pending in f.website.httpCookieStore.getAllCookies { pending.resume(returning: $0) } }
    }

    @Test("clear uses literal pipe SQL only and the same native owner retains original process CacheManager text")
    func clearKeepsCacheAcrossNewBindingsButFreshOwnerReadsOnlyRemainingRows() async throws {
        let f = try await fixture(); defer { cleanup(f) }
        for (domain, raw) in [("http|owned", "old=cached"), ("ordinary", "kept=yes"), ("fullwidth｜pipe", "wide=kept")] {
            _ = try await f.host.dispatch(request(owner: f.owner, action: "set", domain: domain, extra: ["cookie": raw]))
        }
        try await seed(f, "browser=kept; Path=/")
        let browserBefore = await browserCookies(f)
        _ = try await f.host.dispatch(request(owner: f.owner, action: "clear"))
        #expect(try await f.cookies.originalRawText(domain: "http|owned").isEmpty)
        #expect(try await f.cookies.originalText(domain: "http|owned") == "old=cached")
        #expect(try await f.cookies.originalRawText(domain: "ordinary") == "kept=yes")
        #expect(try await f.cookies.originalRawText(domain: "fullwidth｜pipe") == "wide=kept")
        // New RuntimeSession/Host grants share this actual App Cookie owner;
        // neither implies a process/cache restart.
        let next = LegadoPersistentStateHost(backing: BrowserNoOtherOwner(), cookieOwner: f.cookies)
        let owner = try await next.bind(sourceURL: "https://reader.example.co.uk", sourceRevision: "browser-r1")
        let reply = try await next.dispatch(request(owner: owner, action: "get", domain: "http|owned"))
        struct Reply: Decodable { let cookie: String }
        #expect(try JSONDecoder().decode(Reply.self, from: Data(reply.utf8)).cookie == "old=cached")
        let storage = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let freshOwner = CookieStore(fileURL: f.file, storage: storage)
        #expect(try await freshOwner.originalText(domain: "http|owned").isEmpty)
        #expect(try await freshOwner.originalText(domain: "ordinary") == "kept=yes")
        let browserAfter = await browserCookies(f)
        #expect(browserBefore.map { $0.name + "=" + $0.value } == browserAfter.map { $0.name + "=" + $0.value })
    }

    @Test("setWebCookie removes global WK session cookies then applies pieces without changing original DB raw text")
    func setWebCookieUsesActualExistingWKStoreAndLeavesRawDBUntouched() async throws {
        let f = try await fixture(); defer { cleanup(f) }
        _ = try await f.host.dispatch(request(owner: f.owner, action: "set", extra: ["cookie": "db=original"]))
        try await seed(f, "old=global-session; Path=/", url: "https://unrelated.invalid/")
        try await seed(f, "persistent=kept; Path=/; Expires=Fri, 01 Jan 2099 00:00:00 GMT", url: "https://unrelated.invalid/")
        let input = try request(owner: f.owner, action: "webSet", extra: ["baseUrl": "https://reader.example.co.uk", "pieces": ["first=one", "second=two"]])
        _ = try await f.host.dispatch(input)
        let actual = await browserCookies(f)
        #expect(!actual.contains { $0.name == "old" })
        #expect(actual.contains { $0.name == "persistent" && $0.value == "kept" })
        #expect(actual.contains { $0.name == "first" && $0.value == "one" && $0.path == "/" })
        #expect(actual.contains { $0.name == "second" && $0.value == "two" && $0.path == "/" })
        #expect(try await f.cookies.originalRawText(domain: "example.co.uk") == "db=original")
        #expect(try await f.cookies.originalText(domain: "example.co.uk") == "db=original")
        let snapshot = try await f.cookies.snapshot()
        #expect(snapshot.cookies.filter { $0.provenance == .webKit }.allSatisfy { $0.hostOnly == nil && $0.originURL == nil })
    }

    @Test("remove expires root names only at the original host and subdomain targets after DB/cache removal")
    func removeKeepsOtherPathsAndUnrelatedBrowserDomains() async throws {
        let f = try await fixture(); defer { cleanup(f) }
        _ = try await f.host.dispatch(request(owner: f.owner, action: "set", extra: ["cookie": "db=removed"]))
        try await seed(f, "same=root; Path=/")
        try await seed(f, "same=private; Path=/private; Secure; HttpOnly")
        try await seed(f, "foreign=kept; Path=/", url: "https://unrelated.invalid/")
        _ = try await f.host.dispatch(request(owner: f.owner, action: "remove"))
        _ = try await f.host.dispatch(request(owner: f.owner, action: "webRemove", extra: ["domains": ["reader.example.co.uk", "example.co.uk"]]))
        let actual = await browserCookies(f)
        #expect(!actual.contains { $0.name == "same" && $0.domain == "reader.example.co.uk" && $0.path == "/" })
        #expect(actual.contains { $0.name == "same" && $0.value == "private" && $0.path == "/private" && $0.isSecure && $0.isHTTPOnly })
        #expect(actual.contains { $0.name == "foreign" && $0.value == "kept" })
        #expect(try await f.cookies.originalRawText(domain: "example.co.uk").isEmpty)
        #expect(try await f.cookies.originalText(domain: "example.co.uk").isEmpty)
    }

    @Test("real issued WK effects survive failed persistence cancellation and source revocation without late owner publication")
    func issuedBrowserEffectsCannotBeRolledBackOrPublishedThroughARevokedGrant() async throws {
        for mode in ["failure", "cancel", "revoke"] {
            let gate = BrowserOwnerWriteGate(), f = try await fixture(gate: gate)
            defer { cleanup(f) }
            _ = try await f.host.dispatch(request(owner: f.owner, action: "set", extra: ["cookie": "db=old"]))
            let before = try Data(contentsOf: f.file), taskID = UUID().uuidString
            gate.arm(failing: mode == "failure")
            let input = try request(owner: f.owner, action: "webSet", task: taskID,
                extra: ["baseUrl": "https://reader.example.co.uk", "pieces": ["issued=real"]])
            let pending = Task { try await f.host.dispatch(input) }
            await gate.waitUntilEntered()
            if mode == "cancel" { await f.host.cancel(taskID: taskID) }
            if mode == "revoke" { await f.host.revoke(owner: f.owner) }
            gate.release()
            do { _ = try await pending.value; Issue.record("The old Cookie grant must not acknowledge this snapshot") }
            catch let error as LegadoRuntimeError {
                #expect(error.code == (mode == "failure" ? "STATE_IO" : "CANCELLED"))
                #expect(error.completedEffects?.contains("webKitCookieMutationIssued") == true)
            }
            #expect(try Data(contentsOf: f.file) == before)
            #expect(try await f.cookies.originalText(domain: "example.co.uk") == "db=old")
            let actual = await browserCookies(f)
            #expect(actual.contains { $0.name == "issued" && $0.value == "real" })
            let nextOwner = try await f.host.bind(sourceURL: "https://reader.example.co.uk", sourceRevision: "browser-r2")
            _ = try await f.host.dispatch(request(owner: nextOwner, action: "get"))
            #expect(try Data(contentsOf: f.file) == before)
        }
    }

    @Test("clear write failure preserves previous file and cache and rejected browser grants issue no WK write")
    func clearFailureAndRejectedGrantRetainTheOwnedState() async throws {
        let gate = BrowserOwnerWriteGate(), f = try await fixture(gate: gate); defer { cleanup(f) }
        _ = try await f.host.dispatch(request(owner: f.owner, action: "set", domain: "http|owned", extra: ["cookie": "old=kept"]))
        let before = try Data(contentsOf: f.file)
        gate.arm(failing: true)
        do { _ = try await f.host.dispatch(request(owner: f.owner, action: "clear")); Issue.record("Failed clear must throw") }
        catch let error as LegadoRuntimeError { #expect(error.code == "STATE_IO") }
        #expect(try Data(contentsOf: f.file) == before)
        #expect(try await f.cookies.originalRawText(domain: "http|owned") == "old=kept")
        #expect(try await f.cookies.originalText(domain: "http|owned") == "old=kept")
        await f.host.revoke(owner: f.owner)
        do {
            _ = try await f.host.dispatch(request(owner: f.owner, action: "webSet", extra: ["baseUrl": "https://reader.example.co.uk", "pieces": ["bad=never"]]))
            Issue.record("A revoked browser grant must throw")
        } catch let error as LegadoRuntimeError { #expect(error.code == "INVALID_STATE_OWNER") }
        #expect(await browserCookies(f).isEmpty)
        #expect(try Data(contentsOf: f.file) == before)
    }
}
