import Foundation
import os
import LegadoRuntime

enum LegadoPreviewIdentity {
    static func same(_ left: String, _ right: String) -> Bool { left.utf8.elementsEqual(right.utf8) }
    static func same(_ left: String?, _ right: String?) -> Bool {
        switch (left, right) {
        case (.none, .none): return true
        case (.some(let left), .some(let right)): return same(left, right)
        default: return false
        }
    }
    /// Preserve Java's original URL String identity in Swift Dictionary keys, whose
    /// ordinary String equality otherwise equates canonically equivalent Unicode.
    static func key(_ url: String) -> String { Data(url.utf8).base64EncodedString() }

    static func sameChapter(_ left: OnlineChapterRef, _ right: OnlineChapterRef) -> Bool {
        left.id == right.id && left.index == right.index && same(left.title, right.title) && same(left.url, right.url)
            && left.isVolume == right.isVolume && left.isVip == right.isVip && left.isPay == right.isPay
            && same(left.cachedFilename, right.cachedFilename)
            && LegadoPreviewVariableCodec.sameMap(left.runtimeVariables, right.runtimeVariables)
            && left.audioStartSeconds == right.audioStartSeconds && left.audioDurationSeconds == right.audioDurationSeconds
            && left.pdfPageCount == right.pdfPageCount
    }
}

