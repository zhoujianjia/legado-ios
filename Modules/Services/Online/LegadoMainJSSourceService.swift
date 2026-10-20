import CryptoKit
import Foundation
import LegadoRuntime
import Darwin

/// One process owns the JVM. Resolving resources and starting it remain lazy and off main.
actor LegadoRuntimeProcess {
    static let shared = LegadoRuntimeProcess()
    private var runtime: LegadoRuntime?
    private var stateHost: LegadoPersistentStateHost?

    private func persistentHost() -> LegadoPersistentStateHost {
        if let stateHost { return stateHost }
        let value = LegadoPersistentStateHost(backing: AppLegadoOwnedStateBacking(
            sources: .shared, login: .shared))
        stateHost = value
        return value
    }

    /// Embedders must pass an immutable source revision and then explicitly put
    /// the returned grant in session options. This does not select an App route
    /// or infer the UUID of a shelf book from a URL.
    func bindPersistentSource(sourceURL: String, sourceRevision: String) async throws -> String {
        try await persistentHost().bind(sourceURL: sourceURL, sourceRevision: sourceRevision)
    }

    func revokePersistentSource(owner: String) async {
        await persistentHost().revoke(owner: owner)
    }

    /// Explicit embedding seam for the retained traditional runtime. The App must pass
    /// its existing BookStore instance and identities; this does not select a reader route.
    func bindPersistentBook(sourceURL: String, sourceRevision: String, store: BookStore,
                            bookID: UUID, sourceID: UUID, bookURL: String,
                            chapter: OnlineChapterRef? = nil,
                            generation: OriginalRuntimeChapterGeneration? = nil,
                            callbackTaskID: String? = nil) async throws -> String {
        try await persistentHost().bindBook(sourceURL: sourceURL, sourceRevision: sourceRevision,
            store: store, bookID: bookID, sourceID: sourceID, bookURL: bookURL,
            chapter: chapter, generation: generation, callbackTaskID: callbackTaskID)
    }

    func bindPersistentContentBatch(_ request: LegadoContentBatchExecutionRequest) async throws -> String {
        try await persistentHost().bindContentBatch(sourceURL: request.sourceURL, sourceRevision: request.sourceRevision,
            taskID: request.taskID, store: request.store, bookID: request.bookID, sourceID: request.sourceID,
            book: request.book, chapters: request.chapters, deadline: request.deadline, cache: request.cache,
            singleChapter: request.singleChapter)
    }

    func finishContentBatchResult(owner: String, request: LegadoContentBatchExecutionRequest, book: LegadoOriginalBook) async throws -> Bool {
        try await persistentHost().finishContentBatchResult(owner: owner, taskID: request.taskID, book: book, deadline: request.deadline)
    }

    func finishSingleContentResult(owner: String, request: LegadoContentBatchExecutionRequest,
                                   result: LegadoOriginalContentResult) async throws -> [String] {
        try await persistentHost().finishSingleContentResult(owner: owner, taskID: request.taskID,
            result: result, deadline: request.deadline)
    }

    func bindPersistentPreview(grant: OriginalRuntimePreviewGrant) async throws -> String {
        try await persistentHost().bindPreview(grant: grant)
    }

    func executor() throws -> LegadoRuntime {
        if let runtime { return runtime }
        return try SourcePerfTrace.span("legado.process.configure", "main=\(Thread.isMainThread)") {
            let configuration = LegadoRuntime.Configuration.bundled()
            let diagnostics = LegadoRuntime.diagnose(configuration: configuration)
            guard diagnostics.available, let configuration else {
                throw LegadoRuntimeError(code: "MISSING_RUNTIME", message: diagnostics.issues.joined(separator: "; "))
            }
            let value = LegadoRuntime(configuration: configuration, host: persistentHost())
            runtime = value
            return value
        }
    }
}

/// Created only after the existing context owner validates a real record. Imported
/// reference JSON is an identifier, never a Host grant. The bounded completion proof
/// follows this task's accepted Host commits, so an old result cannot overwrite them.
final class OriginalRuntimePreviewGrant: @unchecked Sendable {
    let taskID = UUID().uuidString
    let service: LegadoMainJSSourceService
    let sourceID: UUID
    let sourceURL: String
    let sourceRevision: String
    let recordID: String
    let bookURL: String
    let chapterURL: String?
    let chapterIndex: Int32?
    let discoveringChapters: Bool
    private let expiresAt: Date
    private let lifetime = OriginalRuntimeCommitCancellation()
    private let lock = NSLock()
    private var expected: (revision: UInt64, sha256: String)
    private var completed = false

    fileprivate init(service: LegadoMainJSSourceService, sourceID: UUID, sourceURL: String,
                     sourceRevision: String, recordID: String, bookURL: String,
                     chapter: LegadoOriginalChapter?, discoveringChapters: Bool, expiresAt: Date,
                     revision: UInt64, sha256: String) {
        self.service = service; self.sourceID = sourceID; self.sourceURL = sourceURL
        self.sourceRevision = sourceRevision; self.recordID = recordID; self.bookURL = bookURL
        self.chapterURL = chapter?.url; self.chapterIndex = chapter?.index
        self.discoveringChapters = discoveringChapters
        self.expiresAt = expiresAt
        self.expected = (revision, sha256)
    }
    func revoke() { lifetime.cancel() }
    func check(deadline: Date) throws { try lifetime.check(deadline: min(deadline, expiresAt)) }
    fileprivate func accepted(revision: UInt64, sha256: String) {
        lock.lock(); defer { lock.unlock() }
        expected = (revision, sha256)
    }
    /// Called by the trusted executor after the actual business call and session close,
    /// before its normal Host revocation. A revoked/cancelled execution cannot seal this.
    func sealExecution(deadline: Date) throws {
        try Task.checkCancellation(); try check(deadline: deadline)
        lock.lock(); defer { lock.unlock() }
        completed = true
    }
    fileprivate func completion() throws -> (revision: UInt64, sha256: String) {
        lock.lock(); defer { lock.unlock() }
        guard completed else { throw LegadoRuntimeError(code: "INVALID_STATE_OWNER", message: "Preview execution has no completion proof") }
        return expected
    }
}

/// Original Room-style TOC metadata proof in the existing preview context file.
/// It carries no App UUID/generation/body-save permission.
struct LegadoPreviewTOCStateSnapshot: Sendable {
    let recordID: String
    let revision: UInt64
    let rawSHA256: String
    let wire: String
    let value: Data?
}

struct LegadoOriginalExplorePauseReport: Sendable {
    struct Failure: Sendable {
        let sourceID: UUID
        let code: String
        let completedEffects: [String]
    }
    /// Successful savePending replies; an already-clean or evicted map causes no write.
    let acknowledgedSourceIDs: [UUID]
    let failures: [Failure]
}

struct LegadoOriginalPreviewTransferReceipt: Sendable {
    let recordID: String
    let bookID: UUID
    let sourceID: UUID
    let bookURL: String
    fileprivate init(recordID: String, bookID: UUID, sourceID: UUID, bookURL: String) {
        self.recordID = recordID; self.bookID = bookID; self.sourceID = sourceID; self.bookURL = bookURL
    }
}

protocol LegadoMainJSExecuting: Sendable {
    func createSession(sourceJSON: String) async throws -> String
    func execute(sessionID: String, operation: String, requestJSON: String) async throws -> String
    func closeSession(id: String) async throws
}

struct NativeLegadoMainJSExecutor: LegadoMainJSExecuting {
    func createSession(sourceJSON: String) async throws -> String {
        let runtime = try await LegadoRuntimeProcess.shared.executor()
        return try await runtime.createSession(sourceJSON: sourceJSON, options: .init(httpTransport: .jvmOkHttp)).id
    }
    func execute(sessionID: String, operation: String, requestJSON: String) async throws -> String {
        let runtime = try await LegadoRuntimeProcess.shared.executor()
        return try await runtime.execute(session: .init(id: sessionID), operation: operation, requestJSON: requestJSON)
    }
    func closeSession(id: String) async throws {
        let runtime = try await LegadoRuntimeProcess.shared.executor()
        try await runtime.close(session: .init(id: id))
    }
}

