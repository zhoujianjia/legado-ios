import CryptoKit
import Foundation
import Testing
@testable import yuedu_app

@Suite(.serialized)
@MainActor
struct BuiltInBookSourcesTests {
    @Test("scratch stores never discover or seed a bundled pack by default")
    func directoryStoresDoNotSeedByDefault() async throws {
        let root = try temporaryDirectory()
        defer { removeDirectory(root) }
        _ = try package([source("one")], in: root)
        let store = BookSourceStore(directory: root)
        await store.waitUntilLoaded()
        #expect(store.sources.isEmpty)
        #expect(store.loadError == nil)
        #expect(store.builtInBootstrapError == nil)
        #expect(!FileManager.default.fileExists(atPath: libraryURL(root).path))
        #expect(BuiltInBookSourceBootstrap.Package.bundled(isLocalExperience: false) == nil)
    }

    @Test("a fresh install preserves source options and uses the store URL dedupe rule")
    func freshInstallPreservesSourceConfiguration() async throws {
        let root = try temporaryDirectory()
        defer { removeDirectory(root) }
        var older = source("duplicate")
        older.lastUpdateTime = 1
        var newest = source("duplicate")
        newest.bookSourceName = "Newest fixture"
        newest.lastUpdateTime = 2
        newest.enabled = false
        newest.enabledExplore = false
        newest.bookSourceGroup = "Original fixture group"
        newest.presentsAndroidIdentity = false
        let other = source("other")
        let (pack, manifest) = try package([older, other, newest], in: root)
        let store = BookSourceStore(directory: root, builtInPackage: pack)
        await store.waitUntilLoaded()
        #expect(store.loadError == nil)
        #expect(store.builtInBootstrapError == nil)
        #expect(store.sources.map(\.id) == [newest.id, other.id])
        #expect(try sortedJSON(store.sources[0]) == sortedJSON(newest))
        let saved = try JSONDecoder().decode([BookSource].self, from: Data(contentsOf: libraryURL(root)))
        #expect(saved.map(\.id) == store.sources.map(\.id))
        #expect(try journal(manifest, in: root).state == .complete)
    }

    @Test("upgrades append only missing URLs and preserve local identity, options and bottom pins")
    func upgradesPreserveLocalSourcesAndPins() async throws {
        let root = try temporaryDirectory()
        defer { removeDirectory(root) }
        var local = source("existing")
        local.bookSourceName = "My edited name"
        local.bookSourceGroup = "My group"
        local.enabled = false
        local.enabledExplore = false
        local.presentsAndroidIdentity = false
        local.header = #"{"X-Fixture":"local-value"}"#
        local.lastUpdateTime = 10
        let bottom = source("bottom")
        try writeExisting([local, bottom], in: root)
        let pins = [bottom.id: SourcePinRecord(position: .bottom, originalIndex: 1)]
        let pinsURL = root.appendingPathComponent("book_source_pins.json")
        let pinsData = try JSONEncoder().encode(pins)
        try pinsData.write(to: pinsURL)
        var replacement = source("existing")
        replacement.lastUpdateTime = 999_999
        let addition = source("addition")
        let (pack, _) = try package([replacement, addition], in: root)
        let store = BookSourceStore(directory: root, builtInPackage: pack)
        await store.waitUntilLoaded()
        #expect(store.sources.map(\.id) == [local.id, addition.id, bottom.id])
        #expect(try sortedJSON(store.sources[0]) == sortedJSON(local))
        #expect(store.pinRecord(for: bottom.id)?.position == .bottom)
        #expect(try Data(contentsOf: pinsURL) == pinsData)
    }

    @Test("deleting an installed source does not resurrect it or rewrite an unchanged library")
    func deletionAfterCompletionDoesNotResurrect() async throws {
        let root = try temporaryDirectory()
        defer { removeDirectory(root) }
        let first = source("first")
        let second = source("second")
        let (pack, manifest) = try package([first, second], in: root)
        let store = BookSourceStore(directory: root, builtInPackage: pack)
        await store.waitUntilLoaded()
        #expect(store.delete(id: first.id) == 1)
        await drainWrites(store)
        let original = try Data(contentsOf: libraryURL(root))
        let markerURL = BuiltInBookSourceBootstrap.journalURL(for: manifest, libraryURL: libraryURL(root))
        let marker = try Data(contentsOf: markerURL)
        let reopened = BookSourceStore(directory: root, builtInPackage: pack)
        await reopened.waitUntilLoaded()
        #expect(reopened.sources.map(\.id) == [second.id])
        #expect(reopened.builtInBootstrapError == nil)
        #expect(try Data(contentsOf: libraryURL(root)) == original)
        #expect(try Data(contentsOf: markerURL) == marker)
    }

