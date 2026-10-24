import Foundation
import Testing
@testable import yuedu_app

@Suite("Reader source cache coverage", .serialized)
struct ChangeSourceCacheCoverageTests {
    @Test("legacy and incomplete scans retain failure flags but cannot replace a complete search")
    func legacyAndPartialEntriesDoNotEndSearch() async throws {
        let directory = temporaryDirectory()
        defer { remove(directory) }
        let cache = ChangeSourceCache(directory: directory)
        let bookId = UUID(), sourceId = UUID(), anotherId = UUID()
        let origin = makeOrigin(sourceId)
        let key = ChangeSourceCache.originKey(sourceId: sourceId, bookUrl: origin.bookUrl)
        cache.store(origins: [origin], for: bookId)
        cache.markFailed(originKey: key, for: bookId)
        let legacy = await cache.readForSearch(for: bookId, days: 5, sourceIDs: [sourceId],
            excludingOriginKey: "current", allowCached: true)
        #expect(legacy.origins == nil)
        #expect(legacy.failedKeys == [key])
        await cache.storeCompleted(origins: [origin], for: bookId, sourceIDs: [sourceId, anotherId],
            excludingOriginKey: "current", coverage: BookOriginSearchCoverage(sourceCount: 2, attemptedSourceCount: 1, resultSourceCount: 1))
        let partial = await cache.readForSearch(for: bookId, days: 5, sourceIDs: [sourceId, anotherId],
            excludingOriginKey: "current", allowCached: true)
        #expect(partial.origins == nil)
        #expect(partial.failedKeys == [key])
        #expect(cache.entry(for: bookId)?.completedAttemptSourceIDs == nil)
    }

    @Test("full attempt coverage keeps failures separate and invalidates for source set or current origin changes")
    func completeAttemptCoverageIsBoundToSourceSet() async throws {
        let directory = temporaryDirectory()
        defer { remove(directory) }
        let cache = ChangeSourceCache(directory: directory)
        let bookId = UUID(), sourceId = UUID(), failedId = UUID()
        let origin = makeOrigin(sourceId)
        let coverage = BookOriginSearchCoverage(sourceCount: 2, completedAllAttempts: true,
            attemptedSourceCount: 2, resultSourceCount: 1, failedSourceCount: 1)
        await cache.storeCompleted(origins: [origin], for: bookId, sourceIDs: [sourceId, failedId],
            excludingOriginKey: "current", coverage: coverage)
        let complete = await cache.readForSearch(for: bookId, days: 5, sourceIDs: [failedId, sourceId],
            excludingOriginKey: "current", allowCached: true)
        #expect(complete.origins?.map(\.sourceId) == [sourceId])
        #expect(cache.entry(for: bookId)?.scanCoverage?.failedSourceCount == 1)
        let changed = await cache.readForSearch(for: bookId, days: 5, sourceIDs: [sourceId],
            excludingOriginKey: "current", allowCached: true)
        #expect(changed.origins == nil)
        let switched = await cache.readForSearch(for: bookId, days: 5, sourceIDs: [sourceId, failedId],
            excludingOriginKey: "different-current", allowCached: true)
        #expect(switched.origins == nil)
        let disabled = await cache.readForSearch(for: bookId, days: 0, sourceIDs: [sourceId, failedId],
            excludingOriginKey: "current", allowCached: true)
        #expect(disabled.origins == nil)
        let refreshed = await cache.readForSearch(for: bookId, days: 5, sourceIDs: [sourceId, failedId],
            excludingOriginKey: "current", allowCached: false)
        #expect(refreshed.origins == nil)
        let key = ChangeSourceCache.originKey(sourceId: sourceId, bookUrl: origin.bookUrl)
        cache.markFailed(originKey: key, for: bookId)
        cache.clearFailure(originKeys: [key], for: bookId)
        let cleared = await cache.readForSearch(for: bookId, days: 5, sourceIDs: [sourceId, failedId],
            excludingOriginKey: "current", allowCached: true)
        #expect(cleared.failedKeys.isEmpty)
        #expect(cleared.origins?.count == 1)
    }

