import CryptoKit
import Foundation
import Darwin

enum ChapterCacheWriteError: LocalizedError, Equatable, Sendable {
    case emptyContent
    case createDirectory(String)
    case writeBody(String)
    case writeMetadata(String)
    case writeArtifact(String)
    case verificationFailed
    case invalidIdentity
    case committedProofRead(String)
    case rollbackFailed(original: String, rollback: String)

    var errorDescription: String? {
        switch self {
        case .emptyContent:
            return "Chapter content is empty"
        case .createDirectory(let message):
            return "Unable to create chapter cache directory: \(message)"
        case .writeBody(let message):
            return "Unable to write chapter body: \(message)"
        case .writeMetadata(let message):
            return "Unable to write chapter metadata: \(message)"
        case .writeArtifact(let message):
            return "Unable to write chapter artifact: \(message)"
        case .verificationFailed:
            return "Chapter cache verification failed"
        case .invalidIdentity:
            return "Chapter cache identity or file is invalid"
        case .committedProofRead(let message):
            return "Chapter cache was committed but its final proof could not be read: \(message)"
        case .rollbackFailed(let original, let rollback):
            return "Chapter cache write failed (\(original)); restoration also failed (\(rollback))"
        }
    }
}

struct ChapterCacheWriteReceipt: Sendable {
    let filename: String
    let changed: Bool
}

struct OriginalChapterCacheSnapshot: Sendable {
    let bookID: UUID
    let index: Int
    let package: ChapterPackage?
    let fingerprints: [String: String]
}

struct OriginalChapterCacheCommitReceipt: Sendable {
    let write: ChapterCacheWriteReceipt
    let snapshot: OriginalChapterCacheSnapshot
}

