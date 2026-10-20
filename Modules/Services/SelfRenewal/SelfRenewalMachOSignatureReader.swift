import Darwin
import Foundation

/// The basic entry publishes structural observations, never signing authority
/// or an account identity assertion. Layouts follow Apple's mach-o/{loader,fat}.h
/// and osfmk/kern/cs_blobs.h. Explicit content-hash/signature entries add their
/// separate bounded proofs; Apple authority and entitlement semantics stay unverified.
enum SelfRenewalMachOSignatureReader {
    enum Failure: Error, Sendable, Equatable {
        case invalidRoot, invalidPath, unreadableFile, linkNotAllowed, fileChangedDuringRead
        case fileSizeLimit, totalReadLimit, truncatedRead, unsupportedMagic
        case architectureLimit, malformedFat, overlappingRanges, architectureMismatch
        case commandLimit, malformedLoadCommand, unknownRequiredCommand, duplicateCodeSignature
        case signatureSizeLimit, malformedSignature, unsupportedSignatureSlot
        case malformedCodeDirectory, unsupportedCodeDirectory, unsupportedScatter
        case unsupportedPreEncryptedHashes, unsupportedLinkage, malformedString
    }
    enum ByteOrder: Sendable, Equatable { case big, little }
    enum Container: Sendable, Equatable { case thin32, thin64, fat32, fat64 }
    struct ByteRange: Sendable, Equatable {
        let offset: UInt64
        let byteCount: Int
        var end: UInt64 { offset + UInt64(byteCount) }
    }
    struct CodeDirectory: Sendable, Equatable {
        let slot: UInt32
        let version: UInt32
        let flags: UInt32
        /// Untrusted values read from the CodeDirectory, not signed identity.
        let identifier: String
        let teamIdentifier: String?
        let hashType: UInt8
        let hashByteCount: Int
        let codeSlotCount: UInt32
        let specialSlotCount: UInt32
        let codeLimit: UInt64
        let pageSizeLog2: UInt8
        let hashOffset: Int
        /// Relative to the beginning of the embedded SuperBlob.
        let blobRange: ByteRange
    }
    struct Blob: Sendable, Equatable {
        let slot: UInt32
        let magic: UInt32
        /// Relative to the beginning of LC_CODE_SIGNATURE's data.
        let range: ByteRange
    }
    struct EmbeddedSignature: Sendable, Equatable {
        let range: ByteRange
        let superBlobByteCount: Int
        let blobs: [Blob]
        let codeDirectories: [CodeDirectory]
        /// BlobWrapper payload size only. An empty ad-hoc wrapper is zero;
        /// absence of the slot is nil. ASN.1/CMS is unparsed in both cases.
        let cmsPayloadByteCount: Int?
        var cryptographicVerificationPerformed: Bool { false }
    }
    struct Slice: Sendable, Equatable {
        let range: ByteRange
        let cpuType: UInt32
        let cpuSubtype: UInt32
        let is64Bit: Bool
        let byteOrder: ByteOrder
        let signature: EmbeddedSignature?
    }
    struct ParsedFile: Sendable, Equatable {
        let container: Container
        let slices: [Slice]
        let bytesRead: Int
        var cryptographicVerificationPerformed: Bool { false }
        var replacementAuthorized: Bool { false }
    }
    struct CodeMaterial: Sendable, Equatable {
        let file: SelfRenewalMaterialInventory.FileFact
        let structure: ParsedFile
        let contentHashVerification: SelfRenewalCodeDirectoryHashVerifier.Verification?
        let signedCodeVerification: SelfRenewalSignedCodeVerifier.Verification?
    }
    struct Materials: Sendable, Equatable {
        let inventory: SelfRenewalMaterialInventory.Inventory
        let code: [CodeMaterial]
        /// Additional reads only; does not alter the inventory's separate budget.
        let signatureStructureBytesRead: Int
        let contentHashBytesRead: Int
        let signatureVerificationBytesRead: Int
        var cryptographicVerificationPerformed: Bool { false }
        var accountIdentityEstablished: Bool { false }
        var replacementAuthorized: Bool { false }
    }
    enum Limits {
        static let architectures = 16
        static let commands = 4_096
        static let commandBytes = 1_048_576
        static let signatureBytes = 16_777_216
        static let blobs = 32
        static let stringBytes = 255
        static let totalReadBytes = 67_108_864
        static let ownedMaterialBytes = SelfRenewalResourceSealVerifier.Limits.envelopeBytes
        static let ownedFileReadBytes = 1_073_741_824
        static let ownedFileChunkBytes = 65_536
    }