    @Test("an optional missing resource does not require a manifest or change existing data")
    func missingOptionalResourceIsANoOp() async throws {
        let root = try temporaryDirectory()
        defer { removeDirectory(root) }
        let local = source("local")
        let original = try writeExisting([local], in: root)
        let pack = BuiltInBookSourceBootstrap.Package(
            resourceURL: root.appendingPathComponent("missing.json"),
            manifestURL: root.appendingPathComponent("missing.manifest.json")
        )
        let store = BookSourceStore(directory: root, builtInPackage: pack)
        await store.waitUntilLoaded()
        #expect(store.sources.map(\.id) == [local.id])
        #expect(store.builtInBootstrapError == nil)
        #expect(try Data(contentsOf: libraryURL(root)) == original)
    }

    @Test("bad source packs, missing manifests and invalid metadata preserve the existing library")
    func invalidPackagesPreserveExistingLibrary() async throws {
        for failure in 0..<4 {
            let root = try temporaryDirectory()
            defer { removeDirectory(root) }
            let local = source("local")
            let original = try writeExisting([local], in: root)
            let (pack, _) = try package([source("incoming")], in: root)
            switch failure {
            case 0:
                try Data("changed bytes".utf8).write(to: pack.resourceURL)
            case 1:
                let invalid = Data("not JSON".utf8)
                try invalid.write(to: pack.resourceURL)
                let manifest = BuiltInBookSourceBootstrap.Manifest(schemaVersion: 1, version: "fixture-v1", sha256: digest(invalid))
                try JSONEncoder().encode(manifest).write(to: pack.manifestURL)
            case 2:
                try Data("{}".utf8).write(to: pack.manifestURL)
            default:
                try FileManager.default.removeItem(at: pack.manifestURL)
            }
            let store = BookSourceStore(directory: root, builtInPackage: pack)
            await store.waitUntilLoaded()
            #expect(store.loadError == nil)
            #expect(store.builtInBootstrapError != nil)
            #expect(store.sources.map(\.id) == [local.id])
            #expect(try Data(contentsOf: libraryURL(root)) == original)
            let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
            #expect(!files.contains { $0.hasPrefix("book_source_bootstrap.") })
        }
    }

