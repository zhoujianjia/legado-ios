import CryptoKit
import Darwin
import Foundation
import Testing
@testable import yuedu_app

@Suite("Book source real-file handoff receipts", .serialized)
@MainActor
struct BookSourceStoreHandoffTests {
    @Test("streamed save and a new owner's normal load agree on actual raw bytes")
    func streamedSaveMatchesNewOwnerNormalLoad() async throws {
        let root = try await files { try makeDirectory() }
        defer { removeLater(root) }
        let store = BookSourceStore(directory: root)
        await store.waitUntilLoaded()
        // Fixture creation and encoding remain on a worker, including enough
        // source comments to cross the existing 1 MiB write chunk several times.
        let fixture = await Task.detached {
            let sources = (0..<900).map { index in
                var source = makeSource("stream-\(index)")
                source.bookSourceComment = String(repeating: "owned raw fixture \(index) ", count: 200)
                source.header = #"{"X-Owned":"verbatim 中文"}"#
                return source
            }
            return SourceFixture(sources)
        }.value
        let sources = fixture.sources
        store.sources = sources
        let revision = store.mutationRevision
        let saved = try await store.saveForRenewalHandoff()
        let raw = try await files { try Data(contentsOf: libraryURL(root)) }
        let actualHash = try await files { Data(SHA256.hash(data: raw)) }
        #expect(saved.operation == .atomicWriteCompleted)
        #expect(saved.rawSHA256 == actualHash)
        #expect(saved.rawByteCount == raw.count)
        #expect(saved.rawByteCount > 3 * 1_024 * 1_024)
        #expect(saved.sourceCount == sources.count)
        #expect(saved.mutationRevision == revision)

        let reopened = BookSourceStore(directory: root)
        let loaded = try await reopened.normalLoadReceiptForRenewalHandoff()
        #expect(loaded.operation == .normalFileRead)
        #expect(loaded.rawSHA256 == saved.rawSHA256)
        #expect(loaded.rawByteCount == saved.rawByteCount)
        #expect(loaded.sourceCount == saved.sourceCount)
        #expect(reopened.sources.map(\.id) == sources.map(\.id))
        #expect(reopened.sources[0].header == sources[0].header)
        // Revisions are intentionally local. Compare the raw proof across
        // owners, rather than asserting revision equality across processes.
    }

    @Test("normal load hashes the original JSON and distinguishes true missing from failed reads")
    func normalLoadPreservesRawBytesAndTypedFailures() async throws {
        let root = try await files { try makeDirectory() }
        defer { removeLater(root) }
        let raw = Data("[ \n ]".utf8)
        try await files { try raw.write(to: libraryURL(root)) }
        let store = BookSourceStore(directory: root)
        let loaded = try await store.normalLoadReceiptForRenewalHandoff()
        let expectedHash = Data(hex: "f565160033cec6a31bf2211877da5de2fdb0894b2161788f86529332615840f8")
        #expect(loaded.rawSHA256 == expectedHash)
        #expect(loaded.rawByteCount == 5)
        #expect(loaded.sourceCount == 0)
        let unchanged = try await files { try Data(contentsOf: libraryURL(root)) }
        #expect(unchanged == raw)
        store.sources = [makeSource("not-yet-saved")]
        let initialAgain = try await store.normalLoadReceiptForRenewalHandoff()
        #expect(initialAgain == loaded)
        #expect(initialAgain.mutationRevision != store.mutationRevision)

        let missingRoot = try await files { try makeDirectory() }
        defer { removeLater(missingRoot) }
        let missing = BookSourceStore(directory: missingRoot)
        let absent = try await missing.normalLoadReceiptForRenewalHandoff()
        #expect(absent.operation == .normalMissingFile)
        #expect(absent.rawSHA256 == nil)
        #expect(absent.rawByteCount == 0)

        let corruptRoot = try await files { try makeDirectory() }
        defer { removeLater(corruptRoot) }
        let corruptBytes = Data("[{owned corrupt bytes".utf8)
        try await files { try corruptBytes.write(to: libraryURL(corruptRoot)) }
        let corrupt = BookSourceStore(directory: corruptRoot)
        do {
            _ = try await corrupt.normalLoadReceiptForRenewalHandoff()
            Issue.record("corrupt JSON returned a normal-load receipt")
        } catch BookSourcePersistenceFailure.corruptJSON { }
        do {
            _ = try await corrupt.saveForRenewalHandoff()
            Issue.record("a failed initial read was overwritten")
        } catch BookSourcePersistenceFailure.corruptJSON { }
        let stillCorrupt = try await files { try Data(contentsOf: libraryURL(corruptRoot)) }
        #expect(stillCorrupt == corruptBytes)

        let directoryRoot = try await files { try makeDirectory() }
        defer { removeLater(directoryRoot) }
        try await files { try FileManager.default.createDirectory(at: libraryURL(directoryRoot), withIntermediateDirectories: false) }
        let directory = BookSourceStore(directory: directoryRoot)
        do {
            _ = try await directory.normalLoadReceiptForRenewalHandoff()
            Issue.record("a directory was treated as an absent library")
        } catch BookSourcePersistenceFailure.invalidFileType { }

        let parentRoot = try await files { try makeDirectory() }
        defer { removeLater(parentRoot) }
        let notDirectory = parentRoot.appendingPathComponent("parent-is-file")
        try await files { try Data("owned parent".utf8).write(to: notDirectory) }
        let badParent = BookSourceStore(directory: notDirectory)
        do {
            _ = try await badParent.normalLoadReceiptForRenewalHandoff()
            Issue.record("ENOTDIR was treated as an absent library")
        } catch BookSourcePersistenceFailure.readFailed(let error) {
            #expect((error as NSError).code == Int(ENOTDIR))
        }
    }

