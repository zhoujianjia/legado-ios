import Foundation
import Testing
@testable import yuedu_app

@Suite("Self-renewal Mach-O structure, generated owned fixtures only")
struct SelfRenewalMachOSignatureReaderTests {
    private typealias Reader = SelfRenewalMachOSignatureReader

    @Test("Thin 32/64-bit, both byte orders, use sparse bounded reads and never establish trust")
    func readsThinSignaturesWithoutReadingExecutableBodiesOrClaimingTrust() throws {
        for is64 in [false, true] {
            for little in [false, true] {
                let bytes = Self.thin(is64: is64, little: little, signatureOffset: 131_072)
                var requests: [Reader.ByteRange] = []
                let result = try Reader.parse(fileByteCount: UInt64(bytes.count)) { range in
                    requests.append(range)
                    return bytes.subdata(in: Int(range.offset)..<Int(range.end))
                }
                #expect(result.container == (is64 ? .thin64 : .thin32))
                let slice = try #require(result.slices.first)
                #expect(slice.byteOrder == (little ? .little : .big))
                let signature = try #require(slice.signature)
                #expect(signature.range.offset == 131_072)
                #expect(signature.cmsPayloadByteCount == 2)
                let directory = try #require(signature.codeDirectories.first)
                #expect(directory.identifier == "owned.reader")
                #expect(directory.teamIdentifier == "OWNEDTEAM")
                #expect(directory.codeLimit == 131_072)
                #expect(directory.codeSlotCount == 32)
                #expect(result.bytesRead < 2_048)
                #expect(requests.allSatisfy { $0.byteCount <= Reader.Limits.signatureBytes })
                #expect(requests.reduce(0) { $0 + $1.byteCount } == result.bytesRead)
                #expect(!signature.cryptographicVerificationPerformed)
                #expect(!result.cryptographicVerificationPerformed && !result.replacementAuthorized)
            }
        }
    }

    @Test("Fat 32/64-bit wrappers preserve each architecture and relative signature ranges")
    func readsFat32And64InBothByteOrders() throws {
        let first = Self.thin(is64: true, little: true, cpu: 0x0100000c)
        let second = Self.thin(is64: false, little: false, cpu: 12)
        for is64 in [false, true] {
            for little in [false, true] {
                let result = try Self.parse(Self.fat([first, second], is64: is64, little: little))
                #expect(result.container == (is64 ? .fat64 : .fat32))
                #expect(result.slices.count == 2)
                #expect(result.slices.map(\.cpuType) == [0x0100000c, 12])
                #expect(result.slices.map(\.is64Bit) == [true, false])
                for slice in result.slices {
                    let signature = try #require(slice.signature)
                    #expect(signature.range.offset == slice.range.offset + 64)
                    #expect(signature.range.end <= slice.range.end)
                    #expect(signature.codeDirectories.first?.codeLimit == 64)
                }
            }
        }
    }

    @Test("Malformed fat ranges, architecture identities and hard architecture limit are rejected")
    func rejectsMalformedFatTablesAndOverlappingSlices() throws {
        let a = Self.thin(cpu: 0x0100000c)
        let b = Self.thin(is64: false, little: true, cpu: 12)
        let valid = Self.fat([a, b], is64: false, little: false)
        var overlap = valid
        Self.put32(&overlap, 36, Self.u32(valid, 16))
        #expect(throws: Reader.Failure.overlappingRanges) { try Self.parse(overlap) }
        var outside = valid
        Self.put32(&outside, 20, UInt32.max)
        #expect(throws: Reader.Failure.malformedFat) { try Self.parse(outside) }
        var architecture = valid
        Self.put32(&architecture, 8, 99)
        #expect(throws: Reader.Failure.architectureMismatch) { try Self.parse(architecture) }
        var count = valid
        Self.put32(&count, 4, 17)
        #expect(throws: Reader.Failure.architectureLimit) { try Self.parse(count) }
        var reserved = Self.fat([a], is64: true, little: false)
        Self.put32(&reserved, 36, 1)
        #expect(throws: Reader.Failure.malformedFat) { try Self.parse(reserved) }
    }