/// A bounded lexical guard for the original flat JSON String map only. Each JSON String
/// token is decoded independently by Foundation, before any Swift Dictionary can merge
/// canonically equivalent but byte-distinct Java names. The existing DTO/record decoder
/// still owns its schema; the small navigator only locates its three state-map fields.
enum LegadoPreviewVariableCodec {
    private static func failure(_ message: String) -> LegadoRuntimeError {
        .init(code: "INVALID_RESULT", message: message)
    }
    private static func alias() -> LegadoRuntimeError {
        .init(code: "UNSUPPORTED_CAPABILITY", message: "Byte-distinct original variable names cannot share a Swift state-map key")
    }
    private struct Cursor {
        let bytes: [UInt8]
        var index = 0
        mutating func whitespace() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        mutating func expect(_ byte: UInt8) throws {
            whitespace()
            guard index < bytes.count, bytes[index] == byte else { throw failure("Original variables require a JSON String map") }
            index += 1
        }
        mutating func stringRange() throws -> Range<Int> {
            whitespace(); let start = index
            guard index < bytes.count, bytes[index] == 34 else { throw failure("Original variables require JSON String keys and values") }
            index += 1
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 { return start..<index }
                if byte == 92 {
                    guard index < bytes.count else { throw failure("Original variable JSON String is truncated") }
                    index += 1 // JSONDecoder validates escapes/surrogate pairs for each token.
                }
            }
            throw failure("Original variable JSON String is truncated")
        }
        mutating func string() throws -> String {
            let range = try stringRange()
            do { return try JSONDecoder().decode(String.self, from: Data(bytes[range])) }
            catch { throw failure("Original variable JSON String is invalid") }
        }
        /// Skip an opaque DTO value solely to find a fixed outer state-map field. This
        /// does not decode rules, accept a new schema, or replace JSONDecoder validation.
        mutating func skipValue() throws -> Range<Int> {
            whitespace(); let start = index
            guard index < bytes.count else { throw failure("Owned context JSON is truncated") }
            if bytes[index] == 34 { _ = try stringRange(); return start..<index }
            if bytes[index] == 123 || bytes[index] == 91 {
                var stack: [UInt8] = [bytes[index] == 123 ? 125 : 93]; index += 1
                while !stack.isEmpty {
                    guard index < bytes.count else { throw failure("Owned context JSON is truncated") }
                    let byte = bytes[index]
                    if byte == 34 { _ = try stringRange(); continue }
                    if byte == 123 || byte == 91 {
                        guard stack.count < 32 else { throw failure("Owned context JSON nesting exceeds its budget") }
                        stack.append(byte == 123 ? 125 : 93)
                    } else if byte == 125 || byte == 93 {
                        guard stack.last == byte else { throw failure("Owned context JSON delimiters are invalid") }
                        stack.removeLast()
                    }
                    index += 1
                }
                return start..<index
            }
            while index < bytes.count && ![9, 10, 13, 32, 44, 125, 93].contains(bytes[index]) { index += 1 }
            guard index > start else { throw failure("Owned context JSON value is invalid") }
            return start..<index
        }
        mutating func end() throws {
            whitespace(); guard index == bytes.count else { throw failure("Original variable JSON has trailing content") }
        }
    }

    static func decodeMap(_ raw: String) throws -> [String: String] {
        let bytes = Data(raw.utf8)
        guard bytes.count <= 1_048_576 else { throw LegadoRuntimeError(code: "STATE_LIMIT", message: "Original variable JSON exceeds its byte budget") }
        var result: [String: String] = [:]
        try flatMap(bytes, allowNull: false) { key, value in
            guard let value else { throw failure("Original variables require JSON String values") }
            result[key] = value
        }
        return result
    }
    private static func flatMap(_ raw: Data, allowNull: Bool,
                                entry: (String, String?) throws -> Void = { _, _ in }) throws {
        var cursor = Cursor(bytes: Array(raw)); try cursor.expect(123); cursor.whitespace()
        var seen: [String: Data] = [:]
        if cursor.index < cursor.bytes.count && cursor.bytes[cursor.index] == 125 {
            cursor.index += 1; try cursor.end(); return
        }
        while true {
            let name = try cursor.string(); let identity = Data(name.utf8)
            if let previous = seen[name], previous != identity { throw alias() }
            seen[name] = identity
            guard seen.count <= 4_096 else { throw LegadoRuntimeError(code: "STATE_LIMIT", message: "Original variable key count exceeds its budget") }
            try cursor.expect(58); cursor.whitespace()
            let value: String?
            if allowNull && cursor.index + 4 <= cursor.bytes.count && Array(cursor.bytes[cursor.index..<(cursor.index + 4)]) == Array("null".utf8) {
                cursor.index += 4; value = nil
            } else { value = try cursor.string() }
            try entry(name, value) // Same-byte duplicate keys retain original last-write semantics.
            cursor.whitespace()
            guard cursor.index < cursor.bytes.count else { throw failure("Original variable JSON object is truncated") }
            let separator = cursor.bytes[cursor.index]; cursor.index += 1
            if separator == 125 { try cursor.end(); return }
            guard separator == 44 else { throw failure("Original variable JSON object is invalid") }
        }
    }
    private static func objectFields(_ raw: Data, entry: (String, Data) throws -> Void) throws {
        var cursor = Cursor(bytes: Array(raw)); try cursor.expect(123); cursor.whitespace()
        if cursor.index < cursor.bytes.count && cursor.bytes[cursor.index] == 125 { cursor.index += 1; try cursor.end(); return }
        while true {
            let key = try cursor.string(); try cursor.expect(58)
            let value = try cursor.skipValue(); try entry(key, Data(cursor.bytes[value]))
            cursor.whitespace()
            guard cursor.index < cursor.bytes.count else { throw failure("Owned context JSON is truncated") }
            let separator = cursor.bytes[cursor.index]; cursor.index += 1
            if separator == 125 { try cursor.end(); return }
            guard separator == 44 else { throw failure("Owned context JSON object is invalid") }
        }
    }
    static func validateRecordMaps(_ raw: Data) throws {
        try objectFields(raw) { name, value in
            if name == "bookLargeVariables" { try flatMap(value, allowNull: false) }
            if name == "chapterVariables" || name == "chapterLargeVariables" {
                try objectFields(value) { encodedURL, map in
                    guard let bytes = Data(base64Encoded: encodedURL), !bytes.isEmpty, bytes.count <= 8_192,
                          let url = String(data: bytes, encoding: .utf8), LegadoPreviewIdentity.key(url) == encodedURL else {
                        throw failure("Owned preview chapter-state URL identity is invalid")
                    }
                    try flatMap(map, allowNull: false)
                }
            }
        }
    }
    static func validateHostChanges(_ raw: String) throws {
        try objectFields(Data(raw.utf8)) { field, value in
            if field == "changes" { try flatMap(value, allowNull: true) }
        }
    }
    static func validateRepresentable(_ maps: [[String: String]]) throws {
        var seen: [String: Data] = [:]
        for map in maps {
            for name in map.keys {
                let identity = Data(name.utf8)
                if let previous = seen[name], previous != identity { throw alias() }
                seen[name] = identity
            }
        }
    }
    static func exactValue(_ name: String, in map: [String: String]) throws -> String? {
        guard let index = map.index(forKey: name) else { return nil }
        guard LegadoPreviewIdentity.same(map[index].key, name) else { throw alias() }
        return map[index].value
    }
    static func sameMap(_ left: [String: String], _ right: [String: String]) -> Bool {
        guard left.count == right.count else { return false }
        return left.allSatisfy { name, value in
            guard let index = right.index(forKey: name) else { return false }
            return LegadoPreviewIdentity.same(name, right[index].key) && LegadoPreviewIdentity.same(value, right[index].value)
        }
    }
    static func sameMap(_ left: [String: String]?, _ right: [String: String]?) -> Bool {
        switch (left, right) {
        case (.none, .none): return true
        case (.some(let left), .some(let right)): return sameMap(left, right)
        default: return false
        }
    }
}

