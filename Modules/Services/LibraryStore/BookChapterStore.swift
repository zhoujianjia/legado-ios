import Foundation
import LegadoRuntime
import os

/// Every book's table of contents on this device: one file per book, beside the shelf.
///
/// legado keeps chapters in a table of their own (`BookChapterDao`). The bookshelf reads
/// books; a book's list is read when something needs it (`getChapterList(bookUrl)`), and
/// a table-of-contents refresh replaces that one book's rows (`delByBook` + `insert`).
/// This is that table. `books_meta.json` holds the books, each with a summary of its list
/// (`ReadingBook.totalChapterNum` / `latestChapterTitle`, as legado's `Book` carries), and
/// the lists live here.
///
/// Until 2026-10 every list sat inside `books_meta.json`, and every shelf save — each
/// progress tick of 聽書 among them — encoded all of them on the main thread. A tester's
/// 110 online books made the file 138 MB, and the save made as the app left the
/// foreground outlasted the 10-second scene-update watchdog (0x8BADF00D; build 113
/// MetricKit: `flushPendingMetadataSave` → `encodeBooksMetadata`).
///
/// A changed list is written by the next shelf save (`flush`), so a run of chapter-cache
/// marks costs one write of that one book.
final class BookChapterStore: @unchecked Sendable {
    struct RuntimeVariablesSnapshot: Sendable, Equatable {
        let bookID: UUID
        let chapterID: UUID
        let index: Int
        let url: String
        let revision: Int
        let variables: [String: String]?
    }
    private struct Entry {
        /// `nil`: the book has no list.
        var chapters: [OnlineChapterRef]?
        /// Changed since its file was last written. A changed entry is never evicted.
        var isDirty: Bool
        /// Advances on every change, so a flush cannot mark clean a change made while it wrote.
        var revision: Int
    }

    private struct State {
        var entries: [UUID: Entry] = [:]
        /// Clean entries holding a list, least recently used first.
        var recency: [UUID] = []
        var nextRevision = 0
        /// Coalesced ordinary mutations: at most one pending list and queue turn per book.
        var pendingOwnerChanges: [UUID: Entry] = [:]
        var ownerChangeQueued = Set<UUID>()
    }

    /// Lists kept in memory once read. A reader holds the one it is on; a pass over the
    /// whole shelf (the launch refresh, AI 整理) reads one book after another and must not
    /// end up holding them all, as the shelf file used to.
    private static let cachedListLimit = 8

    let directoryURL: URL
    /// Production injects BookStore's existing persistence queue. The old locked cache is
    /// the immediate read view; this queue alone owns the durable ordering and CAS state.
    private let persistenceQueue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let state = OSAllocatedUnfairLock(initialState: State())
    private var ownerState = State()
    private var committing = false

    init(directoryURL: URL, persistenceQueue: DispatchQueue) {
        self.directoryURL = directoryURL
        self.persistenceQueue = persistenceQueue
        persistenceQueue.setSpecific(key: queueKey, value: 1)
    }

    func fileURL(for bookID: UUID) -> URL {
        directoryURL.appendingPathComponent("\(bookID.uuidString).json")
    }

    /// The book's list, read from its file the first time it is asked for.
    func chapters(for bookID: UUID) -> [OnlineChapterRef]? {
        if let cached = state.withLock({ state -> Entry? in
            guard let entry = state.entries[bookID] else { return nil }
            Self.touch(bookID, entry: entry, in: &state)
            return entry
        }) {
            return cached.chapters
        }
        let loaded = readFile(for: bookID)
        return state.withLock { state in
            // Set while this read was in flight: that list is newer than the file.
            if let entry = state.entries[bookID] { return entry.chapters }
            state.nextRevision &+= 1
            let entry = Entry(chapters: loaded, isDirty: false, revision: state.nextRevision)
            state.entries[bookID] = entry
            Self.touch(bookID, entry: entry, in: &state)
            Self.evictLeastRecentlyUsed(in: &state)
            return loaded
        }
    }

