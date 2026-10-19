import Foundation
import Testing
@testable import yuedu_app

// Extend the existing serialized suite: a second serialized suite would still
// run concurrently with it and race GlobalSettings.shared.
extension UserFontSettingsTests {
    @Test("failed imports preserve old bytes, records and both selections", .timeLimit(.minutes(1)), arguments: FontFault.allCases, [false, true])
    func failedImportPreservesLibrary(fault: FontFault, global: Bool) async throws {
        let fixture = try await FontFixture.make()
        let settings = GlobalSettings.shared
        let saved = FontSettingsSnapshot(settings)
        defer { saved.restore(settings) }
        fixture.installSettings(settings)
        fixture.state.fault = fault
        do {
            if global { _ = try await settings.importGlobalFont(from: fixture.source, storage: fixture.storage) }
            else { _ = try await settings.importReaderFont(from: fixture.source, storage: fixture.storage) }
            Issue.record("Injected font import failure must propagate")
        } catch {}
        #expect(fixture.state.didUseFault, "the selected fault must actually be reached")
        #expect(settings.userFonts == [fixture.original])
        #expect(settings.selectedGlobalFontPostScript == "OwnedFont")
        #expect(settings.selectedReaderFontPostScript == "OwnedFont")
        #expect(try await fixture.oldBytes() == fixture.originalBytes)
        #expect(fixture.state.registered == [fixture.oldURL])
        #expect(fixture.state.allOffMain)
        await fixture.cleanUp()
    }

    @Test("failed deletion restores a file already removed and preserves selections", .timeLimit(.minutes(1)))
    func failedDeletePreservesLibrary() async throws {
        let fixture = try await FontFixture.make()
        let settings = GlobalSettings.shared
        let saved = FontSettingsSnapshot(settings)
        defer { saved.restore(settings) }
        fixture.installSettings(settings)
        fixture.state.fault = .removeAfterMutation
        do { try await settings.deleteUserFont(fixture.original, storage: fixture.storage); Issue.record("Deletion unexpectedly succeeded") }
        catch {}
        #expect(fixture.state.didUseFault)
        #expect(settings.userFonts == [fixture.original])
        #expect(settings.selectedGlobalFontPostScript == "OwnedFont" && settings.selectedReaderFontPostScript == "OwnedFont")
        #expect(try await fixture.oldBytes() == fixture.originalBytes)
        #expect(fixture.state.registered == [fixture.oldURL] && fixture.state.allOffMain)
        // A separate user action may succeed after the injected one-shot failure;
        // the transaction itself never retries or waits for a timing interval.
        try await settings.deleteUserFont(fixture.original, storage: fixture.storage)
        #expect(settings.userFonts.isEmpty && fixture.state.registered.isEmpty)
        #expect(settings.selectedGlobalFontPostScript == nil && settings.selectedReaderFontPostScript == nil)
        await fixture.cleanUp()
    }

    @Test("success replaces one file and deletion then clears both choices", .timeLimit(.minutes(1)))
    func successPublishesOneCommittedFont() async throws {
        let fixture = try await FontFixture.make()
        let settings = GlobalSettings.shared
        let saved = FontSettingsSnapshot(settings)
        defer { saved.restore(settings) }
        fixture.installSettings(settings)
        let imported = try await settings.importUserFont(from: fixture.source, storage: fixture.storage)
        #expect(settings.userFonts == [imported])
        let files = try await fixture.fontFileNames()
        #expect(files == [imported.fileName])
        #expect(settings.selectedGlobalFontPostScript == "OwnedFont" && settings.selectedReaderFontPostScript == "OwnedFont")
        try await settings.deleteUserFont(imported, storage: fixture.storage)
        #expect(settings.userFonts.isEmpty)
        #expect(settings.selectedGlobalFontPostScript == nil && settings.selectedReaderFontPostScript == nil)
        #expect(try await fixture.fontFileNames().isEmpty)
        #expect(fixture.state.registered.isEmpty && fixture.state.allOffMain)
        await fixture.cleanUp()
    }