/// Both variants carry a proof issued by their existing owner. A preview never fabricates
/// BookStore/BookChapterStore snapshots or a library UUID.
enum LegadoEntityBackingSnapshot: Sendable {
    case app(LegadoEntityStateSnapshot)
    case preview(LegadoPreviewEntitySnapshot)

    var state: LegadoOwnedStateSnapshot {
        switch self {
        case .app(let value): return value.state
        case .preview(let value): return value.state
        }
    }
}

protocol LegadoEntityStateBacking: Sendable {
    func revoke()
    func validateRequest(_ request: LegadoHostRequest) throws
    func validateState(deadline: Date) async throws
    func parse(_ wires: [String], sourceURL: String, decodedParts: [String: [String]]) throws -> [LegadoEntityStateKey]
    func readState(keys: [LegadoEntityStateKey], deadline: Date,
                   cancellation: OriginalRuntimeCommitCancellation) async throws -> LegadoEntityBackingSnapshot
    func commitState(snapshot: LegadoEntityBackingSnapshot, keys: [LegadoEntityStateKey], changes: [String: Data?],
                     deadline: Date, cancellation: OriginalRuntimeCommitCancellation,
                     claimCommit: @escaping @Sendable () -> Bool) async throws -> Bool
}

extension AppLegadoBookStateOwner: LegadoEntityStateBacking {
    func validateRequest(_ request: LegadoHostRequest) throws {
        if let callbackTaskID, request.taskID != callbackTaskID {
            throw LegadoRuntimeError(code: "INVALID_STATE_OWNER", message: "App callback state belongs to one actual notification task")
        }
    }
    func validateState(deadline: Date) async throws { try validate(deadline: deadline) }
    func readState(keys: [LegadoEntityStateKey], deadline: Date,
                   cancellation: OriginalRuntimeCommitCancellation) async throws -> LegadoEntityBackingSnapshot {
        .app(try await read(keys: keys, deadline: deadline, cancellation: cancellation))
    }
    func commitState(snapshot: LegadoEntityBackingSnapshot, keys: [LegadoEntityStateKey], changes: [String: Data?],
                     deadline: Date, cancellation: OriginalRuntimeCommitCancellation,
                     claimCommit: @escaping @Sendable () -> Bool = { true }) async throws -> Bool {
        guard case .app(let value) = snapshot else {
            throw LegadoRuntimeError(code: "INVALID_STATE_OWNER", message: "An App owner cannot consume a preview proof")
        }
        return try await commit(snapshot: value, keys: keys, changes: changes, deadline: deadline, cancellation: cancellation, claimCommit: claimCommit)
    }
}

struct LegadoPreviewEntitySnapshot: Sendable {
    let recordID: String
    let revision: UInt64
    let rawSHA256: String
    let chapterIndex: Int32?
    let chapterURL: String?
    let variables: [String: String]?
    let largeVariables: [String: String]
    let state: LegadoOwnedStateSnapshot
}

/// The existing context actor is the only file owner. This adapter borrows its sealed
/// grant, and the Host uses its ordinary read/commit lease table and task cancellation.
struct LegadoPreviewStateOwner: LegadoEntityStateBacking {
    let grant: OriginalRuntimePreviewGrant