    @Test("real create and rename failures never issue successful save receipts")
    func actualWriteFailuresPreserveOriginalTargets() async throws {
        for failAtRename in [false, true] {
            let root = try await files { try makeDirectory() }
            defer { removeLater(root) }
            let store = BookSourceStore(directory: root)
            await store.waitUntilLoaded()
            store.sources = [makeSource("must-not-ack")]
            let sentinel = Data("owned destination must survive".utf8)
            try await files {
                if failAtRename {
                    try FileManager.default.createDirectory(at: libraryURL(root), withIntermediateDirectories: false)
                    try sentinel.write(to: libraryURL(root).appendingPathComponent("sentinel"))
                } else {
                    try FileManager.default.removeItem(at: root)
                    try sentinel.write(to: root)
                }
            }
            do {
                _ = try await store.saveForRenewalHandoff()
                Issue.record("a real filesystem failure returned a save receipt")
            } catch BookSourcePersistenceFailure.writeFailed(let stage, _) {
                switch stage {
                case .createTemporary: #expect(!failAtRename)
                case .replace: #expect(failAtRename)
                default: Issue.record("unexpected write stage \(stage)")
                }
            }
            let surviving = try await files {
                try Data(contentsOf: failAtRename ? libraryURL(root).appendingPathComponent("sentinel") : root)
            }
            #expect(surviving == sentinel)
            if failAtRename {
                let names = try await files { try FileManager.default.contentsOfDirectory(atPath: root.path) }
                #expect(names == ["book_sources.json"], "failed atomic replacement left a temporary file")
            }
        }
    }

