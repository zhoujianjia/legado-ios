import Foundation

/// The three files written by the existing WebDAV backup. This is a bounded
/// restore transaction, not another store or a cross-file crash journal.
enum WebDAVRestoreComponent: String, CaseIterable, Codable, Sendable {
    case sources = "book_sources.json"
    case books = "books.json"
    case rules = "replace_rules.json"
}

struct WebDAVRestorePayload {
    let sources: [BookSource]?
    let books: [ReadingBook]?
    let booksData: Data?
    let rules: [ReplaceRule]?
}

struct WebDAVRestoreConfiguration: Sendable {
    let serverURL: String
    let authorization: String
    let deviceID: String
    let lastSyncDate: Date?
}

struct WebDAVRestoreEnvironment: @unchecked Sendable {
    let destinations: [WebDAVRestoreComponent: URL]
    let temporaryRoot: URL
    let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    var copyOriginal: @Sendable (URL, URL) throws -> Void = {
        try FileManager.default.copyItem(at: $0, to: $1)
    }
    var install: @Sendable (URL, URL) throws -> Void = WebDAVRestoreTransaction.installFile
    var remove: @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    var prepareBooks: @Sendable ([ReadingBook]) -> [ReadingBook] = { $0 }
    let prepareStores: @MainActor (WebDAVRestorePayload) async throws -> WebDAVRestoreWriterLease
    var publish: @MainActor (WebDAVRestorePayload) -> Void
}

struct WebDAVRestoreWriterLease: @unchecked Sendable {
    let isCurrent: @MainActor () -> Bool
    let finish: @MainActor () async -> Void

    static var uncoordinated: Self { .init(isCurrent: { true }, finish: {}) }
}

enum WebDAVRestoreFailure: LocalizedError {
    case invalidData
    case noData
    case commitFailed
    /// The directory remains on disk; user-facing text deliberately omits its path.
    case rollbackFailed(recoveryDirectory: URL)

    var errorDescription: String? {
        switch self {
        case .invalidData: return localized("WebDAV 資料格式無效")
        case .noData: return WebDAVError.noData.errorDescription
        case .commitFailed: return localized("WebDAV 還原未完成，原資料已恢復。")
        case .rollbackFailed: return localized("WebDAV 還原失敗，已保留復原資料。")
        }
    }
}

enum WebDAVRestoreTransaction {
    struct Prepared {
        let directory: URL
        let incoming: [WebDAVRestoreComponent: URL]
        let payload: WebDAVRestorePayload
        let manifest: SyncManifest?
        let bytes: Int
    }

    private struct Original: Codable {
        let component: WebDAVRestoreComponent
        let destination: URL
        let backup: URL?
    }

    /// Explicitly detached: the test target's approachable concurrency must not
    /// accidentally run decoding, file copying or rollback on the caller's actor.
    static func offMain<T>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let worker = Task.detached(priority: .userInitiated, operation: operation)
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func prepare(
        configuration: WebDAVRestoreConfiguration, environment: WebDAVRestoreEnvironment
    ) async throws -> Prepared {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let fm = FileManager.default
        let directory = environment.temporaryRoot.appendingPathComponent("WebDAVRestore-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            var totalBytes = 0
            let manifestData = try await download("manifest.json", configuration: configuration, environment: environment)
            let manifest: SyncManifest?
            if let manifestData {
                totalBytes += manifestData.count
                manifest = try decode(SyncManifest.self, data: manifestData, component: "manifest")
            } else {
                manifest = nil
            }
            var sources: [BookSource]?
            var books: [ReadingBook]?
            var booksData: Data?
            var rules: [ReplaceRule]?
            var incoming: [WebDAVRestoreComponent: URL] = [:]
            for component in WebDAVRestoreComponent.allCases {
                try Task.checkCancellation()
                guard let data = try await download(component.rawValue, configuration: configuration, environment: environment) else { continue }
                totalBytes += data.count
                var stagedData = data
                switch component {
                case .sources:
                    let value = try decode([BookSource].self, data: data, component: component.rawValue)
                    guard Set(value.map(\.id)).count == value.count else { throw WebDAVRestoreFailure.invalidData }
                    sources = value
                case .books:
                    let value = try decode([ReadingBook].self, data: data, component: component.rawValue)
                    guard Set(value.map(\.id)).count == value.count else { throw WebDAVRestoreFailure.invalidData }
                    let repaired = environment.prepareBooks(value)
                    books = repaired
                    // Old builds embedded TOCs. ReadingBook now omits them when
                    // encoding, so keep those original bytes durable until the
                    // normal writer flushes sidecars before migrating metadata.
                    if !value.contains(where: { $0.onlineChapters != nil }) {
                        stagedData = try SourcePerfTrace.span("webdav.restore.books.encode", "books=\(repaired.count) main=\(Thread.isMainThread)") {
                            try JSONEncoder().encode(repaired)
                        }
                    }
                    booksData = stagedData
                case .rules:
                    let decoded = try decode([ReplaceRule].self, data: data, component: component.rawValue)
                    let normalized = ReplaceRuleStore.deduplicated(decoded)
                    rules = normalized
                    if normalized.count != decoded.count { stagedData = try JSONEncoder().encode(normalized) }
                }
                let staged = directory.appendingPathComponent("incoming-" + component.rawValue)
                try stagedData.write(to: staged, options: .atomic)
                incoming[component] = staged
            }
            guard !incoming.isEmpty else { throw WebDAVRestoreFailure.noData }
            try Task.checkCancellation()
            return Prepared(directory: directory, incoming: incoming,
                payload: .init(sources: sources, books: books, booksData: booksData, rules: rules),
                manifest: manifest, bytes: totalBytes)
        } catch {
            cleanUp(directory)
            throw error
        }
    }

