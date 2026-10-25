import CryptoKit
import Darwin
import Foundation
import ReadiumZIPFoundation
import zlib

/// Controlled input -> private static snapshot -> checked ZIP -> owned files ->
/// the existing whole-application verifier. No archive metadata grants trust.
enum SelfRenewalIPAUnpacker {
    typealias Validator = SelfRenewalIPAArchiveValidator
    enum Failure: Error, Sendable, Equatable {
        case invalidInput, inputChanged, inputRead, stagingIO, stagingChanged, cleanupFailed
        case readBudget, operationInProgress, archiveLibraryMismatch, malformedCompression(String)
        case actualSizeMismatch(String), crcMismatch(String)
    }
    enum OperationEvent: Sendable, Equatable {
        case archiveEntered, exclusiveFinished, scopeClosing, scopeDrained, stagingWillCleanup, stagingCleaned
    }
    typealias OperationObserver = @Sendable (OperationEvent) async -> Void
    struct Materials: Sendable, Equatable {
        let application: SelfRenewalApplicationMaterialVerifier.Materials
        let archiveSHA256: Data
        let archiveBytes: Int
        let expandedBytes: Int
        let entryCount: Int
        let applicationPath: String
        var appleSigningAuthorityEstablished: Bool { false }
        var accountIdentityEstablished: Bool { false }
        var deviceEligibilityEstablished: Bool { false }
        var replacementAuthorized: Bool { false }
        fileprivate init(application: SelfRenewalApplicationMaterialVerifier.Materials,
            snapshot: Snapshot, plan: Validator.Plan) {
            self.application = application; archiveSHA256 = snapshot.digest
            archiveBytes = snapshot.byteCount; expandedBytes = plan.expandedBytes
            entryCount = plan.entries.count; applicationPath = plan.applicationPath
        }
    }

    /// The returned value contains real sealed verifier results. Staging is
    /// deleted before return; no mutable path is exported as an installation
    /// capability. A later signing/replacement step must bind its own bytes.
    nonisolated static func verify(ipa input: URL, codeAnchors: [Data], profileAnchors: [Data],
        at date: Date) async throws -> Materials {
        try await withOwnedApplication(ipa: input, codeAnchors: codeAnchors, profileAnchors: profileAnchors, at: date) { scope in
            Materials(application: scope.original, snapshot: scope.snapshot, plan: scope.plan)
        }
    }

