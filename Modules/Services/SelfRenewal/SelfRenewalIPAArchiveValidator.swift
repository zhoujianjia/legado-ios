import Foundation

/// Random reads from a fixed, caller-independent archive snapshot. The reader
/// must reject out-of-bounds or unbounded requests; it never interprets paths.
protocol SelfRenewalIPAArchiveBytes: Sendable {
    var byteCount: Int { get }
    func read(at offset: Int, count: Int) throws -> Data
}

/// A deliberately bounded classic-ZIP subset for controlled IPA materials.
/// Metadata is checked before ZIPFoundation may decompress or create any entry.
enum SelfRenewalIPAArchiveValidator {
    enum Failure: Error, Sendable, Equatable {
        case archiveLimit, entryLimit, directoryLimit, expandedLimit, compressionRatioLimit
        case malformedZIP, unsupportedZIPFeature, unsupportedEncoding
        case unsafePath, duplicatePath, unsupportedFileType, invalidPayload
        case inconsistentLocalHeader, invalidDescriptor, overlappingEntries
    }
    enum Limits {
        static let archiveBytes = 536_870_912
        static let entries = SelfRenewalMaterialInventory.Limits.entries + 2
        // Bounded identity facts, independent of the number of open FDs.
        // The shipped Java home has 615 directories before app/container names.
        static let directories = 2_048
        /// Parent/root plus at most two temporary directory-walk descriptors.
        static let directoryDescriptors = 4
        static let centralBytes = 8_388_608
        static let compressedEntryBytes = SelfRenewalControlledMachOSigner.Limits.fileBytes
        static let expandedEntryBytes = SelfRenewalControlledMachOSigner.Limits.fileBytes
        static let expandedBytes = 536_870_912
        static let pathBytes = 1_024
        static let depth = 24
        static let extraBytes = 4_096
        static let commentBytes = 4_096
        static let chunkBytes = 65_536
    }
    struct Entry: Sendable, Equatable {
        let path: String
        let directory: Bool
        let compressionMethod: UInt16
        let checksum: UInt32
        let compressedBytes: Int
        let expandedBytes: Int
        let localOffset: Int
        let dataOffset: Int
        let endOffset: Int
        fileprivate init(path: String, directory: Bool, method: UInt16, checksum: UInt32,
            compressed: Int, expanded: Int, local: Int, data: Int, end: Int) {
            self.path = path; self.directory = directory; compressionMethod = method
            self.checksum = checksum; compressedBytes = compressed; expandedBytes = expanded
            localOffset = local; dataOffset = data; endOffset = end
        }
    }
    struct Plan: Sendable, Equatable {
        let entries: [Entry]
        let applicationPath: String
        let expandedBytes: Int
        fileprivate init(entries: [Entry], application: String, expanded: Int) {
            self.entries = entries; applicationPath = application; expandedBytes = expanded
        }
    }

