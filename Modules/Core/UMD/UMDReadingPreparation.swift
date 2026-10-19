import Foundation

/// An in-memory projection for the existing TXT document and builder. It does
/// not import, register, persist, reindex or open a book in the product.
enum UMDReadingPreparation {
    enum Failure: Error, Equatable {
        case emptyDocument
        case inconsistentDocument
        case budgetExceeded
    }

    struct Limits: Sendable {
        var utf16Bytes = 32 * 1_024 * 1_024
        var chapters = 16_384
    }

    /// A chapter remains one complete paragraph value. Joining a global string
    /// and using TXT's composed-character ranges could cross a UMD chapter seam.
    /// Raw byte offsets validate directory identity only; they are never rendered
    /// CoreTextReadingPosition.charOffset values.
    static func prepare(
        _ document: UMDTextDocument,
        limits: Limits = Limits()
    ) async throws -> [UnifiedChapter] {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            var validatedBytes = 0
            return try SourcePerfTrace.span(
                "umd.reading.prepare",
                "chapters=\(document.chapters.count) bytes=\(validatedBytes) maxBytes=\(limits.utf16Bytes) main=\(Thread.isMainThread)"
            ) {
                try Task.checkCancellation()
                guard !document.chapters.isEmpty else { throw Failure.emptyDocument }
                guard limits.utf16Bytes > 0, limits.chapters > 0,
                      document.chapters.count <= limits.chapters else { throw Failure.budgetExceeded }
                guard document.metadata.keys.allSatisfy({ (2...9).contains($0) }),
                      document.metadata.values.allSatisfy({ $0.utf16.prefix(126).count <= 125 }) else {
                    throw Failure.inconsistentDocument
                }
                var result: [UnifiedChapter] = []
                result.reserveCapacity(document.chapters.count)
                var offset = 0
                for (index, chapter) in document.chapters.enumerated() {
                    try Task.checkCancellation()
                    let count = chapter.rawUTF16LE.count
                    guard chapter.rawByteOffset == offset, count % 2 == 0,
                          chapter.title.utf16.prefix(128).count <= 127 else { throw Failure.inconsistentDocument }
                    guard count <= limits.utf16Bytes - offset else { throw Failure.budgetExceeded }
                    // Check the existing decoder's literal projection without
                    // making another decoded/normalized copy of the whole book.
                    var units = chapter.text.utf16.makeIterator()
                    try chapter.rawUTF16LE.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                        for byteIndex in stride(from: 0, to: bytes.count, by: 2) {
                            if byteIndex % 16_384 == 0 { try Task.checkCancellation() }
                            let raw = UInt16(bytes[byteIndex]) | UInt16(bytes[byteIndex + 1]) << 8
                            let expected: UInt16 = raw == 0x2029 ? 0x000A : raw
                            guard units.next() == expected else { throw Failure.inconsistentDocument }
                        }
                    }
                    guard units.next() == nil else { throw Failure.inconsistentDocument }
                    offset += count // bounded by the remaining budget above
                    validatedBytes = offset
                    result.append(UnifiedChapter(index: index, title: chapter.title,
                                                 paragraphs: [chapter.text], sourceHref: String(index)))
                }
                guard offset > 0 else { throw Failure.emptyDocument }
                try Task.checkCancellation()
                return result
            }
        }
        return try await withTaskCancellationHandler {
            let chapters = try await worker.value
            try Task.checkCancellation()
            return chapters
        } onCancel: {
            worker.cancel()
        }
    }
}