/// The product mainJs route. No JSC, platform-HTTP or legacy-cache fallback lives here.
/// Immutable book records preserve the complete JVM DTO once per revision, rather than
/// duplicating potentially large infoHtml/tocHtml in every persisted chapter.
actor LegadoMainJSSourceService {
    static let contextKey = "__legado.jvm.mainJs.context.v1"
    private let executor: any LegadoMainJSExecuting
    private let contentBatchExecutor: any LegadoOriginalContentBatchExecuting
    private let originalExecutor: any LegadoOriginalPreviewExecuting
    private var originalSourceRevisions: [String: (signature: String, clock: Int64)] = [:]
    /// Only immutable source identities for contexts actually opened here. The Java
    /// InfoMap remains solely in OriginalExploreContexts' process LRU(99).
    private struct OpenOriginalExploreSource {
        let sourceID: UUID
        let sourceURL: String
        let signature: String
        var access: UInt64
    }
    private var openOriginalExploreSources: [String: OpenOriginalExploreSource] = [:]
    private var originalExploreAccess: UInt64 = 0
    private let configuredDirectory: URL?
    private let operationTimeout: TimeInterval
    private var preparedDirectory: URL?
    private struct Session { let id: String; let signature: String; let clock: Int64 }
    private var sessions: [String: Session] = [:]
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
        let deadlineTask: Task<Void, Never>
    }
    private var busy: Set<String> = []
    private var waiters: [String: [Waiter]] = [:]

    private struct BookRecord: Codable {
        let version: Int
        let sourceID: UUID
        let sourceURL: String
        let sourceSignature: String
        let bookJSON: String
    }
    private struct ContextReference: Codable {
        let version: Int
        let sourceID: UUID
        let sourceURL: String
        let sourceSignature: String
        let bookRecordID: String
        let bookURL: String
        var chapterJSON: String?
        var nextChapterURL: String?
    }

    init(executor: any LegadoMainJSExecuting = NativeLegadoMainJSExecutor(), contextDirectory: URL? = nil,
         operationTimeout: TimeInterval = 60,
         originalExecutor: any LegadoOriginalPreviewExecuting = NativeLegadoOriginalPreviewExecutor(),
         contentBatchExecutor: any LegadoOriginalContentBatchExecuting = NativeLegadoOriginalContentBatchExecutor()) {
        self.executor = executor
        self.originalExecutor = originalExecutor
        self.contentBatchExecutor = contentBatchExecutor
        self.configuredDirectory = contextDirectory
        self.operationTimeout = operationTimeout
    }

    func search(query: String, page: Int, source: BookSource) async throws -> [OnlineBook] {
        let signature = try validate(source)
        let raw = try await perform(source: source, signature: signature, operation: "search", input: ["key": query, "page": page])
        guard let books = raw as? [[String: Any]] else { throw failure("INVALID_RESULT", "search must return an array of books") }
        return try books.map { book in
            try requireTextBook(book)
            let reference = try saveBook(book, source: source, signature: signature)
            return try onlineBook(book, source: source, variables: variables(reference, merging: nil))
        }
    }

    func explore(url: String, page: Int, source: BookSource) async throws -> [OnlineBook] {
        let signature = try validate(source)
        let raw = try await perform(source: source, signature: signature, operation: "explore", input: ["url": url, "page": page])
        guard let books = raw as? [[String: Any]] else { throw failure("INVALID_RESULT", "explore must return an array of books") }
        return try books.map { book in
            try requireTextBook(book)
            let reference = try saveBook(book, source: source, signature: signature)
            return try onlineBook(book, source: source, variables: variables(reference, merging: nil))
        }
    }

    func evaluateMainJSExplore(script: String, page: Int, source: BookSource) async throws -> String {
        let signature = try validate(source)
        let result = try await perform(source: source, signature: signature, operation: "evaluate", input: ["script": script, "page": page])
        if let result = result as? String { return result }
        return String(decoding: try JSONSerialization.data(withJSONObject: result,
            options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    func details(url: String, source: BookSource, runtimeVariables: [String: String]?, knownBook: OnlineBook?) async throws -> BookInfoPackage {
        let signature = try validate(source)
        let variables = runtimeVariables ?? knownBook?.runtimeVariables
        let reference = try context(variables, source: source, signature: signature)
        guard reference.bookURL == url else { throw failure("CONTEXT_MISMATCH", "Details URL does not match the saved JVM book") }
        let book = try loadBook(reference, source: source, signature: signature)
        let result = try await perform(source: source, signature: signature, operation: "details", input: ["book": book])
        guard let detailed = result as? [String: Any] else { throw failure("INVALID_RESULT", "details must return a book object") }
        try requireTextBook(detailed)
        guard try string(detailed, "bookUrl") == reference.bookURL else { throw failure("CONTEXT_MISMATCH", "details changed book identity") }
        let updated = try saveBook(detailed, source: source, signature: signature)
        let display = try onlineBook(detailed, source: source, variables: self.variables(updated, merging: variables))
        return BookInfoPackage(sourceId: source.id, sourceName: source.bookSourceName, bookURL: display.bookUrl,
            name: display.name, author: display.author, intro: display.intro, coverUrl: display.coverUrl,
            tocUrl: display.tocUrl, wordCount: display.wordCount, lastChapter: display.lastChapter, kind: display.kind,
            runtimeVariables: display.runtimeVariables, rawHTMLFilename: nil, savedAt: Date())
    }

    func toc(url: String, source: BookSource, runtimeVariables: [String: String]?) async throws -> TOCPackage {
        let signature = try validate(source)
        let reference = try context(runtimeVariables, source: source, signature: signature)
        let book = try loadBook(reference, source: source, signature: signature)
        guard try string(book, "tocUrl") == url else { throw failure("CONTEXT_MISMATCH", "TOC URL does not match the saved JVM book") }
        let raw = try await perform(source: source, signature: signature, operation: "toc", input: ["book": book])
        guard let chapters = raw as? [[String: Any]] else { throw failure("INVALID_RESULT", "toc must return an array of chapters") }
        let refs = try chapters.enumerated().map { index, chapter -> OnlineChapterRef in
            let chapterURL = try string(chapter, "url")
            guard !chapterURL.isEmpty, (chapter["index"] as? NSNumber)?.intValue == index,
                  try string(chapter, "bookUrl") == reference.bookURL else {
                throw failure("INVALID_RESULT", "Chapter identity or index does not match the JVM TOC")
            }
            var chapterReference = reference
            chapterReference.chapterJSON = try json(chapter)
            chapterReference.nextChapterURL = index + 1 < chapters.count ? try string(chapters[index + 1], "url") : nil
            return OnlineChapterRef(index: index, title: try string(chapter, "title"), url: chapterURL,
                isVolume: chapter["isVolume"] as? Bool ?? false,
                isVip: chapter["isVip"] as? Bool ?? false, isPay: chapter["isPay"] as? Bool ?? false,
                runtimeVariables: try variables(chapterReference, merging: nil))
        }
        return TOCPackage(sourceId: source.id, sourceName: source.bookSourceName, tocURL: url,
            runtimeVariables: try variables(reference, merging: runtimeVariables), chapters: refs,
            rawHTMLFilename: nil, savedAt: Date())
    }

    func content(ref: OnlineChapterRef, source: BookSource) async throws -> String {
        let signature = try validate(source)
        let reference = try context(ref.runtimeVariables, source: source, signature: signature)
        let book = try loadBook(reference, source: source, signature: signature)
        guard let chapterJSON = reference.chapterJSON else { throw failure("CONTEXT_MISSING", "Chapter has no saved JVM DTO") }
        let chapter = try object(chapterJSON)
        guard try string(chapter, "url") == ref.url, try string(chapter, "bookUrl") == reference.bookURL,
              (chapter["index"] as? NSNumber)?.intValue == ref.index else {
            throw failure("CONTEXT_MISMATCH", "Chapter does not match its saved JVM DTO")
        }
        let raw = try await perform(source: source, signature: signature, operation: "content",
            input: ["book": book, "chapter": chapter, "nextChapterUrl": reference.nextChapterURL.map { $0 as Any } ?? NSNull()])
        guard let content = raw as? String else { throw failure("UNSUPPORTED_CAPABILITY", "Only String chapter content is integrated") }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FetchError.emptyContent }
        // Plain prose is escaped by the native renderer. Source HTML/media requires a
        // separate original-core integration; never invoke JSC's deferred-image resolver.
        if content.range(of: #"<\s*/?\s*[a-zA-Z!][^>]*>"#, options: .regularExpression) != nil {
            throw failure("UNSUPPORTED_CAPABILITY", "HTML and media chapter content are not integrated")
        }
        return content
    }

    func closeSessions() async throws {
        let deadline = try operationDeadline()
        for key in Array(sessions.keys) {
            try await acquire(key, deadline: deadline)
            do {
                if let session = sessions[key] { try await executor.closeSession(id: session.id); sessions.removeValue(forKey: key) }
                release(key)
            } catch { release(key); throw error }
        }
    }

    private func validate(_ source: BookSource) throws -> String {
        guard source.isJsSource, source.bookSourceType == 0 else {
            throw failure("UNSUPPORTED_CAPABILITY", "The JVM app route currently supports text mainJs sources only")
        }
        var stable = source
        stable.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        stable.lastUpdateTime = 0
        stable.respondTime = 180000 // A health measurement does not revise source code.
        return digest(try encoded(stable))
    }

    private func perform(source: BookSource, signature: String, operation: String, input: [String: Any]) async throws -> Any {
        let deadline = try operationDeadline()
        let key = source.bookSourceUrl
        try await acquire(key, deadline: deadline)
        defer { release(key) }
        return try await SourcePerfTrace.spanAsync("legado.mainJs.\(operation)", "main=\(Thread.isMainThread) sourceBytes=\(source.mainJs?.utf8.count ?? 0)") {
            try Task.checkCancellation()
            if let previous = sessions[key], previous.signature != signature {
                guard source.lastUpdateTime >= previous.clock else { throw failure("SOURCE_CHANGED", "A newer source session is already active") }
                try await executor.closeSession(id: previous.id)
                sessions.removeValue(forKey: key)
            } else if let previous = sessions[key], source.lastUpdateTime > previous.clock {
                // An unchanged source may arrive with a newer sync clock. Keep that
                // high-water mark so a delayed, different revision cannot replace it.
                sessions[key] = Session(id: previous.id, signature: previous.signature, clock: source.lastUpdateTime)
            }
            if sessions[key] == nil {
                let sourceJSON = String(decoding: try encoded(source), as: UTF8.self)
                let id = try await executor.createSession(sourceJSON: sourceJSON)
                sessions[key] = Session(id: id, signature: signature, clock: source.lastUpdateTime)
            }
            try Task.checkCancellation()
            let remaining = Int(deadline.timeIntervalSinceNow * 1000)
            guard remaining > 0 else { throw failure("TIMEOUT", "Source operation expired while queued") }
            var request = input
            request["timeoutMs"] = remaining
            let response = try await executor.execute(sessionID: sessions[key]!.id, operation: operation, requestJSON: json(request))
            try Task.checkCancellation()
            guard deadline.timeIntervalSinceNow > 0 else { throw failure("TIMEOUT", "Source operation exceeded its absolute deadline") }
            let envelope = try object(response)
            guard envelope["ok"] as? Bool == true else {
                let error = envelope["error"] as? [String: Any]
                throw failure(error?["code"] as? String ?? "INVALID_RESPONSE", error?["message"] as? String ?? "JVM operation failed")
            }
            guard let result = envelope["result"] else { throw failure("INVALID_RESPONSE", "JVM response omitted result") }
            return result
        }
    }

    private func operationDeadline() throws -> Date {
        guard operationTimeout.isFinite, operationTimeout > 0, operationTimeout <= 300 else {
            throw failure("INVALID_ARGUMENT", "Operation timeout must be between zero and 300 seconds")
        }
        return Date().addingTimeInterval(operationTimeout)
    }

    private func acquire(_ key: String, deadline: Date) async throws {
        try Task.checkCancellation()
        guard deadline.timeIntervalSinceNow > 0 else { throw failure("TIMEOUT", "Source operation expired while queued") }
        if busy.insert(key).inserted { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let deadlineTask: Task<Void, Never> = Task { [weak self] in
                    // A real deadline timer, independent of the lock holder's progress.
                    // The holder may still be blocked when this waiter must time out.
                    let nanoseconds = UInt64(max(0, deadline.timeIntervalSinceNow) * 1_000_000_000)
                    do { try await Task.sleep(nanoseconds: nanoseconds) }
                    catch { return } // Acquired/cancelled waiters cancel their timer.
                    await self?.timeoutWaiter(id, key: key)
                }
                waiters[key, default: []].append(Waiter(id: id, continuation: continuation, deadlineTask: deadlineTask))
            }
        } onCancel: { Task { await self.cancelWaiter(id, key: key) } }
        if Task.isCancelled { release(key); throw CancellationError() }
        if deadline.timeIntervalSinceNow <= 0 {
            release(key)
            throw failure("TIMEOUT", "Source operation expired while queued")
        }
    }
    private func cancelWaiter(_ id: UUID, key: String) {
        finishWaiter(id, key: key, error: CancellationError())
    }
    private func timeoutWaiter(_ id: UUID, key: String) {
        finishWaiter(id, key: key, error: failure("TIMEOUT", "Source operation expired while queued"))
    }
    private func finishWaiter(_ id: UUID, key: String, error: Error) {
        guard let index = waiters[key]?.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters[key]!.remove(at: index)
        waiter.deadlineTask.cancel()
        waiter.continuation.resume(throwing: error)
    }
    private func release(_ key: String) {
        if var queue = waiters[key], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[key] = queue
            next.deadlineTask.cancel()
            next.continuation.resume()
        } else { waiters.removeValue(forKey: key); busy.remove(key) }
    }

    private func saveBook(_ book: [String: Any], source: BookSource, signature: String) throws -> ContextReference {
        let url = try string(book, "bookUrl")
        guard !url.isEmpty else { throw failure("INVALID_RESULT", "JVM bookUrl is empty") }
        let record = BookRecord(version: 1, sourceID: source.id, sourceURL: source.bookSourceUrl,
            sourceSignature: signature, bookJSON: try json(book))
        let bytes = try encoded(record)
        let id = digest(bytes)
        try SourcePerfTrace.span("legado.mainJs.context.save", "main=\(Thread.isMainThread) bytes=\(bytes.count)") {
            let path = try directory().appendingPathComponent(id + ".json", isDirectory: false)
            if FileManager.default.fileExists(atPath: path.path) {
                guard digest(try Data(contentsOf: path)) == id else { throw failure("CONTEXT_CORRUPT", "Saved JVM book record hash differs") }
            } else { try bytes.write(to: path, options: .atomic) }
        }
        return ContextReference(version: 1, sourceID: source.id, sourceURL: source.bookSourceUrl,
            sourceSignature: signature, bookRecordID: id, bookURL: url)
    }

    private func context(_ variables: [String: String]?, source: BookSource, signature: String) throws -> ContextReference {
        guard let raw = variables?[Self.contextKey] else { throw failure("CONTEXT_MISSING", "Original JVM book context is required; search this source again") }
        let reference: ContextReference
        do { reference = try JSONDecoder().decode(ContextReference.self, from: Data(raw.utf8)) }
        catch { throw failure("CONTEXT_CORRUPT", "Invalid JVM context reference: \(error.localizedDescription)") }
        guard reference.version == 1, reference.sourceID == source.id, reference.sourceURL == source.bookSourceUrl,
              reference.sourceSignature == signature else { throw failure("CONTEXT_MISMATCH", "JVM context belongs to another source revision") }
        guard reference.bookRecordID.utf8.count == 64,
              reference.bookRecordID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw failure("CONTEXT_CORRUPT", "Invalid JVM book record identifier")
        }
        return reference
    }

    private func loadBook(_ reference: ContextReference, source: BookSource, signature: String) throws -> [String: Any] {
        let path = try directory().appendingPathComponent(reference.bookRecordID + ".json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: path.path) else { throw failure("CONTEXT_MISSING", "Saved JVM book record is absent") }
        let bytes = try Data(contentsOf: path)
        guard digest(bytes) == reference.bookRecordID else { throw failure("CONTEXT_CORRUPT", "Saved JVM book record hash differs") }
        let record = try JSONDecoder().decode(BookRecord.self, from: bytes)
        guard record.version == 1, record.sourceID == source.id, record.sourceURL == source.bookSourceUrl,
              record.sourceSignature == signature else { throw failure("CONTEXT_MISMATCH", "Saved JVM book record belongs to another source revision") }
        let book = try object(record.bookJSON)
        guard try string(book, "bookUrl") == reference.bookURL else { throw failure("CONTEXT_CORRUPT", "Saved JVM book identity differs") }
        try requireTextBook(book)
        return book
    }

    private func variables(_ reference: ContextReference, merging previous: [String: String]?) throws -> [String: String] {
        var result = previous ?? [:]
        result[Self.contextKey] = String(decoding: try encoded(reference), as: UTF8.self)
        return result
    }
    private func onlineBook(_ book: [String: Any], source: BookSource, variables: [String: String]) throws -> OnlineBook {
        OnlineBook(name: try string(book, "name"), author: try string(book, "author"), intro: try string(book, "intro"),
            coverUrl: try string(book, "coverUrl"), bookUrl: try string(book, "bookUrl"), tocUrl: try string(book, "tocUrl"),
            wordCount: try string(book, "wordCount"), lastChapter: try string(book, "latestChapterTitle"), kind: try string(book, "kind"),
            sourceId: source.id, sourceName: source.bookSourceName, runtimeVariables: variables)
    }
    private func requireTextBook(_ book: [String: Any]) throws {
        guard let type = book["type"] as? NSNumber, (type.intValue & 236) == 8 else {
            throw failure("UNSUPPORTED_CAPABILITY", "Only text JVM book DTOs are integrated")
        }
    }
    private func directory() throws -> URL {
        if let preparedDirectory { return preparedDirectory }
        let url = configuredDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LegadoMainJSContexts", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        preparedDirectory = url
        return url
    }
    private func encoded<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
    private func object(_ json: String) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw failure("INVALID_RESPONSE", "Expected a JSON object")
        }
        return value
    }
    private func string(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key], !(value is NSNull) else { return "" }
        guard let text = value as? String else { throw failure("INVALID_RESULT", "JVM field \(key) is not a string") }
        return text
    }
    private func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func failure(_ code: String, _ message: String) -> LegadoRuntimeError { .init(code: code, message: message) }
}

