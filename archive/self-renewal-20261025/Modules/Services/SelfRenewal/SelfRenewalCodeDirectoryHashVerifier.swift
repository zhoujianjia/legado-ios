import CryptoKit
import Foundation

/// Verifies content digests against the CodeDirectories in the same untrusted
/// staging executable. This is integrity consistency, not CMS authentication,
/// certificate/profile trust, resource-envelope validation or install permission.
enum SelfRenewalCodeDirectoryHashVerifier {
    typealias Reader = SelfRenewalMachOSignatureReader
    enum Failure: Error, Sendable, Equatable {
        case missingSignature, unsupportedHash, unsupportedSpecialSlot(UInt32)
        case contentReadLimit, hashOperationLimit, truncatedRead, changedDirectory
        case missingSpecialSlot(UInt32), unexpectedSpecialSlot(UInt32)
        case codeSlotMismatch(UInt32), specialSlotMismatch(UInt32)
    }
    enum Limits {
        static let chunkBytes = 65_536
        static let specialMaterialBytes = SelfRenewalResourceSealVerifier.Limits.envelopeBytes
        // The shipped 142.6 MB main executable is read for each authenticated
        // CodeDirectory, plus its resource envelope and extension code.
        static let totalContentReadBytes = 536_870_912
        static let totalHashOperations = 262_144
        static let specialSlots: UInt32 = 11
    }
    struct DirectoryVerification: Sendable, Equatable {
        let sliceOffset: UInt64
        let directorySlot: UInt32
        let hashType: UInt8
        let verifiedCodeSlots: UInt32
        let verifiedSpecialSlots: [UInt32]
        let absentSpecialSlots: [UInt32]
        let codeBytesHashed: UInt64
        let codeDirectorySHA256: Data
        fileprivate init(sliceOffset: UInt64, directorySlot: UInt32, hashType: UInt8,
            verifiedCodeSlots: UInt32, verifiedSpecialSlots: [UInt32], absentSpecialSlots: [UInt32],
            codeBytesHashed: UInt64, codeDirectorySHA256: Data) {
            self.sliceOffset = sliceOffset
            self.directorySlot = directorySlot
            self.hashType = hashType
            self.verifiedCodeSlots = verifiedCodeSlots
            self.verifiedSpecialSlots = verifiedSpecialSlots
            self.absentSpecialSlots = absentSpecialSlots
            self.codeBytesHashed = codeBytesHashed
            self.codeDirectorySHA256 = codeDirectorySHA256
        }
    }
    struct Verification: Sendable, Equatable {
        let directories: [DirectoryVerification]
        let contentBytesRead: Int
        let hashOperations: Int
        var contentDigestsVerified: Bool { !directories.isEmpty }
        var signatureAuthenticityVerified: Bool { false }
        var provisioningProfileVerified: Bool { false }
        /// The raw CodeResources digest can match while its resource seals fail.
        var resourceEnvelopeVerified: Bool { false }
        var replacementAuthorized: Bool { false }
        fileprivate init(directories: [DirectoryVerification], contentBytesRead: Int, hashOperations: Int) {
            self.directories = directories
            self.contentBytesRead = contentBytesRead
            self.hashOperations = hashOperations
        }
    }
    struct VerifiedFile: Sendable, Equatable {
        let structure: Reader.ParsedFile
        let verification: Verification
        fileprivate init(structure: Reader.ParsedFile, verification: Verification) {
            self.structure = structure
            self.verification = verification
        }
    }

    nonisolated static func read(unpackedApplication root: URL) async throws -> Reader.Materials {
        try await Reader.readVerifyingContentHashes(unpackedApplication: root)
    }

