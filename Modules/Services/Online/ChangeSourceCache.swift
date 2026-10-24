import CryptoKit
import Foundation

/// Persists 換源 (in-book source switch) search results per book so reopening the
/// sheet doesn't re-run a full cross-source search every time. Honors
/// 網路設定 →「搜索結果快取天數」(`GlobalSettings.searchCacheDays`): `<= 0` disables
/// the cache, otherwise results within that window are reused.
///
/// Also remembers which origins failed to switch (TOC fetch threw) so the list
/// can flag them — failure flags survive a re-search of the same book.
final class ChangeSourceCache: @unchecked Sendable {
    static let shared = ChangeSourceCache()
    // Versions admission policy plus configuration-bound resumable progress,
    // independently of application build numbers. Older records are rescanned.
    static let searchCompatibilityVersion = 2

    /// A digest of the actual ordered configuration, never a replacement for the
    /// original preview's own identity/revision checks. Built off the main actor.
    struct SearchContext: Codable, Equatable, Sendable {
        let digest: String

        static func make(title: String, author: String, sources: [BookSource],
            excludingOriginKey: String) throws -> SearchContext {
            let started = SourcePerfTrace.now
            defer { SourcePerfTrace.record("changeSource.context", "sources=\(sources.count) main=\(Thread.isMainThread)", since: started) }
            struct SourceIdentity: Encodable {
                let id: UUID
                let configuration: String
                let searchScope: String?
            }
            struct Identity: Encodable {
                let title: String
                let author: String
                let excludedOrigin: String
                let sources: [SourceIdentity]
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var identities: [SourceIdentity] = []
            for source in sources {
                try Task.checkCancellation()
                var stable = source
                // Match originalSignature: UUID is bound separately; the sync
                // clock and observed response time do not change source rules.
                stable.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
                stable.lastUpdateTime = 0
                stable.respondTime = 180000
                let variables = BookSourceRuntimeStateStore.shared.sourceVariables(for: source.bookSourceUrl)
                var scope: String?
                // The same user-controlled search-scope bucket used by the
                // general search cache; volatile runtime tokens are not keys.
                if let settings = variables["更多设置"] as? [String: Any], !settings.isEmpty {
                    scope = Self.hash(try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]))
                }
                identities.append(SourceIdentity(id: source.id,
                    configuration: Self.hash(try encoder.encode(stable)), searchScope: scope))
            }
            return SearchContext(digest: Self.hash(try encoder.encode(Identity(title: title, author: author,
                excludedOrigin: excludingOriginKey, sources: identities))))
        }

        private static func hash(_ bytes: Data) -> String {
            SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
    }

    struct Entry: Codable, Sendable {
        var origins: [BookOrigin]
        var failedKeys: [String]
        var timestamp: Date
        // Missing in older entries, which may contain an automatically paused scan.
        var completedAttemptSourceIDs: Set<UUID>? = nil
        var excludedOriginKey: String? = nil
        var scanCoverage: BookOriginSearchCoverage? = nil
        var searchCompatibilityVersion: Int? = nil
        var context: SearchContext? = nil
        var acceptedAttempts: [UUID: BookOriginSearchAttempt.Outcome]? = nil
    }

    private let queue = DispatchQueue(label: "com.yuedu.changeSourceCache")
    private let directory: URL
#if DEBUG
    private var completedStoreEnqueuedForTesting: (@Sendable () -> Void)?
    private var partialStoreEnqueuedForTesting: (@Sendable () -> Void)?

    convenience init(directory: URL, completedStoreEnqueuedForTesting: @escaping @Sendable () -> Void) {
        self.init(directory: directory)
        self.completedStoreEnqueuedForTesting = completedStoreEnqueuedForTesting
    }

    convenience init(directory: URL, partialStoreEnqueuedForTesting: @escaping @Sendable () -> Void) {
        self.init(directory: directory)
        self.partialStoreEnqueuedForTesting = partialStoreEnqueuedForTesting
    }