    static func inspect(_ source: any SelfRenewalIPAArchiveBytes) throws -> Plan {
        precondition(!Thread.isMainThread, "IPA metadata inspection must stay off main")
        try Task.checkCancellation()
        guard source.byteCount >= 22, source.byteCount <= Limits.archiveBytes else { throw Failure.archiveLimit }
        let tailCount = min(source.byteCount, 22 + 65_535)
        let tailStart = source.byteCount - tailCount
        let tail = try source.read(at: tailStart, count: tailCount)
        var candidates: [Int] = []
        for position in stride(from: tail.count - 22, through: 0, by: -1) {
            if try u32(tail, position) == 0x06054b50,
               position + 22 + Int(try u16(tail, position + 20)) == tail.count {
                candidates.append(position)
            }
        }
        guard candidates.count == 1, let position = candidates.first else { throw Failure.malformedZIP }
        let end = tailStart + position
        let count = Int(try u16(tail, position + 10))
        let centralSize = Int(try u32(tail, position + 12))
        let centralStart = Int(try u32(tail, position + 16))
        guard try u16(tail, position + 4) == 0, try u16(tail, position + 6) == 0,
              Int(try u16(tail, position + 8)) == count,
              count != 0xffff, centralSize != 0xffffffff, centralStart != 0xffffffff else {
            throw Failure.unsupportedZIPFeature
        }
        guard count > 0, count <= Limits.entries else { throw Failure.entryLimit }
        guard Int(try u16(tail, position + 20)) <= Limits.commentBytes,
              centralSize > 0, centralSize <= Limits.centralBytes,
              centralStart >= 30, centralStart <= end, centralSize == end - centralStart else {
            throw Failure.malformedZIP
        }
        var entries: [Entry] = []
        var cursor = centralStart
        var expanded = 0
        var explicitPaths = Set<String>()
        var tree: [String: (spelling: String, directory: Bool)] = [:]
        var directoryCount = 0
        var applications = Set<String>()
        for _ in 0..<count {
            try Task.checkCancellation()
            guard cursor <= end - 46 else { throw Failure.malformedZIP }
            let header = try source.read(at: cursor, count: 46)
            guard try u32(header, 0) == 0x02014b50 else { throw Failure.malformedZIP }
            let madeBy = try u16(header, 4)
            let version = try u16(header, 6)
            let flags = try u16(header, 8)
            let method = try u16(header, 10)
            let checksum = try u32(header, 16)
            let compressed = Int(try u32(header, 20))
            let size = Int(try u32(header, 24))
            let nameLength = Int(try u16(header, 28))
            let extraLength = Int(try u16(header, 30))
            let commentLength = Int(try u16(header, 32))
            let local = Int(try u32(header, 42))
            guard version >= 10, version <= 20, method == 0 || method == 8,
                  flags & ~UInt16(0x080e) == 0,
                  method == 8 || flags & 6 == 0,
                  try u16(header, 34) == 0,
                  [UInt16(0), 3, 19].contains(madeBy >> 8),
                  compressed != 0xffffffff, size != 0xffffffff, local != 0xffffffff else {
                throw Failure.unsupportedZIPFeature
            }
            guard nameLength > 0, nameLength <= Limits.pathBytes,
                  extraLength <= Limits.extraBytes, commentLength <= Limits.commentBytes,
                  nameLength + extraLength + commentLength <= end - cursor - 46 else { throw Failure.malformedZIP }
            let rawName = try source.read(at: cursor + 46, count: nameLength)
            guard flags & 0x0800 != 0 || rawName.allSatisfy({ $0 < 128 }),
                  let path = String(data: rawName, encoding: .utf8) else { throw Failure.unsupportedEncoding }
            let directory = path.hasSuffix("/")
            let components = try pathComponents(path, directory: directory)
            try insert(components, directory: directory, explicit: &explicitPaths, tree: &tree, directoryCount: &directoryCount)
            guard components[0] == "Payload" else { throw Failure.invalidPayload }
            if components.count == 1 {
                guard directory else { throw Failure.invalidPayload }
            } else {
                guard components[1].hasSuffix(".app"), components[1].count > 4,
                      components.count > 2 || directory else { throw Failure.invalidPayload }
                applications.insert(components[1])
            }
            let attributes = try u32(header, 38)
            let unixType = (attributes >> 16) & 0xf000
            let expectedType: UInt32 = directory ? 0x4000 : 0x8000
            guard unixType == 0 || unixType == expectedType,
                  attributes & 0x08 == 0,
                  attributes & 0x10 == 0 || directory else { throw Failure.unsupportedFileType }
            if directory {
                guard compressed == 0, size == 0, checksum == 0, method == 0, flags & 8 == 0 else { throw Failure.unsupportedFileType }
            }
            guard compressed <= Limits.compressedEntryBytes, size <= Limits.expandedEntryBytes,
                  size <= Limits.expandedBytes - expanded else { throw Failure.expandedLimit }
            guard size <= max(1, compressed) * 200 + 65_536 else { throw Failure.compressionRatioLimit }
            guard method != 0 || compressed == size else { throw Failure.inconsistentLocalHeader }
            guard directory || method == 0 || compressed > 0 else { throw Failure.malformedZIP }
            try extras(source.read(at: cursor + 46 + nameLength, count: extraLength))
            let entry = try localEntry(source, centralStart: centralStart, path: path, rawName: rawName,
                directory: directory, version: version, flags: flags, method: method, checksum: checksum,
                compressed: compressed, size: size, offset: local)
            entries.append(entry)
            expanded += size
            cursor += 46 + nameLength + extraLength + commentLength
        }
        guard cursor == end, applications.count == 1, let application = applications.first else { throw Failure.invalidPayload }
        var previous = 0
        for entry in entries.sorted(by: { $0.localOffset < $1.localOffset }) {
            guard entry.localOffset == previous else { throw Failure.overlappingEntries }
            previous = entry.endOffset
        }
        guard previous == centralStart else { throw Failure.overlappingEntries }
        return Plan(entries: entries, application: "Payload/" + application, expanded: expanded)
    }

