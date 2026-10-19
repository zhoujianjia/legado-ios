import Foundation
import zlib

/// A deliberately bounded, unencrypted type-1 UMD subset. Offsets remain byte
/// offsets in the concatenated UTF-16LE payload, as in the original Java getters.
struct UMDTextDocument: Equatable, Sendable {
    struct Chapter: Equatable, Sendable {
        let title: String
        let rawByteOffset: Int
        let rawUTF16LE: Data
        let text: String
    }
    let metadata: [Int: String]
    let chapters: [Chapter]
    var title: String? { metadata[2] }
    var author: String? { metadata[3] }
}

enum UMDTextError: Error, Equatable {
    case unsupported, malformed, budgetExceeded, invalidUTF16, invalidCompression
}

enum UMDTextDecoder {
    struct Limits: Sendable {
        var inputBytes = 64 * 1_024 * 1_024
        var outputBytes = 32 * 1_024 * 1_024
        var chapters = 16_384
        var records = 65_536
    }

    /// Does no filesystem work. Its caller must run this on an owned worker task.
    static func decode(_ data: Data, limits: Limits = Limits()) throws -> UMDTextDocument {
        try Task.checkCancellation()
        guard limits.inputBytes > 0, limits.outputBytes > 0,
              limits.chapters > 0, limits.records > 0,
              data.count <= limits.inputBytes else { throw UMDTextError.budgetExceeded }
        var reader = Cursor(bytes: Array(data))
        guard try reader.u32() == 0xDE9A9B89 else { throw UMDTextError.unsupported }
        var metadata: [Int: String] = [:]
        var sawHeader = false
        var total: Int?
        var offsets: [Int] = []
        var titles: [String] = []
        var content = Data()
        var chunkIDs: [UInt32] = []
        var uniqueChunkIDs: Set<UInt32> = []
        var indexedIDs: [UInt32]?
        var section: Int?
        var key: UInt32 = 0
        var recordCount = 0
        var finished = false
        var sawOffsets = false
        var sawTitles = false

        while !reader.atEnd {
            try Task.checkCancellation()
            recordCount += 1
            guard recordCount <= limits.records else { throw UMDTextError.budgetExceeded }
            switch try reader.u8() {
            case 0x23:
                let kind = Int(try reader.u16())
                let flag = try reader.u8()
                let length = Int(try reader.u8())
                guard length >= 5 else { throw UMDTextError.malformed }
                var payload = Cursor(bytes: try reader.bytes(length - 5))
                guard sawHeader || kind == 1 else { throw UMDTextError.malformed }
                switch kind {
                case 1:
                    guard !sawHeader, flag == 0, length == 8 else { throw UMDTextError.malformed }
                    guard try payload.u8() == 1 else { throw UMDTextError.unsupported }
                    _ = try payload.bytes(2)
                    sawHeader = true
                case 2...9:
                    guard flag == 0, metadata[kind] == nil, total == nil else { throw UMDTextError.malformed }
                    metadata[kind] = try utf16(try payload.bytes(length - 5))
                case 11:
                    guard flag == 0, length == 9, total == nil else { throw UMDTextError.malformed }
                    let count = Int(try payload.u32())
                    guard count > 0, count % 2 == 0 else { throw UMDTextError.malformed }
                    guard count <= limits.outputBytes else { throw UMDTextError.budgetExceeded }
                    total = count
                case 131:
                    guard flag == 0, length == 9, total != nil, !sawOffsets else { throw UMDTextError.malformed }
                    key = try payload.u32()
                    sawOffsets = true
                case 132:
                    guard flag == 1, length == 9, !offsets.isEmpty, !sawTitles else { throw UMDTextError.malformed }
                    key = try payload.u32()
                    sawTitles = true
                case 241:
                    // The public writer inserts an all-zero license placeholder.
                    // A nonzero license/key is outside this unencrypted subset.
                    guard section == 132, !titles.isEmpty, !chunkIDs.isEmpty,
                          flag == 0, length == 21 else { throw UMDTextError.unsupported }
                    guard try payload.bytes(16).allSatisfy({ $0 == 0 }) else { throw UMDTextError.unsupported }
                case 129:
                    guard flag == 1, length == 9, !chunkIDs.isEmpty, indexedIDs == nil else { throw UMDTextError.malformed }
                    key = try payload.u32()
                case 12:
                    guard flag == 1, length == 9, indexedIDs != nil,
                          Int(try payload.u32()) == data.count, reader.atEnd else { throw UMDTextError.malformed }
                    finished = true
                default:
                    // Image books, DRM/key records, covers and unknown variants
                    // are rejected rather than silently consumed as text.
                    throw UMDTextError.unsupported
                }
                guard payload.atEnd else { throw UMDTextError.malformed }
                if kind != 241 { section = kind }
            case 0x24:
                let additionalKey = try reader.u32()
                let length = Int(try reader.u32())
                guard length >= 9, length - 9 <= reader.remaining else { throw UMDTextError.malformed }
                let payloadBytes = try reader.bytes(length - 9)
                var payload = Cursor(bytes: payloadBytes)
                switch section {
                case 131:
                    guard additionalKey == key, offsets.isEmpty, !payloadBytes.isEmpty,
                          payloadBytes.count % 4 == 0 else { throw UMDTextError.malformed }
                    guard payloadBytes.count / 4 <= limits.chapters else { throw UMDTextError.budgetExceeded }
                    while !payload.atEnd { offsets.append(Int(try payload.u32())) }
                case 132:
                    if additionalKey == key {
                        guard titles.isEmpty, chunkIDs.isEmpty else { throw UMDTextError.malformed }
                        for _ in offsets {
                            let count = Int(try payload.u8())
                            titles.append(try utf16(try payload.bytes(count)))
                        }
                        guard payload.atEnd else { throw UMDTextError.malformed }
                    } else {
                        guard !titles.isEmpty, indexedIDs == nil, !uniqueChunkIDs.contains(additionalKey),
                              let total else { throw UMDTextError.malformed }
                        let inflated = try inflateZlib(Data(payloadBytes), maximumBytes: total - content.count)
                        guard !inflated.isEmpty else { throw UMDTextError.malformed }
                        content.append(inflated)
                        chunkIDs.append(additionalKey)
                        uniqueChunkIDs.insert(additionalKey)
                    }
                case 129:
                    guard additionalKey == key, indexedIDs == nil, payloadBytes.count == chunkIDs.count * 4 else {
                        throw UMDTextError.malformed
                    }
                    var ids: [UInt32] = []
                    while !payload.atEnd { ids.append(try payload.u32()) }
                    guard ids == Array(chunkIDs.reversed()) else { throw UMDTextError.malformed }
                    indexedIDs = ids
                default: throw UMDTextError.malformed
                }
            default: throw UMDTextError.malformed
            }
        }
        guard finished, let total, total == content.count, !offsets.isEmpty,
              offsets.count == titles.count, offsets.first == 0 else { throw UMDTextError.malformed }
        var chapters: [UMDTextDocument.Chapter] = []
        for index in offsets.indices {
            try Task.checkCancellation()
            let start = offsets[index]
            let end = index + 1 < offsets.count ? offsets[index + 1] : total
            guard start % 2 == 0, end % 2 == 0, start >= 0,
                  start <= end, end <= total else { throw UMDTextError.malformed }
            let raw = content.subdata(in: start..<end)
            let text = try utf16(Array(raw)).replacingOccurrences(of: "\u{2029}", with: "\n")
            try Task.checkCancellation()
            chapters.append(.init(title: titles[index], rawByteOffset: start, rawUTF16LE: raw, text: text))
        }
        return UMDTextDocument(metadata: metadata, chapters: chapters)
    }