    private static func download(
        _ name: String, configuration: WebDAVRestoreConfiguration, environment: WebDAVRestoreEnvironment
    ) async throws -> Data? {
        try Task.checkCancellation()
        let base = configuration.serverURL.hasSuffix("/") ? String(configuration.serverURL.dropLast()) : configuration.serverURL
        guard let url = URL(string: base + "/yuedu/" + name),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw WebDAVError.invalidURL
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(configuration.authorization, forHTTPHeaderField: "Authorization")
        let (data, response) = try await environment.transport(request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw WebDAVRestoreFailure.invalidData }
        AppLogger.sync("GET /yuedu/\(name) → \(http.statusCode) \(data.count)B", level: .notice)
        // Older backups legitimately omit files never created on that install,
        // including manifest.json. Only an explicit HTTP 404 means optional absence;
        // authentication/transport/decoding failures must abort before any local write.
        if http.statusCode == 404 { return nil }
        if http.statusCode == 401 { throw WebDAVError.authenticationFailed }
        guard (200...299).contains(http.statusCode) else { throw WebDAVError.connectionFailed(http.statusCode) }
        return data
    }

    private static func decode<T: Decodable>(_ type: T.Type, data: Data, component: String) throws -> T {
        try SourcePerfTrace.span("webdav.restore.decode", "component=\(component) bytes=\(data.count) main=\(Thread.isMainThread)") {
            do { return try JSONDecoder().decode(type, from: data) }
            catch {
                AppLogger.sync("WebDAV restore rejected invalid \(component)", level: .error)
                throw WebDAVRestoreFailure.invalidData
            }
        }
    }

    /// All originals are copied to owned recovery files before the first destination
    /// changes. A 50K-source old JSON is never loaded into a second in-memory Data.
    static func commit(
        _ prepared: Prepared, environment: WebDAVRestoreEnvironment,
        lease: WebDAVRestoreWriterLease,
        publish: @escaping @MainActor () throws -> Void
    ) async throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        try await SourcePerfTrace.spanAsync("webdav.restore.commit", "files=\(prepared.incoming.count) bytes=\(prepared.bytes) main=\(Thread.isMainThread)") {
            guard await lease.isCurrent() else { throw WebDAVRestoreFailure.commitFailed }
            var originals: [Original] = []
            for component in WebDAVRestoreComponent.allCases where prepared.incoming[component] != nil {
                try Task.checkCancellation()
                guard let destination = environment.destinations[component] else { throw WebDAVRestoreFailure.invalidData }
                let backup = prepared.directory.appendingPathComponent("original-" + component.rawValue)
                let attributes: [FileAttributeKey: Any]
                do {
                    attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
                } catch {
                    guard isMissing(error) else { throw error }
                    originals.append(.init(component: component, destination: destination, backup: nil))
                    continue
                }
                guard attributes[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileReadUnknown) }
                try environment.copyOriginal(destination, backup)
                originals.append(.init(component: component, destination: destination, backup: backup))
            }
            // Recovery materials outlive a failed rollback. The manifest contains paths
            // and presence, never credentials or chapter/source contents in a log/UI.
            try JSONEncoder().encode(originals).write(to: prepared.directory.appendingPathComponent("recovery.json"), options: .atomic)
            var attempted: [Original] = []
            do {
                guard await lease.isCurrent() else { throw WebDAVRestoreFailure.commitFailed }
                for original in originals {
                    try Task.checkCancellation()
                    attempted.append(original) // install may change bytes and THEN throw.
                    try environment.install(prepared.incoming[original.component]!, original.destination)
                }
                try Task.checkCancellation()
                // Check and publish together on main: an edit during the worker's
                // copies/install must reject the restore, never silently disappear.
                try await publish()
            } catch {
                var rollbackFailed = false
                for original in attempted.reversed() {
                    do {
                        if let backup = original.backup {
                            try environment.install(backup, original.destination)
                        } else {
                            do { try environment.remove(original.destination) }
                            catch { if !isMissing(error) { throw error } }
                        }
                    } catch {
                        rollbackFailed = true
                        AppLogger.sync("WebDAV restore rollback failed for \(original.component.rawValue); recovery files retained", level: .error)
                    }
                }
                if rollbackFailed { throw WebDAVRestoreFailure.rollbackFailed(recoveryDirectory: prepared.directory) }
                if error is CancellationError { throw CancellationError() }
                throw WebDAVRestoreFailure.commitFailed
            }
        }
    }

    static func installFile(_ source: URL, _ destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".webdav-\(UUID().uuidString).tmp")
        do {
            try fm.copyItem(at: source, to: temporary)
            // POSIX rename atomically replaces an existing file and also handles an
            // originally absent target, without a delete/copy gap in that one file.
            guard rename(temporary.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            cleanUp(temporary)
            throw error
        }
    }

    static func isMissing(_ error: Error) -> Bool {
        let value = error as NSError
        return (value.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(value.code))
            || (value.domain == NSPOSIXErrorDomain && value.code == Int(ENOENT))
    }

    static func cleanUp(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) }
        catch {
            if !isMissing(error) { AppLogger.sync("WebDAV restore could not remove owned temporary material", level: .error) }
        }
    }

    static func cleanUpOffMain(_ url: URL) async {
        await Task.detached(priority: .utility) { cleanUp(url) }.value
    }
}