    /// The supplied app must be a caller-owned, already unpacked, quiescent
    /// staging directory. No app data or executable is changed. Each descendant
    /// is opened relative to a directory FD with O_NOFOLLOW, then rechecked.
    nonisolated static func read(unpackedApplication root: URL) async throws -> Materials {
        try await read(unpackedApplication: root, verifyContentHashes: false, signatureTrust: nil)
    }

    nonisolated static func readVerifyingContentHashes(unpackedApplication root: URL) async throws -> Materials {
        try await read(unpackedApplication: root, verifyContentHashes: true, signatureTrust: nil)
    }

    nonisolated static func readVerifyingSignatures(unpackedApplication root: URL,
        anchors: [Data], at date: Date) async throws -> Materials {
        try await read(unpackedApplication: root, verifyContentHashes: true,
            signatureTrust: SignatureTrust(anchors: anchors, date: date))
    }
    private struct SignatureTrust: Sendable {
        let anchors: [Data]
        let date: Date
    }

    private nonisolated static func read(unpackedApplication root: URL, verifyContentHashes: Bool,
        signatureTrust: SignatureTrust?) async throws -> Materials {
        let inventory = try await SelfRenewalMaterialInventory.read(unpackedApplication: root)
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            try readSynchronously(root: root, inventory: inventory, verifyContentHashes: verifyContentHashes,
                signatureTrust: signatureTrust)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// Pure bounded parser used by the file reader and generated fixtures alike.
    /// The callback must return exactly the requested range; never a whole file.
    static func parse(fileByteCount: UInt64,
        readRange: (ByteRange) throws -> Data) throws -> ParsedFile {
        guard fileByteCount >= 4,
              fileByteCount <= UInt64(SelfRenewalMaterialInventory.Limits.fileBytes) else {
            throw Failure.fileSizeLimit
        }
        var bytesRead = 0
        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            try Task.checkCancellation()
            guard count >= 0, offset <= fileByteCount,
                  UInt64(count) <= fileByteCount - offset else { throw Failure.truncatedRead }
            guard bytesRead <= Limits.totalReadBytes - count else { throw Failure.totalReadLimit }
            let data = try readRange(ByteRange(offset: offset, byteCount: count))
            guard data.count == count else { throw Failure.truncatedRead }
            bytesRead += count
            return Data(data)
        }
        let magic = try number32(read(0, 4), 0, .big)
        let container: Container
        let order: ByteOrder
        switch magic {
        case 0xfeedface: container = .thin32; order = .big
        case 0xcefaedfe: container = .thin32; order = .little
        case 0xfeedfacf: container = .thin64; order = .big
        case 0xcffaedfe: container = .thin64; order = .little
        case 0xcafebabe: container = .fat32; order = .big
        case 0xbebafeca: container = .fat32; order = .little
        case 0xcafebabf: container = .fat64; order = .big
        case 0xbfbafeca: container = .fat64; order = .little
        default: throw Failure.unsupportedMagic
        }
        var slices: [Slice] = []
        if container == .thin32 || container == .thin64 {
            slices.append(try parseSlice(range: ByteRange(offset: 0, byteCount: Int(fileByteCount)),
                expectedArchitecture: nil, read: read))
        } else {
            let count = Int(try number32(read(4, 4), 0, order))
            guard count > 0, count <= Limits.architectures else { throw Failure.architectureLimit }
            let stride = container == .fat64 ? 32 : 20
            let tableEnd = 8 + count * stride
            let table = try read(8, count * stride)
            var ranges: [ByteRange] = []
            var architectures = Set<UInt64>()
            for index in 0..<count {
                let start = index * stride
                let cpu = try number32(table, start, order)
                let subtype = try number32(table, start + 4, order)
                let offset = try container == .fat64
                    ? number64(table, start + 8, order) : UInt64(number32(table, start + 8, order))
                let size = try container == .fat64
                    ? number64(table, start + 16, order) : UInt64(number32(table, start + 12, order))
                let alignment = try number32(table, start + (container == .fat64 ? 24 : 16), order)
                guard alignment <= 30, offset >= UInt64(tableEnd), offset <= fileByteCount,
                      size >= 28, size <= fileByteCount - offset,
                      offset % (UInt64(1) << alignment) == 0 else { throw Failure.malformedFat }
                if container == .fat64, try number32(table, start + 28, order) != 0 {
                    throw Failure.malformedFat
                }
                guard architectures.insert((UInt64(cpu) << 32) | UInt64(subtype)).inserted else {
                    throw Failure.malformedFat
                }
                let range = ByteRange(offset: offset, byteCount: Int(size))
                try appendDisjoint(range, to: &ranges)
                slices.append(try parseSlice(range: range,
                    expectedArchitecture: (cpu, subtype), read: read))
            }
        }
        return ParsedFile(container: container, slices: slices, bytesRead: bytesRead)
    }