// Explicit opt-in original preview. This extends the existing context actor and file
// category; immutable v1 mainJs records and the App's default Fetcher route stay intact.
extension LegadoMainJSSourceService {
    static let originalPreviewContextKey = "__legado.jvm.original.preview.v2"

    private enum PreviewStatus: String, Codable { case active, transferring, transferred, revoked }
    private struct PreviewRecord: Codable {
        let version: Int
        let nonce: UUID
        let sourceID: UUID
        let sourceURL: String
        let sourceSignature: String
        var revision: UInt64
        var status: PreviewStatus
        var transferBookID: UUID?
        var book: LegadoOriginalBook
        var chapters: [LegadoOriginalChapter]
        var originalTOC: [LegadoOriginalChapter]?
        var ephemeralStoredMetadata: Bool? = nil
        var chapterIDs: [UUID] = []
        var bookLargeVariables: [String: String] = [:]
        var chapterVariables: [String: [String: String]] = [:]
        var chapterLargeVariables: [String: [String: String]] = [:]
    }
    private struct PreviewIdentity: Encodable {
        let version: Int
        let nonce: UUID
        let sourceID: UUID
        let sourceURL: String
        let sourceSignature: String
        let bookURL: String
    }
    private struct PreviewChapterReference: Codable {
        let url: String
        let index: Int32
    }
    private struct PreviewRead {
        var record: PreviewRecord
        let raw: Data
        let sha256: String
    }

    /// A new read-only metadata preview may start from a known public book value.
    /// It owns only this actor's isolated file; it grants no shelf UUID/body writes.
    /// Existing context identifiers must validate before any fork or reuse.
    func prepareOriginalBookPreview(url: String, source: BookSource,
                                    runtimeVariables: [String: String]?, knownBook: OnlineBook?,
                                    storedChapters: [OnlineChapterRef]? = nil) async throws -> [String: String] {
        let signature = try originalSignature(source); let deadline = try operationDeadline()
        try await acquire(source.bookSourceUrl, deadline: deadline)
        defer { release(source.bookSourceUrl) }
        try acceptOriginalRevision(source, signature: signature)
        let previous = runtimeVariables ?? knownBook?.runtimeVariables
        if storedChapters == nil, previous?[Self.originalPreviewContextKey] != nil {
            let reference = try previewContext(previous, source: source, signature: signature)
            guard LegadoPreviewIdentity.same(reference.bookURL, url) else { throw failure("CONTEXT_MISMATCH", "Known book URL differs from its original preview") }
            let read = try readPreview(reference, requireActive: false)
            if read.record.status == .active {
                return try previewVariables(read.record, reference: reference, previous: previous)
            }
            guard read.record.status == .transferred else { throw failure("STATE_CONFLICT", "Original preview handoff is pending or revoked") }
        }
        if let knownBook {
            guard knownBook.sourceId == source.id, LegadoPreviewIdentity.same(knownBook.bookUrl, url) else {
                throw failure("CONTEXT_MISMATCH", "Known metadata belongs to another book/source")
            }
        }
        let values = (previous ?? [:]).filter { $0.key != Self.originalPreviewContextKey }
        try LegadoPreviewVariableCodec.validateRepresentable([values])
        var book = LegadoOriginalBook(bookURL: url, origin: source.bookSourceUrl,
            name: knownBook?.name ?? "", author: knownBook?.author ?? "", tocURL: knownBook?.tocUrl ?? "")
        book.coverURL = knownBook?.coverUrl; book.intro = knownBook?.intro
        book.kind = knownBook?.kind; book.wordCount = knownBook?.wordCount
        book.latestChapterTitle = knownBook?.lastChapter; book.originName = source.bookSourceName
        book.variable = String(decoding: try encoded(values.filter { $0.value.utf16.count < 10_000 }), as: UTF8.self)
        try validateOriginalBook(book, sourceURL: source.bookSourceUrl)
        var record = PreviewRecord(version: 2, nonce: UUID(), sourceID: source.id, sourceURL: source.bookSourceUrl,
            sourceSignature: signature, revision: 0, status: .active, book: book, chapters: [])
        record.bookLargeVariables = values.filter { $0.value.utf16.count >= 10_000 }
        if let storedChapters {
            record.ephemeralStoredMetadata = true
            guard storedChapters.count <= 20_000 else { throw failure("STATE_LIMIT", "Stored preview TOC exceeds its chapter budget") }
            var urls = Set<Data>()
            for (offset, ref) in storedChapters.enumerated() {
                guard ref.index == offset, let index = Int32(exactly: offset),
                      !ref.url.isEmpty, urls.insert(Data(ref.url.utf8)).inserted else {
                    throw failure("UNSUPPORTED_CAPABILITY", "Stored TOC cannot map to the original unique URL/index identity")
                }
                let variables = (ref.runtimeVariables ?? [:]).filter { $0.key != Self.originalPreviewContextKey }
                try LegadoPreviewVariableCodec.validateRepresentable([variables])
                var chapter = LegadoOriginalChapter(bookURL: url, url: ref.url, index: index,
                    title: ref.title, baseURL: book.tocURL)
                chapter.isVolume = ref.isVolume; chapter.isVip = ref.isVip; chapter.isPay = ref.isPay
                let small = variables.filter { $0.value.utf16.count < 10_000 }
                chapter.variable = String(decoding: try encoded(small), as: UTF8.self)
                record.chapters.append(chapter); record.chapterIDs.append(ref.id)
                record.chapterVariables[LegadoPreviewIdentity.key(ref.url)] = small
                record.chapterLargeVariables[LegadoPreviewIdentity.key(ref.url)] = variables.filter { $0.value.utf16.count >= 10_000 }
            }
            record.originalTOC = record.chapters
        }
        let id = try previewID(record)
        try writePreview(try encoded(record), id: id, deadline: deadline)
        return try previewVariables(record, reference: previewReference(record, id: id), previous: previous)
    }

    func originalSearch(query: String, page: Int32? = 1, source: BookSource) async throws -> [OnlineBook] {
        let signature = try originalSignature(source); let deadline = try operationDeadline()
        try await acquire(source.bookSourceUrl, deadline: deadline)
        defer { release(source.bookSourceUrl) }
        try acceptOriginalRevision(source, signature: signature)
        let result = try await originalExecutor.execute(sourceJSON: String(decoding: try encoded(source), as: UTF8.self),
            sourceURL: source.bookSourceUrl, sourceRevision: signature, grant: nil,
            operation: .search(query, page), deadline: deadline)
        try previewCheck(deadline)
        guard case .search(let books) = result, books.count <= 2_000 else { throw failure("INVALID_RESULT", "Original search must return bounded books") }
        return try books.map { book in
            try validateOriginalBook(book, sourceURL: source.bookSourceUrl)
            let record = PreviewRecord(version: 2, nonce: UUID(), sourceID: source.id,
                sourceURL: source.bookSourceUrl, sourceSignature: signature, revision: 0,
                status: .active, book: book, chapters: [])
            let id = try previewID(record)
            let bytes = try encoded(record)
            try writePreview(bytes, id: id, deadline: deadline)
            let reference = previewReference(record, id: id)
            return try previewOnlineBook(record, reference: reference, previous: nil, source: source)
        }
    }

    /// Explicit navigation seam: explore does not implicitly open its InfoMap, matching
    /// WebBook. The returned book keeps the same owned preview record as search.
    func originalExplore(url: String, page: Int32? = 1, source: BookSource) async throws -> [OnlineBook] {
        let signature = try originalSignature(source); let deadline = try operationDeadline()
        try await acquire(source.bookSourceUrl, deadline: deadline)
        defer { release(source.bookSourceUrl) }
        try acceptOriginalRevision(source, signature: signature)
        let result = try await originalExecutor.execute(sourceJSON: String(decoding: try encoded(source), as: UTF8.self),
            sourceURL: source.bookSourceUrl, sourceRevision: signature, grant: nil,
            operation: .explore(url, page), deadline: deadline)
        try previewCheck(deadline)
        touchOriginalExploreSource(source, signature: signature, register: false)
        guard case .explore(let books) = result, books.count <= 2_000 else { throw failure("INVALID_RESULT", "Original explore must return bounded books") }
        return try books.map { book in
            try validateOriginalBook(book, sourceURL: source.bookSourceUrl)
            let record = PreviewRecord(version: 2, nonce: UUID(), sourceID: source.id,
                sourceURL: source.bookSourceUrl, sourceSignature: signature, revision: 0,
                status: .active, book: book, chapters: [])
            let id = try previewID(record)
            try writePreview(try encoded(record), id: id, deadline: deadline)
            return try previewOnlineBook(record, reference: previewReference(record, id: id), previous: nil, source: source)
        }
    }

    func openOriginalExploreContext(source: BookSource) async throws -> LegadoOriginalExploreContextResult {
        try await performOriginalExploreContext(source: source, operation: .openExploreContext)
    }

    func evaluateOriginalExploreContext(script: String, source: BookSource) async throws -> LegadoOriginalExploreContextResult {
        guard script.utf8.count <= 1_048_576 else { throw failure("STATE_LIMIT", "Original exploration expression exceeds its byte budget") }
        return try await performOriginalExploreContext(source: source, operation: .evaluateExploreContext(script))
    }

    /// Page pause/close persists only this existing context. It does not remove the
    /// process context: returning to a category must retain its unsaved in-memory map.
    func savePendingOriginalExploreContext(source: BookSource) async throws -> LegadoOriginalExploreContextResult {
        try await performOriginalExploreContext(source: source, operation: .savePendingExploreContext)
    }

    private func performOriginalExploreContext(source: BookSource, operation: LegadoOriginalPreviewOperation,
                                               absoluteDeadline: Date? = nil) async throws -> LegadoOriginalExploreContextResult {
        let signature = try originalSignature(source)
        let deadline = try absoluteDeadline ?? operationDeadline()
        try await acquire(source.bookSourceUrl, deadline: deadline)
        defer { release(source.bookSourceUrl) }
        try acceptOriginalRevision(source, signature: signature)
        let result = try await SourcePerfTrace.spanAsync("legado.original.explore.context", "main=\(Thread.isMainThread) sourceBytes=\(source.exploreUrl.utf8.count)") {
            try await originalExecutor.execute(sourceJSON: String(decoding: try encoded(source), as: UTF8.self),
                sourceURL: source.bookSourceUrl, sourceRevision: signature, grant: nil, operation: operation, deadline: deadline)
        }
        try previewCheck(deadline)
        guard case .exploreContext(let value) = result else { throw failure("INVALID_RESULT", "Original exploration context omitted its result") }
        if case .savePendingExploreContext = operation, value.needSave {
            throw failure("STATE_IO", "Original exploration context did not acknowledge its pending save")
        }
        let register: Bool
        if case .openExploreContext = operation {
            guard value.infoMap != nil else { throw failure("INVALID_RESULT", "Opened original exploration context omitted its map") }
            register = true
        } else { register = false }
        // Evaluation/save of an unopened context cannot manufacture a pause registry entry.
        touchOriginalExploreSource(source, signature: signature, register: register)
        return value
    }

