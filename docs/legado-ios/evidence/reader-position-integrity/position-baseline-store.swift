import Foundation

protocol ReadingPositionStore: AnyObject, Sendable {
    func save(_ position: CoreTextReadingPosition, for bookId: String) async
    func load(for bookId: String) async -> CoreTextReadingPosition?
    func loadSync(for bookId: String) -> CoreTextReadingPosition?
    func flush(for bookId: String) async
}

final class JSONFileReadingPositionStore: ReadingPositionStore {
    private let baseURL: URL
    private let writeData: @Sendable (Data, URL) throws -> Void
    private let onSave: @Sendable (CoreTextReadingPosition, String) -> Void

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
        }
    ) {
        self.baseURL = baseURL
        self.writeData = writeData
        self.onSave = onSave
    }

    private func fileURL(for bookId: String) -> URL {
        baseURL.appendingPathComponent("\(bookId).json")
    }

    func save(_ position: CoreTextReadingPosition, for bookId: String) async {
        do {
            try writePosition(position, for: bookId)
            onSave(position, bookId)
            AppLogger.cache("[ProgressTrace][PositionStore] save bookId=\(bookId) spine=\(position.spineIndex) charOffset=\(position.charOffset)")
        } catch {
            AppLogger.error("[ProgressTrace][PositionStore] save failed", error: error, context: ["bookId": bookId])
        }
    }

    func load(for bookId: String) async -> CoreTextReadingPosition? {
        loadSync(for: bookId)
    }

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
    }

    static func replacePositionsFromSync(_ positions: [String: CoreTextReadingPosition]) {
        let store = JSONFileReadingPositionStore()
        for (bookId, position) in positions {
            do {
                try store.writePosition(position, for: bookId)
            } catch {
                AppLogger.error("[ProgressTrace][PositionStore] sync replacement failed", error: error, context: ["bookId": bookId])
            }
        }
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