    private static func parseSlice(range: ByteRange, expectedArchitecture: (UInt32, UInt32)?,
        read: (UInt64, Int) throws -> Data) throws -> Slice {
        let first = try read(range.offset, 28)
        let magic = try number32(first, 0, .big)
        let is64: Bool
        let order: ByteOrder
        switch magic {
        case 0xfeedface: is64 = false; order = .big
        case 0xcefaedfe: is64 = false; order = .little
        case 0xfeedfacf: is64 = true; order = .big
        case 0xcffaedfe: is64 = true; order = .little
        default: throw Failure.unsupportedMagic
        }
        let headerSize = is64 ? 32 : 28
        guard range.byteCount >= headerSize else { throw Failure.malformedLoadCommand }
        if is64 { _ = try read(range.offset + 28, 4) }
        let cpu = try number32(first, 4, order)
        let subtype = try number32(first, 8, order)
        if let expectedArchitecture,
           cpu != expectedArchitecture.0 || subtype != expectedArchitecture.1 { throw Failure.architectureMismatch }
        let count = Int(try number32(first, 16, order))
        let size = Int(try number32(first, 20, order))
        guard count <= Limits.commands, size <= Limits.commandBytes else { throw Failure.commandLimit }
        guard size <= range.byteCount - headerSize, count <= size / 8 else { throw Failure.malformedLoadCommand }
        let commands = try read(range.offset + UInt64(headerSize), size)
        var cursor = 0
        var signatureRange: ByteRange?
        // Unknown optional commands may be skipped by cmdsize. Unknown required
        // dyld commands are rejected rather than pretending the file is understood.
        let knownRequired: Set<UInt32> = [0x80000018, 0x8000001c, 0x8000001f, 0x80000022,
            0x80000023, 0x80000028, 0x80000033, 0x80000034, 0x80000035]
        for _ in 0..<count {
            try Task.checkCancellation()
            let command = try number32(commands, cursor, order)
            let commandSize = Int(try number32(commands, cursor + 4, order))
            guard commandSize >= 8, commandSize % (is64 ? 8 : 4) == 0,
                  commandSize <= size - cursor else { throw Failure.malformedLoadCommand }
            if command & 0x80000000 != 0, !knownRequired.contains(command) {
                throw Failure.unknownRequiredCommand
            }
            if command == 0x1d {
                guard signatureRange == nil else { throw Failure.duplicateCodeSignature }
                guard commandSize == 16 else { throw Failure.malformedLoadCommand }
                let offset = UInt64(try number32(commands, cursor + 8, order))
                let length = Int(try number32(commands, cursor + 12, order))
                guard length >= 12, length <= Limits.signatureBytes else { throw Failure.signatureSizeLimit }
                guard offset >= UInt64(headerSize + size), offset <= UInt64(range.byteCount),
                      UInt64(length) <= UInt64(range.byteCount) - offset else { throw Failure.malformedSignature }
                signatureRange = ByteRange(offset: range.offset + offset, byteCount: length)
            }
            cursor += commandSize
        }
        guard cursor == size else { throw Failure.malformedLoadCommand }
        let signature: EmbeddedSignature?
        if let signatureRange {
            let bytes = try read(signatureRange.offset, signatureRange.byteCount)
            signature = try parseSignature(bytes, range: signatureRange, slice: range)
        } else { signature = nil }
        return Slice(range: range, cpuType: cpu, cpuSubtype: subtype, is64Bit: is64,
            byteOrder: order, signature: signature)
    }

