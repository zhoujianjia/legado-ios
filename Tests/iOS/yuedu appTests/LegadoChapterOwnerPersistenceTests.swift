import Foundation
import Testing
@testable import yuedu_app

@Suite("Original chapter owner durable writes", .serialized)
struct LegadoChapterOwnerPersistenceTests {
    private func onOwner<T: Sendable>(_ queue: DispatchQueue, _ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    @Test("an overlapping App mutation is ordered after durable CAS and is never overwritten or falsely acknowledged")
    func concurrentChapterMutationUsesOnePersistenceOwner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record("Owned fixture cleanup failed: \(error)") } }
        let queue = DispatchQueue(label: "test.original.chapter.order")
        let owner = BookChapterStore(directoryURL: root, persistenceQueue: queue); let book = UUID()
        let chapter = OnlineChapterRef(index: 0, title: "Before", url: "https://owned.invalid/before")
        owner.setChapters([chapter], for: book)
        try await onOwner(queue) { try owner.flushReportingFailure(for: book) }
        let snapshot = try #require(try await onOwner(queue) { try owner.runtimeVariablesSnapshot(bookID: book, index: 0, url: chapter.url) })
        var replacement = chapter
        replacement.url = "https://owned.invalid/new"
        replacement.title = "New TOC"
        replacement.runtimeVariables = ["app": "later"]
        let later = replacement
        let accepted = try await onOwner(queue) {
            var injected = false
            return try owner.compareRuntimeVariables(expected: snapshot, variables: ["rule": "accepted"]) {
                guard !injected else { return }; injected = true
                // Same deterministic interleaving as a main-thread edit during atomic I/O.
                // setChapters only publishes/enqueues; it never waits for this owner.
                owner.setChapters([later], for: book)
                #expect(owner.chapters(for: book) == [later])
            }
        }
        #expect(accepted)
        // CAS did commit its own durable value before the overlapping edit's queued turn.
        let durable = try JSONDecoder().decode([OnlineChapterRef].self, from: Data(contentsOf: owner.fileURL(for: book)))
        #expect(durable.first?.url == chapter.url)
        #expect(durable.first?.runtimeVariables == ["rule": "accepted"])
        #expect(owner.chapters(for: book) == [later])
        #expect(try await onOwner(queue) { try !owner.compareRuntimeVariables(expected: snapshot, variables: ["stale": "rejected"]) })
        try await onOwner(queue) { try owner.flushReportingFailure(for: book) }
        #expect(BookChapterStore(directoryURL: root, persistenceQueue: queue).chapters(for: book) == [later])
        #expect(!owner.hasUnwrittenChanges)
    }

    @Test("chapter variable CAS preserves its real identity, rejects stale snapshots and never publishes failed I/O")
    func chapterVariableCasIsDurableAndKeepsFailedWritesInvisible() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path); try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Owned fixture cleanup failed: \(error)") }
        }
        let queue = DispatchQueue(label: "test.original.chapter.cas")
        let owner = BookChapterStore(directoryURL: root, persistenceQueue: queue); let book = UUID()
        let chapter = OnlineChapterRef(index: 0, title: "Owned", url: "https://owned.invalid/chapter")
        owner.setChapters([chapter], for: book); try await onOwner(queue) { try owner.flushReportingFailure(for: book) }
        let snapshot = try #require(try await onOwner(queue) { try owner.runtimeVariablesSnapshot(bookID: book, index: 0, url: chapter.url) })
        let beforeGate = try Data(contentsOf: owner.fileURL(for: book))
        await #expect(throws: CancellationError.self) {
            _ = try await onOwner(queue) {
                try owner.compareRuntimeVariables(expected: snapshot, variables: ["sealed": "forbidden"], claimCommit: { false })
            }
        }
        #expect(try Data(contentsOf: owner.fileURL(for: book)) == beforeGate)
        #expect(try await onOwner(queue) { try owner.compareRuntimeVariables(expected: snapshot, variables: ["large": String(repeating: "x", count: 10000)]) })
        #expect(owner.chapters(for: book)?.first?.id == chapter.id)
        #expect(!owner.hasUnwrittenChanges)
        #expect(try await onOwner(queue) { try !owner.compareRuntimeVariables(expected: snapshot, variables: ["stale": "lost"]) })
        let before = try Data(contentsOf: owner.fileURL(for: book))
        let current = try #require(try await onOwner(queue) { try owner.runtimeVariablesSnapshot(bookID: book, index: 0, url: chapter.url) })
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        await #expect(throws: (any Error).self) { try await onOwner(queue) { try owner.compareRuntimeVariables(expected: current, variables: ["bad": "invisible"]) } }
        #expect(try await onOwner(queue) { try owner.runtimeVariablesSnapshot(bookID: book, index: 0, url: chapter.url) } == current)
        #expect(try Data(contentsOf: owner.fileURL(for: book)) == before)
        #expect(BookChapterStore(directoryURL: root, persistenceQueue: queue).chapters(for: book)?.first?.runtimeVariables == current.variables)
    }
    @Test("a strict owner flush reports a real failed atomic write and retains old disk and dirty state")
    func strictFlushFailurePreservesPreviousFileAndCanRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path); try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Owned fixture cleanup failed: \(error)") }
        }
        let queue = DispatchQueue(label: "test.original.chapter.failure")
        let owner = BookChapterStore(directoryURL: root, persistenceQueue: queue); let book = UUID()
        let old = OnlineChapterRef(index: 0, title: "Old", url: "https://owned.invalid/old")
        owner.setChapters([old], for: book); try await onOwner(queue) { try owner.flushReportingFailure(for: book) }
        let path = owner.fileURL(for: book); let before = try Data(contentsOf: path)
        var next = old; next.runtimeVariables = ["owned": "new"]
        owner.setChapters([next], for: book)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        await #expect(throws: (any Error).self) { try await onOwner(queue) { try owner.flushReportingFailure(for: book) } }
        #expect(owner.hasUnwrittenChanges)
        #expect(try Data(contentsOf: path) == before)
        #expect(BookChapterStore(directoryURL: root, persistenceQueue: queue).chapters(for: book) == [old])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try await onOwner(queue) { try owner.flushReportingFailure(for: book) }
        #expect(!owner.hasUnwrittenChanges)
        #expect(BookChapterStore(directoryURL: root, persistenceQueue: queue).chapters(for: book) == [next])
    }

    @Test("a bound book flush never claims another dirty book and unchanged records do not rewrite")
    func strictFlushTargetsOnlyTheBoundBook() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record("Owned fixture cleanup failed: \(error)") } }
        let queue = DispatchQueue(label: "test.original.chapter.target")
        let owner = BookChapterStore(directoryURL: root, persistenceQueue: queue); let a = UUID(); let b = UUID()
        let chapter = OnlineChapterRef(index: 0, title: "Owned", url: "https://owned.invalid/chapter")
        owner.setChapters([chapter], for: a); owner.setChapters([chapter], for: b)
        try await onOwner(queue) { try owner.flushReportingFailure(for: a) }
        #expect(owner.hasUnwrittenChanges)
        #expect(FileManager.default.fileExists(atPath: owner.fileURL(for: a).path))
        #expect(!FileManager.default.fileExists(atPath: owner.fileURL(for: b).path))
        let timestamp = try FileManager.default.attributesOfItem(atPath: owner.fileURL(for: a).path)[.modificationDate] as? Date
        owner.setChapters([chapter], for: a); try await onOwner(queue) { try owner.flushReportingFailure(for: a) }
        #expect(try FileManager.default.attributesOfItem(atPath: owner.fileURL(for: a).path)[.modificationDate] as? Date == timestamp)
        try await onOwner(queue) { try owner.flushReportingFailure(for: b) }; #expect(!owner.hasUnwrittenChanges)
    }
}
