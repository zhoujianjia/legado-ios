import CryptoKit
import Darwin
import Foundation

enum ReadingPositionPersistenceFailure: Error, @unchecked Sendable {
    case unsupported, invalidRoot, invalidBookIdentity, invalidPosition, fileTooLarge, invalidFileType, changedDuringRead
    case io(Int32)
    case corruptJSON(Error)
    case writeFailed(Error)
}

/// An immutable observation from this file's actual bounded read or platform
/// atomic writer. It is a snapshot, not an assertion that later edits stopped,
/// that fsync completed, or that all other user data survived installation.
struct ReadingPositionPersistenceReceipt: Sendable, Equatable {
    enum Operation: Sendable, Equatable { case atomicWriteCompleted, existingFileRead }
    let bookId: String
    let position: CoreTextReadingPosition
    let rawSHA256: Data
    let rawByteCount: Int
    let operation: Operation
    fileprivate init(bookId: String, position: CoreTextReadingPosition, bytes: Data, operation: Operation) {
        self.bookId = bookId; self.position = position
        rawSHA256 = Data(SHA256.hash(data: bytes)); rawByteCount = bytes.count
        self.operation = operation
    }
}

protocol ReadingPositionStore: AnyObject, Sendable {
    func save(_ position: CoreTextReadingPosition, for bookId: String) async
    func load(for bookId: String) async -> CoreTextReadingPosition?
    func loadSync(for bookId: String) -> CoreTextReadingPosition?
    func flush(for bookId: String) async
    func saveChecked(_ position: CoreTextReadingPosition, for bookId: String) async throws -> ReadingPositionPersistenceReceipt
    /// Nil means the real open returned ENOENT; all other failures throw.
    func loadChecked(for bookId: String) async throws -> ReadingPositionPersistenceReceipt?
}

extension ReadingPositionStore {
    // Legacy mocks/adapters cannot turn a void save/flush or nil load into
    // evidence. Only owners with actual checked I/O implement these methods.
    func saveChecked(_ position: CoreTextReadingPosition, for bookId: String) async throws -> ReadingPositionPersistenceReceipt {
        throw ReadingPositionPersistenceFailure.unsupported
    }
    func loadChecked(for bookId: String) async throws -> ReadingPositionPersistenceReceipt? {
        throw ReadingPositionPersistenceFailure.unsupported
    }
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
    enum Limits {
        static let positionBytes = 4_096
        static let bookIdentityBytes = 128
    }
    // A custom legacy test/backend hook is not a platform atomic-write proof.
    private let writeData: (@Sendable (Data, URL) throws -> Void)?
    private let onSave: @Sendable (CoreTextReadingPosition, String) -> Void
    private let onSubmit: @Sendable (Submission) -> Void

    init(
        baseURL: URL = StorageLocations.readingPosition,
        writeData: (@Sendable (Data, URL) throws -> Void)? = nil,
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
        baseURL.appendingPathComponent("\(bookId).json", isDirectory: false)
    }

    func save(_ position: CoreTextReadingPosition, for bookId: String) async {
        let job = await Self.fileJobs.submit(.save, bookId: bookId, position: position, onSubmit: onSubmit) { [self] in
            do {
                _ = try writePosition(position, for: bookId)
                noteSuccessfulSave(position, bookId: bookId)
            } catch {
                AppLogger.error("[ProgressTrace][PositionStore] save failed", error: error, context: ["bookId": bookId])
            }
        }
        // Once admitted, a write completes even if its calling task is cancelled.
        // Dropping an already committed result must not drop its success signal.
        await job.value
    }

    func saveChecked(_ position: CoreTextReadingPosition, for bookId: String) async throws -> ReadingPositionPersistenceReceipt {
        try Task.checkCancellation()
        // An injected no-op must not manufacture a sealed atomic-write receipt.
        guard writeData == nil else { throw ReadingPositionPersistenceFailure.unsupported }
        let job = await Self.fileJobs.submit(.save, bookId: bookId, position: position, onSubmit: onSubmit) { [self] () -> Result<ReadingPositionPersistenceReceipt, ReadingPositionPersistenceFailure> in
            do {
                let bytes = try writePosition(position, for: bookId)
                noteSuccessfulSave(position, bookId: bookId)
                return .success(ReadingPositionPersistenceReceipt(bookId: bookId, position: position,
                    bytes: bytes, operation: .atomicWriteCompleted))
            } catch let failure as ReadingPositionPersistenceFailure { return .failure(failure) }
            catch { return .failure(.writeFailed(error)) }
        }
        // Once admitted, cancellation does not abandon the real write or its
        // onSave signal. No save-after-readback or new file owner is involved.
        return try await job.value.get()
    }