    private static func parseSignature(_ data: Data, range: ByteRange,
        slice: ByteRange) throws -> EmbeddedSignature {
        guard try number32(data, 0, .big) == 0xfade0cc0 else { throw Failure.malformedSignature }
        let length = Int(try number32(data, 4, .big))
        let count = Int(try number32(data, 8, .big))
        guard count > 0, count <= Limits.blobs, length >= 12 + count * 8,
              length <= data.count else { throw Failure.malformedSignature }
        // LC datasize can include zero alignment padding outside SuperBlob.length.
        guard data[length..<data.count].allSatisfy({ $0 == 0 }) else { throw Failure.malformedSignature }
        var types = Set<UInt32>()
        var occupied: [ByteRange] = []
        var blobs: [Blob] = []
        var directories: [CodeDirectory] = []
        var cmsBytes: Int?
        for index in 0..<count {
            try Task.checkCancellation()
            let slot = try number32(data, 12 + index * 8, .big)
            let offset = Int(try number32(data, 16 + index * 8, .big))
            guard types.insert(slot).inserted, offset >= 12 + count * 8,
                  offset <= length - 8 else { throw Failure.malformedSignature }
            let magic = try number32(data, offset, .big)
            let size = Int(try number32(data, offset + 4, .big))
            guard size >= 8, size <= length - offset else { throw Failure.malformedSignature }
            let blobRange = ByteRange(offset: UInt64(offset), byteCount: size)
            try appendDisjoint(blobRange, to: &occupied)
            let blob = Blob(slot: slot, magic: magic, range: blobRange)
            blobs.append(blob)
            if slot == 0 || (0x1000..<0x1005).contains(slot) {
                guard magic == 0xfade0c02 else { throw Failure.malformedCodeDirectory }
                directories.append(try parseCodeDirectory(data.subdata(in: offset..<(offset + size)),
                    slot: slot, blobRange: blobRange, codeBytesAvailable: range.offset - slice.offset))
            } else if slot == 0x10000 {
                guard magic == 0xfade0b01 else { throw Failure.malformedSignature }
                cmsBytes = size - 8
            } else {
                let knownMagic: [UInt32: UInt32] = [2: 0xfade0c01, 5: 0xfade7171, 7: 0xfade7172,
                    8: 0xfade8181, 9: 0xfade8181, 10: 0xfade8181, 11: 0xfade8181]
                guard let expected = knownMagic[slot] else { throw Failure.unsupportedSignatureSlot }
                guard magic == expected else { throw Failure.malformedSignature }
            }
        }
        guard types.contains(0) else { throw Failure.malformedSignature }
        return EmbeddedSignature(range: range, superBlobByteCount: length, blobs: blobs,
            codeDirectories: directories, cmsPayloadByteCount: cmsBytes)
    }

