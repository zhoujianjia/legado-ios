import Foundation
import Security

/// A byte transformer for caller-owned, quiescent staging material. This first
/// implementation deliberately handles an existing, terminal signature on a
/// thin little-endian arm64 MH_EXECUTE or MH_DYLIB.
/// Dynamic symbol table ranges are checked and retained at their original offsets. It neither writes a file nor authorizes
/// installation. Package resource/profile ordering belongs to its caller.
enum SelfRenewalControlledMachOSigner {
    typealias Reader = SelfRenewalMachOSignatureReader
    typealias Hashes = SelfRenewalCodeDirectoryHashVerifier
    typealias CMS = SelfRenewalCMSVerifier
    typealias Signed = SelfRenewalSignedCodeVerifier

    enum Failure: Error, Sendable, Equatable {
        case sizeLimit, unsupportedArchitecture, unsupportedFileType
        case missingTerminalSignature, malformedLayout, unsupportedCommand(UInt32)
        case encryptedCode, unsupportedSignatureSlot(UInt32), unauthenticatedOriginal
        case inconsistentIdentity, unsupportedDigestCombination, invalidExternalSlots, unboundReplacementResource
        case invalidCertificate, unsupportedKey, keyCertificateMismatch, signingFailed
        case signatureCapacity, postVerificationFailed
    }
    enum Limits {
        static let fileBytes = 67_108_864
        static let externalSlotBytes = 2_097_152
        static let signatureBytes = Reader.Limits.signatureBytes
        static let segmentAlignment = 16_384
    }
    /// The vault is the one key owner. Borrowed handles are used synchronously
    /// by one worker; this signer never exports or persists private key bytes.
    /// The package coordinator rechecks the actual lease before publication.
    typealias KeyMaterial = SelfRenewalSigningMaterialVault.KeyMaterial
    struct Result: Sendable {
        let signedMachO: Data
        let codeDirectories: [UInt32: Data]
        let detachedCMS: Data
        let originalSignatures: Signed.Verification
        let contentHashes: Hashes.Verification
        let signatures: Signed.Verification
        let signatureOffset: Int
        let allocatedSignatureBytes: Int
        let identifier: String
        let teamIdentifier: String?
        let originalCodeResourcesSHA256: Data?
        let signedCodeResourcesSHA256: Data?
        var appleSigningAuthorityEstablished: Bool { false }
        var provisioningProfileAuthorized: Bool { false }
        var resourceTreeVerified: Bool { false }
        var replacementAuthorized: Bool { false }
        fileprivate init(bytes: Data, directories: [UInt32: Data], cms: Data,
            before: Signed.Verification, afterHashes: Hashes.Verification,
            after: Signed.Verification, layout: Layout, capacity: Int,
            identifier: String, team: String?, oldResources: Data?, signedResources: Data?) {
            signedMachO = bytes; codeDirectories = directories; detachedCMS = cms
            originalSignatures = before; contentHashes = afterHashes; signatures = after
            signatureOffset = layout.signatureOffset; allocatedSignatureBytes = capacity
            self.identifier = identifier; teamIdentifier = team
            originalCodeResourcesSHA256 = oldResources; signedCodeResourcesSHA256 = signedResources
        }
    }

