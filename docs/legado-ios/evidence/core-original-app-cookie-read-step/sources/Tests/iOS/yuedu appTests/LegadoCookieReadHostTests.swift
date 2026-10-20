import Foundation
import LegadoRuntime
import Testing
@testable import yuedu_app

private struct CookieReadNoOtherOwner: LegadoOwnedStateBacking {
    func read(sourceURL: String, domain: LegadoOwnedStateDomain, fields: Set<String>) throws -> LegadoOwnedStateSnapshot {
        throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY", message: "Fixture did not grant another state owner")
    }
    func commit(sourceURL: String, domain: LegadoOwnedStateDomain, expected: LegadoOwnedStateSnapshot, changes: [String: Data?]) throws -> Bool {
        throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY", message: "Fixture did not grant another state owner")
    }
}

@Suite("Actual Cookie owner read callback", .serialized)
struct LegadoCookieReadHostTests {
    private struct Reply: Decodable { let cookie: String }
    private func request(owner: String, purpose: String, url: String, domain: String, task: String = UUID().uuidString,
                         extra: [String: Any] = [:]) throws -> LegadoHostRequest {
        var input: [String: Any] = ["owner": owner, "purpose": purpose, "url": url, "domain": domain]
        input.merge(extra) { _, latest in latest }
        return .init(taskID: task, operation: "cookie.owner.read", requestJSON: String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self))
    }

    @Test("unknown WK host-only metadata does not block actual Cookie text or RFC-aware header reads")
    func actualUnknownWKValuesReachReadCallbackWithoutJarReconstruction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record("Cookie read fixture cleanup failed: \(error)") } }
        let file = directory.appendingPathComponent("legado_cookies.json")
        try JSONEncoder().encode(CookiePersistenceOwner.Document(legacyHeaders: ["javascript:owned": "raw=kept"]))
            .write(to: file, options: .atomic)
        let storage = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let cookies = CookieStore(fileURL: file, storage: storage)
        let privateURL = try #require(URL(string: "https://reader.example.co.uk/private/chapter"))
        let native = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": "sid=owned; Path=/private; Secure; HttpOnly"], for: privateURL)
        let observation = try await cookies.beginWebKitObservation()
        try await cookies.ingestWebKitSnapshot(native, observation: observation)
        let before = try Data(contentsOf: file)
        let host = LegadoPersistentStateHost(backing: CookieReadNoOtherOwner(), cookieOwner: cookies)
        let owner = try await host.bind(sourceURL: "https://reader.example.co.uk", sourceRevision: "owned-r1")
        let text = try await host.dispatch(request(owner: owner, purpose: "getCookie", url: privateURL.absoluteString, domain: "example.co.uk"))
        #expect(try JSONDecoder().decode(Reply.self, from: Data(text.utf8)).cookie == "sid=owned")
        let hidden = try await host.dispatch(request(owner: owner, purpose: "requestHeader", url: "http://reader.example.co.uk/public", domain: "example.co.uk"))
        #expect(try JSONDecoder().decode(Reply.self, from: Data(hidden.utf8)).cookie.isEmpty)
        let visible = try await host.dispatch(request(owner: owner, purpose: "requestHeader", url: privateURL.absoluteString, domain: "example.co.uk"))
        #expect(try JSONDecoder().decode(Reply.self, from: Data(visible.utf8)).cookie == "sid=owned")
        let rawKey = try await host.dispatch(request(owner: owner, purpose: "getCookie", url: "javascript:owned", domain: "javascript:owned"))
        #expect(try JSONDecoder().decode(Reply.self, from: Data(rawKey.utf8)).cookie == "raw=kept")
        #expect(try await cookies.snapshot().cookies.first?.hostOnly == nil)
        #expect(try Data(contentsOf: file) == before)
    }

    @Test("actual callback preserves typed IO owner revocation cancellation malformed inputs and absolute deadlines")
    func actualReadCallbackKeepsOwnerAndFailureBoundaries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record("Cookie read fixture cleanup failed: \(error)") } }
        let file = directory.appendingPathComponent("legado_cookies.json")
        try Data("broken-cookie-file".utf8).write(to: file)
        let storage = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let host = LegadoPersistentStateHost(backing: CookieReadNoOtherOwner(), cookieOwner: CookieStore(fileURL: file, storage: storage))
        let owner = try await host.bind(sourceURL: "https://owned-cookie.invalid", sourceRevision: "r1")
        let url = "https://owned-cookie.invalid/chapter"
        func expectCode(_ expected: String, _ input: LegadoHostRequest) async throws {
            do { _ = try await host.dispatch(input); Issue.record("Expected Cookie callback error \(expected)") }
            catch let error as LegadoRuntimeError { #expect(error.code == expected) }
        }
        try await expectCode("STATE_IO", request(owner: owner, purpose: "requestHeader", url: url, domain: "owned-cookie.invalid"))
        try await expectCode("INVALID_STATE_REQUEST", .init(taskID: "bad-json", operation: "cookie.owner.read", requestJSON: "{"))
        try await expectCode("INVALID_STATE_REQUEST", request(owner: owner, purpose: "requestHeader", url: "file:///owned", domain: "owned-cookie.invalid"))
        try await expectCode("UNSUPPORTED_CAPABILITY", request(owner: owner, purpose: "writeCookie", url: url, domain: "owned-cookie.invalid"))
        try await expectCode("INVALID_STATE_REQUEST", request(owner: owner, purpose: "getCookie", url: url, domain: "owned-cookie.invalid", extra: ["deadlineEpochMs": true]))
        try await expectCode("STATE_TIMEOUT", request(owner: owner, purpose: "getCookie", url: url, domain: "owned-cookie.invalid", extra: ["deadlineEpochMs": 0]))
        await host.cancel(taskID: "owned-cancel")
        do { _ = try await host.dispatch(request(owner: owner, purpose: "getCookie", url: url, domain: "owned-cookie.invalid", task: "owned-cancel")); Issue.record("Cancelled owner read must not run") }
        catch is CancellationError {}
        _ = try await host.bind(sourceURL: "https://owned-cookie.invalid", sourceRevision: "r2")
        try await expectCode("INVALID_STATE_OWNER", request(owner: owner, purpose: "getCookie", url: url, domain: "owned-cookie.invalid"))
        #expect(try Data(contentsOf: file) == Data("broken-cookie-file".utf8))
    }
}
