import Foundation
import os
import LegadoRuntime

struct OriginalRuntimeBatchChapter: @unchecked Sendable {
    let chapter: OnlineChapterRef
    let generation: OriginalRuntimeChapterGeneration
    let dto: LegadoOriginalChapter
}
struct LegadoContentStateKey: Sendable {
    let wire: String
    let index: Int? // nil is the actual App book TOC projection, never a body grant.
}
struct LegadoContentStateSnapshot: Sendable {
    let index: Int
    let cache: OriginalChapterCacheSnapshot
    let state: LegadoOwnedStateSnapshot
}

/// One exact accepted metadata revision, with no readback/adoption of later App edits.
private final class BatchBookCompletionProof: @unchecked Sendable {
    private let lock = NSLock()
    private var value: OriginalRuntimeBookMetadataOwner.Snapshot?
    func initialize(_ snapshot: OriginalRuntimeBookMetadataOwner.Snapshot) {
        lock.withLock { precondition(value == nil); value = snapshot }
    }
    func accepted(_ snapshot: OriginalRuntimeBookMetadataOwner.Snapshot) { lock.withLock { value = snapshot } }
    func snapshot() -> OriginalRuntimeBookMetadataOwner.Snapshot? { lock.withLock { value } }
}

/// An adapter borrowing the existing BookStore, chapter owner, cache repository and
/// in-flight fetch generations. It owns no file/queue/body cache. At most 32 transient
/// accepted-file proofs prevent a later CAS retry from legitimizing a foreign edit.
final class AppLegadoContentBatchOwner: @unchecked Sendable, LegadoEntityStateBacking {
    let taskID: String
    let book: LegadoOriginalBook
    private let store: BookStore
    private let bookID: UUID
    private let sourceID: UUID
    private let expiresAt: Date
    private let cache: ChapterCacheRepository
    private let bookVariables: AppLegadoBookStateOwner
    private let chapterVariables: [Data: [AppLegadoBookStateOwner]]
    private let granted: [Int: OriginalRuntimeBatchChapter]
    private let lifetime = OriginalRuntimeCommitCancellation()
    private let bookCompletion: BatchBookCompletionProof
    private let proofLock = NSLock()
    private var accepted: [Int: [String: String]] = [:]
    private var busy = Set<Int>()

    init(taskID: String, store: BookStore, bookID: UUID, sourceID: UUID, book: LegadoOriginalBook,
         chapters: [OriginalRuntimeBatchChapter], deadline: Date,
         cache: ChapterCacheRepository = BookSourceFetcher.chapterCacheRepository) throws {
        guard !taskID.isEmpty, chapters.count <= 32, Set(chapters.map { $0.chapter.index }).count == chapters.count,
              Set(chapters.map { $0.chapter.id }).count == chapters.count else { throw Self.failure("INVALID_STATE_OWNER", "Batch requires bounded actual chapter identities") }
        self.taskID = taskID; self.store = store; self.bookID = bookID; self.sourceID = sourceID
        self.book = book; self.expiresAt = deadline; self.cache = cache
        let completion = BatchBookCompletionProof()
        self.bookCompletion = completion
        self.bookVariables = try AppLegadoBookStateOwner(store: store, bookID: bookID, sourceID: sourceID,
            bookURL: book.bookURL, chapter: nil, generation: nil,
            acceptedBookCommit: { completion.accepted($0) })
        var variables: [Data: [AppLegadoBookStateOwner]] = [:]
        var values: [Int: OriginalRuntimeBatchChapter] = [:]
        for value in chapters {
            let ref = value.chapter; let generation = value.generation
            guard ref.index >= 0, Int(value.dto.index) == ref.index, value.dto.bookURL.utf8.elementsEqual(book.bookURL.utf8),
                  value.dto.url.utf8.elementsEqual(ref.url.utf8), generation.bookID == bookID,
                  generation.chapterID == ref.id, generation.index == ref.index,
                  generation.url.utf8.elementsEqual(ref.url.utf8) else { throw Self.failure("INVALID_STATE_OWNER", "Batch chapter lacks its actual App generation") }
            values[ref.index] = value
            variables[Data(ref.url.utf8), default: []].append(try AppLegadoBookStateOwner(store: store,
                bookID: bookID, sourceID: sourceID, bookURL: book.bookURL, chapter: ref, generation: generation))
        }
        granted = values; chapterVariables = variables
    }
    func revoke() {
        lifetime.cancel(); bookVariables.revoke()
        for values in chapterVariables.values { values.forEach { $0.revoke() } }
    }
    func validateRequest(_ request: LegadoHostRequest) throws {
        guard request.taskID == taskID else { throw Self.failure("INVALID_STATE_OWNER", "Batch grant belongs to one actual runtime task") }
        try check(deadline: min(expiresAt, Date().addingTimeInterval(request.remainingTimeoutSeconds)))
    }
    func validateState(deadline: Date) async throws { try check(deadline: deadline) }
    private func check(deadline: Date) throws {
        try lifetime.check(deadline: min(deadline, expiresAt))
        guard store.originalRuntimeBookSnapshot(id: bookID, sourceID: sourceID, bookURL: book.bookURL) != nil else {
            throw Self.failure("STATE_CONFLICT", "The granted App book changed source or identity")
        }
    }
    private func checkChapter(_ index: Int, deadline: Date) throws {
        try check(deadline: deadline)
        guard let value = granted[index] else { throw Self.failure("UNSUPPORTED_CAPABILITY", "Chapter was not granted by the actual batch job") }
        try value.generation.check(deadline: min(deadline, expiresAt))
    }
    private func checkChapterOnWriter(_ index: Int, deadline: Date,
                                       cancellation: OriginalRuntimeCommitCancellation) throws {
        try cancellation.check(deadline: min(deadline, expiresAt)); try checkChapter(index, deadline: deadline)
        let ref = granted[index]!.chapter
        try store.validateOriginalRuntimeCacheChapter(bookID: bookID, chapterID: ref.id, index: ref.index, url: ref.url)
    }