    /// Snapshot the real, presently verified installed bundle for the next
    /// renewal. The URL exists only inside this drained scope; it carries no
    /// signing or installation authority and enters the ordinary IPA verifier
    /// and Coordinator.prepare path again. No imported/previous IPA is reused.
    nonisolated static func withCurrentApplicationArchive<T: Sendable>(application root: URL,
        codeAnchors: [Data], profileAnchors: [Data], at date: Date,
        operation: @escaping @Sendable (URL) async throws -> T) async throws -> T {
        let worker = Task.detached(priority: .utility) {
            let started = SourcePerfTrace.now
            var total = 0
            defer { SourcePerfTrace.record("renewal.ipa.current-bundle", "bytes=\(total) main=\(Thread.isMainThread)", since: started, thresholdMs: 0) }
            // Closed phase names and numeric facts only; none of these records
            // carry a path, identity or error. Beginnings also locate a span
            // that has not yet returned through its cancellation/cleanup path.
            let phases = (initialMaterials: "initial-materials", currentArchive: "current-archive",
                capturedVerification: "captured-verification", currentRecheck: "current-recheck",
                operation: "operation", cleanup: "cleanup")
            var phase = phases.initialMaterials
            var phaseStarted = SourcePerfTrace.now
            var phaseActive = true
            var fileCount = 0
            func recordPhase(ended: Bool, completed: Bool) {
                SourcePerfTrace.record("renewal.ipa.current-phase",
                    "phase=\(phase) ended=\(ended) completed=\(completed) files=\(fileCount) bytes=\(total) main=\(Thread.isMainThread)",
                    since: phaseStarted, thresholdMs: 0)
            }
            func endPhase(completed: Bool) {
                guard phaseActive else { return }
                recordPhase(ended: true, completed: completed)
                phaseActive = false
            }
            func beginPhase(_ next: String) {
                phase = next; phaseStarted = SourcePerfTrace.now; phaseActive = true
                recordPhase(ended: false, completed: false)
            }
            recordPhase(ended: false, completed: false)
            defer { endPhase(completed: false) }
            try Task.checkCancellation()
            let original = try await SelfRenewalApplicationMaterialVerifier.read(unpackedApplication: root,
                codeAnchors: codeAnchors, profileAnchors: profileAnchors, at: date)
            let inventory = original.resources.executableMaterials.inventory
            fileCount = inventory.files.count
            let entries = inventory.files.count + inventory.directories.count + 2
            guard entries <= Validator.Limits.entries,
                  inventory.directories.count + 2 <= Validator.Limits.directories,
                  inventory.files.allSatisfy({ $0.byteCount <= Int64(Validator.Limits.compressedEntryBytes) }),
                  date.timeIntervalSince1970 >= 315_532_800, date.timeIntervalSince1970 < 4_354_819_200 else { throw Failure.readBudget }
            total = Int(inventory.declaredFileBytes)
            endPhase(completed: true)
            beginPhase(phases.currentArchive)
            let tree = try OwnedTree()
            do {
                let name = "current-" + UUID().uuidString.lowercased() + ".ipa"
                let url = tree.url.appendingPathComponent(name)
                let prefix = "Payload/Current.app"
                let directoryPaths = ["Payload/", prefix + "/"] + inventory.directories.map { prefix + "/" + $0 + "/" }
                let outputPaths = directoryPaths + inventory.files.map { prefix + "/" + $0.relativePath }
                let writer = try StoredArchiveWriter(tree: tree, name: name, paths: outputPaths,
                    expandedBytes: total, date: date)
                for path in directoryPaths {
                    try Task.checkCancellation()
                    try writer.append(path: path, directory: true, byteCount: 0, provider: { _, _ in Data() })
                }
                let executables = Set(inventory.codeFiles.map(\.file.relativePath))
                var hashes: [String: Data] = [:]
                for fact in inventory.files {
                    try Task.checkCancellation(); try tree.validateNames()
                    // Bind every file, including original resource-rule omissions.
                    // withOwnedFile rejects links and identity/size/mtime changes.
                    hashes[fact.relativePath] = try currentHash(root: root, fact: fact)
                    try writer.append(path: prefix + "/" + fact.relativePath, directory: false,
                        byteCount: Int(fact.byteCount), executable: executables.contains(fact.relativePath),
                        provider: { offset, count in
                            try currentPart(root: root, fact: fact, offset: offset, count: count)
                        })
                    guard hashes[fact.relativePath] == (try currentHash(root: root, fact: fact)) else { throw Failure.inputChanged }
                }
                try writer.finish()
                endPhase(completed: true)
                beginPhase(phases.capturedVerification)
                // Compare the exact captured bytes too: a transient source edit
                // during an archive callback cannot hide behind unchanged seals.
                let expectedHashes = hashes
                let captured = try await withOwnedApplication(ipa: url, codeAnchors: codeAnchors, profileAnchors: profileAnchors, at: date) { scope in
                    guard try await scope.hashes() == expectedHashes else { throw Failure.inputChanged }
                    return scope.original
                }
                guard captured == original else { throw Failure.inputChanged }
                endPhase(completed: true)
                beginPhase(phases.currentRecheck)
                let current = try await SelfRenewalApplicationMaterialVerifier.read(unpackedApplication: root,
                    codeAnchors: codeAnchors, profileAnchors: profileAnchors, at: date)
                guard current == original else { throw Failure.inputChanged }
                for fact in inventory.files {
                    guard hashes[fact.relativePath] == (try currentHash(root: root, fact: fact)) else { throw Failure.inputChanged }
                }
                try Task.checkCancellation(); try tree.validateNames()
                endPhase(completed: true)
                beginPhase(phases.operation)
                let result = try await operation(url)
                endPhase(completed: true)
                beginPhase(phases.cleanup)
                try Task.checkCancellation(); try tree.validateNames(); try tree.cleanup()
                endPhase(completed: true)
                return result
            } catch {
                endPhase(completed: false)
                beginPhase(phases.cleanup)
                do {
                    try tree.cleanup()
                    endPhase(completed: true)
                } catch {
                    endPhase(completed: false)
                    AppLogger.error("Current bundle IPA cleanup failed", error: error)
                }
                throw error
            }
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private static func currentPart(root: URL, fact: SelfRenewalMaterialInventory.FileFact, offset: Int, count: Int) throws -> Data {
        guard offset >= 0, count >= 0, count <= Validator.Limits.chunkBytes,
              Int64(offset) <= fact.byteCount, Int64(count) <= fact.byteCount - Int64(offset) else { throw Failure.inputRead }
        return try SelfRenewalMachOSignatureReader.withOwnedFile(root: root, fact: fact, maximumReadBytes: count) { read in
            try read(.init(offset: UInt64(offset), byteCount: count))
        }
    }
    private static func currentHash(root: URL, fact: SelfRenewalMaterialInventory.FileFact) throws -> Data {
        try SelfRenewalMachOSignatureReader.withOwnedFile(root: root, fact: fact, maximumReadBytes: Int(fact.byteCount)) { read in
            var hash = SHA256(); var offset = 0
            while offset < Int(fact.byteCount) {
                try Task.checkCancellation()
                let count = min(Validator.Limits.chunkBytes, Int(fact.byteCount) - offset)
                hash.update(data: try read(.init(offset: UInt64(offset), byteCount: count))); offset += count
            }
            return Data(hash.finalize())
        }
    }

    nonisolated static func withOwnedApplication<T: Sendable>(ipa input: URL, codeAnchors: [Data], profileAnchors: [Data],
        at date: Date, observer: OperationObserver? = nil, operation: @escaping @Sendable (OwnedApplication) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            let started = SourcePerfTrace.now
            let tree = try OwnedTree()
            var archiveBytes = 0
            var expandedBytes = 0
            var controlledScope: OwnedApplication?
            defer {
                SourcePerfTrace.record("renewal.ipa.unpack", "bytes=\(archiveBytes) expandedBytes=\(expandedBytes) main=\(Thread.isMainThread)",
                    since: started, thresholdMs: 0)
            }
            do {
                let snapshot = try tree.copySnapshot(from: input)
                defer { snapshot.close() }
                archiveBytes = snapshot.byteCount
                let plan = try Validator.inspect(snapshot)
                // Require complete raw-deflate consumption, actual size and CRC
                // before creating any extracted file. Readium's extraction API
                // returns a CRC but does not itself compare it with the entry.
                try validatePayloads(snapshot, plan: plan)
                let archive = try await Archive(url: nil, dataSource: SnapshotSource(snapshot: snapshot),
                    defaultReadChunkSize: Validator.Limits.chunkBytes, pathEncoding: .utf8)
                let entries = try await archive.entries()
                guard entries.count == plan.entries.count else { throw Failure.archiveLibraryMismatch }
                for (entry, fact) in zip(entries, plan.entries) {
                    guard entry.path(using: .utf8) == fact.path,
                          entry.type == (fact.directory ? .directory : .file),
                          entry.compressedSize == UInt64(fact.compressedBytes),
                          entry.uncompressedSize == UInt64(fact.expandedBytes),
                          entry.checksum == fact.checksum else { throw Failure.archiveLibraryMismatch }
                }
                for (entry, fact) in zip(entries, plan.entries) {
                    try Task.checkCancellation()
                    if fact.directory { try tree.directory(fact.path); continue }
                    let sink = try Sink(descriptor: tree.file(fact.path), expected: fact.expandedBytes)
                    do {
                        let crc = try await archive.extract(entry, bufferSize: Validator.Limits.chunkBytes,
                            skipCRC32: false, consumer: { try await sink.consume($0) })
                        guard crc == fact.checksum else { throw Failure.crcMismatch(fact.path) }
                        try await sink.finish(path: fact.path)
                    } catch {
                        await sink.abort()
                        if error is CancellationError { throw CancellationError() }
                        if let typed = error as? Failure { throw typed }
                        throw Failure.malformedCompression(fact.path)
                    }
                    expandedBytes += fact.expandedBytes
                }
                try tree.validateNames()
                let root = tree.url.appendingPathComponent(plan.applicationPath, isDirectory: true)
                let application = try await SelfRenewalApplicationMaterialVerifier.read(unpackedApplication: root,
                    codeAnchors: codeAnchors, profileAnchors: profileAnchors, at: date)
                try Task.checkCancellation()
                try tree.validateNames()
                let scope = OwnedApplication(tree: tree, snapshot: snapshot, plan: plan, original: application, observer: observer)
                controlledScope = scope
                let result = try await operation(scope)
                await scope.invalidateAndDrain()
                try Task.checkCancellation()
                try tree.validateNames()
                await observer?(.stagingWillCleanup)
                try tree.cleanup()
                await observer?(.stagingCleaned)
                return result
            } catch {
                if let scope = controlledScope { await scope.invalidateAndDrain() }
                await observer?(.stagingWillCleanup)
                do { try tree.cleanup(); await observer?(.stagingCleaned) }
                catch { AppLogger.error("Owned IPA staging cleanup failed", error: error) }
                throw error
            }
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    /// A scoped capability, made only after the original whole app was read and
    /// verified. Every operation fails after the enclosing scope is cleaned.
    /// Trusted package orchestration uses it sequentially; it is never a URL API.
    actor OwnedApplication {
        nonisolated let original: SelfRenewalApplicationMaterialVerifier.Materials
        nonisolated let originalArchiveSHA256: Data
        nonisolated let originalArchiveBytes: Int
        fileprivate nonisolated let snapshot: Snapshot
        fileprivate nonisolated let plan: Validator.Plan
        private let tree: OwnedTree
        private var facts: [String: SelfRenewalMaterialInventory.FileFact]
        private var expandedBytes: Int
        private let observer: OperationObserver?
        private var closing = false
        private var busy = false
        private var cancelRunning: (@Sendable () -> Void)?
        private var drainWaiters: [CheckedContinuation<Void, Never>] = []
        fileprivate init(tree: OwnedTree, snapshot: Snapshot, plan: Validator.Plan,
            original: SelfRenewalApplicationMaterialVerifier.Materials, observer: OperationObserver?) {
            self.observer = observer
            self.tree = tree; self.snapshot = snapshot; self.plan = plan; self.original = original
            originalArchiveSHA256 = snapshot.digest; originalArchiveBytes = snapshot.byteCount
            facts = Dictionary(uniqueKeysWithValues: original.resources.executableMaterials.inventory.files.map { ($0.relativePath, $0) })
            expandedBytes = plan.expandedBytes
        }
        /// Closing is ordered BEFORE tree cleanup. The actor serializes all
        /// synchronous I/O. An asynchronous verifier/writer holds exclusive
        /// ownership until its linked worker actually finishes, including when
        /// the callback launches an escaping child and then returns/throws.
        fileprivate func invalidateAndDrain() async {
            let firstClose = !closing
            closing = true
            cancelRunning?()
            if firstClose { await observer?(.scopeClosing) }
            if busy { await withCheckedContinuation { drainWaiters.append($0) } }
            if firstClose { await observer?(.scopeDrained) }
        }
        private func check() throws {
            precondition(!Thread.isMainThread, "Owned application I/O must stay off main")
            try Task.checkCancellation()
            guard !closing else { throw Failure.stagingChanged }
            guard !busy else { throw Failure.operationInProgress }
        }
        private func finishExclusive() {
            cancelRunning = nil; busy = false
            let waiters = drainWaiters; drainWaiters.removeAll()
            for continuation in waiters { continuation.resume() }
        }
        private var root: URL { tree.url.appendingPathComponent(plan.applicationPath, isDirectory: true) }
        func read(_ path: String, maximumBytes: Int) throws -> Data {
            try check()
            guard let fact = facts[path], fact.byteCount <= Int64(maximumBytes), maximumBytes <= SelfRenewalControlledMachOSigner.Limits.fileBytes else { throw Failure.readBudget }
            return try SelfRenewalMachOSignatureReader.withOwnedFile(root: root, fact: fact, maximumReadBytes: maximumBytes) { read in
                var result = Data(); result.reserveCapacity(Int(fact.byteCount))
                while result.count < Int(fact.byteCount) {
                    try Task.checkCancellation()
                    result.append(try read(.init(offset: UInt64(result.count), byteCount: min(Validator.Limits.chunkBytes, Int(fact.byteCount) - result.count))))
                }
                return result
            }
        }
        private nonisolated static func part(root: URL, fact: SelfRenewalMaterialInventory.FileFact,
            at offset: Int, count: Int) throws -> Data {
            try Task.checkCancellation()
            guard offset >= 0, count >= 0, count <= Validator.Limits.chunkBytes,
                  Int64(offset) <= fact.byteCount, Int64(count) <= fact.byteCount - Int64(offset) else { throw Failure.inputRead }
            return try SelfRenewalMachOSignatureReader.withOwnedFile(root: root, fact: fact, maximumReadBytes: count) { read in
                try read(.init(offset: UInt64(offset), byteCount: count))
            }
        }
        func hashes() throws -> [String: Data] {
            try check()
            var result: [String: Data] = [:]
            for fact in facts.values {
                try Task.checkCancellation()
                result[fact.relativePath] = try SelfRenewalMachOSignatureReader.withOwnedFile(root: root, fact: fact,
                    maximumReadBytes: Int(fact.byteCount)) { read in
                    var hash = SHA256(); var offset = 0
                    while offset < Int(fact.byteCount) {
                        let count = min(Validator.Limits.chunkBytes, Int(fact.byteCount) - offset)
                        hash.update(data: try read(.init(offset: UInt64(offset), byteCount: count))); offset += count
                    }
                    return Data(hash.finalize())
                }
            }
            return result
        }
        func replace(_ path: String, with bytes: Data, expectedSHA256: Data, maximumBytes: Int) throws {
            try check()
            guard let old = facts[path], bytes.count <= maximumBytes,
                  maximumBytes <= Validator.Limits.expandedEntryBytes,
                  bytes.count <= Validator.Limits.expandedBytes - expandedBytes + Int(old.byteCount) else { throw Failure.readBudget }
            let actual = try read(path, maximumBytes: maximumBytes)
            guard Data(SHA256.hash(data: actual)) == expectedSHA256 else { throw Failure.inputChanged }
            if actual == bytes { return }
            try tree.replace(plan.applicationPath + "/" + path, bytes: bytes)
            expandedBytes += bytes.count - Int(old.byteCount)
            facts[path] = .init(relativePath: path, byteCount: Int64(bytes.count))
        }
        func verifyCurrent(codeAnchors: [Data], profileAnchors: [Data], at date: Date) async throws
            -> SelfRenewalApplicationMaterialVerifier.Materials {
            try check(); busy = true
            let tree = self.tree; let root = self.root
            let worker = Task.detached(priority: .utility) {
                try tree.validateNames()
                let proof = try await SelfRenewalApplicationMaterialVerifier.read(unpackedApplication: root,
                    codeAnchors: codeAnchors, profileAnchors: profileAnchors, at: date)
                try Task.checkCancellation(); try tree.validateNames()
                return proof
            }
            cancelRunning = { worker.cancel() }
            defer { finishExclusive() }
            do {
                let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                await observer?(.exclusiveFinished); return value
            } catch { await observer?(.exclusiveFinished); throw error }
        }
        func archive(codeAnchors: [Data], profileAnchors: [Data], at date: Date,
            expectedFileHashes: [String: Data]? = nil) async throws -> ControlledArchive {
            try check(); busy = true
            let tree = self.tree; let root = self.root; let plan = self.plan
            let facts = self.facts; let expandedBytes = self.expandedBytes
            let executablePaths = Set(original.resources.executableMaterials.inventory.codeFiles.map { $0.file.relativePath })
            let observer = self.observer
            let worker = Task.detached(priority: .utility) {
                await observer?(.archiveEntered)
                try Task.checkCancellation(); try tree.validateNames()
                // Bind even omitted/unsealed files across the last asynchronous
                // seam. The actor keeps mutation closed for this entire worker.
                if let expected = expectedFileHashes {
                    guard Set(expected.keys) == Set(facts.keys) else { throw Failure.inputChanged }
                    for fact in facts.values {
                        let digest = try SelfRenewalMachOSignatureReader.withOwnedFile(root: root, fact: fact,
                            maximumReadBytes: Int(fact.byteCount)) { read in
                            var hash = SHA256(); var offset = 0
                            while offset < Int(fact.byteCount) {
                                let count = min(Validator.Limits.chunkBytes, Int(fact.byteCount) - offset)
                                hash.update(data: try read(.init(offset: UInt64(offset), byteCount: count))); offset += count
                            }
                            return Data(hash.finalize())
                        }
                        guard expected[fact.relativePath] == digest else { throw Failure.inputChanged }
                    }
                }
                // The single stored writer checks exact local/central/name
                // overhead before opening output, then bounds every write.
                guard facts.values.allSatisfy({ $0.byteCount <= Int64(Validator.Limits.compressedEntryBytes) }),
                      date.timeIntervalSince1970 >= 315_532_800, date.timeIntervalSince1970 < 4_354_819_200 else { throw Failure.readBudget }
                let outputName = "signed-" + UUID().uuidString.lowercased() + ".ipa"
                let url = tree.url.appendingPathComponent(outputName)
                let writer = try StoredArchiveWriter(tree: tree, name: outputName, paths: plan.entries.map(\.path),
                    expandedBytes: expandedBytes, date: date)
                for entry in plan.entries {
                    // Each source name and its ancestors are identity checked;
                    // a complete scan per entry would be quadratic at JVM size.
                    try Task.checkCancellation(); try tree.validatePath(entry.path)
                    if entry.directory {
                        try writer.append(path: entry.path, directory: true, byteCount: 0, provider: { _, _ in Data() })
                    } else {
                        guard entry.path.hasPrefix(plan.applicationPath + "/") else { throw Failure.stagingChanged }
                        let relative = String(entry.path.dropFirst(plan.applicationPath.count + 1))
                        guard let fact = facts[relative] else { throw Failure.stagingChanged }
                        var emittedHash = SHA256()
                        try writer.append(path: entry.path, directory: false, byteCount: Int(fact.byteCount),
                            executable: executablePaths.contains(relative), provider: { offset, count in
                                let bytes = try Self.part(root: root, fact: fact, at: offset, count: count)
                                emittedHash.update(data: bytes)
                                return bytes
                            })
                        if let expected = expectedFileHashes {
                            // Bind the bytes actually emitted too, including
                            // resources intentionally omitted by signed rules.
                            guard expected[relative] == Data(emittedHash.finalize()) else { throw Failure.inputChanged }
                        }
                    }
                    try tree.validatePath(entry.path)
                    try tree.boundFile(outputName, maximumBytes: Validator.Limits.archiveBytes)
                }
                try writer.finish()
                let proof = try await SelfRenewalIPAUnpacker.verify(ipa: url, codeAnchors: codeAnchors,
                    profileAnchors: profileAnchors, at: date)
                try Task.checkCancellation(); try tree.validateNames()
                let bytes = try tree.copySnapshot(from: url)
                guard bytes.digest == proof.archiveSHA256, bytes.byteCount == proof.archiveBytes else {
                    bytes.close(); throw Failure.inputChanged
                }
                return ControlledArchive(snapshot: bytes, verification: proof)
            }
            cancelRunning = { worker.cancel() }
            defer { finishExclusive() }
            do {
                let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                await observer?(.exclusiveFinished); return value
            } catch { await observer?(.exclusiveFinished); throw error }
        }
    }

    /// Actual pinned, read-only output bytes, plus the verifier result from
    /// reading that exact ZIP. No mutable staging URL or installation authority.
    final class ControlledArchive: @unchecked Sendable {
        let verification: Materials
        var byteCount: Int { snapshot.byteCount }
        var sha256: Data { snapshot.digest }
        private let snapshot: Snapshot
        fileprivate init(snapshot: Snapshot, verification: Materials) { self.snapshot = snapshot; self.verification = verification }
        nonisolated func read(at offset: Int, count: Int) async throws -> Data {
            let worker = Task.detached(priority: .utility) {
                guard (0...Validator.Limits.chunkBytes).contains(count) else { throw Failure.readBudget }
                return try self.snapshot.read(at: offset, count: count)
            }
            let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation(); return value
        }
        nonisolated func data(maximumBytes: Int) async throws -> Data {
            let worker = Task.detached(priority: .utility) {
                let started = SourcePerfTrace.now
                defer { SourcePerfTrace.record("renewal.package.archive-bytes", "bytes=\(self.byteCount) main=\(Thread.isMainThread)", since: started, thresholdMs: 0) }
                guard maximumBytes >= self.byteCount, maximumBytes <= 67_108_864 else { throw Failure.readBudget }
                var result = Data(); result.reserveCapacity(self.byteCount)
                while result.count < self.byteCount {
                    try Task.checkCancellation()
                    result.append(try self.snapshot.read(at: result.count, count: min(Validator.Limits.chunkBytes, self.byteCount - result.count)))
                }
                return result
            }
            let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation(); return value
        }
    }

    static func validatePayloads(_ snapshot: any SelfRenewalIPAArchiveBytes, plan: Validator.Plan) throws {
        precondition(!Thread.isMainThread, "IPA payload validation must stay off main")
        for entry in plan.entries where !entry.directory {
            try Task.checkCancellation()
            var crc: UInt32 = 0
            var produced = 0
            if entry.compressionMethod == 0 {
                while produced < entry.expandedBytes {
                    try Task.checkCancellation()
                    let count = min(Validator.Limits.chunkBytes, entry.expandedBytes - produced)
                    let bytes = try snapshot.read(at: entry.dataOffset + produced, count: count)
                    guard bytes.count == count else { throw Failure.actualSizeMismatch(entry.path) }
                    crc = bytes.crc32(checksum: crc)
                    produced += count
                }
            } else {
                var stream = z_stream()
                guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                    throw Failure.malformedCompression(entry.path)
                }
                defer { inflateEnd(&stream) }
                var consumed = 0
                var ended = false
                var output = [UInt8](repeating: 0, count: Validator.Limits.chunkBytes)
                while consumed < entry.compressedBytes && !ended {
                    try Task.checkCancellation()
                    let count = min(Validator.Limits.chunkBytes, entry.compressedBytes - consumed)
                    let bytes = try snapshot.read(at: entry.dataOffset + consumed, count: count)
                    guard bytes.count == count else { throw Failure.actualSizeMismatch(entry.path) }
                    consumed += count
                    try bytes.withUnsafeBytes { buffer in
                        stream.next_in = UnsafeMutablePointer<Bytef>(mutating: buffer.bindMemory(to: Bytef.self).baseAddress)
                        stream.avail_in = uInt(count)
                        repeat {
                            try Task.checkCancellation()
                            let before = stream.total_in
                            var status: Int32 = Z_OK
                            let written = output.withUnsafeMutableBytes { buffer -> Int in
                                stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                                stream.avail_out = uInt(buffer.count)
                                status = inflate(&stream, Z_NO_FLUSH)
                                return buffer.count - Int(stream.avail_out)
                            }
                            guard written <= entry.expandedBytes - produced else { throw Failure.actualSizeMismatch(entry.path) }
                            crc = Data(output.prefix(written)).crc32(checksum: crc)
                            produced += written
                            if status == Z_STREAM_END { ended = true; break }
                            guard status == Z_OK, written > 0 || stream.total_in > before else {
                                throw Failure.malformedCompression(entry.path)
                            }
                        } while stream.avail_in > 0 || stream.avail_out == 0
                    }
                }
                guard ended, UInt64(stream.total_in) == UInt64(entry.compressedBytes) else { throw Failure.malformedCompression(entry.path) }
            }
            guard produced == entry.expandedBytes else { throw Failure.actualSizeMismatch(entry.path) }
            guard crc == entry.checksum else { throw Failure.crcMismatch(entry.path) }
        }
    }

    private struct Identity {
        let device: dev_t
        let inode: ino_t
        init(_ value: stat) { device = value.st_dev; inode = value.st_ino }
        func matches(_ value: stat) -> Bool { device == value.st_dev && inode == value.st_ino }
    }

    fileprivate final class Snapshot: @unchecked Sendable, SelfRenewalIPAArchiveBytes {
        let byteCount: Int
        let digest: Data
        private let lock = NSLock()
        private var descriptor: Int32
        private var reads = 0
        private var bytesRead = 0
        init(descriptor: Int32, bytes: Int, digest: Data) {
            self.descriptor = descriptor; byteCount = bytes; self.digest = digest
        }
        func read(at offset: Int, count: Int) throws -> Data {
            try Task.checkCancellation()
            lock.lock(); defer { lock.unlock() }
            guard descriptor >= 0, count >= 0, count <= Validator.Limits.chunkBytes + 22,
                  offset >= 0, count <= byteCount, offset <= byteCount - count else { throw Failure.inputRead }
            reads += 1
            let maximumReadBytes = byteCount * 4 + Validator.Limits.centralBytes * 8 + Validator.Limits.chunkBytes * 2
            guard reads <= 500_000, count <= maximumReadBytes - bytesRead else { throw Failure.readBudget }
            bytesRead += count
            var bytes = Data(count: count)
            var done = 0
            while done < count {
                try Task.checkCancellation()
                let actual = bytes.withUnsafeMutableBytes { buffer in
                    Darwin.pread(descriptor, buffer.baseAddress!.advanced(by: done), count - done, off_t(offset + done))
                }
                if actual < 0, errno == EINTR { continue }
                guard actual > 0 else { throw Failure.inputRead }
                done += actual
            }
            return bytes
        }
        func close() { lock.lock(); defer { lock.unlock() }; if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } }
        deinit { close() }
    }

    private struct SnapshotSource: ReadiumZIPFoundation.DataSource {
        let snapshot: Snapshot
        let isWritable = false
        func length() async throws -> UInt64 { UInt64(snapshot.byteCount) }
        func openRead() async throws -> any DataSourceTransaction { Transaction(snapshot: snapshot) }
        private actor Transaction: ReadiumZIPFoundation.DataSourceTransaction {
            let snapshot: Snapshot
            var offset: UInt64 = 0
            init(snapshot: Snapshot) { self.snapshot = snapshot }
            func position() async throws -> UInt64 { offset }
            func seek(to position: UInt64) async throws {
                guard position <= UInt64(snapshot.byteCount) else { throw Failure.inputRead }
                offset = position
            }
            func read(length: Int) async throws -> Data {
                let bytes = try snapshot.read(at: Int(offset), count: length)
                offset += UInt64(bytes.count)
                return bytes
            }
        }
    }

    private actor Sink {
        var descriptor: Int32
        let expected: Int
        var count = 0
        var emptyCallbacks = 0
        init(descriptor: Int32, expected: Int) { self.descriptor = descriptor; self.expected = expected }
        func consume(_ data: Data) throws {
            try Task.checkCancellation()
            guard descriptor >= 0, data.count <= Validator.Limits.chunkBytes, data.count <= expected - count else {
                throw Failure.actualSizeMismatch("entry")
            }
            if data.isEmpty {
                emptyCallbacks += 1
                guard emptyCallbacks <= 4 else { throw Failure.malformedCompression("entry") }
                return
            }
            var done = 0
            while done < data.count {
                try Task.checkCancellation()
                let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!.advanced(by: done), data.count - done) }
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw Failure.stagingIO }
                done += written
            }
            count += data.count
        }
        func finish(path: String) throws {
            guard count == expected else { throw Failure.actualSizeMismatch(path) }
            let result = Darwin.close(descriptor)
            descriptor = -1
            guard result == 0 else { throw Failure.stagingIO }
        }
        func abort() { if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } }
        deinit { if descriptor >= 0 { Darwin.close(descriptor) } }
    }

    /// One bounded stored-ZIP output path. Payloads stream once, local CRCs are
    /// patched in their owned FD, and the bounded central directory is emitted
    /// once at the end. Input metadata parsing remains solely in Validator.
    final class StoredArchiveWriter {
        private let tree: OwnedTree
        private let name: String
        private let paths: [String]
        private let expectedBytes: Int
        private let expectedExpandedBytes: Int
        private let dosTime: UInt16
        private let dosDate: UInt16
        private var descriptor: Int32 = -1
        private var position = 0
        private var expandedBytes = 0
        private var index = 0
        private var central = Data()

        init(tree: OwnedTree, name: String, paths: [String], expandedBytes: Int, date: Date) throws {
            guard !paths.isEmpty, paths.count <= Validator.Limits.entries,
                  expandedBytes >= 0, expandedBytes <= Validator.Limits.expandedBytes else { throw Failure.readBudget }
            var metadata = 22; var centralBytes = 0
            for path in paths {
                try Task.checkCancellation()
                let count = path.utf8.count
                guard count > 0, count <= Validator.Limits.pathBytes,
                      path.split(separator: "/").count <= Validator.Limits.depth else { throw Failure.readBudget }
                metadata += 76 + 2 * count
                centralBytes += 46 + count
            }
            guard metadata <= Validator.Limits.archiveBytes,
                  expandedBytes <= Validator.Limits.archiveBytes - metadata,
                  centralBytes <= Validator.Limits.centralBytes,
                  date.timeIntervalSince1970 >= 315_532_800,
                  date.timeIntervalSince1970 < 4_354_819_200 else { throw Failure.readBudget }
            var calendar = Calendar(identifier: .gregorian)
            guard let utc = TimeZone(secondsFromGMT: 0) else { throw Failure.readBudget }
            calendar.timeZone = utc
            let values = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            guard let year = values.year, let month = values.month, let day = values.day,
                  let hour = values.hour, let minute = values.minute, let second = values.second,
                  (1980...2107).contains(year) else { throw Failure.readBudget }
            dosTime = UInt16(hour << 11 | minute << 5 | second / 2)
            dosDate = UInt16((year - 1980) << 9 | month << 5 | day)
            self.tree = tree; self.name = name; self.paths = paths
            expectedBytes = expandedBytes + metadata
            expectedExpandedBytes = expandedBytes
            central.reserveCapacity(centralBytes)
            descriptor = try tree.file(name)
        }
        func append(path: String, directory: Bool, byteCount: Int, executable: Bool = false,
            provider: (Int, Int) throws -> Data) throws {
            try Task.checkCancellation()
            guard descriptor >= 0, index < paths.count, paths[index] == path,
                  directory == path.hasSuffix("/"), byteCount >= 0,
                  byteCount <= Validator.Limits.compressedEntryBytes,
                  byteCount <= expectedExpandedBytes - expandedBytes,
                  !directory || byteCount == 0 else { throw Failure.readBudget }
            let offset = position; let nameBytes = Data(path.utf8)
            var local = Data()
            Self.u32(0x04034b50, to: &local); Self.u16(20, to: &local)
            Self.u16(0x0800, to: &local); Self.u16(0, to: &local)
            Self.u16(dosTime, to: &local); Self.u16(dosDate, to: &local)
            Self.u32(0, to: &local)
            Self.u32(UInt32(byteCount), to: &local); Self.u32(UInt32(byteCount), to: &local)
            Self.u16(UInt16(nameBytes.count), to: &local); Self.u16(0, to: &local)
            local.append(nameBytes)
            try write(local)
            var consumed = 0; var crc: UInt32 = 0
            while consumed < byteCount {
                try Task.checkCancellation()
                let count = min(Validator.Limits.chunkBytes, byteCount - consumed)
                let bytes = try provider(consumed, count)
                guard bytes.count == count else { throw Failure.actualSizeMismatch(path) }
                crc = bytes.crc32(checksum: crc)
                try write(bytes); consumed += count
            }
            // No second payload traversal and no data descriptor ambiguity.
            // Only the CRC field in this freshly created local header changes.
            var checksum = Data(); Self.u32(crc, to: &checksum)
            var patched = 0
            while patched < checksum.count {
                try Task.checkCancellation()
                let count = checksum.withUnsafeBytes { Darwin.pwrite(descriptor,
                    $0.baseAddress!.advanced(by: patched), checksum.count - patched, off_t(offset + 14 + patched)) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.stagingIO }
                patched += count
            }
            Self.u32(0x02014b50, to: &central); Self.u16(0x0314, to: &central); Self.u16(20, to: &central)
            Self.u16(0x0800, to: &central); Self.u16(0, to: &central)
            Self.u16(dosTime, to: &central); Self.u16(dosDate, to: &central)
            Self.u32(crc, to: &central)
            Self.u32(UInt32(byteCount), to: &central); Self.u32(UInt32(byteCount), to: &central)
            Self.u16(UInt16(nameBytes.count), to: &central)
            for _ in 0..<4 { Self.u16(0, to: &central) }
            let mode: UInt32 = directory ? 0o040755 : (executable ? 0o100755 : 0o100644)
            Self.u32(mode << 16 | (directory ? 0x10 : 0), to: &central)
            Self.u32(UInt32(offset), to: &central); central.append(nameBytes)
            guard central.count <= Validator.Limits.centralBytes else { throw Failure.readBudget }
            expandedBytes += byteCount; index += 1
            try tree.boundFile(name, maximumBytes: expectedBytes)
        }
        func finish() throws {
            try Task.checkCancellation()
            guard descriptor >= 0, index == paths.count, expandedBytes == expectedExpandedBytes else { throw Failure.readBudget }
            let centralStart = position
            try write(central)
            var end = Data()
            Self.u32(0x06054b50, to: &end); Self.u16(0, to: &end); Self.u16(0, to: &end)
            Self.u16(UInt16(index), to: &end); Self.u16(UInt16(index), to: &end)
            Self.u32(UInt32(central.count), to: &end); Self.u32(UInt32(centralStart), to: &end); Self.u16(0, to: &end)
            try write(end)
            guard position == expectedBytes else { throw Failure.actualSizeMismatch(name) }
            let closed = Darwin.close(descriptor); descriptor = -1
            guard closed == 0 else { throw Failure.stagingIO }
            try tree.boundFile(name, maximumBytes: expectedBytes)
        }
        private func write(_ bytes: Data) throws {
            guard descriptor >= 0, bytes.count <= expectedBytes - position else { throw Failure.readBudget }
            try OwnedTree.write(bytes, to: descriptor)
            position += bytes.count
        }
        private static func u16(_ value: UInt16, to bytes: inout Data) {
            bytes.append(UInt8(truncatingIfNeeded: value)); bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        private static func u32(_ value: UInt32, to bytes: inout Data) {
            u16(UInt16(truncatingIfNeeded: value), to: &bytes); u16(UInt16(truncatingIfNeeded: value >> 16), to: &bytes)
        }
        deinit { if descriptor >= 0 { Darwin.close(descriptor) } }
    }

    /// Names and inode/device facts remain bounded in memory. Only the private
    /// parent/root stay open; a walk holds at most two additional directory FDs.
    /// Each component is reopened relative to the pinned root, without links,
    /// and checked against the identity captured when this owner created it.
    final class OwnedTree: @unchecked Sendable {
        let url: URL
        private let name: String
        private let parent: Int32
        private let root: Int32
        private var identities: [String: Identity] = [:]
        private var files: [String: Identity] = [:]
        private var cleaned = false
        init() throws {
            precondition(!Thread.isMainThread, "IPA staging must stay off main")
            let parentURL = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
            parent = Darwin.open(parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parent >= 0 else { throw Failure.stagingIO }
            name = "renewal-owned-ipa-" + UUID().uuidString.lowercased()
            url = parentURL.appendingPathComponent(name, isDirectory: true)
            guard mkdirat(parent, name, 0o700) == 0 else { Darwin.close(parent); throw Failure.stagingIO }
            root = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard root >= 0 else {
                _ = unlinkat(parent, name, AT_REMOVEDIR); Darwin.close(parent); throw Failure.stagingIO
            }
            var value = stat()
            guard fstat(root, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else {
                Darwin.close(root); _ = unlinkat(parent, name, AT_REMOVEDIR); Darwin.close(parent); throw Failure.stagingIO
            }
            identities[""] = Identity(value)
        }
        func directory(_ path: String) throws {
            let parts = try Self.components(path)
            var key = ""
            for part in parts {
                try Task.checkCancellation()
                let parentKey = key
                key += (key.isEmpty ? "" : "/") + part
                if identities[key] != nil { continue }
                guard identities.count < Validator.Limits.directories + 1 else { throw Validator.Failure.directoryLimit }
                try withDirectory(parentKey) { descriptor in
                    guard mkdirat(descriptor, part, 0o700) == 0 else { throw Failure.stagingIO }
                    // Record the created name before opening it, including the
                    // EMFILE path; cleanup never adopts an unrecorded name.
                    var value = stat()
                    guard fstatat(descriptor, part, &value, AT_SYMLINK_NOFOLLOW) == 0,
                          value.st_mode & S_IFMT == S_IFDIR else { throw Failure.stagingIO }
                    identities[key] = Identity(value)
                    let child = openat(descriptor, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw Failure.stagingIO }
                    defer { Darwin.close(child) }
                    guard fstat(child, &value) == 0, identities[key]?.matches(value) == true else { throw Failure.stagingChanged }
                }
            }
        }
        func file(_ path: String) throws -> Int32 {
            let pieces = try Self.components(path)
            guard let leaf = pieces.last else { throw Failure.stagingIO }
            let parentPath = pieces.dropLast().joined(separator: "/")
            try directory(parentPath)
            var created: Int32 = -1
            do {
                return try withDirectory(parentPath) { descriptor in
                    created = openat(descriptor, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    guard created >= 0 else { throw Failure.stagingIO }
                    var value = stat()
                    guard fstat(created, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1 else { throw Failure.stagingIO }
                    files[path] = Identity(value)
                    var named = stat()
                    guard fstatat(descriptor, leaf, &named, AT_SYMLINK_NOFOLLOW) == 0,
                          Self.sameFile(value, named) else { throw Failure.stagingChanged }
                    return created
                }
            } catch {
                if created >= 0 { Darwin.close(created) }
                throw error
            }
        }
        static func write(_ bytes: Data, to descriptor: Int32) throws {
            var done = 0
            while done < bytes.count {
                try Task.checkCancellation()
                let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!.advanced(by: done), bytes.count - done) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.stagingIO }
                done += count
            }
        }
        func boundFile(_ path: String, maximumBytes: Int) throws {
            try withParent(path) { parentFD, leaf in
                var value = stat()
                guard fstatat(parentFD, leaf, &value, AT_SYMLINK_NOFOLLOW) == 0,
                      files[path]?.matches(value) == true, value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1,
                      value.st_size >= 0, value.st_size <= Int64(maximumBytes) else { throw Failure.stagingChanged }
            }
        }
        func validatePath(_ path: String) throws {
            let key = path.hasSuffix("/") ? String(path.dropLast()) : path
            if identities[key] != nil { try withDirectory(key) { _ in } }
            else { try boundFile(key, maximumBytes: Int.max) }
        }
        func replace(_ path: String, bytes: Data) throws {
            try boundFile(path, maximumBytes: Int.max)
            let parts = try Self.components(path)
            let prefix = parts.dropLast().joined(separator: "/")
            let temporaryLeaf = ".renewal-new-" + UUID().uuidString.lowercased()
            let temporary = (prefix.isEmpty ? "" : prefix + "/") + temporaryLeaf
            let descriptor = try file(temporary)
            do { try Self.write(bytes, to: descriptor) }
            catch { Darwin.close(descriptor); throw error }
            guard Darwin.close(descriptor) == 0 else { throw Failure.stagingIO }
            try Task.checkCancellation()
            try boundFile(path, maximumBytes: Int.max)
            try boundFile(temporary, maximumBytes: bytes.count)
            try withParent(path) { parentFD, leaf in
                var old = stat(); var replacement = stat()
                guard fstatat(parentFD, leaf, &old, AT_SYMLINK_NOFOLLOW) == 0,
                      files[path]?.matches(old) == true, old.st_mode & S_IFMT == S_IFREG, old.st_nlink == 1,
                      fstatat(parentFD, temporaryLeaf, &replacement, AT_SYMLINK_NOFOLLOW) == 0,
                      let identity = files[temporary], identity.matches(replacement),
                      replacement.st_mode & S_IFMT == S_IFREG, replacement.st_nlink == 1 else { throw Failure.stagingChanged }
                guard renameat(parentFD, temporaryLeaf, parentFD, leaf) == 0 else { throw Failure.stagingIO }
                files[path] = identity; files.removeValue(forKey: temporary)
            }
            try boundFile(path, maximumBytes: bytes.count)
        }
        fileprivate func copySnapshot(from input: URL) throws -> Snapshot {
            guard input.isFileURL, input.query == nil, input.fragment == nil else { throw Failure.invalidInput }
            let inputFD = Darwin.open(input.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard inputFD >= 0 else { throw Failure.invalidInput }
            defer { Darwin.close(inputFD) }
            var initial = stat()
            guard fstat(inputFD, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG,
                  initial.st_nlink == 1, initial.st_size >= 22,
                  initial.st_size <= off_t(Validator.Limits.archiveBytes) else { throw Failure.invalidInput }
            let output = try file("archive.snapshot")
            defer { Darwin.close(output) }
            var hash = SHA256()
            var buffer = [UInt8](repeating: 0, count: Validator.Limits.chunkBytes)
            var copied = 0
            while copied < Int(initial.st_size) {
                try Task.checkCancellation()
                let count = min(buffer.count, Int(initial.st_size) - copied)
                let got = buffer.withUnsafeMutableBytes { Darwin.read(inputFD, $0.baseAddress!, count) }
                if got < 0, errno == EINTR { continue }
                guard got > 0 else { throw Failure.inputRead }
                let data = Data(buffer.prefix(got))
                hash.update(data: data)
                var done = 0
                while done < got {
                    try Task.checkCancellation()
                    let written = data.withUnsafeBytes { Darwin.write(output, $0.baseAddress!.advanced(by: done), got - done) }
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw Failure.stagingIO }
                    done += written
                }
                copied += got
            }
            var after = stat(); var pathNow = stat()
            guard fstat(inputFD, &after) == 0, lstat(input.path, &pathNow) == 0,
                  Self.sameFile(initial, after), Self.sameFile(initial, pathNow) else { throw Failure.inputChanged }
            try validatePath("")
            let reader = openat(root, "archive.snapshot", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard reader >= 0 else { throw Failure.stagingIO }
            do {
                var snapshot = stat()
                guard fstat(reader, &snapshot) == 0, files["archive.snapshot"]?.matches(snapshot) == true,
                      snapshot.st_mode & S_IFMT == S_IFREG, snapshot.st_nlink == 1,
                      snapshot.st_size == off_t(copied), unlinkat(root, "archive.snapshot", 0) == 0 else { throw Failure.stagingChanged }
                files.removeValue(forKey: "archive.snapshot")
                try validatePath("")
                return Snapshot(descriptor: reader, bytes: copied, digest: Data(hash.finalize()))
            } catch { Darwin.close(reader); throw error }
        }
        func validateNames() throws {
            for path in identities.keys { try Task.checkCancellation(); try validatePath(path) }
            for path in files.keys { try Task.checkCancellation(); try boundFile(path, maximumBytes: Int.max) }
        }
        func cleanup() throws {
            if cleaned { return }
            var failed = false
            for (path, identity) in files {
                do {
                    try withParent(path) { parentFD, leaf in
                        var value = stat()
                        if fstatat(parentFD, leaf, &value, AT_SYMLINK_NOFOLLOW) != 0 {
                            if errno != ENOENT { throw Failure.cleanupFailed }; return
                        }
                        guard identity.matches(value), value.st_mode & S_IFMT == S_IFREG,
                              value.st_nlink == 1, unlinkat(parentFD, leaf, 0) == 0 else { throw Failure.cleanupFailed }
                    }
                } catch { failed = true }
            }
            let paths = identities.keys.sorted { $0.split(separator: "/").count > $1.split(separator: "/").count }
            for path in paths where !path.isEmpty {
                do {
                    try withParent(path) { parentFD, leaf in
                        var value = stat()
                        if fstatat(parentFD, leaf, &value, AT_SYMLINK_NOFOLLOW) != 0 {
                            if errno != ENOENT { throw Failure.cleanupFailed }; return
                        }
                        guard identities[path]?.matches(value) == true, value.st_mode & S_IFMT == S_IFDIR,
                              unlinkat(parentFD, leaf, AT_REMOVEDIR) == 0 else { throw Failure.cleanupFailed }
                    }
                } catch { failed = true }
            }
            var value = stat()
            if fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 {
                if identities[""]?.matches(value) != true || value.st_mode & S_IFMT != S_IFDIR || unlinkat(parent, name, AT_REMOVEDIR) != 0 { failed = true }
            } else if errno != ENOENT { failed = true }
            Darwin.close(root); Darwin.close(parent)
            cleaned = true
            guard !failed else { throw Failure.cleanupFailed }
        }
        private func withParent<T>(_ path: String, operation: (Int32, String) throws -> T) throws -> T {
            let parts = try Self.components(path)
            guard let leaf = parts.last else { throw Failure.stagingIO }
            return try withDirectory(parts.dropLast().joined(separator: "/")) { try operation($0, leaf) }
        }
        private func withDirectory<T>(_ path: String, operation: (Int32) throws -> T) throws -> T {
            var descriptor = try openDirectory(path)
            defer { if descriptor >= 0 { Darwin.close(descriptor) } }
            let result = try operation(descriptor)
            // Detect an ancestor/name replacement across the operation too.
            // The reopened walk never follows a symlink or an unknown inode.
            var before = stat()
            guard fstat(descriptor, &before) == 0 else { throw Failure.stagingChanged }
            Darwin.close(descriptor); descriptor = -1
            let checked = try openDirectory(path)
            defer { Darwin.close(checked) }
            var after = stat()
            guard fstat(checked, &after) == 0,
                  before.st_dev == after.st_dev, before.st_ino == after.st_ino else { throw Failure.stagingChanged }
            return result
        }
        private func openDirectory(_ path: String) throws -> Int32 {
            guard !cleaned else { throw Failure.stagingChanged }
            let parts = try Self.components(path)
            var named = stat(); var pinned = stat()
            guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  fstat(root, &pinned) == 0, identities[""]?.matches(named) == true,
                  identities[""]?.matches(pinned) == true, named.st_mode & S_IFMT == S_IFDIR,
                  pinned.st_mode & S_IFMT == S_IFDIR else { throw Failure.stagingChanged }
            var descriptor = fcntl(root, F_DUPFD_CLOEXEC, 0)
            guard descriptor >= 0 else { throw Failure.stagingIO }
            do {
                var key = ""
                for part in parts {
                    key += (key.isEmpty ? "" : "/") + part
                    guard let identity = identities[key] else { throw Failure.stagingChanged }
                    let next = openat(descriptor, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard next >= 0 else { throw Failure.stagingChanged }
                    var value = stat()
                    guard fstat(next, &value) == 0, identity.matches(value), value.st_mode & S_IFMT == S_IFDIR else {
                        Darwin.close(next); throw Failure.stagingChanged
                    }
                    Darwin.close(descriptor); descriptor = next
                }
                return descriptor
            } catch { Darwin.close(descriptor); throw error }
        }
        private static func components(_ path: String) throws -> [String] {
            if path.isEmpty { return [] }
            let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
            let parts = trimmed.components(separatedBy: "/")
            guard trimmed.utf8.count <= Validator.Limits.pathBytes, parts.count <= Validator.Limits.depth,
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains(":" )
                    && $0.utf8.count <= 255 && !$0.hasSuffix(".") && !$0.hasSuffix(" ")
                    && $0.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) }) else { throw Failure.stagingIO }
            return parts
        }
        private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
            lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size && lhs.st_mode == rhs.st_mode
                && lhs.st_nlink == rhs.st_nlink && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
                && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
                && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
        }
        deinit {
            // Heavy cleanup is explicit on the worker. The interrupted-use
            // fallback closes only the two permanently held directory FDs.
            if !cleaned { Darwin.close(root); Darwin.close(parent) }
        }
    }
}