    @Test("Load-command limits, alignment, duplicate signatures and unknown required commands fail closed")
    func rejectsMalformedAndUnknownRequiredLoadCommands() throws {
        let valid = Self.thin()
        var zero = valid
        Self.put32(&zero, 36, 0, little: true)
        #expect(throws: Reader.Failure.malformedLoadCommand) { try Self.parse(zero) }
        var unaligned = valid
        Self.put32(&unaligned, 36, 12, little: true)
        #expect(throws: Reader.Failure.malformedLoadCommand) { try Self.parse(unaligned) }
        var unknown = valid
        Self.put32(&unknown, 32, 0x8000ffff, little: true)
        #expect(throws: Reader.Failure.unknownRequiredCommand) { try Self.parse(unknown) }
        var optional = valid
        Self.put32(&optional, 32, 0x7fff, little: true)
        #expect(try Self.parse(optional).slices.first?.signature == nil)
        var duplicate = valid
        Self.put32(&duplicate, 16, 2, little: true)
        Self.put32(&duplicate, 20, 32, little: true)
        duplicate.replaceSubrange(48..<64, with: valid[32..<48])
        #expect(throws: Reader.Failure.duplicateCodeSignature) { try Self.parse(duplicate) }
        var excessive = valid
        Self.put32(&excessive, 16, 4_097, little: true)
        #expect(throws: Reader.Failure.commandLimit) { try Self.parse(excessive) }
        var signatureTooLarge = valid
        Self.put32(&signatureTooLarge, 44, UInt32(Reader.Limits.signatureBytes + 1), little: true)
        #expect(throws: Reader.Failure.signatureSizeLimit) { try Self.parse(signatureTooLarge) }
        var signatureInHeader = valid
        Self.put32(&signatureInHeader, 40, 32, little: true)
        #expect(throws: Reader.Failure.malformedSignature) { try Self.parse(signatureInHeader) }
    }

    @Test("SuperBlob slot duplication, overlaps, wrong magic, missing primary and nonzero padding reject")
    func rejectsDamagedEmbeddedSignatureStructures() throws {
        let valid = Self.thin()
        var overlap = valid
        Self.put32(&overlap, 64 + 24, 28)
        #expect(throws: Reader.Failure.overlappingRanges) { try Self.parse(overlap) }
        var duplicate = valid
        Self.put32(&duplicate, 64 + 20, 0)
        #expect(throws: Reader.Failure.malformedSignature) { try Self.parse(duplicate) }
        var wrong = valid
        Self.put32(&wrong, 64, 0xfade0cc1)
        #expect(throws: Reader.Failure.malformedSignature) { try Self.parse(wrong) }
        var missing = valid
        Self.put32(&missing, 64 + 12, 0x1000)
        #expect(throws: Reader.Failure.malformedSignature) { try Self.parse(missing) }
        var unknown = valid
        Self.put32(&unknown, 64 + 20, 0x7777)
        #expect(throws: Reader.Failure.unsupportedSignatureSlot) { try Self.parse(unknown) }
        var padding = valid
        padding.append(1)
        Self.put32(&padding, 44, UInt32(padding.count - 64), little: true)
        #expect(throws: Reader.Failure.malformedSignature) { try Self.parse(padding) }
    }

    @Test("CodeDirectory strings, hash ranges, hash kinds, versions and unsupported scatter reject")
    func rejectsInvalidCodeDirectoryOffsetsAndUnsupportedLayouts() throws {
        let valid = Self.thin()
        let directory = 64 + 28
        var stringOverlap = valid
        Self.put32(&stringOverlap, directory + 48, 52)
        #expect(throws: Reader.Failure.overlappingRanges) { try Self.parse(stringOverlap) }
        var hash = valid
        Self.put32(&hash, directory + 16, 4)
        #expect(throws: Reader.Failure.malformedCodeDirectory) { try Self.parse(hash) }
        var slots = valid
        Self.put32(&slots, directory + 28, 2)
        #expect(throws: Reader.Failure.malformedCodeDirectory) { try Self.parse(slots) }
        var hashKind = valid
        hashKind[directory + 37] = 99
        #expect(throws: Reader.Failure.unsupportedCodeDirectory) { try Self.parse(hashKind) }
        var version = valid
        Self.put32(&version, directory + 8, 0x20700)
        #expect(throws: Reader.Failure.unsupportedCodeDirectory) { try Self.parse(version) }
        var scatter = valid
        Self.put32(&scatter, directory + 44, 52)
        #expect(throws: Reader.Failure.unsupportedScatter) { try Self.parse(scatter) }
        var invalidUTF8 = valid
        invalidUTF8[directory + 52] = 0xff
        #expect(throws: Reader.Failure.malformedString) { try Self.parse(invalidUTF8) }
        var outside = valid
        Self.put32(&outside, directory + 20, UInt32.max)
        #expect(throws: Reader.Failure.malformedString) { try Self.parse(outside) }
    }

