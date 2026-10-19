import Foundation

/// The bounded file parser for the UMD text subset. Product registration awaits
/// the library's checked import commit and the explicit-directory reader route.
/// A generic storageText round-trip would lose the UMD table of contents.
struct UMDBookParser: BookParser {
    struct Snapshot: Sendable {
        let originalBytes: Data
        let document: UMDTextDocument
    }

    func parse(url: URL) async throws -> ParsedBookDocument {
        let snapshot = try await Self.load(url: url)
        return ParsedBookDocument(title: snapshot.document.title ?? url.deletingPathExtension().lastPathComponent,
                                  author: snapshot.document.author ?? "",
                                  chapters: snapshot.document.chapters.map(\.text))
    }

    /// Read at most the configured input budget plus a one-byte EOF probe. The
    /// same owned snapshot is validated and available for future staged import;
    /// no subsequent copy of a potentially changed source is considered valid.
    static func load(url: URL, limits: UMDTextDecoder.Limits = .init()) async throws -> Snapshot {
        let worker = Task.detached(priority: .userInitiated) {
            try SourcePerfTrace.span("umd.parse", "limitBytes=\(limits.inputBytes) main=\(Thread.isMainThread)") {
                try Task.checkCancellation()
                guard limits.inputBytes > 0 else { throw UMDTextError.budgetExceeded }
                let handle = try FileHandle(forReadingFrom: url)
                let bytes: Data
                do {
                    var input = Data()
                    while true {
                        try Task.checkCancellation()
                        let remaining = limits.inputBytes - input.count
                        // Avoid remaining + 1 overflow with caller-supplied limits.
                        let count = remaining >= 65_536 ? 65_536 : remaining + 1
                        guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
                        guard chunk.count <= remaining else { throw UMDTextError.budgetExceeded }
                        input.append(chunk)
                    }
                    bytes = input
                    try handle.close()
                } catch {
                    do { try handle.close() }
                    catch { AppLogger.error("UMD source handle close failed", error: error) }
                    throw error
                }
                let document = try SourcePerfTrace.span("umd.decode", "bytes=\(bytes.count) main=\(Thread.isMainThread)") {
                    try UMDTextDecoder.decode(bytes, limits: limits)
                }
                try Task.checkCancellation()
                return Snapshot(originalBytes: bytes, document: document)
            }
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
