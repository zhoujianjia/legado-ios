import Foundation
import Testing
import WebKit
@testable import yuedu_app

private final class LateBrowserFailureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var first: LateBrowserFailureProtocol?
    nonisolated(unsafe) private static var entered: AsyncStream<Bool>.Continuation?
    nonisolated(unsafe) private static var released = false
    static func prepare() -> AsyncStream<Bool> {
        let pair = AsyncStream<Bool>.makeStream()
        lock.lock(); first = nil; entered = pair.continuation; released = false; lock.unlock()
        return pair.stream
    }
    static func fail() {
        lock.lock(); released = true; let request = first; first = nil; let event = entered; entered = nil; lock.unlock()
        if let request { request.client?.urlProtocol(request, didFailWithError: URLError(.cannotConnectToHost)) }
        event?.finish()
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.port == 0 }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        if !Self.released, Self.first == nil {
            Self.first = self; let event = Self.entered; Self.lock.unlock()
            event?.yield(true)
        } else {
            Self.lock.unlock()
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        }
    }
    override func stopLoading() { }
}

@Suite("Late browser chapter failures", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct ChapterFetchLateFailureTests {
    @Test("a real late browser/import request error cannot remove a newer valid body")
    func lateBrowserFailureDoesNotDeleteNewSuccessfulPackage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cookies = CookieStore(fileURL: root.appendingPathComponent("cookies.json"),
            storage: .sharedCookieStorage(forGroupContainerIdentifier: UUID().uuidString))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LateBrowserFailureProtocol.self]
        let session = URLSession(configuration: config)
        let fetcher = BookSourceFetcher(webFetcher: WebFetcher(session: session, cookies: cookies, webViewCookies: nil))
        // Native WK fallback uses the same existing fetcher implementation and an owned
        // nonpersistent fixture store. Port zero fails locally, without external traffic.
        let web = WebViewFetcher(cookieOwner: cookies, poolSize: 1, websiteDataStore: .nonPersistent())
        let manager = ChapterFetchManager(bookSourceFetcher: fetcher, webViewFetcher: web)
        var book = ReadingBook(title: "Owned browser chapter", author: "Fixture", source: "http://127.0.0.1:0/book", contentFilename: "")
        book.isOnline = true
        let ref = OnlineChapterRef(index: 0, title: "Chapter one", url: "http://127.0.0.1:0/late")
        book.onlineChapters = [ref]
        let directory = StorageLocations.onlineCache.appendingPathComponent(book.id.uuidString)
        defer {
            LateBrowserFailureProtocol.fail(); session.invalidateAndCancel()
            do {
                if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
                try FileManager.default.removeItem(at: root)
            } catch { Issue.record("Owned late-browser cleanup failed: \(error)") }
        }
        let entered = LateBrowserFailureProtocol.prepare()
        let old = Task { try await manager.fetchChapter(book: book, chapterIndex: 0, priority: .immediate, store: nil) }
        var events = entered.makeAsyncIterator()
        #expect(await events.next() == true)
        _ = try await fetcher.saveToCache(content: "New successfully saved chapter prose from another current writer.",
            bookId: book.id, chapterIndex: 0, sourceURL: ref.url, tocTitle: ref.title, storeNormalizedHTML: false)
        LateBrowserFailureProtocol.fail()
        do { _ = try await old.value; Issue.record("The old browser request must actually fail") }
        catch { /* A real primary request and WK navigation both failed locally. */ }
        await BookStore.queuedWritesLanded()
        let actual = ChapterCacheRepository().loadChapterPackageSync(bookId: book.id, chapterIndex: 0,
            expectedSourceURL: ref.url, expectedTOCTitle: ref.title)
        #expect(actual?.content == "New successfully saved chapter prose from another current writer.")
    }
}
