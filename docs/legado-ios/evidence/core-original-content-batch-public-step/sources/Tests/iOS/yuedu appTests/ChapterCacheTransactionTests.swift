import Foundation
import Testing
@testable import yuedu_app

/// Actual owned files and the production writer, with revocation between real renames.
@Suite("Chapter cache owner transactions", .serialized)
struct ChapterCacheTransactionTests {
    private func fixture() throws -> (URL, ChapterCacheRepository, UUID) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, ChapterCacheRepository(rootDirectory: root), UUID())
    }
    private func package(_ book: UUID, _ body: String, url: String = "https://owned.invalid/one") -> ChapterPackage {
        .init(bookId: book, chapterIndex: 0, sourceURL: url, tocTitle: "Chapter one", canonicalTitle: nil,
              content: body, contentChecksum: "", rawHTMLFilename: nil, normalizedHTMLFilename: nil,
              savedAt: Date(timeIntervalSince1970: 1), state: .cached, failureReason: nil)
    }
    private func bytes(_ root: URL, _ book: UUID) throws -> [String: Data] {
        let dir = root.appendingPathComponent(book.uuidString)
        return try Dictionary(uniqueKeysWithValues: ["txt", "meta.json", "raw.html", "normalized.xhtml", "package.json"].compactMap { suffix in
            let file = dir.appendingPathComponent("0." + suffix)
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return (suffix, try Data(contentsOf: file))
        })
    }
    private func cleanup(_ root: URL) {
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Owned cache cleanup failed: \(error)") }
    }
    @Test("revocation after real first-file install restores every old artifact")
    func cancellationBetweenRenamesRestoresCompleteOldPackage() async throws {
        let (root, cache, book) = try fixture(); defer { cleanup(root) }
        _ = try await cache.saveChapterPackageToCache(package(book, "old complete prose"), rawHTML: "<p>old</p>", normalizedHTML: "<html>old</html>")
        let before = try bytes(root, book)
        let body = root.appendingPathComponent(book.uuidString).appendingPathComponent("0.txt")
        await #expect(throws: CancellationError.self) {
            _ = try await cache.saveChapterPackageOwned(package(book, "new complete prose"), rawHTML: "<p>new</p>", normalizedHTML: "<html>new</html>", validateGrant: {
                if try String(contentsOf: body, encoding: .utf8) == "new complete prose" { throw CancellationError() }
            })
        }
        #expect(try bytes(root, book) == before)
        #expect(ChapterCacheRepository(rootDirectory: root).loadChapterPackageSync(bookId: book, chapterIndex: 0)?.content == "old complete prose")
    }
    @Test("failed restoration is explicit and retains actual previous-file artifacts")
    func restorationFailureNeverAcknowledgesOrDeletesBackup() async throws {
        let (root, cache, book) = try fixture(); defer { cleanup(root) }
        _ = try await cache.saveChapterPackageToCache(package(book, "old complete prose"), rawHTML: nil, normalizedHTML: nil)
        let body = root.appendingPathComponent(book.uuidString).appendingPathComponent("0.txt")
        do {
            _ = try await cache.saveChapterPackageOwned(package(book, "new complete prose"), rawHTML: nil, normalizedHTML: nil, validateGrant: {
                if try String(contentsOf: body, encoding: .utf8) == "new complete prose" {
                    try FileManager.default.removeItem(at: body)
                    try FileManager.default.createDirectory(at: body, withIntermediateDirectories: false)
                    throw CancellationError()
                }
            })
            Issue.record("Restoration failed but returned success")
        } catch ChapterCacheWriteError.rollbackFailed { }
        let directory = root.appendingPathComponent(book.uuidString)
        let pending = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasSuffix(".pending") }
        #expect(pending.count == 1)
        let previous = try #require(pending.first).appendingPathComponent("0.txt.previous")
        #expect(try String(contentsOf: previous, encoding: .utf8) == "old complete prose")
    }
    @Test("stale CAS and late rejected-cache cleanup retain a newer verified package")
    func foreignWriteAndLateCleanupPreserveNewestFiles() async throws {
        let (root, cache, book) = try fixture(); defer { cleanup(root) }
        _ = try await cache.saveChapterPackageToCache(package(book, "old complete prose"), rawHTML: nil, normalizedHTML: nil)
        let old = try #require(cache.loadChapterPackageSync(bookId: book, chapterIndex: 0))
        let proof = try await cache.originalBatchSnapshot(bookID: book, index: 0, sourceURL: "https://owned.invalid/one", tocTitle: "Chapter one", validateGrant: {})
        _ = try await cache.saveChapterPackageToCache(package(book, "new successful prose"), rawHTML: nil, normalizedHTML: nil)
        let before = try bytes(root, book)
        let result = try await cache.compareOriginalBatchSnapshot(proof, package: package(book, "stale failed body"), validateGrant: {}, claimCommit: { true })
        #expect(result == nil)
        cache.clearChapterCache(bookId: book, chapterIndex: 0, ifUnchanged: old)
        cache.clearChapterCache(bookId: book, chapterIndex: 0, onlyIfInvalid: true)
        await BookStore.queuedWritesLanded()
        #expect(try bytes(root, book) == before)
        #expect(ChapterCacheRepository(rootDirectory: root).loadChapterPackageSync(bookId: book, chapterIndex: 0)?.content == "new successful prose")
        let body = root.appendingPathComponent(book.uuidString).appendingPathComponent("0.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: body.path)
        await #expect(throws: (any Error).self) {
            try await cache.clearChapterCacheAwait(bookId: book, chapterIndex: 0, onlyIfInvalid: true)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: body.path)
        #expect(try bytes(root, book) == before)
    }
    @Test("unchanged saves and old TOC reconciliation keep current replacement files")
    func unchangedAndReconcileDoNotRewriteOrDeleteNewIdentity() async throws {
        let (root, cache, book) = try fixture(); defer { cleanup(root) }
        let current = package(book, "current complete prose", url: "https://owned.invalid/new")
        _ = try await cache.saveChapterPackageOwned(current, rawHTML: nil, normalizedHTML: nil)
        let before = try bytes(root, book)
        let noop = try await cache.saveChapterPackageOwned(current, rawHTML: nil, normalizedHTML: nil)
        #expect(!noop.changed); #expect(try bytes(root, book) == before)
        try await cache.reconcileChapterCache(bookId: book, old: .init(index: 0, title: "Chapter one", url: "https://owned.invalid/old"), new: .init(index: 0, title: "Chapter one", url: "https://owned.invalid/new"))
        #expect(try bytes(root, book) == before)
    }
    @Test("a queued legacy read rechecks files after the current successful writer")
    func legacyReadCannotInstallItsOlderCandidateAfterNewBody() async throws {
        let (root, cache, book) = try fixture(); defer { cleanup(root) }
        _ = try await cache.saveChapterPackageToCache(package(book, "old legacy complete prose"), rawHTML: nil, normalizedHTML: nil)
        let artifact = root.appendingPathComponent(book.uuidString).appendingPathComponent("0.package.json")
        try FileManager.default.removeItem(at: artifact)
        let gate = CacheWriterGate()
        let write = Task { try await cache.saveChapterPackageOwned(package(book, "new committed complete prose"),
            rawHTML: nil, normalizedHTML: nil, validateGrant: { try gate.pauseFirst() }) }
        var events = gate.entered.makeAsyncIterator()
        #expect(await events.next() == true)
        // This actual synchronous reader sees the still-valid old files, but its
        // upgrade only enqueues; it cannot touch the paused writer's candidates.
        #expect(cache.loadChapterPackageSync(bookId: book, chapterIndex: 0)?.content == "old legacy complete prose")
        gate.open()
        _ = try await write.value
        await BookStore.queuedWritesLanded()
        #expect(ChapterCacheRepository(rootDirectory: root).loadChapterPackageSync(bookId: book, chapterIndex: 0)?.content == "new committed complete prose")
    }
}

private final class CacheWriterGate: @unchecked Sendable {
    let entered: AsyncStream<Bool>
    private let event: AsyncStream<Bool>.Continuation
    private let lock = NSLock()
    private var visited = false
    private let release = DispatchSemaphore(value: 0)
    init() { let pair = AsyncStream<Bool>.makeStream(); entered = pair.stream; event = pair.continuation }
    func pauseFirst() throws {
        precondition(!Thread.isMainThread)
        let first = lock.withLock { if visited { return false }; visited = true; return true }
        guard first else { return }
        event.yield(true)
        guard release.wait(timeout: .now() + 30) == .success else { throw CancellationError() }
        event.finish()
    }
    func open() { release.signal() }
}