    func authorize(bookURL: String, chapters: [(Int, String)], deadline: Date) throws {
        try check(deadline: deadline)
        guard bookURL.utf8.elementsEqual(book.bookURL.utf8), chapters.count == granted.count,
              Set(chapters.map { $0.0 }).count == chapters.count else { throw Self.failure("UNSUPPORTED_CAPABILITY", "Batch DTOs differ from the explicitly granted App chapters") }
        for (index, url) in chapters {
            guard let value = granted[index], value.chapter.url.utf8.elementsEqual(url.utf8) else {
                throw Self.failure("UNSUPPORTED_CAPABILITY", "Batch URL/index was not granted")
            }
            try checkChapter(index, deadline: deadline)
        }
    }

    func prepareBookCompletion(deadline: Date) async throws {
        let snapshot = try await store.originalRuntimeBookVariableSnapshot(bookID: bookID, sourceID: sourceID,
            bookURL: book.bookURL, deadline: min(deadline, expiresAt), cancellation: lifetime,
            validateGrant: { [self] in try check(deadline: deadline) })
        bookCompletion.initialize(snapshot)
    }

    /// Direct Book.variable assignment is the original returned small-map field.
    /// Merge it with the large companions of this task's exact last accepted proof;
    /// another App/Host edit is a conflict, never a fresh snapshot to overwrite.
    func finishResultBook(_ result: LegadoOriginalBook, deadline: Date) async throws -> Bool {
        try check(deadline: deadline)
        guard result.bookURL.utf8.elementsEqual(book.bookURL.utf8),
              result.origin.utf8.elementsEqual(book.origin.utf8), result.type == book.type else {
            throw Self.failure("INVALID_RESULT", "Original batch changed its granted book/source identity")
        }
        guard let expected = bookCompletion.snapshot() else { throw Self.failure("INVALID_STATE_OWNER", "Batch completion has no initial App book proof") }
        let small = try result.variable.map(LegadoPreviewVariableCodec.decodeMap)
        guard small?.values.allSatisfy({ $0.utf16.count < 10_000 }) != false else {
            throw Self.failure("INVALID_RESULT", "Original returned small variables contain a large companion")
        }
        let large = expected.book.variables?.filter { $0.value.utf16.count >= 10_000 } ?? [:]
        try LegadoPreviewVariableCodec.validateRepresentable([small ?? [:], large])
        guard Set((small ?? [:]).keys).isDisjoint(with: large.keys) else {
            throw Self.failure("UNSUPPORTED_CAPABILITY", "Small and large original variable companions cannot share one App map key")
        }
        let variables: [String: String]? = small == nil && large.isEmpty ? nil : (small ?? [:]).merging(large) { first, _ in first }
        let validate: @Sendable () throws -> Void = { [self] in try check(deadline: deadline) }
        if BookStore.RuntimeBookSnapshot.sameVariables(variables, expected.book.variables) {
            guard try await store.validateOriginalRuntimeBookProof(expected, deadline: deadline,
                cancellation: lifetime, validateGrant: validate) else {
                throw Self.failure("STATE_CONFLICT", "App book changed after the batch's last accepted variable commit")
            }
            return false // No semantic change: no write, revision bump or UI publication.
        }
        guard try await store.compareOriginalRuntimeBook(expected: expected, expectedView: expected.book,
            variables: variables, deadline: deadline, cancellation: lifetime,
            accepted: { [bookCompletion] in bookCompletion.accepted($0) }, validateGrant: validate) else {
            throw Self.failure("STATE_CONFLICT", "App book changed after the batch's last accepted variable commit")
        }
        return true
    }

