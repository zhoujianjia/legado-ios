import Foundation
import Testing
@testable import yuedu_app

@Suite("Bounded unencrypted UMD text subset")
struct UMDTextDecoderTests {
    private static let fixtures = ["chinese-two-chapters", "paragraph-separators", "non-bmp-utf16",
                                   "multi-chapter-optional-metadata", "cross-compression-blocks"]
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/UMD")

    @Test("All five original Java public getter observations retain exact UTF-16 byte offsets and raw content")
    func matchesOriginalJavaFixtures() throws {
        for id in Self.fixtures {
            let folder = Self.root.appendingPathComponent(id)
            let golden = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: folder.appendingPathComponent("reader-output.json")))
            let document = try UMDTextDecoder.decode(Data(contentsOf: folder.appendingPathComponent("fixture.umd")))
            for (key, name) in [(2, "title"), (3, "author"), (4, "year"), (5, "month"),
                                (6, "day"), (7, "bookType"), (8, "bookMan"), (9, "shopKeeper")] {
                let actualUnits: [UInt16]? = document.metadata[key].map { Array($0.utf16) }
                let expectedValue: String? = golden.metadata[name]?.value
                let expectedUnits: [UInt16]? = expectedValue.map { Array($0.utf16) }
                #expect(actualUnits == expectedUnits)
            }
            #expect(document.chapters.count == golden.chapterCount.value)
            #expect(document.chapters.map(\.rawUTF16LE.count).reduce(0, +) == golden.totalContentLength.value)
            for (chapter, expected) in zip(document.chapters, golden.chapters) {
                #expect(Array(chapter.title.utf16) == Array(expected.title.value.utf16))
                #expect(chapter.rawByteOffset == expected.offset.value)
                #expect(chapter.rawUTF16LE == Data(base64Encoded: expected.rawContent.valueBase64))
                #expect(Array(chapter.text.utf16) == Array(expected.getContentString.value.utf16))
                #expect(chapter.text.utf16.count * 2 == chapter.rawUTF16LE.count)
            }
        }
    }

    @Test("Every truncated prefix of an original small fixture is rejected; original bytes remain valid")
    func rejectsEveryTruncatedPrefix() throws {
        let bytes = try fixture()
        for count in 0..<bytes.count { #expect(throws: (any Error).self) { try UMDTextDecoder.decode(Data(bytes.prefix(count))) } }
        #expect(try UMDTextDecoder.decode(bytes).chapters.count == 2)
    }

    @Test("Image books, nonzero license bytes, and unknown records are outside the text subset")
    func rejectsImagesKeysAndUnknownSections() throws {
        var image = try fixture(); image[9] = 2
        #expect(throws: UMDTextError.unsupported) { try UMDTextDecoder.decode(image) }
        var license = try fixture()
        let records = try Self.records(license)
        let key = try #require(records.first { $0.kind == 241 })
        license[key.start + 5] = 1
        #expect(throws: UMDTextError.unsupported) { try UMDTextDecoder.decode(license) }
        var unknown = try fixture()
        let record = try #require(records.first { $0.kind == 11 })
        unknown[record.start + 1] = 240
        #expect(throws: UMDTextError.unsupported) { try UMDTextDecoder.decode(unknown) }
    }

    @Test("Unsigned additional lengths, small section headers and wrong EOF size cannot escape the input")
    func rejectsInvalidLengthsAndEndMarker() throws {
        let original = try fixture()
        let records = try Self.records(original)
        let additional = try #require(records.first { $0.kind == nil })
        var overflowing = original; Self.put32(UInt32.max, into: &overflowing, at: additional.start + 5)
        #expect(throws: (any Error).self) { try UMDTextDecoder.decode(overflowing) }
        var small = original; small[8] = 4
        #expect(throws: UMDTextError.malformed) { try UMDTextDecoder.decode(small) }
        var wrongEnd = original; Self.put32(0, into: &wrongEnd, at: wrongEnd.count - 4)
        #expect(throws: UMDTextError.malformed) { try UMDTextDecoder.decode(wrongEnd) }
        var tail = original; tail.append(0)
        #expect(throws: UMDTextError.malformed) { try UMDTextDecoder.decode(tail) }
    }

    @Test("Chapter offsets must be even, monotonic, in range and begin at zero")
    func rejectsInvalidChapterOffsets() throws {
        let original = try fixture()
        let records = try Self.records(original)
        let offsets = try #require(records.firstIndex { $0.kind == 131 })
        let payload = records[offsets + 1].start + 9
        for (offset, value) in [(0, UInt32(2)), (4, UInt32(3)), (4, UInt32.max)] {
            var changed = original; Self.put32(value, into: &changed, at: payload + offset)
            #expect(throws: (any Error).self) { try UMDTextDecoder.decode(changed) }
        }
        let multi = try fixture("multi-chapter-optional-metadata")
        let multiRecords = try Self.records(multi)
        let record = try #require(multiRecords.firstIndex { $0.kind == 131 })
        var reversed = multi; Self.put32(2, into: &reversed, at: multiRecords[record + 1].start + 9 + 8)
        #expect(throws: UMDTextError.malformed) { try UMDTextDecoder.decode(reversed) }
    }

    @Test("Malformed UTF-16 metadata and a directory cutting a surrogate pair are rejected without repair")
    func rejectsInvalidUTF16AndSurrogateBoundary() throws {
        var metadata = try fixture()
        metadata[17] = 0x00; metadata[18] = 0xD8
        #expect(throws: UMDTextError.invalidUTF16) { try UMDTextDecoder.decode(metadata) }
        let nonBMP = try fixture("non-bmp-utf16")
        let decoded = try UMDTextDecoder.decode(nonBMP)
        let units = Array(decoded.chapters[0].rawUTF16LE)
        let high = try #require(stride(from: 0, to: units.count, by: 2).first {
            let unit = UInt16(units[$0]) | UInt16(units[$0 + 1]) << 8
            return (0xD800...0xDBFF).contains(unit)
        })
        let records = try Self.records(nonBMP)
        let offsets = try #require(records.firstIndex { $0.kind == 131 })
        var split = nonBMP; Self.put32(UInt32(high + 2), into: &split, at: records[offsets + 1].start + 13)
        #expect(throws: UMDTextError.invalidUTF16) { try UMDTextDecoder.decode(split) }
    }

    @Test("Zlib checksum, wrapper and complete compressed stream are required")
    func rejectsCorruptedZlibAndUnconsumedTail() throws {
        let original = try fixture()
        let records = try Self.records(original)
        let title = try #require(records.firstIndex { $0.kind == 132 })
        let chunk = records[title + 2]
        for offset in [chunk.start + 9, chunk.start + chunk.length - 1] {
            var corrupt = original; corrupt[offset] ^= 0xFF
            #expect(throws: UMDTextError.invalidCompression) { try UMDTextDecoder.decode(corrupt) }
        }
        var tailed = original
        tailed.insert(0, at: chunk.start + chunk.length)
        Self.put32(UInt32(chunk.length + 1), into: &tailed, at: chunk.start + 5)
        Self.put32(UInt32(tailed.count), into: &tailed, at: tailed.count - 4)
        #expect(throws: UMDTextError.invalidCompression) { try UMDTextDecoder.decode(tailed) }
    }

    @Test("Directory additional keys and final compressed block index must match")
    func rejectsMismatchedRecordIdentity() throws {
        let original = try fixture()
        let records = try Self.records(original)
        let offsets = try #require(records.firstIndex { $0.kind == 131 })
        var wrongKey = original; wrongKey[records[offsets + 1].start + 1] ^= 1
        #expect(throws: UMDTextError.malformed) { try UMDTextDecoder.decode(wrongKey) }
        let index = try #require(records.firstIndex { $0.kind == 129 })
        var wrongIndex = original; wrongIndex[records[index + 1].start + 9] ^= 1
        #expect(throws: UMDTextError.malformed) { try UMDTextDecoder.decode(wrongIndex) }
    }

    @Test("Input, declared output, chapter, record and actual inflation budgets fail closed")
    func enforcesAllBudgets() throws {
        let original = try fixture()
        var limits = UMDTextDecoder.Limits(); limits.inputBytes = original.count - 1
        #expect(throws: UMDTextError.budgetExceeded) { try UMDTextDecoder.decode(original, limits: limits) }
        limits = .init(); limits.outputBytes = 66
        #expect(throws: UMDTextError.budgetExceeded) { try UMDTextDecoder.decode(original, limits: limits) }
        limits = .init(); limits.chapters = 1
        #expect(throws: UMDTextError.budgetExceeded) { try UMDTextDecoder.decode(original, limits: limits) }
        limits = .init(); limits.records = 2
        #expect(throws: UMDTextError.budgetExceeded) { try UMDTextDecoder.decode(original, limits: limits) }
        let records = try Self.records(original)
        let length = try #require(records.first { $0.kind == 11 })
        var understated = original; Self.put32(2, into: &understated, at: length.start + 5)
        #expect(throws: UMDTextError.budgetExceeded) { try UMDTextDecoder.decode(understated) }
    }

    @Test("A cancelled owned task never decodes")
    func observesCancellation() async throws {
        let original = try fixture()
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try UMDTextDecoder.decode(original)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("File parsing retains the exact bounded source snapshot on an owned worker")
    func fileParserRetainsSnapshotAndEnforcesInputBudget() async throws {
        let url = Self.root.appendingPathComponent("cross-compression-blocks/fixture.umd")
        let source = try Data(contentsOf: url)
        let loaded = try await UMDBookParser.load(url: url)
        #expect(loaded.originalBytes == source)
        #expect(loaded.document.chapters.count == 3)
        var limits = UMDTextDecoder.Limits(); limits.inputBytes = source.count - 1
        await #expect(throws: UMDTextError.budgetExceeded) { try await UMDBookParser.load(url: url, limits: limits) }
        let parsed = try await UMDBookParser().parse(url: url)
        #expect(parsed.title == loaded.document.title)
        #expect(parsed.author == loaded.document.author)
        #expect(parsed.chapters == loaded.document.chapters.map(\.text))
    }

    private func fixture(_ name: String = "chinese-two-chapters") throws -> Data {
        try Data(contentsOf: Self.root.appendingPathComponent(name).appendingPathComponent("fixture.umd"))
    }
    private struct JavaValue<T: Decodable>: Decodable { let value: T }
    private struct JavaOptionalString: Decodable { let value: String? }
    private struct Golden: Decodable {
        let metadata: [String: JavaOptionalString]
        let chapterCount: JavaValue<Int>
        let totalContentLength: JavaValue<Int>
        let chapters: [Chapter]
        struct Chapter: Decodable {
            let title: JavaValue<String>
            let offset: JavaValue<Int>
            let rawContent: Raw
            let getContentString: JavaValue<String>
            struct Raw: Decodable { let valueBase64: String }
        }
    }
    private struct Record { let start: Int; let length: Int; let kind: Int? }
    private static func records(_ data: Data) throws -> [Record] {
        var offset = 4; var result: [Record] = []
        while offset < data.count {
            let kind: Int?; let length: Int
            if data[offset] == 35 {
                guard offset + 5 <= data.count else { throw UMDTextError.malformed }
                kind = Int(data[offset + 1]) | Int(data[offset + 2]) << 8
                length = Int(data[offset + 4])
            } else {
                guard data[offset] == 36, offset + 9 <= data.count else { throw UMDTextError.malformed }
                kind = nil
                length = (0..<4).reduce(0) { $0 | Int(data[offset + 5 + $1]) << (8 * $1) }
            }
            guard length > 0, length <= data.count - offset else { throw UMDTextError.malformed }
            result.append(Record(start: offset, length: length, kind: kind)); offset += length
        }
        return result
    }
    private static func put32(_ value: UInt32, into data: inout Data, at offset: Int) {
        for index in 0..<4 { data[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
    }
}