    @Test("a complete cache still expires using the configured day window")
    func completeEntryExpires() async throws {
        let directory = temporaryDirectory()
        defer { remove(directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cache = ChangeSourceCache(directory: directory)
        let bookId = UUID(), sourceId = UUID()
        let entry = ChangeSourceCache.Entry(origins: [makeOrigin(sourceId)], failedKeys: [],
            timestamp: Date().addingTimeInterval(-6 * 86_400), completedAttemptSourceIDs: [sourceId],
            excludedOriginKey: "current", scanCoverage: BookOriginSearchCoverage(sourceCount: 1,
                completedAllAttempts: true, attemptedSourceCount: 1, resultSourceCount: 1),
            searchCompatibilityVersion: ChangeSourceCache.searchCompatibilityVersion)
        try JSONEncoder().encode(entry).write(to: directory.appendingPathComponent("\(bookId.uuidString).json"))
        let expired = await cache.readForSearch(for: bookId, days: 5, sourceIDs: [sourceId],
            excludingOriginKey: "current", allowCached: true)
        #expect(expired.origins == nil)
    }

    @Test("a complete result from an incompatible admission policy is rescanned without losing failure markers")
    func incompatibleCompletedEntryDoesNotEndSearch() async throws {
        let directory = temporaryDirectory()
        defer { remove(directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cache = ChangeSourceCache(directory: directory)
        let bookId = UUID(), sourceId = UUID(), failedId = UUID()
        let origin = makeOrigin(sourceId)
        let key = ChangeSourceCache.originKey(sourceId: sourceId, bookUrl: origin.bookUrl)
        let coverage = BookOriginSearchCoverage(sourceCount: 2, completedAllAttempts: true,
            attemptedSourceCount: 2, resultSourceCount: 1, failedSourceCount: 1)
        let incompatibleVersions: [Int?] = [nil, 0, 1, ChangeSourceCache.searchCompatibilityVersion + 1]
        for version in incompatibleVersions {
            let entry = ChangeSourceCache.Entry(origins: [origin], failedKeys: [key], timestamp: Date(),
                completedAttemptSourceIDs: [sourceId, failedId], excludedOriginKey: "current", scanCoverage: coverage,
                searchCompatibilityVersion: version)
            try JSONEncoder().encode(entry).write(to: directory.appendingPathComponent("\(bookId.uuidString).json"))
            let snapshot = await cache.readForSearch(for: bookId, days: 5, sourceIDs: [sourceId, failedId],
                excludingOriginKey: "current", allowCached: true)
            #expect(snapshot.origins == nil)
            #expect(snapshot.failedKeys == [key])
        }
        await cache.storeCompleted(origins: [origin], for: bookId, sourceIDs: [sourceId, failedId],
            excludingOriginKey: "current", coverage: coverage)
        let current = await cache.readForSearch(for: bookId, days: 5, sourceIDs: [sourceId, failedId],
            excludingOriginKey: "current", allowCached: true)
        #expect(current.origins?.map(\.sourceId) == [sourceId])
        #expect(current.failedKeys == [key])
        #expect(cache.entry(for: bookId)?.searchCompatibilityVersion == ChangeSourceCache.searchCompatibilityVersion)
    }

    @Test("cancelling a completed scan while its cache write is queued drops the stale write")
    func cancelledQueuedCompletedStoreDoesNotWrite() async throws {
        let directory = temporaryDirectory()
        defer { remove(directory) }
        let enqueued = CacheStoreEnqueuedSignal()
        let cache = ChangeSourceCache(directory: directory,
            completedStoreEnqueuedForTesting: { Task { await enqueued.signal() } })
        let releaseQueue = DispatchSemaphore(value: 0)
        defer { releaseQueue.signal() }
        // Only the cache's background queue waits. The test awaits an explicit
        // enqueue ACK before cancellation, so no timing delay chooses the race.
        cache.enqueueWorkForTesting { releaseQueue.wait() }
        let bookId = UUID(), oldSourceId = UUID(), newSourceId = UUID()
        let coverage = BookOriginSearchCoverage(sourceCount: 1, completedAllAttempts: true,
            attemptedSourceCount: 1, resultSourceCount: 1)
        let oldOrigin = makeOrigin(oldSourceId)
        let oldStore = Task {
            await cache.storeCompleted(origins: [oldOrigin], for: bookId, sourceIDs: [oldSourceId],
                excludingOriginKey: "current", coverage: coverage)
        }
        await enqueued.wait()
        oldStore.cancel()
        releaseQueue.signal()
        await oldStore.value
        #expect(cache.entry(for: bookId) == nil)
        await cache.storeCompleted(origins: [makeOrigin(newSourceId)], for: bookId, sourceIDs: [newSourceId],
            excludingOriginKey: "current", coverage: coverage)
        #expect(cache.entry(for: bookId)?.completedAttemptSourceIDs == [newSourceId])

        let partialEnqueued = CacheStoreEnqueuedSignal()
        let partialCache = ChangeSourceCache(directory: directory,
            partialStoreEnqueuedForTesting: { Task { await partialEnqueued.signal() } })
        let partialRelease = DispatchSemaphore(value: 0)
        defer { partialRelease.signal() }
        partialCache.enqueueWorkForTesting { partialRelease.wait() }
        let partial = Task {
            await partialCache.storePartial(origins: [makeOrigin(oldSourceId)], for: bookId,
                sourceIDs: [oldSourceId, newSourceId], excludingOriginKey: "current",
                context: ChangeSourceCache.SearchContext(digest: "owned-cancelled-partial"),
                acceptedAttempts: [oldSourceId: .results], timestamp: Date())
        }
        await partialEnqueued.wait()
        partial.cancel()
        partialRelease.signal()
        await partial.value
        #expect(partialCache.entry(for: bookId)?.completedAttemptSourceIDs == [newSourceId])
    }

    @Test("partial scans display unchanged origins and real terminal progress for at most five minutes")
    func partialSnapshotPreservesProgressAndExpiresWithoutSlidingTime() async throws {
        let directory = temporaryDirectory()
        defer { remove(directory) }
        let cache = ChangeSourceCache(directory: directory)
        let bookId = UUID(), ids = (0..<5).map { _ in UUID() }
        let context = ChangeSourceCache.SearchContext(digest: "owned-partial-context")
        let origin = BookOrigin(sourceId: ids[0], sourceName: "owned", bookUrl: "https://owned.invalid/book",
            tocUrl: "https://owned.invalid/toc", coverUrl: "", intro: "", lastChapter: "", wordCount: "", kind: "",
            runtimeVariables: ["owned-immutable-reference": "unchanged synthetic bytes"])
        let attempts: [UUID: BookOriginSearchAttempt.Outcome] = [ids[0]: .results, ids[1]: .empty,
            ids[2]: .failed, ids[3]: .timedOut]
        let sourceIDs = Set(ids), timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        await cache.storePartial(origins: [origin], for: bookId, sourceIDs: sourceIDs,
            excludingOriginKey: "current", context: context, acceptedAttempts: attempts, timestamp: timestamp)
        let recent = await cache.readForSearch(for: bookId, days: 5, sourceIDs: sourceIDs,
            excludingOriginKey: "current", allowCached: true, context: context, now: timestamp.addingTimeInterval(299))
        #expect(recent.origins == nil)
        #expect(!recent.canEndSearch)
        #expect(recent.displayOrigins.map(\.bookUrl) == [origin.bookUrl])
        #expect(recent.displayOrigins.first?.runtimeVariables == origin.runtimeVariables)
        #expect(recent.acceptedAttempts == attempts)
        #expect(recent.timestamp == timestamp)
        #expect(cache.entry(for: bookId)?.completedAttemptSourceIDs == nil)
        let changed = await cache.readForSearch(for: bookId, days: 5, sourceIDs: sourceIDs,
            excludingOriginKey: "current", allowCached: true,
            context: ChangeSourceCache.SearchContext(digest: "different-configuration"), now: timestamp)
        #expect(changed.displayOrigins.isEmpty)
        #expect(changed.acceptedAttempts.isEmpty)
        // Saving another close keeps the actual scan time; it cannot extend TTL.
        await cache.storePartial(origins: recent.displayOrigins, for: bookId, sourceIDs: sourceIDs,
            excludingOriginKey: "current", context: context, acceptedAttempts: recent.acceptedAttempts,
            timestamp: try #require(recent.timestamp))
        for (days, allowed, now) in [(5, true, timestamp.addingTimeInterval(300)),
                                     (0, true, timestamp.addingTimeInterval(1)),
                                     (5, false, timestamp.addingTimeInterval(1)),
                                     (5, true, timestamp.addingTimeInterval(-1))] {
            let rejected = await cache.readForSearch(for: bookId, days: days, sourceIDs: sourceIDs,
                excludingOriginKey: "current", allowCached: allowed, context: context, now: now)
            #expect(rejected.displayOrigins.isEmpty)
            #expect(rejected.acceptedAttempts.isEmpty)
            #expect(!rejected.canEndSearch)
        }
        #expect(cache.entry(for: bookId)?.timestamp == timestamp)
    }

    @Test("source-change identity binds rules, order, UUID, query and search scope but ignores operational clocks")
    func contextBindsConfigurationAndScopeWithoutOperationalChurn() async throws {
        var first = BookSource(bookSourceUrl: "https://context-first-\(UUID()).invalid", bookSourceName: "owned")
        first.searchUrl = "/search?key={{key}}"
        let second = BookSource(bookSourceUrl: "https://context-second-\(UUID()).invalid", bookSourceName: "owned")
        let original = try await context([first, second])
        var observed = first
        observed.respondTime = 9
        observed.lastUpdateTime = 99
        #expect(try await context([observed, second]) == original)
        var changed = first
        changed.ruleToc.chapterList = ".changed-toc"
        #expect(try await context([changed, second]) != original)
        changed = first; changed.header = "{\"X-Owned\":\"changed\"}"
        #expect(try await context([changed, second]) != original)
        changed = first; changed.id = UUID()
        #expect(try await context([changed, second]) != original)
        #expect(try await context([second, first]) != original)
        #expect(try await context([first, second], title: "other") != original)
        #expect(try await context([first, second], author: "other") != original)
        #expect(try await context([first, second], excluded: "other") != original)
        let state = BookSourceRuntimeStateStore.shared
        defer { state.setSourceVariableJSON(nil, for: first.bookSourceUrl) }
        state.setSourceVariableJSON("{\"更多设置\":{\"搜索模式\":\"owned-new-scope\"}}", for: first.bookSourceUrl)
        #expect(try await context([first, second]) != original)
    }

    @Test("malformed progress cannot authorize reuse and an older close cannot downgrade a newer complete record")
    func rejectsInconsistentProgressAndPreservesNewerCompleteRecord() async throws {
        let directory = temporaryDirectory()
        defer { remove(directory) }
        let cache = ChangeSourceCache(directory: directory)
        let bookId = UUID(), first = UUID(), second = UUID()
        let sourceIDs: Set<UUID> = [first, second]
        let context = ChangeSourceCache.SearchContext(digest: "owned-consistency-context")
        let origin = makeOrigin(first)
        let attempts: [UUID: BookOriginSearchAttempt.Outcome] = [first: .results, second: .failed]
        let coverage = ChangeSourceCache.coverage(sourceIDs: sourceIDs, attempts: attempts, completed: true)
        await cache.storeCompleted(origins: [origin], for: bookId, sourceIDs: sourceIDs,
            excludingOriginKey: "current", coverage: coverage, context: context, acceptedAttempts: attempts)
        let completeTime = try #require(cache.entry(for: bookId)?.timestamp)
        await cache.storePartial(origins: [origin], for: bookId, sourceIDs: sourceIDs,
            excludingOriginKey: "current", context: context, acceptedAttempts: [first: .results],
            timestamp: completeTime.addingTimeInterval(-1))
        let complete = await cache.readForSearch(for: bookId, days: 5, sourceIDs: sourceIDs,
            excludingOriginKey: "current", allowCached: true, context: context, now: completeTime)
        #expect(complete.canEndSearch)
        #expect(complete.acceptedAttempts == attempts)
        #expect(cache.entry(for: bookId)?.timestamp == completeTime)
        var malformed = try #require(cache.entry(for: bookId))
        malformed.scanCoverage?.completedAllAttempts = false
        malformed.acceptedAttempts = [first: .empty, second: .failed]
        try JSONEncoder().encode(malformed).write(to: directory.appendingPathComponent("\(bookId.uuidString).json"))
        let rejected = await cache.readForSearch(for: bookId, days: 5, sourceIDs: sourceIDs,
            excludingOriginKey: "current", allowCached: true, context: context, now: completeTime)
        #expect(rejected.displayOrigins.isEmpty)
        #expect(rejected.acceptedAttempts.isEmpty)
        #expect(!rejected.canEndSearch)

        // A late closing work can come from another reader instance, outside
        // this view model's checkpoint chain. Both partial and different-context
        // complete records must survive an older queued snapshot.
        let latestContext = ChangeSourceCache.SearchContext(digest: "owned-newer-context")
        let latestTime = Date().addingTimeInterval(-1)
        await cache.storePartial(origins: [origin], for: bookId, sourceIDs: sourceIDs,
            excludingOriginKey: "current", context: latestContext,
            acceptedAttempts: attempts, timestamp: latestTime)
        await cache.storePartial(origins: [origin], for: bookId, sourceIDs: sourceIDs,
            excludingOriginKey: "current", context: context,
            acceptedAttempts: [first: .results], timestamp: latestTime.addingTimeInterval(-1))
        #expect(cache.entry(for: bookId)?.context == latestContext)
        #expect(cache.entry(for: bookId)?.acceptedAttempts == attempts)
        await cache.storeCompleted(origins: [origin], for: bookId, sourceIDs: sourceIDs,
            excludingOriginKey: "current", coverage: coverage, context: latestContext, acceptedAttempts: attempts)
        await cache.storePartial(origins: [origin], for: bookId, sourceIDs: sourceIDs,
            excludingOriginKey: "current", context: context,
            acceptedAttempts: [first: .results], timestamp: latestTime)
        #expect(cache.entry(for: bookId)?.context == latestContext)
        #expect(cache.entry(for: bookId)?.scanCoverage?.completedAllAttempts == true)
    }

    private func context(_ sources: [BookSource], title: String = "owned", author: String = "author",
        excluded: String = "current") async throws -> ChangeSourceCache.SearchContext {
        try await Task.detached {
            try ChangeSourceCache.SearchContext.make(title: title, author: author,
                sources: sources, excludingOriginKey: excluded)
        }.value
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ChangeSourceCoverage-\(UUID())", isDirectory: true)
    }
    private func remove(_ directory: URL) {
        do { try FileManager.default.removeItem(at: directory) }
        catch { Issue.record(error) }
    }
    private func makeOrigin(_ sourceId: UUID) -> BookOrigin {
        BookOrigin(sourceId: sourceId, sourceName: "Owned source", bookUrl: "https://example.invalid/book",
            tocUrl: "https://example.invalid/toc", coverUrl: "", intro: "", lastChapter: "", wordCount: "", kind: "", runtimeVariables: nil)
    }
}

private actor CacheStoreEnqueuedSignal {
    private var signalled = false
    private var waiter: CheckedContinuation<Void, Never>?
    func signal() {
        signalled = true
        waiter?.resume(); waiter = nil
    }
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiter = $0 }
    }
}