    private func touchOriginalExploreSource(_ source: BookSource, signature: String, register: Bool) {
        let key = LegadoPreviewIdentity.key(source.bookSourceUrl)
        guard register || openOriginalExploreSources[key]?.signature == signature else { return }
        originalExploreAccess += 1
        openOriginalExploreSources[key] = .init(sourceID: source.id, sourceURL: source.bookSourceUrl, signature: signature, access: originalExploreAccess)
        // Match the original process lifetime bound. Eviction does not invent a save
        // that upstream did not request, and carries no second copy of InfoMap values.
        if openOriginalExploreSources.count > 99,
           let oldest = openOriginalExploreSources.min(by: { $0.value.access < $1.value.access })?.key {
            openOriginalExploreSources.removeValue(forKey: oldest)
        }
    }

    /// App pause visits every source opened by this actual DI service, including pages
    /// no longer on screen. Resolve by the store's UUID index before granting a write:
    /// a removed or edited source must not silently publish its stale cached snapshot.
    func savePendingOriginalExploreContexts(
        sourceResolver: @escaping @MainActor @Sendable (UUID) -> BookSource? = { BookSourceStore.shared.source(id: $0) }
    ) async throws -> LegadoOriginalExplorePauseReport {
        let opened = openOriginalExploreSources.values.sorted { $0.access < $1.access }
        guard !opened.isEmpty else { return .init(acknowledgedSourceIDs: [], failures: []) }
        let deadline = try operationDeadline()
        return try await SourcePerfTrace.spanAsync("legado.original.explore.pause", "main=\(Thread.isMainThread) sources=\(opened.count)") {
            var acknowledged: [UUID] = []
            var failures: [LegadoOriginalExplorePauseReport.Failure] = []
            for previous in opened {
                try Task.checkCancellation()
                do {
                    guard let source = await sourceResolver(previous.sourceID), source.id == previous.sourceID,
                          LegadoPreviewIdentity.same(source.bookSourceUrl, previous.sourceURL),
                          try originalSignature(source) == previous.signature else {
                        throw failure("SOURCE_CHANGED", "Original exploration source was removed or changed before pause")
                    }
                    _ = try await performOriginalExploreContext(source: source, operation: .savePendingExploreContext, absoluteDeadline: deadline)
                    acknowledged.append(source.id)
                } catch {
                    if error is CancellationError || Task.isCancelled { throw error }
                    let runtime = error as? LegadoRuntimeError
                    failures.append(.init(sourceID: previous.sourceID, code: runtime?.code ?? "STATE_IO",
                        completedEffects: runtime?.completedEffects ?? []))
                    AppLogger.error("Original exploration pending save failed", error: error,
                        context: ["sourceID": previous.sourceID.uuidString])
                    // An individual failed write is never ACKed and cannot prevent the
                    // remaining independent sources from attempting their own save.
                }
            }
            try Task.checkCancellation()
            return .init(acknowledgedSourceIDs: acknowledged, failures: failures)
        }
    }

    func originalDetails(url: String, source: BookSource, runtimeVariables: [String: String]?,
                         knownBook: OnlineBook? = nil) async throws -> BookInfoPackage {
        let signature = try originalSignature(source); let deadline = try operationDeadline()
        try await acquire(source.bookSourceUrl, deadline: deadline)
        defer { release(source.bookSourceUrl) }
        try acceptOriginalRevision(source, signature: signature)
        let previous = runtimeVariables ?? knownBook?.runtimeVariables
        let reference = try previewContext(previous, source: source, signature: signature)
        guard LegadoPreviewIdentity.same(reference.bookURL, url) else { throw failure("CONTEXT_MISMATCH", "Preview details URL changed") }
        let before = try readPreview(reference)
        let grant = try makePreviewGrant(reference, read: before, chapter: nil, deadline: deadline)
        defer { grant.revoke() }
        let result = try await executePreview(source, signature: signature, grant: grant,
            operation: .details(before.record.book), deadline: deadline)
        guard case .details(let book) = result else { throw failure("INVALID_RESULT", "Original details omitted its book") }
        let updated = try finishPreview(reference, grant: grant, book: book, chapters: nil, chapter: nil, deadline: deadline)
        let display = try previewOnlineBook(updated, reference: reference, previous: previous, source: source)
        return BookInfoPackage(sourceId: source.id, sourceName: source.bookSourceName, bookURL: display.bookUrl,
            name: display.name, author: display.author, intro: display.intro, coverUrl: display.coverUrl,
            tocUrl: display.tocUrl, wordCount: display.wordCount, lastChapter: display.lastChapter, kind: display.kind,
            runtimeVariables: display.runtimeVariables, rawHTMLFilename: nil, savedAt: Date())
    }

    func originalTOC(url: String, source: BookSource, runtimeVariables: [String: String]?,
                     runPreUpdateJS: Bool = false) async throws -> TOCPackage {
        let signature = try originalSignature(source); let deadline = try operationDeadline()
        try await acquire(source.bookSourceUrl, deadline: deadline)
        defer { release(source.bookSourceUrl) }
        try acceptOriginalRevision(source, signature: signature)
        let reference = try previewContext(runtimeVariables, source: source, signature: signature)
        let before = try readPreview(reference)
        guard LegadoPreviewIdentity.same(before.record.book.tocURL, url) else { throw failure("CONTEXT_MISMATCH", "Preview TOC URL changed") }
        let grant = try makePreviewGrant(reference, read: before, chapter: nil, discoveringChapters: true, deadline: deadline)
        defer { grant.revoke() }
        let result = try await executePreview(source, signature: signature, grant: grant,
            operation: .toc(before.record.book, runPreUpdateJS: runPreUpdateJS), deadline: deadline)
        guard case .toc(let book, let chapters) = result else { throw failure("INVALID_RESULT", "Original TOC omitted its DTOs") }
        let updated = try finishPreview(reference, grant: grant, book: book, chapters: chapters, chapter: nil, deadline: deadline)
        return try previewTOCPackage(updated, reference: reference, previous: runtimeVariables, source: source)
    }

    /// Current owned preview projection only. Refreshing the source TOC would rerun
    /// original upChapterInfo and may intentionally replace transient title/variables.
    func originalPreviewSnapshot(source: BookSource, runtimeVariables: [String: String]?) async throws -> TOCPackage {
        let signature = try originalSignature(source); let deadline = try operationDeadline()
        try await acquire(source.bookSourceUrl, deadline: deadline)
        defer { release(source.bookSourceUrl) }
        try acceptOriginalRevision(source, signature: signature)
        let reference = try previewContext(runtimeVariables, source: source, signature: signature)
        let read = try readPreview(reference)
        return try previewTOCPackage(read.record, reference: reference, previous: runtimeVariables, source: source)
    }

    private func previewTOCPackage(_ record: PreviewRecord, reference: ContextReference,
                                   previous: [String: String]?, source: BookSource) throws -> TOCPackage {
        let refs = try record.chapters.map { chapter -> OnlineChapterRef in
            var ref = reference
            ref.chapterJSON = String(decoding: try encoded(PreviewChapterReference(url: chapter.url, index: chapter.index)), as: UTF8.self)
            let next = Int(chapter.index) + 1
            ref.nextChapterURL = next < record.chapters.count ? record.chapters[next].url : nil
            return OnlineChapterRef(id: record.chapterIDs[Int(chapter.index)], index: Int(chapter.index), title: chapter.title, url: chapter.url,
                isVolume: chapter.isVolume, isVip: chapter.isVip, isPay: chapter.isPay,
                runtimeVariables: try previewChapterProjection(record, chapter: chapter, reference: ref))
        }
        return TOCPackage(sourceId: source.id, sourceName: source.bookSourceName, tocURL: record.book.tocURL,
            runtimeVariables: try previewVariables(record, reference: reference, previous: previous),
            chapters: refs, rawHTMLFilename: nil, savedAt: Date())
    }