    func revoke() { grant.revoke() }
    func validateRequest(_ request: LegadoHostRequest) throws {
        guard request.taskID == grant.taskID else {
            throw LegadoRuntimeError(code: "INVALID_STATE_OWNER", message: "A preview grant belongs to one original business task")
        }
        if request.operation == "state.commit" { try LegadoPreviewVariableCodec.validateHostChanges(request.requestJSON) }
    }
    func validateState(deadline: Date) async throws {
        try await grant.service.validatePreviewGrant(grant, deadline: deadline)
    }
    func parse(_ wires: [String], sourceURL: String, decodedParts: [String: [String]]) throws -> [LegadoEntityStateKey] {
        try grant.check(deadline: Date().addingTimeInterval(180))
        var result: [LegadoEntityStateKey] = []
        for wire in wires {
            guard let parts = decodedParts[wire], parts.count == 5 || parts.count == 6,
                  LegadoPreviewIdentity.same(parts[0], sourceURL), LegadoPreviewIdentity.same(sourceURL, grant.sourceURL),
                  parts[1] == "variables" || parts[1] == "big-variable",
                  (parts[1] == "variables" ? parts.count == 5 : parts.count == 6),
                  LegadoPreviewIdentity.same(parts[3], grant.bookURL) else { throw Self.failure("Preview key does not match its granted record") }
            let chapterURL: String?
            if parts[2] == "book", parts[4].isEmpty { chapterURL = nil }
            else if parts[2] == "chapter", !parts[4].isEmpty, parts[4].utf8.count <= 8_192,
                    (LegadoPreviewIdentity.same(parts[4], grant.chapterURL) || grant.discoveringChapters) { chapterURL = parts[4] }
            else { throw Self.failure("Preview chapter has not been explicitly granted") }
            result.append(.init(wire: wire, chapterURL: chapterURL, largeVariable: parts.count == 6 ? parts[5] : nil))
        }
        guard let first = result.first, result.allSatisfy({ LegadoPreviewIdentity.same($0.chapterURL, first.chapterURL) }) else {
            throw Self.failure("One entity snapshot must belong to one preview record or chapter")
        }
        return result
    }
    func readState(keys: [LegadoEntityStateKey], deadline: Date,
                   cancellation: OriginalRuntimeCommitCancellation) async throws -> LegadoEntityBackingSnapshot {
        .preview(try await grant.service.readPreviewEntity(grant, keys: keys, deadline: deadline, cancellation: cancellation))
    }
    func commitState(snapshot: LegadoEntityBackingSnapshot, keys: [LegadoEntityStateKey], changes: [String: Data?],
                     deadline: Date, cancellation: OriginalRuntimeCommitCancellation,
                     claimCommit: @escaping @Sendable () -> Bool = { true }) async throws -> Bool {
        guard case .preview(let value) = snapshot else {
            throw LegadoRuntimeError(code: "INVALID_STATE_OWNER", message: "A preview owner cannot consume an App proof")
        }
        return try await grant.service.commitPreviewEntity(grant, snapshot: value, keys: keys,
            changes: changes, deadline: deadline, cancellation: cancellation, claimCommit: claimCommit)
    }
    private static func failure(_ message: String) -> LegadoRuntimeError {
        .init(code: "UNSUPPORTED_CAPABILITY", message: message)
    }
}

/// Explicit original-business execution only. No route selection, JSC or second HTTP jar.
enum LegadoOriginalPreviewOperation: Sendable {
    case loginAction(action: String?, credentials: [String: String], isLongClick: Bool, inputBindingFailed: Bool = false)
    case loginUI([String: String]?, evaluationValues: [String: String]?, reuseState: LegadoOriginalLoginUIReuseState?)
    case formLogin([String: String])
    case persistLoginInfo([String: String])
    case search(String, Int32?)
    case explore(String, Int32?)
    case openExploreContext
    case evaluateExploreContext(String)
    case savePendingExploreContext
    case sourceCallback(String)
    case details(LegadoOriginalBook)
    case toc(LegadoOriginalBook, runPreUpdateJS: Bool)
    case content(LegadoOriginalBook, LegadoOriginalChapter, nextChapterURL: String?)
}

enum LegadoOriginalPreviewResult: Sendable {
    case loginAction(LegadoOriginalLoginActionResult, completedEffects: [String])
    case loginUI(LegadoOriginalLoginUIResult, completedEffects: [String])
    case formLogin(LegadoOriginalFormLoginResult, completedEffects: [String])
    case search([LegadoOriginalBook])
    case explore([LegadoOriginalBook])
    case exploreContext(LegadoOriginalExploreContextResult)
    case sourceCallback(LegadoOriginalSourceCallbackResult, completedEffects: [String])
    case details(LegadoOriginalBook)
    case toc(LegadoOriginalBook, [LegadoOriginalChapter])
    case content(LegadoOriginalBook, LegadoOriginalChapter, String)
}