    @Test("an unreadable existing library is not treated as an empty installation or overwritten")
    func unreadableExistingLibraryIsProtected() async throws {
        let root = try temporaryDirectory()
        defer { removeDirectory(root) }
        let original = Data("[{broken existing library".utf8)
        try original.write(to: libraryURL(root))
        let pinsURL = root.appendingPathComponent("book_source_pins.json")
        let pins = [UUID(): SourcePinRecord(position: .top, originalIndex: 0)]
        let originalPins = try JSONEncoder().encode(pins)
        try originalPins.write(to: pinsURL)
        let (pack, manifest) = try package([source("incoming")], in: root)
        let store = BookSourceStore(directory: root, builtInPackage: pack)
        await store.waitUntilLoaded()
        #expect(store.loadError != nil)
        #expect(store.builtInBootstrapError == nil)
        store.add(source("manual"))
        await drainWrites(store)
        #expect(try Data(contentsOf: libraryURL(root)) == original)
        #expect(try Data(contentsOf: pinsURL) == originalPins)
        #expect(!FileManager.default.fileExists(atPath:
            BuiltInBookSourceBootstrap.journalURL(for: manifest, libraryURL: libraryURL(root)).path))
    }

    @Test("a failed library write stays pending and a later launch can retry safely")
    func failedWritesStayPendingAndCanRetry() async throws {
        let root = try temporaryDirectory()
        defer { removeDirectory(root) }
        let original = try writeExisting([source("local")], in: root)
        let (pack, manifest) = try package([source("incoming")], in: root)
        let url = libraryURL(root)
        let failedAsExpected = try await Task.detached {
            let existing = try JSONDecoder().decode([BookSource].self, from: original)
            do {
                _ = try BuiltInBookSourceBootstrap.apply(pack, to: existing, libraryURL: url, pins: [:]) { _, _ in
                    throw FixtureFailure.write
                }
                return false
            } catch FixtureFailure.write {
                return true
            }
        }.value
        #expect(failedAsExpected)
        #expect(try Data(contentsOf: url) == original)
        #expect(try journal(manifest, in: root).state == .pending)
        let store = BookSourceStore(directory: root, builtInPackage: pack)
        await store.waitUntilLoaded()
        #expect(store.builtInBootstrapError == nil)
        #expect(store.sources.count == 2)
        #expect(try journal(manifest, in: root).state == .complete)
    }

    @Test("a committed pending import finishes only its marker without reimporting")
    func committedPendingImportRecoversWithoutRewriting() async throws {
        let root = try temporaryDirectory()
        defer { removeDirectory(root) }
        let before = [source("local")]
        let incoming = source("incoming")
        let after = before + [incoming]
        let (pack, manifest) = try package([incoming], in: root)
        try writeExisting(after, in: root)
        try await writePendingJournal(manifest, before: before, after: after, in: root)
        let original = try Data(contentsOf: libraryURL(root))
        let store = BookSourceStore(directory: root, builtInPackage: pack)
        await store.waitUntilLoaded()
        #expect(store.sources.map(\.id) == after.map(\.id))
        #expect(store.builtInBootstrapError == nil)
        #expect(try journal(manifest, in: root).state == .complete)
        #expect(try Data(contentsOf: libraryURL(root)) == original)
    }

    @Test("ambiguous pending recovery preserves a user's edit or deletion and stops seeding")
    func interruptedImportDoesNotOverwriteLaterUserEdits() async throws {
        let root = try temporaryDirectory()
        defer { removeDirectory(root) }
        let local = source("local")
        let incoming = source("incoming")
        var edited = local
        edited.bookSourceName = "User edited after interruption"
        let original = try writeExisting([edited], in: root)
        let (pack, manifest) = try package([incoming], in: root)
        try await writePendingJournal(manifest, before: [local], after: [local, incoming], in: root)
        let store = BookSourceStore(directory: root, builtInPackage: pack)
        await store.waitUntilLoaded()
        #expect(store.loadError == nil)
        #expect(store.builtInBootstrapError != nil)
        #expect(store.sources.map(\.id) == [edited.id])
        #expect(store.sources[0].bookSourceName == edited.bookSourceName)
        #expect(try Data(contentsOf: libraryURL(root)) == original)
        #expect(try journal(manifest, in: root).state == .pending)
    }

    private enum FixtureFailure: Error { case write }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BuiltInBookSources-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func removeDirectory(_ directory: URL) {
        do { try FileManager.default.removeItem(at: directory) }
        catch { Issue.record("Fixture cleanup failed: \(error)") }
    }

    private func libraryURL(_ directory: URL) -> URL {
        directory.appendingPathComponent("book_sources.json")
    }

    @discardableResult
    private func writeExisting(_ sources: [BookSource], in directory: URL) throws -> Data {
        let data = try JSONEncoder().encode(sources)
        try data.write(to: libraryURL(directory))
        return data
    }

    private func package(_ sources: [BookSource], in directory: URL) throws
        -> (BuiltInBookSourceBootstrap.Package, BuiltInBookSourceBootstrap.Manifest) {
        let resource = directory.appendingPathComponent("BuiltInBookSources.json")
        let manifestURL = directory.appendingPathComponent("BuiltInBookSources.manifest.json")
        let data = try JSONEncoder().encode(sources)
        let manifest = BuiltInBookSourceBootstrap.Manifest(schemaVersion: 1, version: "fixture-v1", sha256: digest(data))
        try data.write(to: resource)
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        return (.init(resourceURL: resource, manifestURL: manifestURL), manifest)
    }

    private func journal(_ manifest: BuiltInBookSourceBootstrap.Manifest, in directory: URL) throws
        -> BuiltInBookSourceBootstrap.Journal {
        let url = BuiltInBookSourceBootstrap.journalURL(for: manifest, libraryURL: libraryURL(directory))
        return try JSONDecoder().decode(BuiltInBookSourceBootstrap.Journal.self, from: Data(contentsOf: url))
    }

    private func writePendingJournal(
        _ manifest: BuiltInBookSourceBootstrap.Manifest,
        before: [BookSource], after: [BookSource], in directory: URL
    ) async throws {
        // Encode the immutable fixture before leaving MainActor; no store state
        // is read by this worker and only Sendable bytes/URLs cross the boundary.
        let beforeData = try JSONEncoder().encode(before)
        let afterData = try JSONEncoder().encode(after)
        let url = BuiltInBookSourceBootstrap.journalURL(for: manifest, libraryURL: libraryURL(directory))
        try await Task.detached {
            let decoder = JSONDecoder()
            let journal = BuiltInBookSourceBootstrap.Journal(
                schemaVersion: 1, version: manifest.version, sha256: manifest.sha256,
                previousLibraryDigest: try BuiltInBookSourceBootstrap.libraryDigest(decoder.decode([BookSource].self, from: beforeData)),
                targetLibraryDigest: try BuiltInBookSourceBootstrap.libraryDigest(decoder.decode([BookSource].self, from: afterData)),
                state: .pending
            )
            try JSONEncoder().encode(journal).write(to: url, options: .atomic)
        }.value
    }

    private func drainWrites(_ store: BookSourceStore) async {
        await Task.detached { store.waitForQueuedWrites() }.value
    }

    private func source(_ name: String) -> BookSource {
        BookSource(bookSourceUrl: "https://\(name).example.invalid", bookSourceName: "Fixture \(name)")
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func sortedJSON(_ source: BookSource) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(source)
    }
}
