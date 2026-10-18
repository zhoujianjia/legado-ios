import Foundation

struct CachedBookTXTExportRequest: Identifiable {
    let bookID: UUID
    let title: String
    let author: String
    let chapters: [OnlineChapterRef]
    var id: UUID { bookID }
}

struct CachedBookTXTExportResult {
    let fileURL: URL
    let cachedChapterCount: Int
    let totalChapterCount: Int
}

enum CachedBookTXTExportError: LocalizedError {
    case noCachedChapters

    var errorDescription: String? { localized("尚無可匯出的已快取正文，請先閱讀或下載章節。") }
}

/// A local-only export: the same validated packages the reader uses, in current TOC order.
/// No fetcher is owned here, so exporting can never silently download the rest of a book.
enum CachedBookTXTExportService {
    nonisolated static func export(
        _ request: CachedBookTXTExportRequest,
        repository: ChapterCacheRepository = ChapterCacheRepository(),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) async throws -> CachedBookTXTExportResult {
        try SourcePerfTrace.span(
            "book.export.cachedTXT",
            "main=\(Thread.isMainThread) chapters=\(request.chapters.count)"
        ) {
            try write(request, repository: repository, temporaryDirectory: temporaryDirectory)
        }
    }

    nonisolated private static func write(
        _ request: CachedBookTXTExportRequest,
        repository: ChapterCacheRepository,
        temporaryDirectory: URL
    ) throws -> CachedBookTXTExportResult {
        let directory = temporaryDirectory
            .appendingPathComponent("LegadoTXTExport", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(safeFileName(request.title) + ".txt")
        guard fileManager.createFile(atPath: fileURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            var isClosed = false
            defer {
                if !isClosed {
                    do { try handle.close() }
                    catch { AppLogger.error("TXT export file close failed", error: error) }
                }
            }
            try handle.write(contentsOf: Data((request.title + "\n" + request.author + "\n\n").utf8))
            var cachedCount = 0
            let chapterCount = request.chapters.reduce(0) { $0 + ($1.isVolume ? 0 : 1) }
            for (position, chapter) in request.chapters.enumerated() {
                try Task.checkCancellation()
                guard !chapter.isVolume,
                      let package = repository.loadChapterPackageSync(
                        bookId: request.bookID,
                        // Cache keys are TOC positions, as in OnlineChapterContentService.
                        chapterIndex: position,
                        expectedSourceURL: chapter.sanitizedContentURL,
                        expectedTOCTitle: chapter.title
                      ),
                      package.state == .cached,
                      !package.content.isEmpty else { continue }
                let body = ReaderHTMLUtilities.displayText(
                    fromHTMLFragment: package.content, preservingLineBreaks: true
                )
                guard !body.isEmpty else { continue }
                let heading = ReaderHTMLUtilities.displayText(
                    fromHTMLFragment: package.renderTitle.isEmpty ? chapter.title : package.renderTitle
                )
                try handle.write(contentsOf: Data((heading + "\n\n" + body + "\n\n").utf8))
                cachedCount += 1
            }
            guard cachedCount > 0 else { throw CachedBookTXTExportError.noCachedChapters }
            try handle.close()
            isClosed = true
            let resultURL: URL
            if cachedCount < chapterCount {
                // A shared partial book keeps its scope visible even outside this app.
                resultURL = directory.appendingPathComponent(safeFileName(request.title) + "-cached.txt")
                try fileManager.moveItem(at: fileURL, to: resultURL)
            } else {
                resultURL = fileURL
            }
            return CachedBookTXTExportResult(
                fileURL: resultURL,
                cachedChapterCount: cachedCount,
                totalChapterCount: chapterCount
            )
        } catch {
            do { try fileManager.removeItem(at: directory) }
            catch { AppLogger.error("TXT export cleanup failed", error: error) }
            throw error
        }
    }

    nonisolated private static func safeFileName(_ title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:\n\r\0").union(.controlCharacters)
        let name = title.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "." || name == ".." ? "Book" : String(name.prefix(80))
    }
}