struct ChapterCacheRepository: Sendable {
    private let rootDirectory: URL

    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory ?? StorageLocations.onlineCache
    }

    func loadNormalizedChapterHTMLSync(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String? = nil,
        expectedTOCTitle: String? = nil
    ) -> String? {
        guard isCachedChapterMetadataValid(
            bookId: bookId,
            chapterIndex: chapterIndex,
            expectedSourceURL: expectedSourceURL,
            expectedTOCTitle: expectedTOCTitle
        ) else {
            return nil
        }
        let url = chapterNormalizedHTMLPath(bookId: bookId, chapterIndex: chapterIndex)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func isChapterCached(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String? = nil,
        expectedTOCTitle: String? = nil
    ) -> Bool {
        guard isCachedChapterMetadataValid(
            bookId: bookId,
            chapterIndex: chapterIndex,
            expectedSourceURL: expectedSourceURL,
            expectedTOCTitle: expectedTOCTitle
        ) else {
            return false
        }
        let url = cachePath(bookId: bookId, chapterIndex: chapterIndex)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        // Upgrade legacy entries that predate the .package.json artifact so that
        // loadChapterPackageSync (which requires the artifact) can validate them.
        _ = legacyChapterCandidate(bookId: bookId, chapterIndex: chapterIndex)
        return true
    }

    /// Compatibility commands enqueue on the actual owner and make no durable
    /// ACK claim. Strict runtime callbacks use the awaited variant below.
    func clearChapterCache(bookId: UUID, chapterIndex: Int, ifUnchanged: ChapterPackage? = nil,
                           onlyIfInvalid: Bool = false) {
        BookStore.enqueueChapterCacheMaintenance {
            do { try clearChapterFiles(bookId: bookId, chapterIndex: chapterIndex,
                expected: ifUnchanged, onlyIfInvalid: onlyIfInvalid, check: {}) }
            catch { AppLogger.error("Queued chapter cache removal failed", error: error) }
        }
    }
    func clearAllChapterCache(bookId: UUID) {
        BookStore.enqueueChapterCacheMaintenance {
            do { try clearBookFiles(bookId: bookId) }
            catch { AppLogger.error("Queued book cache removal failed", error: error) }
        }
    }
    func clearChapterCacheAwait(bookId: UUID, chapterIndex: Int, ifUnchanged: ChapterPackage? = nil,
                                onlyIfInvalid: Bool = false) async throws {
        let cancellation = OriginalRuntimeCommitCancellation()
        try await withTaskCancellationHandler {
            try await BookStore.chapterCachePersistence {
                try clearChapterFiles(bookId: bookId, chapterIndex: chapterIndex, expected: ifUnchanged,
                    onlyIfInvalid: onlyIfInvalid, check: { try cancellation.check(deadline: .distantFuture) })
            }
        } onCancel: { cancellation.cancel() }
    }
    private func clearChapterFiles(bookId: UUID, chapterIndex: Int, expected: ChapterPackage?,
                                    onlyIfInvalid: Bool, check: @Sendable () throws -> Void) throws {
        BookStore.assertChapterCachePersistenceQueue(); try check()
        guard chapterIndex >= 0 else { throw ChapterCacheWriteError.invalidIdentity }
        if let expected, loadChapterPackageSync(bookId: bookId, chapterIndex: chapterIndex) != expected { return }
        if onlyIfInvalid {
            let invalid = try knownInvalidChapterFiles(bookId: bookId, index: chapterIndex, check: check)
            if !invalid { return }
        }
        let directory = cacheDir(for: bookId)
        var status = stat()
        if lstat(directory.path, &status) != 0 {
            if errno == ENOENT { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let index = String(chapterIndex)
        let names = [index+".txt", index+".meta.json", index+".raw.html", index+".normalized.xhtml", index+".package.json"]
        try SourcePerfTrace.span("chapter.cache.clear", "files=5 main=\(Thread.isMainThread)") {
            try installChapterFiles(directory: directory, index: index, candidates: names.map { ($0, nil) }, validateGrant: check) {
                for name in names {
                    var status = stat()
                    if lstat(directory.appendingPathComponent(name).path, &status) == 0 { throw ChapterCacheWriteError.verificationFailed }
                    if errno != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                }
            }
        }
    }
    /// A compatibility loader's nil is not proof of corruption. Read each artifact
    /// through this owner's bounded throwing FD reader before classifying bytes;
    /// permission/I/O/regular-file/size failures never authorize deletion.
    private func knownInvalidChapterFiles(bookId: UUID, index: Int, check: @Sendable () throws -> Void) throws -> Bool {
        var required: [String: Data] = [:]
        var anyFile = false
        for suffix in [".txt", ".meta.json", ".package.json", ".raw.html", ".normalized.xhtml"] {
            try check()
            let path = cacheDir(for: bookId).appendingPathComponent(String(index) + suffix)
            if let bytes = try cacheFileBytes(path, limit: suffix.hasSuffix("json") ? 1_048_576 : 67_108_864, check: check) {
                anyFile = true
                if suffix == ".txt" || suffix.hasSuffix("json") { required[suffix] = bytes }
            }
        }
        guard let bytes = required[".txt"] else { return anyFile }
        guard let body = String(data: bytes, encoding: .utf8), !body.isEmpty else { return true }
        // An unidentified legacy body is not a diagnosed invalid download.
        guard let metadataBytes = required[".meta.json"] else { return false }
        let metadata: CachedChapterMetadata
        do { metadata = try JSONDecoder().decode(CachedChapterMetadata.self, from: metadataBytes) }
        catch let error as DecodingError {
            AppLogger.error("Chapter cleanup found malformed metadata bytes", error: error)
            return true
        }
        if !metadata.contentChecksum.isEmpty, metadata.contentChecksum != cacheChecksum(for: body) { return true }
        if let artifactBytes = required[".package.json"] {
            let artifact: ChapterPackageArtifact
            do { artifact = try JSONDecoder().decode(ChapterPackageArtifact.self, from: artifactBytes) }
            catch let error as DecodingError {
                AppLogger.error("Chapter cleanup found malformed package bytes", error: error)
                return true
            }
            if artifact.contentChecksum != cacheChecksum(for: body) { return true }
        }
        if let state = metadata.state, state != .cached { return true }
        return ChapterFetcher.shared.isRejectedChapterContent(body, title: metadata.extractedTitle ?? metadata.tocTitle ?? "")
    }
    func clearAllChapterCacheAwait(bookId: UUID) async throws {
        try await BookStore.chapterCachePersistence { try clearBookFiles(bookId: bookId) }
    }
    /// TOC refresh can only remove a package still identifying the old chapter.
    /// Re-read on the same writer; an earlier directory listing is not authority to
    /// delete a freshly written replacement. Unknown/corrupt legacy identity is kept.
    func reconcileChapterCache(bookId: UUID, old: OnlineChapterRef, new: OnlineChapterRef?) async throws {
        try await BookStore.chapterCachePersistence {
            guard let current = loadChapterPackageSync(bookId: bookId, chapterIndex: old.index, scheduleLegacyMigration: false),
                  current.sourceURL.map({ $0.utf8.elementsEqual(old.url.utf8) }) == true, current.tocTitle.map({ $0.utf8.elementsEqual(old.title.utf8) }) == true else { return }
            if let new, current.sourceURL.map({ $0.utf8.elementsEqual(new.url.utf8) }) == true, current.tocTitle.map({ $0.utf8.elementsEqual(new.title.utf8) }) == true { return }
            try clearChapterFiles(bookId: bookId, chapterIndex: old.index, expected: current, onlyIfInvalid: false, check: {})
        }
    }
    private func clearBookFiles(bookId: UUID) throws {
        BookStore.assertChapterCachePersistenceQueue()
        try SourcePerfTrace.span("chapter.cache.clearBook", "books=1 main=\(Thread.isMainThread)") {
            let directory = cacheDir(for: bookId)
            var status = stat()
            if lstat(directory.path, &status) != 0 {
                if errno == ENOENT { return }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw ChapterCacheWriteError.invalidIdentity }
            // Explicit user deletion, not failed-write cleanup. Recursive-delete
            // errors propagate; this operation is not claimed all-or-nothing.
            try FileManager.default.removeItem(at: directory)
        }
    }

    @discardableResult
    func saveToCache(
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
        let canonicalTitle = extractedTitle.map {
            ReaderHTMLUtilities.displayText(fromHTMLFragment: $0)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let displayTOCTitle = tocTitle.map {
            ReaderHTMLUtilities.displayText(fromHTMLFragment: $0)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let effectiveTitle = canonicalTitle?.isEmpty == false ? canonicalTitle! : (displayTOCTitle ?? "")
        let hasRawHTML = rawHTML?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        // A plain-text rebuild is only persisted alongside its raw HTML — see
        // `saveChapterArtifact`, which enforces the same rule for every writer.
        let persistsNormalizedHTML = storeNormalizedHTML && hasRawHTML
        let normalizedHTML = persistsNormalizedHTML
            ? ChapterFetcher.shared.buildNormalizedHTML(title: effectiveTitle, content: content)
            : nil
        let package = ChapterPackage(
            bookId: bookId,
            chapterIndex: chapterIndex,
            sourceURL: sourceURL,
            tocTitle: displayTOCTitle?.isEmpty == false ? displayTOCTitle : nil,
            canonicalTitle: canonicalTitle?.isEmpty == false ? canonicalTitle : nil,
            content: content,
            contentChecksum: cacheChecksum(for: content),
            rawHTMLFilename: hasRawHTML ? "\(chapterIndex).raw.html" : nil,
            normalizedHTMLFilename: persistsNormalizedHTML ? "\(chapterIndex).normalized.xhtml" : nil,
            savedAt: Date(),
            state: .cached,
            failureReason: nil
        )
        return try await saveChapterPackageToCache(
            package,
            rawHTML: rawHTML,
            normalizedHTML: normalizedHTML,
            validateGrant: validateGrant
        )
    }

    @discardableResult
    func saveChapterPackageToCache(
        _ package: ChapterPackage, rawHTML: String?, normalizedHTML: String?,
        validateGrant: @escaping @Sendable () throws -> Void = {}
    ) async throws -> String {
        try await saveChapterPackageOwned(package, rawHTML: rawHTML, normalizedHTML: normalizedHTML,
            validateGrant: validateGrant).filename
    }

    func saveChapterPackageOwned(_ package: ChapterPackage, rawHTML: String?, normalizedHTML: String?,
                                  validateGrant: @escaping @Sendable () throws -> Void = {}) async throws -> ChapterCacheWriteReceipt {
        let cancellation = OriginalRuntimeCommitCancellation()
        return try await withTaskCancellationHandler {
            try await BookStore.chapterCachePersistence {
                try SourcePerfTrace.span("chapter.cache.persist", "bytes=\(package.content.utf8.count) main=\(Thread.isMainThread)") {
                    let check: @Sendable () throws -> Void = {
                        try cancellation.check(deadline: .distantFuture); try validateGrant()
                    }
                    try check()
                    return try persistChapterPackage(package, rawHTML: rawHTML, normalizedHTML: normalizedHTML,
                        validateGrant: check)
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    /// All actual file mutations are on the existing book/chapter persistence
    /// queue. Candidate bytes are complete before any committed path changes.
    /// Hard-linked backups preserve the original bytes without copying a whole
    /// chapter into a second in-memory/file cache. Failure restores old paths;
    /// rollback failure is an unknown partial mutation, never an uncommitted ACK.
    private func persistChapterPackage(_ package: ChapterPackage, rawHTML: String?, normalizedHTML: String?,
                                       validateGrant: @Sendable () throws -> Void, migrationOnly: Bool = false,
                                       claimCommit: @Sendable () -> Bool = { true }) throws -> ChapterCacheWriteReceipt {
        BookStore.assertChapterCachePersistenceQueue()
        guard package.chapterIndex >= 0 else { throw ChapterCacheWriteError.invalidIdentity }
        guard !package.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChapterCacheWriteError.emptyContent }
        let manager = FileManager.default
        let directory = cacheDir(for: package.bookId)
        do { try manager.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { throw ChapterCacheWriteError.createDirectory(error.localizedDescription) }
        let index = String(package.chapterIndex)
        let filename = index + ".txt"
        let checksum = cacheChecksum(for: package.content)
        let hasRaw = rawHTML?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let rawName = hasRaw ? index + ".raw.html" : nil
        let normalizedName = hasRaw && normalizedHTML != nil ? index + ".normalized.xhtml" : nil
        if !migrationOnly,
           try cacheFileBytes(chapterPackagePath(bookId: package.bookId, chapterIndex: package.chapterIndex), limit: 1_048_576) != nil,
           let current = loadChapterPackageSync(bookId: package.bookId, chapterIndex: package.chapterIndex),
           current.state == .cached, current.content.utf8.elementsEqual(package.content.utf8),
           Self.sameRaw(current.sourceURL, package.sourceURL), Self.sameRaw(current.tocTitle, package.tocTitle),
           Self.sameRaw(current.canonicalTitle, package.canonicalTitle), current.rawHTMLFilename == rawName,
           current.normalizedHTMLFilename == normalizedName,
           current.renderArtifactVersion == OnlineChapterRenderArtifact.currentVersion,
           try cacheFileBytes(chapterRawHTMLPath(bookId: package.bookId, chapterIndex: package.chapterIndex), limit: 67_108_864) == (hasRaw ? rawHTML.map { Data($0.utf8) } : nil),
           try cacheFileBytes(chapterNormalizedHTMLPath(bookId: package.bookId, chapterIndex: package.chapterIndex), limit: 67_108_864) == (normalizedName != nil ? normalizedHTML.map { Data($0.utf8) } : nil) {
            try validateGrant()
            return .init(filename: filename, changed: false)
        }
        let metadata = CachedChapterMetadata(sourceURL: package.sourceURL, tocTitle: package.tocTitle,
            extractedTitle: package.canonicalTitle, contentChecksum: checksum, savedAt: package.savedAt,
            state: .cached, failureReason: nil)
        let artifact = ChapterPackageArtifact(sourceURL: package.sourceURL, tocTitle: package.tocTitle,
            canonicalTitle: package.canonicalTitle, contentChecksum: checksum, rawHTMLFilename: rawName,
            normalizedHTMLFilename: normalizedName, renderArtifactVersion: OnlineChapterRenderArtifact.currentVersion,
            savedAt: package.savedAt)
        let fullCandidates: [(String, Data?)] = [
            (filename, Data(package.content.utf8)),
            (index + ".meta.json", try JSONEncoder().encode(metadata)),
            (index + ".raw.html", hasRaw ? rawHTML.map { Data($0.utf8) } : nil),
            (index + ".normalized.xhtml", normalizedName != nil ? normalizedHTML.map { Data($0.utf8) } : nil),
            (index + ".package.json", try JSONEncoder().encode(artifact))
        ]
        let candidates = migrationOnly ? fullCandidates.filter { $0.0.hasSuffix(".meta.json") || $0.0.hasSuffix(".package.json") } : fullCandidates
        try installChapterFiles(directory: directory, index: index, candidates: candidates, validateGrant: validateGrant, claimCommit: claimCommit) {
            guard let verified = loadChapterPackageSync(bookId: package.bookId, chapterIndex: package.chapterIndex,
                expectedSourceURL: package.sourceURL, expectedTOCTitle: package.tocTitle),
                verified.state == .cached, verified.content == package.content, verified.contentChecksum == checksum else {
                throw ChapterCacheWriteError.verificationFailed
            }
        }
        return .init(filename: filename, changed: true)
    }

    /// The runtime borrows this proof from the same real cache files and writer.
    /// It does not mint an edit generation or choose a book/chapter from URL text.
    func originalBatchSnapshot(bookID: UUID, index: Int, sourceURL: String, tocTitle: String,
                                validateGrant: @escaping @Sendable () throws -> Void) async throws -> OriginalChapterCacheSnapshot {
        try await BookStore.chapterCachePersistence {
            try validateGrant()
            return try SourcePerfTrace.span("chapter.cache.original.snapshot", "files=5 main=\(Thread.isMainThread)") {
                let fingerprints = try chapterFingerprints(bookID: bookID, index: index, check: validateGrant)
                let package = loadChapterPackageSync(bookId: bookID, chapterIndex: index,
                    expectedSourceURL: sourceURL, expectedTOCTitle: tocTitle, scheduleLegacyMigration: false)
                if package == nil && fingerprints.values.contains(where: { $0 != "missing" }) {
                    throw ChapterCacheWriteError.verificationFailed
                }
                if let package, !Self.sameRaw(package.sourceURL, sourceURL) { throw ChapterCacheWriteError.invalidIdentity }
                try validateGrant()
                return .init(bookID: bookID, index: index, package: package, fingerprints: fingerprints)
            }
        }
    }

    /// nil means a stale, unmodified CAS. Actual write errors throw; a successful
    /// receipt is returned even if cancellation arrives after the committed IO.
    func compareOriginalBatchSnapshot(_ expected: OriginalChapterCacheSnapshot, package: ChapterPackage,
                                       validateGrant: @escaping @Sendable () throws -> Void,
                                       claimCommit: @escaping @Sendable () -> Bool) async throws -> OriginalChapterCacheCommitReceipt? {
        guard package.bookId == expected.bookID, package.chapterIndex == expected.index else {
            throw ChapterCacheWriteError.invalidIdentity
        }
        let cancellation = OriginalRuntimeCommitCancellation()
        return try await withTaskCancellationHandler {
            try await BookStore.chapterCachePersistence {
                let check: @Sendable () throws -> Void = { try cancellation.check(deadline: .distantFuture); try validateGrant() }
                try check()
                guard try chapterFingerprints(bookID: expected.bookID, index: expected.index, check: check) == expected.fingerprints else { return nil }
                let currentPackage = loadChapterPackageSync(bookId: expected.bookID, chapterIndex: expected.index,
                    scheduleLegacyMigration: false)
                if let existing = currentPackage, existing.state == .cached,
                   existing.content.utf8.elementsEqual(package.content.utf8),
                   Self.sameRaw(existing.sourceURL, package.sourceURL) {
                    // Identical resolved text is already durable: retain existing
                    // canonical title/raw/render artifacts instead of stripping them.
                    return .init(write: .init(filename: String(expected.index)+".txt", changed: false), snapshot: expected)
                }
                let receipt = try persistChapterPackage(package, rawHTML: nil, normalizedHTML: nil,
                    validateGrant: check, claimCommit: claimCommit)
                if !receipt.changed { return .init(write: receipt, snapshot: expected) }
                do {
                    // Already committed: complete its proof without turning a late
                    // cancellation/revoke into a claim of no file mutation.
                    let fingerprints = try chapterFingerprints(bookID: expected.bookID, index: expected.index, check: {})
                    let current = loadChapterPackageSync(bookId: expected.bookID, chapterIndex: expected.index,
                        scheduleLegacyMigration: false)
                    guard current != nil else { throw ChapterCacheWriteError.verificationFailed }
                    return .init(write: receipt, snapshot: .init(bookID: expected.bookID, index: expected.index,
                        package: current, fingerprints: fingerprints))
                } catch { throw ChapterCacheWriteError.committedProofRead(error.localizedDescription) }
            }
        } onCancel: { cancellation.cancel() }
    }

    private func chapterFingerprints(bookID: UUID, index: Int, check: () throws -> Void) throws -> [String: String] {
        BookStore.assertChapterCachePersistenceQueue()
        guard index >= 0 else { throw ChapterCacheWriteError.invalidIdentity }
        var result: [String: String] = [:]
        for suffix in [".txt", ".meta.json", ".raw.html", ".normalized.xhtml", ".package.json"] {
            try check()
            let path = cacheDir(for: bookID).appendingPathComponent(String(index) + suffix)
            if let data = try cacheFileBytes(path, limit: suffix.hasSuffix("json") ? 1_048_576 : 67_108_864, check: check) {
                result[suffix] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            } else { result[suffix] = "missing" }
        }
        return result
    }

    private static func sameRaw(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (left?, right?): return left.utf8.elementsEqual(right.utf8)
        default: return false
        }
    }

    private func installChapterFiles(directory: URL, index: String, candidates: [(String, Data?)],
                                     validateGrant: @Sendable () throws -> Void, claimCommit: @Sendable () -> Bool = { true },
                                     verify: () throws -> Void) throws {
        BookStore.assertChapterCachePersistenceQueue()
        let manager = FileManager.default
        let staging = directory.appendingPathComponent(".chapter-\(index)-\(UUID().uuidString).pending", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        var backups = Set<String>(); var installed: [String] = []
        do {
            // Preflight every destination before touching an existing committed file.
            for (name, bytes) in candidates {
                let target = directory.appendingPathComponent(name)
                var status = stat()
                if lstat(target.path, &status) == 0 {
                    guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw ChapterCacheWriteError.invalidIdentity }
                    try manager.linkItem(at: target, to: staging.appendingPathComponent(name + ".previous"))
                    backups.insert(name)
                } else if errno != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                if let bytes { try bytes.write(to: staging.appendingPathComponent(name + ".candidate"), options: .atomic) }
            }
            try validateGrant()
            // This request-local gate races native deadline sealing under its
            // existing lock; never enter an irreversible rename after denial.
            guard claimCommit() else { throw CancellationError() }
            for (name, bytes) in candidates {
                try validateGrant()
                let target = directory.appendingPathComponent(name)
                if bytes != nil {
                    guard rename(staging.appendingPathComponent(name + ".candidate").path, target.path) == 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                } else if backups.contains(name) {
                    guard unlink(target.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                } else { continue }
                installed.append(name)
            }
            try verify()
        } catch {
            let original = error
            do {
                for name in installed.reversed() {
                    let target = directory.appendingPathComponent(name)
                    if backups.contains(name) {
                        guard rename(staging.appendingPathComponent(name + ".previous").path, target.path) == 0 else {
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                    } else if unlink(target.path) != 0 && errno != ENOENT {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                }
            } catch {
                AppLogger.error("Chapter cache restoration failed; retained transaction directory", error: error)
                throw ChapterCacheWriteError.rollbackFailed(original: original.localizedDescription, rollback: error.localizedDescription)
            }
            do { try manager.removeItem(at: staging) }
            catch { AppLogger.error("Chapter cache failed transaction cleanup", error: error) }
            throw original
        }
        // All committed files were verified. A late cancellation cannot turn an
        // acknowledged cache mutation into a claim that nothing was committed.
        do { try manager.removeItem(at: staging) }
        catch { AppLogger.error("Chapter cache committed transaction cleanup", error: error) }
    }

    func loadCachedChapterMetadataSync(bookId: UUID, chapterIndex: Int) -> CachedChapterMetadata? {
        let url = cacheMetadataPath(bookId: bookId, chapterIndex: chapterIndex)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CachedChapterMetadata.self, from: data)
    }

    func loadChapterPackageSync(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String? = nil,
        expectedTOCTitle: String? = nil,
        scheduleLegacyMigration: Bool = true
    ) -> ChapterPackage? {
        // The package loader is the reading pipeline's source of truth. Upgrade
        // old offline downloads here (not only from `isChapterCached`) so opening
        // an already-downloaded chapter can never miss its valid `.txt` body.
        let legacy = legacyChapterCandidate(bookId: bookId, chapterIndex: chapterIndex, scheduleMigration: scheduleLegacyMigration)
        // "No metadata at all" is the ordinary not-cached-yet path and is checked
        // once per chapter by the offline validator — logging it would drown the
        // rejections below, which are the ones that mean a cache went bad.
        guard let metadata = legacy?.metadata ?? loadCachedChapterMetadataSync(bookId: bookId, chapterIndex: chapterIndex) else {
            return nil
        }
        if let expectedSourceURL,
            normalizedURLKey(metadata.sourceURL) != normalizedURLKey(expectedSourceURL)
        {
            AppLogger.cache("⟐ chapterPackage miss", context: [
                "index": chapterIndex,
                "reason": "urlMismatch",
                "saved": String((metadata.sourceURL ?? "nil").prefix(120)),
                "expected": String(expectedSourceURL.prefix(120)),
            ])
            return nil
        }
        if let expectedTOCTitle,
            !expectedTOCTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let normalizedExpected = normalizeCacheTitle(expectedTOCTitle)
            let normalizedCached = normalizeCacheTitle(metadata.tocTitle ?? metadata.extractedTitle ?? "")
            if !normalizedCached.isEmpty
                && normalizedExpected != normalizedCached
                && !normalizedExpected.contains(normalizedCached)
                && !normalizedCached.contains(normalizedExpected)
            {
                AppLogger.cache("⟐ chapterPackage miss", context: [
                    "index": chapterIndex,
                    "reason": "titleMismatch",
                    "saved": String(normalizedCached.prefix(60)),
                    "expected": String(normalizedExpected.prefix(60)),
                ])
                return nil
            }
        }

        let packageURL = chapterPackagePath(bookId: bookId, chapterIndex: chapterIndex)
        let bodyURL = cachePath(bookId: bookId, chapterIndex: chapterIndex)
        let artifactData = try? Data(contentsOf: packageURL)
        let artifact = legacy?.artifact ?? artifactData.flatMap { try? JSONDecoder().decode(ChapterPackageArtifact.self, from: $0) }
        let body = legacy?.package.content ?? ((try? String(contentsOf: bodyURL, encoding: .utf8)) ?? "")
        let cachedTitle = metadata.extractedTitle ?? metadata.tocTitle ?? ""

        if metadata.state == .cached {
            guard let artifact, !body.isEmpty, artifact.contentChecksum == cacheChecksum(for: body) else {
                AppLogger.cache("⟐ chapterPackage miss", context: [
                    "index": chapterIndex,
                    "reason": "artifact",
                    "hasArtifact": artifact != nil,
                    "bodyLen": body.count,
                    "checksumMatch": artifact.map { $0.contentChecksum == cacheChecksum(for: body) } ?? false,
                ])
                return nil
            }
            if ChapterFetcher.shared.isRejectedChapterContent(body, title: cachedTitle) {
                AppLogger.cache("⟐ chapterPackage miss", context: [
                    "index": chapterIndex,
                    "reason": "contentRejected",
                    "bodyLen": body.count,
                    "title": String(cachedTitle.prefix(60)),
                ])
                return nil
            }
            return ChapterPackage(
                bookId: bookId,
                chapterIndex: chapterIndex,
                sourceURL: artifact.sourceURL ?? metadata.sourceURL,
                tocTitle: artifact.tocTitle ?? metadata.tocTitle,
                canonicalTitle: artifact.canonicalTitle ?? metadata.extractedTitle,
                content: body,
                contentChecksum: artifact.contentChecksum,
                rawHTMLFilename: artifact.rawHTMLFilename,
                normalizedHTMLFilename: artifact.normalizedHTMLFilename,
                renderArtifactVersion: artifact.renderArtifactVersion,
                savedAt: artifact.savedAt,
                state: .cached,
                failureReason: nil
            )
        }

        return ChapterPackage(
            bookId: bookId,
            chapterIndex: chapterIndex,
            sourceURL: metadata.sourceURL,
            tocTitle: metadata.tocTitle,
            canonicalTitle: metadata.extractedTitle,
            content: "",
            contentChecksum: metadata.contentChecksum,
            rawHTMLFilename: artifact?.rawHTMLFilename,
            normalizedHTMLFilename: artifact?.normalizedHTMLFilename,
            renderArtifactVersion: artifact?.renderArtifactVersion,
            savedAt: metadata.savedAt,
            state: .failed,
            failureReason: metadata.failureReason
        )
    }

    private func isCachedChapterMetadataValid(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String?,
        expectedTOCTitle: String?
    ) -> Bool {
        let textPath = cachePath(bookId: bookId, chapterIndex: chapterIndex)
        guard FileManager.default.fileExists(atPath: textPath.path) else { return false }
        guard let metadata = loadCachedChapterMetadataSync(bookId: bookId, chapterIndex: chapterIndex) else {
            return expectedSourceURL == nil && expectedTOCTitle == nil
        }

        if let expectedSourceURL,
            normalizedURLKey(metadata.sourceURL) != normalizedURLKey(expectedSourceURL)
        {
            return false
        }

        if let expectedTOCTitle,
            !expectedTOCTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let normalizedExpected = normalizeCacheTitle(expectedTOCTitle)
            let normalizedCached = normalizeCacheTitle(metadata.tocTitle ?? metadata.extractedTitle ?? "")
            if !normalizedCached.isEmpty
                && normalizedExpected != normalizedCached
                && !normalizedExpected.contains(normalizedCached)
                && !normalizedCached.contains(normalizedExpected)
            {
                return false
            }
        }

        return true
    }

    private func cacheDir(for bookId: UUID) -> URL {
        rootDirectory.appendingPathComponent(bookId.uuidString, isDirectory: true)
    }

    private func cachePath(bookId: UUID, chapterIndex: Int) -> URL {
        cacheDir(for: bookId).appendingPathComponent("\(chapterIndex).txt")
    }

    private func cacheMetadataPath(bookId: UUID, chapterIndex: Int) -> URL {
        cacheDir(for: bookId).appendingPathComponent("\(chapterIndex).meta.json")
    }

    private func chapterPackagePath(bookId: UUID, chapterIndex: Int) -> URL {
        cacheDir(for: bookId).appendingPathComponent("\(chapterIndex).package.json")
    }

    private func chapterRawHTMLPath(bookId: UUID, chapterIndex: Int) -> URL {
        cacheDir(for: bookId).appendingPathComponent("\(chapterIndex).raw.html")
    }

    private func chapterNormalizedHTMLPath(bookId: UUID, chapterIndex: Int) -> URL {
        cacheDir(for: bookId).appendingPathComponent("\(chapterIndex).normalized.xhtml")
    }

    private func normalizedURLKey(_ raw: String?) -> String {
        guard let raw, var components = URLComponents(string: raw) else { return "" }
        components.fragment = nil
        components.queryItems = components.queryItems?.sorted { $0.name < $1.name }
        return (components.string ?? raw).lowercased()
    }

    private func normalizeCacheTitle(_ title: String) -> String {
        ReaderHTMLUtilities.displayText(fromHTMLFragment: title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .lowercased()
    }

    private func cacheChecksum(for content: String) -> String {
        let digest = SHA256.hash(data: Data(content.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private struct LegacyCandidate: Sendable {
        let metadata: CachedChapterMetadata
        let artifact: ChapterPackageArtifact
        let package: ChapterPackage
    }
    /// This is a bounded set of scheduled maintenance identities only, never a
    /// second content cache. The lock protects no I/O and is released before enqueue.
    private final class PendingMigrations: @unchecked Sendable {
        private let lock = NSLock()
        private var keys = Set<String>()
        func begin(_ key: String) -> Bool { lock.withLock {
            guard keys.count < 64, !keys.contains(key) else { return false }
            keys.insert(key); return true
        } }
        func end(_ key: String) { lock.withLock { _ = keys.remove(key) } }
    }
    private static let pendingMigrations = PendingMigrations()

    private func legacyChapterCandidate(bookId: UUID, chapterIndex: Int, scheduleMigration: Bool = true) -> LegacyCandidate? {
        do {
            guard let candidate = try readLegacyCandidate(bookId: bookId, chapterIndex: chapterIndex) else { return nil }
            let key = cachePath(bookId: bookId, chapterIndex: chapterIndex).path
            if scheduleMigration && Self.pendingMigrations.begin(key) {
                BookStore.enqueueChapterCacheMaintenance {
                    defer { Self.pendingMigrations.end(key) }
                    do {
                        // Never publish a stale UI-read candidate over a newer write.
                        guard let current = try readLegacyCandidate(bookId: bookId, chapterIndex: chapterIndex) else { return }
                        _ = try persistChapterPackage(current.package, rawHTML: nil, normalizedHTML: nil,
                            validateGrant: {}, migrationOnly: true)
                    } catch { AppLogger.error("Chapter cache legacy migration failed", error: error) }
                }
            }
            return candidate
        } catch {
            AppLogger.error("Chapter cache legacy record could not be read", error: error)
            return nil // Compatibility UI read; strict Host snapshots use the throwing owner API.
        }
    }

    private func readLegacyCandidate(bookId: UUID, chapterIndex: Int) throws -> LegacyCandidate? {
        guard try cacheFileBytes(chapterPackagePath(bookId: bookId, chapterIndex: chapterIndex), limit: 1_048_576) == nil else { return nil }
        guard let bodyData = try cacheFileBytes(cachePath(bookId: bookId, chapterIndex: chapterIndex), limit: 67_108_864),
              let body = String(data: bodyData, encoding: .utf8), !body.isEmpty,
              let metadataData = try cacheFileBytes(cacheMetadataPath(bookId: bookId, chapterIndex: chapterIndex), limit: 1_048_576) else { return nil }
        let prior = try JSONDecoder().decode(CachedChapterMetadata.self, from: metadataData)
        guard prior.state == .cached || prior.state == nil else { return nil }
        return try SourcePerfTrace.span("chapter.cache.legacy.read", "bytes=\(bodyData.count) main=\(Thread.isMainThread)") {
            let checksum = cacheChecksum(for: body)
            guard prior.contentChecksum.isEmpty || prior.contentChecksum == checksum else { return nil }
            let metadata = CachedChapterMetadata(sourceURL: prior.sourceURL, tocTitle: prior.tocTitle,
                extractedTitle: prior.extractedTitle, contentChecksum: checksum, savedAt: prior.savedAt,
                state: .cached, failureReason: nil)
            let artifact = ChapterPackageArtifact(sourceURL: prior.sourceURL, tocTitle: prior.tocTitle,
                canonicalTitle: prior.extractedTitle, contentChecksum: checksum, rawHTMLFilename: nil,
                normalizedHTMLFilename: nil, renderArtifactVersion: OnlineChapterRenderArtifact.currentVersion, savedAt: prior.savedAt)
            let package = ChapterPackage(bookId: bookId, chapterIndex: chapterIndex, sourceURL: prior.sourceURL,
                tocTitle: prior.tocTitle, canonicalTitle: prior.extractedTitle, content: body, contentChecksum: checksum,
                rawHTMLFilename: nil, normalizedHTMLFilename: nil, renderArtifactVersion: OnlineChapterRenderArtifact.currentVersion,
                savedAt: prior.savedAt, state: .cached, failureReason: nil)
            return LegacyCandidate(metadata: metadata, artifact: artifact, package: package)
        }
    }

    /// One descriptor, regular file, bound before allocation and exact ENOENT.
    /// Cached chapter payloads are bounded to 64 MiB; metadata/artifacts to 1 MiB.
    private func cacheFileBytes(_ path: URL, limit: Int, check: () throws -> Void = {}) throws -> Data? {
        try check()
        let descriptor = Darwin.open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var open = true
        defer { if open { _ = Darwin.close(descriptor) } }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_size >= 0,
              before.st_size <= limit else { throw ChapterCacheWriteError.invalidIdentity }
        var result = Data(count: Int(before.st_size))
        try result.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try check()
                let count = Darwin.pread(descriptor, buffer.baseAddress!.advanced(by: offset), min(262_144, buffer.count-offset), off_t(offset))
                if count < 0 { if errno == EINTR { continue }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                guard count > 0 else { throw ChapterCacheWriteError.invalidIdentity }
                offset += count
            }
        }
        var after = stat(); var atPath = stat()
        guard Darwin.fstat(descriptor, &after) == 0, Darwin.lstat(path.path, &atPath) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              after.st_dev == atPath.st_dev, after.st_ino == atPath.st_ino else { throw ChapterCacheWriteError.invalidIdentity }
        open = false
        guard Darwin.close(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try check()
        return result
    }
}
