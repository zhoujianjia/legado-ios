import Foundation

// MARK: - Chapter Cache Delegation (ChapterCacheRepository)

extension BookSourceFetcher {

    nonisolated func loadNormalizedChapterHTMLSync(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String? = nil,
        expectedTOCTitle: String? = nil
    ) -> String? {
        Self.chapterCacheRepository.loadNormalizedChapterHTMLSync(
            bookId: bookId,
            chapterIndex: chapterIndex,
            expectedSourceURL: expectedSourceURL,
            expectedTOCTitle: expectedTOCTitle
        )
    }

    nonisolated func isChapterCached(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String? = nil,
        expectedTOCTitle: String? = nil
    ) -> Bool {
        Self.chapterCacheRepository.isChapterCached(
            bookId: bookId,
            chapterIndex: chapterIndex,
            expectedSourceURL: expectedSourceURL,
            expectedTOCTitle: expectedTOCTitle
        )
    }

    nonisolated func clearChapterCache(bookId: UUID, chapterIndex: Int, ifUnchanged: ChapterPackage? = nil, onlyIfInvalid: Bool = false) {
        Self.chapterCacheRepository.clearChapterCache(bookId: bookId, chapterIndex: chapterIndex, ifUnchanged: ifUnchanged, onlyIfInvalid: onlyIfInvalid)
    }
    nonisolated func clearChapterCacheAwait(bookId: UUID, chapterIndex: Int, ifUnchanged: ChapterPackage? = nil,
                                           onlyIfInvalid: Bool = false) async throws {
        try await Self.chapterCacheRepository.clearChapterCacheAwait(bookId: bookId, chapterIndex: chapterIndex,
            ifUnchanged: ifUnchanged, onlyIfInvalid: onlyIfInvalid)
    }
    nonisolated func clearAllChapterCache(bookId: UUID) {
        Self.chapterCacheRepository.clearAllChapterCache(bookId: bookId)
    }
    nonisolated func clearAllChapterCacheAwait(bookId: UUID) async throws {
        try await Self.chapterCacheRepository.clearAllChapterCacheAwait(bookId: bookId)
    }

    @discardableResult
    nonisolated func saveToCache(
        content: String,
        bookId: UUID,
        chapterIndex: Int,
        sourceURL: String? = nil,
        tocTitle: String? = nil,
        extractedTitle: String? = nil,
        rawHTML: String? = nil,
        storeNormalizedHTML: Bool = true,
        validateGrant: @escaping @Sendable () throws -> Void = {}
    ) async throws -> String {
        try await Self.chapterCacheRepository.saveToCache(
            content: content,
            bookId: bookId,
            chapterIndex: chapterIndex,
            sourceURL: sourceURL,
            tocTitle: tocTitle,
            extractedTitle: extractedTitle,
            rawHTML: rawHTML,
            storeNormalizedHTML: storeNormalizedHTML,
            validateGrant: validateGrant
        )
    }

    @discardableResult
    nonisolated func saveChapterPackageToCache(
        _ package: ChapterPackage,
        rawHTML: String?,
        normalizedHTML: String?,
        validateGrant: @escaping @Sendable () throws -> Void = {}
    ) async throws -> String {
        try await Self.chapterCacheRepository.saveChapterPackageToCache(
            package,
            rawHTML: rawHTML,
            normalizedHTML: normalizedHTML,
            validateGrant: validateGrant
        )
    }

    nonisolated func loadCachedChapterMetadataSync(bookId: UUID, chapterIndex: Int) -> CachedChapterMetadata? {
        Self.chapterCacheRepository.loadCachedChapterMetadataSync(
            bookId: bookId,
            chapterIndex: chapterIndex
        )
    }

    nonisolated func loadChapterPackageSync(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String? = nil,
        expectedTOCTitle: String? = nil
    ) -> ChapterPackage? {
        Self.chapterCacheRepository.loadChapterPackageSync(
            bookId: bookId,
            chapterIndex: chapterIndex,
            expectedSourceURL: expectedSourceURL,
            expectedTOCTitle: expectedTOCTitle
        )
    }
}