    func originalContent(ref: OnlineChapterRef, source: BookSource) async throws -> String {
        let signature = try originalSignature(source); let deadline = try operationDeadline()
        try await acquire(source.bookSourceUrl, deadline: deadline)
        defer { release(source.bookSourceUrl) }
        try acceptOriginalRevision(source, signature: signature)
        let reference = try previewContext(ref.runtimeVariables, source: source, signature: signature)
        let before = try readPreview(reference)
        guard let raw = reference.chapterJSON else { throw failure("CONTEXT_MISSING", "Preview chapter identity is missing") }
        let identity = try JSONDecoder().decode(PreviewChapterReference.self, from: Data(raw.utf8))
        guard Int(identity.index) == ref.index, LegadoPreviewIdentity.same(identity.url, ref.url), identity.index >= 0,
              Int(identity.index) < before.record.chapters.count else { throw failure("CONTEXT_MISMATCH", "Preview chapter identity changed") }
        var chapter = before.record.chapters[Int(identity.index)]
        if let variables = before.record.chapterVariables[LegadoPreviewIdentity.key(chapter.url)] {
            chapter.variable = String(decoding: try encoded(variables), as: UTF8.self)
        }
        guard LegadoPreviewIdentity.same(chapter.url, ref.url), before.record.chapterIDs[Int(identity.index)] == ref.id else { throw failure("CONTEXT_MISMATCH", "Preview TOC was replaced") }
        let nextIndex = Int(chapter.index) + 1
        let actualNext = nextIndex < before.record.chapters.count ? before.record.chapters[nextIndex].url : nil
        guard LegadoPreviewIdentity.same(reference.nextChapterURL, actualNext) else { throw failure("CONTEXT_MISMATCH", "Preview next chapter identity changed") }
        let grant = try makePreviewGrant(reference, read: before, chapter: chapter, deadline: deadline)
        defer { grant.revoke() }
        let result = try await executePreview(source, signature: signature, grant: grant,
            operation: .content(before.record.book, chapter, nextChapterURL: actualNext), deadline: deadline)
        guard case .content(let book, let returnedChapter, let content) = result else { throw failure("INVALID_RESULT", "Original content omitted its DTOs") }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FetchError.emptyContent }
        if content.range(of: #"<\s*/?\s*[a-zA-Z!][^>]*>"#, options: .regularExpression) != nil {
            throw failure("UNSUPPORTED_CAPABILITY", "Preview HTML and media rendering is not integrated")
        }
        _ = try finishPreview(reference, grant: grant, book: book, chapters: nil, chapter: returnedChapter, deadline: deadline)
        return content
    }

    /// Explicit close survives reopening this same context directory. It does not remove
    /// files or change any library record; pending Host commits then fail their active check.
    func revokeOriginalPreview(source: BookSource, runtimeVariables: [String: String]?) async throws {
        let signature = try originalSignature(source); let deadline = try operationDeadline()
        try await acquire(source.bookSourceUrl, deadline: deadline)
        defer { release(source.bookSourceUrl) }
        let reference = try previewContext(runtimeVariables, source: source, signature: signature)
        var read = try readPreview(reference, requireActive: false)
        guard read.record.status != .transferring && read.record.status != .transferred else {
            throw failure("STATE_CONFLICT", "A preview transfer cannot be revoked as an unowned preview")
        }
        if read.record.status != .revoked {
            read.record.status = .revoked
            try replacePreview(read.record, previous: read, id: reference.bookRecordID, deadline: deadline)
        }
    }

    /// Transfers only to an already existing App UUID/source/URL. The context file first
    /// becomes non-writable; failure retains that retryable intent and the original values.
    /// This is a resumable two-owner handoff, not a claim of cross-file atomicity.
    func transferOriginalPreview(source: BookSource, runtimeVariables: [String: String]?,
                                 to store: BookStore, bookID: UUID) async throws -> LegadoOriginalPreviewTransferReceipt {
        let signature = try originalSignature(source); let deadline = try operationDeadline()
        try await acquire(source.bookSourceUrl, deadline: deadline)
        defer { release(source.bookSourceUrl) }
        try acceptOriginalRevision(source, signature: signature)
        let reference = try previewContext(runtimeVariables, source: source, signature: signature)
        var read = try readPreview(reference, requireActive: false)
        guard read.record.status == .active || read.record.status == .transferring || read.record.status == .transferred,
              read.record.transferBookID == nil || read.record.transferBookID == bookID else {
            throw failure("STATE_CONFLICT", "Preview was revoked or transferred to another App identity")
        }
        guard let view = await store.prepareOriginalRuntimeBookSnapshot(id: bookID, sourceID: source.id, bookURL: reference.bookURL) else {
            throw failure("UNSUPPORTED_CAPABILITY", "Preview transfer requires the existing App record UUID, source and URL")
        }
        guard LegadoPreviewIdentity.same(view.tocURL, read.record.book.tocURL) && LegadoPreviewIdentity.same(view.bookURL, reference.bookURL) else { throw failure("STATE_CONFLICT", "The App TOC identity differs from this preview") }
        let cancellation = OriginalRuntimeCommitCancellation()
        let owned = try await store.originalRuntimeBookVariableSnapshot(bookID: bookID, sourceID: source.id,
            bookURL: reference.bookURL, deadline: deadline, cancellation: cancellation)
        let small = try previewVariableMap(read.record.book.variable) ?? [:]
        guard small.values.allSatisfy({ $0.utf16.count < 10_000 }),
              read.record.bookLargeVariables.values.allSatisfy({ $0.utf16.count >= 10_000 }),
              Set(small.keys).isDisjoint(with: read.record.bookLargeVariables.keys) else {
            throw failure("UNSUPPORTED_CAPABILITY", "This preview variable compartment cannot be represented by the App book owner")
        }
        try LegadoPreviewVariableCodec.validateRepresentable([small, read.record.bookLargeVariables])
        let preview = small.merging(read.record.bookLargeVariables) { first, _ in first }
        var merged = owned.book.variables ?? [:]
        if merged[Self.originalPreviewContextKey] != nil {
            let existingReference = try previewContext(merged, source: source, signature: signature)
            guard existingReference.bookRecordID == reference.bookRecordID else {
                throw failure("STATE_CONFLICT", "The App record carries another existing preview context identity")
            }
        }
        let existing = merged.filter { $0.key != Self.originalPreviewContextKey }
        try LegadoPreviewVariableCodec.validateRepresentable([existing, preview])
        guard existing.allSatisfy({ entry in
            guard let index = preview.index(forKey: entry.key), LegadoPreviewIdentity.same(preview[index].key, entry.key) else { return false }
            return LegadoPreviewIdentity.same(preview[index].value, entry.value)
        }) else {
            throw failure("STATE_CONFLICT", "App variables changed before preview transfer")
        }
        for (key, value) in preview { merged[key] = value }
        // References stop at the preview boundary. Keeping a fresh context nonce
        // in durable book variables would dirty an unchanged 2,000-chapter book
        // on every refresh and expose an implementation key to original rules.
        merged.removeValue(forKey: Self.originalPreviewContextKey)
        // A user action has already created the real App TOC. Require its actual chapter
        // identity and values, including the latest preview commits; never manufacture
        // UUIDs or bypass ChapterFetchManager's generation predicate to patch a mismatch.
        let appChapters = try await store.originalRuntimeChapters(bookID: bookID)
        guard appChapters.count == read.record.chapters.count else {
            throw failure("STATE_CONFLICT", "The App TOC has not received the current preview chapters")
        }
        for (app, chapter) in zip(appChapters, read.record.chapters) {
            let chapterSmall = try read.record.chapterVariables[LegadoPreviewIdentity.key(chapter.url)] ?? previewVariableMap(chapter.variable) ?? [:]
            let chapterLarge = read.record.chapterLargeVariables[LegadoPreviewIdentity.key(chapter.url)] ?? [:]
            guard chapterSmall.values.allSatisfy({ $0.utf16.count < 10_000 }),
                  chapterLarge.values.allSatisfy({ $0.utf16.count >= 10_000 }),
                  Set(chapterSmall.keys).isDisjoint(with: chapterLarge.keys) else {
                throw failure("UNSUPPORTED_CAPABILITY", "This preview variable compartment cannot be represented by the App chapter owner")
            }
            let projected = try previewChapterProjection(read.record, chapter: chapter, reference: reference)
                .filter { $0.key != Self.originalPreviewContextKey }
            guard app.index == Int(chapter.index), LegadoPreviewIdentity.same(app.url, chapter.url),
                  LegadoPreviewVariableCodec.sameMap((app.runtimeVariables ?? [:]).filter({ $0.key != Self.originalPreviewContextKey }), projected) else {
                throw failure("STATE_CONFLICT", "The App chapter owner differs from the latest preview variables")
            }
        }
        try previewCheck(deadline)
        let expectedTOC = read.record.book.tocURL
        let sourceID = source.id; let bookURL = reference.bookURL
        let expectedAppVariables = merged
        let ownedInputVariables = owned.book.variables
        let originalViewVariables = view.variables
        let appIdentityCurrent: @Sendable () -> Bool = {
            guard let current = store.originalRuntimeBookSnapshot(id: bookID, sourceID: sourceID, bookURL: bookURL),
                  LegadoPreviewIdentity.same(current.bookURL, bookURL), LegadoPreviewIdentity.same(current.tocURL, expectedTOC) else { return false }
            let currentChapters = store.chapters(for: bookID) ?? []
            guard LegadoPreviewVariableCodec.sameMap(current.variables, ownedInputVariables)
                    || LegadoPreviewVariableCodec.sameMap(current.variables, originalViewVariables)
                    || LegadoPreviewVariableCodec.sameMap(current.variables, expectedAppVariables) else { return false }
            return currentChapters.count == appChapters.count && zip(currentChapters, appChapters).allSatisfy {
                LegadoPreviewIdentity.sameChapter($0.0, $0.1)
            }
        }
        if read.record.status == .active {
            read.record.status = .transferring; read.record.transferBookID = bookID
            read = try replacePreview(read.record, previous: read, id: reference.bookRecordID, deadline: deadline)
        }
        let committed: Bool
        do {
            committed = try await withTaskCancellationHandler {
                let validate: @Sendable () throws -> Void = {
                    try cancellation.check(deadline: deadline)
                    guard appIdentityCurrent() else { throw LegadoRuntimeError(code: "STATE_CONFLICT", message: "App identity or chapter state changed during preview transfer") }
                }
                if BookStore.RuntimeBookSnapshot.sameVariables(owned.book.variables, merged) {
                    return try await store.validateOriginalRuntimeBookProof(owned, deadline: deadline,
                        cancellation: cancellation, validateGrant: validate)
                }
                return try await store.compareOriginalRuntimeBook(expected: owned, expectedView: view, variables: merged,
                    deadline: deadline, cancellation: cancellation, validateGrant: validate)
            } onCancel: { cancellation.cancel() }
        } catch let error as LegadoRuntimeError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch {
            AppLogger.error("Original preview transfer could not write App metadata", error: error)
            throw failure("STATE_IO", "Preview transfer retained its intent after an App metadata write failure")
        }
        guard committed else { throw failure("STATE_CONFLICT", "App metadata owner changed during preview transfer") }
        guard appIdentityCurrent() else { throw failure("STATE_CONFLICT", "App identity changed after its metadata commit; preview intent remains pending") }
        // No late cancellation pretends the durable App write did not happen. If this
        // final context replacement fails, replay verifies the same App UUID and values.
        read = try readPreview(reference, requireActive: false, check: {})
        guard read.record.status == .transferring || read.record.status == .transferred,
              read.record.transferBookID == bookID else { throw failure("STATE_CONFLICT", "Preview transfer intent changed") }
        if read.record.status != .transferred {
            read.record.status = .transferred
            try replacePreview(read.record, previous: read, id: reference.bookRecordID,
                deadline: Date().addingTimeInterval(operationTimeout), honourCancellation: false)
        }
        if read.record.ephemeralStoredMetadata == true {
            // This reference was never adopted into the real book/chapter maps.
            // Remove only this successfully retired owned metadata context. A
            // failure keeps its non-writable proof and reports the cleanup error.
            do {
                let retired = try readPreview(reference, requireActive: false, check: {})
                guard retired.record.status == .transferred, retired.record.transferBookID == bookID else {
                    throw failure("STATE_CONFLICT", "Retired metadata context changed before cleanup")
                }
                let path = try directory().appendingPathComponent(reference.bookRecordID + ".json")
                if Darwin.unlink(path.path) != 0 { throw failure("STATE_IO", "Retired metadata context could not be removed") }
            } catch { AppLogger.error("Retired original metadata context cleanup failed", error: error) }
        }
        return .init(recordID: reference.bookRecordID, bookID: bookID, sourceID: source.id, bookURL: reference.bookURL)
    }

    // The Host adapter calls directly into this same actor while executePreview awaits
    // JNI. These methods deliberately do not reacquire the operation's source lock.
    func validatePreviewGrant(_ grant: OriginalRuntimePreviewGrant, deadline: Date) throws {
        try grant.check(deadline: deadline)
        _ = try readPreview(grantReference(grant))
    }

    func readPreviewEntity(_ grant: OriginalRuntimePreviewGrant, keys: [LegadoEntityStateKey], deadline: Date,
                           cancellation: OriginalRuntimeCommitCancellation) throws -> LegadoPreviewEntitySnapshot {
        try cancellation.check(deadline: deadline); try grant.check(deadline: deadline)
        let read = try readPreview(grantReference(grant), check: {
            try cancellation.check(deadline: deadline); try grant.check(deadline: deadline)
        })
        let chapterURL = try previewChapterURL(grant, keys: keys, record: read.record)
        let chapter = chapterURL.flatMap { url in read.record.chapters.first { LegadoPreviewIdentity.same($0.url, url) } }
        let variables: [String: String]?
        let large: [String: String]
        if let chapterURL {
            variables = try read.record.chapterVariables[LegadoPreviewIdentity.key(chapterURL)] ?? previewVariableMap(chapter?.variable)
            large = read.record.chapterLargeVariables[LegadoPreviewIdentity.key(chapterURL)] ?? [:]
        } else {
            variables = try previewVariableMap(read.record.book.variable)
            large = read.record.bookLargeVariables
        }
        var values: [String: Data] = [:]
        for key in keys {
            if let name = key.largeVariable {
                if let value = try LegadoPreviewVariableCodec.exactValue(name, in: large) { values[key.wire] = Data(value.utf8) }
            } else if let variables {
                values[key.wire] = try encoded(variables)
            }
        }
        try cancellation.check(deadline: deadline); try grant.check(deadline: deadline)
        return .init(recordID: grant.recordID, revision: read.record.revision, rawSHA256: read.sha256,
            chapterIndex: chapter?.index, chapterURL: chapterURL, variables: variables, largeVariables: large,
            state: .init(revision: read.record.revision, values: values))
    }

    func commitPreviewEntity(_ grant: OriginalRuntimePreviewGrant, snapshot: LegadoPreviewEntitySnapshot,
                             keys: [LegadoEntityStateKey], changes: [String: Data?], deadline: Date,
                             cancellation: OriginalRuntimeCommitCancellation,
                             claimCommit: @Sendable () -> Bool = { true }) throws -> Bool {
        try cancellation.check(deadline: deadline); try grant.check(deadline: deadline)
        let reference = grantReference(grant)
        var read = try readPreview(reference, check: {
            try cancellation.check(deadline: deadline); try grant.check(deadline: deadline)
        })
        let chapterURL = try previewChapterURL(grant, keys: keys, record: read.record)
        let chapter = chapterURL.flatMap { url in read.record.chapters.first { LegadoPreviewIdentity.same($0.url, url) } }
        guard snapshot.recordID == grant.recordID, snapshot.revision == read.record.revision,
              snapshot.rawSHA256 == read.sha256, snapshot.chapterIndex == chapter?.index,
              LegadoPreviewIdentity.same(snapshot.chapterURL, chapterURL) else { return false }
        var small = snapshot.variables ?? [:]
        var large = snapshot.largeVariables
        let readWires = Set(keys.map { Data($0.wire.utf8) })
        guard changes.keys.allSatisfy({ readWires.contains(Data($0.utf8)) }) else {
            throw failure("UNSUPPORTED_CAPABILITY", "Preview changes must preserve the exact original read-key bytes")
        }
        var deleted = false
        for key in keys {
            guard let change = changes[key.wire] else { continue }
            if let name = key.largeVariable {
                _ = try LegadoPreviewVariableCodec.exactValue(name, in: large)
                if let change {
                    guard let value = String(data: change, encoding: .utf8) else {
                        throw failure("UNSUPPORTED_CAPABILITY", "Preview companion variables must retain UTF-8 bytes")
                    }
                    large[name] = value
                } else { large.removeValue(forKey: name) }
            } else if let change {
                guard let raw = String(data: change, encoding: .utf8) else { throw failure("INVALID_RESULT", "Preview variables must contain UTF-8 JSON") }
                small = try previewVariableMap(raw) ?? [:]
            } else { small = [:]; deleted = true }
        }
        try LegadoPreviewVariableCodec.validateRepresentable([small, large])
        guard small.count <= 4_096, small[Self.originalPreviewContextKey] == nil,
              large.count <= 4_096, large[Self.originalPreviewContextKey] == nil else {
            throw failure("STATE_LIMIT", "Preview variable keys exceed their budget or reserved namespace")
        }
        let raw = deleted ? nil : String(decoding: try encoded(small), as: UTF8.self)
        if let raw { _ = try previewVariableMap(raw) }
        if let chapterURL {
            if deleted { read.record.chapterVariables.removeValue(forKey: LegadoPreviewIdentity.key(chapterURL)) }
            else { read.record.chapterVariables[LegadoPreviewIdentity.key(chapterURL)] = small }
            read.record.chapterLargeVariables[LegadoPreviewIdentity.key(chapterURL)] = large
            if let chapter { read.record.chapters[Int(chapter.index)].variable = raw }
        } else { read.record.book.variable = raw; read.record.bookLargeVariables = large }
        try cancellation.check(deadline: deadline); try grant.check(deadline: deadline)
        let accepted = try replacePreview(read.record, previous: read, id: grant.recordID, deadline: deadline,
            beforeWrite: {
                try cancellation.check(deadline: deadline); try grant.check(deadline: deadline)
                guard claimCommit() else { throw CancellationError() }
            })
        grant.accepted(revision: accepted.record.revision, sha256: accepted.sha256)
        return true
    }

    private func validateOriginalPreviewTOC(_ chapters: [LegadoOriginalChapter], bookURL: String) throws {
        guard chapters.count <= 20_000 else { throw failure("STATE_LIMIT", "Original preview TOC is oversized") }
        var urls = Set<Data>()
        for (offset, chapter) in chapters.enumerated() {
            guard chapter.index == Int32(offset), LegadoPreviewIdentity.same(chapter.bookURL, bookURL),
                  !chapter.url.isEmpty, chapter.url.utf8.count <= 8_192, urls.insert(Data(chapter.url.utf8)).inserted else {
                throw failure("INVALID_STATE_REQUEST", "Original preview TOC identity is invalid")
            }
            _ = try previewVariableMap(chapter.variable)
        }
    }

    func readPreviewTOCState(_ grant: OriginalRuntimePreviewGrant, wire: String, deadline: Date,
                             cancellation: OriginalRuntimeCommitCancellation) throws -> LegadoPreviewTOCStateSnapshot {
        try cancellation.check(deadline: deadline); try grant.check(deadline: deadline)
        let read = try readPreview(grantReference(grant), check: {
            try cancellation.check(deadline: deadline); try grant.check(deadline: deadline)
        })
        let value = try read.record.originalTOC.map { try encoded($0) }
        guard (value?.count ?? 0) <= 1_048_576 else { throw failure("STATE_LIMIT", "Original preview TOC exceeds the state bridge budget") }
        return .init(recordID: grant.recordID, revision: read.record.revision, rawSHA256: read.sha256, wire: wire, value: value)
    }

    func commitPreviewTOCState(_ grant: OriginalRuntimePreviewGrant, snapshot: LegadoPreviewTOCStateSnapshot,
                               value: Data, deadline: Date, cancellation: OriginalRuntimeCommitCancellation,
                               claimCommit: @Sendable () -> Bool) throws -> Bool {
        try cancellation.check(deadline: deadline); try grant.check(deadline: deadline)
        guard grant.discoveringChapters, value.count <= 1_048_576 else {
            throw failure("UNSUPPORTED_CAPABILITY", "Only this original TOC operation can publish its bounded preview metadata")
        }
        var read = try readPreview(grantReference(grant), check: {
            try cancellation.check(deadline: deadline); try grant.check(deadline: deadline)
        })
        guard snapshot.recordID == grant.recordID, snapshot.revision == read.record.revision,
              snapshot.rawSHA256 == read.sha256 else { return false }
        let toc: [LegadoOriginalChapter]
        do { toc = try JSONDecoder().decode([LegadoOriginalChapter].self, from: value) }
        catch { throw failure("INVALID_STATE_REQUEST", "Original preview TOC requires chapter metadata") }
        try validateOriginalPreviewTOC(toc, bookURL: grant.bookURL)
        read.record.originalTOC = toc
        let accepted = try replacePreview(read.record, previous: read, id: grant.recordID, deadline: deadline,
            beforeWrite: {
                try cancellation.check(deadline: deadline); try grant.check(deadline: deadline)
                guard claimCommit() else { throw CancellationError() }
            })
        grant.accepted(revision: accepted.record.revision, sha256: accepted.sha256)
        return true
    }

    private func executePreview(_ source: BookSource, signature: String, grant: OriginalRuntimePreviewGrant,
                                operation: LegadoOriginalPreviewOperation, deadline: Date) async throws -> LegadoOriginalPreviewResult {
        let result = try await withTaskCancellationHandler {
            try await SourcePerfTrace.spanAsync("legado.original.preview.execute", "main=\(Thread.isMainThread) sourceBytes=\(source.bookSourceUrl.utf8.count)") {
                try await originalExecutor.execute(sourceJSON: String(decoding: try encoded(source), as: UTF8.self),
                    sourceURL: source.bookSourceUrl, sourceRevision: signature, grant: grant, operation: operation, deadline: deadline)
            }
        } onCancel: { grant.revoke() }
        try previewCheck(deadline)
        _ = try grant.completion()
        return result
    }

    private func finishPreview(_ reference: ContextReference, grant: OriginalRuntimePreviewGrant,
                               book: LegadoOriginalBook, chapters: [LegadoOriginalChapter]?,
                               chapter: LegadoOriginalChapter?, deadline: Date) throws -> PreviewRecord {
        try previewCheck(deadline)
        var read = try readPreview(reference)
        let proof = try grant.completion()
        guard read.record.revision == proof.revision, read.sha256 == proof.sha256 else {
            throw failure("STATE_CONFLICT", "Preview changed after this task's last accepted variable commit")
        }
        try validateOriginalBook(book, sourceURL: reference.sourceURL)
        guard LegadoPreviewIdentity.same(book.bookURL, reference.bookURL) else { throw failure("CONTEXT_MISMATCH", "Original result changed its preview book identity") }
        read.record.book = book
        if let chapters {
            guard chapters.count <= 20_000 else { throw failure("STATE_LIMIT", "Preview TOC exceeds its chapter budget") }
            var uniqueURLs = Set<Data>()
            for (offset, value) in chapters.enumerated() {
                guard Int(value.index) == offset, LegadoPreviewIdentity.same(value.bookURL, reference.bookURL), !value.url.isEmpty,
                      value.url.utf8.count <= 8_192, uniqueURLs.insert(Data(value.url.utf8)).inserted else {
                    throw failure("INVALID_RESULT", "Original TOC has a mismatched chapter index or identity")
                }
                _ = try previewVariableMap(value.variable)
            }
            let previousIDs = Dictionary(uniqueKeysWithValues: zip(read.record.chapters, read.record.chapterIDs).map {
                (LegadoPreviewIdentity.key($0.0.url), $0.1)
            })
            read.record.chapterIDs = chapters.map { previousIDs[LegadoPreviewIdentity.key($0.url)] ?? UUID() }
            read.record.chapters = chapters
            for value in chapters {
                if let map = try previewVariableMap(value.variable) { read.record.chapterVariables[LegadoPreviewIdentity.key(value.url)] = map }
                else { read.record.chapterVariables.removeValue(forKey: LegadoPreviewIdentity.key(value.url)) }
            }
        }
        if let chapter {
            guard let index = grant.chapterIndex, chapter.index == index, LegadoPreviewIdentity.same(chapter.url, grant.chapterURL),
                  LegadoPreviewIdentity.same(chapter.bookURL, reference.bookURL), index >= 0, Int(index) < read.record.chapters.count,
                  LegadoPreviewIdentity.same(read.record.chapters[Int(index)].url, chapter.url) else { throw failure("CONTEXT_MISMATCH", "Original content changed its preview chapter identity") }
            _ = try previewVariableMap(chapter.variable)
            read.record.chapters[Int(index)] = chapter
            if let map = try previewVariableMap(chapter.variable) { read.record.chapterVariables[LegadoPreviewIdentity.key(chapter.url)] = map }
            else { read.record.chapterVariables.removeValue(forKey: LegadoPreviewIdentity.key(chapter.url)) }
        }
        return try replacePreview(read.record, previous: read, id: reference.bookRecordID, deadline: deadline).record
    }

    /// Explicit App-owned batch entry; shares the existing per-source operation
    /// lease, immutable source revision and sole runtime process with all other calls.
    func originalContentBatch(source: BookSource, store: BookStore, bookID: UUID,
                              book: LegadoOriginalBook, chapters: [OriginalRuntimeBatchChapter],
                              taskID: String, deadline: Date,
                              cache: ChapterCacheRepository = BookSourceFetcher.chapterCacheRepository,
                              singleChapter: Bool = false, nextChapterURL: String? = nil) async throws -> LegadoOriginalContentBatchResult {
        let signature = try originalSignature(source)
        try validateOriginalBook(book, sourceURL: source.bookSourceUrl)
        try await acquire(source.bookSourceUrl, deadline: deadline)
        defer { release(source.bookSourceUrl) }
        try acceptOriginalRevision(source, signature: signature)
        try Task.checkCancellation()
        guard deadline.timeIntervalSinceNow > 0 else { throw failure("TIMEOUT", "Original batch deadline elapsed") }
        let sourceJSON = String(decoding: try encoded(source), as: UTF8.self)
        return try await contentBatchExecutor.execute(.init(sourceJSON: sourceJSON, sourceURL: source.bookSourceUrl,
            sourceRevision: signature, sourceID: source.id, store: store, bookID: bookID, book: book,
            chapters: chapters, taskID: taskID, deadline: deadline, cache: cache,
            singleChapter: singleChapter, nextChapterURL: nextChapterURL))
    }

    private func originalSignature(_ source: BookSource) throws -> String {
        guard !source.isJsSource, source.bookSourceType == 0, !source.bookSourceUrl.isEmpty,
              source.bookSourceUrl.utf8.count <= 8_192 else { throw failure("UNSUPPORTED_CAPABILITY", "Explicit original preview requires a traditional text source") }
        var stable = source
        stable.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        stable.lastUpdateTime = 0; stable.respondTime = 180000
        return digest(try encoded(stable))
    }
    private func acceptOriginalRevision(_ source: BookSource, signature: String) throws {
        if let current = originalSourceRevisions[source.bookSourceUrl] {
            guard current.signature == signature || source.lastUpdateTime >= current.clock else {
                throw failure("SOURCE_CHANGED", "A newer original source revision is already active")
            }
        } else if originalSourceRevisions.count >= 256 { throw failure("STATE_LIMIT", "Too many original source grants") }
        originalSourceRevisions[source.bookSourceUrl] = (signature, max(source.lastUpdateTime, originalSourceRevisions[source.bookSourceUrl]?.clock ?? 0))
    }
    private func validateOriginalBook(_ book: LegadoOriginalBook, sourceURL: String) throws {
        guard LegadoPreviewIdentity.same(book.origin, sourceURL), !book.bookURL.isEmpty, book.bookURL.utf8.count <= 8_192,
              book.type == 8 else { throw failure("INVALID_RESULT", "Original preview book has an invalid source, URL or text type") }
        _ = try previewVariableMap(book.variable)
    }
    private func previewVariableMap(_ raw: String?) throws -> [String: String]? {
        guard let raw else { return nil }
        guard raw.utf8.count <= 1_048_576 else { throw failure("STATE_LIMIT", "Preview variables exceed their byte budget") }
        let value = try LegadoPreviewVariableCodec.decodeMap(raw)
        guard value.count <= 4_096, value[Self.originalPreviewContextKey] == nil else {
            throw failure("STATE_LIMIT", "Preview variables exceed their key budget or contain the reserved context key")
        }
        return value
    }
    private func previewReference(_ record: PreviewRecord, id: String) -> ContextReference {
        .init(version: 2, sourceID: record.sourceID, sourceURL: record.sourceURL, sourceSignature: record.sourceSignature,
            bookRecordID: id, bookURL: record.book.bookURL)
    }
    private func previewContext(_ variables: [String: String]?, source: BookSource, signature: String) throws -> ContextReference {
        guard let raw = variables?[Self.originalPreviewContextKey], raw.utf8.count <= 32_768 else {
            throw failure("CONTEXT_MISSING", "Original preview requires its existing context record")
        }
        let ref = try JSONDecoder().decode(ContextReference.self, from: Data(raw.utf8))
        guard ref.version == 2, ref.sourceID == source.id, LegadoPreviewIdentity.same(ref.sourceURL, source.bookSourceUrl),
              ref.sourceSignature == signature, ref.bookRecordID.count == 64,
              ref.bookRecordID.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw failure("CONTEXT_MISMATCH", "Original preview context belongs to another source or revision")
        }
        return ref
    }
    private func previewVariables(_ record: PreviewRecord, reference: ContextReference, previous: [String: String]?) throws -> [String: String] {
        // Project the current owner, including deletion, instead of merging an older UI map.
        let small = try previewVariableMap(record.book.variable) ?? [:]
        try LegadoPreviewVariableCodec.validateRepresentable([small, record.bookLargeVariables])
        var value = record.bookLargeVariables.merging(small) { _, small in small }
        value[Self.originalPreviewContextKey] = try previewReferenceString(reference)
        return value
    }
    private func previewChapterProjection(_ record: PreviewRecord, chapter: LegadoOriginalChapter,
                                          reference: ContextReference) throws -> [String: String] {
        let small = try record.chapterVariables[LegadoPreviewIdentity.key(chapter.url)] ?? previewVariableMap(chapter.variable) ?? [:]
        let large = record.chapterLargeVariables[LegadoPreviewIdentity.key(chapter.url)] ?? [:]
        try LegadoPreviewVariableCodec.validateRepresentable([small, large])
        var values = large.merging(small) { _, small in small }
        values[Self.originalPreviewContextKey] = try previewReferenceString(reference)
        return values
    }
    private func previewReferenceString(_ reference: ContextReference) throws -> String {
        let raw = try encoded(reference)
        guard raw.count <= 32_768 else { throw failure("STATE_LIMIT", "Preview context reference exceeds its byte budget") }
        return String(decoding: raw, as: UTF8.self)
    }
    private func previewOnlineBook(_ record: PreviewRecord, reference: ContextReference, previous: [String: String]?, source: BookSource) throws -> OnlineBook {
        let book = record.book
        return OnlineBook(name: book.name, author: book.author, intro: book.intro ?? "", coverUrl: book.coverURL ?? "",
            bookUrl: book.bookURL, tocUrl: book.tocURL, wordCount: book.wordCount ?? "",
            lastChapter: book.latestChapterTitle ?? "", kind: book.kind ?? "", sourceId: source.id, sourceName: source.bookSourceName,
            runtimeVariables: try previewVariables(record, reference: reference, previous: previous))
    }
    private func previewID(_ record: PreviewRecord) throws -> String {
        digest(try encoded(PreviewIdentity(version: 2, nonce: record.nonce, sourceID: record.sourceID,
            sourceURL: record.sourceURL, sourceSignature: record.sourceSignature, bookURL: record.book.bookURL)))
    }
    private func readPreview(_ reference: ContextReference, requireActive: Bool = true,
                             check: () throws -> Void = { try Task.checkCancellation() }) throws -> PreviewRead {
        do { return try SourcePerfTrace.span("legado.original.preview.read", "main=\(Thread.isMainThread)") {
            dispatchPrecondition(condition: .notOnQueue(.main))
            let path = try directory().appendingPathComponent(reference.bookRecordID + ".json")
            let raw = try readPreviewFile(path, check: check)
            try LegadoPreviewVariableCodec.validateRecordMaps(raw)
            let record = try JSONDecoder().decode(PreviewRecord.self, from: raw)
            try validateOriginalBook(record.book, sourceURL: reference.sourceURL)
            try validatePreviewVariableBounds(record)
            guard record.chapters.count <= 20_000,
                  record.chapterVariables.count <= 20_000,
                  record.chapterLargeVariables.count <= 20_000 else { throw failure("STATE_LIMIT", "Preview entity count exceeds its budget") }
            guard record.chapterIDs.count == record.chapters.count, Set(record.chapterIDs).count == record.chapterIDs.count else {
                throw failure("CONTEXT_CORRUPT", "Preview chapter identities are duplicated")
            }
            var uniqueURLs = Set<Data>()
            for (offset, chapter) in record.chapters.enumerated() {
                try check()
                guard Int(chapter.index) == offset, LegadoPreviewIdentity.same(chapter.bookURL, reference.bookURL),
                      !chapter.url.isEmpty, chapter.url.utf8.count <= 8_192,
                      uniqueURLs.insert(Data(chapter.url.utf8)).inserted else {
                    throw failure("CONTEXT_CORRUPT", "Preview chapter identity or index is corrupt")
                }
            }
            guard record.version == 2, record.sourceID == reference.sourceID, LegadoPreviewIdentity.same(record.sourceURL, reference.sourceURL),
                  record.sourceSignature == reference.sourceSignature, LegadoPreviewIdentity.same(record.book.bookURL, reference.bookURL),
                  try previewID(record) == reference.bookRecordID else { throw failure("CONTEXT_CORRUPT", "Preview record identity differs from its reference") }
            guard (record.status == .active || record.status == .revoked) == (record.transferBookID == nil) else {
                throw failure("CONTEXT_CORRUPT", "Preview lifecycle and its transfer identity disagree")
            }
            guard !requireActive || record.status == .active else { throw failure("INVALID_STATE_OWNER", "Preview was revoked or transferred to its App owner") }
            return PreviewRead(record: record, raw: raw, sha256: digest(raw))
        } } catch let error as LegadoRuntimeError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch {
            AppLogger.error("Original preview context could not be read", error: error)
            throw failure("STATE_IO", "The original preview context could not be read")
        }
    }

    /// One FD, bounded allocation and positional reads. Imported references choose only a
    /// validated hex record ID beneath this actor's existing configured context directory.
    /// No path check authorizes a later Foundation read of a replaceable file.
    private func readPreviewFile(_ path: URL, check: () throws -> Void) throws -> Data {
        try check()
        let descriptor = Darwin.open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure("STATE_IO", "Preview context could not be opened") }
        var isOpen = true
        defer { if isOpen { _ = Darwin.close(descriptor) } }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_nlink == 1,
              before.st_uid == geteuid() else { throw failure("STATE_IO", "Preview context is not an owned regular file") }
        guard before.st_size >= 0, before.st_size <= 8_388_608 else { throw failure("STATE_LIMIT", "Preview record exceeds its byte budget") }
        var data = Data(count: Int(before.st_size))
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try check()
                let count = Darwin.pread(descriptor, buffer.baseAddress!.advanced(by: offset), min(262_144, buffer.count - offset), off_t(offset))
                if count < 0 {
                    if errno == EINTR { continue }
                    throw failure("STATE_IO", "Preview context could not be read")
                }
                guard count > 0 else { throw failure("STATE_IO", "Preview context changed during its read") }
                offset += count
            }
        }
        var after = stat(); var atPath = stat()
        guard Darwin.fstat(descriptor, &after) == 0, Darwin.lstat(path.path, &atPath) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              atPath.st_dev == after.st_dev, atPath.st_ino == after.st_ino,
              atPath.st_size == after.st_size, atPath.st_uid == after.st_uid, atPath.st_nlink == 1,
              atPath.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, atPath.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              atPath.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, atPath.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              atPath.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw failure("STATE_IO", "Preview context changed during its read")
        }
        isOpen = false // close is attempted exactly once, including EINTR/failure.
        guard Darwin.close(descriptor) == 0 else { throw failure("STATE_IO", "Preview context could not be closed") }
        try check()
        return data
    }
    @discardableResult
    private func replacePreview(_ record: PreviewRecord, previous: PreviewRead, id: String, deadline: Date,
                                honourCancellation: Bool = true, beforeWrite: () throws -> Void = {}) throws -> PreviewRead {
        try validateOriginalBook(record.book, sourceURL: record.sourceURL)
        try validatePreviewVariableBounds(record)
        guard record.chapterVariables.count <= 20_000, record.chapterLargeVariables.count <= 20_000 else {
            throw failure("STATE_LIMIT", "Preview discovered chapter state exceeds its budget")
        }
        var next = record
        next.revision = previous.record.revision
        let withoutRevision = try encoded(next)
        if withoutRevision == previous.raw { return previous }
        guard next.revision < UInt64.max else { throw failure("STATE_LIMIT", "Preview revision space exhausted") }
        next.revision += 1
        try beforeWrite()
        let bytes = try encoded(next)
        try writePreview(bytes, id: id, deadline: deadline, honourCancellation: honourCancellation)
        return PreviewRead(record: next, raw: bytes, sha256: digest(bytes))
    }
    private func validatePreviewVariableBounds(_ record: PreviewRecord) throws {
        if let toc = record.originalTOC { try validateOriginalPreviewTOC(toc, bookURL: record.book.bookURL) }
        try LegadoPreviewVariableCodec.validateRepresentable([try previewVariableMap(record.book.variable) ?? [:], record.bookLargeVariables])
        var effectiveChapterVariables: [String: [String: String]] = [:]
        for chapter in record.chapters {
            effectiveChapterVariables[LegadoPreviewIdentity.key(chapter.url)] = try previewVariableMap(chapter.variable) ?? [:]
        }
        for (key, value) in record.chapterVariables { effectiveChapterVariables[key] = value }
        let chapterKeys = Set(effectiveChapterVariables.keys).union(record.chapterLargeVariables.keys)
        for key in chapterKeys {
            try LegadoPreviewVariableCodec.validateRepresentable([effectiveChapterVariables[key] ?? [:], record.chapterLargeVariables[key] ?? [:]])
        }
        guard record.bookLargeVariables.count <= 4_096, record.bookLargeVariables[Self.originalPreviewContextKey] == nil,
              record.chapterVariables.values.allSatisfy({ $0.count <= 4_096 && $0[Self.originalPreviewContextKey] == nil }),
              record.chapterLargeVariables.values.allSatisfy({ $0.count <= 4_096 && $0[Self.originalPreviewContextKey] == nil }) else {
            throw failure("STATE_LIMIT", "Preview variable state exceeds its key budget or reserved namespace")
        }
    }
    private func writePreview(_ bytes: Data, id: String, deadline: Date, honourCancellation: Bool = true) throws {
        if honourCancellation { try previewCheck(deadline) }
        guard bytes.count <= 8_388_608 else { throw failure("STATE_LIMIT", "Preview record exceeds its byte budget") }
        do {
            let path = try directory().appendingPathComponent(id + ".json")
            try SourcePerfTrace.span("legado.original.preview.write", "bytes=\(bytes.count) main=\(Thread.isMainThread)") {
            dispatchPrecondition(condition: .notOnQueue(.main))
            try bytes.write(to: path, options: .atomic)
        } } catch {
            AppLogger.error("Original preview context could not be written", error: error)
            throw failure("STATE_IO", "The original preview context could not be written")
        }
    }
    private func previewCheck(_ deadline: Date) throws {
        try Task.checkCancellation()
        guard deadline.timeIntervalSinceNow > 0 else { throw failure("TIMEOUT", "Preview operation exceeded its absolute deadline") }
    }
    private func makePreviewGrant(_ reference: ContextReference, read: PreviewRead, chapter: LegadoOriginalChapter?, discoveringChapters: Bool = false, deadline: Date) throws -> OriginalRuntimePreviewGrant {
        try previewCheck(deadline)
        return .init(service: self, sourceID: reference.sourceID, sourceURL: reference.sourceURL,
            sourceRevision: reference.sourceSignature, recordID: reference.bookRecordID, bookURL: reference.bookURL,
            chapter: chapter, discoveringChapters: discoveringChapters, expiresAt: deadline,
            revision: read.record.revision, sha256: read.sha256)
    }
    private func grantReference(_ grant: OriginalRuntimePreviewGrant) -> ContextReference {
        .init(version: 2, sourceID: grant.sourceID, sourceURL: grant.sourceURL, sourceSignature: grant.sourceRevision,
            bookRecordID: grant.recordID, bookURL: grant.bookURL)
    }
    private func previewChapterURL(_ grant: OriginalRuntimePreviewGrant, keys: [LegadoEntityStateKey], record: PreviewRecord) throws -> String? {
        guard let first = keys.first else { throw failure("INVALID_ARGUMENT", "Preview entity key list is empty") }
        guard let url = first.chapterURL else { return nil }
        if grant.discoveringChapters { return url }
        guard let index = grant.chapterIndex, index >= 0, Int(index) < record.chapters.count,
              LegadoPreviewIdentity.same(record.chapters[Int(index)].url, grant.chapterURL), LegadoPreviewIdentity.same(url, grant.chapterURL) else {
            throw failure("INVALID_STATE_OWNER", "Preview chapter no longer belongs to its granted TOC")
        }
        return url
    }
}