    /// Reused when the content verifier re-reads the hash table from the same FD.
    static func parseCodeDirectory(_ data: Data, slot: UInt32, blobRange: ByteRange,
        codeBytesAvailable: UInt64) throws -> CodeDirectory {
        let version = try number32(data, 8, .big)
        let sizes: [UInt32: Int] = [0x20001: 44, 0x20100: 48, 0x20200: 52,
            0x20300: 64, 0x20400: 88, 0x20500: 96, 0x20600: 108]
        guard let headerSize = sizes[version] else { throw Failure.unsupportedCodeDirectory }
        guard data.count >= headerSize else { throw Failure.malformedCodeDirectory }
        let flags = try number32(data, 12, .big)
        let hashOffset = Int(try number32(data, 16, .big))
        let identifierOffset = Int(try number32(data, 20, .big))
        let specialSlots = try number32(data, 24, .big)
        let codeSlots = try number32(data, 28, .big)
        let codeLimit32 = UInt64(try number32(data, 32, .big))
        let hashSize = Int(data[data.startIndex + 36])
        let hashType = data[data.startIndex + 37]
        let pageSize = data[data.startIndex + 39]
        let expectedHashSize: [UInt8: Int] = [1: 20, 2: 32, 3: 20, 4: 48]
        guard expectedHashSize[hashType] == hashSize, pageSize <= 30 else { throw Failure.unsupportedCodeDirectory }
        guard try number32(data, 40, .big) == 0 else { throw Failure.malformedCodeDirectory }
        if version >= 0x20100, try number32(data, 44, .big) != 0 { throw Failure.unsupportedScatter }
        var limit = codeLimit32
        if version >= 0x20300 {
            guard try number32(data, 52, .big) == 0 else { throw Failure.malformedCodeDirectory }
            let limit64 = try number64(data, 56, .big)
            if limit64 != 0 { limit = limit64 }
        }
        guard limit > 0, limit <= codeBytesAvailable else { throw Failure.malformedCodeDirectory }
        let pageBytes = pageSize == 0 ? limit : UInt64(1) << pageSize
        let expectedSlots = (limit - 1) / pageBytes + 1
        guard UInt64(codeSlots) == expectedSlots else { throw Failure.malformedCodeDirectory }
        let specialBytes = UInt64(specialSlots) * UInt64(hashSize)
        let codeBytes = UInt64(codeSlots) * UInt64(hashSize)
        guard hashOffset >= headerSize, hashOffset <= data.count,
              specialBytes <= UInt64(hashOffset - headerSize),
              codeBytes <= UInt64(data.count - hashOffset) else { throw Failure.malformedCodeDirectory }
        let hashStart = hashOffset - Int(specialBytes)
        var occupied = [ByteRange(offset: 0, byteCount: headerSize),
            ByteRange(offset: UInt64(hashStart), byteCount: Int(specialBytes + codeBytes))]
        let identifier = try string(data, at: identifierOffset, minimum: headerSize)
        try appendDisjoint(identifier.1, to: &occupied)
        var team: String?
        if version >= 0x20200 {
            let offset = Int(try number32(data, 48, .big))
            if offset != 0 {
                let value = try string(data, at: offset, minimum: headerSize)
                try appendDisjoint(value.1, to: &occupied)
                team = value.0
            }
        }
        if version >= 0x20400 {
            let base = try number64(data, 64, .big)
            let size = try number64(data, 72, .big)
            guard base <= limit, size <= limit - base else { throw Failure.malformedCodeDirectory }
        }
        if version >= 0x20500, try number32(data, 92, .big) != 0 { throw Failure.unsupportedPreEncryptedHashes }
        if version >= 0x20600 {
            guard data[data.startIndex + 96] == 0, data[data.startIndex + 97] == 0,
                  data[data.startIndex + 98] == 0, data[data.startIndex + 99] == 0,
                  try number32(data, 100, .big) == 0, try number32(data, 104, .big) == 0 else {
                throw Failure.unsupportedLinkage
            }
        }
        return CodeDirectory(slot: slot, version: version, flags: flags, identifier: identifier.0,
            teamIdentifier: team, hashType: hashType, hashByteCount: hashSize,
            codeSlotCount: codeSlots, specialSlotCount: specialSlots, codeLimit: limit, pageSizeLog2: pageSize,
            hashOffset: hashOffset, blobRange: blobRange)
    }

