import Foundation
import Testing
@testable import yuedu_app

@Suite("Modern chapter cache integrity scenarios", .serialized, .timeLimit(.minutes(1)))
struct ModernChapterCacheScenarioTests {
    @Test("a lightweight hit does not certify the body or rewrite damaged bytes", arguments: [0, 1, 2])
    nonisolated func lightweightHitStillRequiresBodyValidation(damageKind: Int) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModernChapterCacheScenario-\(UUID().uuidString)")
        defer { removeOwnedDirectory(root) }
        let repository = ChapterCacheRepository(rootDirectory: root)
        let bookID = UUID()
        let snapshot = try seedAndDamage(repository: repository, root: root, bookID: bookID,
                                         sourceURL: "https://cache-scenario.example/0", damageKind: damageKind)

        // Reopening must not turn damaged modern bytes into a newly blessed legacy entry.
        for candidate in [repository, ChapterCacheRepository(rootDirectory: root)] {
            #expect(candidate.isChapterCached(bookId: bookID, chapterIndex: 0))
            #expect(candidate.loadChapterPackageSync(bookId: bookID, chapterIndex: 0,
                expectedSourceURL: "https://cache-scenario.example/0", expectedTOCTitle: "Chapter 1") == nil)
            try snapshot.expectUnchanged()
        }
    }

    @Test("prefetch skips the lightweight hit but entering the chapter validates and recovers it")
    @MainActor
    func enteringDamagedChapterFetchesOnceAndThenReusesVerifiedCache() async throws {
        let host = "cache-scenario-\(UUID().uuidString.lowercased()).example"
        var source = BookSource(bookSourceUrl: "https://\(host)", bookSourceName: "Owned cache scenario")
        source.ruleContent.content = "#content@html"
        let ownedSource = source
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CacheRecoveryURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let fetcher = BookSourceFetcher(webFetcher: WebFetcher(session: session))
        let manager = ChapterFetchManager(bookSourceFetcher: fetcher, webViewFetcher: WebViewFetcher.shared,
                                          sourceResolver: { _ in ownedSource })
        var book = ReadingBook(title: "Owned cache scenario", author: "Fixture", source: source.bookSourceUrl,
                               contentFilename: "")
        book.isOnline = true
        book.bookSourceId = source.id
        book.onlineChapters = [OnlineChapterRef(index: 0, title: "Chapter 1", url: source.bookSourceUrl + "/0")]
        let bookID = book.id
        let sourceURL = source.bookSourceUrl + "/0"
        let root = StorageLocations.onlineCache
        let directory = root.appendingPathComponent(bookID.uuidString)
        defer { removeOwnedDirectory(directory) }
        CacheRecoveryURLProtocol.reset()
        let snapshot = try await Task.detached {
            try seedAndDamage(repository: ChapterCacheRepository(), root: root, bookID: bookID,
                              sourceURL: sourceURL, damageKind: 0)
        }.value

        #expect(await manager.chapterState(bookId: bookID, chapterIndex: 0) == .cached)
        await manager.prefetchChapters(book: book, indices: [0], priority: .prefetch, store: nil)
        // The method returns after checking the state, with no fetch Task created for a hit.
        #expect(CacheRecoveryURLProtocol.requestCount == 0)
        #expect(await manager.cachedChapterPackage(book: book, chapterIndex: 0) == nil)
        try await Task.detached { try snapshot.expectUnchanged() }.value

        let recovered = try await manager.fetchChapter(book: book, chapterIndex: 0, priority: .jump, store: nil)
        #expect(recovered.state == .cached)
        #expect(recovered.content.contains(CacheRecoveryURLProtocol.body))
        #expect(!recovered.content.contains("damaged"))
        #expect(CacheRecoveryURLProtocol.requestCount == 1)
        #expect(await manager.isChapterCached(book: book, chapterIndex: 0))
        let reopened = try await ChapterFetchManager(bookSourceFetcher: fetcher,
            webViewFetcher: WebViewFetcher.shared, sourceResolver: { _ in ownedSource })
            .fetchChapter(book: book, chapterIndex: 0, priority: .immediate, store: nil)
        #expect(reopened.content == recovered.content)
        #expect(reopened.contentChecksum == recovered.contentChecksum)
        #expect(CacheRecoveryURLProtocol.requestCount == 1)
        print("READER_CACHE_SCENARIO lightweight=cached validated=missing prefetchRequests=0 entryRequests=1 reopenedRequests=0")
    }
}

private struct DamagedCacheSnapshot: Sendable {
    let directory: URL
    let body: Data
    let metadata: Data
    let artifact: Data

    nonisolated func expectUnchanged() throws {
        #expect(try Data(contentsOf: directory.appendingPathComponent("0.txt")) == body)
        #expect(try Data(contentsOf: directory.appendingPathComponent("0.meta.json")) == metadata)
        #expect(try Data(contentsOf: directory.appendingPathComponent("0.package.json")) == artifact)
    }
}

private func seedAndDamage(repository: ChapterCacheRepository, root: URL, bookID: UUID,
                                       sourceURL: String, damageKind: Int) throws -> DamagedCacheSnapshot {
    let package = ChapterPackage(bookId: bookID, chapterIndex: 0, sourceURL: sourceURL,
        tocTitle: "Chapter 1", canonicalTitle: "Chapter 1", content: "Complete committed fixture prose.",
        contentChecksum: "", rawHTMLFilename: nil, normalizedHTMLFilename: nil,
        savedAt: Date(timeIntervalSince1970: 1), state: .cached, failureReason: nil)
    try repository.saveChapterPackageToCache(package, rawHTML: nil, normalizedHTML: nil)
    let directory = root.appendingPathComponent(bookID.uuidString)
    let metadata = try Data(contentsOf: directory.appendingPathComponent("0.meta.json"))
    let artifact = try Data(contentsOf: directory.appendingPathComponent("0.package.json"))
    let body: Data
    switch damageKind {
    case 0: body = Data("damaged replacement fixture prose".utf8)
    case 1: body = Data()
    default: body = Data([0xff, 0xfe, 0x80])
    }
    // Only the body is tampered with; package and metadata retain their original checksum.
    try body.write(to: directory.appendingPathComponent("0.txt"), options: .atomic)
    return DamagedCacheSnapshot(directory: directory, body: body, metadata: metadata, artifact: artifact)
}

private func removeOwnedDirectory(_ directory: URL) {
    do { try FileManager.default.removeItem(at: directory) }
    catch { Issue.record("Could not remove owned cache fixture: \(error)") }
}

private final class CacheRecoveryURLProtocol: URLProtocol, @unchecked Sendable {
    static let body = "Recovered chapter prose from the owned fixture response."
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    static func reset() {
        lock.lock()
        count = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, url.host?.hasPrefix("cache-scenario-") == true,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "text/html; charset=utf-8"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        Self.lock.lock()
        Self.count += 1
        Self.lock.unlock()
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("<html><body><div id='content'><p>\(Self.body)</p></div></body></html>".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