extension LegadoMainJSSourceService {
    /// Actual App notification entry: UUID comes from its existing record, chapter
    /// identity from that record's existing ChapterStore. No URL creates authority.
    func originalBookCallback(event: SourceCallBackEvent, source: BookSource, book: ReadingBook,
        chapter requested: ReaderHTMLUtilities.LegadoSourceActionContext.ChapterSnapshot?,
        chapterID: UUID?, result: String?, store: BookStore,
        position: CoreTextReadingPosition?, positionStore: (any ReadingPositionStore)?,
        eventTimeMilliseconds: Int64?) async throws -> LegadoBookCallbackReceipt {
        let signature = try originalSignature(source)
        guard book.resolvedPipelineKind == .html else {
            throw failure("UNSUPPORTED_CAPABILITY", "Original notifications require the actual online text-book entity")
        }
        let deadline = min(try operationDeadline(), Date().addingTimeInterval(60))
        try await acquire(source.bookSourceUrl, deadline: deadline)
        defer { release(source.bookSourceUrl) }
        try Task.checkCancellation()
        guard deadline.timeIntervalSinceNow > 0 else { throw failure("TIMEOUT", "Book notification deadline expired") }
        try acceptOriginalRevision(source, signature: signature)
        guard [.startRead, .endRead, .saveRead, .addBookShelf].contains(event),
              book.isOnline, book.bookSourceId == source.id,
              let bookURL = book.bookInfoURL, !bookURL.isEmpty,
              let owned = await store.prepareOriginalRuntimeBookSnapshot(id: book.id, sourceID: source.id, bookURL: bookURL) else {
            throw failure("INVALID_STATE_OWNER", "Book notification requires its actual App book/source identity")
        }
        let actualPosition: CoreTextReadingPosition
        if let position {
            actualPosition = position
        } else if let positionStore {
            do {
                if let saved = try await positionStore.loadChecked(for: book.id.uuidString) {
                    actualPosition = saved.position
                } else {
                    // The actual owner returned ENOENT. Only a never-read record
                    // is known to start at zero; an existing unknown position fails.
                    guard event == .addBookShelf, book.lastOpenedDate == nil, book.currentPosition == 0 else {
                        throw failure("UNSUPPORTED_CAPABILITY", "The actual book has no exact stored reading position")
                    }
                    actualPosition = .chapterStart(0)
                }
            } catch let error as LegadoRuntimeError { throw error }
              catch is CancellationError { throw CancellationError() }
              catch {
                throw failure("STATE_IO", "The actual reading-position owner could not provide its snapshot")
            }
        } else {
            throw failure("INVALID_STATE_OWNER", "A notification requires its actual position snapshot or the same position owner")
        }
        guard actualPosition.spineIndex >= 0, actualPosition.charOffset >= 0,
              let progressIndex = Int32(exactly: actualPosition.spineIndex),
              let progressOffset = Int32(exactly: actualPosition.charOffset) else {
            throw failure("UNSUPPORTED_CAPABILITY", "Notification position exceeds the original nonnegative integer contract")
        }
        let lastReadMilliseconds: Int64
        if event == .saveRead {
            guard let eventTimeMilliseconds, eventTimeMilliseconds >= 0,
                  result == String(eventTimeMilliseconds) else {
                throw failure("INVALID_ARGUMENT", "saveRead result and book.durChapterTime must describe the same actual event")
            }
            lastReadMilliseconds = eventTimeMilliseconds
        } else {
            // The App's existing opened date is its available reading-history fact.
            // An unread entity retains its real construction date. Never substitute
            // the time an unrelated start/end/shelf notification happens to run.
            let history = book.lastOpenedDate ?? book.addedDate
            let milliseconds = history.timeIntervalSince1970 * 1000
            guard milliseconds.isFinite, milliseconds >= 0,
                  let exact = Int64(exactly: milliseconds.rounded(.towardZero)) else {
                throw failure("UNSUPPORTED_CAPABILITY", "Book notification has no representable actual reading-history date")
            }
            lastReadMilliseconds = exact
        }
        let chapters = try await store.originalRuntimeChapters(bookID: book.id)
        let exactInitialUnread = book.lastOpenedDate == nil && book.currentPosition == 0
            && actualPosition == .chapterStart(0) && requested == nil
        guard (chapters.indices.contains(actualPosition.spineIndex)
               && chapters[actualPosition.spineIndex].index == actualPosition.spineIndex)
              || (exactInitialUnread && chapters.isEmpty) else {
            throw failure("STATE_CONFLICT", "The actual reading position has no current chapter")
        }
        var selected: OnlineChapterRef?
        if let requested {
            guard requested.index == actualPosition.spineIndex, let chapterID, chapters.indices.contains(requested.index),
                  chapters[requested.index].id == chapterID,
                  chapters[requested.index].index == requested.index,
                  chapters[requested.index].url.utf8.elementsEqual(requested.url.utf8) else {
                throw failure("STATE_CONFLICT", "Notification chapter no longer belongs to the actual App TOC")
            }
            selected = chapters[requested.index]
        } else if chapterID != nil {
            throw failure("INVALID_STATE_OWNER", "A notification chapter UUID needs its actual chapter snapshot")
        }
        var dto = LegadoOriginalBook(bookURL: bookURL, origin: source.bookSourceUrl,
            name: book.title, author: book.author, tocURL: owned.tocURL)
        dto.originName = source.bookSourceName; dto.coverURL = book.coverUrl
        dto.durChapterIndex = progressIndex; dto.durChapterPos = progressOffset
        dto.durChapterTitle = chapters.indices.contains(actualPosition.spineIndex) ? chapters[actualPosition.spineIndex].title : nil
        dto.durChapterTime = lastReadMilliseconds
        guard let recordOrder = store.originalRuntimeBookOrder(id: book.id, sourceID: source.id, bookURL: bookURL),
              let order = Int32(exactly: recordOrder), let originOrder = Int32(exactly: source.customOrder) else {
            throw failure("STATE_CONFLICT", "Notification lost the existing App book ordering")
        }
        dto.order = order; dto.originOrder = originOrder
        dto.totalChapterNum = Int32(exactly: chapters.count) ?? Int32.max
        dto.latestChapterTitle = book.latestChapterTitle
        dto.intro = owned.variables?["book.abstract"]
        dto.imageStyle = owned.variables?["book.imageStyle"]
        dto.variable = try callbackSmallVariables(owned.variables)
        var chapter: LegadoOriginalChapter?
        if let selected, let index = Int32(exactly: selected.index) {
            var value = LegadoOriginalChapter(bookURL: bookURL, url: selected.url, index: index,
                title: selected.title, baseURL: owned.tocURL)
            value.isVolume = selected.isVolume; value.isVip = selected.isVip; value.isPay = selected.isPay
            value.variable = try callbackSmallVariables(selected.runtimeVariables)
            chapter = value
        }
        return try await SourcePerfTrace.spanAsync("legado.original.book.callback",
            "main=\(Thread.isMainThread) event=\(event.rawValue) chapter=\(selected?.index ?? -1)") {
            try await NativeLegadoBookCallbackExecutor.execute(source: source, signature: signature,
                store: store, bookID: book.id, book: dto, chapter: chapter, actualChapter: selected,
                event: event.rawValue, result: result, deadline: deadline)
        }
    }

