import Foundation
import Testing
@testable import yuedu_app

/// Owned files and an injected transport only. These checks prove process-local
/// rollback and publication ordering, not crash/power-loss atomicity or WebDAV interoperability.
@Suite("WebDAV restore integrity", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct WebDAVRestoreIntegrityTests {
    @Test("every malformed existing component aborts before local writes", arguments: ["manifest.json", "book_sources.json", "books.json", "replace_rules.json"])
    func malformedBackupDoesNotWrite(name: String) async throws {
        let fixture = try await RestoreFixture.make()
        fixture.transport.set(name, data: Data("{broken".utf8))
        let manager = fixture.manager()
        let error = await caughtRestore(manager)
        #expect(error is WebDAVRestoreFailure)
        await fixture.expectUnchanged(manager)
        await fixture.cleanUp()
    }

    @Test("only HTTP 404 is optional absence", arguments: [401, 403, 500, -1009])
    func transportErrorsAreNotMissingFiles(code: Int) async throws {
        let fixture = try await RestoreFixture.make()
        fixture.transport.set("books.json", status: code)
        let manager = fixture.manager()
        #expect(await caughtRestore(manager) != nil)
        await fixture.expectUnchanged(manager)
        #expect(fixture.transport.requests.filter { $0.url?.lastPathComponent == "books.json" }.count == 1)
        await fixture.cleanUp()
    }

    @Test("manifest alone and an empty remote directory are not a restore", arguments: [false, true])
    func missingAllDataFails(hasManifest: Bool) async throws {
        let fixture = try await RestoreFixture.make()
        for component in WebDAVRestoreComponent.allCases { fixture.transport.set(component.rawValue, status: 404) }
        if !hasManifest { fixture.transport.set("manifest.json", status: 404) }
        let manager = fixture.manager()
        #expect(await caughtRestore(manager) != nil)
        await fixture.expectUnchanged(manager)
        await fixture.cleanUp()
    }

    @Test("legacy partial backups skip only explicitly absent components", arguments: WebDAVRestoreComponent.allCases)
    func legacyPartialBackupRestoresPresentFile(component: WebDAVRestoreComponent) async throws {
        let fixture = try await RestoreFixture.make()
        fixture.transport.set("manifest.json", status: 404)
        for missing in WebDAVRestoreComponent.allCases where missing != component {
            fixture.transport.set(missing.rawValue, status: 404)
        }
        let manager = fixture.manager()
        try await manager.restore()
        #expect(fixture.publications == 1 && manager.lastSyncDate != fixture.oldSync)
        let actual = try await fixture.readDestinations()
        for item in WebDAVRestoreComponent.allCases {
            #expect(actual[item] == (item == component ? Data("[]".utf8) : fixture.originals[item]))
        }
        await fixture.cleanUp()
    }

    @Test("a write that changes its destination and then throws is rolled back", arguments: [0, 1, 2], [false, true])
    func failedAttemptIsIncludedInRollback(failureIndex: Int, originallyMissing: Bool) async throws {
        let fixture = try await RestoreFixture.make(missing: originallyMissing ? WebDAVRestoreComponent.allCases[failureIndex] : nil)
        fixture.disk.failInstallIndex = failureIndex
        var environment = fixture.environment()
        environment.install = fixture.disk.install
        let manager = fixture.manager(environment)
        #expect(await caughtRestore(manager) != nil)
        await fixture.expectUnchanged(manager)
        #expect(fixture.disk.installCount > failureIndex, "the injected failure is after the attempted mutation")
        await fixture.cleanUp()
    }

    @Test("original read/copy failures abort before any destination changes")
    func originalCopyFailureDoesNotStartCommit() async throws {
        let fixture = try await RestoreFixture.make()
        var environment = fixture.environment()
        environment.copyOriginal = { _, _ in throw CocoaError(.fileReadNoPermission) }
        environment.install = fixture.disk.install
        let manager = fixture.manager(environment)
        #expect(await caughtRestore(manager) != nil)
        await fixture.expectUnchanged(manager)
        #expect(fixture.disk.installCount == 0)
        await fixture.cleanUp()
    }

    @Test("a failed rollback retains durable originals and has a safe error message")
    func failedRollbackPreservesRecoveryMaterial() async throws {
        let fixture = try await RestoreFixture.make()
        fixture.disk.failInstallIndex = 1
        fixture.disk.failRollback = true
        var environment = fixture.environment()
        environment.install = fixture.disk.install
        let manager = fixture.manager(environment)
        let error = await caughtRestore(manager)
        let failure = try #require(error as? WebDAVRestoreFailure)
        guard case .rollbackFailed(let recovery) = failure else {
            Issue.record("Expected an explicit rollback failure")
            await fixture.cleanUp()
            return
        }
        let retained = try await WebDAVRestoreTransaction.offMain {
            let contents = try FileManager.default.contentsOfDirectory(at: recovery, includingPropertiesForKeys: nil)
            let originals = try WebDAVRestoreComponent.allCases.map {
                try Data(contentsOf: recovery.appendingPathComponent("original-" + $0.rawValue))
            }
            return (contents.map(\.lastPathComponent), originals)
        }
        #expect(retained.0.contains("recovery.json"))
        #expect(retained.1 == WebDAVRestoreComponent.allCases.compactMap { fixture.originals[$0] })
        #expect(!manager.statusMessage.contains(fixture.root.path))
        #expect(fixture.publications == 0 && manager.lastSyncDate == fixture.oldSync && !manager.isSyncing)
        await fixture.cleanUp()
    }

    @Test("success publishes once after the whole batch and normalizes duplicate rules")
    func successfulBatchPublishesCommittedValues() async throws {
        let fixture = try await RestoreFixture.make()
        let rule = ReplaceRule(id: "a", name: "Owned rule", pattern: "fixture")
        var duplicate = rule
        duplicate.id = "z"
        fixture.transport.set("replace_rules.json", data: try JSONEncoder().encode([duplicate, rule]))
        var environment = fixture.environment()
        environment.install = fixture.disk.install
        environment.publish = { payload in
            #expect(fixture.disk.installCount == 3)
            #expect(payload.rules?.map(\.id) == ["a"])
            fixture.publications += 1
        }
        let manager = fixture.manager(environment)
        try await manager.restore()
        let data = try await fixture.readDestinations()
        let saved = try JSONDecoder().decode([ReplaceRule].self, from: #require(data[.rules]))
        #expect(saved.map(\.id) == ["a"])
        #expect(fixture.publications == 1 && manager.lastSyncDate != fixture.oldSync && !manager.isSyncing)
        #expect(fixture.disk.allIOOffMain)
        await fixture.cleanUp()
    }

    @Test("one explicit later restore recovers after an earlier validation failure")
    func subsequentRestoreRecoversWithoutImplicitRetry() async throws {
        let fixture = try await RestoreFixture.make()
        fixture.transport.set("replace_rules.json", data: Data("broken".utf8))
        let manager = fixture.manager()
        #expect(await caughtRestore(manager) != nil)
        await fixture.expectUnchanged(manager)
        fixture.transport.set("replace_rules.json", data: Data("[]".utf8))
        try await manager.restore()
        #expect(fixture.publications == 1 && manager.lastSyncDate != fixture.oldSync)
        #expect(fixture.transport.requests.count == 8, "two explicit attempts, four GETs each")
        await fixture.cleanUp()
    }

    @Test("a cross-device manifest waits for an explicit conflict choice", arguments: [false, true])
    func manifestConflictRequiresChoice(keepRemote: Bool) async throws {
        let fixture = try await RestoreFixture.make()
        let manifest = SyncManifest(deviceId: "another-owned-device", deviceName: "Remote fixture",
            backupDate: fixture.oldSync.addingTimeInterval(60), appVersion: "test")
        fixture.transport.set("manifest.json", data: try JSONEncoder().encode(manifest))
        let manager = fixture.manager()
        try await manager.restore()
        #expect(manager.pendingConflict?.remote.deviceId == "another-owned-device")
        await fixture.expectUnchanged(manager)
        try await manager.resolveConflict(keepRemote: keepRemote)
        #expect(manager.pendingConflict == nil)
        if keepRemote {
            #expect(fixture.publications == 1 && manager.lastSyncDate != fixture.oldSync)
            #expect(try await fixture.readDestinations().values.allSatisfy { $0 == Data("[]".utf8) })
        } else {
            await fixture.expectUnchanged(manager)
        }
        await fixture.cleanUp()
    }

    @Test("queued old writes drain and a new paused edit rejects the restore")
    func pausedEditConflictsAndKeepsLocalProgress() async throws {
        let fixture = try await RestoreFixture.make()
        let book = ReadingBook(title: "Owned local book", contentFilename: "fixture.txt")
        let metadata = try #require(fixture.destinations[.books])
        let initialData = try JSONEncoder().encode([book])
        try await WebDAVRestoreTransaction.offMain { try initialData.write(to: metadata, options: .atomic) }
        let store = try await WebDAVRestoreTransaction.offMain { BookStore(metadataFileURL: metadata) }
        // This request is debounced. begin must enqueue it, then the async barrier
        // must land it before recovery copies are taken; no scheduler sleeps.
        store.updatePosition(bookId: book.id, position: 0.25, notifyLibraryViews: false)
        var didEdit = false
        var environment = fixture.environment()
        environment.copyOriginal = { original, backup in
            try FileManager.default.copyItem(at: original, to: backup)
            if original == metadata {
                let old = try JSONDecoder().decode([ReadingBook].self, from: Data(contentsOf: backup))
                #expect(old.first?.currentPosition == 0.25)
            }
        }
        environment.install = fixture.disk.install
        environment = replacingPreparation(environment) { _ in
            let revision = try store.beginValidatedRestoreWrites()
            await BookStore.queuedWritesLanded()
            return .init(isCurrent: {
                if fixture.disk.installCount > 0, !didEdit {
                    didEdit = true
                    store.updatePosition(bookId: book.id, position: 0.75, forceSave: true, notifyLibraryViews: false)
                }
                return store.mutationRevision == revision
            }, finish: { store.finishValidatedRestoreWrites() })
        }
        let manager = fixture.manager(environment)
        #expect(await caughtRestore(manager) != nil)
        store.flushPendingMetadataSave()
        await BookStore.queuedWritesLanded()
        let saved = try await WebDAVRestoreTransaction.offMain {
            try JSONDecoder().decode([ReadingBook].self, from: Data(contentsOf: metadata))
        }
        #expect(didEdit && saved.first?.currentPosition == 0.75)
        #expect(store.readingBook(id: book.id)?.currentPosition == 0.75)
        #expect(fixture.publications == 0 && manager.lastSyncDate == fixture.oldSync)
        await fixture.cleanUp()
    }

    @Test("restore preserves the local TOC summary and refuses TXT migration during its lease")
    func localSummaryAndTXTWriterRespectBoundary() async throws {
        let fixture = try await RestoreFixture.make()
        let metadata = try #require(fixture.destinations[.books])
        var local = ReadingBook(title: "Owned TOC", contentFilename: "fixture.txt")
        local.isOnline = true
        local.onlineChapters = [OnlineChapterRef(index: 0, title: "Local latest", url: "https://restore.example/1")]
        try await WebDAVRestoreTransaction.offMain { try Data("[]".utf8).write(to: metadata, options: .atomic) }
        let store = try await WebDAVRestoreTransaction.offMain { BookStore(metadataFileURL: metadata) }
        // The existing setter moves TOCs into the dirty sidecar cache without
        // scheduling a write: summary repair must also handle an unflushed list.
        store.books = [local]
        let incoming = local.strippedForSync()
        let repaired = try await WebDAVRestoreTransaction.offMain { store.preparingValidatedRestoreShelf([incoming]) }
        #expect(repaired.first?.totalChapterNum == 1 && repaired.first?.latestChapterTitle == "Local latest")
        // Legacy inline TOCs must stay in the durable wire file until the normal
        // writer migrates them, flushing the sidecar before replacing metadata.
        var legacyObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode([incoming])) as? [[String: Any]])
        legacyObject[0]["onlineChapters"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(local.onlineChapters))
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject, options: [.sortedKeys])
        fixture.transport.set("books.json", data: legacyData)
        var environment = fixture.environment()
        environment.prepareBooks = { store.preparingValidatedRestoreShelf($0) }
        let ownedEnvironment = environment
        let prepared = try await WebDAVRestoreTransaction.offMain {
            try await WebDAVRestoreTransaction.prepare(configuration: .init(serverURL: "https://restore.example",
                authorization: "Basic fixture", deviceID: "owned-device", lastSyncDate: nil), environment: ownedEnvironment)
        }
        #expect(prepared.payload.books?.first?.onlineChapters?.first?.title == "Local latest")
        let stagedURL = try #require(prepared.incoming[.books])
        let staged = try await WebDAVRestoreTransaction.offMain { try Data(contentsOf: stagedURL) }
        #expect(staged == legacyData)
        await WebDAVRestoreTransaction.cleanUpOffMain(prepared.directory)
        _ = try store.beginValidatedRestoreWrites()
        await BookStore.queuedWritesLanded()
        let before = try await fixture.readDestinations()
        do {
            try await store.commitTXTBookmarks(bookId: local.id, original: [], migrated: [])
            Issue.record("TXT migration must reject an active restore lease")
        } catch { #expect((error as NSError).code == CocoaError.fileLocking.rawValue) }
        #expect(try await fixture.readDestinations() == before)
        store.finishValidatedRestoreWrites()
        await fixture.cleanUp()
    }

    private func caughtRestore(_ manager: WebDAVManager) async -> Error? {
        do { try await manager.restore(); Issue.record("Restore unexpectedly succeeded"); return nil }
        catch { return error }
    }

    private func replacingPreparation(_ original: WebDAVRestoreEnvironment,
        prepare: @escaping @MainActor (WebDAVRestorePayload) async throws -> WebDAVRestoreWriterLease
    ) -> WebDAVRestoreEnvironment {
        .init(destinations: original.destinations, temporaryRoot: original.temporaryRoot,
              transport: original.transport, copyOriginal: original.copyOriginal,
              install: original.install, remove: original.remove, prepareBooks: original.prepareBooks,
              prepareStores: prepare, publish: original.publish)
    }
}