    // Variable operations delegate to the actual existing per-entity owner. Original
    // URL-keyed variable ABI cannot silently select between two distinct App chapters.
    private func variableOwner(_ wires: [String], decoded: [String: [String]]) throws -> AppLegadoBookStateOwner {
        guard let wire = wires.first, let parts = decoded[wire], parts.count >= 5 else { throw Self.failure("INVALID_STATE_REQUEST", "Entity identity is malformed") }
        if parts[2] == "book" { return bookVariables }
        guard let owners = chapterVariables[Data(parts[4].utf8)], owners.count == 1 else {
            throw Self.failure("UNSUPPORTED_CAPABILITY", "URL-keyed original variables do not identify a unique granted App chapter")
        }
        return owners[0]
    }
    func parse(_ wires: [String], sourceURL: String, decodedParts: [String: [String]]) throws -> [LegadoEntityStateKey] {
        try variableOwner(wires, decoded: decodedParts).parse(wires, sourceURL: sourceURL, decodedParts: decodedParts)
    }
    func readState(keys: [LegadoEntityStateKey], deadline: Date, cancellation: OriginalRuntimeCommitCancellation) async throws -> LegadoEntityBackingSnapshot {
        try check(deadline: deadline)
        let owner = try ownerForKeys(keys)
        return try await owner.readState(keys: keys, deadline: deadline, cancellation: cancellation)
    }
    func commitState(snapshot: LegadoEntityBackingSnapshot, keys: [LegadoEntityStateKey], changes: [String: Data?],
                     deadline: Date, cancellation: OriginalRuntimeCommitCancellation,
                     claimCommit: @escaping @Sendable () -> Bool = { true }) async throws -> Bool {
        try check(deadline: deadline)
        return try await ownerForKeys(keys).commitState(snapshot: snapshot, keys: keys, changes: changes,
            deadline: deadline, cancellation: cancellation, claimCommit: claimCommit)
    }
    private func ownerForKeys(_ keys: [LegadoEntityStateKey]) throws -> AppLegadoBookStateOwner {
        guard let key = keys.first else { throw Self.failure("INVALID_STATE_REQUEST", "Entity keys are empty") }
        guard let url = key.chapterURL else { return bookVariables }
        guard let values = chapterVariables[Data(url.utf8)], values.count == 1 else { throw Self.failure("UNSUPPORTED_CAPABILITY", "Chapter variable owner is ambiguous") }
        return values[0]
    }

    func parseContent(_ wires: [String], sourceURL: String, decoded: [String: [String]]) throws -> [LegadoContentStateKey] {
        var values: [LegadoContentStateKey] = []
        for wire in wires {
            guard let parts = decoded[wire], parts.count == 3 || parts.count == 4,
                  parts[0].utf8.elementsEqual(sourceURL.utf8), parts[2].utf8.elementsEqual(book.bookURL.utf8) else {
                throw Self.failure("UNSUPPORTED_CAPABILITY", "Body key does not match the granted App book")
            }
            if parts[1] == "toc", parts.count == 3 { values.append(.init(wire: wire, index: nil)) }
            else if parts[1] == "content", parts.count == 4, let index = Int(parts[3]), String(index) == parts[3], granted[index] != nil {
                values.append(.init(wire: wire, index: index))
            } else { throw Self.failure("UNSUPPORTED_CAPABILITY", "Body key has no actual chapter generation grant") }
        }
        guard values.count <= 2, values.filter({ $0.index != nil }).count == 1 else {
            throw Self.failure("UNSUPPORTED_CAPABILITY", "One original save snapshot must belong to one granted chapter")
        }
        return values
    }

