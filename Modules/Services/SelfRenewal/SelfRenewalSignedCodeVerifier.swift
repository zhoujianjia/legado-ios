import Foundation

/// Connects actual content hashes, detached CodeDirectory CMS signatures and
/// authenticated hash-agility attributes. Explicit generic anchors do not prove
/// Apple signing/provisioning authority, resources or replacement eligibility.
enum SelfRenewalSignedCodeVerifier {
    typealias Reader = SelfRenewalMachOSignatureReader
    typealias Hashes = SelfRenewalCodeDirectoryHashVerifier
    typealias CMS = SelfRenewalCMSVerifier
    enum Failure: Error, Sendable, Equatable {
        case readLimit, truncatedRead, changedCodeDirectory, missingCMS
        case duplicateHashType, malformedHashAgilityV1, malformedHashAgilityV2
        case hashAgilityMismatch
    }
    enum Authentication: Sendable, Equatable {
        case detachedPrimaryCMS, hashAgilityV1, hashAgilityV2
    }
    struct DirectoryBinding: Sendable, Equatable {
        let slot: UInt32
        let hashType: UInt8
        let rawCodeDirectorySHA256: Data
        let cdHash: Data
        let fullCDHash: Data
        let loadedByOriginalAlternateOrder: Bool
        let authenticatedBy: [Authentication]
        var signerAuthenticated: Bool { !authenticatedBy.isEmpty }
        fileprivate init(slot: UInt32, hashType: UInt8, rawCodeDirectorySHA256: Data,
            cdHash: Data, fullCDHash: Data, loaded: Bool, authenticatedBy: [Authentication]) {
            self.slot = slot
            self.hashType = hashType
            self.rawCodeDirectorySHA256 = rawCodeDirectorySHA256
            self.cdHash = cdHash
            self.fullCDHash = fullCDHash
            loadedByOriginalAlternateOrder = loaded
            self.authenticatedBy = authenticatedBy
        }
    }
    struct SliceBinding: Sendable, Equatable {
        let sliceOffset: UInt64
        let selectedDirectorySlot: UInt32
        let isAdHoc: Bool
        let signers: [CMS.Signer]
        let hashAgilityV1Present: Bool
        let hashAgilityV2Present: Bool
        let directories: [DirectoryBinding]
        var selectedDirectoryAuthenticated: Bool {
            directories.first { $0.slot == selectedDirectorySlot }?.signerAuthenticated == true
        }
        fileprivate init(sliceOffset: UInt64, selectedDirectorySlot: UInt32, isAdHoc: Bool,
            signers: [CMS.Signer], v1: Bool, v2: Bool, directories: [DirectoryBinding]) {
            self.sliceOffset = sliceOffset
            self.selectedDirectorySlot = selectedDirectorySlot
            self.isAdHoc = isAdHoc
            self.signers = signers
            hashAgilityV1Present = v1
            hashAgilityV2Present = v2
            self.directories = directories
        }
    }
    struct Verification: Sendable, Equatable {
        let slices: [SliceBinding]
        let additionalBytesRead: Int
        var allLoadedDirectoriesAuthenticated: Bool {
            !slices.isEmpty && slices.allSatisfy { slice in
                slice.directories.filter(\.loadedByOriginalAlternateOrder).allSatisfy(\.signerAuthenticated)
            }
        }
        var appleSigningAuthorityEstablished: Bool { false }
        var provisioningProfileAuthorized: Bool { false }
        var resourceTreeVerified: Bool { false }
        var replacementAuthorized: Bool { false }
        fileprivate init(slices: [SliceBinding], additionalBytesRead: Int) {
            self.slices = slices
            self.additionalBytesRead = additionalBytesRead
        }
    }
    enum Limits { static let additionalReadBytes = 67_108_864 }

    nonisolated static func read(unpackedApplication root: URL, anchors: [Data], at date: Date) async throws -> Reader.Materials {
        try await Reader.readVerifyingSignatures(unpackedApplication: root, anchors: anchors, at: date)
    }

