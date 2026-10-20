import Foundation
import CoreGraphics
import Testing
@testable import yuedu_app

@Suite("WebFetcher persisted cookies", .serialized)
struct WebFetcherPersistedCookieTests {

    @Test("native request restores a cookie from CookieStore persistence")
    func nativeRequestRestoresPersistedCookie() async throws {
        PersistedCookieURLProtocol.reset()
        let host = "persisted-cookie-\(UUID().uuidString).example.com"
        let url = try #require(URL(string: "https://\(host)/chapter"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("Owned persisted Cookie fixture cleanup failed: \(error)") }
        }
        let file = directory.appendingPathComponent("legado_cookies.json")
        let initialStorage = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let initial = CookieStore(fileURL: file, storage: initialStorage)
        try await initial.setOwned(url: url.absoluteString, cookie: "admin_session=session-token")

        // A different owner instance/native jar reads the actual accepted file.
        let storage = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let reopened = CookieStore(fileURL: file, storage: storage)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = storage
        configuration.protocolClasses = [PersistedCookieURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let fetcher = WebFetcher(session: session, cookies: reopened, webViewCookies: nil)

        _ = try await fetcher.fetchHTML(
            url: url,
            method: "GET",
            body: nil,
            headers: [:],
            baseURL: "https://\(host)"
        )

        #expect(PersistedCookieURLProtocol.cookieHeader?.contains("admin_session=session-token") == true)
    }
}

private final class PersistedCookieURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedCookieHeader: String?

    static var cookieHeader: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedCookieHeader
    }

    static func reset() {
        lock.lock()
        storedCookieHeader = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.storedCookieHeader = request.value(forHTTPHeaderField: "Cookie")
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("<html></html>".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