    private func begin(_ index: Int) throws {
        try proofLock.withLock {
            guard !busy.contains(index) else { throw Self.failure("STATE_CONFLICT", "This chapter already has an active owner operation") }
            busy.insert(index)
        }
    }
    private func end(_ index: Int) { proofLock.withLock { _ = busy.remove(index) } }
    private func acceptRead(_ value: OriginalChapterCacheSnapshot) throws {
        try proofLock.withLock {
            if let prior = accepted[value.index], prior != value.fingerprints {
                throw Self.failure("STATE_CONFLICT", "Another cache writer changed the actual chapter files")
            }
            accepted[value.index] = value.fingerprints
        }
    }
    func readContent(keys: [LegadoContentStateKey], deadline: Date,
                     cancellation: OriginalRuntimeCommitCancellation) async throws -> LegadoContentStateSnapshot {
        let index = keys.compactMap(\.index)[0]
        try begin(index); defer { end(index) }
        try checkChapter(index, deadline: deadline)
        let value = granted[index]!
        let snapshot = try await cache.originalBatchSnapshot(bookID: bookID, index: index, sourceURL: value.chapter.url,
            tocTitle: value.chapter.title, validateGrant: { [self] in try checkChapterOnWriter(index, deadline: deadline, cancellation: cancellation) })
        try cancellation.check(deadline: min(deadline, expiresAt)); try checkChapter(index, deadline: deadline)
        try acceptRead(snapshot)
        var result: [String: Data] = [:]
        for key in keys {
            if key.index != nil {
                let row = ContentRecord(version: 0, bookUrl: book.bookURL, index: index, chapterUrl: value.chapter.url,
                    name: book.name, author: book.author, title: value.dto.title, imgUrl: value.dto.imgURL, body: snapshot.package?.content ?? "")
                result[key.wire] = try JSONEncoder().encode(row)
            } else {
                let chapters = try await store.originalRuntimeChapters(bookID: bookID)
                result[key.wire] = try JSONEncoder().encode(chapters.map { TocRecord(chapter: $0, book: book) })
            }
        }
        try checkChapter(index, deadline: deadline)
        return .init(index: index, cache: snapshot, state: .init(revision: 0, values: result))
    }