    @Test("restore pause and cancellation before admission do not claim a save")
    func restoreAndPreAdmissionCancellationAreExplicit() async throws {
        let root = try await files { try makeDirectory() }
        defer { removeLater(root) }
        let store = BookSourceStore(directory: root)
        await store.waitUntilLoaded()
        store.sources = [makeSource("restore-pause")]
        _ = try store.beginValidatedRestoreWrites()
        do {
            _ = try await store.saveForRenewalHandoff()
            Issue.record("restore paused owner returned a save receipt")
        } catch BookSourcePersistenceFailure.restoreInProgress { }
        store.finishValidatedRestoreWrites()
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.saveForRenewalHandoff()
        }
        do {
            _ = try await cancelled.value
            Issue.record("pre-admission cancellation returned a receipt")
        } catch is CancellationError { }
        let exists = try await files { FileManager.default.fileExists(atPath: libraryURL(root).path) }
        #expect(!exists)
        let saved = try await store.saveForRenewalHandoff()
        #expect(saved.operation == .atomicWriteCompleted)
    }

    @Test("normal startup records actual bootstrap writes and never hides bootstrap failures")
    func bootstrapUsesTheSameConcreteWriterProof() async throws {
        let root = try await files { try makeDirectory() }
        defer { removeLater(root) }
        let source = makeSource("bootstrap")
        let package = try await files { try makePackage([source], at: root) }
        let store = BookSourceStore(directory: root, builtInPackage: package)
        let bootstrap = try await store.normalLoadReceiptForRenewalHandoff()
        let actual = try await files { try Data(contentsOf: libraryURL(root)) }
        #expect(bootstrap.operation == .normalBootstrapWrite)
        let actualHash = try await files { Data(SHA256.hash(data: actual)) }
        #expect(bootstrap.rawSHA256 == actualHash)
        #expect(bootstrap.rawByteCount == actual.count)
        #expect(bootstrap.sourceCount == 1)
        #expect(store.sources.map(\.id) == [source.id])
        let reopened = BookSourceStore(directory: root, builtInPackage: package)
        let read = try await reopened.normalLoadReceiptForRenewalHandoff()
        #expect(read.operation == .normalFileRead)
        #expect(read.rawSHA256 == bootstrap.rawSHA256)

        let invalidRoot = try await files { try makeDirectory() }
        defer { removeLater(invalidRoot) }
        let original = Data("[ \n ]".utf8)
        let invalidPackage = try await files {
            try original.write(to: libraryURL(invalidRoot))
            let package = try makePackage([source], at: invalidRoot)
            try Data("{}".utf8).write(to: package.manifestURL)
            return package
        }
        let invalid = BookSourceStore(directory: invalidRoot, builtInPackage: invalidPackage)
        do {
            _ = try await invalid.normalLoadReceiptForRenewalHandoff()
            Issue.record("a failed bootstrap was reported as a successful normal load")
        } catch BookSourcePersistenceFailure.bootstrapFailed { }
        do {
            _ = try await invalid.saveForRenewalHandoff()
            Issue.record("a failed bootstrap admitted an ambiguous memory checkpoint")
        } catch BookSourcePersistenceFailure.bootstrapFailed { }
        let preserved = try await files { try Data(contentsOf: libraryURL(invalidRoot)) }
        #expect(preserved == original)
    }

    @Test("admitted cancellation and later edits preserve the existing cross-store queue order")
    func admittedCancellationAndCoalescingKeepActualFileOrder() async throws {
        #if DEBUG
        let root = try await files { try makeDirectory() }
        let otherRoot = try await files { try makeDirectory() }
        defer { removeLater(root); removeLater(otherRoot) }
        let store = BookSourceStore(directory: root)
        let other = BookSourceStore(directory: otherRoot)
        await store.waitUntilLoaded()
        await other.waitUntilLoaded()
        let gate = PersistenceWorkerGate()
        await gate.waitUntilEntered()
        defer { gate.release() }

        let old = makeSource("before-checkpoint")
        let newer = makeSource("after-checkpoint")
        store.replaceSourcesFromSync([old]) // Original coalesced save, held.
        let admitted = try store.admitRenewalHandoffSave()
        let revision = store.mutationRevision
        admitted.cancel() // Already admitted: finish write and return its fact.
        let checkpointBytes = PersistenceWorkerCapture(url: libraryURL(root))
        defer { checkpointBytes.release() }
        store.replaceSourcesFromSync([newer]) // Must be queued after checkpoint.
        other.sources = [makeSource("other-owner")]
        let otherAdmitted = try other.admitRenewalHandoffSave()

        gate.release()
        let receipt = try await admitted.value
        let rawAtCheckpoint = try await checkpointBytes.value()
        #expect(receipt.operation == .atomicWriteCompleted)
        #expect(receipt.mutationRevision == revision)
        let checkpointHash = try await files { Data(SHA256.hash(data: rawAtCheckpoint)) }
        #expect(receipt.rawSHA256 == checkpointHash)
        let checkpointIDs = try await files { try JSONDecoder().decode([BookSource].self, from: rawAtCheckpoint).map(\.id) }
        #expect(checkpointIDs == [old.id])
        checkpointBytes.release()
        let otherReceipt = try await otherAdmitted.value
        await BookSourceStore.queuedWritesLanded()
        let freshOwner = BookSourceStore(directory: root)
        let final = try await freshOwner.normalLoadReceiptForRenewalHandoff()
        #expect(freshOwner.sources.map(\.id) == [newer.id])
        #expect(final.rawSHA256 != receipt.rawSHA256)
        #expect(otherReceipt.rawSHA256 != receipt.rawSHA256)
        let otherFresh = BookSourceStore(directory: otherRoot)
        let otherRead = try await otherFresh.normalLoadReceiptForRenewalHandoff()
        #expect(otherRead.rawSHA256 == otherReceipt.rawSHA256)
        #else
        Issue.record("this deterministic queue regression requires the DEBUG test observation")
        #endif
    }
}