    private func callbackSmallVariables(_ values: [String: String]?) throws -> String? {
        guard let values else { return nil }
        let exposed = values.filter { $0.key != Self.originalPreviewContextKey && $0.value.utf16.count < 10_000 }
        try LegadoPreviewVariableCodec.validateRepresentable([exposed])
        return String(decoding: try JSONEncoder().encode(exposed), as: UTF8.self)
    }
}


extension LegadoMainJSSourceService {
    /// Locked source-only notifications use the same actor/source lock and the
    /// ordinary source binding. There is no App BookStore/chapter/cache authority.
    func originalSourceCallback(event: SourceCallBackEvent, source: BookSource) async throws -> LegadoBookCallbackReceipt {
        guard event == .startShelfRefresh || event == .endShelfRefresh else {
            throw failure("UNSUPPORTED_CAPABILITY", "Only original shelf-refresh source notifications are connected")
        }
        let signature = try originalSignature(source)
        // callBackSource uses 30s; the existing book notifications use 60s. The
        // original absolute source budget includes time waiting for this lock.
        let deadline = min(try operationDeadline(), Date().addingTimeInterval(30))
        try await acquire(source.bookSourceUrl, deadline: deadline)
        defer { release(source.bookSourceUrl) }
        try acceptOriginalRevision(source, signature: signature)
        let result = try await SourcePerfTrace.spanAsync("legado.original.source.callback",
            "main=\(Thread.isMainThread) event=\(event.rawValue) sourceBytes=\(source.bookSourceUrl.utf8.count)") {
            try await originalExecutor.execute(sourceJSON: String(decoding: try encoded(source), as: UTF8.self),
                sourceURL: source.bookSourceUrl, sourceRevision: signature, grant: nil,
                operation: .sourceCallback(event.rawValue), deadline: deadline)
        }
        guard case .sourceCallback(let reply, let effects) = result else {
            throw failure("INVALID_RESULT", "Original source notification omitted its result")
        }
        do { try previewCheck(deadline) }
        catch {
            if effects.isEmpty { throw error }
            let typed = error as? LegadoRuntimeError
            throw LegadoRuntimeError(code: typed?.code ?? (error is CancellationError ? "CANCELLED" : "STATE_IO"),
                message: error.localizedDescription,
                completedEffects: Array(Set(effects + (typed?.completedEffects ?? []))).sorted())
        }
        return .init(executed: reply.executed, completedEffects: effects)
    }
}

