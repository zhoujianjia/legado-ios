import CryptoKit
import Foundation
import LegadoRuntime

// MARK: - Fetch Chapter Content

extension BookSourceFetcher {

    func fetchChapter(
        ref: OnlineChapterRef, bookId: UUID, source: BookSource, chapterReferer: String? = nil,
        cacheWriteGeneration: OriginalRuntimeChapterGeneration? = nil
    ) async throws
        -> String
    {
        let package = try await fetchChapterPackage(
            ref: ref,
            bookId: bookId,
            source: source,
            chapterReferer: chapterReferer,
            cacheWriteGeneration: cacheWriteGeneration
        )
        return package.content
    }

    func fetchChapterPackage(
        ref: OnlineChapterRef, bookId: UUID, source: BookSource, chapterReferer: String? = nil,
        cacheWriteGeneration: OriginalRuntimeChapterGeneration? = nil
    ) async throws -> ChapterPackage {
        await BookStore.queuedWritesLanded()
        try Task.checkCancellation()
        if source.isJsSource {
            return try await fetchMainJSChapterPackage(ref: ref, bookId: bookId, source: source, cacheWriteGeneration: cacheWriteGeneration)
        }
        guard !ref.shouldRenderAsVolumeSeparator else { throw FetchError.volumeSeparator(ref.title) }
        // Validation/preview calls have no real App book or generation. They read
        // original text without creating a cache file under a synthetic UUID.
        guard cacheWriteGeneration == nil else {
            throw LegadoRuntimeError(code: "INVALID_STATE_OWNER",
                message: "Traditional reader writes require its actual BookStore and chapter generation")
        }
        let content = try await mainJSService.originalContent(ref: ref, source: source)
        return ChapterPackage(bookId: bookId, chapterIndex: ref.index, sourceURL: ref.url,
            tocTitle: ref.title, canonicalTitle: nil, content: content,
            contentChecksum: SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined(),
            rawHTMLFilename: nil, normalizedHTMLFilename: nil, savedAt: Date(), state: .cached, failureReason: nil)
    }

    private func fetchMainJSChapterPackage(ref: OnlineChapterRef, bookId: UUID, source: BookSource, cacheWriteGeneration: OriginalRuntimeChapterGeneration?) async throws -> ChapterPackage {
        guard !ref.shouldRenderAsVolumeSeparator else { throw FetchError.volumeSeparator(ref.title) }
        let content = try await mainJSService.content(ref: ref, source: source)
        try ChapterFetcher.shared.validateResolvedContent(content)
        // mainJs returns authoritative plain text, with no original HTML to retain.
        // The reader builds its escaped XHTML from this durable body on cache-only opens.
        let checksum = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
        let package = ChapterPackage(bookId: bookId, chapterIndex: ref.index, sourceURL: ref.url,
            tocTitle: ref.title, canonicalTitle: nil, content: content, contentChecksum: checksum,
            rawHTMLFilename: nil, normalizedHTMLFilename: nil,
            savedAt: Date(), state: .cached, failureReason: nil)
        try await saveChapterPackageToCache(package, rawHTML: nil, normalizedHTML: nil,
            validateGrant: { try cacheWriteGeneration?.checkCacheWrite(deadline: .distantFuture) })
        guard let reloaded = loadChapterPackageSync(bookId: bookId, chapterIndex: ref.index,
            expectedSourceURL: ref.url, expectedTOCTitle: ref.title) else {
            throw ChapterCacheWriteError.verificationFailed
        }
        return reloaded
    }

    /// The real Reader borrows one already-active generation from its manager.
    /// Original single-page/pagination and configured batch content share the same
    /// existing App Host, final variable CAS, body writer and durable readback.
    func fetchOriginalOwnedChapterPackage(book: ReadingBook, ref: OnlineChapterRef,
                                         source: BookSource, store: BookStore,
                                         generation: OriginalRuntimeChapterGeneration) async throws -> ChapterPackage {
        let deadline = Date().addingTimeInterval(TimeInterval(AppConfig.chapterFetchTimeoutSeconds))
        guard let bookURL = book.bookInfoURL, !bookURL.isEmpty,
              generation.bookID == book.id, generation.chapterID == ref.id,
              generation.index == ref.index, generation.url.utf8.elementsEqual(ref.url.utf8),
              let index = Int32(exactly: ref.index), index >= 0 else {
            throw LegadoRuntimeError(code: "INVALID_STATE_OWNER", message: "Reader chapter lost its actual App identity")
        }
        try generation.check(deadline: deadline)
        guard let owned = await store.prepareOriginalRuntimeBookSnapshot(id: book.id,
            sourceID: source.id, bookURL: bookURL) else {
            throw LegadoRuntimeError(code: "STATE_CONFLICT", message: "Reader book/source changed before original execution")
        }
        let currentRefs = try await store.originalRuntimeChapters(bookID: book.id)
        guard currentRefs.indices.contains(ref.index), currentRefs[ref.index].id == ref.id,
              currentRefs[ref.index].url.utf8.elementsEqual(ref.url.utf8) else {
            throw LegadoRuntimeError(code: "STATE_CONFLICT", message: "Reader TOC changed before original execution")
        }
        let actual = currentRefs[ref.index]
        var dto = LegadoOriginalBook(bookURL: bookURL, origin: source.bookSourceUrl,
            name: book.title, author: book.author, tocURL: owned.tocURL)
        dto.originName = source.bookSourceName
        dto.totalChapterNum = Int32(exactly: currentRefs.count) ?? Int32.max
        dto.variable = try originalSmallVariables(owned.variables)
        var chapter = LegadoOriginalChapter(bookURL: bookURL, url: actual.url, index: index,
            title: actual.title, baseURL: owned.tocURL)
        chapter.isVolume = actual.isVolume; chapter.isVip = actual.isVip; chapter.isPay = actual.isPay
        chapter.variable = try originalSmallVariables(actual.runtimeVariables)
        let selected = OriginalRuntimeBatchChapter(chapter: actual, generation: generation, dto: chapter)
        let result = try await withTaskCancellationHandler {
            try await mainJSService.originalContentBatch(source: source, store: store, bookID: book.id,
                book: dto, chapters: [selected], taskID: UUID().uuidString, deadline: deadline,
                singleChapter: true,
                nextChapterURL: currentRefs.indices.contains(ref.index + 1) ? currentRefs[ref.index + 1].url : nil)
        } onCancel: { generation.revoke() }
        try generation.check(deadline: deadline)
        guard result.missingChapters.isEmpty else { throw FetchError.emptyContent }
        let package = try await BookStore.chapterCachePersistence {
            try generation.checkCacheWrite(deadline: deadline)
            return Self.chapterCacheRepository.loadChapterPackageSync(bookId: book.id, chapterIndex: ref.index,
                expectedSourceURL: actual.url, expectedTOCTitle: actual.title, scheduleLegacyMigration: false)
        }
        guard let package, OnlineChapterCacheWritePolicy.isReusableCachedPackage(package, hasBookSource: true) else {
            throw ChapterCacheWriteError.verificationFailed
        }
        generation.recordReportedEffects(["chapterContentVerified"])
        return package
    }

    private func originalSmallVariables(_ variables: [String: String]?) throws -> String? {
        guard let variables else { return nil }
        let exposed = variables.filter { $0.key != LegadoMainJSSourceService.originalPreviewContextKey && $0.value.utf16.count < 10_000 }
        try LegadoPreviewVariableCodec.validateRepresentable([exposed])
        return String(decoding: try JSONEncoder().encode(exposed), as: UTF8.self)
    }
}
