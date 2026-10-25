import CryptoKit
import Foundation
import LegadoRuntime
import Testing
@testable import yuedu_app

/// Gate only the actual existing persistence worker. Main observes an async event,
/// never waits on the semaphore, and no timer is used to settle writer ordering.
private final class BookHandoffWriteGate: @unchecked Sendable {
    let entered: AsyncStream<Bool>
    private let event: AsyncStream<Bool>.Continuation
    private let release = DispatchSemaphore(value: 0)
    init() { let pair = AsyncStream<Bool>.makeStream(); entered = pair.stream; event = pair.continuation }
    func wait() throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        event.yield(true)
        guard release.wait(timeout: .now() + 30) == .success else { throw CocoaError(.userCancelled) }
    }
    func open() { release.signal() }
    func finish() { event.finish() }
}

@Suite("Real two-file BookStore renewal handoff", .serialized)
@MainActor
struct BookStoreMetadataHandoffTests {
    private struct Fixture {
        let root: URL
        let shelfURL: URL
        let readingURL: URL
        let store: BookStore
        let shelf: ReadingBook
        let reading: ReadingBook
        let source: UUID
    }
    private func fixture() async throws -> Fixture {
        let source = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BookHandoff-" + UUID().uuidString, isDirectory: true)
        let shelfURL = root.appendingPathComponent("books_meta.json")
        let readingURL = shelfURL.deletingPathExtension().appendingPathExtension("reading.json")
        func book(_ title: String, onShelf: Bool) -> ReadingBook {
            var book = ReadingBook(title: title, author: "Owned fixture", source: "https://book-handoff.invalid/" + title, contentFilename: "")
            book.isOnline = true; book.bookSourceId = source; book.bookInfoURL = book.source; book.tocURL = book.source + "/toc"
            book.isInBookshelf = onShelf; book.runtimeVariables = ["original": title]
            return book
        }
        let a = book("shelf", onShelf: true), b = book("reading", onShelf: false)
        try await Task.detached {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode([a]).write(to: shelfURL, options: .atomic)
            try encoder.encode([b]).write(to: readingURL, options: .atomic)
        }.value
        let store = try await BookStore.openForRenewalHandoff(metadataFileURL: shelfURL)
        return .init(root: root, shelfURL: shelfURL, readingURL: readingURL, store: store, shelf: a, reading: b, source: source)
    }
    private func cleanup(_ f: Fixture) async throws {
        await BookStore.queuedWritesLanded()
        try await Task.detached {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.root.path)
            let chapters = f.shelfURL.deletingPathExtension().appendingPathExtension("chapters")
            if FileManager.default.fileExists(atPath: chapters.path) {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: chapters.path)
            }
            try FileManager.default.removeItem(at: f.root)
        }.value
    }
    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let f = try await fixture()
        do { try await body(f); try await cleanup(f) }
        catch { let original = error; do { try await cleanup(f) } catch { Issue.record(error) }; throw original }
    }
    private static func bytes(_ url: URL) async throws -> Data { try await Task.detached { try Data(contentsOf: url) }.value }
    private static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func file(_ receipt: BookMetadataPersistenceReceipt, _ role: BookMetadataPersistenceReceipt.Role) throws -> BookMetadataPersistenceReceipt.File {
        try #require(receipt.files.first { $0.role == role })
    }

    @Test("real writer and the same normal reader report each original raw file exactly")
    func actualSaveAndNormalReopenBindBothRawFiles() async throws {
        try await withFixture { f in
            let first = try await f.store.normalLoadReceiptForRenewalHandoff()
            #expect(first.phase == .normalLoad && first.files.map(\.operation) == [.read, .read])
            var edited = f.shelf; edited.title = "updated title"
            f.store.books = [edited]
            let saved = try await f.store.saveForRenewalHandoff()
            #expect(saved.phase == .save && saved.localRevision == f.store.mutationRevision)
            #expect(try file(saved, .shelf).operation == .written)
            #expect(try file(saved, .reading).operation == .unchanged)
            let shelf = try await Self.bytes(f.shelfURL), reading = try await Self.bytes(f.readingURL)
            #expect(try file(saved, .shelf).rawSHA256 == Self.sha(shelf))
            #expect(try file(saved, .shelf).rawByteCount == shelf.count)
            #expect(try file(saved, .reading).rawSHA256 == Self.sha(reading))
            #expect(try file(saved, .reading).rawByteCount == reading.count)
            // The first normal-load receipt remains the original read, despite later writes.
            #expect(try await f.store.normalLoadReceiptForRenewalHandoff() == first)
            let reopened = try await BookStore.openForRenewalHandoff(metadataFileURL: f.shelfURL)
            let loaded = try await reopened.normalLoadReceiptForRenewalHandoff()
            #expect(loaded.files.map(\.operation) == [.read, .read])
            #expect(loaded.files.map(\.rawSHA256) == saved.files.map(\.rawSHA256))
            #expect(reopened.readingBook(id: f.shelf.id)?.title == edited.title)
            #expect(reopened.readingBook(id: f.reading.id)?.runtimeVariables == f.reading.runtimeVariables)
        }
    }

    @Test("unchanged saves really CAS-read both files and reject an external reading-byte change")
    func unchangedSaveCannotUseOnlyCachedBytes() async throws {
        try await withFixture { f in
            let shelf = try await Self.bytes(f.shelfURL), before = try await Self.bytes(f.readingURL)
            let saved = try await f.store.saveForRenewalHandoff()
            #expect(saved.files.map(\.operation) == [.unchanged, .unchanged])
            let external = before + Data("\n".utf8) // semantically identical, different actual bytes
            try await Task.detached { try external.write(to: f.readingURL, options: .atomic) }.value
            do { _ = try await f.store.saveForRenewalHandoff(); Issue.record("Cached unchanged bytes were accepted") }
            catch let error as BookMetadataPersistenceFailure {
                #expect(error.code == .externalChange)
                #expect(error.partialFiles.first { $0.role == .reading }?.rawSHA256 == Self.sha(external))
                #expect(error.partialFiles.allSatisfy { $0.operation != .written })
            }
            #expect(try await Self.bytes(f.shelfURL) == shelf)
            #expect(try await Self.bytes(f.readingURL) == external)
            let reopened = try await BookStore.openForRenewalHandoff(metadataFileURL: f.shelfURL)
            let read = try await reopened.normalLoadReceiptForRenewalHandoff()
            #expect(try file(read, .reading).rawSHA256 == Self.sha(external))
            #expect(try file(read, .reading).rawByteCount == external.count)
        }
    }

    @Test("only real ENOENT is absent; unreadable or corrupt normal loads preserve orphan chapters")
    func missingAndFailedNormalLoadsRemainDifferent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BookLoad-" + UUID().uuidString, isDirectory: true)
        try await Task.detached { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }.value
        do {
            let url = root.appendingPathComponent("books_meta.json")
            let missing = try await BookStore.openForRenewalHandoff(metadataFileURL: url)
            let absent = try await missing.normalLoadReceiptForRenewalHandoff()
            #expect(absent.files.map(\.operation) == [.absent, .absent])
            #expect(absent.files.allSatisfy { $0.rawSHA256 == nil && $0.rawByteCount == 0 })
            let corrupt = Data("not JSON".utf8)
            let chapters = url.deletingPathExtension().appendingPathExtension("chapters")
            let orphan = chapters.appendingPathComponent(UUID().uuidString + ".json")
            try await Task.detached {
                try FileManager.default.createDirectory(at: chapters, withIntermediateDirectories: true)
                try Data("[]".utf8).write(to: orphan)
                try corrupt.write(to: url)
            }.value
            // Use the same normal initializer, but retain this failed owner for strict API checks.
            let failed = await Task.detached { BookStore(metadataFileURL: url) }.value
            do { _ = try await failed.normalLoadReceiptForRenewalHandoff(); Issue.record("Corrupt normal read became a receipt") }
            catch let error as BookMetadataPersistenceFailure { #expect(error.code == .normalLoadFailed) }
            do { _ = try await failed.saveForRenewalHandoff(); Issue.record("Failed load became a checkpoint") }
            catch let error as BookMetadataPersistenceFailure { #expect(error.code == .normalLoadFailed || error.code == .writesBlocked) }
            #expect(try await Self.bytes(url) == corrupt)
            #expect(try await Self.bytes(orphan) == Data("[]".utf8))
            let parentFile = root.appendingPathComponent("not-directory")
            try await Task.detached { try Data("owned".utf8).write(to: parentFile) }.value
            let bad = await Task.detached { BookStore(metadataFileURL: parentFile.appendingPathComponent("metadata.json")) }.value
            do { _ = try await bad.normalLoadReceiptForRenewalHandoff(); Issue.record("ENOTDIR was reported absent") }
            catch let error as BookMetadataPersistenceFailure { #expect(error.code == .normalLoadFailed) }
            await BookStore.queuedWritesLanded()
            try await Task.detached { try FileManager.default.removeItem(at: root) }.value
        } catch {
            let original = error
            do { try await Task.detached { try FileManager.default.removeItem(at: root) }.value } catch { Issue.record(error) }
            throw original
        }
    }

    @Test("real atomic-write failure has no success receipt, leaves old files, and permits a later retry")
    func realWriteFailureRetainsOldFilesAndRetry() async throws {
        try await withFixture { f in
            let shelf = try await Self.bytes(f.shelfURL), reading = try await Self.bytes(f.readingURL)
            var edited = f.shelf; edited.title = "unwritten"
            f.store.books = [edited]
            let job = try f.store.admitRenewalHandoffSave { role in
                if role == .shelf { try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.root.path) }
            }
            do { _ = try await job.value; Issue.record("Actual readonly directory produced success") }
            catch let error as BookMetadataPersistenceFailure {
                #expect(error.code == .io && error.underlying != nil)
                #expect(error.partialFiles.allSatisfy { $0.operation == .unchanged })
            }
            try await Task.detached { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.root.path) }.value
            #expect(try await Self.bytes(f.shelfURL) == shelf)
            #expect(try await Self.bytes(f.readingURL) == reading)
            let retry = try await f.store.saveForRenewalHandoff()
            #expect(try file(retry, .shelf).operation == .written)
            let reopened = try await BookStore.openForRenewalHandoff(metadataFileURL: f.shelfURL)
            #expect(reopened.readingBook(id: edited.id)?.title == edited.title)
        }
    }

    @Test("partial two-file promotion preserves the reading copy until the shelf is durable")
    func partialSaveReportsRealFilesAndRetainsProtectedCopy() async throws {
        try await withFixture { f in
            let oldReading = try await Self.bytes(f.readingURL)
            // Promote the original reading record and remove the old shelf record.
            // A failure in final pruning must retain the reading copy of this same UUID.
            f.store.books = [f.reading]
            let job = try f.store.admitRenewalHandoffSave { role in
                if role == .reading { try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.root.path) }
            }
            var partial: [BookMetadataPersistenceReceipt.File] = []
            do { _ = try await job.value; Issue.record("Partial two-file save returned a complete receipt") }
            catch let error as BookMetadataPersistenceFailure { #expect(error.code == .io); partial = error.partialFiles }
            try await Task.detached { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.root.path) }.value
            let shelf = try await Self.bytes(f.shelfURL)
            #expect(partial.first { $0.role == .shelf }?.operation == .written)
            #expect(partial.first { $0.role == .shelf }?.rawSHA256 == Self.sha(shelf))
            #expect(partial.first { $0.role == .reading }?.rawSHA256 == Self.sha(oldReading))
            #expect(try await Self.bytes(f.readingURL) == oldReading)
            let decoded = try JSONDecoder().decode([ReadingBook].self, from: shelf)
            #expect(decoded.map(\.id) == [f.reading.id])
            let retry = try await f.store.saveForRenewalHandoff()
            #expect(try file(retry, .shelf).operation == .unchanged)
            #expect(try file(retry, .reading).operation == .written)
            #expect(try JSONDecoder().decode([ReadingBook].self, from: await Self.bytes(f.readingURL)).isEmpty)
        }
    }

    @Test("queued cancellation and a restore pause cannot be acknowledged as persisted metadata")
    func cancellationAndRestorePauseCannotAcknowledgeAWrite() async throws {
        try await withFixture { f in
            let shelf = try await Self.bytes(f.shelfURL), reading = try await Self.bytes(f.readingURL)
            var edited = f.shelf; edited.title = "must remain pending"
            f.store.books = [edited]
            let gate = BookHandoffWriteGate(); defer { gate.open(); gate.finish() }
            let job = try f.store.admitRenewalHandoffSave { role in if role == .shelf { try gate.wait() } }
            var entered = gate.entered.makeAsyncIterator(); #expect(await entered.next() == true)
            #expect(Thread.isMainThread)
            job.cancel(); gate.open()
            do { _ = try await job.value; Issue.record("Cancelled pre-write job received a receipt") }
            catch let error as BookMetadataPersistenceFailure { #expect(error.code == .cancelled) }
            #expect(try await Self.bytes(f.shelfURL) == shelf)
            #expect(try await Self.bytes(f.readingURL) == reading)
            _ = try f.store.beginValidatedRestoreWrites()
            do { _ = try await f.store.saveForRenewalHandoff(); Issue.record("Restore pause accepted a checkpoint") }
            catch let error as BookMetadataPersistenceFailure { #expect(error.code == .restoreInProgress) }
            f.store.finishValidatedRestoreWrites()
            _ = try await f.store.saveForRenewalHandoff()
        }
    }

    @Test("an older checked snapshot uses the actual variable owner and cannot erase a successful runtime CAS")
    func checkedWriterPreservesAcceptedRuntimeVariables() async throws {
        try await withFixture { f in
            _ = try #require(await f.store.prepareOriginalRuntimeBookSnapshot(id: f.shelf.id, sourceID: f.source, bookURL: f.shelf.source))
            let expected = try await f.store.originalRuntimeBookVariableSnapshot(bookID: f.shelf.id, sourceID: f.source, bookURL: f.shelf.source)
            let gate = BookHandoffWriteGate(); defer { gate.open(); gate.finish() }
            let cas = Task {
                try await f.store.compareOriginalRuntimeBook(expected: expected, expectedView: expected.book,
                    variables: ["accepted": "survives checkpoint"], deadline: Date().addingTimeInterval(30),
                    cancellation: OriginalRuntimeCommitCancellation(), beforeWrite: { try gate.wait() }, validateGrant: {})
            }
            var entered = gate.entered.makeAsyncIterator(); #expect(await entered.next() == true)
            let older = try f.store.admitRenewalHandoffSave()
            gate.open()
            #expect(try await cas.value)
            do { _ = try await older.value }
            catch let error as BookMetadataPersistenceFailure { #expect(error.code == .staleSnapshot) }
            let final = try await f.store.saveForRenewalHandoff()
            let raw = try await Self.bytes(f.shelfURL)
            #expect(try file(final, .shelf).rawSHA256 == Self.sha(raw))
            let reopened = try await BookStore.openForRenewalHandoff(metadataFileURL: f.shelfURL)
            #expect(reopened.readingBook(id: f.shelf.id)?.runtimeVariables == ["accepted": "survives checkpoint"])
        }
    }

    @Test("a failed real chapter flush cannot be replaced by the old swallowed-error save wrapper")
    func realChapterFlushFailurePreventsMetadataReceipt() async throws {
        try await withFixture { f in
            let beforeShelf = try await Self.bytes(f.shelfURL), beforeReading = try await Self.bytes(f.readingURL)
            let chapterDirectory = f.shelfURL.deletingPathExtension().appendingPathExtension("chapters")
            try await Task.detached {
                // A regular file at the existing chapter directory makes the actual
                // BookChapterStore.createDirectory/write fail deterministically.
                try Data("owned blocker".utf8).write(to: chapterDirectory)
            }.value
            var edited = f.shelf
            edited.onlineChapters = [.init(index: 0, title: "owned", url: f.shelf.source + "/chapter")]
            f.store.books = [edited]
            do { _ = try await f.store.saveForRenewalHandoff(); Issue.record("Failed chapter flush was treated as durable") }
            catch let error as BookMetadataPersistenceFailure { #expect(error.code == .io) }
            #expect(try await Self.bytes(f.shelfURL) == beforeShelf)
            #expect(try await Self.bytes(f.readingURL) == beforeReading)
            try await Task.detached { try FileManager.default.removeItem(at: chapterDirectory) }.value
            _ = try await f.store.saveForRenewalHandoff()
            let reopened = try await BookStore.openForRenewalHandoff(metadataFileURL: f.shelfURL)
            #expect(reopened.chapters(for: f.shelf.id)?.count == 1)
        }
        try await legacyInlineChaptersKeepTheirOnlyCopyUntilActualFlush(blockReading: false)
        try await legacyInlineChaptersKeepTheirOnlyCopyUntilActualFlush(blockReading: true)
        try await ordinaryInlineSaveCannotEraseItsOnlyTOCCopy()
    }

    /// Same eighth method: real legacy inline-TOC migration, not a mocked save callback.
    private func legacyInlineChaptersKeepTheirOnlyCopyUntilActualFlush(blockReading: Bool) async throws {
        let suite = "BookHandoffLegacy-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let url = root.appendingPathComponent("books_meta.json")
        let chapterDirectory = url.deletingPathExtension().appendingPathExtension("chapters")
        let readingURL = url.deletingPathExtension().appendingPathExtension("reading.json")
        var book = ReadingBook(title: "Legacy owned inline", author: "Fixture", source: "https://legacy-book-handoff.invalid/book", contentFilename: "")
        book.isOnline = true; book.bookSourceId = UUID(); book.bookInfoURL = book.source
        var reading = ReadingBook(title: "Legacy reading-only", author: "Fixture", source: "https://legacy-book-handoff.invalid/reading", contentFilename: "")
        reading.isOnline = true; reading.bookSourceId = book.bookSourceId; reading.bookInfoURL = reading.source
        reading.isInBookshelf = false; reading.runtimeVariables = ["reading": "only legacy copy"]
        let chapters = [OnlineChapterRef(index: 0, title: "only inline copy", url: book.source + "/chapter", runtimeVariables: ["retained": "owned"])]
        let raw = try await Task.detached {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if blockReading { try FileManager.default.createDirectory(at: readingURL, withIntermediateDirectories: false) }
            else { try Data("block real chapter directory".utf8).write(to: chapterDirectory) }
            return try JSONEncoder().encode([BookHandoffLegacyInlineRecord(book: book, chapters: chapters),
                                            BookHandoffLegacyInlineRecord(book: reading, chapters: [])])
        }.value
        defaults.set(raw, forKey: "yd_books_meta")
        do {
            let failed = await Task.detached { BookStore(metadataFileURL: url, legacyMetadataDefaults: defaults) }.value
            // This barrier is only for test observation. Actual file/key assertions and
            // the new owner's same-normal-reader receipt establish the outcome below.
            await BookStore.queuedWritesLanded()
            #expect(defaults.data(forKey: "yd_books_meta") == raw)
            let shelfExists = await Task.detached { FileManager.default.fileExists(atPath: url.path) }.value
            #expect(!shelfExists) // even the old automatic whole-shelf save stayed protected
            do { _ = try await failed.normalLoadReceiptForRenewalHandoff(); Issue.record("Failed migration got normal-load receipt") }
            catch let error as BookMetadataPersistenceFailure { #expect(error.code == .normalLoadFailed) }
            #expect(failed.chapters(for: book.id)?.first?.id == chapters[0].id)
            try await Task.detached { try FileManager.default.removeItem(at: blockReading ? readingURL : chapterDirectory) }.value
            let retry = await Task.detached { BookStore(metadataFileURL: url, legacyMetadataDefaults: defaults) }.value
            await BookStore.queuedWritesLanded()
            #expect(defaults.data(forKey: "yd_books_meta") == nil)
            let actualShelf = try await Self.bytes(url)
            #expect(try JSONDecoder().decode([ReadingBook].self, from: actualShelf).map(\.id) == [book.id])
            let reopened = try await BookStore.openForRenewalHandoff(metadataFileURL: url, legacyMetadataDefaults: defaults)
            let receipt = try await reopened.normalLoadReceiptForRenewalHandoff()
            #expect(try file(receipt, .shelf).rawSHA256 == Self.sha(actualShelf))
            #expect(reopened.chapters(for: book.id)?.first?.id == chapters[0].id)
            #expect(reopened.chapters(for: book.id)?.first?.runtimeVariables == ["retained": "owned"])
            let actualReading = try await Self.bytes(readingURL)
            #expect(try JSONDecoder().decode([ReadingBook].self, from: actualReading).map(\.id) == [reading.id])
            #expect(reopened.readingBook(id: reading.id)?.runtimeVariables == ["reading": "only legacy copy"])
            #expect(try file(receipt, .reading).rawSHA256 == Self.sha(actualReading))
            // Keep this real owner alive through its queued migration publication.
            #expect(retry.readingBook(id: book.id)?.title == book.title)
            await BookStore.queuedWritesLanded()
            try await Task.detached { try FileManager.default.removeItem(at: root) }.value
            defaults.removePersistentDomain(forName: suite)
        } catch {
            let original = error
            await BookStore.queuedWritesLanded()
            do { try await Task.detached { try FileManager.default.removeItem(at: root) }.value } catch { Issue.record(error) }
            defaults.removePersistentDomain(forName: suite)
            throw original
        }
    }
    /// Actual normal-file inline TOC, including the ordinary automatic save path.
    private func ordinaryInlineSaveCannotEraseItsOnlyTOCCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BookHandoffInline-" + UUID().uuidString, isDirectory: true)
        let url = root.appendingPathComponent("books_meta.json")
        let chapterDirectory = url.deletingPathExtension().appendingPathExtension("chapters")
        var book = ReadingBook(title: "Normal file only TOC", author: "Fixture", source: "https://inline-book-handoff.invalid/book", contentFilename: "")
        book.isOnline = true; book.bookSourceId = UUID(); book.bookInfoURL = book.source
        let chapters = [OnlineChapterRef(index: 0, title: "must survive ordinary flush failure", url: book.source + "/chapter")]
        let raw = try await Task.detached {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("owned real chapter blocker".utf8).write(to: chapterDirectory)
            let raw = try JSONEncoder().encode([BookHandoffLegacyInlineRecord(book: book, chapters: chapters)])
            try raw.write(to: url, options: .atomic)
            return raw
        }.value
        do {
            let store = await Task.detached { BookStore(metadataFileURL: url, legacyMetadataDefaults: nil) }.value
            await BookStore.queuedWritesLanded()
            #expect(try await Self.bytes(url) == raw) // ordinary automatic save must stop
            let originalRead = try await store.normalLoadReceiptForRenewalHandoff()
            #expect(try file(originalRead, .shelf).rawSHA256 == Self.sha(raw))
            do { _ = try await store.saveForRenewalHandoff(); Issue.record("Actual chapter failure accepted a checked save") }
            catch let error as BookMetadataPersistenceFailure { #expect(error.code == .io) }
            #expect(try await Self.bytes(url) == raw)
            try await Task.detached { try FileManager.default.removeItem(at: chapterDirectory) }.value
            _ = try await store.saveForRenewalHandoff()
            let reopened = try await BookStore.openForRenewalHandoff(metadataFileURL: url, legacyMetadataDefaults: nil)
            #expect(reopened.chapters(for: book.id)?.first?.id == chapters[0].id)
            await BookStore.queuedWritesLanded()
            try await Task.detached { try FileManager.default.removeItem(at: root) }.value
        } catch {
            let original = error
            await BookStore.queuedWritesLanded()
            do { try await Task.detached { try FileManager.default.removeItem(at: root) }.value } catch { Issue.record(error) }
            throw original
        }
    }
}

private struct BookHandoffLegacyInlineRecord: Encodable {
    private enum Key: String, CodingKey { case onlineChapters }
    let book: ReadingBook
    let chapters: [OnlineChapterRef]
    func encode(to encoder: Encoder) throws {
        try book.encode(to: encoder)
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(chapters, forKey: .onlineChapters)
    }
}