    func enqueueWorkForTesting(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }
#endif

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChangeSourceCache", isDirectory: true)
    }

    private func fileURL(for bookId: UUID) -> URL {
        directory.appendingPathComponent("\(bookId.uuidString).json")
    }

    /// Raw cached entry (results + failure flags), regardless of freshness.
    func entry(for bookId: UUID) -> Entry? {
        queue.sync { readEntry(for: bookId) }
    }

    /// Cached entry only if it exists and is within `days` (days <= 0 = disabled).
    func freshEntry(for bookId: UUID, days: Int) -> Entry? {
        guard days > 0, let entry = entry(for: bookId), !entry.origins.isEmpty else { return nil }
        let maxAge = TimeInterval(days) * 86_400
        guard Date().timeIntervalSince(entry.timestamp) < maxAge else { return nil }
        return entry
    }

    /// Replace the cached origin list, preserving any still-relevant failure flags.
    func store(origins: [BookOrigin], for bookId: UUID) {
        queue.sync { storeEntry(origins: origins, for: bookId, sourceIDs: nil, excludingOriginKey: nil, coverage: nil) }
    }

    struct SearchSnapshot: Sendable {
        /// Complete-cache compatibility for existing callers. Partial display
        /// data is separate and can never take the complete early-return path.
        let origins: [BookOrigin]?
        let failedKeys: Set<String>
        let displayOrigins: [BookOrigin]
        let acceptedAttempts: [UUID: BookOriginSearchAttempt.Outcome]
        let canEndSearch: Bool
        let timestamp: Date?
    }

    /// Reader searches perform disk/decode/coverage work on the cache queue. A
    /// legacy or partial entry can supply failure markers but cannot end a scan.
    func readForSearch(for bookId: UUID, days: Int, sourceIDs: Set<UUID>,
        excludingOriginKey: String, allowCached: Bool, context: SearchContext? = nil,
        now: Date? = nil) async -> SearchSnapshot {
        await withCheckedContinuation { continuation in
            queue.async {
                let entry = self.readEntry(for: bookId)
                let identityMatches = allowCached && days > 0 && entry?.context == context
                    && entry?.searchCompatibilityVersion == Self.searchCompatibilityVersion
                    && entry?.excludedOriginKey == excludingOriginKey
                let attempts = entry?.acceptedAttempts ?? [:]
                let progressValid = Set(attempts.keys).isSubset(of: sourceIDs)
                    && entry?.origins.allSatisfy({ attempts[$0.sourceId] == .results }) == true
                    && entry.map { Self.matchesCoverage($0.scanCoverage, sourceCount: sourceIDs.count, attempts: attempts) } == true
                let observedNow = now ?? Date()
                let age = entry.map { observedNow.timeIntervalSince($0.timestamp) }
                let fresh = age.map { $0 >= 0 && $0 < TimeInterval(days) * 86_400 } == true
                let complete = identityMatches && fresh && entry?.completedAttemptSourceIDs == sourceIDs
                    && entry?.scanCoverage?.completedAllAttempts == true
                    && entry?.scanCoverage?.sourceCount == sourceIDs.count
                    && entry?.scanCoverage?.attemptedSourceCount == sourceIDs.count
                    && !(entry?.origins.isEmpty ?? true)
                    && (context == nil || (progressValid && Set(attempts.keys) == sourceIDs))
                let partial = identityMatches && context != nil && progressValid && !attempts.isEmpty
                    && entry?.scanCoverage?.completedAllAttempts == false
                    && age.map { $0 >= 0 && $0 < min(TimeInterval(days) * 86_400, 300) } == true
                let usable = complete || partial
                continuation.resume(returning: SearchSnapshot(origins: complete ? entry?.origins : nil,
                    failedKeys: Set(entry?.failedKeys ?? []), displayOrigins: usable ? entry?.origins ?? [] : [],
                    acceptedAttempts: usable ? attempts : [:], canEndSearch: complete,
                    timestamp: usable ? entry?.timestamp : nil))
            }
        }
    }

    /// Called only after every enabled source was attempted in this generation.
    func storeCompleted(origins: [BookOrigin], for bookId: UUID, sourceIDs: Set<UUID>,
        excludingOriginKey: String, coverage: BookOriginSearchCoverage, context: SearchContext? = nil,
        acceptedAttempts: [UUID: BookOriginSearchAttempt.Outcome]? = nil) async {
        guard !Task.isCancelled, coverage.completedAllAttempts, coverage.sourceCount == sourceIDs.count,
              coverage.attemptedSourceCount == sourceIDs.count else { return }
        if context != nil {
            guard let acceptedAttempts, Set(acceptedAttempts.keys) == sourceIDs,
                  Self.matchesCoverage(coverage, sourceCount: sourceIDs.count, attempts: acceptedAttempts),
                  origins.allSatisfy({ acceptedAttempts[$0.sourceId] == .results }) else { return }
        }
        let cancellation = PendingStoreCancellation()
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                queue.async {
                    // After this check the serial queue owns the write. Any new
                    // generation's queued write necessarily follows this one.
                    if !cancellation.isCancelled {
                        self.storeEntry(origins: origins, for: bookId, sourceIDs: sourceIDs,
                            excludingOriginKey: excludingOriginKey, coverage: coverage, context: context,
                            acceptedAttempts: acceptedAttempts)
                    }
                    continuation.resume()
                }
#if DEBUG
                self.completedStoreEnqueuedForTesting?()
#endif
            }
        }, onCancel: { cancellation.cancel() })
    }

    /// The closing reader owns this short checkpoint task. It is independent of
    /// the cancelled network task, and the next opening awaits this queue write.
    func storePartial(origins: [BookOrigin], for bookId: UUID, sourceIDs: Set<UUID>,
        excludingOriginKey: String, context: SearchContext,
        acceptedAttempts: [UUID: BookOriginSearchAttempt.Outcome], timestamp: Date) async {
        guard !Task.isCancelled, !acceptedAttempts.isEmpty,
              Set(acceptedAttempts.keys).isSubset(of: sourceIDs),
              origins.allSatisfy({ acceptedAttempts[$0.sourceId] == .results }) else { return }
        let coverage = Self.coverage(sourceIDs: sourceIDs, attempts: acceptedAttempts, completed: false)
        let cancellation = PendingStoreCancellation()
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                queue.async {
                    guard !cancellation.isCancelled else { continuation.resume(); return }
                    // Checkpoints from separate reader instances share this
                    // queue too. An older snapshot must not replace newer
                    // partial progress or a newer complete, even across contexts.
                    if let current = self.readEntry(for: bookId), Self.hasConsistentProgress(current),
                       current.timestamp <= Date(),
                       current.timestamp >= timestamp,
                       current.timestamp > timestamp || current.scanCoverage?.completedAllAttempts == true
                        || (current.acceptedAttempts?.count ?? 0) >= acceptedAttempts.count {
                        continuation.resume()
                        return
                    }
                    self.storeEntry(origins: origins, for: bookId, sourceIDs: nil,
                        excludingOriginKey: excludingOriginKey, coverage: coverage, context: context,
                        acceptedAttempts: acceptedAttempts, timestamp: timestamp)
                    continuation.resume()
                }
#if DEBUG
                self.partialStoreEnqueuedForTesting?()
#endif
            }
        }, onCancel: { cancellation.cancel() })
    }

    static func coverage(sourceIDs: Set<UUID>, attempts: [UUID: BookOriginSearchAttempt.Outcome],
        completed: Bool) -> BookOriginSearchCoverage {
        coverage(sourceCount: sourceIDs.count, attempts: attempts, completed: completed)
    }

    private static func coverage(sourceCount: Int, attempts: [UUID: BookOriginSearchAttempt.Outcome],
        completed: Bool) -> BookOriginSearchCoverage {
        var result = BookOriginSearchCoverage(sourceCount: sourceCount,
            completedAllAttempts: completed, attemptedSourceCount: attempts.count)
        for outcome in attempts.values {
            switch outcome {
            case .results: result.resultSourceCount += 1
            case .empty: result.emptySourceCount += 1
            case .failed: result.failedSourceCount += 1
            case .timedOut: result.timedOutSourceCount += 1
            }
        }
        return result
    }

    private static func matchesCoverage(_ coverage: BookOriginSearchCoverage?, sourceCount: Int,
        attempts: [UUID: BookOriginSearchAttempt.Outcome]) -> Bool {
        guard let coverage else { return false }
        let expected = Self.coverage(sourceCount: sourceCount, attempts: attempts, completed: coverage.completedAllAttempts)
        return coverage.sourceCount == expected.sourceCount && coverage.attemptedSourceCount == expected.attemptedSourceCount
            && coverage.resultSourceCount == expected.resultSourceCount && coverage.emptySourceCount == expected.emptySourceCount
            && coverage.failedSourceCount == expected.failedSourceCount && coverage.timedOutSourceCount == expected.timedOutSourceCount
            && coverage.cancelledSourceCount == 0
    }

    private static func hasConsistentProgress(_ entry: Entry) -> Bool {
        guard entry.searchCompatibilityVersion == Self.searchCompatibilityVersion, entry.context != nil,
              let attempts = entry.acceptedAttempts, !attempts.isEmpty, let coverage = entry.scanCoverage,
              coverage.sourceCount >= attempts.count,
              matchesCoverage(coverage, sourceCount: coverage.sourceCount, attempts: attempts),
              entry.origins.allSatisfy({ attempts[$0.sourceId] == .results }) else { return false }
        return !coverage.completedAllAttempts || (coverage.sourceCount == attempts.count
            && entry.completedAttemptSourceIDs == Set(attempts.keys))
    }

    private final class PendingStoreCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
        }
    }

    /// Flag a source-qualified origin key as having failed to switch.
    func markFailed(originKey: String, for bookId: UUID) {
        guard !originKey.isEmpty else { return }
        queue.async {
            var entry = self.readEntry(for: bookId)
                ?? Entry(origins: [], failedKeys: [], timestamp: Date())
            guard !entry.failedKeys.contains(originKey) else { return }
            entry.failedKeys.append(originKey)
            self.writeEntry(entry, for: bookId)
        }
    }

    /// Clear a failure flag after that origin switched successfully. Without this a source
    /// that failed once stayed badged 載入失敗 forever, including in every later session,
    /// because `markFailed` only ever appended.
    func clearFailure(originKeys: [String], for bookId: UUID) {
        queue.async {
            let keys = Set(originKeys.filter { !$0.isEmpty })
            guard !keys.isEmpty, var entry = self.readEntry(for: bookId) else { return }
            let remaining = entry.failedKeys.filter { !keys.contains($0) }
            guard remaining.count != entry.failedKeys.count else { return }
            entry.failedKeys = remaining
            self.writeEntry(entry, for: bookId)
        }
    }

    func clear(for bookId: UUID) {
        queue.sync {
            do { try FileManager.default.removeItem(at: fileURL(for: bookId)) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { }
            catch { AppLogger.parse("ChangeSource cache clear failed type=\(String(reflecting: type(of: error)))") }
        }
    }

    private func readEntry(for bookId: UUID) -> Entry? {
        let started = SourcePerfTrace.now
        var bytes = 0
        defer { SourcePerfTrace.record("changeSource.cache.read", "bytes=\(bytes) main=\(Thread.isMainThread)", since: started) }
        do {
            let data = try Data(contentsOf: fileURL(for: bookId)); bytes = data.count
            return try JSONDecoder().decode(Entry.self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        catch {
            AppLogger.parse("ChangeSource cache read failed type=\(String(reflecting: type(of: error)))")
            return nil
        }
    }

    private func storeEntry(origins: [BookOrigin], for bookId: UUID, sourceIDs: Set<UUID>?, excludingOriginKey: String?,
        coverage: BookOriginSearchCoverage?, context: SearchContext? = nil,
        acceptedAttempts: [UUID: BookOriginSearchAttempt.Outcome]? = nil, timestamp: Date = Date()) {
        let previousFailed = readEntry(for: bookId)?.failedKeys ?? []
        let validKeys = Set(origins.flatMap { origin in
            [Self.originKey(sourceId: origin.sourceId, bookUrl: origin.bookUrl), Self.urlKey(origin.bookUrl)]
        })
        let entry = Entry(origins: origins, failedKeys: previousFailed.filter { validKeys.contains($0) },
            timestamp: timestamp, completedAttemptSourceIDs: sourceIDs, excludedOriginKey: excludingOriginKey, scanCoverage: coverage,
            searchCompatibilityVersion: coverage == nil ? nil : Self.searchCompatibilityVersion,
            context: context, acceptedAttempts: acceptedAttempts)
        writeEntry(entry, for: bookId)
    }

    private func writeEntry(_ entry: Entry, for bookId: UUID) {
        let started = SourcePerfTrace.now
        defer { SourcePerfTrace.record("changeSource.cache.write", "origins=\(entry.origins.count) main=\(Thread.isMainThread)", since: started) }
        do {
            let data = try JSONEncoder().encode(entry)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL(for: bookId), options: .atomic)
        } catch { AppLogger.parse("ChangeSource cache write failed type=\(String(reflecting: type(of: error)))") }
    }

    /// Normalized book-URL key for matching origins (drops fragment, lowercased).
    /// Kept identical to `ReaderViewModel`'s dedup key so failure flags line up.
    static func urlKey(_ raw: String?) -> String {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return "" }
        if var components = URLComponents(string: trimmed) {
            components.fragment = nil
            return (components.string ?? trimmed).lowercased()
        }
        return trimmed.lowercased()
    }

    /// Source-qualified origin identity. Two sources may intentionally return
    /// the same detail URL, so URL-only keys would merge their failure state and
    /// hide one of the switchable origins.
    static func originKey(sourceId: UUID, bookUrl: String?) -> String {
        let url = urlKey(bookUrl)
        let sourceKey = sourceId.uuidString.lowercased()
        guard !url.isEmpty else { return sourceKey + "|" }
        return sourceKey + "|" + url
    }
}
