import Foundation
import Testing
@testable import yuedu_app

@Suite("Actual CodeDirectory CMS and authenticated agility, owned vectors only")
struct SelfRenewalSignedCodeVerifierTests {
    private typealias Verifier = SelfRenewalSignedCodeVerifier
    private typealias Reader = SelfRenewalMachOSignatureReader
    private typealias Hashes = SelfRenewalCodeDirectoryHashVerifier
    private typealias Fixture = SelfRenewalSignedCodeFixture
    private static let anchors = [SelfRenewalCMSFixture.rootCertificate]
    private static let date = SelfRenewalCMSFixture.validationDate

    @Test("Legacy detached CMS authenticates actual primary bytes without inventing alternate authentication")
    func authenticatesDetachedPrimaryAndPreservesLegacyUnboundAlternate() async throws {
        try await Task.detached {
            let bytes = try Fixture.data("legacy")
            let proof = try Self.verify(bytes)
            let slice = try #require(proof.slices.first)
            #expect(slice.selectedDirectorySlot == 0x1000)
            #expect(slice.directories.map(\.signerAuthenticated) == [true, false])
            #expect(slice.directories.first?.authenticatedBy == [.detachedPrimaryCMS])
            #expect(!slice.selectedDirectoryAuthenticated && !proof.allLoadedDirectoriesAuthenticated)
            #expect(!slice.hashAgilityV1Present && !slice.hashAgilityV2Present)
            #expect(slice.signers.count == 1)
            #expect(!proof.appleSigningAuthorityEstablished && !proof.provisioningProfileAuthorized)
            #expect(!proof.resourceTreeVerified && !proof.replacementAuthorized)
            let changedPrimary = try Self.changedIdentifier(bytes, slot: 0)
            #expect(throws: SelfRenewalCMSVerifier.Failure.digestMismatch) { try Self.verify(changedPrimary) }
            // Legacy behavior permits an unbound alternate; the result must keep
            // that limitation visible instead of treating its valid pages as trust.
            let changedAlternate = try Self.verify(Self.changedIdentifier(bytes, slot: 0x1000))
            #expect(changedAlternate.slices.first?.directories.last?.signerAuthenticated == false)
        }.value
    }