    /// Default inflateInit2 window accepts only a zlib wrapper, checks Adler-32,
    /// and rejects preset dictionaries. Require both STREAM_END and no tail.
    private static func inflateZlib(_ input: Data, maximumBytes: Int) throws -> Data {
        guard !input.isEmpty, maximumBytes > 0, input.count <= Int(uInt.max) else { throw UMDTextError.invalidCompression }
        var stream = z_stream()
        guard inflateInit2_(&stream, MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw UMDTextError.invalidCompression
        }
        defer { inflateEnd(&stream) }
        return try input.withUnsafeBytes { bytes in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: bytes.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            var output = Data()
            var chunk = [UInt8](repeating: 0, count: 16_384)
            while true {
                try Task.checkCancellation()
                let before = stream.total_in
                var status: Int32 = Z_OK
                let produced = chunk.withUnsafeMutableBytes { buffer -> Int in
                    stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(buffer.count)
                    status = inflate(&stream, Z_NO_FLUSH)
                    return buffer.count - Int(stream.avail_out)
                }
                guard produced <= maximumBytes - output.count else { throw UMDTextError.budgetExceeded }
                output.append(contentsOf: chunk.prefix(produced))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw UMDTextError.invalidCompression }
                    return output
                }
                guard status == Z_OK, produced > 0 || stream.total_in > before else { throw UMDTextError.invalidCompression }
            }
        }
    }

    /// Foundation decoding may repair malformed surrogates on some platforms;
    /// validate code units explicitly so chapter boundaries cannot split a pair.
    private static func utf16(_ bytes: [UInt8]) throws -> String {
        guard bytes.count % 2 == 0 else { throw UMDTextError.invalidUTF16 }
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var index = 0
        while index < bytes.count {
            if index % 16_384 == 0 { try Task.checkCancellation() }
            let unit = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
            units.append(unit)
            index += 2
        }
        var offset = 0
        var nextCancellationOffset = 0
        while offset < units.count {
            if offset >= nextCancellationOffset {
                try Task.checkCancellation()
                nextCancellationOffset = offset + 8_192
            }
            let unit = units[offset]
            if (0xD800...0xDBFF).contains(unit) {
                guard offset + 1 < units.count, (0xDC00...0xDFFF).contains(units[offset + 1]) else { throw UMDTextError.invalidUTF16 }
                offset += 2
            } else {
                guard !(0xDC00...0xDFFF).contains(unit) else { throw UMDTextError.invalidUTF16 }
                offset += 1
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    private struct Cursor {
        let bytes: [UInt8]
        var offset = 0
        var remaining: Int { bytes.count - offset }
        var atEnd: Bool { offset == bytes.count }
        mutating func bytes(_ count: Int) throws -> [UInt8] {
            guard count >= 0, count <= remaining else { throw UMDTextError.malformed }
            defer { offset += count }
            return Array(bytes[offset..<(offset + count)])
        }
        mutating func u8() throws -> UInt8 {
            guard remaining >= 1 else { throw UMDTextError.malformed }
            defer { offset += 1 }
            return bytes[offset]
        }
        mutating func u16() throws -> UInt16 {
            let first = try u8(); let second = try u8()
            return UInt16(first) | UInt16(second) << 8
        }
        mutating func u32() throws -> UInt32 {
            let first = try u16(); let second = try u16()
            return UInt32(first) | UInt32(second) << 16
        }
    }
}
