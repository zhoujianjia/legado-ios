import CryptoKit
import Foundation
import Testing
@testable import yuedu_app

@Suite("Chapter cache migration", .serialized)
struct ChapterCacheMigrationTests {
    @Test("package loader upgrades a downloaded legacy chapter")
    func packageLoaderUpgradesDownloadedLegacyChapter() throws {
        let bookId = UUID()
        let chapterIndex = 3
        let sourceURL = "https://example.com/book/3"
        let tocTitle = "第三章 舊下載"
        let content = "這是已經下載到本機的章節正文。"
        let cacheDirectory = StorageLocations.onlineCache.appendingPathComponent(bookId.uuidString)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try content.write(
            to: cacheDirectory.appendingPathComponent("\(chapterIndex).txt"),
            atomically: true,
            encoding: .utf8
        )
        let metadata = CachedChapterMetadata(
            sourceURL: sourceURL,
            tocTitle: tocTitle,
            extractedTitle: tocTitle,
            contentChecksum: checksum(content),
            savedAt: Date(timeIntervalSince1970: 1_700_000_000),
            state: nil,
            failureReason: nil
        )
        let metadataData = try JSONEncoder().encode(metadata)
        try metadataData.write(
            to: cacheDirectory.appendingPathComponent("\(chapterIndex).meta.json"),
            options: .atomic
        )

        let package = ChapterCacheRepository().loadChapterPackageSync(
            bookId: bookId,
            chapterIndex: chapterIndex,
            expectedSourceURL: sourceURL,
            expectedTOCTitle: tocTitle
        )

        #expect(package?.state == .cached)
        #expect(package?.content == content)
        #expect(package?.contentChecksum == checksum(content))
        #expect(
            FileManager.default.fileExists(
                atPath: cacheDirectory.appendingPathComponent("\(chapterIndex).package.json").path
            )
        )
    }

    @Test("missing package cannot bless a body that differs from its saved checksum", arguments: [false, true])
    func corruptLegacyBodyDoesNotRewriteStoredChecksum(hasCachedState: Bool) throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ChapterCacheRepository(rootDirectory: root)
        let bookId = UUID()
        let directory = root.appendingPathComponent(bookId.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bodyURL = directory.appendingPathComponent("0.txt")
        let metadataURL = directory.appendingPathComponent("0.meta.json")
        let artifactURL = directory.appendingPathComponent("0.package.json")
        let damagedBody = Data("Interrupted or damaged cached body".utf8)
        try damagedBody.write(to: bodyURL)
        let metadata = CachedChapterMetadata(
            sourceURL: "https://example.com/chapter/0", tocTitle: "Chapter 1", extractedTitle: nil,
            contentChecksum: checksum("Complete committed chapter body"),
            savedAt: Date(timeIntervalSince1970: 1_700_000_000),
            state: hasCachedState ? .cached : nil, failureReason: nil
        )
        let metadataBytes = try JSONEncoder().encode(metadata)
        try metadataBytes.write(to: metadataURL)

        // Reopening repeats the migration attempt. Neither attempt may rewrite
        // the known checksum or manufacture a package for the damaged bytes.
        for candidate in [repository, ChapterCacheRepository(rootDirectory: root)] {
            let package = candidate.loadChapterPackageSync(
                bookId: bookId, chapterIndex: 0,
                expectedSourceURL: metadata.sourceURL, expectedTOCTitle: metadata.tocTitle
            )
            #expect(package?.state != .cached)
            #expect(package?.content != String(decoding: damagedBody, as: UTF8.self))
            #expect(!FileManager.default.fileExists(atPath: artifactURL.path))
            #expect(try Data(contentsOf: bodyURL) == damagedBody)
            #expect(try Data(contentsOf: metadataURL) == metadataBytes)
        }
    }

    @Test("legacy metadata without a checksum can still migrate", arguments: [false, true])
    func legacyBodyWithoutChecksumRemainsUpgradeable(hasCachedState: Bool) throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ChapterCacheRepository(rootDirectory: root)
        let bookId = UUID()
        let directory = root.appendingPathComponent(bookId.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let body = "A complete legacy chapter without a stored checksum."
        try body.write(to: directory.appendingPathComponent("0.txt"), atomically: true, encoding: .utf8)
        let metadata = CachedChapterMetadata(
            sourceURL: "https://example.com/chapter/0", tocTitle: "Chapter 1", extractedTitle: nil,
            contentChecksum: "", savedAt: Date(timeIntervalSince1970: 1_700_000_000),
            state: hasCachedState ? .cached : nil, failureReason: nil
        )
        try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent("0.meta.json"))

        let migrated = try #require(repository.loadChapterPackageSync(
            bookId: bookId, chapterIndex: 0,
            expectedSourceURL: metadata.sourceURL, expectedTOCTitle: metadata.tocTitle
        ))
        #expect(migrated.state == .cached)
        #expect(migrated.content == body)
        #expect(migrated.contentChecksum == checksum(body))
        let reopened = ChapterCacheRepository(rootDirectory: root).loadChapterPackageSync(
            bookId: bookId, chapterIndex: 0,
            expectedSourceURL: metadata.sourceURL, expectedTOCTitle: metadata.tocTitle
        )
        #expect(reopened == migrated)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ChapterCacheMigrationTests-\(UUID().uuidString)")
    }

    private func checksum(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