    @Test("Known CodeDirectory headers and empty ad-hoc CMS wrappers remain unverified")
    func readsKnownDirectoryVersionsAndEmptyCMSWithoutAssumingTrust() throws {
        for version: UInt32 in [0x20001, 0x20100, 0x20200, 0x20300, 0x20400, 0x20500, 0x20600] {
            let bytes = Self.thin(codeDirectoryVersion: version, emptyCMS: true)
            let signature = try #require(Self.parse(bytes).slices.first?.signature)
            let directory = try #require(signature.codeDirectories.first)
            #expect(directory.version == version)
            #expect(directory.identifier == "owned.reader")
            #expect(directory.teamIdentifier == (version >= 0x20200 ? "OWNEDTEAM" : nil))
            #expect(signature.cmsPayloadByteCount == 0)
            #expect(!signature.cryptographicVerificationPerformed)
        }
        let directory = 64 + 28
        var encrypted = Self.thin(codeDirectoryVersion: 0x20500)
        Self.put32(&encrypted, directory + 92, 96)
        #expect(throws: Reader.Failure.unsupportedPreEncryptedHashes) { try Self.parse(encrypted) }
        var linkage = Self.thin(codeDirectoryVersion: 0x20600)
        linkage[directory + 96] = 2
        #expect(throws: Reader.Failure.unsupportedLinkage) { try Self.parse(linkage) }
        var identifierWithSpace = Self.thin()
        identifierWithSpace[directory + 52] = 32
        #expect(try Self.parse(identifierWithSpace).slices.first?.signature?
            .codeDirectories.first?.identifier == " wned.reader")
        var emptyIdentifier = Self.thin()
        emptyIdentifier[directory + 52] = 0
        #expect(try Self.parse(emptyIdentifier).slices.first?.signature?
            .codeDirectories.first?.identifier == "")
    }

    @Test("No signature and truncated reads remain explicit observations/errors; cancellation propagates")
    func handlesUnsignedTruncatedAndCancelledInputs() async throws {
        var unsigned = Self.thin()
        Self.put32(&unsigned, 16, 0, little: true)
        Self.put32(&unsigned, 20, 0, little: true)
        #expect(try Self.parse(unsigned).slices.first?.signature == nil)
        #expect(throws: Reader.Failure.truncatedRead) {
            try Reader.parse(fileByteCount: 1_024) { _ in Data() }
        }
        #expect(throws: Reader.Failure.fileSizeLimit) {
            try Reader.parse(fileByteCount: UInt64.max) { _ in Data() }
        }
        let cancelled = Task.detached { () throws -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try Self.parse(Self.thin()); return false }
            catch is CancellationError { return true }
        }
        #expect(try await cancelled.value)
    }

    @Test("The independent material reader consumes inventory code facts and stays untrusted")
    func readsOwnedUnpackedAppThroughInventoryAndRejectsLinkedCode() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = base.appendingPathComponent("Owned.app", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { Self.removeOwnedFixture(base) }
        let info: [String: String] = ["CFBundleIdentifier": "owned.reader", "CFBundleExecutable": "Owned",
            "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: root.appendingPathComponent("Info.plist"))
        let executable = root.appendingPathComponent("Owned")
        try Self.thin().write(to: executable)
        let result = try await Reader.read(unpackedApplication: root)
        #expect(result.inventory.codeFiles.count == 1 && result.code.count == 1)
        #expect(result.code.first?.file.relativePath == "Owned")
        #expect(result.code.first?.structure.slices.first?.signature?.cmsPayloadByteCount == 2)
        #expect(result.signatureStructureBytesRead == result.code.first?.structure.bytesRead)
        #expect(!result.cryptographicVerificationPerformed && !result.accountIdentityEstablished)
        #expect(!result.replacementAuthorized)
        try FileManager.default.moveItem(at: executable, to: root.appendingPathComponent("Original"))
        try FileManager.default.createSymbolicLink(atPath: executable.path, withDestinationPath: "Original")
        await #expect(throws: SelfRenewalMaterialInventory.Failure.linkNotAllowed) {
            try await Reader.read(unpackedApplication: root)
        }
    }

    private static func parse(_ data: Data) throws -> Reader.ParsedFile {
        try Reader.parse(fileByteCount: UInt64(data.count)) { range in
            data.subdata(in: Int(range.offset)..<Int(range.end))
        }
    }
    private static func thin(is64: Bool = true, little: Bool = true,
        cpu: UInt32 = 0x0100000c, signatureOffset: Int = 64,
        codeDirectoryVersion: UInt32 = 0x20200, emptyCMS: Bool = false) -> Data {
        let signature = superBlob(codeLimit: signatureOffset,
            version: codeDirectoryVersion, emptyCMS: emptyCMS)
        var bytes = Data(repeating: 0, count: signatureOffset)
        put32(&bytes, 0, is64 ? 0xfeedfacf : 0xfeedface, little: little)
        put32(&bytes, 4, cpu, little: little)
        put32(&bytes, 12, 2, little: little)
        put32(&bytes, 16, 1, little: little)
        put32(&bytes, 20, 16, little: little)
        let command = is64 ? 32 : 28
        put32(&bytes, command, 0x1d, little: little)
        put32(&bytes, command + 4, 16, little: little)
        put32(&bytes, command + 8, UInt32(signatureOffset), little: little)
        put32(&bytes, command + 12, UInt32(signature.count), little: little)
        bytes.append(signature)
        return bytes
    }
    private static func superBlob(codeLimit: Int, version: UInt32, emptyCMS: Bool) -> Data {
        let sizes: [UInt32: Int] = [0x20001: 44, 0x20100: 48, 0x20200: 52,
            0x20300: 64, 0x20400: 88, 0x20500: 96, 0x20600: 108]
        let header = sizes[version] ?? 52
        var directory = Data(repeating: 0, count: header)
        put32(&directory, 0, 0xfade0c02)
        put32(&directory, 8, version)
        put32(&directory, 20, UInt32(header))
        directory.append(contentsOf: "owned.reader".utf8)
        directory.append(0)
        if version >= 0x20200 {
            put32(&directory, 48, UInt32(directory.count))
            directory.append(contentsOf: "OWNEDTEAM".utf8)
            directory.append(0)
        }
        let slots = (codeLimit - 1) / 4_096 + 1
        put32(&directory, 16, UInt32(directory.count))
        put32(&directory, 28, UInt32(slots))
        put32(&directory, 32, UInt32(codeLimit))
        directory[36] = 32
        directory[37] = 2
        directory[39] = 12
        directory.append(Data(repeating: 0, count: slots * 32))
        put32(&directory, 4, UInt32(directory.count))
        var signature = Data(repeating: 0, count: 28)
        put32(&signature, 0, 0xfade0cc0)
        put32(&signature, 8, 2)
        put32(&signature, 16, 28)
        put32(&signature, 20, 0x10000)
        put32(&signature, 24, UInt32(28 + directory.count))
        signature.append(directory)
        var cms = Data(repeating: 0, count: 8)
        put32(&cms, 0, 0xfade0b01)
        put32(&cms, 4, emptyCMS ? 8 : 10)
        if !emptyCMS { cms.append(contentsOf: [0x30, 0x00]) }
        signature.append(cms)
        put32(&signature, 4, UInt32(signature.count))
        return signature
    }
    private static func fat(_ slices: [Data], is64: Bool, little: Bool) -> Data {
        let stride = is64 ? 32 : 20
        var bytes = Data(repeating: 0, count: 8 + slices.count * stride)
        put32(&bytes, 0, is64 ? 0xcafebabf : 0xcafebabe, little: little)
        put32(&bytes, 4, UInt32(slices.count), little: little)
        for (index, slice) in slices.enumerated() {
            while bytes.count % 64 != 0 { bytes.append(0) }
            let start = 8 + index * stride
            let sliceIsLittle = slice[0] == 0xce || slice[0] == 0xcf
            put32(&bytes, start, u32(slice, 4, little: sliceIsLittle), little: little)
            put32(&bytes, start + 4, u32(slice, 8, little: sliceIsLittle), little: little)
            if is64 {
                put64(&bytes, start + 8, UInt64(bytes.count), little: little)
                put64(&bytes, start + 16, UInt64(slice.count), little: little)
                put32(&bytes, start + 24, 6, little: little)
            } else {
                put32(&bytes, start + 8, UInt32(bytes.count), little: little)
                put32(&bytes, start + 12, UInt32(slice.count), little: little)
                put32(&bytes, start + 16, 6, little: little)
            }
            bytes.append(slice)
        }
        return bytes
    }
    private static func put32(_ data: inout Data, _ offset: Int, _ value: UInt32, little: Bool = false) {
        for index in 0..<4 {
            data[offset + index] = UInt8(truncatingIfNeeded: value >> ((little ? index : 3 - index) * 8))
        }
    }
    private static func put64(_ data: inout Data, _ offset: Int, _ value: UInt64, little: Bool) {
        for index in 0..<8 {
            data[offset + index] = UInt8(truncatingIfNeeded: value >> ((little ? index : 7 - index) * 8))
        }
    }
    private static func u32(_ data: Data, _ offset: Int, little: Bool = false) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 { value |= UInt32(data[offset + index]) << ((little ? index : 3 - index) * 8) }
        return value
    }
    private static func removeOwnedFixture(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) }
        catch { Issue.record("Owned Mach-O fixture cleanup failed") }
    }
}
