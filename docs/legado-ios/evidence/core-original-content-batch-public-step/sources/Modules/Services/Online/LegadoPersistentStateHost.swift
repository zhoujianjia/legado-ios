import Foundation
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
    case cacheText(String)
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
}

/// Reuses the shipped source, login and cache owners. It never writes a second
/// source database, Cookie jar, chapter directory or shelf metadata file.
struct AppLegadoOwnedStateBacking: @unchecked Sendable, LegadoOwnedStateBacking {
    let sources: BookSourceRuntimeStateStore
    let login: LoginManager

    func read(sourceURL: String, domain: LegadoOwnedStateDomain, fields: Set<String>) throws -> LegadoOwnedStateSnapshot {
        switch domain {
        case .sourceVariable: return sources.runtimeVariableSnapshot(for: sourceURL)
        case .sourceValues: return sources.runtimeValuesSnapshot(for: sourceURL, keys: fields)
        case .loginHeader: return login.runtimeHeaderSnapshot(sourceUrl: sourceURL)
        case .cacheText(let key): return try LegadoCacheBridge.runtimeSnapshot(sourceId: sourceURL, key: key)
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
        }
    }
}

/// JNI's existing HostCallback now has an explicitly bound state adapter.
/// Bindings are granted by the embedding App; imported JSON never grants an
/// owner or selects a filesystem path. Book/chapter identity requires bindBook; complete
/// Cookie storage and transactions spanning independent App owners remain unsupported.
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
    private let backing: any LegadoOwnedStateBacking
    private let fallback: any LegadoPlatformHost
    private var bindings: [String: Binding] = [:]
    private var revisions: [String: String] = [:]
    private var leases: [Int64: Lease] = [:]
    private var bookOwners: [String: any LegadoEntityStateBacking] = [:]
    private var entityLeases: [Int64: EntityLease] = [:]
    private struct ContentLease {
        let owner: String; let binding: Binding; let backing: AppLegadoContentBatchOwner
        let keys: [LegadoContentStateKey]; let snapshot: LegadoContentStateSnapshot
    }
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
         originalWebCookieStore: @escaping @MainActor @Sendable () -> WKHTTPCookieStore = { WKWebsiteDataStore.default().httpCookieStore }) {
        self.cookieOwner = cookieOwner
        self.originalWebCookieStore = originalWebCookieStore
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
                cancelWebCookieOperations(owner: owner)
                bookOwners.removeValue(forKey: owner)?.revoke()
                contentOwners.removeValue(forKey: owner)
            }
            bindings = bindings.filter { $0.value.sourceURL != sourceURL }
            leases = leases.filter { $0.value.binding.sourceURL != sourceURL }
            entityLeases = entityLeases.filter { $0.value.binding.sourceURL != sourceURL }
            contentLeases = contentLeases.filter { $0.value.binding.sourceURL != sourceURL }
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
                  chapter: OnlineChapterRef? = nil, generation: OriginalRuntimeChapterGeneration? = nil) async throws -> String {
        let previousRevision = revisions[sourceURL]
        guard await store.prepareOriginalRuntimeBookSnapshot(id: bookID, sourceID: sourceID, bookURL: bookURL) != nil else {
            throw failure("UNSUPPORTED_CAPABILITY", "The App book/source identity has no current stable owner")
        }
        let backing = try AppLegadoBookStateOwner(store: store, bookID: bookID, sourceID: sourceID,
            bookURL: bookURL, chapter: chapter, generation: generation)
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
                          cache: ChapterCacheRepository = BookSourceFetcher.chapterCacheRepository) async throws -> String {
        let previous = revisions[sourceURL]
        guard book.origin.utf8.elementsEqual(sourceURL.utf8),
              await store.prepareOriginalRuntimeBookSnapshot(id: bookID, sourceID: sourceID, bookURL: book.bookURL) != nil else {
            throw failure("UNSUPPORTED_CAPABILITY", "Batch requires an existing App book/source UUID")
        }
        let backing = try AppLegadoContentBatchOwner(taskID: taskID, store: store, bookID: bookID, sourceID: sourceID,
            book: book, chapters: chapters, deadline: deadline, cache: cache)
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
        let removed = bindings.removeValue(forKey: owner)
        removed?.cookieCancellation.cancel()
        cancelWebCookieOperations(owner: owner)
        bookOwners.removeValue(forKey: owner)?.revoke()
        contentOwners.removeValue(forKey: owner)
        contentLeases = contentLeases.filter { $0.value.owner != owner }
        leases = leases.filter { $0.value.owner != owner }
        entityLeases = entityLeases.filter { $0.value.owner != owner }
        if let removed, !bindings.values.contains(where: { $0.sourceURL == removed.sourceURL }) {
            revisions.removeValue(forKey: removed.sourceURL)
        }
    }

    /// Value-free diagnostics for verifying bounded ownership bookkeeping.
    func ownershipCounts() -> (bindings: Int, sourceRevisions: Int, leases: Int) {
        (bindings.count, revisions.count, leases.count + entityLeases.count + contentLeases.count)
    }

    func dispatch(_ request: LegadoHostRequest) async throws -> String {
        if request.operation == "content.batch.authorize" { return try authorizeContentBatch(request) }
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
                committed = try backing.commit(sourceURL: binding.sourceURL,
                    domain: lease.keys[0].domain, expected: lease.snapshot, changes: changes)
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
            var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value,
                .domain: hostOnly ? domain : "." + domain, .path: path, .originURL: url]
            if secure { properties[.secure] = "TRUE" }
            if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            let nativeExpiry = expiresAt == Int64.min ? Date(timeIntervalSince1970: 0)
                : Date(timeIntervalSince1970: Double(expiresAt) / 1000)
            if persistent {
                // OkHttp Long.MIN_VALUE is an explicit deletion marker. Keep
                // that exact integer in provenance and use an expired native date.
                properties[.expires] = nativeExpiry
            } else { properties[.discard] = "TRUE" }
            guard let native = HTTPCookie(properties: properties), native.name == name, native.value == value,
                  native.path == path, native.isSecure == secure, native.isHTTPOnly == httpOnly,
                  native.isSessionOnly == !persistent, native.expiresDate == (persistent ? nativeExpiry : nil) else {
                throw failure("UNSUPPORTED_CAPABILITY", "Parsed original Cookie cannot be represented by the existing native owner")
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
        if let pending = pendingEntityOperations[taskID] { for ticket in pending.values { ticket.cancel() } }
        // The final returned Book.variable CAS is an App completion, beyond the
        // synchronous state callback. It borrows this same task-owned lifetime.
        for backing in contentOwners.values where backing.taskID == taskID { backing.revoke() }
        if let pending = pendingWebCookieOperations[taskID] { for operation in pending.values { operation.task.cancel() } }
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
                  parts[0] == binding.sourceURL, ["cache-text", "cache-binary"].contains(parts[1]) else {
                throw failure("UNSUPPORTED_CAPABILITY", "State key has no connected App source owner")
            }
            let source = binding.sourceURL
            let raw = parts[2]
            let domain: LegadoOwnedStateDomain
            let field: String
            if raw == "sourceVariable_" + source { domain = .sourceVariable; field = "value" }
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
        guard let value = String(data: data, encoding: .utf8) else { throw failure("STATE_IO", "App source state is not UTF-8") }
        return try LegadoRuntimeCacheEntry(text: value).encoded()
    }

    private func storedValue(_ data: Data, domain: LegadoOwnedStateDomain) throws -> Data {
        let entry = try JSONDecoder().decode(LegadoRuntimeCacheEntry.self, from: data)
        let text = try entry.text()
        if case .cacheText = domain { return try entry.encoded() }
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