    /// Whether the book's list is on disk, without reading it.
    func hasStoredList(for bookID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: bookID).path)
    }

    /// Whether the book has a list — in memory, possibly not yet written, or on disk —
    /// without reading it.
    func hasList(for bookID: UUID) -> Bool {
        if let entry = state.withLock({ $0.entries[bookID] }) { return entry.chapters != nil }
        return hasStoredList(for: bookID)
    }

    /// Replaces the book's list; an empty one removes it. Written by the next `flush`.
    func setChapters(_ chapters: [OnlineChapterRef], for bookID: UUID) {
        let list: [OnlineChapterRef]? = chapters.isEmpty ? nil : chapters
        state.withLock { state in
            if let entry = state.entries[bookID], entry.chapters == list { return }
            Self.markChanged(bookID, chapters: list, in: &state)
            enqueueOwnerChange(bookID, entry: state.entries[bookID]!, in: &state)
        }
    }

    /// Called on the existing library persistence queue, never from a view/main-thread read.
    /// The real stored chapter identity is retained instead of allocating a bridge UUID.
    func runtimeVariablesSnapshot(bookID: UUID, index: Int, url: String) throws -> RuntimeVariablesSnapshot? {
        dispatchPrecondition(condition: .onQueue(persistenceQueue))
        let entry = try ownerEntry(for: bookID)
        guard let chapters = entry.chapters, chapters.indices.contains(index),
              chapters[index].index == index, chapters[index].url.utf8.elementsEqual(url.utf8) else { return nil }
        let chapter = chapters[index]
        return RuntimeVariablesSnapshot(bookID: bookID, chapterID: chapter.id, index: index, url: url,
            revision: entry.revision, variables: chapter.runtimeVariables)
    }

    /// Ordered with all ordinary changes on the same existing persistence queue. Changes
    /// made by the UI during I/O publish immediately in its derived view and enqueue after
    /// this transaction. They cannot mutate this owner's candidate or be overwritten by
    /// its publication. Success acknowledges this ordered durable mutation, not a promise
    /// that a later overlapping App edit cannot replace it.
    func compareRuntimeVariables(expected: RuntimeVariablesSnapshot, variables: [String: String]?,
                                 claimCommit: @Sendable () -> Bool = { true }, beforeWrite: () throws -> Void = {}) throws -> Bool {
        dispatchPrecondition(condition: .onQueue(persistenceQueue))
        let entry = try ownerEntry(for: expected.bookID)
        guard entry.revision == expected.revision, var candidate = entry.chapters,
              candidate.indices.contains(expected.index), candidate[expected.index].id == expected.chapterID,
              candidate[expected.index].url.utf8.elementsEqual(expected.url.utf8),
              candidate[expected.index].runtimeVariables == expected.variables else { return false }
        if variables == expected.variables, !entry.isDirty { return true }
        candidate[expected.index].runtimeVariables = variables
        committing = true
        defer { committing = false }
        try write(candidate, for: expected.bookID, beforeWrite: beforeWrite, claimCommit: claimCommit)
        let revision = variables == expected.variables ? entry.revision : state.withLock { state in
            state.nextRevision &+= 1
            return state.nextRevision
        }
        let published = Entry(chapters: candidate, isDirty: false, revision: revision)
        ownerState.entries[expected.bookID] = published
        Self.touch(expected.bookID, entry: published, in: &ownerState)
        Self.evictLeastRecentlyUsed(in: &ownerState)
        state.withLock { state in
            // A subsequent ordinary mutation already owns the UI view. Its queued owner
            // operation follows this commit and must retain its exact chapter metadata.
            guard state.entries[expected.bookID]?.revision == expected.revision else { return }
            state.entries[expected.bookID] = published
            Self.touch(expected.bookID, entry: published, in: &state)
            Self.evictLeastRecentlyUsed(in: &state)
        }
        return true
    }

    struct CachedFileUpdate: Sendable {
        let index: Int
        let chapterID: UUID
        let url: String
        let filename: String
    }

    /// One existing chapter-file transaction for the verified saved prefix. Candidate
    /// construction/encoding stays on the library writer; a UI mutation queued later
    /// retains the same ordering and cannot be overwritten by late publication.
    func publishCachedFiles(bookID: UUID, updates: [CachedFileUpdate], beforeWrite: () throws -> Void) throws -> Bool {
        dispatchPrecondition(condition: .onQueue(persistenceQueue))
        guard updates.count <= 32, Set(updates.map(\.index)).count == updates.count else {
            throw LegadoRuntimeError(code: "INVALID_STATE_REQUEST", message: "Cached chapter publication exceeds its grant")
        }
        let entry = try ownerEntry(for: bookID)
        guard var candidate = entry.chapters else { throw LegadoRuntimeError(code: "STATE_CONFLICT", message: "The App TOC is missing") }
        for value in updates {
            guard candidate.indices.contains(value.index), candidate[value.index].index == value.index,
                  candidate[value.index].id == value.chapterID, candidate[value.index].url.utf8.elementsEqual(value.url.utf8) else {
                throw LegadoRuntimeError(code: "STATE_CONFLICT", message: "The cached chapter no longer has its granted TOC identity")
            }
        }
        let changed = updates.contains { candidate[$0.index].cachedFilename != $0.filename }
        if !changed && !entry.isDirty { try beforeWrite(); return false }
        for value in updates { candidate[value.index].cachedFilename = value.filename }
        committing = true; defer { committing = false }
        try SourcePerfTrace.span("library.chapters.cachePublication", "chapters=\(candidate.count) saved=\(updates.count) main=\(Thread.isMainThread)") {
            _ = try write(candidate, for: bookID, beforeWrite: beforeWrite)
        }
        let revision = state.withLock { state in state.nextRevision &+= 1; return state.nextRevision }
        let published = Entry(chapters: candidate, isDirty: false, revision: revision)
        ownerState.entries[bookID] = published
        Self.touch(bookID, entry: published, in: &ownerState); Self.evictLeastRecentlyUsed(in: &ownerState)
        state.withLock { state in
            guard state.entries[bookID]?.revision == entry.revision else { return }
            state.entries[bookID] = published
            Self.touch(bookID, entry: published, in: &state); Self.evictLeastRecentlyUsed(in: &state)
        }
        return changed
    }

    /// The host reads the queue-owned list, never a partially published UI mutation.
    func ownerChapters(for bookID: UUID) throws -> [OnlineChapterRef]? {
        dispatchPrecondition(condition: .onQueue(persistenceQueue))
        return try ownerEntry(for: bookID).chapters
    }

    /// The book is gone: its list goes with it at the next `flush`.
    func removeChapters(for bookID: UUID) {
        state.withLock { state in
            Self.markChanged(bookID, chapters: nil, in: &state)
            enqueueOwnerChange(bookID, entry: state.entries[bookID]!, in: &state)
        }
    }

    /// Removes the list of every book not in `bookIDs`. Pass only a shelf known to be
    /// complete, never the result of a load that may have failed.
    func removeChapters(notIn bookIDs: Set<UUID>) {
        var stored: [String] = []
        if FileManager.default.fileExists(atPath: directoryURL.path) {
            do {
                stored = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
            } catch {
                AppLogger.error("Tables of contents could not be listed", error: error)
            }
        }
        let storedIDs = stored.compactMap { name -> UUID? in
            guard name.hasSuffix(".json") else { return nil }
            return UUID(uuidString: String(name.dropLast(".json".count)))
        }
        let cachedIDs = state.withLock { Array($0.entries.keys) }
        let orphans = Set(storedIDs + cachedIDs).subtracting(bookIDs)
        guard !orphans.isEmpty else { return }
        AppLogger.cache("目錄：移除已不在書架與閱讀紀錄中的書的目錄", context: ["count": orphans.count])
        for bookID in orphans {
            removeChapters(for: bookID)
        }
    }

    var hasUnwrittenChanges: Bool {
        state.withLock { $0.entries.values.contains(where: \.isDirty) }
    }

    /// Writes every changed list and deletes the removed ones. A list that cannot be
    /// written stays changed, and the next flush tries again.
    func flush() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            do { try flushReportingFailure() }
            catch { /* Failed entries remain dirty for the existing save path. */ }
        } else {
            persistenceQueue.async { [self] in flush() }
        }
    }

    /// Owner callers that promise durable state must observe the actual write failure.
    /// A multi-book flush can have partial success; it is not a cross-book transaction.
    func flushReportingFailure() throws {
        dispatchPrecondition(condition: .onQueue(persistenceQueue))
        try flush(ownerState.entries.filter { $0.value.isDirty })
    }

    /// Flush only the explicitly bound book. This does not publish another dirty book as
    /// durable or turn a logged background failure into a successful host transaction.
    func flushReportingFailure(for bookID: UUID) throws {
        dispatchPrecondition(condition: .onQueue(persistenceQueue))
        guard let entry = ownerState.entries[bookID], entry.isDirty else { return }
        try flush([bookID: entry])
    }

    private func flush(_ pending: [UUID: Entry]) throws {
        guard !pending.isEmpty else { return }
        // Bytes are part of the line: the field's disk-write exceptions (≈1 GB within a minute
        // of launch) were this flush rewriting every list, which time alone did not show.
        var bytes = 0
        var firstFailure: Error?
        SourcePerfTrace.span("library.chapters.write", "books=\(pending.count) bytes=\(bytes) main=\(Thread.isMainThread)", thresholdMs: 5) {
            var written: [UUID: Int] = [:]
            for (bookID, entry) in pending {
                do {
                    bytes += try write(entry.chapters, for: bookID)
                    written[bookID] = entry.revision
                } catch {
                    if firstFailure == nil { firstFailure = error }
                    AppLogger.error(
                        "Table of contents could not be saved",
                        error: error,
                        context: ["book": bookID.uuidString, "chapters": entry.chapters?.count ?? 0]
                    )
                }
            }
            for (bookID, revision) in written {
                guard var entry = ownerState.entries[bookID], entry.revision == revision else { continue }
                entry.isDirty = false
                ownerState.entries[bookID] = entry
                Self.touch(bookID, entry: entry, in: &ownerState)
            }
            Self.evictLeastRecentlyUsed(in: &ownerState)
            state.withLock { state in
                for (bookID, revision) in written {
                    guard var entry = state.entries[bookID], entry.revision == revision else { continue }
                    entry.isDirty = false
                    state.entries[bookID] = entry
                    Self.touch(bookID, entry: entry, in: &state)
                }
                Self.evictLeastRecentlyUsed(in: &state)
            }
        }
        if let firstFailure { throw firstFailure }
    }

    // MARK: - Files

    /// Called inside the short view lock. Enqueueing is nonblocking; no encoding or disk
    /// operation runs under that lock. Both caches retain the existing clean-list limit;
    /// dirty entries, as before, stay pinned until the normal flush succeeds.
    private func enqueueOwnerChange(_ bookID: UUID, entry: Entry, in state: inout State) {
        if DispatchQueue.getSpecific(key: queueKey) != nil, !committing {
            state.pendingOwnerChanges.removeValue(forKey: bookID)
            ownerState.entries[bookID] = entry
            ownerState.recency.removeAll { $0 == bookID }
        } else {
            state.pendingOwnerChanges[bookID] = entry
            guard state.ownerChangeQueued.insert(bookID).inserted else { return }
            persistenceQueue.async { [self] in
                guard let entry = self.state.withLock({ state -> Entry? in
                    state.ownerChangeQueued.remove(bookID)
                    return state.pendingOwnerChanges.removeValue(forKey: bookID)
                }) else { return }
                ownerState.entries[bookID] = entry
                ownerState.recency.removeAll { $0 == bookID }
            }
        }
    }

    private func ownerEntry(for bookID: UUID) throws -> Entry {
        if let entry = ownerState.entries[bookID] {
            Self.touch(bookID, entry: entry, in: &ownerState)
            return entry
        }
        let loaded = try readFileReportingFailure(for: bookID)
        let entry = state.withLock { state -> Entry in
            if let existing = state.entries[bookID], !existing.isDirty, existing.chapters == loaded { return existing }
            state.nextRevision &+= 1
            let entry = Entry(chapters: loaded, isDirty: false, revision: state.nextRevision)
            if state.entries[bookID]?.isDirty != true {
                state.entries[bookID] = entry
                Self.touch(bookID, entry: entry, in: &state)
                Self.evictLeastRecentlyUsed(in: &state)
            }
            return entry
        }
        ownerState.entries[bookID] = entry
        Self.touch(bookID, entry: entry, in: &ownerState)
        Self.evictLeastRecentlyUsed(in: &ownerState)
        return entry
    }

    private func readFile(for bookID: UUID) -> [OnlineChapterRef]? {
        do {
            return try readFileReportingFailure(for: bookID)
        } catch {
            // Read as "no list": the book's next table-of-contents refresh writes a new one.
            AppLogger.error(
                "Table of contents could not be read",
                error: error,
                context: ["book": bookID.uuidString]
            )
            return nil
        }
    }

    /// New owner contracts must distinguish a missing list from unreadable/corrupt bytes.
    /// Only the legacy UI reader above keeps its historical log-and-empty behavior.
    private func readFileReportingFailure(for bookID: UUID) throws -> [OnlineChapterRef]? {
        let url = fileURL(for: bookID)
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileReadNoSuchFile.rawValue {
            return nil
        }
        return try SourcePerfTrace.span("library.chapters.read", "bytes=\(data.count) main=\(Thread.isMainThread)", thresholdMs: 5) {
            try JSONDecoder().decode([OnlineChapterRef].self, from: data)
        }
    }

    /// Returns the bytes written.
    private func write(_ chapters: [OnlineChapterRef]?, for bookID: UUID, beforeWrite: () throws -> Void = {},
                       claimCommit: @Sendable () -> Bool = { true }) throws -> Int {
        try beforeWrite()
        let url = fileURL(for: bookID)
        guard let chapters else {
            if FileManager.default.fileExists(atPath: url.path) {
                guard claimCommit() else { throw CancellationError() }
                try FileManager.default.removeItem(at: url)
            }
            return 0
        }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(chapters)
        try beforeWrite()
        guard claimCommit() else { throw CancellationError() }
        try data.write(to: url, options: .atomic)
        return data.count
    }

    // MARK: - Cache

    private static func markChanged(_ bookID: UUID, chapters: [OnlineChapterRef]?, in state: inout State) {
        state.nextRevision &+= 1
        state.entries[bookID] = Entry(chapters: chapters, isDirty: true, revision: state.nextRevision)
        state.recency.removeAll { $0 == bookID }
    }

    private static func touch(_ bookID: UUID, entry: Entry, in state: inout State) {
        guard !entry.isDirty, entry.chapters != nil else { return }
        state.recency.removeAll { $0 == bookID }
        state.recency.append(bookID)
    }

    private static func evictLeastRecentlyUsed(in state: inout State) {
        while state.recency.count > cachedListLimit {
            state.entries.removeValue(forKey: state.recency.removeFirst())
        }
    }
}