    /// Production supplies both read closures from one open, checked file FD.
    /// External slots are actual bounded Info.plist/CodeResources bytes; a nil
    /// value means no such file, distinctly from a present empty file.
    static func verify(fileByteCount: UInt64,
        maximumContentBytes: Int = Limits.totalContentReadBytes,
        maximumHashOperations: Int = Limits.totalHashOperations,
        readStructureRange: (Reader.ByteRange) throws -> Data,
        readContentRange: (Reader.ByteRange) throws -> Data,
        externalSpecialSlot: (UInt32, Int) throws -> Data?) throws -> VerifiedFile {
        guard (0...Limits.totalContentReadBytes).contains(maximumContentBytes) else { throw Failure.contentReadLimit }
        guard (0...Limits.totalHashOperations).contains(maximumHashOperations) else { throw Failure.hashOperationLimit }
        let structure = try Reader.parse(fileByteCount: fileByteCount, readRange: readStructureRange)
        var bytesRead = 0
        var operations = 0
        func read(_ range: Reader.ByteRange) throws -> Data {
            try Task.checkCancellation()
            guard range.byteCount >= 0, range.offset <= fileByteCount,
                  UInt64(range.byteCount) <= fileByteCount - range.offset else { throw Failure.truncatedRead }
            guard range.byteCount <= maximumContentBytes - bytesRead else { throw Failure.contentReadLimit }
            let bytes = try readContentRange(range)
            guard bytes.count == range.byteCount else { throw Failure.truncatedRead }
            bytesRead += bytes.count
            return Data(bytes)
        }
        func hash(_ range: Reader.ByteRange, type: UInt8) throws -> Data {
            guard operations < maximumHashOperations else { throw Failure.hashOperationLimit }
            operations += 1
            var digest = try Accumulator(type: type)
            var offset = range.offset
            while offset < range.end {
                let count = Int(min(UInt64(Limits.chunkBytes), range.end - offset))
                digest.update(try read(Reader.ByteRange(offset: offset, byteCount: count)))
                offset += UInt64(count)
            }
            return digest.finish()
        }
        var verified: [DirectoryVerification] = []
        for slice in structure.slices {
            try Task.checkCancellation()
            guard let signature = slice.signature else { throw Failure.missingSignature }
            for directory in signature.codeDirectories {
                guard directory.specialSlotCount <= Limits.specialSlots else {
                    throw Failure.unsupportedSpecialSlot(directory.specialSlotCount)
                }
                guard UInt64(directory.codeSlotCount) <= UInt64(maximumHashOperations - operations) else {
                    throw Failure.hashOperationLimit
                }
                let blob = try read(Reader.ByteRange(offset: signature.range.offset + directory.blobRange.offset,
                    byteCount: directory.blobRange.byteCount))
                // Bind re-read digest bytes to the parser's CodeDirectory header.
                guard try be32(blob, 0) == 0xfade0c02,
                      try be32(blob, 4) == UInt32(blob.count) else { throw Failure.changedDirectory }
                let reread = try Reader.parseCodeDirectory(blob, slot: directory.slot,
                    blobRange: directory.blobRange, codeBytesAvailable: signature.range.offset - slice.range.offset)
                guard reread == directory else { throw Failure.changedDirectory }
                guard operations < maximumHashOperations else { throw Failure.hashOperationLimit }
                operations += 1
                let directoryDigest = try digest(blob, hashType: 2)
                let pageBytes = directory.pageSizeLog2 == 0 ? directory.codeLimit : UInt64(1) << directory.pageSizeLog2
                for slot in 0..<directory.codeSlotCount {
                    let relative = UInt64(slot) * pageBytes
                    let count = Int(min(pageBytes, directory.codeLimit - relative))
                    let actual = try hash(Reader.ByteRange(offset: slice.range.offset + relative, byteCount: count),
                        type: directory.hashType)
                    let offset = directory.hashOffset + Int(slot) * directory.hashByteCount
                    guard matches(actual, blob.subdata(in: offset..<(offset + directory.hashByteCount))) else {
                        throw Failure.codeSlotMismatch(slot)
                    }
                }
                var special: [UInt32] = []
                var absent: [UInt32] = []
                for slot: UInt32 in 1...Limits.specialSlots {
                    try Task.checkCancellation()
                    let expected: Data
                    if slot <= directory.specialSlotCount {
                        let offset = directory.hashOffset - Int(slot) * directory.hashByteCount
                        expected = blob.subdata(in: offset..<(offset + directory.hashByteCount))
                    } else { expected = Data(repeating: 0, count: directory.hashByteCount) }
                    let present = expected.contains { $0 != 0 }
                    let embedded = signature.blobs.first { $0.slot == slot }
                    let external: Data?
                    if slot == 1 || slot == 3 {
                        if let bytes = try externalSpecialSlot(slot,
                            min(Limits.specialMaterialBytes, maximumContentBytes - bytesRead)) {
                            external = Data(bytes)
                        } else { external = nil }
                        if let external {
                            guard external.count <= Limits.specialMaterialBytes,
                                  external.count <= maximumContentBytes - bytesRead else { throw Failure.contentReadLimit }
                            bytesRead += external.count
                        }
                    } else { external = nil }
                    if !present {
                        guard embedded == nil, external == nil else { throw Failure.unexpectedSpecialSlot(slot) }
                        absent.append(slot)
                        continue
                    }
                    guard slot != 4, slot != 6 else { throw Failure.unsupportedSpecialSlot(slot) }
                    let actual: Data
                    if let external {
                        guard operations < maximumHashOperations else { throw Failure.hashOperationLimit }
                        operations += 1
                        actual = try digest(external, hashType: directory.hashType)
                    } else if let embedded {
                        actual = try hash(Reader.ByteRange(offset: signature.range.offset + embedded.range.offset,
                            byteCount: embedded.range.byteCount), type: directory.hashType)
                    } else { throw Failure.missingSpecialSlot(slot) }
                    guard matches(actual, expected) else { throw Failure.specialSlotMismatch(slot) }
                    special.append(slot)
                }
                verified.append(DirectoryVerification(sliceOffset: slice.range.offset,
                    directorySlot: directory.slot, hashType: directory.hashType,
                    verifiedCodeSlots: directory.codeSlotCount, verifiedSpecialSlots: special,
                    absentSpecialSlots: absent, codeBytesHashed: directory.codeLimit,
                    codeDirectorySHA256: directoryDigest))
            }
        }
        return VerifiedFile(structure: structure, verification: Verification(directories: verified,
            contentBytesRead: bytesRead, hashOperations: operations))
    }