@MainActor
private final class RestoreFixture {
    let root: URL
    let destinations: [WebDAVRestoreComponent: URL]
    let originals: [WebDAVRestoreComponent: Data]
    let defaults: UserDefaults
    let suite: String
    let transport = RestoreTransport()
    let disk = RestoreDiskFaults()
    var publications = 0
    let oldSync = Date(timeIntervalSince1970: 123)

    private init(root: URL, destinations: [WebDAVRestoreComponent: URL],
                 originals: [WebDAVRestoreComponent: Data], suite: String, defaults: UserDefaults) {
        self.root = root; self.destinations = destinations; self.originals = originals
        self.suite = suite; self.defaults = defaults
    }

    static func make(missing: WebDAVRestoreComponent? = nil) async throws -> RestoreFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WebDAVRestoreTests-\(UUID().uuidString)")
        let destinations = Dictionary(uniqueKeysWithValues: WebDAVRestoreComponent.allCases.map { ($0, root.appendingPathComponent($0.rawValue)) })
        let originals = Dictionary(uniqueKeysWithValues: WebDAVRestoreComponent.allCases.filter { $0 != missing }.map {
            ($0, Data("old-owned-\($0.rawValue)".utf8))
        })
        try await WebDAVRestoreTransaction.offMain {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for (component, data) in originals { try data.write(to: destinations[component]!, options: .atomic) }
        }
        let suite = "WebDAVRestoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let fixture = RestoreFixture(root: root, destinations: destinations, originals: originals, suite: suite, defaults: defaults)
        defaults.set(fixture.oldSync, forKey: "webdav_last_sync")
        defaults.set("owned-device", forKey: "sync_device_id")
        defaults.set("https://restore.example", forKey: "webdav_url")
        let manifest = SyncManifest(deviceId: "owned-device", deviceName: "Owned fixture", backupDate: fixture.oldSync, appVersion: "test")
        fixture.transport.set("manifest.json", data: try JSONEncoder().encode(manifest))
        for component in WebDAVRestoreComponent.allCases { fixture.transport.set(component.rawValue, data: Data("[]".utf8)) }
        return fixture
    }

    func environment() -> WebDAVRestoreEnvironment {
        .init(destinations: destinations, temporaryRoot: root, transport: { [transport] in try transport.respond($0) },
              prepareStores: { _ in .uncoordinated }, publish: { [self] _ in publications += 1 })
    }

    func manager(_ environment: WebDAVRestoreEnvironment? = nil) -> WebDAVManager {
        WebDAVManager(defaults: defaults, restoreEnvironment: environment ?? self.environment())
    }

    func readDestinations() async throws -> [WebDAVRestoreComponent: Data] {
        let paths = destinations
        return try await WebDAVRestoreTransaction.offMain {
            var values: [WebDAVRestoreComponent: Data] = [:]
            for (component, url) in paths {
                do { values[component] = try Data(contentsOf: url) }
                catch { if !WebDAVRestoreTransaction.isMissing(error) { throw error } }
            }
            return values
        }
    }

    func expectUnchanged(_ manager: WebDAVManager) async {
        do { #expect(try await readDestinations() == originals) }
        catch { Issue.record("Could not inspect owned destinations: \(error)") }
        #expect(publications == 0 && manager.lastSyncDate == oldSync && !manager.isSyncing)
    }

    func cleanUp() async {
        defaults.removePersistentDomain(forName: suite)
        await WebDAVRestoreTransaction.cleanUpOffMain(root)
    }
}