    @Test("an original already removed in Files can be deleted or replaced", .timeLimit(.minutes(1)), arguments: [false, true])
    func missingOldFilesCanBeRepaired(reimport: Bool) async throws {
        let fixture = try await FontFixture.make()
        let settings = GlobalSettings.shared
        let saved = FontSettingsSnapshot(settings)
        defer { saved.restore(settings) }
        fixture.installSettings(settings)
        let oldURL = fixture.oldURL
        try await Task.detached { try FileManager.default.removeItem(at: oldURL) }.value
        if reimport {
            let imported = try await settings.importUserFont(from: fixture.source, storage: fixture.storage)
            let importedURL = try fixture.storage.fileURL(for: imported)
            #expect(settings.userFonts == [imported])
            #expect(try await fixture.fontFileNames() == [imported.fileName])
            #expect(fixture.state.registered == [importedURL])
        } else {
            try await settings.deleteUserFont(fixture.original, storage: fixture.storage)
            #expect(settings.userFonts.isEmpty && fixture.state.registered.isEmpty)
            #expect(settings.selectedGlobalFontPostScript == nil && settings.selectedReaderFontPostScript == nil)
            #expect(try await fixture.fontFileNames().isEmpty)
        }
        #expect(fixture.state.allOffMain)
        await fixture.cleanUp()
    }

