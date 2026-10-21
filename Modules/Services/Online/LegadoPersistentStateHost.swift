import Foundation
import Combine
import CryptoKit
import CoreFoundation
import WebKit
import CoreFoundation
import LegadoRuntime

/// A short-lived revision proof from the existing App owner, not another store.
struct LegadoOwnedStateSnapshot: Sendable, Equatable {
    let revision: UInt64
    let values: [String: Data]
}

enum LegadoOwnedStateDomain: Sendable, Equatable {
    case sourceVariable, sourceValues, loginHeader
    case cacheText(String), sharedJsLibrary(String)
}

struct LegadoRuntimeCacheEntry: Codable, Sendable, Equatable {
    let deadline: Int64
    let data: String

    init(text: String, deadline: Int64 = 0) {
        self.deadline = deadline
        self.data = Data(text.utf8).base64EncodedString()
    }

    func text() throws -> String {
        guard let bytes = Data(base64Encoded: data),
              let value = String(data: bytes, encoding: .utf8) else {
            throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY", message: "Only UTF-8 cache text is connected to the App owner")
        }
        return value
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

protocol LegadoOwnedStateBacking: Sendable {
    func read(sourceURL: String, domain: LegadoOwnedStateDomain, fields: Set<String>) throws -> LegadoOwnedStateSnapshot
    /// False promises that this transaction changed no value.
    func commit(sourceURL: String, domain: LegadoOwnedStateDomain, expected: LegadoOwnedStateSnapshot,
                changes: [String: Data?]) throws -> Bool
    func loginInfo(sourceURL: String, validate: () throws -> Void, recordEffect: (String) -> Bool) throws -> String?
    func storeLoginInfo(sourceURL: String, value: String?, validate: () throws -> Void, recordEffect: (String) -> Bool) throws -> Bool
    func storeLoginHeader(sourceURL: String, value: String?, validate: () throws -> Void, recordEffect: (String) -> Bool) throws -> Bool
}

extension LegadoOwnedStateBacking {
    func storeLoginHeader(sourceURL: String, value: String?, validate: () throws -> Void, recordEffect: (String) -> Bool) throws -> Bool {
        throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY", message: "The checked App login-header owner is not connected")
    }
    func loginInfo(sourceURL: String, validate: () throws -> Void, recordEffect: (String) -> Bool) throws -> String? {
        throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY", message: "The checked App login-info owner is not connected")
    }
    func storeLoginInfo(sourceURL: String, value: String?, validate: () throws -> Void, recordEffect: (String) -> Bool) throws -> Bool {
        throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY", message: "The checked App login-info owner is not connected")
    }
}

/// Reuses the shipped source, login and cache owners. It never writes a second
/// source database, Cookie jar, chapter directory or shelf metadata file.
struct AppLegadoOwnedStateBacking: @unchecked Sendable, LegadoOwnedStateBacking {
    let sources: BookSourceRuntimeStateStore
    let login: LoginManager

    func loginInfo(sourceURL: String, validate: () throws -> Void, recordEffect: (String) -> Bool) throws -> String? {
        try login.runtimeLoginInfo(sourceUrl: sourceURL, validate: validate, recordEffect: recordEffect)
    }
    func storeLoginInfo(sourceURL: String, value: String?, validate: () throws -> Void, recordEffect: (String) -> Bool) throws -> Bool {
        try login.storeRuntimeLoginInfo(sourceUrl: sourceURL, value: value, validate: validate, recordEffect: recordEffect)
    }

    func storeLoginHeader(sourceURL: String, value: String?, validate: () throws -> Void, recordEffect: (String) -> Bool) throws -> Bool {
        try login.storeRuntimeLoginHeader(sourceUrl: sourceURL, value: value, validate: validate, recordEffect: recordEffect)
    }

    func read(sourceURL: String, domain: LegadoOwnedStateDomain, fields: Set<String>) throws -> LegadoOwnedStateSnapshot {
        switch domain {
        case .sourceVariable: return sources.runtimeVariableSnapshot(for: sourceURL)
        case .sourceValues: return sources.runtimeValuesSnapshot(for: sourceURL, keys: fields)
        case .loginHeader: return login.runtimeHeaderSnapshot(sourceUrl: sourceURL)
        case .cacheText(let key): return try LegadoCacheBridge.runtimeSnapshot(sourceId: sourceURL, key: key)
        case .sharedJsLibrary(let key):
            return try LegadoCacheBridge.runtimeSnapshot(sourceId: sourceURL, key: key, namespace: .sharedJsLibrary)
        }
    }

    func commit(sourceURL: String, domain: LegadoOwnedStateDomain, expected: LegadoOwnedStateSnapshot,
                changes: [String: Data?]) throws -> Bool {
        switch domain {
        case .sourceVariable:
            return sources.compareRuntimeVariable(for: sourceURL, expected: expected, value: changes["value"] ?? nil)
        case .sourceValues:
            return sources.compareRuntimeValues(for: sourceURL, expected: expected, changes: changes)
        case .loginHeader:
            return login.compareRuntimeHeader(sourceUrl: sourceURL, expected: expected, value: changes["value"] ?? nil)
        case .cacheText(let key):
            return try LegadoCacheBridge.compareRuntimeEntry(sourceId: sourceURL, key: key,
                expected: expected, value: changes["value"] ?? nil)
        case .sharedJsLibrary(let key):
            return try LegadoCacheBridge.compareRuntimeEntry(sourceId: sourceURL, key: key,
                expected: expected, value: changes["value"] ?? nil, namespace: .sharedJsLibrary)
        }
    }
}

/// JNI's existing HostCallback now has an explicitly bound state adapter.
/// Bindings are granted by the embedding App; imported JSON never grants an
/// owner or selects a filesystem path. Book/chapter identity requires bindBook; complete
/// Cookie storage and transactions spanning independent App owners remain unsupported.
/// One live presentation request borrows its existing checked source/task.
/// No credentials, JS evaluator, persistent state or new source owner live here.
/// Transient lease metadata generated by the admitted JVM producer, never a new
/// source/session grant supplied by page JavaScript.
struct LegadoOriginalWebPageDescriptor: Decodable, Sendable {
    let pageId: String
    let sessionId: String
    let parentTaskId: String
    let javaName: String
    let cacheName: String
    let resultName: String
}

struct LegadoOriginalWebJSCall: Codable, Sendable {
    let method: String
    let params: [String?]
    let function: String?
    let requestId: String?
}

struct LegadoOriginalWebJSReply: Codable, Sendable {
    let kind: String
    let value: String?
    let values: [String]?
    let requestId: String?
    let success: Bool?
}

struct LegadoOriginalWebPageLease: Sendable {
    let descriptor: LegadoOriginalWebPageDescriptor
    let request: @Sendable (LegadoOriginalWebJSCall) async throws -> LegadoOriginalWebJSReply
    let close: @Sendable () async throws -> Void
}

struct LegadoOriginalBrowserPresentation: Sendable {
    let taskID: String
    let url: String
    let title: String
    let headers: [String: String]
    /// Present, including empty, only for original JVM POST prefetch. Never local WebJS.
    let prefetchedHTML: String?
    let awaitsResult: Bool
    let refetchAfterSuccess: Bool
    let deadline: Date
    let authorize: @Sendable () async throws -> Void
    /// Synchronous commit guard for the existing Cookie actor. Source revision
    /// revocation cancels this same grant; Presenter adds its own task token.
    let validateCommit: @Sendable () throws -> Void
    let recordEffect: @Sendable (String) -> Bool
    let localPage: LegadoOriginalWebPageLease?
}

/// Finite live page receipt, separate from deduplicated status/effect strings.
/// Presented never counts as an awaited terminal result.
enum LegadoOriginalBrowserCompletion: Sendable {
    case presented
    case response(finalURL: String, body: String)
    case refetchConfirmed
}

/// A page's transient observation of the existing source owner. The only
/// memoized fact is which store mutation this lease has already validated;
/// source values and their persistent ownership remain in BookSourceStore.
@MainActor
private final class OriginalWebSourceAdmission {
    private let store: BookSourceStore
    private let sourceID: UUID
    private let expected: String
    private let invalidate: @Sendable () -> Void
    private var tracked: Bool
    private var invalidated = false
    private var ended = false
    private var validatedRevision: Int?
    private var checking: (revision: Int, work: Task<Bool, Error>)?
    private var observation: AnyCancellable?
    private var observationWork: Task<Void, Never>?

    init(sourceID: UUID, expected: String, initiallyTracked: Bool, invalidate: @escaping @Sendable () -> Void) {
        self.tracked = initiallyTracked
        self.store = .shared; self.sourceID = sourceID; self.expected = expected; self.invalidate = invalidate
        // @Published emits in willSet. The owned MainActor task reads the
        // updated index after that synchronous owner mutation has completed.
        observation = store.sourcesPublisher.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let previous = self.observationWork
                previous?.cancel()
                self.observationWork = Task { @MainActor [weak self] in
                    if let previous { await previous.value }
                    guard let self, !Task.isCancelled, !self.ended else { return }
                    do { try await self.validate() }
                    catch {
                        if !self.ended && !Task.isCancelled { self.reject() }
                    }
                }
            }
        }
    }

    func validate() async throws {
        await store.waitUntilLoaded()
        while true {
            try Task.checkCancellation()
            guard !ended, !invalidated, let snapshot = store.runtimeIndexedSnapshot(id: sourceID) else {
                throw LegadoRuntimeError(code: "SOURCE_CHANGED", message: "Original page source is unavailable")
            }
            if validatedRevision == snapshot.revision { return }
            let work: Task<Bool, Error>
            if let checking, checking.revision == snapshot.revision { work = checking.work }
            else {
                let source = snapshot.source, required = tracked, expected = expected
                work = Task { try await Self.matches(source, required: required, expected: expected) }
                checking = (snapshot.revision, work)
            }
            do {
                let present = try await work.value
                try Task.checkCancellation()
                guard !ended, !invalidated else { throw CancellationError() }
                tracked = tracked || present
                // A concurrent store edit must be validated too; a completed
                // older snapshot never admits a later child or final reply.
                guard store.runtimeIndexedSnapshot(id: sourceID)?.revision == snapshot.revision else { continue }
                validatedRevision = snapshot.revision
                return
            } catch {
                if !ended && !Task.isCancelled { reject() }
                throw error
            }
        }
    }

    func end() async {
        ended = true
        observation?.cancel(); observation = nil
        let running = observationWork
        observationWork = nil
        running?.cancel()
        checking?.work.cancel()
        if let running { await running.value }
    }

    private func reject() {
        guard !invalidated else { return }
        invalidated = true
        invalidate()
    }

    nonisolated private static func matches(_ source: BookSource?, required: Bool, expected: String) async throws -> Bool {
        try SourcePerfTrace.span("legado.original.webjs.source", "main=\(Thread.isMainThread) sources=1") {
            try Task.checkCancellation()
            guard var source else {
                if required { throw LegadoRuntimeError(code: "SOURCE_CHANGED", message: "Original page source was removed") }
                // Public finite consumers may supply an immutable, unsaved
                // source. Once its id is present in the owner it is tracked.
                return false
            }
            source.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            source.lastUpdateTime = 0; source.respondTime = 180000
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let bytes = try encoder.encode(source)
            try Task.checkCancellation()
            let signature = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard signature == expected else {
                throw LegadoRuntimeError(code: "SOURCE_CHANGED", message: "Original page source was edited")
            }
            return true
        }
    }
}