    func loadChecked(for bookId: String) async throws -> ReadingPositionPersistenceReceipt? {
        try Task.checkCancellation()
        let job = await Self.fileJobs.submit(.load, bookId: bookId, onSubmit: onSubmit) { [self] () -> Result<ReadingPositionPersistenceReceipt?, ReadingPositionPersistenceFailure> in
            do { return .success(try readPosition(for: bookId)) }
            catch let failure as ReadingPositionPersistenceFailure { return .failure(failure) }
            catch { return .failure(.corruptJSON(error)) }
        }
        return try await job.value.get()
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
        do {
            return try readPosition(for: bookId)?.position
        } catch ReadingPositionPersistenceFailure.corruptJSON(let error) {
            AppLogger.error("[ProgressTrace][PositionStore] decode failed", error: error, context: ["bookId": bookId])
            return nil
        } catch {
            // Keep the original bytes: a failed decode must not turn a recoverable
            // progress file into a newly saved chapter-start position here.
            AppLogger.error("[ProgressTrace][PositionStore] read failed", error: error, context: ["bookId": bookId])
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
                        _ = try writePosition(position, for: bookId)
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
    private func writePosition(_ position: CoreTextReadingPosition, for bookId: String) throws -> Data {
        precondition(!Thread.isMainThread)
        try validate(bookId: bookId); try validate(position: position)
        let data: Data
        do { data = try JSONEncoder().encode(position) }
        catch { throw ReadingPositionPersistenceFailure.writeFailed(error) }
        guard data.count <= Limits.positionBytes else { throw ReadingPositionPersistenceFailure.fileTooLarge }
        return try SourcePerfTrace.span("reader.position.save", "main=\(Thread.isMainThread) bytes=\(data.count)") {
            // A long-lived store may outlive a directory removed during restore or
            // maintenance. The writer owns restoring its directory on each write.
            do {
                try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
                if let writeData { try writeData(data, fileURL(for: bookId)) }
                else { try data.write(to: fileURL(for: bookId), options: .atomic) }
                return data
            } catch { throw ReadingPositionPersistenceFailure.writeFailed(error) }
        }
    }

    private func noteSuccessfulSave(_ position: CoreTextReadingPosition, bookId: String) {
        onSave(position, bookId)
        AppLogger.cache("[ProgressTrace][PositionStore] save bookId=\(bookId) spine=\(position.spineIndex) charOffset=\(position.charOffset)")
    }

    private func validate(bookId: String) throws {
        guard baseURL.isFileURL, baseURL.query == nil, baseURL.fragment == nil else { throw ReadingPositionPersistenceFailure.invalidRoot }
        guard !bookId.isEmpty, bookId != ".", bookId != "..", bookId.utf8.count <= Limits.bookIdentityBytes,
              !bookId.contains("/"), !bookId.contains("\\"), bookId.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ReadingPositionPersistenceFailure.invalidBookIdentity
        }
    }
    private func validate(position: CoreTextReadingPosition) throws {
        guard position.spineIndex >= 0, position.charOffset >= 0,
              (position.translationOffset.map { $0 >= 0 } ?? true) else { throw ReadingPositionPersistenceFailure.invalidPosition }
    }

    /// The legacy loadSync entry remains an immediate synchronous snapshot.
    /// New checked async calls always run this bounded primitive on fileJobs.
    private func readPosition(for bookId: String) throws -> ReadingPositionPersistenceReceipt? {
        try validate(bookId: bookId)
        let started = SourcePerfTrace.now
        var readCount = 0
        defer { SourcePerfTrace.record("reader.position.load", "main=\(Thread.isMainThread) bytes=\(readCount)", since: started, thresholdMs: 0) }
        let fd = Darwin.open(fileURL(for: bookId).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { AppLogger.cache("[ProgressTrace][PositionStore] load bookId=\(bookId) result=miss"); return nil }
            throw ReadingPositionPersistenceFailure.io(errno)
        }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0 else { throw ReadingPositionPersistenceFailure.io(errno) }
        guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw ReadingPositionPersistenceFailure.invalidFileType }
        guard before.st_size >= 0, before.st_size <= Int64(Limits.positionBytes) else { throw ReadingPositionPersistenceFailure.fileTooLarge }
        var data = Data(count: Int(before.st_size))
        try data.withUnsafeMutableBytes { buffer in
            while readCount < buffer.count {
                let count = pread(fd, buffer.baseAddress!.advanced(by: readCount), buffer.count - readCount, off_t(readCount))
                if count < 0 { if errno == EINTR { continue }; throw ReadingPositionPersistenceFailure.io(errno) }
                guard count > 0 else { throw ReadingPositionPersistenceFailure.changedDuringRead }
                readCount += count
            }
        }
        var after = stat()
        guard fstat(fd, &after) == 0 else { throw ReadingPositionPersistenceFailure.io(errno) }
        guard before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw ReadingPositionPersistenceFailure.changedDuringRead
        }
        let position: CoreTextReadingPosition
        do { position = try JSONDecoder().decode(CoreTextReadingPosition.self, from: data) }
        catch { throw ReadingPositionPersistenceFailure.corruptJSON(error) }
        try validate(position: position)
        AppLogger.cache("[ProgressTrace][PositionStore] load bookId=\(bookId) spine=\(position.spineIndex) charOffset=\(position.charOffset)")
        return ReadingPositionPersistenceReceipt(bookId: bookId, position: position, bytes: data, operation: .existingFileRead)
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