    @Test("an ENOENT from copying an existing original is not optional absence", .timeLimit(.minutes(1)))
    func recoveryCopyMissingErrorStillAborts() async throws {
        let fixture = try await FontFixture.make()
        let settings = GlobalSettings.shared
        let saved = FontSettingsSnapshot(settings)
        defer { saved.restore(settings) }
        fixture.installSettings(settings)
        fixture.state.fault = .copyOriginal
        fixture.state.copyOriginalErrorIsMissing = true
        do { _ = try await settings.importUserFont(from: fixture.source, storage: fixture.storage); Issue.record("Copy failure must abort") }
        catch { #expect(UserFontStorageManager.isMissingFileError(error)) }
        #expect(fixture.state.didUseFault && fixture.state.allOffMain)
        #expect(settings.userFonts == [fixture.original])
        #expect(settings.selectedGlobalFontPostScript == "OwnedFont" && settings.selectedReaderFontPostScript == "OwnedFont")
        #expect(try await fixture.oldBytes() == fixture.originalBytes)
        #expect(try await fixture.fontFileNames() == [fixture.original.fileName])
        #expect(fixture.state.registered == [fixture.oldURL])
        await fixture.cleanUp()
    }

    @Test("default CoreText operations can remove a never-registered missing owned URL", .timeLimit(.minutes(1)))
    func defaultRegistryCanRemoveAnAlreadyMissingFont() async throws {
        let fixture = try await FontFixture.make()
        let settings = GlobalSettings.shared
        let saved = FontSettingsSnapshot(settings)
        defer { saved.restore(settings) }
        fixture.installSettings(settings)
        // No fake Operations are passed here. This owned URL was never registered
        // with CoreText; the future Simulator run exercises its real missing-URL
        // response without unregistering or removing any user-installed font.
        let productionStorage = UserFontStorageManager(ownedDirectory: fixture.directory)
        let oldURL = fixture.oldURL
        do {
            try await Task.detached { try FileManager.default.removeItem(at: oldURL) }.value
            try await settings.deleteUserFont(fixture.original, storage: productionStorage)
            #expect(settings.userFonts.isEmpty)
            #expect(settings.selectedGlobalFontPostScript == nil && settings.selectedReaderFontPostScript == nil)
            #expect(try await fixture.fontFileNames().isEmpty)
        } catch {
            await fixture.cleanUp()
            throw error
        }
        await fixture.cleanUp()
    }

    @Test("concurrent mutations reject and cancellation cannot drop a committed result", .timeLimit(.minutes(1)), arguments: [false, true])
    func heldImportHasOnePublicationBoundary(cancelFirst: Bool) async throws {
        let fixture = try await FontFixture.make()
        let gate = FontCopyGate()
        fixture.state.gate = gate
        let settings = GlobalSettings.shared
        let saved = FontSettingsSnapshot(settings)
        defer { gate.open(); saved.restore(settings) }
        fixture.installSettings(settings)
        let first = Task { try await settings.importGlobalFont(from: fixture.source, storage: fixture.storage) }
        var events = gate.started.makeAsyncIterator()
        _ = await events.next() // real worker entry, not a settling delay
        do { try await settings.deleteUserFont(fixture.original, storage: fixture.storage); Issue.record("Concurrent deletion must reject") }
        catch { #expect((error as? CocoaError)?.code == .fileLocking) }
        if cancelFirst { first.cancel() }
        gate.open()
        let imported = try await first.value
        #expect(settings.userFonts == [imported] && settings.selectedGlobalFontPostScript == imported.postScriptName)
        #expect(try await fixture.fontFileNames() == [imported.fileName])
        await fixture.cleanUp()
    }

    @Test("bad persisted file names cannot escape the owned directory", .timeLimit(.minutes(1)), arguments: ["../outside.ttf", "/outside.ttf", "folder/font.ttf", "folder\\font.ttf", ".", ".."])
    func invalidNamesAreRejected(name: String) async throws {
        let fixture = try await FontFixture.make()
        let bad = UserFontInfo(id: UUID(), fileName: name, displayName: "Bad", familyName: "Bad", postScriptName: "Bad", addedAt: Date())
        do { try fixture.storage.fileURL(for: bad); Issue.record("Unsafe font filename was accepted") }
        catch { #expect(error is UserFontStorageError) }
        #expect(try await fixture.oldBytes() == fixture.originalBytes)
        await fixture.cleanUp()
    }

    @Test("rollback failure keeps recovery bytes on disk and never publishes", .timeLimit(.minutes(1)))
    func rollbackFailureRetainsMaterials() async throws {
        let fixture = try await FontFixture.make()
        fixture.state.fault = .register
        fixture.state.failRestoringRegistration = true
        let settings = GlobalSettings.shared
        let saved = FontSettingsSnapshot(settings)
        defer { saved.restore(settings) }
        fixture.installSettings(settings)
        do { _ = try await settings.importGlobalFont(from: fixture.source, storage: fixture.storage); Issue.record("Rollback failure must propagate") }
        catch {
            guard let failure = error as? UserFontStorageError, case .rollbackFailed = failure else {
                Issue.record("Expected explicit rollback failure"); await fixture.cleanUp(); return
            }
            #expect(!error.localizedDescription.contains(fixture.root.path))
        }
        #expect(fixture.state.didUseFault)
        let fonts = fixture.directory
        let retained = try await Task.detached {
            let directories = try FileManager.default.contentsOfDirectory(at: fonts, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(".font-transaction-") }
            return try directories.map { try Data(contentsOf: $0.appendingPathComponent("old.ttf")) }
        }.value
        #expect(retained == [fixture.originalBytes])
        #expect(settings.userFonts == [fixture.original] && settings.selectedGlobalFontPostScript == "OwnedFont")
        await fixture.cleanUp()
    }
}

enum FontFault: String, CaseIterable, Sendable {
    case copyCandidate, metadata, copyOriginal, unregister, register, removeAfterMutation
}

@MainActor
private struct FontSettingsSnapshot {
    let fonts: [UserFontInfo]
    let global: String?
    let reader: String?
    init(_ settings: GlobalSettings) {
        fonts = settings.userFonts; global = settings.selectedGlobalFontPostScript; reader = settings.selectedReaderFontPostScript
    }
    func restore(_ settings: GlobalSettings) {
        settings.userFonts = fonts; settings.selectedGlobalFontPostScript = global; settings.selectedReaderFontPostScript = reader
    }
}

@MainActor
private final class FontFixture {
    let root: URL
    let directory: URL
    let source: URL
    let oldURL: URL
    let original: UserFontInfo
    let originalBytes = Data("owned original font bytes".utf8)
    let state: FontOperationState
    let storage: UserFontStorageManager

    private init(root: URL) {
        self.root = root
        directory = root.appendingPathComponent("fonts")
        source = root.appendingPathComponent("incoming.ttf")
        oldURL = directory.appendingPathComponent("old.ttf")
        original = .init(id: UUID(), fileName: "old.ttf", displayName: "OwnedFont", familyName: "OwnedFont", postScriptName: "OwnedFont", addedAt: Date())
        let state = FontOperationState(oldURL: oldURL)
        self.state = state
        storage = UserFontStorageManager(ownedDirectory: directory, operations: state.operations)
    }

    static func make() async throws -> FontFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UserFontTransaction-\(UUID().uuidString)")
        let fixture = FontFixture(root: root)
        let directory = fixture.directory, oldURL = fixture.oldURL, source = fixture.source, bytes = fixture.originalBytes
        try await Task.detached {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try bytes.write(to: oldURL, options: .atomic)
            try Data("owned incoming font bytes".utf8).write(to: source, options: .atomic)
        }.value
        return fixture
    }

    func installSettings(_ settings: GlobalSettings) {
        settings.userFonts = [original]
        settings.selectedGlobalFontPostScript = "OwnedFont"
        settings.selectedReaderFontPostScript = "OwnedFont"
    }
    func oldBytes() async throws -> Data { let url = oldURL; return try await Task.detached { try Data(contentsOf: url) }.value }
    func fontFileNames() async throws -> Set<String> {
        let directory = self.directory
        return try await Task.detached { Set(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") }) }.value
    }
    func cleanUp() async {
        let root = self.root
        await Task.detached {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Could not remove owned font fixture: \(error)") }
        }.value
    }
}

private final class FontOperationState: @unchecked Sendable {
    private let lock = NSLock()
    let oldURL: URL
    var fault: FontFault?
    var failRestoringRegistration = false
    var copyOriginalErrorIsMissing = false
    var gate: FontCopyGate?
    private var usedFault = false
    private var registrations: Set<URL>
    private var offMain = true
    var registered: Set<URL> { lock.withLock { registrations } }
    var allOffMain: Bool { lock.withLock { offMain } }
    var didUseFault: Bool { lock.withLock { usedFault } }
    init(oldURL: URL) { self.oldURL = oldURL; registrations = [oldURL] }

    private func fail(_ point: FontFault) -> Bool {
        lock.withLock {
            offMain = offMain && !Thread.isMainThread
            guard fault == point && !usedFault else { return false }
            usedFault = true; return true
        }
    }

    var operations: UserFontStorageManager.Operations {
        .init(copy: { [self] source, destination in
            if source.lastPathComponent == "incoming.ttf" { gate?.hold() }
            try FileManager.default.copyItem(at: source, to: destination)
            if fail(source == oldURL ? .copyOriginal : .copyCandidate) {
                if source == oldURL && copyOriginalErrorIsMissing { throw CocoaError(.fileReadNoSuchFile) }
                throw CocoaError(.fileWriteOutOfSpace)
            }
        }, remove: { [self] url in
            try FileManager.default.removeItem(at: url)
            if url == oldURL && fail(.removeAfterMutation) { throw CocoaError(.fileWriteNoPermission) }
        }, metadata: { [self] _ in
            fail(.metadata) ? nil : ("OwnedFont", "OwnedFont")
        }, register: { [self] url in
            if url == oldURL && failRestoringRegistration { throw UserFontStorageError.invalidFontFile }
            let occupied = lock.withLock { !registrations.isEmpty }
            guard !occupied else { throw UserFontStorageError.invalidFontFile }
            lock.withLock { registrations.insert(url) }
            if url != oldURL && fail(.register) { throw UserFontStorageError.invalidFontFile }
        }, unregister: { [self] url in
            lock.withLock { registrations.remove(url) }
            if url == oldURL && fail(.unregister) { throw UserFontStorageError.invalidFontFile }
        })
    }
}

/// Held only on a detached test worker. The async side waits for a real callback.
private final class FontCopyGate: @unchecked Sendable {
    let started: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation
    private let condition = NSCondition()
    private var opened = false
    init() { let pair = AsyncStream<Bool>.makeStream(); started = pair.stream; continuation = pair.continuation }
    func hold() {
        #expect(!Thread.isMainThread)
        continuation.yield(true)
        condition.lock()
        while !opened { condition.wait() }
        condition.unlock()
    }
    func open() { condition.lock(); opened = true; condition.broadcast(); condition.unlock(); continuation.finish() }
}