    func commitContent(snapshot: LegadoContentStateSnapshot, keys: [LegadoContentStateKey], changes: [String: Data?],
                       deadline: Date, cancellation: OriginalRuntimeCommitCancellation,
                       request: LegadoHostRequest) async throws -> Bool {
        let index = snapshot.index
        try begin(index); defer { end(index) }
        try checkChapter(index, deadline: deadline)
        guard let key = keys.first(where: { $0.index == index }), changes.count == 1,
              let optional = changes[key.wire], let bytes = optional, bytes.count <= 1_048_576 else {
            throw Self.failure("UNSUPPORTED_CAPABILITY", "Original batch saves only one content value; TOC metadata/deletion is not granted")
        }
        let row: ContentRecord
        do { row = try JSONDecoder().decode(ContentRecord.self, from: bytes) }
        catch { throw Self.failure("INVALID_STATE_REQUEST", "Original content record is incompatible with the granted save") }
        let value = granted[index]!
        guard row.version == 0, row.index == index, row.bookUrl.utf8.elementsEqual(book.bookURL.utf8),
              row.chapterUrl.utf8.elementsEqual(value.chapter.url.utf8), row.name.utf8.elementsEqual(book.name.utf8),
              row.author.utf8.elementsEqual(book.author.utf8), !row.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Self.failure("INVALID_STATE_REQUEST", "Original body identity differs from the captured App save grant")
        }
        // Original BatchContentContext does not run the single-page HtmlFormatter:
        // this is the authored rule's final content string, not an HTTP document.
        // Keep those exact bytes in .txt for original state reads and audio/image
        // URL consumers; the ordinary reader separately consumes normalized XHTML.
        let hasMarkup = row.body.range(of: #"<\s*/?\s*[a-zA-Z!][^>]*>"#, options: .regularExpression) != nil
        let normalized: String?
        if hasMarkup {
            // The existing deferred-image resolver evaluates UrlOption.js in the
            // old source JS session. Original tasks cannot borrow that session.
            guard !row.body.contains(";base64,,{") else {
                throw Self.failure("UNSUPPORTED_CAPABILITY", "Original batch deferred image UrlOption.js requires the same original Rhino task")
            }
            let base = value.dto.baseURL.isEmpty ? book.origin : value.dto.baseURL
            guard let resourceBase = URL(string: value.dto.url, relativeTo: URL(string: base))?.absoluteURL,
                  resourceBase.scheme?.lowercased() == "http" || resourceBase.scheme?.lowercased() == "https" else {
                throw Self.failure("UNSUPPORTED_CAPABILITY", "Original batch markup requires its actual absolute chapter resource base")
            }
            normalized = await SourcePerfTrace.spanAsync("chapter.original.batch.render",
                "bytes=\(row.body.utf8.count) main=\(Thread.isMainThread)") {
                let resolved = await ChapterFetcher.shared.resolveContent(parsed: .init(
                    content: row.body, title: value.chapter.title, sourceMatched: true, isPay: value.chapter.isPay))
                // nil reviewContext deliberately avoids the legacy JSC image
                // resolver; ordinary static images/embedded media use the same
                // established sanitizer/XHTML/reader data contract as normal fetch.
                return await ChapterFetcher.shared.buildRenderableNormalizedHTML(
                    title: value.chapter.title, plainTextContent: resolved,
                    rawHTMLContent: row.body, reviewContext: nil,
                    contentBaseURL: resourceBase.absoluteString)
            }
            try cancellation.check(deadline: min(deadline, expiresAt)); try checkChapter(index, deadline: deadline)
            guard normalized?.isEmpty == false else {
                throw Self.failure("UNSUPPORTED_CAPABILITY", "Existing chapter renderer could not map original callback resources")
            }
        } else { normalized = nil }
        let package = ChapterPackage(bookId: bookID, chapterIndex: index, sourceURL: value.chapter.url,
            tocTitle: value.chapter.title, canonicalTitle: nil, content: row.body, contentChecksum: "",
            rawHTMLFilename: hasMarkup ? "\(index).raw.html" : nil,
            normalizedHTMLFilename: hasMarkup ? "\(index).normalized.xhtml" : nil,
            savedAt: Date(), state: .cached, failureReason: nil)
        do {
            guard let receipt = try await cache.compareOriginalBatchSnapshot(snapshot.cache, package: package,
                rawHTML: hasMarkup ? row.body : nil, normalizedHTML: normalized,
                validateGrant: { [self] in try checkChapterOnWriter(index, deadline: deadline, cancellation: cancellation) },
                claimCommit: { request.recordPossibleEffect("chapterContentMayCommit") }) else { return false }
            proofLock.withLock { accepted[index] = receipt.snapshot.fingerprints }
            if receipt.write.changed { request.recordPossibleEffect("chapterContentCommitted") }
            return true
        } catch let error as ChapterCacheWriteError {
            switch error {
            case .rollbackFailed, .committedProofRead:
                throw LegadoRuntimeError(code: "STATE_IO", message: error.localizedDescription,
                    completedEffects: ["chapterContentMayCommit"])
            default: throw error
            }
        }
    }
    // version=0 is only the finite JVM record representation. Authorization/edit
    // protection is the real generation plus captured complete file proofs above.
    private struct ContentRecord: Codable {
        let version: Int64; let bookUrl: String; let index: Int; let chapterUrl: String
        let name: String; let author: String; let title: String; let imgUrl: String?; let body: String
    }
    private struct TocRecord: Codable {
        let url: String; let title: String; let bookUrl: String; let index: Int; let baseUrl: String
        let isVolume: Bool; let isVip: Bool; let isPay: Bool
        init(chapter: OnlineChapterRef, book: LegadoOriginalBook) {
            url = chapter.url; title = chapter.title; bookUrl = book.bookURL; index = chapter.index; baseUrl = book.tocURL
            isVolume = chapter.isVolume; isVip = chapter.isVip; isPay = chapter.isPay
        }
    }
    private static func failure(_ code: String, _ message: String) -> LegadoRuntimeError { .init(code: code, message: message) }
}