protocol LegadoOriginalPreviewExecuting: Sendable {
    func execute(sourceJSON: String, sourceURL: String, sourceRevision: String,
                 grant: OriginalRuntimePreviewGrant?, operation: LegadoOriginalPreviewOperation,
                 deadline: Date) async throws -> LegadoOriginalPreviewResult
}

struct NativeLegadoOriginalPreviewExecutor: LegadoOriginalPreviewExecuting {
    static func embeddingOptions(owner: String) -> LegadoSessionOptions {
        .init(httpTransport: .jvmOkHttp, stateOwner: owner, sourceMode: .originalTraditional, cookieAccess: .appOwnerText)
    }
    func execute(sourceJSON: String, sourceURL: String, sourceRevision: String,
                 grant: OriginalRuntimePreviewGrant?, operation: LegadoOriginalPreviewOperation,
                 deadline: Date) async throws -> LegadoOriginalPreviewResult {
        let process = LegadoRuntimeProcess.shared
        let owner: String
        if let grant { owner = try await process.bindPersistentPreview(grant: grant) }
        else { owner = try await process.bindPersistentSource(sourceURL: sourceURL, sourceRevision: sourceRevision) }
        let reportedEffects = OSAllocatedUnfairLock(initialState: [String]())
        let observeEffects: @Sendable ([String]) -> Void = { effects in reportedEffects.withLock { $0 = effects } }
        let reportedLoginUIEvents = OSAllocatedUnfairLock(initialState: [LegadoOriginalLoginUIEvent]())
        let observeLoginUIEvents: @Sendable ([LegadoOriginalLoginUIEvent]) -> Void = { events in
            reportedLoginUIEvents.withLock { $0 = events }
        }
        let loginOperation: Bool
        switch operation { case .loginAction, .formLogin, .persistLoginInfo: loginOperation = true; default: loginOperation = false }
        do {
            let runtime = try await process.executor()
            try check(deadline)
            let session = try await runtime.createSession(sourceJSON: sourceJSON, options: Self.embeddingOptions(owner: owner))
            let result: LegadoOriginalPreviewResult
            do {
                try check(deadline)
                let taskID = grant?.taskID ?? UUID().uuidString
                let remaining = Int64(min(300_000, max(1, deadline.timeIntervalSinceNow * 1000)))
                switch operation {
                case .loginAction(let action, let credentials, let isLongClick, let inputBindingFailed):
                    let value = try await runtime.loginActionOriginal(session: session, action: action,
                        credentials: credentials, isLongClick: isLongClick, inputBindingFailed: inputBindingFailed,
                        timeoutMilliseconds: min(30_000, remaining), taskID: taskID, onReportedEffects: observeEffects,
                        onReportedLoginUIEvents: observeLoginUIEvents)
                    result = .loginAction(value, completedEffects: reportedEffects.withLock { $0 })
                case .loginUI(let values, let evaluationValues, let reuseState):
                    let value = try await runtime.loginUIOriginal(session: session, values: values, evaluationValues: evaluationValues, reuseState: reuseState,
                        timeoutMilliseconds: min(30_000, remaining), taskID: taskID, onReportedEffects: observeEffects)
                    result = .loginUI(value, completedEffects: reportedEffects.withLock { $0 })
                case .persistLoginInfo(let values):
                    let value = try await runtime.persistLoginInfoOriginal(session: session, credentials: values,
                        timeoutMilliseconds: min(30_000, remaining), taskID: taskID, onReportedEffects: observeEffects)
                    result = .formLogin(value, completedEffects: reportedEffects.withLock { $0 })
                case .formLogin(let credentials):
                    let value = try await runtime.formLoginOriginal(session: session, credentials: credentials,
                        timeoutMilliseconds: min(30_000, remaining), taskID: taskID, onReportedEffects: observeEffects,
                        onReportedLoginUIEvents: observeLoginUIEvents)
                    result = .formLogin(value, completedEffects: reportedEffects.withLock { $0 })
                case .sourceCallback(let event):
                    let value = try await runtime.sourceCallbackOriginal(session: session, event: event,
                        timeoutMilliseconds: min(30_000, remaining), taskID: taskID, onReportedEffects: observeEffects)
                    result = .sourceCallback(value, completedEffects: reportedEffects.withLock { $0 })
                case .search(let key, let page):
                    result = .search(try await runtime.searchOriginal(session: session, key: key, page: page, timeoutMilliseconds: remaining, taskID: taskID, onReportedEffects: observeEffects).books)
                case .explore(let url, let page):
                    result = .explore(try await runtime.exploreOriginal(session: session, url: url, page: page,
                        timeoutMilliseconds: remaining, taskID: taskID, onReportedEffects: observeEffects).books)
                case .openExploreContext:
                    result = .exploreContext(try await runtime.openExploreContextOriginal(session: session,
                        timeoutMilliseconds: remaining, taskID: taskID, onReportedEffects: observeEffects))
                case .evaluateExploreContext(let script):
                    result = .exploreContext(try await runtime.evaluateExploreContextOriginal(session: session, script: script,
                        timeoutMilliseconds: remaining, taskID: taskID, onReportedEffects: observeEffects))
                case .savePendingExploreContext:
                    result = .exploreContext(try await runtime.savePendingExploreContextOriginal(session: session,
                        timeoutMilliseconds: remaining, taskID: taskID, onReportedEffects: observeEffects))
                case .details(let book):
                    result = .details(try await runtime.detailsOriginal(session: session, book: book, timeoutMilliseconds: remaining, taskID: taskID, onReportedEffects: observeEffects).book)
                case .toc(let book, let runPreUpdate):
                    let value = try await runtime.chaptersOriginal(session: session, book: book,
                        runPreUpdateJs: runPreUpdate, timeoutMilliseconds: remaining, taskID: taskID, onReportedEffects: observeEffects)
                    result = .toc(value.book, value.chapters)
                case .content(let book, let chapter, let next):
                    // The public runtime encodes needSave=false; a preview cannot grant a
                    // ChapterCacheRepository write or create a BookStore download token.
                    let value = try await runtime.contentOriginal(session: session, book: book, chapter: chapter,
                        nextChapterURL: next, timeoutMilliseconds: remaining, taskID: taskID, onReportedEffects: observeEffects)
                    result = .content(value.book, value.chapter, value.content)
                }
            } catch let executionError {
                do { try await runtime.close(session: session) }
                catch let cleanupError {
                    if loginOperation {
                        throw terminalFailure(executionError,
                            effects: reportedEffects.withLock { $0 },
                            events: reportedLoginUIEvents.withLock { $0 }, cleanupError: cleanupError)
                    }
                    AppLogger.error("Original preview session cleanup failed", error: cleanupError)
                }
                throw executionError
            }
            try await runtime.close(session: session)
            try check(deadline)
            try grant?.sealExecution(deadline: deadline)
            await process.revokePersistentSource(owner: owner)
            grant?.revoke()
            return result
        } catch {
            await process.revokePersistentSource(owner: owner)
            grant?.revoke()
            let failure = error as? LegadoRuntimeError
            let events = failure?.loginUIEvents?.isEmpty == false
                ? failure!.loginUIEvents! : reportedLoginUIEvents.withLock { $0 }
            let effects = Array(Set(reportedEffects.withLock { $0 } + (failure?.completedEffects ?? []))).sorted()
            if !effects.isEmpty || !events.isEmpty || !(failure?.secondaryFailures ?? []).isEmpty {
                throw terminalFailure(error, effects: effects, events: events)
            }
            throw error
        }
    }
    private func terminalFailure(_ error: Error, effects: [String], events: [LegadoOriginalLoginUIEvent],
                                 cleanupError: Error? = nil) -> LegadoRuntimeError {
        let failure = error as? LegadoRuntimeError
        let retained = failure?.loginUIEvents?.isEmpty == false ? failure!.loginUIEvents! : events
        var secondary = failure?.secondaryFailures ?? []
        if let cleanupError {
            let typed = cleanupError as? LegadoRuntimeError
            secondary.append(.init(code: typed?.code ?? "STATE_IO",
                message: "Original session cleanup did not complete"))
        }
        return LegadoRuntimeError(code: failure?.code ?? (error is CancellationError ? "CANCELLED" : "STATE_IO"),
            message: failure?.message ?? "Original invocation did not complete",
            completedEffects: Array(Set(effects + (failure?.completedEffects ?? []))).sorted(),
            loginUIEvents: retained.isEmpty ? nil : retained,
            secondaryFailures: secondary.isEmpty ? nil : secondary)
    }
    private func check(_ deadline: Date) throws {
        try Task.checkCancellation()
        guard deadline.timeIntervalSinceNow > 0 else {
            throw LegadoRuntimeError(code: "TIMEOUT", message: "Preview operation exceeded its absolute deadline")
        }
    }
}