actor LegadoPersistentStateHost: LegadoPlatformHost {
    private struct Binding {
        let sourceURL: String
        let sourceRevision: String
        let cookieCancellation = OriginalRuntimeCommitCancellation()
    }
    private struct Key {
        let wire: String
        let domain: LegadoOwnedStateDomain
        let field: String
        let binaryCompanion: Bool
    }
    private struct Lease {
        let owner: String
        let binding: Binding
        let keys: [Key]
        let snapshot: LegadoOwnedStateSnapshot
    }
    private struct EntityLease {
        let owner: String
        let binding: Binding
        let backing: any LegadoEntityStateBacking
        let keys: [LegadoEntityStateKey]
        let snapshot: LegadoEntityBackingSnapshot
    }
    // Identity of this existing backing owner instance, not storage authority.
    // It is stable across short-lived grants and never persisted as a new store.
    private let exploreScopeIdentity = UUID().uuidString
    private let cookieOwner: CookieStore
    private let originalWebCookieStore: @MainActor @Sendable () -> WKHTTPCookieStore
    private let originalBrowserPresenter: @MainActor @Sendable (LegadoOriginalBrowserPresentation) async throws -> LegadoOriginalBrowserCompletion
    private let backing: any LegadoOwnedStateBacking
    private let fallback: any LegadoPlatformHost
    // Resource participation only: these retain the already granted Binding,
    // runtime and session. They own no credentials, cache values or source state.
    private final class OriginalInvocation {
        let runtime: LegadoRuntime
        let session: LegadoSourceSession
        let taskID: String
        let sourceID: UUID?
        let sourceInitiallyTracked: Bool
        var sourceAdmission: OriginalWebSourceAdmission?
        var producerEnded = false
        var invalidated = false
        var pages: [String: OriginalPage] = [:]
        var cleanup: Task<Void, Error>?
        init(runtime: LegadoRuntime, session: LegadoSourceSession, taskID: String, sourceID: UUID?, initiallyTracked: Bool) {
            self.sourceInitiallyTracked = initiallyTracked
            self.runtime = runtime; self.session = session; self.taskID = taskID; self.sourceID = sourceID
        }
    }
    private final class OriginalPage {
        let descriptor: LegadoOriginalWebPageDescriptor
        let parentDeadline: Date?
        let cancellation = OriginalRuntimeCommitCancellation()
        let recordEffect: @Sendable (String) -> Bool
        var children: [UUID: Task<LegadoOriginalWebJSReply, Error>] = [:]
        var closing: Task<Void, Error>?
        init(_ descriptor: LegadoOriginalWebPageDescriptor, parentDeadline: Date?, recordEffect: @escaping @Sendable (String) -> Bool) {
            self.descriptor = descriptor; self.parentDeadline = parentDeadline; self.recordEffect = recordEffect
        }
    }
    private var originalInvocations: [String: OriginalInvocation] = [:]
    private var originalChildInvocations: [String: (owner: String, pageID: String)] = [:]
    private var originalHeadlessOperations: [String: (taskID: String, work: Task<LegadoOriginalHeadlessResult, Error>)] = [:]
    private var originalInvalidations: [String: Task<Void, Never>] = [:]

    private var bindings: [String: Binding] = [:]
    private var revisions: [String: String] = [:]
    private var leases: [Int64: Lease] = [:]
    private var bookOwners: [String: any LegadoEntityStateBacking] = [:]
    private var entityLeases: [Int64: EntityLease] = [:]
    private struct ContentLease {
        let owner: String; let binding: Binding; let backing: AppLegadoContentBatchOwner
        let keys: [LegadoContentStateKey]; let snapshot: LegadoContentStateSnapshot
    }
    private struct PreviewTOCLease {
        let owner: String; let binding: Binding; let grant: OriginalRuntimePreviewGrant
        let snapshot: LegadoPreviewTOCStateSnapshot
    }
    private var previewTOCLeases: [Int64: PreviewTOCLease] = [:]
    private var contentOwners: [String: AppLegadoContentBatchOwner] = [:]
    private var contentLeases: [Int64: ContentLease] = [:]
    private var pendingEntityOperations: [String: [UUID: OriginalRuntimeCommitCancellation]] = [:]
    private struct OriginalWebCookieOperation {
        let owner: String
        let task: Task<Void, Error>
    }
    private var pendingWebCookieOperations: [String: [UUID: OriginalWebCookieOperation]] = [:]
    private var leaseOrder: [Int64] = []
    private var nextLease: Int64 = 0
    private var cancelled = Set<String>()
    private var cancellationOrder: [String] = []

    init(backing: any LegadoOwnedStateBacking, fallback: any LegadoPlatformHost = UnsupportedLegadoHost(), cookieOwner: CookieStore = .shared,
         originalWebCookieStore: @escaping @MainActor @Sendable () -> WKHTTPCookieStore = { WKWebsiteDataStore.default().httpCookieStore },
         originalBrowserPresenter: @escaping @MainActor @Sendable (LegadoOriginalBrowserPresentation) async throws -> LegadoOriginalBrowserCompletion = {
             try await SourceBrowserPresenter.presentOriginal($0)
         }) {
        self.cookieOwner = cookieOwner
        self.originalWebCookieStore = originalWebCookieStore
        self.originalBrowserPresenter = originalBrowserPresenter
        self.backing = backing
        self.fallback = fallback
    }

    /// Call with the owning App's immutable source snapshot. Rebinding a changed
    /// source revokes prior grants and pending CAS proofs for that source.
    func bind(sourceURL: String, sourceRevision: String) throws -> String {
        guard !sourceURL.isEmpty, sourceURL.utf8.count <= 8_192,
              !sourceRevision.isEmpty, sourceRevision.utf8.count <= 256 else {
            throw failure("INVALID_STATE_OWNER", "An explicit source identity and revision are required")
        }
        if revisions[sourceURL] != sourceRevision {
            for (owner, binding) in bindings where binding.sourceURL == sourceURL {
                binding.cookieCancellation.cancel()
                invalidateOriginalInvocation(owner: owner)
                cancelWebCookieOperations(owner: owner)
                bookOwners.removeValue(forKey: owner)?.revoke()
                contentOwners.removeValue(forKey: owner)
            }
            bindings = bindings.filter { $0.value.sourceURL != sourceURL }
            leases = leases.filter { $0.value.binding.sourceURL != sourceURL }
            entityLeases = entityLeases.filter { $0.value.binding.sourceURL != sourceURL }
            contentLeases = contentLeases.filter { $0.value.binding.sourceURL != sourceURL }
            previewTOCLeases = previewTOCLeases.filter { $0.value.binding.sourceURL != sourceURL }
        }
        guard bindings.count < 256 else { throw failure("STATE_LIMIT", "Too many active source state owners") }
        let owner = UUID().uuidString
        revisions[sourceURL] = sourceRevision
        bindings[owner] = Binding(sourceURL: sourceURL, sourceRevision: sourceRevision)
        return owner
    }

    /// The embedding reader supplies the actual store/UUID and (for chapters) a grant
    /// borrowed from its active pipeline generation. Nothing is inferred from a URL.
    func bindBook(sourceURL: String, sourceRevision: String, store: BookStore,
                  bookID: UUID, sourceID: UUID, bookURL: String,
                  chapter: OnlineChapterRef? = nil, generation: OriginalRuntimeChapterGeneration? = nil,
                  callbackTaskID: String? = nil) async throws -> String {
        let previousRevision = revisions[sourceURL]
        guard await store.prepareOriginalRuntimeBookSnapshot(id: bookID, sourceID: sourceID, bookURL: bookURL) != nil else {
            throw failure("UNSUPPORTED_CAPABILITY", "The App book/source identity has no current stable owner")
        }
        let backing = try AppLegadoBookStateOwner(store: store, bookID: bookID, sourceID: sourceID,
            bookURL: bookURL, chapter: chapter, generation: generation, callbackTaskID: callbackTaskID)
        if let chapter {
            let proof: BookChapterStore.RuntimeVariablesSnapshot?
            do { proof = try await store.originalRuntimeChapterSnapshot(bookID: bookID, index: chapter.index, url: chapter.url) }
            catch let error as LegadoRuntimeError { throw error }
            catch is CancellationError { throw CancellationError() }
            catch {
                AppLogger.error("JVM App chapter owner could not be read", error: error)
                throw failure("STATE_IO", "The App chapter owner could not be read")
            }
            guard proof?.chapterID == chapter.id else { throw failure("UNSUPPORTED_CAPABILITY", "The App chapter identity is no longer current") }
        }
        try Task.checkCancellation()
        guard revisions[sourceURL] == previousRevision else {
            throw failure("INVALID_STATE_OWNER", "The source revision changed while granting its App book")
        }
        try backing.validate(deadline: Date().addingTimeInterval(180))
        let owner = try bind(sourceURL: sourceURL, sourceRevision: sourceRevision)
        bookOwners[owner] = backing
        return owner
    }

    func bindContentBatch(sourceURL: String, sourceRevision: String, taskID: String, store: BookStore,
                          bookID: UUID, sourceID: UUID, book: LegadoOriginalBook,
                          chapters: [OriginalRuntimeBatchChapter], deadline: Date,
                          cache: ChapterCacheRepository = BookSourceFetcher.chapterCacheRepository,
                          singleChapter: Bool = false) async throws -> String {
        let previous = revisions[sourceURL]
        guard book.origin.utf8.elementsEqual(sourceURL.utf8),
              await store.prepareOriginalRuntimeBookSnapshot(id: bookID, sourceID: sourceID, bookURL: book.bookURL) != nil else {
            throw failure("UNSUPPORTED_CAPABILITY", "Batch requires an existing App book/source UUID")
        }
        let backing = try AppLegadoContentBatchOwner(taskID: taskID, store: store, bookID: bookID, sourceID: sourceID,
            book: book, chapters: chapters, deadline: deadline, cache: cache, singleChapter: singleChapter)
        for value in chapters {
            guard let current = try await store.originalRuntimeChapterSnapshot(bookID: bookID,
                index: value.chapter.index, url: value.chapter.url), current.chapterID == value.chapter.id else {
                throw failure("UNSUPPORTED_CAPABILITY", "Batch chapter TOC identity is no longer current")
            }
            try value.generation.check(deadline: deadline)
        }
        try await backing.prepareBookCompletion(deadline: deadline)
        try Task.checkCancellation(); try await backing.validateState(deadline: deadline)
        guard revisions[sourceURL] == previous else { throw failure("SOURCE_CHANGED", "Source changed while binding the App batch owner") }
        let owner = try bind(sourceURL: sourceURL, sourceRevision: sourceRevision)
        bookOwners[owner] = backing; contentOwners[owner] = backing
        return owner
    }

    func finishContentBatchResult(owner: String, taskID: String, book: LegadoOriginalBook, deadline: Date) async throws -> Bool {
        try Task.checkCancellation()
        guard !cancelled.contains(taskID) else { throw CancellationError() }
        guard let binding = bindings[owner], revisions[binding.sourceURL] == binding.sourceRevision,
              let backing = contentOwners[owner], backing.taskID == taskID else {
            throw failure("INVALID_STATE_OWNER", "Batch completion no longer has its current source/task grant")
        }
        return try await backing.finishResultBook(book, deadline: deadline)
        // A final CAS can already be durable. Do not convert a late revoke/cancel
        // into false/no-mutation after its actual accepted receipt.
    }

    func finishSingleContentResult(owner: String, taskID: String, result: LegadoOriginalContentResult,
                                   deadline: Date) async throws -> [String] {
        try Task.checkCancellation()
        guard !cancelled.contains(taskID), let binding = bindings[owner],
              revisions[binding.sourceURL] == binding.sourceRevision,
              let backing = contentOwners[owner], backing.taskID == taskID else {
            throw failure("INVALID_STATE_OWNER", "Single result lost its source/task/chapter owner")
        }
        return try await backing.finishSingleContent(result, deadline: deadline)
    }

    /// Only the existing context actor can issue this proof. Source JSON/reference text
    /// alone cannot manufacture a preview grant or acquire a library UUID.
    func bindPreview(grant: OriginalRuntimePreviewGrant) async throws -> String {
        let previousRevision = revisions[grant.sourceURL]
        let backing = LegadoPreviewStateOwner(grant: grant)
        try await backing.validateState(deadline: Date().addingTimeInterval(180))
        try Task.checkCancellation()
        guard revisions[grant.sourceURL] == previousRevision else {
            throw failure("INVALID_STATE_OWNER", "The source changed while granting its preview record")
        }
        try grant.check(deadline: Date().addingTimeInterval(180))
        let owner = try bind(sourceURL: grant.sourceURL, sourceRevision: grant.sourceRevision)
        bookOwners[owner] = backing
        return owner
    }

    func revoke(owner: String) {
        invalidateOriginalInvocation(owner: owner)
        let removed = bindings.removeValue(forKey: owner)
        removed?.cookieCancellation.cancel()
        cancelWebCookieOperations(owner: owner)
        bookOwners.removeValue(forKey: owner)?.revoke()
        contentOwners.removeValue(forKey: owner)
        contentLeases = contentLeases.filter { $0.value.owner != owner }
        previewTOCLeases = previewTOCLeases.filter { $0.value.owner != owner }
        leases = leases.filter { $0.value.owner != owner }
        entityLeases = entityLeases.filter { $0.value.owner != owner }
        if let removed, !bindings.values.contains(where: { $0.sourceURL == removed.sourceURL }) {
            revisions.removeValue(forKey: removed.sourceURL)
        }
    }

    /// Value-free diagnostics for verifying bounded ownership bookkeeping.
    func ownershipCounts() -> (bindings: Int, sourceRevisions: Int, leases: Int) {
        (bindings.count, revisions.count, leases.count + entityLeases.count + contentLeases.count + previewTOCLeases.count)
    }

    func dispatch(_ request: LegadoHostRequest) async throws -> String {
        if let child = originalChildInvocations[request.taskID] {
            try await validateOriginalChildHost(owner: child.owner, pageID: child.pageID)
        }
        if request.operation == "source.browser" { return try await presentSourceBrowser(request) }
        if request.operation == "source.webview" { return try await runOriginalHeadless(request) }
        if request.operation == "source.login-info" { return try sourceLoginInfo(request) }
        if request.operation == "source.login-header" { return try sourceLoginHeader(request) }
        if request.operation == "content.batch.authorize" { return try authorizeContentBatch(request) }
        if request.operation == "book.refresh.identity" { return try await refreshBookIdentity(request) }
        if request.operation == "explore.owner.scope" { return try explorationOwnerScope(request) }
        if request.operation == "cookie.owner.read" { return try await readCookieOwner(request) }
        if request.operation == "cookie.owner.text" { return try await textCookieOwner(request) }
        if request.operation != "state.read" && request.operation != "state.commit" {
            return try await fallback.dispatch(request)
        }
        try check(request)
        do {
          let decoded = try decodeStateRequest(request)
          let input = decoded.input; let owner = decoded.owner; let binding = decoded.binding
          if let result = try await dispatchPreviewTOCStateIfNeeded(request, decoded: decoded) { return result }
          if let result = try await dispatchContentStateIfNeeded(request, decoded: decoded) { return result }
          if let result = try await dispatchEntityStateIfNeeded(request, decoded: decoded) { return result }
          return try SourcePerfTrace.span("legado.state.host", "bytes=\(request.requestJSON.utf8.count) main=\(Thread.isMainThread)") {
            if request.operation == "state.read" {
                let rawKeys = decoded.keys!
                let keys = try parse(rawKeys, binding: binding, decodedParts: decoded.parts)
                let snapshot = try backing.read(sourceURL: binding.sourceURL, domain: keys[0].domain,
                    fields: Set(keys.filter { !$0.binaryCompanion }.map(\.field)))
                try check(request)
                guard nextLease < Int64.max else { throw failure("STATE_LIMIT", "State revision space exhausted") }
                var values: [String: String] = [:]
                var total = 0
                for key in keys where !key.binaryCompanion {
                    if let value = snapshot.values[key.field] {
                        let wire = try wireValue(value, domain: key.domain)
                        total += wire.count
                        guard total <= 1_048_576 else { throw failure("STATE_LIMIT", "State read exceeds its byte limit") }
                        values[key.wire] = wire.base64EncodedString()
                    }
                }
                nextLease += 1
                leases[nextLease] = Lease(owner: owner, binding: binding, keys: keys, snapshot: snapshot)
                leaseOrder.append(nextLease)
                trimLeases()
                return try encoded(["revision": nextLease, "values": values])
            }
            guard let revision = decoded.revision,
                  let rawChanges = input["changes"] as? [String: Any], !rawChanges.isEmpty, rawChanges.count <= 64 else {
                throw failure("INVALID_STATE_REQUEST", "State commit requires a revision and bounded changes")
            }
            guard let lease = leases.removeValue(forKey: revision), lease.owner == owner,
                  lease.binding.sourceURL == binding.sourceURL,
                  lease.binding.sourceRevision == binding.sourceRevision else { return try encoded(["committed": false]) }
            let allowed = Dictionary(uniqueKeysWithValues: lease.keys.map { ($0.wire, $0) })
            guard rawChanges.keys.allSatisfy({ allowed[$0] != nil }) else {
                throw failure("INVALID_STATE_REQUEST", "State commit changed an unread key")
            }
            var changes: [String: Data?] = [:]
            for (wire, raw) in rawChanges {
                let key = allowed[wire]!
                if key.binaryCompanion {
                    guard raw is NSNull else { throw failure("UNSUPPORTED_CAPABILITY", "App binary cache storage is not connected") }
                    continue
                }
                if raw is NSNull { changes.updateValue(nil, forKey: key.field) }
                else {
                    guard let text = raw as? String, text.utf8.count <= 1_398_104,
                          let value = Data(base64Encoded: text), value.count <= 1_048_576 else {
                        throw failure("STATE_LIMIT", "State value is malformed or oversized")
                    }
                    changes.updateValue(try storedValue(value, domain: key.domain), forKey: key.field)
                }
            }
            try check(request)
            let committed: Bool
            if changes.isEmpty {
                committed = try backing.read(sourceURL: binding.sourceURL, domain: lease.keys[0].domain,
                    fields: Set(lease.keys.filter { !$0.binaryCompanion }.map(\.field))) == lease.snapshot
            } else {
                guard request.recordPossibleEffect("sourceStateMayCommit") else { throw CancellationError() }
                committed = try backing.commit(sourceURL: binding.sourceURL,
                    domain: lease.keys[0].domain, expected: lease.snapshot, changes: changes)
                if committed { request.recordPossibleEffect("sourceStateCommitted") }
            }
            // The synchronous owner commit is the transaction boundary. Once
            // it succeeds, report that fact rather than pretend a late cancel
            // rolled the existing owner's accepted mutation back.
            return try encoded(["committed": committed])
          }
        } catch let error as LegadoRuntimeError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch {
            AppLogger.error("JVM source state owner failed", error: error)
            throw failure("STATE_IO", "The App state owner did not complete the request")
        }
    }

    /// Registered by the existing Preview executor before any producer code.
    func attachOriginalInvocation(owner: String, runtime: LegadoRuntime,
                                  session: LegadoSourceSession, taskID: String, sourceID: UUID?) async throws {
        guard let binding = bindings[owner], revisions[binding.sourceURL] == binding.sourceRevision,
              originalInvocations[owner] == nil, !taskID.isEmpty,
              session.sourceMode == .originalTraditional else {
            throw failure("INVALID_STATE_OWNER", "Original invocation lost its admitted source/session")
        }
        let initiallyTracked: Bool
        if let sourceID {
            await BookSourceStore.shared.waitUntilLoaded()
            let presence = await MainActor.run { () -> Bool? in
                guard let snapshot = BookSourceStore.shared.runtimeIndexedSnapshot(id: sourceID) else { return nil }
                return snapshot.source != nil
            }
            guard let presence else { throw failure("STATE_IO", "Original source owner is unavailable") }
            initiallyTracked = presence
        } else { initiallyTracked = false }
        guard let current = bindings[owner], current.sourceURL == binding.sourceURL,
              current.sourceRevision == binding.sourceRevision,
              revisions[current.sourceURL] == current.sourceRevision, originalInvocations[owner] == nil else {
            throw failure("INVALID_STATE_OWNER", "Original invocation changed while attaching its source identity")
        }
        originalInvocations[owner] = OriginalInvocation(runtime: runtime, session: session,
            taskID: taskID, sourceID: sourceID, initiallyTracked: initiallyTracked)
    }

    func finishOriginalInvocation(owner: String, taskID: String, cancelPages: Bool) async throws {
        guard let invocation = originalInvocations[owner] else { return }
        guard invocation.taskID == taskID else {
            throw failure("INVALID_STATE_OWNER", "Original invocation completion is not current")
        }
        invocation.producerEnded = true
        if cancelPages {
            invocation.invalidated = true
            for page in invocation.pages.values { page.cancellation.cancel() }
            await SourceBrowserPresenter.cancelOriginal(taskID: taskID)
            await cancelOriginalHeadless(taskID: taskID)
            for pageID in Array(invocation.pages.keys) {
                try await closeOriginalWebPage(owner: owner, pageID: pageID)
            }
        }
        try await cleanupOriginalInvocationIfIdle(owner: owner)
    }

    private func cleanupOriginalInvocationIfIdle(owner: String) async throws {
        guard let invocation = originalInvocations[owner], invocation.producerEnded,
              invocation.pages.isEmpty else { return }
        if let cleanup = invocation.cleanup { return try await cleanup.value }
        let runtime = invocation.runtime, session = invocation.session
        let cleanup = Task { try await runtime.close(session: session) }
        invocation.cleanup = cleanup
        defer {
            originalInvocations.removeValue(forKey: owner)
            originalInvalidations.removeValue(forKey: owner)
            revoke(owner: owner)
        }
        do { try await cleanup.value }
        catch {
            await invocation.sourceAdmission?.end()
            throw error
        }
        await invocation.sourceAdmission?.end()
    }

    private func invalidateOriginalInvocation(owner: String) {
        guard let invocation = originalInvocations[owner], !invocation.invalidated else { return }
        invocation.invalidated = true
        for page in invocation.pages.values {
            page.cancellation.cancel()
            for child in page.children.values { child.cancel() }
        }
        let runtime = invocation.runtime, taskID = invocation.taskID
        originalInvalidations[owner] = Task { [weak self] in
            // Cancel independently of the blocked parent's source gate. The
            // existing Host cancel path waits for real page/child drains.
            do { try await runtime.cancel(taskID: taskID) }
            catch { AppLogger.error("Original page cancellation failed", error:
                LegadoRuntimeError(code: (error as? LegadoRuntimeError)?.code ?? "STATE_IO",
                    message: "Original page cancellation did not complete")) }
            await self?.endOriginalInvalidation(owner: owner)
        }
    }

    private func endOriginalInvalidation(owner: String) {
        originalInvalidations.removeValue(forKey: owner)
    }

    private func makeOriginalWebPage(_ raw: Any, request: LegadoHostRequest,
                                    owner: String, parentDeadline: Date?) async throws -> LegadoOriginalWebPageLease {
        let keys: Set<String> = ["pageId", "sessionId", "parentTaskId", "javaName", "cacheName", "resultName"]
        guard let fields = raw as? [String: String], Set(fields.keys) == keys,
              fields.values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
              let invocation = originalInvocations[owner], !invocation.invalidated, !invocation.producerEnded,
              invocation.session.id == fields["sessionId"], invocation.taskID == request.taskID,
              fields["parentTaskId"] == request.taskID else {
            throw failure("INVALID_STATE_OWNER", "Local page requires its current original invocation")
        }
        if invocation.sourceAdmission == nil {
            guard let sourceID = invocation.sourceID, let binding = bindings[owner] else {
                throw failure("INVALID_STATE_OWNER", "Local page requires its admitted source identity")
            }
            let admission = await OriginalWebSourceAdmission(sourceID: sourceID, expected: binding.sourceRevision,
                initiallyTracked: invocation.sourceInitiallyTracked,
                invalidate: { [weak self] in Task { await self?.invalidateOriginalInvocation(owner: owner) } })
            invocation.sourceAdmission = admission
        }
        try await invocation.sourceAdmission?.validate()
        guard originalInvocations[owner] === invocation, !invocation.invalidated, bindings[owner] != nil else {
            throw CancellationError()
        }
        for key in ["javaName", "cacheName", "resultName"] {
            let value = fields[key]!
            let first = Set("_$abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
            let rest = first.union(Set("0123456789".utf8))
            guard value.utf8.count <= 128, let leading = value.utf8.first, first.contains(leading),
                  value.utf8.allSatisfy({ rest.contains($0) }) else {
                throw failure("INVALID_STATE_REQUEST", "Local page aliases must be bounded identifiers")
            }
        }
        guard Set([fields["javaName"]!, fields["cacheName"]!, fields["resultName"]!]).count == 3 else {
            throw failure("INVALID_STATE_REQUEST", "Local page aliases must be distinct")
        }
        let descriptor = LegadoOriginalWebPageDescriptor(pageId: fields["pageId"]!,
            sessionId: fields["sessionId"]!, parentTaskId: fields["parentTaskId"]!,
            javaName: fields["javaName"]!, cacheName: fields["cacheName"]!, resultName: fields["resultName"]!)
        guard invocation.pages[descriptor.pageId] == nil else {
            throw failure("INVALID_STATE_REQUEST", "Local page identity was already admitted")
        }
        invocation.pages[descriptor.pageId] = OriginalPage(descriptor, parentDeadline: parentDeadline, recordEffect: { request.recordPossibleEffect($0) })
        return .init(descriptor: descriptor, request: { [weak self] call in
            guard let self else { throw CancellationError() }
            return try await self.requestOriginalWebPage(owner: owner, pageID: descriptor.pageId, call: call)
        }, close: { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.closeOriginalWebPage(owner: owner, pageID: descriptor.pageId)
        })
    }

    private func validateOriginalChildHost(owner: String, pageID: String) async throws {
        guard let invocation = originalInvocations[owner], !invocation.invalidated,
              let page = invocation.pages[pageID], page.closing == nil,
              let binding = bindings[owner], revisions[binding.sourceURL] == binding.sourceRevision else {
            throw failure("INVALID_STATE_OWNER", "Original page child no longer owns its source")
        }
        try await invocation.sourceAdmission?.validate()
        let deadline = page.parentDeadline ?? .distantFuture
        try page.cancellation.check(deadline: deadline)
        try binding.cookieCancellation.check(deadline: deadline)
    }

    private func requestOriginalWebPage(owner: String, pageID: String,
                                       call: LegadoOriginalWebJSCall,
                                       nativePolicy: Bool = false) async throws -> LegadoOriginalWebJSReply {
        let requestDeadline = Date().addingTimeInterval(30)
        guard let invocation = originalInvocations[owner], !invocation.invalidated,
              let page = invocation.pages[pageID], page.closing == nil,
              let binding = bindings[owner], revisions[binding.sourceURL] == binding.sourceRevision else {
            throw failure("INVALID_STATE_OWNER", "Original page is no longer admitted")
        }
        let deadline = min(requestDeadline, page.parentDeadline ?? .distantFuture)
        try await invocation.sourceAdmission?.validate()
        try page.cancellation.check(deadline: deadline)
        try binding.cookieCancellation.check(deadline: deadline)
        guard page.children.count < 32, call.method.utf8.count <= 128, call.params.count <= 64,
              call.params.reduce(0, { $0 + ($1?.utf8.count ?? 0) }) <= 4 * 1024 * 1024,
              (call.function?.utf8.count ?? 0) <= 128, (call.requestId?.utf8.count ?? 0) <= 256 else {
            throw failure("STATE_LIMIT", "Original page request exceeds its budget")
        }
        struct Input: Encodable {
            let pageId: String; let method: String; let params: [String?]
            let function: String?; let requestId: String?; let timeoutMs: Int
        }
        struct Output: Decodable { let result: LegadoOriginalWebJSReply }
        struct Facts: Decodable { let completedEffects: [String]? }
        let input = Input(pageId: pageID, method: call.method, params: call.params,
            function: call.function, requestId: call.requestId,
            timeoutMs: min(30_000, max(1, Int(deadline.timeIntervalSinceNow * 1000))))
        let requestJSON = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        let runtime = invocation.runtime, session = invocation.session
        let childID = UUID(), taskID = UUID().uuidString
        originalChildInvocations[taskID] = (owner, pageID)
        let child = Task { () throws -> LegadoOriginalWebJSReply in
            try await SourcePerfTrace.spanAsync("legado.original.webjs.request",
                "main=\(Thread.isMainThread) bytes=\(requestJSON.utf8.count)") {
                let raw = try await runtime.execute(session: session, operation: nativePolicy ? "generalWebPolicy" : "webJsRequest",
                    requestJSON: requestJSON, taskID: taskID)
                guard raw.utf8.count <= 8 * 1024 * 1024 + 65_536 else {
                    throw LegadoRuntimeError(code: "STATE_LIMIT", message: "Original page response exceeds its budget")
                }
                let bytes = Data(raw.utf8)
                let facts = try JSONDecoder().decode(Facts.self, from: bytes)
                // Retain accepted facts before DTO decoding. A bad business
                // response cannot erase an earlier irreversible Host commit.
                for effect in facts.completedEffects ?? [] { _ = page.recordEffect(effect) }
                let reply: LegadoOriginalWebJSReply
                do { reply = try JSONDecoder().decode(Output.self, from: bytes).result }
                catch { throw LegadoRuntimeError(code: "INVALID_RESULT", message: "Original page response did not decode",
                    completedEffects: facts.completedEffects) }
                guard ["string", "stringList", "void", "callback"].contains(reply.kind),
                      reply.kind != "callback" || (reply.requestId == call.requestId && reply.success != nil) else {
                    throw LegadoRuntimeError(code: "INVALID_RESULT", message: "Original page response is incompatible")
                }
                return reply
            }
        }
        _ = page.recordEffect("sourceBrowserWebJsMayExecute")
        page.children[childID] = child
        let admittedName = await SourceBrowserPresenter.originalWebJSRequestDidStart
        let parentTaskID = invocation.taskID
        await MainActor.run {
            NotificationCenter.default.post(name: admittedName, object: nil,
                userInfo: ["taskID": parentTaskID, "pageID": pageID, "method": call.method])
        }
        defer {
            page.children.removeValue(forKey: childID)
            originalChildInvocations.removeValue(forKey: taskID)
        }
        let reply: LegadoOriginalWebJSReply
        do { reply = try await withTaskCancellationHandler(operation: { try await child.value }, onCancel: { child.cancel() }) }
        catch {
            for effect in (error as? LegadoRuntimeError)?.completedEffects ?? [] { _ = page.recordEffect(effect) }
            throw error
        }
        try Task.checkCancellation()
        try await invocation.sourceAdmission?.validate()
        try page.cancellation.check(deadline: deadline)
        guard originalInvocations[owner] === invocation, bindings[owner] != nil, !invocation.invalidated else {
            throw CancellationError()
        }
        return reply
    }

    private struct OriginalHeadlessWire: Decodable {
        let owner: String
        let sourceURL: String
        let sessionId: String
        let taskId: String
        let cookieAccess: String
        let url: String?
        let html: String?
        let js: String?
        let headers: [String: String]
        let userAgent: String?
        let additionalHeaders: [String: String]
        let cookieTag: String?
        let isRule: Bool
        let cacheFirst: Bool
        let delayTime: Int64
        let initialDelayMs: Int
        let browserDeadlineEpochMs: Int64
        let timeoutMs: Int
        let sourceRegex: String?
        let overrideUrlRegex: String?
        let resultJSON: String?
        let injectionString: String?
        let page: [String: String]
    }

    /// This path is original parser authority, independent of the finite login
    /// browser flag. Native policy uses its own JVM operation; page JS can only
    /// reach webJsRequest through the separately bounded WK lease closure.
    private func runOriginalHeadless(_ request: LegadoHostRequest) async throws -> String {
        try await SourcePerfTrace.spanAsync("legado.original.webview.host",
            "main=\(Thread.isMainThread) bytes=\(request.requestJSON.utf8.count)") {
            try await runOriginalHeadlessRequest(request)
        }
    }

    private func runOriginalHeadlessRequest(_ request: LegadoHostRequest) async throws -> String {
        guard request.requestJSON.utf8.count <= 6 * 4 * 1024 * 1024 + 262_144 else {
            throw failure("STATE_LIMIT", "Original WebView packet exceeds its budget")
        }
        let input: OriginalHeadlessWire
        do { input = try JSONDecoder().decode(OriginalHeadlessWire.self, from: Data(request.requestJSON.utf8)) }
        catch { throw failure("INVALID_STATE_REQUEST", "Original WebView packet is incompatible") }
        guard input.taskId.utf8.elementsEqual(request.taskID.utf8),
              let binding = bindings[input.owner], input.sourceURL.utf8.elementsEqual(binding.sourceURL.utf8),
              revisions[binding.sourceURL] == binding.sourceRevision,
              let invocation = originalInvocations[input.owner], !invocation.producerEnded, !invocation.invalidated,
              invocation.taskID == request.taskID, invocation.session.id == input.sessionId,
              invocation.session.sourceMode == .originalTraditional else {
            throw failure("INVALID_STATE_OWNER", "Original WebView needs its current source/task/session")
        }
        guard input.cookieAccess == "app-owner-text" else {
            // All three actual App executors explicitly grant this existing
            // mode. Read-only callers cannot acquire Cookie writes by opening WK.
            throw failure("UNSUPPORTED_CAPABILITY", "Original WebView Cookie capture requires its explicit text owner")
        }
        guard input.cookieTag == nil || input.cookieTag?.utf8.elementsEqual(binding.sourceURL.utf8) == true,
              input.headers.count <= 256, input.additionalHeaders.count <= 256,
              input.headers.allSatisfy({ $0.key.utf8.count <= 8192 && $0.value.utf8.count <= 65_536 }),
              input.additionalHeaders.allSatisfy({ $0.key.utf8.count <= 8192 && $0.value.utf8.count <= 65_536 }),
              (input.html?.utf8.count ?? 0) <= 4 * 1024 * 1024,
              (input.js?.utf8.count ?? 0) <= 4 * 1024 * 1024,
              (input.resultJSON?.utf8.count ?? 0) <= 4 * 1024 * 1024,
              (input.url?.utf8.count ?? 0) < 65_536,
              (input.userAgent?.utf8.count ?? 0) <= 65_536,
              input.isRule == (input.injectionString != nil),
              input.initialDelayMs >= 0, input.initialDelayMs <= 300_000,
              input.timeoutMs > 0, input.timeoutMs <= (input.isRule ? 10_000 : 60_000) else {
            throw failure("STATE_LIMIT", "Original WebView fields exceed their native budgets")
        }
        guard input.sourceRegex?.isEmpty != false else {
            throw failure("UNSUPPORTED_CAPABILITY", "Public WebKit cannot report every original HTTP resource load")
        }
        if let url = input.url, let scheme = URL(string: url)?.scheme?.lowercased(), !["http", "https"].contains(scheme) {
            throw failure("UNSUPPORTED_CAPABILITY", "Original WebView has no local-file or custom-scheme loading grant")
        }
        let deadline = min(Date(timeIntervalSince1970: Double(input.browserDeadlineEpochMs) / 1000),
            Date().addingTimeInterval(Double(input.timeoutMs) / 1000))
        try checkCookieRead(request, deadline: deadline)
        try binding.cookieCancellation.check(deadline: deadline)
        let keys: Set<String> = ["pageId", "sessionId", "parentTaskId", "javaName", "cacheName", "resultName", "sourceName"]
        guard Set(input.page.keys) == keys, let sourceName = input.page["sourceName"] else {
            throw failure("INVALID_STATE_REQUEST", "Original WebView page metadata is incompatible")
        }
        let first = Set("_$abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
        let rest = first.union(Set("0123456789".utf8))
        guard sourceName.utf8.count <= 128, let leading = sourceName.utf8.first,
              first.contains(leading), sourceName.utf8.allSatisfy({ rest.contains($0) }),
              ![input.page["javaName"], input.page["cacheName"], input.page["resultName"]].contains(sourceName) else {
            throw failure("INVALID_STATE_REQUEST", "Original source interface name is not a distinct bounded identifier")
        }
        var pageFields = input.page
        pageFields.removeValue(forKey: "sourceName")
        let page = try await makeOriginalWebPage(pageFields, request: request, owner: input.owner, parentDeadline: deadline)
        let pageID = page.descriptor.pageId
        do {
            guard let sourceID = invocation.sourceID else {
                throw failure("INVALID_STATE_OWNER", "Original WebView has no admitted source identity")
            }
            let registered = await MainActor.run {
                guard let snapshot = BookSourceStore.shared.runtimeIndexedSnapshot(id: sourceID),
                      let source = snapshot.source else { return false }
                return source.bookSourceUrl.utf8.elementsEqual(binding.sourceURL.utf8)
            }
            let configured = try await originalHeadlessPolicy(owner: input.owner, pageID: pageID,
                method: "configure", params: [registered ? "true" : "false"])
            guard configured.kind == "string", configured.value == "configured" else {
                throw failure("INVALID_RESULT", "Original WebView policy did not acknowledge its actual source registration")
            }
            let cancellation = originalInvocations[input.owner]?.pages[pageID]?.cancellation
            guard let cancellation else { throw CancellationError() }
            let owner = input.owner
            let packet = LegadoOriginalHeadlessRequest(html: input.html, url: input.url,
                javaScript: input.js, headers: input.headers, userAgent: input.userAgent,
                additionalHeaders: input.additionalHeaders, cacheFirst: input.cacheFirst,
                navigationCapture: input.overrideUrlRegex != nil,
                delayMilliseconds: input.delayTime, initialDelayMilliseconds: input.initialDelayMs,
                resultJSON: input.resultJSON, injectionString: input.isRule ? input.injectionString : nil,
                sourceName: sourceName, registeredSource: registered, page: page, deadline: deadline,
                authorize: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try await self.validateOriginalChildHost(owner: owner, pageID: pageID)
                }, validateCommit: {
                    try cancellation.check(deadline: deadline)
                    try binding.cookieCancellation.check(deadline: deadline)
                }, recordEffect: { request.recordPossibleEffect($0) },
                evaluate: { [weak self] raw in
                    guard let self else { throw CancellationError() }
                    let reply = try await self.originalHeadlessPolicy(owner: owner, pageID: pageID, method: "evaluate", params: [raw])
                    guard reply.kind == "string", let value = reply.value else {
                        throw LegadoRuntimeError(code: "INVALID_RESULT", message: "Original evaluation policy omitted its result")
                    }
                    return try JSONDecoder().decode(LegadoOriginalHeadlessEvaluation.self, from: Data(value.utf8))
                }, navigation: { [weak self] url in
                    guard let self else { throw CancellationError() }
                    let reply = try await self.originalHeadlessPolicy(owner: owner, pageID: pageID, method: "navigation", params: [url])
                    guard reply.kind == "string", let value = reply.value, ["true", "false"].contains(value) else {
                        throw LegadoRuntimeError(code: "INVALID_RESULT", message: "Original navigation policy omitted its decision")
                    }
                    return value == "true"
                }, publishCookies: { [weak self] url, text in
                    guard let self else { throw CancellationError() }
                    let reply = try await self.originalHeadlessPolicy(owner: owner, pageID: pageID, method: "cookie", params: [url, text])
                    guard reply.kind == "void" else {
                        throw LegadoRuntimeError(code: "INVALID_RESULT", message: "Original Cookie owner did not acknowledge its accepted operation")
                    }
                })
            guard request.recordPossibleEffect("sourceWebViewMayStart") else { throw CancellationError() }
            let work = Task { try await LegadoHeadlessWebView.runOriginal(packet) }
            originalHeadlessOperations[pageID] = (request.taskID, work)
            defer { originalHeadlessOperations.removeValue(forKey: pageID) }
            let result = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
            try Task.checkCancellation()
            try await validateOriginalChildHost(owner: owner, pageID: pageID)
            // The parent still owns terminal policy validation. Drain/remove
            // the Swift lease now; its JVM finally closes the same Page only
            // after validating this exact accepted body.
            try await releaseOriginalHeadlessPage(owner: owner, pageID: pageID)
            var output: [String: Any] = ["url": result.url, "body": result.body, "redirected": result.redirected]
            if let origin = result.originURL { output["originURL"] = origin }
            return try encoded(output)
        } catch let primary {
            do { try await page.close() }
            catch {
                let typed = primary as? LegadoRuntimeError
                let secondary = LegadoRuntimeFailureDetail(code: (error as? LegadoRuntimeError)?.code ?? "STATE_IO",
                    message: "Original WebView page cleanup did not complete")
                let effects = Array(Set((typed?.completedEffects ?? []) + ((error as? LegadoRuntimeError)?.completedEffects ?? []))).sorted()
                throw LegadoRuntimeError(code: typed?.code ?? (primary is CancellationError ? "CANCELLED" : "STATE_IO"),
                    message: "Original WebView did not complete", completedEffects: effects,
                    loginUIEvents: typed?.loginUIEvents, secondaryFailures: (typed?.secondaryFailures ?? []) + [secondary])
            }
            let typed = primary as? LegadoRuntimeError
            throw LegadoRuntimeError(code: typed?.code ?? (primary is CancellationError ? "CANCELLED" : "STATE_IO"),
                message: "Original WebView did not complete", completedEffects: typed?.completedEffects,
                loginUIEvents: typed?.loginUIEvents, secondaryFailures: typed?.secondaryFailures)
        }
    }

    private func originalHeadlessPolicy(owner: String, pageID: String, method: String,
                                        params: [String?]) async throws -> LegadoOriginalWebJSReply {
        guard ["configure", "evaluate", "navigation", "cookie"].contains(method) else {
            throw failure("UNSUPPORTED_CAPABILITY", "Original native policy method is not admitted")
        }
        return try await requestOriginalWebPage(owner: owner, pageID: pageID,
            call: .init(method: method, params: params, function: nil, requestId: nil), nativePolicy: true)
    }

    private func releaseOriginalHeadlessPage(owner: String, pageID: String) async throws {
        guard let invocation = originalInvocations[owner], let page = invocation.pages[pageID] else { return }
        page.cancellation.cancel()
        let children = Array(page.children.values)
        for child in children { child.cancel() }
        for child in children { _ = await child.result }
        invocation.pages.removeValue(forKey: pageID)
        try await cleanupOriginalInvocationIfIdle(owner: owner)
    }

    private func cancelOriginalHeadless(taskID: String) async {
        let work = originalHeadlessOperations.values.filter { $0.taskID == taskID }.map(\.work)
        for item in work { item.cancel() }
        for item in work { _ = await item.result }
    }

    private func closeOriginalWebPage(owner: String, pageID: String) async throws {
        guard let invocation = originalInvocations[owner], let page = invocation.pages[pageID] else { return }
        if let closing = page.closing { return try await closing.value }
        page.cancellation.cancel()
        let children = Array(page.children.values)
        for child in children { child.cancel() }
        let runtime = invocation.runtime, session = invocation.session
        let closing = Task { () throws -> Void in
            for child in children { _ = await child.result }
            struct Input: Encodable { let pageId: String; let timeoutMs: Int }
            let json = String(decoding: try JSONEncoder().encode(Input(pageId: pageID, timeoutMs: 30_000)), as: UTF8.self)
            _ = try await runtime.execute(session: session, operation: "webJsPageClose", requestJSON: json)
        }
        page.closing = closing
        var closeError: Error?
        do { try await closing.value } catch { closeError = error }
        invocation.pages.removeValue(forKey: pageID)
        do { try await cleanupOriginalInvocationIfIdle(owner: owner) }
        catch { if closeError == nil { closeError = error } }
        if let closeError { throw closeError }
    }

    /// An accepted nonawait page outlives normal producer cleanup, as the original
    /// Activity does. It is acknowledged only after real UIKit presentation;
    /// its later user-driven Cookie capture belongs to that existing page owner.
    private func presentSourceBrowser(_ request: LegadoHostRequest) async throws -> String {
        try await SourcePerfTrace.spanAsync("legado.original.browser.present",
            "main=\(Thread.isMainThread) bytes=\(request.requestJSON.utf8.count)") {
            try await presentSourceBrowserRequest(request)
        }
    }

    private func presentSourceBrowserRequest(_ request: LegadoHostRequest) async throws -> String {
        guard request.requestJSON.utf8.count <= 6 * 4 * 1024 * 1024 + 262_144 else {
            throw failure("STATE_LIMIT", "Browser presentation request exceeds its budget")
        }
        let decoded: Any
        do { decoded = try JSONSerialization.jsonObject(with: Data(request.requestJSON.utf8)) }
        catch { throw failure("INVALID_STATE_REQUEST", "Browser presentation request is not JSON") }
        guard let input = decoded as? [String: Any],
              Set(input.keys).isSubset(of: ["owner", "sourceURL", "url", "title", "headers", "prefetchedHTML", "awaitsResult", "refetchAfterSuccess", "deadlineEpochMs", "remainingTimeoutMs", "localPage"]),
              let owner = input["owner"] as? String, let sourceURL = input["sourceURL"] as? String,
              let url = input["url"] as? String, url.utf8.count < 65_536,
              let target = URL(string: url), target.host?.isEmpty == false,
              ["http", "https"].contains(target.scheme?.lowercased() ?? ""),
              let title = input["title"] as? String, title.utf8.count <= 8_192,
              let headers = input["headers"] as? [String: String], headers.count <= 256 else {
            throw failure("INVALID_STATE_REQUEST", "Browser presentation requires bounded page fields")
        }
        let prefetchedHTML: String?
        if let rawHTML = input["prefetchedHTML"] {
            guard let html = rawHTML as? String else {
                throw failure("INVALID_STATE_REQUEST", "Browser prefetch must be a String")
            }
            guard html.utf8.count <= 4 * 1024 * 1024 else {
                throw failure("STATE_LIMIT", "Browser prefetch exceeds its byte budget")
            }
            prefetchedHTML = html
        } else {
            guard request.requestJSON.utf8.count <= 262_144 else {
                throw failure("STATE_LIMIT", "Browser presentation request exceeds its budget")
            }
            prefetchedHTML = nil
        }
        let headerToken = Set("!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
        var normalizedHeaders = Set<String>(), headerBytes = 0
        for (name, value) in headers {
            guard !name.isEmpty, name.utf8.count <= 1_024, value.utf8.count <= 16_384,
                  name.utf8.allSatisfy({ headerToken.contains($0) }),
                  value.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }),
                  normalizedHeaders.insert(name.lowercased()).inserted else {
                throw failure("UNSUPPORTED_CAPABILITY", "Browser headers cannot be represented safely")
            }
            headerBytes += name.utf8.count + value.utf8.count
        }
        guard headerBytes <= 65_536 else { throw failure("STATE_LIMIT", "Browser headers exceed their budget") }
        func flag(_ name: String, default defaultValue: Bool) throws -> Bool {
            guard let value = input[name] else { return defaultValue }
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw failure("INVALID_STATE_REQUEST", "Browser flags must be Boolean")
            }
            return number.boolValue
        }
        let awaitsResult = try flag("awaitsResult", default: false)
        let refetchAfterSuccess = try flag("refetchAfterSuccess", default: true)
        let deadline = try cookieReadDeadline(input)
        try authorizeSourceBrowser(request, owner: owner, sourceURL: sourceURL, deadline: deadline)
        guard let binding = bindings[owner] else { throw CancellationError() }
        let localPage: LegadoOriginalWebPageLease?
        if let raw = input["localPage"] {
            guard prefetchedHTML != nil else {
                throw failure("INVALID_STATE_REQUEST", "Local page requires its sole prepared body")
            }
            localPage = try await makeOriginalWebPage(raw, request: request, owner: owner,
                parentDeadline: awaitsResult ? deadline : nil)
        }
        else { localPage = nil }
        let presentation = LegadoOriginalBrowserPresentation(taskID: request.taskID, url: url, title: title,
            headers: headers, prefetchedHTML: prefetchedHTML, awaitsResult: awaitsResult, refetchAfterSuccess: refetchAfterSuccess, deadline: deadline,
            authorize: { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.authorizeSourceBrowser(request, owner: owner, sourceURL: sourceURL, deadline: deadline)
            }, validateCommit: {
                try Task.checkCancellation()
                try binding.cookieCancellation.check(deadline: deadline)
            }, recordEffect: { request.recordPossibleEffect($0) }, localPage: localPage)
        // This awaits MainActor/UI only. It never reenters the source service or
        // the JVM/source gate currently waiting for this synchronous Host call.
        do {
            let completion = try await originalBrowserPresenter(presentation)
            try authorizeSourceBrowser(request, owner: owner, sourceURL: sourceURL, deadline: deadline)
            switch completion {
            case .presented:
                guard !awaitsResult else {
                    throw failure("INVALID_BROWSER_RESULT", "Page presentation is not an awaited result")
                }
                return try encoded(["presented": true])
            case .refetchConfirmed:
                guard awaitsResult && refetchAfterSuccess else {
                    throw failure("INVALID_BROWSER_RESULT", "Unexpected browser refetch confirmation")
                }
                return try encoded(["mode": "refetchConfirmed"])
            case .response(let finalURL, let body):
                guard awaitsResult && !refetchAfterSuccess, finalURL.utf8.count < 65_536,
                      body.utf8.count <= 4 * 1024 * 1024 else {
                    throw failure("INVALID_BROWSER_RESULT", "Unexpected or oversized awaited page result")
                }
                guard !body.isEmpty else { throw failure("BROWSER_EMPTY_RESULT", "The awaited browser returned an empty result") }
                return try encoded(["mode": "response", "finalURL": finalURL, "body": body])
            }
        } catch let presentationError {
            // Admission may have changed after UIKit accepted the page. Also
            // close a lease when cancellation rejected the Presenter before
            // its ticket was queued: no UI ticket exists to release it then.
            await SourceBrowserPresenter.cancelOriginal(taskID: request.taskID)
            if let localPage {
                do { try await localPage.close() }
                catch { AppLogger.error("Unpresented original page cleanup failed", error:
                    LegadoRuntimeError(code: (error as? LegadoRuntimeError)?.code ?? "STATE_IO",
                        message: "Original page scope cleanup did not complete")) }
            }
            throw presentationError
        }
    }

    private func authorizeSourceBrowser(_ request: LegadoHostRequest, owner: String,
                                        sourceURL: String, deadline: Date) throws {
        try checkCookieRead(request, deadline: deadline)
        guard let binding = bindings[owner], sourceURL.utf8.elementsEqual(binding.sourceURL.utf8),
              revisions[binding.sourceURL] == binding.sourceRevision else {
            throw failure("INVALID_STATE_OWNER", "Browser requires its current explicit source owner")
        }
        try binding.cookieCancellation.check(deadline: deadline)
    }

    /// Credentials use their own checked LoginManager boundary, never the
    /// general cache/state domains. The grant still binds the exact same source
    /// revision and task deadline as every other original-host operation.
    /// The task/mode fields come from the restricted first-party JVM producer,
    /// not imported source JSON. This Host does not maintain a second native
    /// session registry. Generic state.commit remains a separate CAS boundary.
    private func sourceLoginHeader(_ request: LegadoHostRequest) throws -> String {
        guard request.requestJSON.utf8.count <= 524_288 else {
            throw failure("STATE_LIMIT", "Login-header request exceeds its byte budget")
        }
        let decoded: Any
        do { decoded = try JSONSerialization.jsonObject(with: Data(request.requestJSON.utf8)) }
        catch { throw failure("INVALID_STATE_REQUEST", "Login-header request is not JSON") }
        guard let input = decoded as? [String: Any],
              Set(input.keys).isSubset(of: ["owner", "sourceURL", "taskId", "cookieAccess", "action", "value", "deadlineEpochMs", "remainingTimeoutMs"]) else {
            throw failure("INVALID_STATE_REQUEST", "Login-header request has invalid fields")
        }
        guard input["cookieAccess"] as? String == "app-owner-text" else {
            throw failure("UNSUPPORTED_CAPABILITY", "Login-header mutation requires explicit app-owner-text mode")
        }
        guard let taskID = input["taskId"] as? String, !taskID.isEmpty,
              taskID.utf8.elementsEqual(request.taskID.utf8),
              let owner = input["owner"] as? String,
              let sourceURL = input["sourceURL"] as? String,
              let binding = bindings[owner], sourceURL.utf8.elementsEqual(binding.sourceURL.utf8),
              revisions[binding.sourceURL] == binding.sourceRevision else {
            throw failure("INVALID_STATE_OWNER", "Login-header requires its current source and task owner")
        }
        guard let action = input["action"] as? String, ["put", "remove"].contains(action) else {
            throw failure("INVALID_STATE_REQUEST", "Unknown login-header action")
        }
        let value: String?
        if action == "put" {
            guard let raw = input["value"] as? String, raw.utf8.count <= 65_536 else {
                throw failure("STATE_LIMIT", "Login-header requires a bounded String")
            }
            value = raw
        } else {
            guard input["value"] == nil else { throw failure("INVALID_STATE_REQUEST", "Header removal does not accept a value") }
            value = nil
        }
        let deadline = try cookieReadDeadline(input)
        let validate = {
            try self.checkCookieRead(request, deadline: deadline)
            try binding.cookieCancellation.check(deadline: deadline)
        }
        try validate()
        do {
            let accepted = try backing.storeLoginHeader(sourceURL: sourceURL, value: value,
                validate: validate, recordEffect: { request.recordPossibleEffect($0) })
            guard accepted else { throw failure("STATE_IO", "The App login-header owner rejected its mutation") }
            return try encoded(["committed": true])
        } catch let error as LegadoRuntimeError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch LoginCredentialOwnerFailure.valueLimit { throw failure("STATE_LIMIT", "Login-header exceeds its byte budget") }
        catch {
            AppLogger.error("JVM login-header owner failed", context: ["errorType": String(reflecting: type(of: error))])
            throw failure("STATE_IO", "The App login-header owner did not complete its operation")
        }
    }

    private func sourceLoginInfo(_ request: LegadoHostRequest) throws -> String {
        guard request.requestJSON.utf8.count <= 524_288 else { throw failure("STATE_LIMIT", "Login-info request exceeds its byte budget") }
        let decoded: Any
        do { decoded = try JSONSerialization.jsonObject(with: Data(request.requestJSON.utf8)) }
        catch { throw failure("INVALID_STATE_REQUEST", "Login-info request is not valid JSON") }
        guard let input = decoded as? [String: Any], let owner = input["owner"] as? String,
              let sourceURL = input["sourceURL"] as? String,
              let binding = bindings[owner], sourceURL.utf8.elementsEqual(binding.sourceURL.utf8),
              revisions[binding.sourceURL] == binding.sourceRevision else {
            throw failure("INVALID_STATE_OWNER", "Login-info requires its current explicit source owner")
        }
        guard let action = input["action"] as? String, ["get", "put", "remove"].contains(action) else {
            throw failure("INVALID_STATE_REQUEST", "Unknown login-info action")
        }
        let deadline = try cookieReadDeadline(input)
        let validate = {
            try self.checkCookieRead(request, deadline: deadline)
            try binding.cookieCancellation.check(deadline: deadline)
        }
        try validate()
        do {
            if action == "get" {
                let value = try backing.loginInfo(sourceURL: sourceURL, validate: validate,
                    recordEffect: { request.recordPossibleEffect($0) })
                return try encoded(["value": value.map { $0 as Any } ?? NSNull()])
            }
            let value: String?
            if action == "put" {
                guard let raw = input["value"] as? String, raw.utf8.count <= 65_536 else {
                    throw failure("STATE_LIMIT", "Login-info requires a bounded String")
                }
                value = raw
            } else { value = nil }
            let accepted = try backing.storeLoginInfo(sourceURL: sourceURL, value: value, validate: validate,
                recordEffect: { request.recordPossibleEffect($0) })
            if action == "remove", !accepted { throw failure("STATE_IO", "The App credential owner rejected removal") }
            return try encoded(["committed": accepted])
        } catch let error as LegadoRuntimeError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch LoginCredentialOwnerFailure.valueLimit { throw failure("STATE_LIMIT", "Login-info exceeds its byte budget") }
        catch {
            // Do not log the request, source URL, credential payload or an
            // injected storage error's possibly secret-bearing description.
            AppLogger.error("JVM login-info owner failed", context: ["errorType": String(reflecting: type(of: error))])
            throw failure("STATE_IO", "The App credential owner did not complete the request")
        }
    }

    /// A finite read-only Cookie operation shares the existing bound owner and
    /// CookieStore. It returns business text, never a reconstructed Java jar.
    /// Mutation/session-response batching is deliberately a separate capability.
    private func readCookieOwner(_ request: LegadoHostRequest) async throws -> String {
        guard request.requestJSON.utf8.count <= 32_768 else { throw failure("STATE_LIMIT", "Cookie owner request exceeds its byte budget") }
        let decoded: Any
        do { decoded = try JSONSerialization.jsonObject(with: Data(request.requestJSON.utf8)) }
        catch { throw failure("INVALID_STATE_REQUEST", "Cookie owner request is not valid JSON") }
        guard let input = decoded as? [String: Any], let owner = input["owner"] as? String,
              let binding = bindings[owner], revisions[binding.sourceURL] == binding.sourceRevision else {
            throw failure("INVALID_STATE_OWNER", "Cookie read has no current explicit App owner")
        }
        guard let purpose = input["purpose"] as? String,
              let url = input["url"] as? String, url.utf8.count <= 8_192,
              let domain = input["domain"] as? String, domain.utf8.count <= 8_192 else {
            throw failure("INVALID_STATE_REQUEST", "Cookie read requires bounded URL/domain text")
        }
        let deadline = try cookieReadDeadline(input)
        try checkCookieRead(request, deadline: deadline)
        do {
            let value: String
            switch purpose {
            case "getCookie":
                // Domain comes from the JVM's locked original NetworkUtils/PSL,
                // not a Swift last-two-label approximation. This intentionally
                // uses the existing broad text API, not automatic HTTP headers.
                if let target = cookieDomainURL(domain) {
                    value = try await cookieOwner.getOwned(url: target.absoluteString)
                } else {
                    // The original getSubDomain returns arbitrary non-URL text
                    // unchanged. Such a DB key is not a made-up HTTPS origin.
                    value = try await cookieOwner.originalRawText(domain: domain)
                }
            case "requestHeader":
                guard let target = URL(string: url), target.host != nil,
                      ["http", "https"].contains(target.scheme?.lowercased() ?? "") else {
                    throw failure("INVALID_STATE_REQUEST", "Automatic Cookie headers require an absolute HTTP(S) URL")
                }
                value = try await cookieOwner.requestHeader(url: target) ?? ""
            default: throw failure("UNSUPPORTED_CAPABILITY", "Unknown App Cookie read purpose")
            }
            try checkCookieRead(request, deadline: deadline)
            try currentEntityBinding(owner: owner, binding: binding)
            guard value.utf8.count <= 65_536 else { throw failure("STATE_LIMIT", "Cookie owner read exceeds its byte budget") }
            return try encoded(["cookie": value])
        } catch let error as CookieOwnerError {
            throw failure(error.code, error.message)
        } catch let error as LegadoRuntimeError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch {
            AppLogger.error("The original runtime Cookie owner read failed", error: error)
            throw failure("STATE_IO", "The App Cookie owner could not be read")
        }
    }

    /// Only identifies the already granted backing/source/revision. A returned
    /// scope cannot authorize cache writes; those still use the current grant.
    private func explorationOwnerScope(_ request: LegadoHostRequest) throws -> String {
        guard request.requestJSON.utf8.count <= 32_768 else { throw failure("STATE_LIMIT", "Explore owner scope request is oversized") }
        let decoded: Any
        do { decoded = try JSONSerialization.jsonObject(with: Data(request.requestJSON.utf8)) }
        catch { throw failure("INVALID_STATE_REQUEST", "Explore owner request is not valid JSON") }
        guard let input = decoded as? [String: Any], let owner = input["owner"] as? String,
              let sourceURL = input["sourceURL"] as? String, sourceURL.utf8.count <= 8_192,
              let binding = bindings[owner], binding.sourceURL.utf8.elementsEqual(sourceURL.utf8),
              revisions[binding.sourceURL] == binding.sourceRevision else {
            throw failure("INVALID_STATE_OWNER", "Explore context has no current explicit source owner")
        }
        let deadline = try cookieReadDeadline(input)
        try checkCookieRead(request, deadline: deadline)
        try binding.cookieCancellation.check(deadline: deadline)
        let scope = String(decoding: try JSONSerialization.data(withJSONObject: [exploreScopeIdentity, binding.sourceURL, binding.sourceRevision]), as: UTF8.self)
        return try encoded(["scope": scope])
    }

    /// Single-owner original text operations are deliberately separate from the
    /// outward atomic state.commit batch. No source/header/cache write occurs
    /// inside this owner operation, and unsupported input is rejected first.
    private func textCookieOwner(_ request: LegadoHostRequest) async throws -> String {
        guard request.requestJSON.utf8.count <= 1_048_576 else { throw failure("STATE_LIMIT", "Cookie text request is oversized") }
        let decoded: Any
        do { decoded = try JSONSerialization.jsonObject(with: Data(request.requestJSON.utf8)) }
        catch { throw failure("INVALID_STATE_REQUEST", "Cookie text request is not valid JSON") }
        guard let input = decoded as? [String: Any], let owner = input["owner"] as? String,
              let binding = bindings[owner], revisions[binding.sourceURL] == binding.sourceRevision else {
            throw failure("INVALID_STATE_OWNER", "Cookie text has no current explicit owner")
        }
        guard let action = input["action"] as? String,
              let url = input["url"] as? String, url.utf8.count <= 8_192,
              let domain = input["domain"] as? String, domain.utf8.count <= 8_192 else {
            throw failure("INVALID_STATE_REQUEST", "Cookie text requires bounded action URL and domain")
        }
        guard ["get", "session", "set", "replace", "remove", "removeKey", "response", "clear", "webSet", "webRemove"].contains(action) else {
            throw failure("UNSUPPORTED_CAPABILITY", "Unknown original Cookie text action")
        }
        let deadline = try cookieReadDeadline(input)
        try checkCookieRead(request, deadline: deadline)
        try binding.cookieCancellation.check(deadline: deadline)
        let ticket = OriginalRuntimeCommitCancellation(), operationID = UUID()
        pendingEntityOperations[request.taskID, default: [:]][operationID] = ticket
        defer {
            pendingEntityOperations[request.taskID]?.removeValue(forKey: operationID)
            if pendingEntityOperations[request.taskID]?.isEmpty == true { pendingEntityOperations.removeValue(forKey: request.taskID) }
        }
        do {
            if action == "get" || action == "session" {
                let text = action == "get" ? try await cookieOwner.originalText(domain: domain)
                    : try await cookieOwner.originalSession(domain: url)
                try checkCookieRead(request, deadline: deadline)
                try currentEntityBinding(owner: owner, binding: binding)
                guard text.utf8.count <= 65_536 else { throw failure("STATE_LIMIT", "Cookie text result is oversized") }
                return try encoded(["cookie": text])
            }
            let validate: @Sendable () throws -> Void = {
                try ticket.check(deadline: deadline)
                try binding.cookieCancellation.check(deadline: deadline)
            }
            if action == "webSet" || action == "webRemove" {
                guard pendingWebCookieOperations.values.reduce(0, { $0 + $1.count }) < 256 else {
                    throw failure("STATE_LIMIT", "Too many active original browser Cookie operations")
                }
                let operation: OriginalCookieWebKitMutation
                if action == "webSet" {
                    guard let baseURL = input["baseUrl"] as? String, baseURL.utf8.count <= 8_192,
                          let pieces = input["pieces"] as? [String], pieces.count <= 4096,
                          pieces.reduce(0, { $0 + $1.utf8.count }) <= 65_536 else {
                        throw failure("INVALID_STATE_REQUEST", "Original Web Cookie pieces exceed their budget")
                    }
                    operation = .set(baseURL: baseURL, pieces: pieces)
                } else {
                    guard let domains = input["domains"] as? [String], domains.count == 2,
                          domains.allSatisfy({ $0.utf8.count <= 8_192 }) else {
                        throw failure("INVALID_STATE_REQUEST", "Original browser expiration requires its two exact targets")
                    }
                    operation = .remove(domains: domains)
                }
                let cookieOwner = self.cookieOwner, storeProvider = originalWebCookieStore
                let pending = Task {
                    try await cookieOwner.performOriginalWebCookieMutation(operation, storeProvider: storeProvider,
                        recordPossibleEffect: { request.recordPossibleEffect($0) }, validate: validate)
                }
                pendingWebCookieOperations[request.taskID, default: [:]][operationID] = OriginalWebCookieOperation(owner: owner, task: pending)
                defer {
                    pendingWebCookieOperations[request.taskID]?.removeValue(forKey: operationID)
                    if pendingWebCookieOperations[request.taskID]?.isEmpty == true { pendingWebCookieOperations.removeValue(forKey: request.taskID) }
                }
                try await withTaskCancellationHandler {
                    try await pending.value
                } onCancel: { ticket.cancel(); pending.cancel() }
            } else if action == "clear" {
                guard request.recordPossibleEffect("cookieOkHttpSubsetClearMayCommit") else { throw CancellationError() }
                try await withTaskCancellationHandler {
                    try await cookieOwner.clearOriginalOkHttp(validate: validate)
                } onCancel: { ticket.cancel() }
            } else if action == "response" {
                let response = try originalResponseCookies(input, rawURL: url)
                guard request.recordPossibleEffect("cookieResponseMayCommit") else { throw CancellationError() }
                try await withTaskCancellationHandler {
                    try await cookieOwner.ingestOriginalResponse(response.records, domain: domain,
                        persistentText: response.persistent, sessionText: response.session, validate: validate)
                } onCancel: { ticket.cancel() }
            } else {
                let raw = input["cookie"] as? String
                guard action == "remove" || raw != nil, (raw?.utf8.count ?? 0) <= 65_536 else {
                    throw failure("INVALID_STATE_REQUEST", "Cookie mutation requires bounded text")
                }
                guard request.recordPossibleEffect("cookieTextMutationMayCommit") else { throw CancellationError() }
                try await withTaskCancellationHandler {
                    try await cookieOwner.mutateOriginalText(domain: domain, action: action, raw: raw, validate: validate)
                } onCancel: { ticket.cancel() }
            }
            // The actor has already replaced its file (or proved no change).
            // Preserve that ACK even if the JVM observes cancellation on return.
            if action != "webSet" && action != "webRemove" {
                let effect = action == "clear" ? "cookieOkHttpSubsetCleared" : (action == "remove" ? "cookieRemoval" : "cookieText")
                request.recordPossibleEffect(effect)
            }
            return try encoded(["committed": true])
        } catch let error as OriginalCookieWebKitFailure {
            let code = (error.underlying as? CookieOwnerError)?.code ?? (error.underlying as? LegadoRuntimeError)?.code
                ?? (error.underlying is CancellationError ? "CANCELLED" : "STATE_IO")
            throw LegadoRuntimeError(code: code, message: error.errorDescription ?? "Earlier WebKit Cookie effects may exist", completedEffects: error.completedEffects)
        } catch let error as CookieOwnerError { throw failure(error.code, error.message) }
        catch let error as LegadoRuntimeError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch {
            AppLogger.error("The original Cookie text owner failed", error: error)
            throw failure("STATE_IO", "The original Cookie text owner did not complete its operation")
        }
    }

    private func originalResponseCookies(_ input: [String: Any], rawURL: String) throws
        -> (records: [CookiePersistenceOwner.Record], persistent: String, session: String) {
        guard let url = URL(string: rawURL), let host = url.host?.lowercased(),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let headers = input["headers"] as? [String], !headers.isEmpty, headers.count <= 256,
              headers.reduce(0, { $0 + $1.utf8.count }) <= 65_536,
              let cookies = input["cookies"] as? [[String: Any]], !cookies.isEmpty, cookies.count <= 256 else {
            throw failure("INVALID_STATE_REQUEST", "Original response Cookies require bounded actual HTTP provenance")
        }
        return try SourcePerfTrace.span("legado.cookie.response.decode", "main=\(Thread.isMainThread) cookies=\(cookies.count)") {
        var records: [CookiePersistenceOwner.Record] = []
        var persistentValues: [String] = [], sessionValues: [String] = []
        for cookie in cookies {
            guard let name = cookie["name"] as? String, !name.isEmpty,
                  let value = cookie["value"] as? String,
                  let domain = cookie["domain"] as? String, !domain.isEmpty,
                  let path = cookie["path"] as? String, path.hasPrefix("/"),
                  let raw = cookie["setCookieHeader"] as? String, headers.contains(raw),
                  let secure = cookieBoolean(cookie["secure"]), let httpOnly = cookieBoolean(cookie["httpOnly"]),
                  let hostOnly = cookieBoolean(cookie["hostOnly"]), let persistent = cookieBoolean(cookie["persistent"]),
                  let expiry = cookie["expiresAtMs"] as? NSNumber, CFGetTypeID(expiry) != CFBooleanGetTypeID(),
                  let expiresAt = Int64(expiry.stringValue),
                  hostOnly ? host == domain : (host == domain || host.hasSuffix("." + domain)) else {
                throw failure("INVALID_STATE_REQUEST", "Original parsed Cookie attributes are malformed")
            }
            // Use the system's actual response-cookie property representation,
            // including HttpOnly. That attribute has no public property-key
            // constant, so guessing its initializer key/value is not portable.
            let parsed = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": raw], for: url)
            guard parsed.count == 1, let seed = parsed.first, var properties = seed.properties else {
                throw failure("UNSUPPORTED_CAPABILITY", "Parsed original Cookie cannot be represented by the existing native owner [responseParser]")
            }
            let nativeDomain = hostOnly ? domain : "." + domain
            properties[.name] = name; properties[.value] = value
            properties[.domain] = nativeDomain; properties[.path] = path; properties[.originURL] = url
            // OkHttp already resolved Max-Age to one absolute millisecond date.
            // Replaying its relative value here would start a second clock.
            properties.removeValue(forKey: .maximumAge)
            properties[.version] = "0"
            // Discard is optional. Version0 defaults to persistent when the
            // key is absent; WebKit emits its true value only for session cookies.
            // Never supply an explicit false NSNumber for a persistent cookie.
            if persistent { properties.removeValue(forKey: .discard) }
            else { properties[.discard] = NSNumber(value: true) }
            let nativeExpiry = expiresAt == Int64.min ? Date(timeIntervalSince1970: 0)
                : Date(timeIntervalSince1970: Double(expiresAt) / 1000)
            if persistent { properties[.expires] = nativeExpiry }
            else { properties.removeValue(forKey: .expires) }
            guard let native = HTTPCookie(properties: properties) else {
                throw failure("UNSUPPORTED_CAPABILITY", "Parsed original Cookie cannot be represented by the existing native owner [construction]")
            }
            // Only fixed field labels and numeric expiry proof enter diagnostics.
            // Never include Cookie names/values/domains/paths or header bytes.
            var mismatches: [String] = []
            if !native.name.utf8.elementsEqual(name.utf8) { mismatches.append("name") }
            if !native.value.utf8.elementsEqual(value.utf8) { mismatches.append("value") }
            if !native.domain.utf8.elementsEqual(nativeDomain.utf8) { mismatches.append("domain") }
            if !native.path.utf8.elementsEqual(path.utf8) { mismatches.append("path") }
            if native.isSecure != secure { mismatches.append("secure") }
            if native.isHTTPOnly != httpOnly { mismatches.append("httpOnly") }
            if native.isSessionOnly != !persistent { mismatches.append("session") }
            if native.expiresDate != (persistent ? nativeExpiry : nil) { mismatches.append("expiry") }
            guard mismatches.isEmpty else {
                // Exact Date equality above remains authoritative; these bits
                // retain subsecond differences instead of rounding a diagnosis.
                let expectedBits = String(nativeExpiry.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
                let seedBits = seed.expiresDate.map { String($0.timeIntervalSinceReferenceDate.bitPattern, radix: 16) } ?? "nil"
                let nativeBits = native.expiresDate.map { String($0.timeIntervalSinceReferenceDate.bitPattern, radix: 16) } ?? "nil"
                let seedMaximumAge = seed.properties?[.maximumAge] != nil
                let seedCreated = seed.properties?[HTTPCookiePropertyKey(rawValue: "Created")] != nil
                throw failure("UNSUPPORTED_CAPABILITY", "Parsed original Cookie cannot be represented by the existing native owner [\(mismatches.joined(separator: ","))] persistent=\(persistent) seedSession=\(seed.isSessionOnly) seedExpiry=\(seed.expiresDate != nil) nativeSession=\(native.isSessionOnly) nativeExpiry=\(native.expiresDate != nil) originalExpiresMs=\(expiresAt) expectedRefBits=\(expectedBits) seedRefBits=\(seedBits) nativeRefBits=\(nativeBits) seedMaximumAge=\(seedMaximumAge) seedCreated=\(seedCreated)")
            }
            records.append(try CookiePersistenceOwner.Record(cookie: native, provenance: .httpResponse,
                originURL: url, hostOnly: hostOnly, originalExpiresAtMs: expiresAt,
                originalDomain: domain, originalSetCookieHeader: raw))
            if persistent { persistentValues.append("\(name)=\(value)") }
            else { sessionValues.append("\(name)=\(value)") }
        }
        let persistent = persistentValues.joined(separator: "; "), session = sessionValues.joined(separator: "; ")
        guard input["persistentText"] as? String == persistent, input["sessionText"] as? String == session else {
            throw failure("INVALID_STATE_REQUEST", "Original response text does not match its parsed attributes")
        }
        return (records, persistent, session)
        }
    }

    private func cookieBoolean(_ raw: Any?) -> Bool? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private func cookieDomainURL(_ domain: String) -> URL? {
        guard !domain.contains("://"), let parts = URLComponents(string: "https://" + domain),
              parts.host?.isEmpty == false, parts.user == nil, parts.password == nil,
              parts.port == nil, parts.percentEncodedPath.isEmpty,
              parts.query == nil, parts.fragment == nil else { return nil }
        return parts.url
    }

    private func cookieReadDeadline(_ input: [String: Any]) throws -> Date {
        let now = Date()
        var deadline = now.addingTimeInterval(180)
        for field in ["remainingTimeoutMs", "timeoutMs", "deadlineEpochMs"] {
            guard let raw = input[field] else { continue }
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
                throw failure("INVALID_STATE_REQUEST", "Cookie owner deadline must be finite numeric metadata")
            }
            let value = number.doubleValue / 1000
            let limit = field == "deadlineEpochMs" ? Date(timeIntervalSince1970: value) : now.addingTimeInterval(value)
            deadline = min(deadline, limit)
        }
        return deadline
    }
    private func checkCookieRead(_ request: LegadoHostRequest, deadline: Date) throws {
        try Task.checkCancellation()
        guard !cancelled.contains(request.taskID) else { throw CancellationError() }
        guard deadline.timeIntervalSinceNow > 0 else { throw failure("STATE_TIMEOUT", "Cookie owner read deadline expired") }
    }

    private func cancelWebCookieOperations(owner: String) {
        for operations in pendingWebCookieOperations.values {
            for operation in operations.values where operation.owner == owner { operation.task.cancel() }
        }
    }

    func cancel(taskID: String) async {
        if cancelled.insert(taskID).inserted { cancellationOrder.append(taskID) }
        if cancellationOrder.count > 1_024 { cancelled.remove(cancellationOrder.removeFirst()) }
        for invocation in originalInvocations.values where invocation.taskID == taskID {
            invocation.invalidated = true
            for page in invocation.pages.values {
                page.cancellation.cancel()
                for child in page.children.values { child.cancel() }
            }
        }
        if let pending = pendingEntityOperations[taskID] { for ticket in pending.values { ticket.cancel() } }
        // The final returned Book.variable CAS is an App completion, beyond the
        // synchronous state callback. It borrows this same task-owned lifetime.
        for backing in contentOwners.values where backing.taskID == taskID { backing.revoke() }
        for case let backing as AppLegadoBookStateOwner in bookOwners.values where backing.callbackTaskID == taskID {
            backing.revoke()
        }
        if let pending = pendingWebCookieOperations[taskID] { for operation in pending.values { operation.task.cancel() } }
        await SourceBrowserPresenter.cancelOriginal(taskID: taskID)
        await cancelOriginalHeadless(taskID: taskID)
        await fallback.cancel(taskID: taskID)
    }

    private struct DecodedStateInput {
        let input: [String: Any]
        let owner: String
        let binding: Binding
        let keys: [String]?
        let parts: [String: [String]]
        let revision: Int64?
    }

    /// Exactly one bounded request decode, and one decode of each read key. Bad JSON,
    /// numeric revisions and unknown capabilities are explicit typed failures.
    private func decodeStateRequest(_ request: LegadoHostRequest) throws -> DecodedStateInput {
        guard request.requestJSON.utf8.count <= 2_097_152 else { throw failure("STATE_LIMIT", "State payload is oversized") }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: Data(request.requestJSON.utf8)) }
        catch { throw failure("INVALID_STATE_REQUEST", "State payload is not valid JSON") }
        guard let input = object as? [String: Any] else { throw failure("INVALID_STATE_REQUEST", "State payload requires an object") }
        guard let owner = input["owner"] as? String, let binding = bindings[owner],
              revisions[binding.sourceURL] == binding.sourceRevision else {
            throw failure("INVALID_STATE_OWNER", "State request has no current embedding-owner grant")
        }
        if request.operation == "state.read" {
            guard let keys = input["keys"] as? [String], !keys.isEmpty, keys.count <= 64,
                  Set(keys).count == keys.count else { throw failure("STATE_LIMIT", "State read requires 1...64 unique keys") }
            var decoded: [String: [String]] = [:]
            for wire in keys {
                guard wire.utf8.count <= 16_384 else { throw failure("STATE_LIMIT", "State key is oversized") }
                let key: Any
                do { key = try JSONSerialization.jsonObject(with: Data(wire.utf8)) }
                catch { throw failure("INVALID_STATE_REQUEST", "State key is not valid JSON") }
                guard let parts = key as? [String], parts.count >= 2 else { throw failure("INVALID_STATE_REQUEST", "State key requires identity components") }
                decoded[wire] = parts
            }
            return .init(input: input, owner: owner, binding: binding, keys: keys, parts: decoded, revision: nil)
        }
        guard let number = input["revision"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), let revision = Int64(number.stringValue), revision > 0 else {
            throw failure("INVALID_STATE_REQUEST", "State commit requires an exact positive Int64 revision")
        }
        return .init(input: input, owner: owner, binding: binding, keys: nil, parts: [:], revision: revision)
    }

    private func trimLeases() {
        if leaseOrder.count > 256 {
            let expired = leaseOrder.removeFirst()
            leases.removeValue(forKey: expired)
            entityLeases.removeValue(forKey: expired)
            contentLeases.removeValue(forKey: expired)
            previewTOCLeases.removeValue(forKey: expired)
        }
    }

    private func authorizeContentBatch(_ request: LegadoHostRequest) throws -> String {
        try check(request)
        guard request.requestJSON.utf8.count <= 65_536 else { throw failure("STATE_LIMIT", "Batch grant request is oversized") }
        let raw: Any
        do { raw = try JSONSerialization.jsonObject(with: Data(request.requestJSON.utf8)) }
        catch { throw failure("INVALID_STATE_REQUEST", "Batch grant request is not valid JSON") }
        guard let input = raw as? [String: Any], Set(input.keys).isSubset(of: ["owner", "sourceURL", "bookURL", "chapters", "deadlineEpochMs", "remainingTimeoutMs"]),
              let owner = input["owner"] as? String, let binding = bindings[owner],
              revisions[binding.sourceURL] == binding.sourceRevision,
              let sourceURL = input["sourceURL"] as? String, sourceURL.utf8.elementsEqual(binding.sourceURL.utf8),
              let bookURL = input["bookURL"] as? String, let rows = input["chapters"] as? [[String: Any]], rows.count <= 32,
              let backing = contentOwners[owner] else { throw failure("UNSUPPORTED_CAPABILITY", "No actual App batch save owner is bound") }
        try backing.validateRequest(request)
        let chapters: [(Int, String)] = try rows.map { row in
            guard Set(row.keys) == ["index", "url"], let number = row["index"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), let index = Int(number.stringValue), index >= 0,
                  let url = row["url"] as? String, !url.isEmpty, url.utf8.count <= 8_192 else {
                throw failure("INVALID_STATE_REQUEST", "Batch chapter identity is malformed")
            }
            return (index, url)
        }
        try backing.authorize(bookURL: bookURL, chapters: chapters, deadline: cookieReadDeadline(input))
        return try encoded(["authorized": true])
    }

    /// The original TOC metadata table belongs to the existing preview context,
    /// not the App body cache. No preview read or TOC publish grants a body save.
    private func dispatchPreviewTOCStateIfNeeded(_ request: LegadoHostRequest, decoded: DecodedStateInput) async throws -> String? {
        let preview = bookOwners[decoded.owner] as? LegadoPreviewStateOwner
        let isRead = request.operation == "state.read" && decoded.parts.values.contains { $0[1] == "toc" } && preview != nil
        guard isRead || decoded.revision.flatMap({ previewTOCLeases[$0] }) != nil else { return nil }
        guard let preview else { throw failure("INVALID_STATE_OWNER", "Preview TOC grant is no longer bound") }
        try preview.validateRequest(request)
        let grant = preview.grant; let deadline = try cookieReadDeadline(decoded.input)
        let ticket = OriginalRuntimeCommitCancellation(); let id = UUID()
        pendingEntityOperations[request.taskID, default: [:]][id] = ticket
        defer {
            pendingEntityOperations[request.taskID]?.removeValue(forKey: id)
            if pendingEntityOperations[request.taskID]?.isEmpty == true { pendingEntityOperations.removeValue(forKey: request.taskID) }
        }
        return try await SourcePerfTrace.spanAsync("legado.state.preview-toc", "bytes=\(request.requestJSON.utf8.count) main=\(Thread.isMainThread)") {
            if isRead {
                guard let keys = decoded.keys, keys.count == 1, let wire = keys.first,
                      let parts = decoded.parts[wire], parts.count == 3, parts[1] == "toc",
                      LegadoPreviewIdentity.same(parts[0], decoded.binding.sourceURL),
                      LegadoPreviewIdentity.same(parts[2], grant.bookURL) else {
                    throw failure("UNSUPPORTED_CAPABILITY", "Preview TOC requires one exact source/book metadata key")
                }
                let snapshot = try await withTaskCancellationHandler {
                    try await grant.service.readPreviewTOCState(grant, wire: wire, deadline: deadline, cancellation: ticket)
                } onCancel: { ticket.cancel() }
                try check(request); try currentEntityBinding(owner: decoded.owner, binding: decoded.binding)
                let values = snapshot.value.map { [wire: $0.base64EncodedString()] } ?? [:]
                // Content uses this solely for original next-chapter lookup. Only
                // the explicit TOC task can acquire a metadata publication lease.
                guard grant.discoveringChapters else { return try encoded(["revision": 0, "values": values]) }
                guard previewTOCLeases.count < 32, nextLease < Int64.max else { throw failure("STATE_LIMIT", "Preview TOC lease budget exceeded") }
                nextLease += 1
                let proof = LegadoPreviewTOCStateSnapshot(recordID: snapshot.recordID, revision: snapshot.revision,
                    rawSHA256: snapshot.rawSHA256, bookURL: snapshot.bookURL, wire: wire, value: nil)
                previewTOCLeases[nextLease] = .init(owner: decoded.owner, binding: decoded.binding, grant: grant, snapshot: proof)
                leaseOrder.append(nextLease); trimLeases()
                return try encoded(["revision": nextLease, "values": values])
            }
            guard let revision = decoded.revision, let lease = previewTOCLeases[revision],
                  lease.owner == decoded.owner, lease.binding.sourceRevision == decoded.binding.sourceRevision else {
                return try encoded(["committed": false])
            }
            previewTOCLeases.removeValue(forKey: revision)
            guard let changes = decoded.input["changes"] as? [String: Any], changes.count == 1,
                  let first = changes.first, first.key.utf8.elementsEqual(lease.snapshot.wire.utf8),
                  let text = first.value as? String, text.utf8.count <= 1_398_104,
                  let data = Data(base64Encoded: text), data.count <= 1_048_576 else {
                throw failure("UNSUPPORTED_CAPABILITY", "Preview TOC publication cannot change entity variables or chapter bodies")
            }
            try check(request); try currentEntityBinding(owner: decoded.owner, binding: decoded.binding)
            let committed = try await withTaskCancellationHandler {
                try await grant.service.commitPreviewTOCState(grant, snapshot: lease.snapshot, value: data,
                    deadline: deadline, cancellation: ticket,
                    claimCommit: { request.recordPossibleEffect("previewTOCMayCommit") })
            } onCancel: { ticket.cancel() }
            if committed { request.recordPossibleEffect("previewTOCCommitted") }
            return try encoded(["committed": committed])
        }
    }

    private func dispatchContentStateIfNeeded(_ request: LegadoHostRequest, decoded: DecodedStateInput) async throws -> String? {
        let isRead = request.operation == "state.read" && decoded.parts.values.contains { $0[1] == "content" || $0[1] == "toc" }
        guard isRead || decoded.revision.flatMap({ contentLeases[$0] }) != nil else { return nil }
        guard let backing = contentOwners[decoded.owner] else { throw failure("UNSUPPORTED_CAPABILITY", "Body state requires actual App chapter save grants") }
        try backing.validateRequest(request)
        let deadline = try cookieReadDeadline(decoded.input)
        let ticket = OriginalRuntimeCommitCancellation(); let id = UUID()
        pendingEntityOperations[request.taskID, default: [:]][id] = ticket
        defer {
            pendingEntityOperations[request.taskID]?.removeValue(forKey: id)
            if pendingEntityOperations[request.taskID]?.isEmpty == true { pendingEntityOperations.removeValue(forKey: request.taskID) }
        }
        return try await SourcePerfTrace.spanAsync("legado.state.content", "bytes=\(request.requestJSON.utf8.count) main=\(Thread.isMainThread)") {
            if isRead {
                let keys = try backing.parseContent(decoded.keys!, sourceURL: decoded.binding.sourceURL, decoded: decoded.parts)
                let snapshot = try await withTaskCancellationHandler {
                    try await backing.readContent(keys: keys, deadline: deadline, cancellation: ticket)
                } onCancel: { ticket.cancel() }
                try check(request); try currentEntityBinding(owner: decoded.owner, binding: decoded.binding)
                guard snapshot.state.values.values.reduce(0, { $0 + $1.count }) <= 1_048_576 else { throw failure("STATE_LIMIT", "Content snapshot exceeds its bridge byte budget") }
                // contentSaveToken performs a value-only read; retaining an
                // unused CAS lease for all 32 chapters would exhaust the first
                // actual save. Only content+TOC read sets can enter a save CAS.
                if keys.count == 1 {
                    return try encoded(["revision": 0, "values": snapshot.state.values.mapValues { $0.base64EncodedString() }])
                }
                guard contentLeases.count < 32 else { throw failure("STATE_LIMIT", "Too many active content save CAS proofs") }
                guard nextLease < Int64.max else { throw failure("STATE_LIMIT", "State revision space exhausted") }
                nextLease += 1
                // Retain only CAS identity/fingerprints, never the returned prose or
                // whole TOC bytes as another in-memory body cache.
                let proof = LegadoContentStateSnapshot(index: snapshot.index,
                    cache: .init(bookID: snapshot.cache.bookID, index: snapshot.cache.index, package: nil,
                        fingerprints: snapshot.cache.fingerprints),
                    state: .init(revision: snapshot.state.revision, values: [:]))
                contentLeases[nextLease] = .init(owner: decoded.owner, binding: decoded.binding, backing: backing, keys: keys, snapshot: proof)
                leaseOrder.append(nextLease); trimLeases()
                return try encoded(["revision": nextLease, "values": snapshot.state.values.mapValues { $0.base64EncodedString() }])
            }
            guard let revision = decoded.revision, let lease = contentLeases.removeValue(forKey: revision),
                  lease.owner == decoded.owner, lease.binding.sourceRevision == decoded.binding.sourceRevision else {
                return try encoded(["committed": false])
            }
            guard let rawChanges = decoded.input["changes"] as? [String: Any], rawChanges.count == 1,
                  rawChanges.keys.allSatisfy({ key in lease.keys.contains(where: { $0.wire == key && $0.index != nil }) }) else {
                throw failure("UNSUPPORTED_CAPABILITY", "Body commit cannot change another owner or TOC metadata")
            }
            var changes: [String: Data?] = [:]
            for (key, raw) in rawChanges {
                guard let value = raw as? String, value.utf8.count <= 1_398_104,
                      let bytes = Data(base64Encoded: value), bytes.count <= 1_048_576 else { throw failure("STATE_LIMIT", "Content commit is malformed or oversized") }
                changes.updateValue(bytes, forKey: key)
            }
            try check(request); try currentEntityBinding(owner: decoded.owner, binding: decoded.binding)
            let committed = try await withTaskCancellationHandler {
                try await lease.backing.commitContent(snapshot: lease.snapshot, keys: lease.keys, changes: changes,
                    deadline: deadline, cancellation: ticket, request: request)
            } onCancel: { ticket.cancel() }
            // Commit receipt already crossed actual file IO. Never replace that
            // fact with a later cancel/revoke "false" response.
            return try encoded(["committed": committed])
        }
    }

    /// Entity records use raw variable bytes, unlike the CacheManager envelope used by
    /// source/cache keys. The actual App owner performs every async snapshot and write.
    private func dispatchEntityStateIfNeeded(_ request: LegadoHostRequest, decoded: DecodedStateInput) async throws -> String? {
        let input = decoded.input; let owner = decoded.owner; let binding = decoded.binding
        let rawKeys = decoded.keys; let revision = decoded.revision
        let isEntityRead = request.operation == "state.read" && decoded.parts.values.contains { $0[1] == "variables" || $0[1] == "big-variable" }
        guard isEntityRead || revision.flatMap({ entityLeases[$0] }) != nil else { return nil }
        guard let backing = bookOwners[owner] else {
            throw failure("UNSUPPORTED_CAPABILITY", "Entity state has no explicitly connected App book owner")
        }
        try backing.validateRequest(request)
        let deadline = Date().addingTimeInterval(request.remainingTimeoutSeconds)
        return try await SourcePerfTrace.spanAsync("legado.state.entity", "bytes=\(request.requestJSON.utf8.count) main=\(Thread.isMainThread)") {
            if isEntityRead {
                guard let rawKeys, !rawKeys.isEmpty, rawKeys.count <= 64, Set(rawKeys).count == rawKeys.count else {
                    throw failure("STATE_LIMIT", "Entity read requires 1...64 unique keys")
                }
                let keys = try backing.parse(rawKeys, sourceURL: binding.sourceURL, decodedParts: decoded.parts)
                let ticket = OriginalRuntimeCommitCancellation(); let requestID = UUID()
                pendingEntityOperations[request.taskID, default: [:]][requestID] = ticket
                defer {
                    pendingEntityOperations[request.taskID]?.removeValue(forKey: requestID)
                    if pendingEntityOperations[request.taskID]?.isEmpty == true { pendingEntityOperations.removeValue(forKey: request.taskID) }
                }
                let snapshot = try await withTaskCancellationHandler {
                    try await backing.readState(keys: keys, deadline: deadline, cancellation: ticket)
                } onCancel: { ticket.cancel() }
                try check(request)
                try currentEntityBinding(owner: owner, binding: binding)
                guard nextLease < Int64.max else { throw failure("STATE_LIMIT", "State revision space exhausted") }
                let values = snapshot.state.values.mapValues { $0.base64EncodedString() }
                guard snapshot.state.values.values.reduce(0, { $0 + $1.count }) <= 1_048_576 else {
                    throw failure("STATE_LIMIT", "Entity read exceeds its byte limit")
                }
                nextLease += 1
                entityLeases[nextLease] = .init(owner: owner, binding: binding, backing: backing, keys: keys, snapshot: snapshot)
                leaseOrder.append(nextLease); trimLeases()
                return try encoded(["revision": nextLease, "values": values])
            }
            guard let revision, let rawChanges = input["changes"] as? [String: Any],
                  !rawChanges.isEmpty, rawChanges.count <= 64 else {
                throw failure("INVALID_STATE_REQUEST", "Entity commit requires bounded changes")
            }
            guard let lease = entityLeases.removeValue(forKey: revision), lease.owner == owner,
                  lease.binding.sourceURL == binding.sourceURL, lease.binding.sourceRevision == binding.sourceRevision else {
                return try encoded(["committed": false])
            }
            let allowed = Set(lease.keys.map(\.wire))
            guard rawChanges.keys.allSatisfy({ allowed.contains($0) }) else {
                throw failure("INVALID_STATE_REQUEST", "Entity commit changed an unread key")
            }
            var changes: [String: Data?] = [:]
            for (wire, raw) in rawChanges {
                if raw is NSNull { changes.updateValue(nil, forKey: wire) }
                else {
                    guard let text = raw as? String, text.utf8.count <= 1_398_104,
                          let data = Data(base64Encoded: text), data.count <= 1_048_576 else {
                        throw failure("STATE_LIMIT", "Entity value is malformed or oversized")
                    }
                    changes.updateValue(data, forKey: wire)
                }
            }
            try check(request)
            try currentEntityBinding(owner: owner, binding: binding)
            let ticket = OriginalRuntimeCommitCancellation(); let requestID = UUID()
            pendingEntityOperations[request.taskID, default: [:]][requestID] = ticket
            defer {
                pendingEntityOperations[request.taskID]?.removeValue(forKey: requestID)
                if pendingEntityOperations[request.taskID]?.isEmpty == true { pendingEntityOperations.removeValue(forKey: request.taskID) }
            }
            let effectPrefix = lease.keys.first?.chapterURL == nil ? "bookVariables" : "chapterVariables"
            let committed = try await withTaskCancellationHandler {
                try await backing.commitState(snapshot: lease.snapshot, keys: lease.keys, changes: changes,
                    deadline: deadline, cancellation: ticket,
                    claimCommit: { request.recordPossibleEffect(effectPrefix + "MayCommit") })
            } onCancel: { ticket.cancel() }
            if committed { request.recordPossibleEffect(effectPrefix + "Committed") }
            // Successful atomic replacement is already the owner transaction boundary.
            // A later cancel/revoke cannot be reported as an uncommitted disk mutation.
            return try encoded(["committed": committed])
        }
    }

    private func refreshBookIdentity(_ request: LegadoHostRequest) async throws -> String {
        try check(request)
        guard request.requestJSON.utf8.count <= 1_114_112,
              let input = try JSONSerialization.jsonObject(with: Data(request.requestJSON.utf8)) as? [String: Any],
              Set(input.keys).isSubset(of: ["owner", "sourceURL", "fromBookURL", "toBookURL", "bookVariables", "deadlineEpochMs", "remainingTimeoutMs"]),
              let owner = input["owner"] as? String, let binding = bindings[owner],
              let sourceURL = input["sourceURL"] as? String, LegadoPreviewIdentity.same(sourceURL, binding.sourceURL),
              revisions[binding.sourceURL] == binding.sourceRevision,
              let preview = bookOwners[owner] as? LegadoPreviewStateOwner,
              let from = input["fromBookURL"] as? String, let to = input["toBookURL"] as? String,
              let variables = input["bookVariables"] as? String, variables.utf8.count <= 1_048_576 else {
            throw failure("INVALID_STATE_REQUEST", "Book identity refresh requires its exact current owner and bounded fields")
        }
        try preview.validateRequest(request)
        let deadline = min(try cookieReadDeadline(input), Date().addingTimeInterval(request.remainingTimeoutSeconds))
        let ticket = OriginalRuntimeCommitCancellation(); let requestID = UUID()
        pendingEntityOperations[request.taskID, default: [:]][requestID] = ticket
        defer {
            pendingEntityOperations[request.taskID]?.removeValue(forKey: requestID)
            if pendingEntityOperations[request.taskID]?.isEmpty == true { pendingEntityOperations.removeValue(forKey: request.taskID) }
        }
        return try await SourcePerfTrace.spanAsync("legado.book.refresh.identity", "bytes=\(request.requestJSON.utf8.count) main=\(Thread.isMainThread)") {
            guard request.recordPossibleEffect("bookIdentityGrantMayChange") else { throw CancellationError() }
            try await withTaskCancellationHandler {
                try await preview.grant.service.refreshPreviewBookIdentity(preview.grant, from: from, to: to,
                    bookVariables: variables, deadline: deadline, cancellation: ticket)
            } onCancel: { ticket.cancel() }
            // No old entity/TOC lease can authorize writes after this scope change.
            entityLeases = entityLeases.filter { $0.value.owner != owner }
            previewTOCLeases = previewTOCLeases.filter { $0.value.owner != owner }
            request.recordPossibleEffect("bookIdentityGrantChanged")
            try check(request); try currentEntityBinding(owner: owner, binding: binding)
            try preview.grant.check(deadline: deadline)
            return try encoded(["accepted": true, "bookURL": to])
        }
    }

    private func currentEntityBinding(owner: String, binding: Binding) throws {
        guard bindings[owner] != nil, revisions[binding.sourceURL] == binding.sourceRevision else {
            throw failure("INVALID_STATE_OWNER", "The App entity grant was revoked while awaiting its owner")
        }
    }

    private func check(_ request: LegadoHostRequest) throws {
        try Task.checkCancellation()
        guard !cancelled.contains(request.taskID) else { throw CancellationError() }
        guard request.remainingTimeoutSeconds > 0 else { throw failure("STATE_TIMEOUT", "State request deadline expired") }
    }

    private func parse(_ values: [String], binding: Binding, decodedParts: [String: [String]]) throws -> [Key] {
        var result: [Key] = []
        for wire in values {
            guard let parts = decodedParts[wire], parts.count == 3,
                  parts[0] == binding.sourceURL, ["cache-text", "cache-binary", "jslib-text"].contains(parts[1]) else {
                throw failure("UNSUPPORTED_CAPABILITY", "State key has no connected App source owner")
            }
            let source = binding.sourceURL
            let raw = parts[2]
            let domain: LegadoOwnedStateDomain
            let field: String
            if parts[1] == "jslib-text" {
                guard raw.utf8.count == 32, raw.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                    throw failure("INVALID_STATE_REQUEST", "Shared jsLib requires an exact lowercase URL MD5")
                }
                domain = .sharedJsLibrary(raw); field = "value"
            } else if raw == "sourceVariable_" + source { domain = .sourceVariable; field = "value" }
            else if raw == "loginHeader_" + source { domain = .loginHeader; field = "value" }
            else if raw.hasPrefix("v_" + source + "_") {
                domain = .sourceValues
                field = String(raw.dropFirst(("v_" + source + "_").count))
            } else { domain = .cacheText(raw); field = "value" }
            result.append(Key(wire: wire, domain: domain, field: field, binaryCompanion: parts[1] == "cache-binary"))
        }
        guard let first = result.first, result.allSatisfy({ $0.domain == first.domain }),
              result.contains(where: { !$0.binaryCompanion }),
              Set(result.filter { !$0.binaryCompanion }.map(\.field)).count == result.filter({ !$0.binaryCompanion }).count else {
            throw failure("UNSUPPORTED_CAPABILITY", "Transactions spanning App owners or binary caches are not connected")
        }
        for key in result where key.binaryCompanion {
            guard result.contains(where: { !$0.binaryCompanion && $0.field == key.field }) else {
                throw failure("UNSUPPORTED_CAPABILITY", "A binary cache key is supported only as an empty deletion companion")
            }
        }
        return result
    }

    private func wireValue(_ data: Data, domain: LegadoOwnedStateDomain) throws -> Data {
        if case .cacheText = domain { return data }
        if case .sharedJsLibrary = domain { return data }
        guard let value = String(data: data, encoding: .utf8) else { throw failure("STATE_IO", "App source state is not UTF-8") }
        return try LegadoRuntimeCacheEntry(text: value).encoded()
    }

    private func storedValue(_ data: Data, domain: LegadoOwnedStateDomain) throws -> Data {
        let entry = try JSONDecoder().decode(LegadoRuntimeCacheEntry.self, from: data)
        let text = try entry.text()
        if case .cacheText = domain { return try entry.encoded() }
        if case .sharedJsLibrary = domain {
            guard entry.deadline == 0 else { throw failure("UNSUPPORTED_CAPABILITY", "Shared jsLib has no caller-selected TTL") }
            return try entry.encoded()
        }
        guard entry.deadline == 0 else { throw failure("UNSUPPORTED_CAPABILITY", "TTL on App source variables or login headers is not connected") }
        if case .loginHeader = domain {
            let object: [String: Any]?
            do { object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] }
            catch { object = nil } // A bare token is a valid verbatim login payload.
            if object?.contains(where: { $0.key.caseInsensitiveCompare("Cookie") == .orderedSame && ($0.value as? String) != "" }) == true {
                throw failure("UNSUPPORTED_CAPABILITY", "Login headers with Cookie require the complete Cookie owner adapter")
            }
        }
        return Data(text.utf8)
    }

    private func encoded(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
    private func failure(_ code: String, _ message: String) -> LegadoRuntimeError {
        LegadoRuntimeError(code: code, message: message)
    }
}
