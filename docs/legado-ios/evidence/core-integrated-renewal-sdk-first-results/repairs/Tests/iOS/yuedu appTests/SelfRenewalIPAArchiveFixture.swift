import Foundation
import ReadiumZIPFoundation
import zlib
@testable import yuedu_app

/// Owned ZIP construction is independent of the production ZIP parser and
/// ZIPFoundation's archive writer. Public existing app fixtures supply CMS.
enum SelfRenewalIPAArchiveFixture {
    struct Member {
        var path: String
        var bytes: Data
        var method: UInt16 = 0
        var flags: UInt16 = 0x0800
        var attributes: UInt32 = 0o100644 << 16
        var extra = Data()
        var rawName: Data?
        var compressed: Data?
        var expandedSize: UInt32?
        var checksum: UInt32?
        /// nil = no descriptor; true = signature; false = unsigned descriptor.
        var descriptor: Bool?
    }
    struct Bytes: SelfRenewalIPAArchiveBytes {
        let data: Data
        var byteCount: Int { data.count }
        func read(at offset: Int, count: Int) throws -> Data {
            guard offset >= 0, count >= 0, count <= byteCount,
                  offset <= byteCount - count else { throw SelfRenewalIPAUnpacker.Failure.inputRead }
            return data.subdata(in: offset..<offset + count)
        }
    }
    static func ownedMembers(method: UInt16 = 0, descriptor: Bool? = nil) throws -> [Member] {
        var result: [Member] = []
        for bundle in SelfRenewalApplicationMaterialFixture.bundles {
            let root = "Payload/Owned.app" + (bundle.relativePath == "." ? "" : "/" + bundle.relativePath)
            for (name, base64) in [("Info.plist", bundle.infoBase64), ("embedded.mobileprovision", bundle.profileBase64),
                                   ("_CodeSignature/CodeResources", bundle.resourcesBase64), ("Owned", bundle.codeBase64)] {
                guard let bytes = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { throw CocoaError(.coderReadCorrupt) }
                result.append(Member(path: root + "/" + name, bytes: bytes, method: method, descriptor: descriptor))
            }
            result.append(Member(path: root + "/chapter.txt", bytes: Data("abc".utf8), method: method, descriptor: descriptor))
        }
        return result
    }
    static func archive(_ members: [Member]) throws -> Data {
        var local = Data()
        var central = Data()
        for member in members {
            let name = member.rawName ?? Data(member.path.utf8)
            let compressed = try member.compressed ?? (member.method == 8 ? deflated(member.bytes) : member.bytes)
            let checksum = member.checksum ?? member.bytes.crc32(checksum: 0)
            let size = member.expandedSize ?? UInt32(member.bytes.count)
            let offset = UInt32(local.count)
            let flags = member.flags | (member.descriptor == nil ? 0 : 8)
            u32(0x04034b50, to: &local); u16(20, to: &local); u16(flags, to: &local)
            u16(member.method, to: &local); u16(0, to: &local); u16(0x21, to: &local)
            u32(member.descriptor == nil ? checksum : 0, to: &local)
            u32(member.descriptor == nil ? UInt32(compressed.count) : 0, to: &local)
            u32(member.descriptor == nil ? size : 0, to: &local)
            u16(UInt16(name.count), to: &local); u16(UInt16(member.extra.count), to: &local)
            local.append(name); local.append(member.extra); local.append(compressed)
            if let signed = member.descriptor {
                if signed { u32(0x08074b50, to: &local) }
                u32(checksum, to: &local); u32(UInt32(compressed.count), to: &local); u32(size, to: &local)
            }
            u32(0x02014b50, to: &central); u16(0x0314, to: &central); u16(20, to: &central)
            u16(flags, to: &central); u16(member.method, to: &central); u16(0, to: &central); u16(0x21, to: &central)
            u32(checksum, to: &central); u32(UInt32(compressed.count), to: &central); u32(size, to: &central)
            u16(UInt16(name.count), to: &central); u16(UInt16(member.extra.count), to: &central)
            u16(0, to: &central); u16(0, to: &central); u16(0, to: &central)
            u32(member.attributes, to: &central); u32(offset, to: &central)
            central.append(name); central.append(member.extra)
        }
        let centralOffset = UInt32(local.count)
        local.append(central)
        u32(0x06054b50, to: &local); u16(0, to: &local); u16(0, to: &local)
        u16(UInt16(members.count), to: &local); u16(UInt16(members.count), to: &local)
        u32(UInt32(central.count), to: &local); u32(centralOffset, to: &local); u16(0, to: &local)
        return local
    }
    static func deflated(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw CocoaError(.coderInvalidValue) }
        defer { deflateEnd(&stream) }
        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var output = Data(count: max(64, Int(deflateBound(&stream, uLong(data.count)))))
            let status = output.withUnsafeMutableBytes { buffer -> Int32 in
                stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(buffer.count)
                return deflate(&stream, Z_FINISH)
            }
            guard status == Z_STREAM_END else { throw CocoaError(.coderInvalidValue) }
            output.count = Int(stream.total_out)
            return output
        }
    }
    static func u16(_ value: UInt16, to data: inout Data) { data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(truncatingIfNeeded: value >> 8)) }
    static func u32(_ value: UInt32, to data: inout Data) { u16(UInt16(truncatingIfNeeded: value), to: &data); u16(UInt16(truncatingIfNeeded: value >> 16), to: &data) }
    static func set16(_ value: UInt16, at offset: Int, in data: inout Data) { data[offset] = UInt8(truncatingIfNeeded: value); data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8) }
    static func set32(_ value: UInt32, at offset: Int, in data: inout Data) { set16(UInt16(truncatingIfNeeded: value), at: offset, in: &data); set16(UInt16(truncatingIfNeeded: value >> 16), at: offset + 2, in: &data) }
}