private final class RestoreTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String: (Int, Data)] = [:]
    private var captured: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { captured } }

    func set(_ name: String, status: Int = 200, data: Data = Data()) {
        lock.withLock { replies[name] = (status, data) }
    }

    func respond(_ request: URLRequest) throws -> (Data, URLResponse) {
        let reply = lock.withLock {
            captured.append(request)
            return replies[request.url!.lastPathComponent] ?? (404, Data())
        }
        if reply.0 < 0 { throw URLError(URLError.Code(rawValue: reply.0)) }
        return (reply.1, HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

private final class RestoreDiskFaults: @unchecked Sendable {
    private let lock = NSLock()
    private var installs = 0
    private var offMain = true
    var failInstallIndex: Int?
    var failRollback = false
    var installCount: Int { lock.withLock { installs } }
    var allIOOffMain: Bool { lock.withLock { offMain } }

    func install(_ source: URL, _ destination: URL) throws {
        let index = lock.withLock {
            offMain = offMain && !Thread.isMainThread
            let value = installs; installs += 1; return value
        }
        let rollback = source.lastPathComponent.hasPrefix("original-")
        if rollback && failRollback { throw CocoaError(.fileWriteNoPermission) }
        try WebDAVRestoreTransaction.installFile(source, destination)
        if !rollback && index == failInstallIndex { throw CocoaError(.fileWriteOutOfSpace) }
    }
}