    private static func localEntry(_ source: any SelfRenewalIPAArchiveBytes, centralStart: Int,
        path: String, rawName: Data, directory: Bool, version: UInt16, flags: UInt16, method: UInt16,
        checksum: UInt32, compressed: Int, size: Int, offset: Int) throws -> Entry {
        guard offset >= 0, offset <= centralStart - 30 else { throw Failure.inconsistentLocalHeader }
        let header = try source.read(at: offset, count: 30)
        let nameLength = Int(try u16(header, 26))
        let extraLength = Int(try u16(header, 28))
        guard try u32(header, 0) == 0x04034b50,
              try u16(header, 4) == version, try u16(header, 6) == flags,
              try u16(header, 8) == method, nameLength == rawName.count,
              extraLength <= Limits.extraBytes,
              nameLength + extraLength <= centralStart - offset - 30 else { throw Failure.inconsistentLocalHeader }
        let name = try source.read(at: offset + 30, count: nameLength)
        guard name == rawName else { throw Failure.inconsistentLocalHeader }
        try extras(source.read(at: offset + 30 + nameLength, count: extraLength))
        let dataOffset = offset + 30 + nameLength + extraLength
        guard compressed <= centralStart - dataOffset else { throw Failure.inconsistentLocalHeader }
        let localCRC = try u32(header, 14)
        let localCompressed = try u32(header, 18)
        let localSize = try u32(header, 22)
        let matches = localCRC == checksum && Int(localCompressed) == compressed && Int(localSize) == size
        let zero = localCRC == 0 && localCompressed == 0 && localSize == 0
        var endOffset = dataOffset + compressed
        if flags & 8 != 0 {
            guard matches || zero, endOffset <= centralStart - 12 else { throw Failure.invalidDescriptor }
            let prefix = try source.read(at: endOffset, count: 4)
            let signed = try u32(prefix, 0) == 0x08074b50
            let count = signed ? 16 : 12
            guard count <= centralStart - endOffset else { throw Failure.invalidDescriptor }
            let descriptor = try source.read(at: endOffset, count: count)
            let base = signed ? 4 : 0
            guard try u32(descriptor, base) == checksum,
                  Int(try u32(descriptor, base + 4)) == compressed,
                  Int(try u32(descriptor, base + 8)) == size else { throw Failure.invalidDescriptor }
            endOffset += count
        } else if !matches { throw Failure.inconsistentLocalHeader }
        return Entry(path: path, directory: directory, method: method, checksum: checksum,
            compressed: compressed, expanded: size, local: offset, data: dataOffset, end: endOffset)
    }

    private static func extras(_ bytes: Data) throws {
        var cursor = 0
        var identifiers = Set<UInt16>()
        while cursor < bytes.count {
            guard cursor <= bytes.count - 4 else { throw Failure.malformedZIP }
            let identifier = try u16(bytes, cursor)
            let count = Int(try u16(bytes, cursor + 2))
            // Ignore only explicitly selected non-path/non-link metadata. No
            // extra field, permission, timestamp or owner is applied to output.
            guard [UInt16(0x5455), 0x7875, 0x5855, 0x000a].contains(identifier),
                  identifiers.insert(identifier).inserted else { throw Failure.unsupportedZIPFeature }
            guard count <= bytes.count - cursor - 4 else { throw Failure.malformedZIP }
            cursor += 4 + count
        }
    }

    private static func pathComponents(_ path: String, directory: Bool) throws -> [String] {
        guard !path.contains("\\"), !path.contains(":"),
              path.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { throw Failure.unsafePath }
        let raw = directory ? String(path.dropLast()) : path
        let components = raw.components(separatedBy: "/")
        guard components.count <= Limits.depth,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255
                && !$0.hasSuffix(".") && !$0.hasSuffix(" ") }) else { throw Failure.unsafePath }
        return components
    }

    private static func insert(_ parts: [String], directory: Bool, explicit: inout Set<String>,
        tree: inout [String: (spelling: String, directory: Bool)], directoryCount: inout Int) throws {
        var raw = ""
        for (index, part) in parts.enumerated() {
            raw += (raw.isEmpty ? "" : "/") + part
            let key = raw.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            let isDirectory = index < parts.count - 1 || directory
            if let old = tree[key], !old.spelling.utf8.elementsEqual(raw.utf8) || old.directory != isDirectory { throw Failure.duplicatePath }
            if tree[key] == nil, isDirectory {
                guard directoryCount < Limits.directories else { throw Failure.directoryLimit }
                directoryCount += 1
            }
            tree[key] = (raw, isDirectory)
            if index == parts.count - 1, !explicit.insert(key).inserted { throw Failure.duplicatePath }
        }
    }
    private static func u16(_ bytes: Data, _ offset: Int) throws -> UInt16 {
        guard offset >= 0, bytes.count >= 2, offset <= bytes.count - 2 else { throw Failure.malformedZIP }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }
    private static func u32(_ bytes: Data, _ offset: Int) throws -> UInt32 {
        UInt32(try u16(bytes, offset)) | UInt32(try u16(bytes, offset + 2)) << 16
    }
}