    @Test("Actual signed V1/V2 values bind full raw directories and preserve signed DER bytes")
    func bindsOriginalHashAgilityEncodingsAndRejectsWrongValues() async throws {
        try await Task.detached {
            for name in ["v1", "v2", "both"] {
                let proof = try Self.verify(Fixture.data(name))
                let slice = try #require(proof.slices.first)
                #expect(proof.allLoadedDirectoriesAuthenticated && slice.selectedDirectoryAuthenticated)
                #expect(slice.selectedDirectorySlot == 0x1000) // SHA384 beats SHA256.
                #expect(slice.directories.map(\.hashType) == [1, 4, 2])
                #expect(slice.hashAgilityV1Present == (name != "v2"))
                #expect(slice.hashAgilityV2Present == (name != "v1"))
                let signer = try #require(slice.signers.first)
                let der = try #require(signer.signedAttributesDER)
                #expect(der.first == 0x31 && !signer.signedAttributes.isEmpty)
                #expect(signer.signedAttributes.allSatisfy { $0.originalDER.first == 0x30 })
                #expect(throws: Verifier.Failure.hashAgilityMismatch) {
                    try Self.verify(Self.changedIdentifier(Fixture.data(name), slot: 0x1001))
                }
            }
            // These CMS signatures are independently valid in OpenSSL; their
            // authenticated attribute values disagree with the CodeDirectories.
            for name in ["v1WrongOrder", "v2WrongDigest"] {
                #expect(throws: Verifier.Failure.hashAgilityMismatch) { try Self.verify(Fixture.data(name)) }
            }
        }.value
    }

    @Test("Original type3 hasher emits 20 bytes for V2 and duplicate algorithm OIDs reject")
    func supportsOriginalTruncatedCDHashAndRejectsAgilityOIDCollisions() async throws {
        try await Task.detached {
            let proof = try Self.verify(Fixture.data("v2Truncated"))
            let directory = try #require(proof.slices.first?.directories.first)
            #expect(directory.hashType == 3 && directory.fullCDHash.count == 20)
            #expect(directory.fullCDHash == Self.hex(Fixture.truncatedFullHashHex))
            #expect(directory.cdHash == directory.fullCDHash && directory.signerAuthenticated)
            #expect(throws: Verifier.Failure.hashAgilityMismatch) { try Self.verify(Fixture.data("v2WrongLength")) }
            #expect(throws: Verifier.Failure.malformedHashAgilityV2) { try Self.verify(Fixture.data("v2DuplicateOID")) }
        }.value
    }

    @Test("Original alternate gap, selected ad-hoc and duplicate hash-type behavior remain distinct")
    func preservesOriginalAlternateOrderAndAdHocSemantics() async throws {
        try await Task.detached {
            let gap = try Self.verify(Fixture.data("gap"))
            let slice = try #require(gap.slices.first)
            #expect(slice.selectedDirectorySlot == 0 && slice.selectedDirectoryAuthenticated)
            #expect(slice.directories.map(\.loadedByOriginalAlternateOrder) == [true, false])
            #expect(slice.directories.map(\.signerAuthenticated) == [true, false])
            #expect(gap.allLoadedDirectoriesAuthenticated) // Only the primary was loaded.
            let adHoc = try Self.verify(Fixture.data("adHoc"))
            #expect(adHoc.slices.first?.isAdHoc == true && adHoc.slices.first?.signers == [])
            #expect(!adHoc.allLoadedDirectoriesAuthenticated)
            #expect(adHoc.slices.first?.directories.allSatisfy { !$0.signerAuthenticated } == true)
            var unsigned = try Fixture.data("adHoc")
            let structure = try Reader.parse(fileByteCount: UInt64(unsigned.count)) { Self.read(unsigned, $0) }
            let signature = try #require(structure.slices.first?.signature)
            for directory in signature.codeDirectories {
                unsigned[Int(signature.range.offset + directory.blobRange.offset) + 15] = 0
            }
            #expect(throws: Verifier.Failure.missingCMS) { try Self.verify(unsigned) }
            #expect(throws: Verifier.Failure.duplicateHashType) { try Self.verify(Fixture.data("duplicateHashType")) }
        }.value
    }

    @Test("Re-read CD equality, budgets, short reads, all slices and cancellation guard publication")
    func rejectsChangedReadBudgetsAndCancellationAcrossSlices() async throws {
        try await Task.detached {
            let bytes = try Fixture.data("both")
            let verified = try Self.hash(bytes)
            let signature = try #require(verified.structure.slices.first?.signature)
            let primary = try #require(signature.codeDirectories.first { $0.slot == 0 })
            #expect(throws: Verifier.Failure.changedCodeDirectory) {
                try Verifier.bind(verified, anchors: Self.anchors, at: Self.date) { range in
                    var read = Self.read(bytes, range)
                    if range.offset == signature.range.offset + primary.blobRange.offset { read[52] ^= 1 }
                    return read
                }
            }
            #expect(throws: Verifier.Failure.readLimit) {
                try Verifier.bind(verified, anchors: Self.anchors, at: Self.date, maximumReadBytes: 1) { Self.read(bytes, $0) }
            }
            #expect(throws: Verifier.Failure.truncatedRead) {
                try Verifier.bind(verified, anchors: Self.anchors, at: Self.date) { _ in Data() }
            }
            let fat = try Self.fat(Fixture.data("v1"), Fixture.data("v2"))
            let fatProof = try Self.verify(fat)
            #expect(fatProof.slices.count == 2 && fatProof.allLoadedDirectoriesAuthenticated)
            var secondChanged = fat
            let second = try #require(Self.hash(fat).structure.slices.last)
            let secondSignature = try #require(second.signature)
            let secondPrimary = try #require(secondSignature.codeDirectories.first { $0.slot == 0 })
            secondChanged[Int(secondSignature.range.offset + secondPrimary.blobRange.offset) + 52] ^= 1
            #expect(throws: SelfRenewalCMSVerifier.Failure.digestMismatch) { try Self.verify(secondChanged) }
            let cancelled = Task.detached { () throws -> Bool in
                withUnsafeCurrentTask { $0?.cancel() }
                do { _ = try Self.verify(bytes); return false }
                catch is CancellationError { return true }
            }
            #expect(try await cancelled.value)
        }.value
    }

    @Test("Owned app entry joins inventory, actual content hashes and same-FD detached signatures")
    func readsOwnedAppAndKeepsGenericAnchorsSeparateFromAppleAuthority() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = base.appendingPathComponent("Owned.app", isDirectory: true)
        try await Task.detached { try Self.writeOwnedApp(root) }.value
        defer { Self.removeOwnedFixture(base) }
        let materials = try await Verifier.read(unpackedApplication: root, anchors: Self.anchors, at: Self.date)
        let code = try #require(materials.code.first)
        let proof = try #require(code.signedCodeVerification)
        #expect(proof.allLoadedDirectoriesAuthenticated)
        #expect(code.contentHashVerification?.contentDigestsVerified == true)
        #expect(materials.signatureVerificationBytesRead == proof.additionalBytesRead)
        #expect(!materials.accountIdentityEstablished && !materials.replacementAuthorized)
        #expect(!proof.appleSigningAuthorityEstablished && !proof.provisioningProfileAuthorized)
        #expect(!proof.resourceTreeVerified && !proof.replacementAuthorized)
        await #expect(throws: SelfRenewalCMSVerifier.Failure.untrustedChain) {
            try await Verifier.read(unpackedApplication: root, anchors: Self.anchors,
                at: Self.date.addingTimeInterval(12 * 366 * 86_400))
        }
        try await Task.detached {
            let info = Data(String(decoding: Fixture.info, as: UTF8.self)
                .replacingOccurrences(of: ">1.0<", with: ">2.0<").utf8)
            try info.write(to: root.appendingPathComponent("Info.plist"))
        }.value
        await #expect(throws: Hashes.Failure.specialSlotMismatch(1)) {
            try await Verifier.read(unpackedApplication: root, anchors: Self.anchors, at: Self.date)
        }
    }

    @Test("Shared owned FD reader supports empty hashes and enforces chunks, budgets, identity and paths")
    func enforcesSharedOwnedFileReadBoundaryIncludingEmptyFiles() async throws {
        try await Task.detached {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let root = base.appendingPathComponent("Owned.app", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { Self.removeOwnedFixture(base) }
            let empty = SelfRenewalMaterialInventory.FileFact(relativePath: "empty", byteCount: 0)
            try Data().write(to: root.appendingPathComponent("empty"))
            let zero = try Reader.withOwnedFile(root: root, fact: empty, maximumReadBytes: 0) { read in
                try read(Reader.ByteRange(offset: 0, byteCount: 0))
            }
            #expect(zero.isEmpty)
            let bytes = Data(repeating: 0x71, count: 65_537)
            let fact = SelfRenewalMaterialInventory.FileFact(relativePath: "stream", byteCount: Int64(bytes.count))
            try bytes.write(to: root.appendingPathComponent("stream"))
            let full = try Reader.withOwnedFile(root: root, fact: fact, maximumReadBytes: bytes.count) { read in
                var value = try read(Reader.ByteRange(offset: 0, byteCount: 65_536))
                value.append(try read(Reader.ByteRange(offset: 65_536, byteCount: 1)))
                return value
            }
            #expect(full == bytes)
            #expect(throws: Reader.Failure.truncatedRead) {
                try Reader.withOwnedFile(root: root, fact: fact, maximumReadBytes: bytes.count) { read in
                    try read(Reader.ByteRange(offset: 0, byteCount: 65_537))
                }
            }
            #expect(throws: Reader.Failure.totalReadLimit) {
                try Reader.withOwnedFile(root: root, fact: fact, maximumReadBytes: 0) { read in
                    try read(Reader.ByteRange(offset: 0, byteCount: 1))
                }
            }
            #expect(throws: Reader.Failure.truncatedRead) {
                try Reader.withOwnedFile(root: root, fact: fact, maximumReadBytes: 1) { read in
                    try read(Reader.ByteRange(offset: UInt64(bytes.count), byteCount: 1))
                }
            }
            #expect(throws: Reader.Failure.invalidPath) {
                try Reader.withOwnedFile(root: root, fact: .init(relativePath: "../escape", byteCount: 0), maximumReadBytes: 0) { _ in 0 }
            }
            #expect(throws: Reader.Failure.fileSizeLimit) {
                try Reader.withOwnedFile(root: root, fact: fact,
                    maximumReadBytes: Reader.Limits.ownedFileReadBytes + 1) { _ in 0 }
            }
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"),
                withDestinationURL: root.appendingPathComponent("stream"))
            #expect(throws: Reader.Failure.unreadableFile) {
                try Reader.withOwnedFile(root: root, fact: .init(relativePath: "link", byteCount: fact.byteCount),
                    maximumReadBytes: 0) { _ in 0 }
            }
            let cancelled = Task.detached { () throws -> Bool in
                withUnsafeCurrentTask { $0?.cancel() }
                do {
                    _ = try Reader.withOwnedFile(root: root, fact: empty, maximumReadBytes: 0) { _ in 0 }
                    return false
                } catch is CancellationError { return true }
            }
            #expect(try await cancelled.value)
            #expect(throws: Reader.Failure.fileChangedDuringRead) {
                try Reader.withOwnedFile(root: root, fact: fact, maximumReadBytes: 1) { read in
                    let value = try read(Reader.ByteRange(offset: 0, byteCount: 1))
                    // A deterministic size change must fail the final fstat.
                    let writer = try FileHandle(forWritingTo: root.appendingPathComponent("stream"))
                    defer { Self.closeOwnedWriter(writer) }
                    try writer.truncate(atOffset: 1)
                    return value
                }
            }
        }.value
    }

    private static func hash(_ bytes: Data) throws -> Hashes.VerifiedFile {
        try Hashes.verify(fileByteCount: UInt64(bytes.count), readStructureRange: { read(bytes, $0) },
            readContentRange: { read(bytes, $0) }, externalSpecialSlot: { slot, _ in
                slot == 1 ? Fixture.info : (slot == 3 ? Fixture.resources : nil)
            })
    }
    private static func verify(_ bytes: Data) throws -> Verifier.Verification {
        try Verifier.bind(hash(bytes), anchors: anchors, at: date) { read(bytes, $0) }
    }
    private static func read(_ bytes: Data, _ range: Reader.ByteRange) -> Data {
        bytes.subdata(in: Int(range.offset)..<Int(range.end))
    }
    private static func changedIdentifier(_ bytes: Data, slot: UInt32) throws -> Data {
        let structure = try Reader.parse(fileByteCount: UInt64(bytes.count)) { read(bytes, $0) }
        let signature = try #require(structure.slices.first?.signature)
        let directory = try #require(signature.codeDirectories.first { $0.slot == slot })
        var changed = bytes
        changed[Int(signature.range.offset + directory.blobRange.offset) + 52] ^= 1
        return changed
    }
    private static func fat(_ first: Data, _ second: Data) throws -> Data {
        // The independently signed v2 vector has x86_64 pages; v1 is arm64.
        // Fat table offsets do not alter either raw signed thin slice.
        var bytes = Data(repeating: 0, count: 48)
        put32(&bytes, at: 0, 0xcafebabe)
        put32(&bytes, at: 4, 2)
        for (index, slice) in [first, second].enumerated() {
            while bytes.count % 64 != 0 { bytes.append(0) }
            let entry = 8 + index * 20
            let cpu = (0..<4).reduce(UInt32(0)) { $0 | UInt32(slice[4 + $1]) << ($1 * 8) }
            put32(&bytes, at: entry, cpu)
            put32(&bytes, at: entry + 8, UInt32(bytes.count))
            put32(&bytes, at: entry + 12, UInt32(slice.count))
            put32(&bytes, at: entry + 16, 6)
            bytes.append(slice)
        }
        return bytes
    }
    private static func put32(_ bytes: inout Data, at offset: Int, _ value: UInt32) {
        for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> ((3 - index) * 8)) }
    }
    private static func writeOwnedApp(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("_CodeSignature"), withIntermediateDirectories: true)
        try Fixture.info.write(to: root.appendingPathComponent("Info.plist"))
        try Fixture.resources.write(to: root.appendingPathComponent("_CodeSignature/CodeResources"))
        try Fixture.data("both").write(to: root.appendingPathComponent("Owned"))
    }
    private static func hex(_ string: String) -> Data {
        var bytes = Data()
        var index = string.startIndex
        while index < string.endIndex {
            let end = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<end], radix: 16) else { preconditionFailure("Invalid owned vector") }
            bytes.append(byte)
            index = end
        }
        return bytes
    }
    private static func removeOwnedFixture(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) }
        catch { Issue.record("Owned fixture cleanup failed: \(error)") }
    }
    private static func closeOwnedWriter(_ writer: FileHandle) {
        do { try writer.close() }
        catch { Issue.record("Owned fixture writer close failed: \(error)") }
    }
}