    /// Also exposed internally for fixed independent digest-vector regressions.
    static func digest(_ bytes: Data, hashType: UInt8) throws -> Data {
        let buffer = Data(bytes)
        var result = try Accumulator(type: hashType)
        var offset = 0
        while offset < buffer.count {
            try Task.checkCancellation()
            let end = min(buffer.count, offset + Limits.chunkBytes)
            result.update(buffer.subdata(in: offset..<end))
            offset = end
        }
        return result.finish()
    }
    private enum Accumulator {
        case sha1(Insecure.SHA1), sha256(SHA256, truncated: Bool), sha384(SHA384)
        init(type: UInt8) throws {
            switch type {
            case 1: self = .sha1(Insecure.SHA1())
            case 2: self = .sha256(SHA256(), truncated: false)
            case 3: self = .sha256(SHA256(), truncated: true)
            case 4: self = .sha384(SHA384())
            default: throw Failure.unsupportedHash
            }
        }
        mutating func update(_ bytes: Data) {
            switch self {
            case .sha1(var state): state.update(data: bytes); self = .sha1(state)
            case .sha256(var state, let truncated): state.update(data: bytes); self = .sha256(state, truncated: truncated)
            case .sha384(var state): state.update(data: bytes); self = .sha384(state)
            }
        }
        func finish() -> Data {
            switch self {
            case .sha1(var state): return Data(state.finalize())
            case .sha256(var state, let truncated):
                let bytes = Data(state.finalize())
                return truncated ? Data(bytes.prefix(20)) : bytes
            case .sha384(var state): return Data(state.finalize())
            }
        }
    }
    private static func matches(_ left: Data, _ right: Data) -> Bool {
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(left, right) { difference |= a ^ b }
        return difference == 0
    }
    private static func be32(_ data: Data, _ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= data.count - 4 else { throw Failure.truncatedRead }
        return (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(data[offset + $1]) }
    }
}
