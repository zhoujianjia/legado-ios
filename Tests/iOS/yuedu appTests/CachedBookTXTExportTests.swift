import Foundation
import Testing
@testable import yuedu_app

@Suite("Cached book TXT export", .serialized)
struct CachedBookTXTExportTests {
    @Test("partial export preserves TOC order and excludes stale, missing and volume entries")
    func partialExportUsesValidatedCacheInTOCOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = ChapterCacheRepository(rootDirectory: directory.appendingPathComponent("cache"))
        let bookID = UUID()
        let chapters = [
            OnlineChapterRef(index: 0, title: "Volume", url: "", isVolume: true),
            OnlineChapterRef(index: 4, title: "First", url: "https://example.test/4"),
            OnlineChapterRef(index: 2, title: "Second", url: "https://example.test/2"),
            OnlineChapterRef(index: 3, title: "Stale", url: "https://example.test/new"),
            OnlineChapterRef(index: 9, title: "Missing", url: "https://example.test/9"),
        ]
        try save(repository, bookID: bookID, position: 1, chapter: chapters[1], body: "first body")
        try save(repository, bookID: bookID, position: 2, chapter: chapters[2], body: "second body")
        var stale = chapters[3]
        stale.url = "https://example.test/old"
        try save(repository, bookID: bookID, position: 3, chapter: stale, body: "stale body")

        let result = try await CachedBookTXTExportService.export(
            CachedBookTXTExportRequest(bookID: bookID, title: "../A:Book", author: "Author", chapters: chapters),
            repository: repository, temporaryDirectory: directory
        )
        #expect(result.cachedChapterCount == 2)
        #expect(result.totalChapterCount == 4)
        #expect(result.fileURL.lastPathComponent.hasSuffix("-cached.txt"))
        #expect(result.fileURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "LegadoTXTExport")
        let text = try String(contentsOf: result.fileURL, encoding: .utf8)
        #expect(text == "../A:Book\nAuthor\n\nFirst\n\nfirst body\n\nSecond\n\nsecond body\n\n")
        #expect(!text.contains("stale body"))
    }

    @Test("complete export is UTF-8 and contains every cached chapter")
    func completeExportPreservesChinese() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = ChapterCacheRepository(rootDirectory: directory.appendingPathComponent("cache"))
        let bookID = UUID()
        let chapter = OnlineChapterRef(index: 0, title: "第一章", url: "https://example.test/0")
        let html = "<p>简体中文正文。</p><p>第二段。<img src=\"https://example.test/cover\"></p>"
        try save(repository, bookID: bookID, position: 0, chapter: chapter, body: html, rawHTML: html)
        let result = try await CachedBookTXTExportService.export(
            CachedBookTXTExportRequest(bookID: bookID, title: "测试书", author: "作者", chapters: [chapter]),
            repository: repository, temporaryDirectory: directory
        )
        #expect(result.cachedChapterCount == result.totalChapterCount)
        #expect(result.fileURL.lastPathComponent == "测试书.txt")
        #expect(try String(contentsOf: result.fileURL, encoding: .utf8) == "测试书\n作者\n\n第一章\n\n简体中文正文。\n第二段。\n\n")
    }

    @Test("authoritative plain text preserves literal tags, entities and whitespace")
    func plainTextExportsWithoutHTMLInterpretation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = ChapterCacheRepository(rootDirectory: directory.appendingPathComponent("cache"))
        let bookID = UUID()
        let chapter = OnlineChapterRef(index: 0, title: "第一章 <literal> &lt;", url: "https://example.test/plain")
        let body = "  原样保留 <标签> 与 &lt;code&gt;、&amp;。\r\n\t第二行。\n"
        try save(repository, bookID: bookID, position: 0, chapter: chapter, body: body)
        let package = try #require(repository.loadChapterPackageSync(
            bookId: bookID, chapterIndex: 0, expectedSourceURL: chapter.sanitizedContentURL,
            expectedTOCTitle: chapter.title
        ))
        #expect(package.rawHTMLFilename == nil)
        #expect(package.normalizedHTMLFilename == nil)

        let result = try await CachedBookTXTExportService.export(
            CachedBookTXTExportRequest(bookID: bookID, title: "Plain", author: "Author", chapters: [chapter]),
            repository: repository, temporaryDirectory: directory
        )
        let expected = "Plain\nAuthor\n\n" + chapter.title + "\n\n" + body + "\n\n"
        #expect(try Data(contentsOf: result.fileURL) == Data(expected.utf8))
    }

    @Test("no readable cache produces an error and leaves no misleading TXT")
    func emptyExportDoesNotCreateEmptyBook() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = ChapterCacheRepository(rootDirectory: directory.appendingPathComponent("cache"))
        do {
            _ = try await CachedBookTXTExportService.export(
                CachedBookTXTExportRequest(bookID: UUID(), title: "Book", author: "", chapters: [
                    OnlineChapterRef(index: 0, title: "Missing", url: "https://example.test/0"),
                ]), repository: repository, temporaryDirectory: directory
            )
            Issue.record("An empty export must not be reported as a book")
        } catch CachedBookTXTExportError.noCachedChapters {
            let exportDirectory = directory.appendingPathComponent("LegadoTXTExport")
            #expect(try FileManager.default.contentsOfDirectory(atPath: exportDirectory.path).isEmpty)
        }
    }

    private func save(
        _ repository: ChapterCacheRepository, bookID: UUID, position: Int, chapter: OnlineChapterRef,
        body: String, rawHTML: String? = nil
    ) throws {
        try repository.saveChapterPackageToCache(ChapterPackage(
            bookId: bookID, chapterIndex: position, sourceURL: chapter.sanitizedContentURL,
            tocTitle: chapter.title, canonicalTitle: chapter.title, content: body,
            contentChecksum: "", rawHTMLFilename: rawHTML == nil ? nil : "\(position).raw.html", normalizedHTMLFilename: nil,
            savedAt: Date(), state: .cached, failureReason: nil
        ), rawHTML: rawHTML, normalizedHTML: nil)
    }
}
