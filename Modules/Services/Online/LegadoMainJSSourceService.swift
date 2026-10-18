import CryptoKit
import Foundation
import LegadoRuntime

/// One process owns the JVM. Resolving resources and starting it remain lazy and off main.
actor LegadoRuntimeProcess {
    static let shared = LegadoRuntimeProcess()
    private var runtime: LegadoRuntime?

    func executor() throws -> LegadoRuntime {
        if let runtime { return runtime }
        return try SourcePerfTrace.span("legado.process.configure", "main=\(Thread.isMainThread)") {
            let configuration = LegadoRuntime.Configuration.bundled()
            let diagnostics = LegadoRuntime.diagnose(configuration: configuration)
            guard diagnostics.available, let configuration else {
                throw LegadoRuntimeError(code: "MISSING_RUNTIME", message: diagnostics.issues.joined(separator: "; "))
            }
            let value = LegadoRuntime(configuration: configuration)
            runtime = value
            return value
        }
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
         operationTimeout: TimeInterval = 60) {
        self.executor = executor
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