// Only owned temporary roots are read. Heavy fixture/file operations use a real
// worker; helper construction on MainActor forms values and borrows snapshots.
private func files<T: Sendable>(_ action: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached(operation: action).value
}

private func makeDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BookSourceHandoff-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func libraryURL(_ root: URL) -> URL { root.appendingPathComponent("book_sources.json") }
private func makeSource(_ name: String) -> BookSource {
    BookSource(bookSourceUrl: "https://\(name).example.invalid", bookSourceName: "Owned \(name)")
}

/// Immutable ownership transfer of existing value-only source DTOs. This keeps
/// the test's large fixture construction off main without changing the app DTO.
private struct SourceFixture: @unchecked Sendable {
    let sources: [BookSource]
    init(_ sources: [BookSource]) { self.sources = sources }
}

private func makePackage(_ sources: [BookSource], at root: URL) throws -> BuiltInBookSourceBootstrap.Package {
    let data = try JSONEncoder().encode(sources)
    let package = BuiltInBookSourceBootstrap.Package(resourceURL: root.appendingPathComponent("owned-pack.json"),
        manifestURL: root.appendingPathComponent("owned-pack.manifest.json"))
    try data.write(to: package.resourceURL)
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let manifest = BuiltInBookSourceBootstrap.Manifest(schemaVersion: 1, version: "owned-handoff-v1", sha256: hash)
    try JSONEncoder().encode(manifest).write(to: package.manifestURL)
    return package
}

@MainActor private func removeLater(_ root: URL) {
    // The test has awaited every admitted write before scheduling cleanup on the
    // same existing queue; no arbitrary delay or main-thread filesystem work.
    #if DEBUG
    BookSourceStore.enqueuePersistenceTestJob {
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("owned temporary root cleanup failed: \(error)") }
    }
    #endif
}

private extension Data {
    init(hex: String) {
        self.init(stride(from: 0, to: hex.count, by: 2).map { offset in
            let first = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(first, offsetBy: 2)
            return UInt8(hex[first..<end], radix: 16)!
        })
    }
}

#if DEBUG
private final class PersistenceWorkerGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let entered: AsyncStream<Bool>
    init() {
        let pair = AsyncStream<Bool>.makeStream()
        entered = pair.stream
        let semaphore = self.semaphore
        BookSourceStore.enqueuePersistenceTestJob {
            dispatchPrecondition(condition: .notOnQueue(.main))
            pair.continuation.yield(true)
            pair.continuation.finish()
            semaphore.wait()
        }
    }
    func waitUntilEntered() async { for await _ in entered { return } }
    func release() { semaphore.signal() }
}

private final class PersistenceWorkerCapture: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let result: AsyncStream<Result<Data, Error>>
    init(url: URL) {
        let pair = AsyncStream<Result<Data, Error>>.makeStream()
        result = pair.stream
        let semaphore = self.semaphore
        BookSourceStore.enqueuePersistenceTestJob {
            dispatchPrecondition(condition: .notOnQueue(.main))
            pair.continuation.yield(Result { try Data(contentsOf: url) })
            pair.continuation.finish()
            semaphore.wait()
        }
    }
    func value() async throws -> Data {
        for await outcome in result { return try outcome.get() }
        throw CocoaError(.fileReadUnknown)
    }
    func release() { semaphore.signal() }
}
#endif
