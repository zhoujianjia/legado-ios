import Foundation

protocol ReadingPositionStore: AnyObject, Sendable {
    func save(_ position: CoreTextReadingPosition, for bookId: String) async
    func load(for bookId: String) async -> CoreTextReadingPosition?
    func loadSync(for bookId: String) -> CoreTextReadingPosition?
    func flush(for bookId: String) async
}

final class JSONFileReadingPositionStore: ReadingPositionStore {
    struct Submission: Sendable {
        enum Kind: Sendable, Equatable { case save, load, flush, syncReplacement }
        let sequence: UInt64
        let kind: Kind
        let bookId: String?
        let position: CoreTextReadingPosition?
    }

    // All instances, including the sync importer, use one admission order. The
    // actor never performs file work: a held writer cannot block new admissions.
    private static let fileJobs = ReadingPositionFileJobs()
    private let baseURL: URL
    private let writeData: @Sendable (Data, URL) throws -> Void
    private let onSave: @Sendable (CoreTextReadingPosition, String) -> Void
    private let onSubmit: @Sendable (Submission) -> Void

    init(
        baseURL: URL = StorageLocations.readingPosition,
        writeData: @escaping @Sendable (Data, URL) throws -> Void = {
            try $0.write(to: $1, options: .atomic)
        },
        onSave: @escaping @Sendable (CoreTextReadingPosition, String) -> Void = { position, bookId in
            // Debounce the cloud push: positions save on every page turn, so writing
            // each one directly would flood Firestore.
            Task { @MainActor in
                FirestoreSyncManager.shared.scheduleReadingPositionPush(position, for: bookId)
            }
        },
        // Small synchronous observation of actual admission, used by owned-file
        // regressions. Observers must not do I/O or wait for a worker.
        onSubmit: @escaping @Sendable (Submission) -> Void = { _ in }
    ) {
        self.baseURL = baseURL
        self.writeData = writeData
        self.onSave = onSave
        self.onSubmit = onSubmit
    }

    private func fileURL(for bookId: String) -> URL {
        baseURL.appendingPathComponent("\(bookId).json")
    }

    func save(_ position: CoreTextReadingPosition, for bookId: String) async {
        let job = await Self.fileJobs.submit(.save, bookId: bookId, position: position, onSubmit: onSubmit) { [self] in
            do {
                try writePosition(position, for: bookId)
                onSave(position, bookId)
                AppLogger.cache("[ProgressTrace][PositionStore] save bookId=\(bookId) spine=\(position.spineIndex) charOffset=\(position.charOffset)")
            } catch {
                AppLogger.error("[ProgressTrace][PositionStore] save failed", error: error, context: ["bookId": bookId])
            }
        }
        // Once admitted, a write completes even if its calling task is cancelled.
        // Dropping an already committed result must not drop its success signal.
        await job.value
    }

    func load(for bookId: String) async -> CoreTextReadingPosition? {
        let job = await Self.fileJobs.submit(.load, bookId: bookId, onSubmit: onSubmit) { [self] in
            loadSync(for: bookId)
        }
        return await job.value
    }

    // An immediate atomic-file snapshot, without waiting for admitted jobs. A
    // caller needing read-after-write must first await save/flush (TXT migration
    // does so). This entry must never synchronously wait on the worker from main.
    func loadSync(for bookId: String) -> CoreTextReadingPosition? {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL(for: bookId))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            AppLogger.cache("[ProgressTrace][PositionStore] load bookId=\(bookId) result=miss")
            return nil
        } catch {
            AppLogger.error("[ProgressTrace][PositionStore] read failed", error: error, context: ["bookId": bookId])
            return nil
        }
        do {
            let position = try JSONDecoder().decode(CoreTextReadingPosition.self, from: data)
            AppLogger.cache("[ProgressTrace][PositionStore] load bookId=\(bookId) spine=\(position.spineIndex) charOffset=\(position.charOffset)")
            return position
        } catch {
            // Keep the original bytes: a failed decode must not turn a recoverable
            // progress file into a newly saved chapter-start position here.
            AppLogger.error("[ProgressTrace][PositionStore] decode failed", error: error, context: ["bookId": bookId])
            return nil
        }
    }

    func flush(for bookId: String) async {
        let barrier = await Self.fileJobs.submit(.flush, bookId: bookId, onSubmit: onSubmit) { }
        await barrier.value
    }

    static func replacePositionsFromSync(_ positions: [String: CoreTextReadingPosition]) async {
        let store = JSONFileReadingPositionStore()
        await store.applySyncedPositions(positions)
    }

    // Same use case with the existing owned-root/writeData dependencies. This
    // keeps sync import and its failure/order regressions on the single writer.
    func applySyncedPositions(_ positions: [String: CoreTextReadingPosition]) async {
        let job = await Self.fileJobs.submit(.syncReplacement, onSubmit: onSubmit) { [self] in
            SourcePerfTrace.span("reader.position.syncReplacement", "main=\(Thread.isMainThread) positions=\(positions.count)") {
                for (bookId, position) in positions {
                    do {
                        try writePosition(position, for: bookId)
                    } catch {
                        AppLogger.error("[ProgressTrace][PositionStore] sync replacement failed", error: error, context: ["bookId": bookId])
                    }
                }
            }
        }
        // Preserve the existing no-onSave sync behavior to avoid a push loop.
        await job.value
    }

    /// Completion means the atomic write has finished. TXT index migration relies
    /// on save -> flush -> loadSync observing that file before removing its journal.
    private func writePosition(_ position: CoreTextReadingPosition, for bookId: String) throws {
        let data = try JSONEncoder().encode(position)
        try SourcePerfTrace.span("reader.position.save", "main=\(Thread.isMainThread) bytes=\(data.count)") {
            // A long-lived store may outlive a directory removed during restore or
            // maintenance. The writer owns restoring its directory on each write.
            try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
            try writeData(data, fileURL(for: bookId))
        }
    }
}

/// Orders actual admissions, not the creation of unrelated calling Tasks. Actor
/// scheduling is not FIFO; once accepted, each detached job awaits its predecessor
/// before doing synchronous I/O. No file work or synchronous worker wait happens
/// in this actor, so test-held writes leave admission and flush observation live.
private actor ReadingPositionFileJobs {
    private var tail: Task<Void, Never>?
    private var sequence: UInt64 = 0

    func submit<Result: Sendable>(
        _ kind: JSONFileReadingPositionStore.Submission.Kind,
        bookId: String? = nil,
        position: CoreTextReadingPosition? = nil,
        onSubmit: @Sendable (JSONFileReadingPositionStore.Submission) -> Void,
        operation: @escaping @Sendable () -> Result
    ) -> Task<Result, Never> {
        let previous = tail
        let job = Task.detached(priority: .utility) {
            if let previous { await previous.value }
            return operation()
        }
        tail = Task.detached(priority: .utility) { _ = await job.value }
        sequence &+= 1
        onSubmit(.init(sequence: sequence, kind: kind, bookId: bookId, position: position))
        return job
    }
}