/// Values borrowed from real App owners, never decoded from imported source JSON.
struct LegadoContentBatchExecutionRequest: @unchecked Sendable {
    let sourceJSON: String
    let sourceURL: String
    let sourceRevision: String
    let sourceID: UUID
    let store: BookStore
    let bookID: UUID
    let book: LegadoOriginalBook
    let chapters: [OriginalRuntimeBatchChapter]
    let taskID: String
    let deadline: Date
    let cache: ChapterCacheRepository
}
protocol LegadoOriginalContentBatchExecuting: Sendable {
    func execute(_ request: LegadoContentBatchExecutionRequest) async throws -> LegadoOriginalContentBatchResult
}
struct NativeLegadoOriginalContentBatchExecutor: LegadoOriginalContentBatchExecuting {
    func execute(_ request: LegadoContentBatchExecutionRequest) async throws -> LegadoOriginalContentBatchResult {
        let process = LegadoRuntimeProcess.shared
        let owner = try await process.bindPersistentContentBatch(request)
        var finalBookCommitted = false
        let reportedEffects = OSAllocatedUnfairLock(initialState: [String]())
        do {
            let runtime = try await process.executor()
            try check(request.deadline)
            let session = try await runtime.createSession(sourceJSON: request.sourceJSON,
                options: NativeLegadoOriginalPreviewExecutor.embeddingOptions(owner: owner))
            let result: LegadoOriginalContentBatchResult
            do {
                try check(request.deadline)
                result = try await runtime.contentBatchOriginal(session: session, book: request.book,
                    chapters: request.chapters.map(\.dto),
                    timeoutMilliseconds: Int64(min(300_000, max(1, request.deadline.timeIntervalSinceNow * 1000))), taskID: request.taskID,
                    onReportedEffects: { effects in reportedEffects.withLock { $0 = effects } })
                guard result.missingChapters.count <= request.chapters.count,
                      Set(result.missingChapters.map(\.index)).count == result.missingChapters.count,
                      result.missingChapters.allSatisfy({ missing in
                          request.chapters.contains { value in value.dto.index == missing.index &&
                              value.dto.url.utf8.elementsEqual(missing.url.utf8) &&
                              value.dto.bookURL.utf8.elementsEqual(missing.bookURL.utf8) }
                      }) else {
                    throw LegadoRuntimeError(code: "INVALID_RESULT", message: "Original missing chapters changed their granted App index/URL identity")
                }
                finalBookCommitted = try await process.finishContentBatchResult(owner: owner, request: request, book: result.book)
            } catch {
                do { try await runtime.close(session: session) }
                catch { AppLogger.error("Original batch session cleanup failed after execution error", error: error) }
                throw error
            }
            try await runtime.close(session: session)
            try check(request.deadline)
            await process.revokePersistentSource(owner: owner)
            return result
        } catch {
            await process.revokePersistentSource(owner: owner)
            let failure = error as? LegadoRuntimeError
            let effects = Array(Set(reportedEffects.withLock { $0 } + (failure?.completedEffects ?? []) +
                (finalBookCommitted ? ["bookVariablesCommitted"] : []))).sorted()
            if !effects.isEmpty {
                throw LegadoRuntimeError(code: failure?.code ?? (error is CancellationError ? "CANCELLED" : "STATE_IO"),
                    message: error.localizedDescription, completedEffects: effects)
            }
            throw error
        }
    }
    private func check(_ deadline: Date) throws {
        try Task.checkCancellation()
        guard deadline.timeIntervalSinceNow > 0 else { throw LegadoRuntimeError(code: "TIMEOUT", message: "Original batch absolute deadline elapsed") }
    }
}

/// Actual cache-readback facts survive ordinary JVM and later metadata errors.
/// A saved prefix is never rolled back merely because another chapter failed.
struct OriginalContentBatchFailure: Error {
    let executionError: Error?
    let publicationError: Error?
    let verifiedSavedIndexes: [Int]
}