    nonisolated static func resign(_ input: Data, identity: KeyMaterial,
        originalAnchors: [Data], replacementAnchors: [Data], at date: Date,
        externalSpecialSlots: [UInt32: Data] = [:],
        replacementExternalSpecialSlots: [UInt32: Data] = [:]) async throws -> Result {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            try resignSynchronously(input, identity: identity, originalAnchors: originalAnchors,
                replacementAnchors: replacementAnchors, at: date,
                externalSpecialSlots: externalSpecialSlots,
                replacementExternalSpecialSlots: replacementExternalSpecialSlots)
        }
        return try await withTaskCancellationHandler(operation: {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        }, onCancel: { worker.cancel() })
    }

    private static func resignSynchronously(_ supplied: Data, identity: KeyMaterial,
        originalAnchors: [Data], replacementAnchors: [Data], at date: Date,
        externalSpecialSlots: [UInt32: Data], replacementExternalSpecialSlots: [UInt32: Data]) throws -> Result {
        precondition(!Thread.isMainThread, "Controlled code signing must stay off main")
        let started = SourcePerfTrace.now
        defer { SourcePerfTrace.record("renewal.material.resign",
            "bytes=\(supplied.count) main=\(Thread.isMainThread)", since: started, thresholdMs: 0) }
        try Task.checkCancellation()
        guard supplied.count >= 32, supplied.count <= Limits.fileBytes else { throw Failure.sizeLimit }
        guard externalSpecialSlots.keys.allSatisfy({ $0 == 1 || $0 == 3 }),
              externalSpecialSlots.values.allSatisfy({ $0.count <= Limits.externalSlotBytes }),
              replacementExternalSpecialSlots.keys.allSatisfy({ $0 == 3 }),
              replacementExternalSpecialSlots.values.allSatisfy({ $0.count <= Limits.externalSlotBytes }) else {
            throw Failure.invalidExternalSlots
        }
        let input = Data(supplied)
        let parsed = try Reader.parse(fileByteCount: UInt64(input.count)) { try bytes(input, $0) }
        guard parsed.container == .thin64, parsed.slices.count == 1,
              let slice = parsed.slices.first, slice.cpuType == 0x0100_000c,
              slice.cpuSubtype & 0x00ff_ffff == 0, slice.byteOrder == .little,
              slice.is64Bit else { throw Failure.unsupportedArchitecture }
        guard let embedded = slice.signature else { throw Failure.missingTerminalSignature }
        let layout = try inspectLayout(input, signature: embedded)
        let original = try verify(input, anchors: originalAnchors, at: date, external: externalSpecialSlots)
        guard original.signed.allLoadedDirectoriesAuthenticated,
              original.signed.slices.count == 1,
              original.signed.slices.allSatisfy({ !$0.isAdHoc && $0.selectedDirectoryAuthenticated }) else {
            throw Failure.unauthenticatedOriginal
        }
        // Old code is always authenticated against OLD external bytes. Package
        // re-signing may then supply its newly rebuilt resource envelope only.
        // Info slot 1 and every embedded identity/entitlement blob stay unchanged.
        if replacementExternalSpecialSlots[3] != nil, externalSpecialSlots[3] == nil {
            throw Failure.unboundReplacementResource
        }
        var signedExternal = externalSpecialSlots
        if let resources = replacementExternalSpecialSlots[3] { signedExternal[3] = resources }
        let directories = embedded.codeDirectories.sorted { $0.slot < $1.slot }
        guard let primary = directories.first, primary.slot == 0,
              directories.count == original.signed.slices[0].directories.count,
              original.signed.slices[0].directories.allSatisfy({ $0.loadedByOriginalAlternateOrder && $0.signerAuthenticated }),
              directories.allSatisfy({ $0.identifier == primary.identifier && $0.teamIdentifier == primary.teamIdentifier &&
                  $0.codeLimit == UInt64(layout.signatureOffset) }) else { throw Failure.inconsistentIdentity }
        // Security's V2 dictionary is keyed by digest OID. Truncated SHA256 is
        // supported with its real 20-byte digest; two different entries mapping
        // to the same SHA256 OID cannot be represented by this bounded encoder.
        let digestOIDs = try directories.map { try digestOID($0.hashType) }
        guard Set(digestOIDs).count == digestOIDs.count else { throw Failure.unsupportedDigestCombination }
        var preserved: [UInt32: Data] = [:]
        for blob in embedded.blobs {
            try Task.checkCancellation()
            if directories.contains(where: { $0.slot == blob.slot }) || blob.slot == 0x10000 { continue }
            guard [UInt32(2), 5, 7, 8, 9, 10, 11].contains(blob.slot) else {
                throw Failure.unsupportedSignatureSlot(blob.slot)
            }
            preserved[blob.slot] = try bytes(input, Reader.ByteRange(
                offset: embedded.range.offset + blob.range.offset, byteCount: blob.range.byteCount))
        }
        let signer = try SigningIdentity(identity)
        let rawDirectories = try Dictionary(uniqueKeysWithValues: directories.map { directory in
            (directory.slot, try bytes(input, Reader.ByteRange(
                offset: embedded.range.offset + directory.blobRange.offset,
                byteCount: directory.blobRange.byteCount)))
        })
        let cmsCapacity = try checkedSum(signer.chain.reduce(0) { $0 + $1.count }, signer.maximumSignatureBytes, 8_192)
        guard cmsCapacity <= CMS.Limits.messageBytes else { throw Failure.signatureCapacity }
        let overhead = 12 + (directories.count + preserved.count + 1) * 8
        let allocation = try align(checkedSum(overhead, rawDirectories.values.reduce(0) { $0 + $1.count },
            preserved.values.reduce(0) { $0 + $1.count }, 8, cmsCapacity), to: 16)
        guard allocation <= Limits.signatureBytes,
              allocation <= Limits.fileBytes - layout.signatureOffset else { throw Failure.signatureCapacity }
        let newFileSize = layout.signatureOffset + allocation
        var output = input.subdata(in: 0..<layout.signatureOffset)
        // Allocation precedes every page digest, including the modified header.
        try write32(&output, layout.signatureCommand + 12, UInt32(allocation), little: true)
        let linkeditSize = newFileSize - layout.linkeditFileOffset
        let linkeditVMSize = try align(linkeditSize, to: Limits.segmentAlignment)
        guard UInt64(linkeditVMSize) <= UInt64.max - layout.linkeditVMAddress else { throw Failure.malformedLayout }
        try write64(&output, layout.linkeditCommand + 48, UInt64(linkeditSize), little: true)
        try write64(&output, layout.linkeditCommand + 32, UInt64(linkeditVMSize), little: true)

        var rebuilt: [UInt32: Data] = [:]
        for directory in directories {
            try Task.checkCancellation()
            guard var raw = rawDirectories[directory.slot] else { throw Failure.malformedLayout }
            // Preserve original version, identifiers, team, executable flags,
            // runtime/platform and page geometry. Clear only signer provenance.
            try write32(&raw, 12, directory.flags & ~UInt32(0x0002_0002), little: false)
            for zeroSlot: UInt32 in 0..<directory.specialSlotCount {
                let slot = zeroSlot + 1
                try Task.checkCancellation()
                let material = signedExternal[slot] ?? preserved[slot]
                let digest = try material.map { try Hashes.digest($0, hashType: directory.hashType) }
                    ?? Data(repeating: 0, count: directory.hashByteCount)
                try replace(&raw, at: directory.hashOffset - Int(slot) * directory.hashByteCount, with: digest)
            }
            let page = directory.pageSizeLog2 == 0 ? layout.signatureOffset : 1 << Int(directory.pageSizeLog2)
            for index in 0..<Int(directory.codeSlotCount) {
                try Task.checkCancellation()
                let start = index * page; let end = min(output.count, start + page)
                let digest = try Hashes.digest(output.subdata(in: start..<end), hashType: directory.hashType)
                try replace(&raw, at: directory.hashOffset + index * directory.hashByteCount, with: digest)
            }
            // Re-run the original structure parser before any signature is made.
            let reparsed = try Reader.parseCodeDirectory(raw, slot: directory.slot,
                blobRange: directory.blobRange, codeBytesAvailable: UInt64(output.count))
            guard reparsed.identifier == directory.identifier, reparsed.teamIdentifier == directory.teamIdentifier,
                  reparsed.hashType == directory.hashType, reparsed.codeLimit == directory.codeLimit else {
                throw Failure.inconsistentIdentity
            }
            rebuilt[directory.slot] = raw
        }
        let cms = try makeCMS(directories: directories, raw: rebuilt, identity: signer)
        guard cms.count <= cmsCapacity else { throw Failure.signatureCapacity }
        var blobs = preserved
        for (slot, bytes) in rebuilt {
            guard blobs[slot] == nil else { throw Failure.malformedLayout }
            blobs[slot] = bytes
        }
        blobs[0x10000] = try wrapped(magic: 0xfade0b01, body: cms)
        let signature = try superBlob(blobs)
        guard signature.count <= allocation else { throw Failure.signatureCapacity }
        // No byte of the old signature tail is copied. New spare capacity is zero.
        output.append(signature)
        output.append(Data(repeating: 0, count: allocation - signature.count))
        let after = try verify(output, anchors: replacementAnchors, at: date, external: signedExternal)
        guard after.signed.allLoadedDirectoriesAuthenticated,
              after.signed.slices.count == 1,
              let bound = after.signed.slices.first, !bound.isAdHoc,
              bound.hashAgilityV1Present, bound.hashAgilityV2Present,
              bound.directories.count == directories.count,
              bound.directories.allSatisfy({ $0.signerAuthenticated }),
              bound.signers.count == 1,
              bound.signers.first?.certificateSHA256 == (try Hashes.digest(signer.chain[0], hashType: 2)) else {
            throw Failure.postVerificationFailed
        }
        // Headers and original signing identity are compared after actual checks.
        let newDirectories = after.hashes.structure.slices[0].signature?.codeDirectories ?? []
        guard newDirectories.count == directories.count,
              zip(directories, newDirectories.sorted { $0.slot < $1.slot }).allSatisfy({ old, new in
                  old.slot == new.slot && old.identifier == new.identifier && old.teamIdentifier == new.teamIdentifier &&
                  old.hashType == new.hashType && old.pageSizeLog2 == new.pageSizeLog2 && old.codeLimit == new.codeLimit
              }) else { throw Failure.postVerificationFailed }
        let oldResourceDigest = try externalSpecialSlots[3].map { try Hashes.digest($0, hashType: 2) }
        let signedResourceDigest = try signedExternal[3].map { try Hashes.digest($0, hashType: 2) }
        return Result(bytes: output, directories: rebuilt, cms: cms, before: original.signed,
            afterHashes: after.hashes.verification, after: after.signed, layout: layout,
            capacity: allocation, identifier: primary.identifier, team: primary.teamIdentifier,
            oldResources: oldResourceDigest, signedResources: signedResourceDigest)
    }

    private static func verify(_ data: Data, anchors: [Data], at date: Date, external: [UInt32: Data]) throws
        -> (hashes: Hashes.VerifiedFile, signed: Signed.Verification) {
        let read: (Reader.ByteRange) throws -> Data = { try bytes(data, $0) }
        let hashes = try Hashes.verify(fileByteCount: UInt64(data.count), readStructureRange: read,
            readContentRange: read, externalSpecialSlot: { slot, maximum in
                guard let value = external[slot] else { return nil }
                guard value.count <= maximum else { throw Failure.sizeLimit }; return value
            })
        return (hashes, try Signed.bind(hashes, anchors: anchors, at: date, readRange: read))
    }

    fileprivate struct Layout {
        let signatureCommand: Int
        let signatureOffset: Int
        let linkeditCommand: Int
        let linkeditFileOffset: Int
        let linkeditVMAddress: UInt64
    }
    private struct Segment {
        let command: Int; let name: Data; let fileOffset: UInt64; let fileSize: UInt64
        let vmAddress: UInt64; let vmSize: UInt64
    }
    private static func inspectLayout(_ data: Data, signature: Reader.EmbeddedSignature) throws -> Layout {
        guard [UInt32(2), 6].contains(try u32(data, 12, true)) else { throw Failure.unsupportedFileType }
        let signatureOffset = Int(signature.range.offset)
        guard signature.range.end == UInt64(data.count), signatureOffset % 16 == 0 else { throw Failure.missingTerminalSignature }
        let commandEnd = 32 + Int(try u32(data, 20, true))
        var cursor = 32; var segments: [Segment] = []; var signatureCommand: Int?
        var symbolCount: UInt64?; var dynamicSymbols: [(UInt64, UInt64)]?
        let linkeditName = Data("__LINKEDIT".utf8); let textName = Data("__TEXT".utf8)
        func bounded(_ offset: UInt64, _ length: UInt64) throws {
            guard offset <= UInt64(signatureOffset), length <= UInt64(signatureOffset) - offset else { throw Failure.malformedLayout }
        }
        for _ in 0..<Int(try u32(data, 16, true)) {
            try Task.checkCancellation()
            let command = try u32(data, cursor, true); let size = Int(try u32(data, cursor + 4, true))
            guard size >= 8, size <= commandEnd - cursor else { throw Failure.malformedLayout }
            switch command {
            case 0x19:
                guard size >= 72 else { throw Failure.malformedLayout }
                let sections = Int(try u32(data, cursor + 64, true))
                guard sections <= (size - 72) / 80, size == 72 + sections * 80 else { throw Failure.malformedLayout }
                let name = data.subdata(in: (cursor + 8)..<(cursor + 24)).prefix { $0 != 0 }
                let vm = try u64(data, cursor + 24, true); let vmSize = try u64(data, cursor + 32, true)
                let offset = try u64(data, cursor + 40, true); let length = try u64(data, cursor + 48, true)
                guard vmSize >= length, vm <= UInt64.max - vmSize, offset <= UInt64(data.count),
                      length <= UInt64(data.count) - offset,
                      try u32(data, cursor + 56, true) & ~UInt32(7) == 0,
                      try u32(data, cursor + 60, true) & ~u32(data, cursor + 56, true) == 0 else { throw Failure.malformedLayout }
                if name == linkeditName {
                    guard sections == 0, offset <= UInt64(signatureOffset), offset + length == UInt64(data.count),
                          vm % UInt64(Limits.segmentAlignment) == 0, offset % UInt64(Limits.segmentAlignment) == 0 else { throw Failure.malformedLayout }
                } else { try bounded(offset, length) }
                for index in 0..<sections {
                    let section = cursor + 72 + index * 80
                    let count = try u64(data, section + 40, true); let sectionOffset = UInt64(try u32(data, section + 48, true))
                    let type = try u32(data, section + 64, true) & 0xff
                    if ![UInt32(1), 0xc, 0x12].contains(type) {
                        try bounded(sectionOffset, count)
                        guard sectionOffset >= offset, sectionOffset <= offset + length,
                              count <= offset + length - sectionOffset else { throw Failure.malformedLayout }
                    }
                    try bounded(UInt64(try u32(data, section + 56, true)), UInt64(try u32(data, section + 60, true)) * 8)
                }
                segments.append(Segment(command: cursor, name: Data(name), fileOffset: offset, fileSize: length, vmAddress: vm, vmSize: vmSize))
            case 0x1d:
                guard size == 16, signatureCommand == nil,
                      Int(try u32(data, cursor + 8, true)) == signatureOffset,
                      Int(try u32(data, cursor + 12, true)) == signature.range.byteCount else { throw Failure.malformedLayout }
                signatureCommand = cursor
            case 0x2c:
                guard size == 24 else { throw Failure.malformedLayout }
                guard try u32(data, cursor + 16, true) == 0 else { throw Failure.encryptedCode }
                try bounded(UInt64(try u32(data, cursor + 8, true)), UInt64(try u32(data, cursor + 12, true)))
            case 0x21: throw Failure.encryptedCode
            case 0x2:
                guard size == 24, symbolCount == nil else { throw Failure.malformedLayout }
                symbolCount = UInt64(try u32(data, cursor + 12, true))
                try bounded(UInt64(try u32(data, cursor + 8, true)), UInt64(try u32(data, cursor + 12, true)) * 16)
                try bounded(UInt64(try u32(data, cursor + 16, true)), UInt64(try u32(data, cursor + 20, true)))
            case 0xb:
                // xnu loader.h dysymtab_command (80 bytes). nlist_64 is
                // 16 bytes, dylib_module_64 56, TOC/relocations 8 and
                // reference/indirect entries 4. We never relocate these tables.
                guard size == 80, dynamicSymbols == nil else { throw Failure.malformedLayout }
                dynamicSymbols = try [8, 16, 24].map { field in
                    (UInt64(try u32(data, cursor + field, true)), UInt64(try u32(data, cursor + field + 4, true)))
                }
                for (field, width) in [(32, UInt64(8)), (40, 56), (48, 4), (56, 4), (64, 8), (72, 8)] {
                    try bounded(UInt64(try u32(data, cursor + field, true)), UInt64(try u32(data, cursor + field + 4, true)) * width)
                }
            case 0x22, 0x80000022:
                guard size == 48 else { throw Failure.malformedLayout }
                for field in stride(from: 8, to: 48, by: 8) {
                    try bounded(UInt64(try u32(data, cursor + field, true)), UInt64(try u32(data, cursor + field + 4, true)))
                }
            case 0x1e, 0x26, 0x29, 0x2b, 0x2e, 0x80000033, 0x80000034:
                guard size == 16 else { throw Failure.malformedLayout }
                try bounded(UInt64(try u32(data, cursor + 8, true)), UInt64(try u32(data, cursor + 12, true)))
            case 0x80000028:
                guard size == 24 else { throw Failure.malformedLayout }
                try bounded(try u64(data, cursor + 8, true), 1)
            case 0x1b: guard size == 24 else { throw Failure.malformedLayout }
            case 0x2a: guard size == 16 else { throw Failure.malformedLayout }
            case 0x24, 0x25, 0x2f, 0x30:
                guard size == 16 else { throw Failure.malformedLayout }
            case 0x32:
                guard size >= 24 else { throw Failure.malformedLayout }
                let tools = Int(try u32(data, cursor + 20, true))
                guard tools <= (size - 24) / 8, size == 24 + tools * 8 else { throw Failure.malformedLayout }
            case 0xc, 0xd, 0x18, 0x80000018, 0x1f, 0x8000001f, 0x20, 0x80000023:
                try commandString(data, command: cursor, size: size, minimum: 24)
            case 0xe, 0xf, 0x8000001c:
                try commandString(data, command: cursor, size: size, minimum: 12)
            default: throw Failure.unsupportedCommand(command)
            }
            cursor += size
        }
        if let ranges = dynamicSymbols {
            guard let count = symbolCount else { throw Failure.malformedLayout }
            for (index, length) in ranges {
                guard index <= count, length <= count - index else { throw Failure.malformedLayout }
            }
        }
        guard cursor == commandEnd, let signatureCommand,
              segments.filter({ $0.name == linkeditName }).count == 1,
              let linkedit = segments.first(where: { $0.name == linkeditName }),
              segments.filter({ $0.name == textName && $0.fileOffset == 0 && $0.fileSize >= UInt64(commandEnd) }).count == 1 else {
            throw Failure.malformedLayout
        }
        for (index, segment) in segments.enumerated() {
            if segment.command != linkedit.command {
                guard segment.fileOffset + segment.fileSize <= linkedit.fileOffset,
                      segment.vmAddress + segment.vmSize <= linkedit.vmAddress else { throw Failure.malformedLayout }
            }
            for other in segments.dropFirst(index + 1) {
                if segment.fileSize > 0 && other.fileSize > 0,
                   segment.fileOffset < other.fileOffset + other.fileSize && other.fileOffset < segment.fileOffset + segment.fileSize {
                    throw Failure.malformedLayout
                }
                if segment.vmSize > 0 && other.vmSize > 0,
                   segment.vmAddress < other.vmAddress + other.vmSize && other.vmAddress < segment.vmAddress + segment.vmSize {
                    throw Failure.malformedLayout
                }
            }
        }
        return Layout(signatureCommand: signatureCommand, signatureOffset: signatureOffset,
            linkeditCommand: linkedit.command, linkeditFileOffset: Int(linkedit.fileOffset), linkeditVMAddress: linkedit.vmAddress)
    }

    private struct SigningIdentity {
        let key: SecKey; let publicKey: SecKey
        let chain: [Data]; let issuerAndSerial: Data
        let algorithm: SecKeyAlgorithm; let algorithmDER: Data; let maximumSignatureBytes: Int
        init(_ material: KeyMaterial) throws {
            guard !material.certificateChainDER.isEmpty, material.certificateChainDER.count <= CMS.Limits.certificates,
                  Set(material.certificateChainDER).count == material.certificateChainDER.count,
                  material.certificateChainDER.allSatisfy({ !$0.isEmpty && $0.count <= CMS.Limits.certificateBytes }),
                  let first = material.certificateChainDER.first,
                  let certificate = SecCertificateCreateWithData(nil, first as CFData),
                  let certificateKey = SecCertificateCopyKey(certificate),
                  let ownPublic = SecKeyCopyPublicKey(material.privateKey) else { throw Failure.invalidCertificate }
            var keyError: Unmanaged<CFError>?
            defer { if let keyError { _ = keyError.takeRetainedValue() } }
            guard let ownBytes = SecKeyCopyExternalRepresentation(ownPublic, &keyError) as Data? else {
                throw Failure.unsupportedKey
            }
            guard let certificateBytes = SecKeyCopyExternalRepresentation(certificateKey, &keyError) as Data?,
                  ownBytes == certificateBytes else { throw Failure.keyCertificateMismatch }
            let attributes = SecKeyCopyAttributes(certificateKey) as NSDictionary?
            let kind = attributes?[kSecAttrKeyType] as? String
            let bits = (attributes?[kSecAttrKeySizeInBits] as? NSNumber)?.intValue ?? 0
            let signingAlgorithm: SecKeyAlgorithm
            let signingAlgorithmDER: Data
            let maximumSignature: Int
            if kind == (kSecAttrKeyTypeRSA as String), (2048...8192).contains(bits) {
                signingAlgorithm = .rsaSignatureMessagePKCS1v15SHA256
                signingAlgorithmDER = try DER.sequence([DER.oid(OID.rsaEncryption), DER.tlv(0x05, Data())])
                maximumSignature = (bits + 7) / 8
            } else if kind == (kSecAttrKeyTypeECSECPrimeRandom as String), bits == 256 || bits == 384 {
                signingAlgorithm = .ecdsaSignatureMessageX962SHA256
                signingAlgorithmDER = try DER.sequence([DER.oid(OID.ecSHA256)])
                maximumSignature = 2 * ((bits + 7) / 8 + 1) + 8
            } else { throw Failure.unsupportedKey }
            guard SecKeyIsAlgorithmSupported(material.privateKey, .sign, signingAlgorithm),
                  SecKeyIsAlgorithmSupported(certificateKey, .verify, signingAlgorithm) else { throw Failure.unsupportedKey }
            let certificateFields = try CMS.children(of: CMS.parseDER(first))
            guard certificateFields.count == 3, certificateFields[0].tag == 0x30 else { throw Failure.invalidCertificate }
            let fields = try CMS.children(of: certificateFields[0]); let base = fields.first?.tag == 0xa0 ? 1 : 0
            guard fields.count >= base + 6, fields[base].tag == 2, fields[base + 2].tag == 0x30 else { throw Failure.invalidCertificate }
            issuerAndSerial = try DER.sequence([fields[base + 2].originalDER, fields[base].originalDER])
            key = material.privateKey; publicKey = certificateKey; chain = material.certificateChainDER
            algorithm = signingAlgorithm; algorithmDER = signingAlgorithmDER; maximumSignatureBytes = maximumSignature
        }
        func sign(_ message: Data) throws -> Data {
            try Task.checkCancellation()
            var error: Unmanaged<CFError>?
            defer { if let error { _ = error.takeRetainedValue() } }
            guard let signature = SecKeyCreateSignature(key, algorithm, message as CFData, &error) as Data?,
                  !signature.isEmpty, signature.count <= maximumSignatureBytes else { throw Failure.signingFailed }
            try Task.checkCancellation()
            guard SecKeyVerifySignature(publicKey, algorithm, message as CFData, signature as CFData, &error) else {
                throw Failure.keyCertificateMismatch
            }
            return signature
        }
    }

    private static func makeCMS(directories: [Reader.CodeDirectory], raw: [UInt32: Data], identity: SigningIdentity) throws -> Data {
        guard let primary = raw[0] else { throw Failure.malformedLayout }
        let ordered = directories.sorted { $0.hashType < $1.hashType }
        let hashes = try ordered.map { directory -> Data in
            guard let bytes = raw[directory.slot] else { throw Failure.malformedLayout }
            return try Hashes.digest(bytes, hashType: directory.hashType)
        }
        let v1 = try PropertyListSerialization.data(fromPropertyList: ["cdhashes": hashes.map { Data($0.prefix(20)) }], format: .xml, options: 0)
        let v2 = try zip(ordered, hashes).map { directory, hash in
            try DER.sequence([DER.oid(digestOID(directory.hashType)), DER.tlv(4, hash)])
        }
        let attributes = try DER.sortedSet([
            DER.attribute(OID.contentType, values: [DER.oid(OID.data)]),
            DER.attribute(OID.messageDigest, values: [DER.tlv(4, Hashes.digest(primary, hashType: 2))]),
            DER.attribute(OID.agilityV1, values: [DER.tlv(4, v1)]),
            DER.attribute(OID.agilityV2, values: v2)
        ])
        let signature = try identity.sign(attributes)
        let attrNode = try CMS.parseDER(attributes)
        let digestAlgorithm = try DER.sequence([DER.oid(OID.sha256), DER.tlv(5, Data())])
        let signerInfo = try DER.sequence([DER.integer(1), identity.issuerAndSerial, digestAlgorithm,
            DER.tlv(0xa0, attrNode.body), identity.algorithmDER, DER.tlv(4, signature)])
        let certificates = identity.chain.sorted { $0.lexicographicallyPrecedes($1) }.reduce(into: Data()) { $0.append($1) }
        let signedData = try DER.sequence([DER.integer(1), DER.sortedSet([digestAlgorithm]),
            DER.sequence([DER.oid(OID.data)]), DER.tlv(0xa0, certificates), DER.sortedSet([signerInfo])])
        let message = try DER.sequence([DER.oid(OID.signedData), DER.tlv(0xa0, signedData)])
        guard message.count <= CMS.Limits.messageBytes else { throw Failure.signatureCapacity }
        return message
    }

    /// A bounded DER writer, not a second decoder. Structural parsing and every
    /// cryptographic/trust decision still use the existing CMS verifier above.
    private enum DER {
        static func tlv(_ tag: UInt8, _ body: Data) throws -> Data {
            guard body.count <= CMS.Limits.messageBytes else { throw Failure.signatureCapacity }
            var data = Data([tag]); let count = body.count
            if count < 128 { data.append(UInt8(count)) }
            else {
                var length: [UInt8] = []; var remaining = count
                while remaining > 0 { length.insert(UInt8(remaining & 0xff), at: 0); remaining >>= 8 }
                data.append(0x80 | UInt8(length.count)); data.append(contentsOf: length)
            }
            data.append(body); return data
        }
        static func sequence(_ values: [Data]) throws -> Data { try tlv(0x30, joined(values)) }
        static func sortedSet(_ values: [Data]) throws -> Data {
            try tlv(0x31, joined(values.sorted { $0.lexicographicallyPrecedes($1) }))
        }
        static func oid(_ body: Data) throws -> Data { try tlv(6, body) }
        static func integer(_ value: UInt8) throws -> Data { try tlv(2, Data([value])) }
        static func attribute(_ oid: Data, values: [Data]) throws -> Data { try sequence([self.oid(oid), sortedSet(values)]) }
        static func joined(_ values: [Data]) throws -> Data {
            var data = Data()
            for value in values {
                guard value.count <= CMS.Limits.messageBytes - data.count else { throw Failure.signatureCapacity }
                data.append(value)
            }
            return data
        }
    }
    private enum OID {
        static let data = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 7, 1])
        static let signedData = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 7, 2])
        static let contentType = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 9, 3])
        static let messageDigest = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 9, 4])
        static let agilityV1 = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 9, 1])
        static let agilityV2 = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 9, 2])
        static let sha1 = Data([0x2b, 0x0e, 3, 2, 0x1a])
        static let sha256 = Data([0x60, 0x86, 0x48, 1, 0x65, 3, 4, 2, 1])
        static let sha384 = Data([0x60, 0x86, 0x48, 1, 0x65, 3, 4, 2, 2])
        static let rsaEncryption = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 1, 1])
        static let ecSHA256 = Data([0x2a, 0x86, 0x48, 0xce, 0x3d, 4, 3, 2])
    }
    private static func digestOID(_ type: UInt8) throws -> Data {
        switch type { case 1: return OID.sha1; case 2, 3: return OID.sha256; case 4: return OID.sha384
        default: throw Failure.unsupportedDigestCombination }
    }
    private static func superBlob(_ blobs: [UInt32: Data]) throws -> Data {
        guard blobs.count <= Reader.Limits.blobs else { throw Failure.signatureCapacity }
        let slots = blobs.keys.sorted(); var index = Data(); var payload = Data(); let start = 12 + slots.count * 8
        for slot in slots {
            guard let blob = blobs[slot] else { throw Failure.malformedLayout }
            let offset = try checkedSum(start, payload.count)
            guard offset <= Limits.signatureBytes, blob.count <= Limits.signatureBytes - offset else { throw Failure.signatureCapacity }
            index.append(be32(slot)); index.append(be32(UInt32(offset))); payload.append(blob)
        }
        let total = try checkedSum(start, payload.count)
        return be32(0xfade0cc0) + be32(UInt32(total)) + be32(UInt32(slots.count)) + index + payload
    }
    private static func wrapped(magic: UInt32, body: Data) throws -> Data {
        guard body.count <= Limits.signatureBytes - 8 else { throw Failure.signatureCapacity }
        return be32(magic) + be32(UInt32(body.count + 8)) + body
    }
    private static func commandString(_ data: Data, command: Int, size: Int, minimum: Int) throws {
        guard size >= minimum else { throw Failure.malformedLayout }
        let offset = Int(try u32(data, command + 8, true))
        guard offset >= minimum, offset < size,
              data.subdata(in: (command + offset)..<(command + size)).contains(0) else { throw Failure.malformedLayout }
    }
    private static func checkedSum(_ values: Int...) throws -> Int {
        var total = 0
        for value in values { guard value >= 0, value <= Int.max - total else { throw Failure.sizeLimit }; total += value }
        return total
    }
    private static func align(_ value: Int, to alignment: Int) throws -> Int {
        guard value >= 0, alignment > 0, value <= Int.max - (alignment - 1) else { throw Failure.sizeLimit }
        return ((value + alignment - 1) / alignment) * alignment
    }
    private static func bytes(_ data: Data, _ range: Reader.ByteRange) throws -> Data {
        try Task.checkCancellation()
        guard range.byteCount >= 0, range.offset <= UInt64(data.count),
              UInt64(range.byteCount) <= UInt64(data.count) - range.offset else { throw Failure.malformedLayout }
        return data.subdata(in: Int(range.offset)..<(Int(range.offset) + range.byteCount))
    }
    private static func u32(_ data: Data, _ offset: Int, _ little: Bool) throws -> UInt32 {
        guard offset >= 0 else { throw Failure.malformedLayout }
        let bytes = try self.bytes(data, Reader.ByteRange(offset: UInt64(offset), byteCount: 4))
        return (little ? Array(bytes.reversed()) : Array(bytes)).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    private static func u64(_ data: Data, _ offset: Int, _ little: Bool) throws -> UInt64 {
        guard offset >= 0 else { throw Failure.malformedLayout }
        let bytes = try self.bytes(data, Reader.ByteRange(offset: UInt64(offset), byteCount: 8))
        return (little ? Array(bytes.reversed()) : Array(bytes)).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
    private static func be32(_ value: UInt32) -> Data { Data((0..<4).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    private static func write32(_ data: inout Data, _ offset: Int, _ value: UInt32, little: Bool) throws {
        let bytes = be32(value); try replace(&data, at: offset, with: little ? Data(bytes.reversed()) : bytes)
    }
    private static func write64(_ data: inout Data, _ offset: Int, _ value: UInt64, little: Bool) throws {
        let bytes = Data((0..<8).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        try replace(&data, at: offset, with: little ? Data(bytes.reversed()) : bytes)
    }
    private static func replace(_ data: inout Data, at offset: Int, with bytes: Data) throws {
        guard offset >= 0, offset <= data.count, bytes.count <= data.count - offset else { throw Failure.malformedLayout }
        data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }
}