/// Coordinates only the existing three writers while a validated restore commits.
/// This does not lock all stores/sidecar migrations or make a crash-safe journal.
@MainActor
final class WebDAVRestoreStoreBoundary {
    private let bookStore: BookStore?
    private var sourceStore: BookSourceStore?
    private var ruleStore: ReplaceRuleStore?
    private var bookRevision: UInt64?
    private var sourceRevision: Int?
    private var ruleRevision: UInt64?

    init(bookStore: BookStore?) { self.bookStore = bookStore }

    func prepare(_ payload: WebDAVRestorePayload) async throws -> WebDAVRestoreWriterLease {
        // Load before pausing any writer, awaiting the source store's real signal.
        if payload.sources != nil {
            let store = BookSourceStore.shared
            await store.waitUntilLoaded()
            sourceStore = store
        }
        if payload.rules != nil {
            // Its legacy singleton initializer reads JSON synchronously. If this is
            // first use, construct it off main; only its later publication runs here.
            ruleStore = try await WebDAVRestoreTransaction.offMain { ReplaceRuleStore.shared }
        }
        do {
            if payload.books != nil { bookRevision = try bookStore?.beginValidatedRestoreWrites() }
            sourceRevision = try sourceStore?.beginValidatedRestoreWrites()
            ruleRevision = try ruleStore?.beginValidatedRestoreWrites()
            // These are continuation barriers on the existing serial queues. No
            // queue.sync/main wait and no old pending snapshot crosses the commit.
            await BookStore.queuedWritesLanded()
            await BookSourceStore.queuedWritesLanded()
            try Task.checkCancellation()
            guard isCurrent else { throw WebDAVRestoreFailure.commitFailed }
            return .init(isCurrent: { self.isCurrent }, finish: { await self.finish() })
        } catch {
            await finish()
            throw error
        }
    }

    private var isCurrent: Bool {
        (bookRevision == nil || bookStore?.mutationRevision == bookRevision)
            && (sourceRevision == nil || sourceStore?.mutationRevision == sourceRevision)
            && (ruleRevision == nil || ruleStore?.mutationRevision == ruleRevision)
    }

    func publish(_ payload: WebDAVRestorePayload) {
        SourcePerfTrace.span("webdav.restore.publish", "books=\(payload.books?.count ?? 0) sources=\(payload.sources?.count ?? 0) rules=\(payload.rules?.count ?? 0) main=\(Thread.isMainThread)") {
            if let sources = payload.sources { sourceStore?.applyValidatedRestoreSources(sources) }
            if let books = payload.books, let data = payload.booksData {
                bookStore?.applyValidatedRestoreShelf(books, persistedData: data)
            }
            if let rules = payload.rules { ruleStore?.applyValidatedRestoreRules(rules) }
        }
    }

    private func finish() async {
        // Release only leases this boundary actually acquired (another restore
        // may own a store whose begin call rejected this one).
        if bookRevision != nil { bookStore?.finishValidatedRestoreWrites(); bookRevision = nil }
        if sourceRevision != nil { sourceStore?.finishValidatedRestoreWrites(); sourceRevision = nil }
        if ruleRevision != nil { await ruleStore?.finishValidatedRestoreWrites(); ruleRevision = nil }
    }
}