    /// The caller supplies an actual Hashes.VerifiedFile from the same checked
    /// FD. Re-read raw CD bytes must match the digest recorded by that verifier.
    /// No caller-provided Bool or reserialized CodeDirectory grants trust.
    static func bind(_ verified: Hashes.VerifiedFile, anchors: [Data], at date: Date,
        maximumReadBytes: Int = Limits.additionalReadBytes,
        readRange: (Reader.ByteRange) throws -> Data) throws -> Verification {
        precondition(!Thread.isMainThread, "Signed-code verification must stay off main")
        guard (0...Limits.additionalReadBytes).contains(maximumReadBytes) else { throw Failure.readLimit }
        let started = SourcePerfTrace.now
        var readBytes = 0
        defer {
            SourcePerfTrace.record("renewal.signature.code-directory-cms",
                "slices=\(verified.structure.slices.count) bytes=\(readBytes) main=\(Thread.isMainThread)",
                since: started, thresholdMs: 0)
        }
        func read(_ range: Reader.ByteRange) throws -> Data {
            guard range.byteCount >= 0, range.byteCount <= maximumReadBytes - readBytes else { throw Failure.readLimit }
            var data = Data()
            while data.count < range.byteCount {
                try Task.checkCancellation()
                let count = min(65_536, range.byteCount - data.count)
                let bytes = try readRange(Reader.ByteRange(offset: range.offset + UInt64(data.count), byteCount: count))
                guard bytes.count == count else { throw Failure.truncatedRead }
                data.append(bytes)
                readBytes += bytes.count
            }
            return data
        }
        var slices: [SliceBinding] = []
        for slice in verified.structure.slices {
            try Task.checkCancellation()
            guard let signature = slice.signature else { throw Failure.missingCMS }
            var raw: [UInt32: RawDirectory] = [:]
            for directory in signature.codeDirectories {
                let bytes = try read(Reader.ByteRange(offset: signature.range.offset + directory.blobRange.offset,
                    byteCount: directory.blobRange.byteCount))
                let sha256 = try Hashes.digest(bytes, hashType: 2)
                guard let prior = verified.verification.directories.first(where: {
                    $0.sliceOffset == slice.range.offset && $0.directorySlot == directory.slot
                }), prior.codeDirectorySHA256 == sha256 else { throw Failure.changedCodeDirectory }
                let full = try Hashes.digest(bytes, hashType: directory.hashType)
                raw[directory.slot] = RawDirectory(facts: directory, bytes: bytes, sha256: sha256, fullHash: full)
            }
            guard let primary = raw[0] else { throw Failure.changedCodeDirectory }
            // Match original loadCodeDirectories: stop at the first absent
            // alternate slot. Later structural blobs remain explicitly unbound.
            var loaded: [RawDirectory] = [primary]
            for slot: UInt32 in 0x1000..<0x1005 {
                guard let alternate = raw[slot] else { break }
                loaded.append(alternate)
            }
            guard Set(loaded.map { $0.facts.hashType }).count == loaded.count else { throw Failure.duplicateHashType }
            let byHashType = loaded.sorted { $0.facts.hashType < $1.facts.hashType }
            let selected = try selectedDirectory(loaded)
            let adHoc = selected.facts.flags & 2 != 0
            var signers: [CMS.Signer] = []
            var v1 = false
            var v2 = false
            if !adHoc {
                guard let wrapper = signature.blobs.first(where: { $0.slot == 0x10000 }), wrapper.range.byteCount > 8 else {
                    throw Failure.missingCMS
                }
                guard primary.bytes.count <= CMS.Limits.contentBytes,
                      wrapper.range.byteCount - 8 <= CMS.Limits.messageBytes else { throw CMS.Failure.sizeLimit }
                let cmsBytes = try read(Reader.ByteRange(offset: signature.range.offset + wrapper.range.offset + 8,
                    byteCount: wrapper.range.byteCount - 8))
                let cms = try CMS.verify(cmsBytes, detachedContent: primary.bytes, anchors: anchors, at: date)
                signers = cms.signers
                // Original code-signing hash-agility checks use signer index 0.
                // The generic verifier independently verifies every CMS signer.
                let attributes = cms.signers.first?.signedAttributes ?? []
                if let attribute = attributes.first(where: { $0.oid == OID.agilityV1 }) {
                    try verifyV1(attribute, directories: byHashType)
                    v1 = true
                }
                if let attribute = attributes.first(where: { $0.oid == OID.agilityV2 }) {
                    try verifyV2(attribute, directories: byHashType)
                    v2 = true
                }
            }
            let loadedSlots = Set(loaded.map { $0.facts.slot })
            let bindings = raw.values.sorted { $0.facts.slot < $1.facts.slot }.map { directory in
                let isLoaded = loadedSlots.contains(directory.facts.slot)
                var evidence: [Authentication] = []
                if !adHoc && isLoaded {
                    if directory.facts.slot == 0 { evidence.append(.detachedPrimaryCMS) }
                    if v1 { evidence.append(.hashAgilityV1) }
                    if v2 { evidence.append(.hashAgilityV2) }
                }
                return DirectoryBinding(slot: directory.facts.slot, hashType: directory.facts.hashType,
                    rawCodeDirectorySHA256: directory.sha256, cdHash: Data(directory.fullHash.prefix(20)),
                    fullCDHash: directory.fullHash, loaded: isLoaded, authenticatedBy: evidence)
            }
            slices.append(SliceBinding(sliceOffset: slice.range.offset, selectedDirectorySlot: selected.facts.slot,
                isAdHoc: adHoc, signers: signers, v1: v1, v2: v2, directories: bindings))
        }
        return Verification(slices: slices, additionalBytesRead: readBytes)
    }
    private struct RawDirectory {
        let facts: Reader.CodeDirectory
        let bytes: Data
        let sha256: Data
        let fullHash: Data
    }
    private static func selectedDirectory(_ directories: [RawDirectory]) throws -> RawDirectory {
        for kind: UInt8 in [4, 2, 3, 1] {
            if let value = directories.first(where: { $0.facts.hashType == kind }) { return value }
        }
        throw Failure.changedCodeDirectory
    }
    private static func verifyV1(_ attribute: CMS.SignedAttribute, directories: [RawDirectory]) throws {
        guard attribute.values.count == 1, let value = attribute.values.first, value.tag == 0x04 else {
            throw Failure.malformedHashAgilityV1
        }
        let object: Any
        do { object = try PropertyListSerialization.propertyList(from: value.body, options: [], format: nil) }
        catch { throw Failure.malformedHashAgilityV1 }
        guard let dictionary = object as? [String: Any], let hashes = dictionary["cdhashes"] as? [Data] else {
            throw Failure.malformedHashAgilityV1
        }
        guard hashes == directories.map({ Data($0.fullHash.prefix(20)) }) else { throw Failure.hashAgilityMismatch }
    }
    private static func verifyV2(_ attribute: CMS.SignedAttribute, directories: [RawDirectory]) throws {
        var actual: [Data: Data] = [:]
        for value in attribute.values {
            guard value.tag == 0x30 else { throw Failure.malformedHashAgilityV2 }
            let fields = try CMS.children(of: value)
            guard fields.count == 2, fields[0].tag == 0x06, fields[1].tag == 0x04,
                  actual[fields[0].body] == nil else { throw Failure.malformedHashAgilityV2 }
            actual[fields[0].body] = fields[1].body
        }
        guard actual.count == directories.count else { throw Failure.hashAgilityMismatch }
        for directory in directories {
            let oid: Data
            switch directory.facts.hashType {
            case 1: oid = OID.sha1
            case 2, 3: oid = OID.sha256
            case 4: oid = OID.sha384
            default: throw Failure.hashAgilityMismatch
            }
            // Pinned Security hashFor(type3) and cdhash(false) both produce
            // 20 bytes. Do not silently replace that actual hasher with SHA256.
            guard actual[oid] == directory.fullHash else { throw Failure.hashAgilityMismatch }
        }
    }
    private enum OID {
        static let agilityV1 = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x09, 0x01])
        static let agilityV2 = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x09, 0x02])
        static let sha1 = Data([0x2b, 0x0e, 0x03, 0x02, 0x1a])
        static let sha256 = Data([0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01])
        static let sha384 = Data([0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02])
    }
}