struct LegadoOriginalFormLoginReceipt: Sendable {
    let credentialsStored: Bool
    let credentialsCleared: Bool
    let executed: Bool
    let completedEffects: [String]
}

extension LegadoMainJSSourceService {
    /// Standalone traditional text form submission. Shares the actual reader's
    /// source lock/process/credential/Cookie/header owners; grants no Book.
    func originalFormLogin(source: BookSource, credentials: [String: String]) async throws -> LegadoOriginalFormLoginReceipt {
        var effects: [String] = []
        do {
            let signature = try originalSignature(source)
            // The original dialog is lifecycle-bound. This finite 30s iOS
            // embedding budget includes lock wait; it is not an Android timer.
            let deadline = min(try operationDeadline(), Date().addingTimeInterval(30))
            try await acquire(source.bookSourceUrl, deadline: deadline)
            defer { release(source.bookSourceUrl) }
            try acceptOriginalRevision(source, signature: signature)
            let result = try await SourcePerfTrace.spanAsync("legado.original.form.login",
                "main=\(Thread.isMainThread) fields=\(credentials.count)") {
                try await originalExecutor.execute(sourceJSON: String(decoding: try encoded(source), as: UTF8.self),
                    sourceURL: source.bookSourceUrl, sourceRevision: signature, grant: nil,
                    operation: .formLogin(credentials), deadline: deadline)
            }
            guard case .formLogin(let reply, let reported) = result else {
                throw failure("INVALID_RESULT", "Original form login omitted its result")
            }
            effects = reported
            guard reply.credentialsStored || reply.credentialsCleared else {
                throw failure("STATE_IO", "The credential owner rejected the submitted form")
            }
            try previewCheck(deadline)
            return .init(credentialsStored: reply.credentialsStored, credentialsCleared: reply.credentialsCleared,
                executed: reply.executed, completedEffects: effects)
        } catch {
            let typed = error as? LegadoRuntimeError
            let code = typed?.code ?? (error is CancellationError ? "CANCELLED" : "STATE_IO")
            // Neither authored JS errors nor request/credential text may enter
            // a login alert/log through an arbitrary Error description.
            throw LegadoRuntimeError(code: code, message: "Original form login did not complete (\(code))",
                completedEffects: Array(Set(effects + (typed?.completedEffects ?? []))).sorted())
        }
    }
}