    private static func string(_ data: Data, at offset: Int, minimum: Int) throws -> (String, ByteRange) {
        guard offset >= minimum, offset < data.count else { throw Failure.malformedString }
        let end = min(data.count, offset + Limits.stringBytes + 1)
        let bytes = data[offset..<end]
        // This is a C-string structure observation, not a bundle-ID grammar.
        // Preserve the bounded UTF-8 value (including whitespace/empty values);
        // identity and display semantics belong to later untrusted-input users.
        guard let nul = bytes.firstIndex(of: 0),
              let value = String(data: data.subdata(in: offset..<nul), encoding: .utf8) else {
            throw Failure.malformedString
        }
        return (value, ByteRange(offset: UInt64(offset), byteCount: nul - offset + 1))
    }
    private static func appendDisjoint(_ range: ByteRange, to values: inout [ByteRange]) throws {
        guard !values.contains(where: { range.offset < $0.end && $0.offset < range.end }) else {
            throw Failure.overlappingRanges
        }
        values.append(range)
    }
    private static func number32(_ data: Data, _ offset: Int, _ order: ByteOrder) throws -> UInt32 {
        guard offset >= 0, offset <= data.count - 4 else { throw Failure.truncatedRead }
        let bytes = (0..<4).map { UInt32(data[data.startIndex + offset + $0]) }
        return order == .big ? bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3]
            : bytes[3] << 24 | bytes[2] << 16 | bytes[1] << 8 | bytes[0]
    }
    private static func number64(_ data: Data, _ offset: Int, _ order: ByteOrder) throws -> UInt64 {
        let a = UInt64(try number32(data, offset, order))
        let b = UInt64(try number32(data, offset + 4, order))
        return order == .big ? a << 32 | b : b << 32 | a
    }

    private static func readSynchronously(root suppliedRoot: URL,
        inventory: SelfRenewalMaterialInventory.Inventory, verifyContentHashes: Bool,
        signatureTrust: SignatureTrust?) throws -> Materials {
        precondition(!Thread.isMainThread, "Renewal signature reads must stay off main")
        try Task.checkCancellation()
        let rootFD = try openRoot(suppliedRoot)
        defer { Darwin.close(rootFD) }
        let started = SourcePerfTrace.now
        var bytesRead = 0
        var contentReadBytes = 0
        var hashOperations = 0
        var signatureReadBytes = 0
        var code: [CodeMaterial] = []
        defer {
            SourcePerfTrace.record("renewal.material.macho",
                "files=\(code.count) bytes=\(bytesRead) hashBytes=\(contentReadBytes) signatureBytes=\(signatureReadBytes) hashOperations=\(hashOperations) main=\(Thread.isMainThread)",
                since: started, thresholdMs: 0)
        }
        for item in inventory.codeFiles {
            try Task.checkCancellation()
            let descriptor = try openCodeFile(item.file, rootFD: rootFD)
            defer { Darwin.close(descriptor) }
            let before = try status(descriptor, expectedBytes: item.file.byteCount)
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            let parsed: ParsedFile
            let verification: SelfRenewalCodeDirectoryHashVerifier.Verification?
            let signedVerification: SelfRenewalSignedCodeVerifier.Verification?
            if verifyContentHashes {
                let component = inventory.components.first { $0.executable?.file.relativePath == item.file.relativePath }
                let verified = try SelfRenewalCodeDirectoryHashVerifier.verify(fileByteCount: UInt64(item.file.byteCount),
                    maximumContentBytes: SelfRenewalCodeDirectoryHashVerifier.Limits.totalContentReadBytes - contentReadBytes,
                    maximumHashOperations: SelfRenewalCodeDirectoryHashVerifier.Limits.totalHashOperations - hashOperations,
                    readStructureRange: { range in
                        try readRange(handle, range: range, budget: &bytesRead, maximum: Limits.totalReadBytes)
                    }, readContentRange: { range in
                        try readRange(handle, range: range, budget: &contentReadBytes,
                            maximum: SelfRenewalCodeDirectoryHashVerifier.Limits.totalContentReadBytes)
                    }, externalSpecialSlot: { slot, remaining in
                        guard let component else { return nil }
                        let fact: SelfRenewalMaterialInventory.FileFact?
                        if slot == 1 {
                            let path = component.relativePath == "." ? "Info.plist" : component.relativePath + "/Info.plist"
                            fact = try materialFact(relativePath: path, rootFD: rootFD,
                                maximumBytes: SelfRenewalMaterialInventory.Limits.plistBytes)
                        } else if slot == 3 { fact = component.codeResources }
                        else { return nil }
                        guard let fact else { return nil }
                        guard fact.byteCount <= Int64(remaining) else { throw SelfRenewalCodeDirectoryHashVerifier.Failure.contentReadLimit }
                        let bytes = try readOwnedMaterial(root: suppliedRoot, fact: fact,
                            maximumBytes: max(1, min(remaining, Limits.ownedMaterialBytes)))
                        contentReadBytes += bytes.count
                        return bytes
                    })
                parsed = verified.structure
                verification = verified.verification
                hashOperations += verified.verification.hashOperations
                if let signatureTrust {
                    let bound = try SelfRenewalSignedCodeVerifier.bind(verified,
                        anchors: signatureTrust.anchors, at: signatureTrust.date,
                        maximumReadBytes: SelfRenewalSignedCodeVerifier.Limits.additionalReadBytes - signatureReadBytes) { range in
                            try readRange(handle, range: range, budget: &contentReadBytes,
                                maximum: SelfRenewalCodeDirectoryHashVerifier.Limits.totalContentReadBytes)
                        }
                    signedVerification = bound
                    signatureReadBytes += bound.additionalBytesRead
                } else { signedVerification = nil }
            } else {
                parsed = try parse(fileByteCount: UInt64(item.file.byteCount)) { range in
                    try readRange(handle, range: range, budget: &bytesRead, maximum: Limits.totalReadBytes)
                }
                verification = nil
                signedVerification = nil
            }
            let after = try status(descriptor, expectedBytes: item.file.byteCount)
            try unchanged(before, after)
            code.append(CodeMaterial(file: item.file, structure: parsed, contentHashVerification: verification,
                signedCodeVerification: signedVerification))
        }
        return Materials(inventory: inventory, code: code, signatureStructureBytesRead: bytesRead,
            contentHashBytesRead: contentReadBytes, signatureVerificationBytesRead: signatureReadBytes)
    }
    /// One bounded, read-only small-material path shared by hash/profile readers.
    /// Call only on a worker with caller-owned quiescent staging; not an atomic
    /// seal. maximumBytes may tighten but never increase the fixed 2 MiB cap.
    static func readOwnedMaterial(root: URL, fact: SelfRenewalMaterialInventory.FileFact,
        maximumBytes: Int) throws -> Data {
        guard (1...Limits.ownedMaterialBytes).contains(maximumBytes), fact.byteCount >= 0,
              fact.byteCount <= Int64(maximumBytes) else { throw Failure.fileSizeLimit }
        return try withOwnedFile(root: root, fact: fact, maximumReadBytes: maximumBytes) { read in
            var bytes = Data()
            var offset: UInt64 = 0
            while offset < UInt64(fact.byteCount) {
                let count = Int(min(UInt64(Limits.ownedFileChunkBytes), UInt64(fact.byteCount) - offset))
                bytes.append(try read(ByteRange(offset: offset, byteCount: count)))
                offset += UInt64(count)
            }
            return bytes
        }
    }
    /// Shared streaming path. The callback cannot escape or read outside this
    /// one regular file without hard links. A zero budget permits empty hashes.
    /// File identity checks apply before publishing success, not an atomic seal
    /// against a caller that mutates its staging directory concurrently.
    static func withOwnedFile<T>(root: URL, fact: SelfRenewalMaterialInventory.FileFact,
        maximumReadBytes: Int, _ action: ((ByteRange) throws -> Data) throws -> T) throws -> T {
        precondition(!Thread.isMainThread, "Renewal material reads must stay off main")
        try Task.checkCancellation()
        guard (0...Limits.ownedFileReadBytes).contains(maximumReadBytes), fact.byteCount >= 0,
              fact.byteCount <= Int64(Limits.ownedFileReadBytes) else { throw Failure.fileSizeLimit }
        let started = SourcePerfTrace.now
        var bytesRead = 0
        defer {
            SourcePerfTrace.record("renewal.material.owned-file",
                "bytes=\(bytesRead) declaredBytes=\(fact.byteCount) main=\(Thread.isMainThread)", since: started, thresholdMs: 0)
        }
        let rootFD = try openRoot(root)
        defer { Darwin.close(rootFD) }
        let descriptor = try openCodeFile(fact, rootFD: rootFD)
        defer { Darwin.close(descriptor) }
        let before = try status(descriptor, expectedBytes: fact.byteCount)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let value = try action { range in
            guard range.byteCount >= 0, range.byteCount <= Limits.ownedFileChunkBytes,
                  range.offset <= UInt64(fact.byteCount),
                  UInt64(range.byteCount) <= UInt64(fact.byteCount) - range.offset else { throw Failure.truncatedRead }
            return try readRange(handle, range: range, budget: &bytesRead, maximum: maximumReadBytes)
        }
        try unchanged(before, status(descriptor, expectedBytes: fact.byteCount))
        try Task.checkCancellation()
        return value
    }
    private static func openRoot(_ root: URL) throws -> Int32 {
        guard root.isFileURL, root.query == nil, root.fragment == nil,
              root.pathExtension.lowercased() == "app" else { throw Failure.invalidRoot }
        var initial = stat()
        guard Darwin.lstat(root.path, &initial) == 0,
              initial.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw Failure.invalidRoot }
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
        let descriptor = Darwin.open(canonical.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.invalidRoot }
        return descriptor
    }
    private static func materialFact(relativePath: String, rootFD: Int32,
        maximumBytes: Int) throws -> SelfRenewalMaterialInventory.FileFact {
        let descriptor = try openCodeFile(.init(relativePath: relativePath, byteCount: 0), rootFD: rootFD)
        defer { Darwin.close(descriptor) }
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0 else { throw Failure.unreadableFile }
        guard value.st_size >= 0, value.st_size <= Int64(maximumBytes) else { throw Failure.fileSizeLimit }
        _ = try status(descriptor, expectedBytes: value.st_size)
        return .init(relativePath: relativePath, byteCount: value.st_size)
    }
    private static func readRange(_ handle: FileHandle, range: ByteRange,
        budget: inout Int, maximum: Int) throws -> Data {
        try Task.checkCancellation()
        guard range.byteCount >= 0, range.byteCount <= maximum - budget else { throw Failure.totalReadLimit }
        var data = Data()
        do {
            try handle.seek(toOffset: range.offset)
            while data.count < range.byteCount {
                try Task.checkCancellation()
                guard let chunk = try handle.read(upToCount: min(65_536, range.byteCount - data.count)),
                      !chunk.isEmpty else { throw Failure.truncatedRead }
                data.append(chunk)
                budget += chunk.count
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as Failure { throw error }
        catch { throw Failure.unreadableFile }
        return data
    }
    private static func unchanged(_ before: stat, _ after: stat) throws {
        guard before.st_ino == after.st_ino, before.st_dev == after.st_dev,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw Failure.fileChangedDuringRead }
    }
    private static func openCodeFile(_ file: SelfRenewalMaterialInventory.FileFact, rootFD: Int32) throws -> Int32 {
        let pieces = file.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !pieces.isEmpty, pieces.count <= SelfRenewalMaterialInventory.Limits.depth,
              file.relativePath.utf8.count <= SelfRenewalMaterialInventory.Limits.pathBytes,
              pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw Failure.invalidPath
        }
        var directory = Darwin.dup(rootFD)
        guard directory >= 0 else { throw Failure.unreadableFile }
        defer { Darwin.close(directory) }
        for piece in pieces.dropLast() {
            try Task.checkCancellation()
            let next = Darwin.openat(directory, String(piece), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw Failure.linkNotAllowed }
            Darwin.close(directory)
            directory = next
        }
        guard let last = pieces.last else { throw Failure.invalidPath }
        let descriptor = Darwin.openat(directory, String(last), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unreadableFile }
        return descriptor
    }
    private static func status(_ descriptor: Int32, expectedBytes: Int64) throws -> stat {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0 else { throw Failure.unreadableFile }
        guard value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), value.st_nlink == 1 else {
            throw Failure.linkNotAllowed
        }
        guard expectedBytes >= 0, expectedBytes <= SelfRenewalMaterialInventory.Limits.fileBytes,
              value.st_size == expectedBytes else { throw Failure.fileChangedDuringRead }
        return value
    }
}
