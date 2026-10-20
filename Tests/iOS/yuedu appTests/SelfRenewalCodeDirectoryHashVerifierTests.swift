import Foundation
import Testing
@testable import yuedu_app

@Suite("CodeDirectory real content digests, independent owned vectors only")
struct SelfRenewalCodeDirectoryHashVerifierTests {
    private typealias Verifier = SelfRenewalCodeDirectoryHashVerifier
    private typealias Reader = SelfRenewalMachOSignatureReader

    @Test("SHA1, SHA256, truncated SHA256 and SHA384 match independent fixed abc vectors")
    func matchesIndependentDigestVectors() throws {
        let expected: [UInt8: String] = [
            1: "a9993e364706816aba3e25717850c26c9cd0d89d",
            2: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            3: "ba7816bf8f01cfea414140de5dae2223b00361a396",
            4: "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7",
        ]
        for (kind, hex) in expected {
            #expect(try Verifier.digest(Data("abc".utf8), hashType: kind) == Self.hex(hex))
        }
        #expect(throws: Verifier.Failure.unsupportedHash) {
            try Verifier.digest(Data(), hashType: 99)
        }
    }

    @Test("Four hash kinds verify every code page, short final page and actual special-slot bytes")
    func verifiesFourAlgorithmsAndAllKnownSpecialMaterials() throws {
        for kind in 1...4 {
            let bytes = try Self.fixture("thin\(kind)")
            var ranges: [Reader.ByteRange] = []
            let result = try Self.verify(bytes, contentRead: { ranges.append($0) })
            let directory = try #require(result.verification.directories.first)
            #expect(directory.hashType == UInt8(kind))
            #expect(directory.verifiedCodeSlots == 3 && directory.codeBytesHashed == 173)
            #expect(directory.verifiedSpecialSlots == [1, 2, 3, 5, 7])
            #expect(directory.absentSpecialSlots == [4, 6, 8, 9, 10, 11])
            #expect(ranges.contains { $0.offset == 128 && $0.byteCount == 45 })
            #expect(result.verification.hashOperations == 8)
            #expect(result.verification.contentDigestsVerified)
            #expect(!result.verification.signatureAuthenticityVerified)
            #expect(!result.verification.provisioningProfileVerified)
            #expect(!result.verification.resourceEnvelopeVerified)
            #expect(!result.verification.replacementAuthorized)
        }
    }

    @Test("Changed pages, stored digests and every supported special material reject")
    func rejectsChangedPagesDigestsAndSpecialMaterials() throws {
        let valid = try Self.fixture("thin2")
        var code = valid
        code[70] ^= 1
        #expect(throws: Verifier.Failure.codeSlotMismatch(1)) { try Self.verify(code) }
        let structure = try Self.structure(valid)
        let signature = try #require(structure.slices.first?.signature)
        let directory = try #require(signature.codeDirectories.first)
        let hashOffset = Int(signature.range.offset + directory.blobRange.offset) + directory.hashOffset
        var storedDigest = valid
        storedDigest[hashOffset] ^= 1
        #expect(throws: Verifier.Failure.codeSlotMismatch(0)) { try Self.verify(storedDigest) }
        let directoryStart = Int(signature.range.offset + directory.blobRange.offset)
        var shorterLimit = valid
        Self.put32(&shorterLimit, directoryStart + 32, 172)
        #expect(throws: Verifier.Failure.codeSlotMismatch(2)) { try Self.verify(shorterLimit) }
        var differentPages = valid
        differentPages[directoryStart + 39] = 7
        Self.put32(&differentPages, directoryStart + 28, 2)
        #expect(throws: Verifier.Failure.codeSlotMismatch(0)) { try Self.verify(differentPages) }
        for slot: UInt32 in [1, 3] {
            var materials = Self.external
            materials[slot] = Data("changed material".utf8)
            #expect(throws: Verifier.Failure.specialSlotMismatch(slot)) {
                try Self.verify(valid, materials: materials)
            }
        }
        for slot: UInt32 in [2, 5, 7] {
            let blob = try #require(signature.blobs.first { $0.slot == slot })
            var changed = valid
            changed[Int(signature.range.offset + blob.range.end - 1)] ^= 1
            #expect(throws: Verifier.Failure.specialSlotMismatch(slot)) { try Self.verify(changed) }
        }
    }

    @Test("All slices, alternate directories, unlimited pages and large pages are checked with bounded chunks")
    func verifiesFatAlternateAndUnpagedContentWithBoundedChunks() throws {
        let alternate = try Self.verify(Self.fixture("alternate"))
        #expect(alternate.verification.directories.map(\.directorySlot) == [0, 0x1000])
        #expect(alternate.verification.directories.map(\.hashType) == [2, 4])
        let fat = Self.fat(try Self.fixture("thin2"), try Self.fixture("secondCPU"))
        let fatResult = try Self.verify(fat)
        #expect(fatResult.structure.slices.count == 2)
        #expect(fatResult.verification.directories.count == 2)
        #expect(fatResult.verification.directories.allSatisfy { $0.verifiedCodeSlots == 3 })
        var changedSecond = fat
        let second = try #require(fatResult.structure.slices.last)
        changedSecond[Int(second.range.offset) + 70] ^= 1
        #expect(throws: Verifier.Failure.codeSlotMismatch(1)) { try Self.verify(changedSecond) }
        let infinite = try Self.verify(Self.fixture("infinite"))
        #expect(infinite.verification.directories.first?.verifiedCodeSlots == 1)
        var contentRequests: [Reader.ByteRange] = []
        let large = try Self.verify(Self.fixture("largePage"), contentRead: { contentRequests.append($0) })
        #expect(large.verification.directories.first?.verifiedCodeSlots == 2)
        #expect(contentRequests.contains { $0.byteCount == 65_536 })
        #expect(contentRequests.allSatisfy { $0.byteCount <= 65_536 })
    }

    @Test("Missing, extra, unsupported and explicitly absent special slots are distinct")
    func rejectsMissingExtraAndUnsupportedSpecialSlots() throws {
        let valid = try Self.fixture("thin2")
        for slot: UInt32 in [1, 3] {
            var materials = Self.external
            materials.removeValue(forKey: slot)
            #expect(throws: Verifier.Failure.missingSpecialSlot(slot)) {
                try Self.verify(valid, materials: materials)
            }
        }
        let bare = try Self.fixture("bare")
        #expect(try Self.verify(bare, materials: [:]).verification.directories.first?.verifiedSpecialSlots == [])
        #expect(throws: Verifier.Failure.unexpectedSpecialSlot(1)) {
            try Self.verify(bare, materials: [1: Data()])
        }
        let signature = try #require(Self.structure(valid).slices.first?.signature)
        let directory = try #require(signature.codeDirectories.first)
        let base = Int(signature.range.offset + directory.blobRange.offset) + directory.hashOffset
        var zeroed = valid
        zeroed.replaceSubrange((base - 2 * 32)..<(base - 32), with: Data(repeating: 0, count: 32))
        #expect(throws: Verifier.Failure.unexpectedSpecialSlot(2)) { try Self.verify(zeroed) }
        var unsupported = valid
        unsupported[base - 4 * 32] = 1
        #expect(throws: Verifier.Failure.unsupportedSpecialSlot(4)) { try Self.verify(unsupported) }
        #expect(throws: Verifier.Failure.unsupportedSpecialSlot(12)) {
            try Self.verify(Self.fixture("unsupportedSpecial"))
        }
    }

    @Test("Content budgets, operation limits, short reads and cancellation never publish success")
    func rejectsBudgetsTruncatedReadsAndCancellation() async throws {
        let valid = try Self.fixture("thin2")
        let read: (Reader.ByteRange) throws -> Data = { valid.subdata(in: Int($0.offset)..<Int($0.end)) }
        #expect(throws: Verifier.Failure.contentReadLimit) {
            try Verifier.verify(fileByteCount: UInt64(valid.count), maximumContentBytes: 1,
                readStructureRange: read, readContentRange: read, externalSpecialSlot: { _, _ in nil })
        }
        #expect(throws: Verifier.Failure.hashOperationLimit) {
            try Verifier.verify(fileByteCount: UInt64(valid.count), maximumHashOperations: 1,
                readStructureRange: read, readContentRange: read, externalSpecialSlot: { _, _ in nil })
        }
        #expect(throws: Verifier.Failure.truncatedRead) {
            try Verifier.verify(fileByteCount: UInt64(valid.count), readStructureRange: read,
                readContentRange: { _ in Data() }, externalSpecialSlot: { _, _ in nil })
        }
        let signature = try #require(Self.structure(valid).slices.first?.signature)
        let directory = try #require(signature.codeDirectories.first)
        #expect(throws: Verifier.Failure.changedDirectory) {
            try Verifier.verify(fileByteCount: UInt64(valid.count), readStructureRange: read,
                readContentRange: { range in
                    var bytes = try read(range)
                    if range.offset == signature.range.offset + directory.blobRange.offset { bytes[15] ^= 1 }
                    return bytes
                }, externalSpecialSlot: { _, _ in nil })
        }
        #expect(throws: Verifier.Failure.contentReadLimit) {
            try Self.verify(valid, materials: [1: Data(repeating: 0, count: Verifier.Limits.specialMaterialBytes + 1)])
        }
        let cancelled = Task.detached { () throws -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try Self.verify(valid); return false }
            catch is CancellationError { return true }
        }
        #expect(try await cancelled.value)
    }

    @Test("The real owned app path hashes inventory files and bounded materials without granting trust")
    func readsOwnedApplicationAndUsesBoundedMaterialIO() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = base.appendingPathComponent("Owned.app", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("_CodeSignature"), withIntermediateDirectories: true)
        defer { Self.removeOwnedFixture(base) }
        try Self.info.write(to: root.appendingPathComponent("Info.plist"))
        try Self.resources.write(to: root.appendingPathComponent("_CodeSignature/CodeResources"))
        try Self.fixture("thin2").write(to: root.appendingPathComponent("Owned"))
        let result = try await Verifier.read(unpackedApplication: root)
        let verified = try #require(result.code.first?.contentHashVerification)
        #expect(result.code.count == 1 && verified.contentDigestsVerified)
        #expect(result.contentHashBytesRead == verified.contentBytesRead)
        #expect(!result.accountIdentityEstablished && !result.replacementAuthorized)
        #expect(!verified.signatureAuthenticityVerified && !verified.resourceEnvelopeVerified)
        let infoFact = SelfRenewalMaterialInventory.FileFact(relativePath: "Info.plist", byteCount: Int64(Self.info.count))
        let material = try await Task.detached {
            try Reader.readOwnedMaterial(root: root, fact: infoFact, maximumBytes: Self.info.count)
        }.value
        #expect(material == Self.info)
        let badPath = SelfRenewalMaterialInventory.FileFact(relativePath: "../Info.plist", byteCount: 0)
        let rejected = Task.detached { () throws -> Bool in
            do { _ = try Reader.readOwnedMaterial(root: root, fact: badPath, maximumBytes: 1); return false }
            catch Reader.Failure.invalidPath { return true }
        }
        #expect(try await rejected.value)
        let changed = Data(String(decoding: Self.info, as: UTF8.self).replacingOccurrences(of: ">1.0<", with: ">2.0<").utf8)
        try changed.write(to: root.appendingPathComponent("Info.plist"))
        await #expect(throws: Verifier.Failure.specialSlotMismatch(1)) {
            try await Verifier.read(unpackedApplication: root)
        }
    }

    private static let info = Data(#"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>owned.reader</string><key>CFBundleExecutable</key><string>Owned</string><key>CFBundleShortVersionString</key><string>1.0</string><key>CFBundleVersion</key><string>1</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>"#.utf8)
    private static let resources = Data("owned raw CodeResources bytes; resource envelope intentionally unverified".utf8)
    private static var external: [UInt32: Data] { [1: info, 3: resources] }
    private static func structure(_ data: Data) throws -> Reader.ParsedFile {
        try Reader.parse(fileByteCount: UInt64(data.count)) { data.subdata(in: Int($0.offset)..<Int($0.end)) }
    }
    private static func verify(_ data: Data, materials: [UInt32: Data] = Self.external,
        contentRead: (Reader.ByteRange) -> Void = { _ in }) throws -> Verifier.VerifiedFile {
        try Verifier.verify(fileByteCount: UInt64(data.count),
            readStructureRange: { data.subdata(in: Int($0.offset)..<Int($0.end)) },
            readContentRange: { range in
                contentRead(range)
                return data.subdata(in: Int(range.offset)..<Int(range.end))
            }, externalSpecialSlot: { slot, _ in materials[slot] })
    }
    private struct Fixture {
        let limit: Int
        let prefix: String
        let signature: String
    }
    private static func fixture(_ name: String) throws -> Data {
        let fixture = try #require(fixtures[name])
        let prefix = try #require(Data(base64Encoded: fixture.prefix))
        let signature = try #require(Data(base64Encoded: fixture.signature))
        var result = Data((0..<fixture.limit).map { UInt8(($0 * 17 + 3) % 256) })
        result.replaceSubrange(0..<64, with: prefix)
        result.append(signature)
        return result
    }
    private static func fat(_ first: Data, _ second: Data) -> Data {
        var bytes = Data(repeating: 0, count: 48)
        put32(&bytes, 0, 0xcafebabe)
        put32(&bytes, 4, 2)
        for (index, slice) in [first, second].enumerated() {
            while bytes.count % 64 != 0 { bytes.append(0) }
            let entry = 8 + index * 20
            let cpu = (0..<4).reduce(UInt32(0)) { $0 | UInt32(slice[4 + $1]) << ($1 * 8) }
            put32(&bytes, entry, cpu)
            put32(&bytes, entry + 8, UInt32(bytes.count))
            put32(&bytes, entry + 12, UInt32(slice.count))
            put32(&bytes, entry + 16, 6)
            bytes.append(slice)
        }
        return bytes
    }
    private static func put32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
        for index in 0..<4 { data[offset + index] = UInt8(truncatingIfNeeded: value >> ((3 - index) * 8)) }
    }
    private static func hex(_ string: String) -> Data {
        var bytes = Data()
        var index = string.startIndex
        while index < string.endIndex {
            let end = string.index(index, offsetBy: 2)
            if let byte = UInt8(string[index..<end], radix: 16) { bytes.append(byte) }
            index = end
        }
        return bytes
    }
    private static func removeOwnedFixture(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) }
        catch { Issue.record("Owned hash fixture cleanup failed") }
    }
    private static let fixtures: [String: Fixture] = [
        "thin1": Fixture(limit: 173, prefix: "z/rt/gwAAAEAAAAAAgAAAAEAAAAQAAAAAAAAAAAAAAAdAAAAEAAAAK0AAACRAQAAAAAAAAAAAAAAAAAAAAAAAA==",
            signature: "+t4MwAAAAZEAAAAFAAAAAAAAADQAAAACAAABRwAAAAUAAAFTAAAABwAAAX8AAQAAAAABifreDAIAAAETAAICAAAAAAIAAADXAAAANAAAAAcAAAADAAAArRQBAAYAAAAAAAAAAAAAAEFvd25lZC5yZWFkZXIAT1dORURURUFNAPxNzkh+/U+tY6t4ECoVkW+IyNE0AAAAAAAAAAAAAAAAAAAAAAAAAAAO5tL3B4Yk6YNPpfbeTaoixto5BQAAAAAAAAAAAAAAAAAAAAAAAAAAsykS57RKOWxo6B5ZKP+w2FP+YUQ6dfbbBYUpFI4U3X6htHKcwJ7Jc37pfloya2bFt/yIejy84GMuq5Q9Om8oyIMkS5DyXRN5YkyCkXIJXi4GkgNCaKb5drb0qLz68mmP19IQzAvDuaQGP+KGw7YfxDCwXlv5OAQs+t4MAQAAAAwAAAAA+t5xcQAAACw8cGxpc3QgdmVyc2lvbj0iMS4wIj48ZGljdC8+PC9wbGlzdD763nFyAAAACjAA+t4LAQAAAAg="),
        "thin2": Fixture(limit: 173, prefix: "z/rt/gwAAAEAAAAAAgAAAAEAAAAQAAAAAAAAAAAAAAAdAAAAEAAAAK0AAAAJAgAAAAAAAAAAAAAAAAAAAAAAAA==",
            signature: "+t4MwAAAAgkAAAAFAAAAAAAAADQAAAACAAABvwAAAAUAAAHLAAAABwAAAfcAAQAAAAACAfreDAIAAAGLAAICAAAAAAIAAAErAAAANAAAAAcAAAADAAAArSACAAYAAAAAAAAAAAAAAEFvd25lZC5yZWFkZXIAT1dORURURUFNAF7nBHLcYKHeMbH7QaK8GOt/o++Z/kPnFOKti7Pb8rC8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAHgmCiNj9mEc5B3E3valflhwK4sTWECzJIk8+LwBdulgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAScoPlt8pMIhHrgb/4VGiZaa/Ebq7Fcz9vSVQThXJyzSYeSCQTqtlDnV4jAVKoLBSTmqAv8caoy340jemF0P5hlKjMhrLzBbc4/hNV4aVVCztQab9l+snf2wMf/v30R2Dpzk0wpovhU0yUV1VWvvQzbdEkwuYcxJ9ycHW/2T1kXz2HyzoxizW/BkzRUKgAsiT32LRl5GM3Rtmu1272Vk0QroKnQBuwe8KcpRvwitHtDF7N8XyWvX3qtpl8i32M3cn+t4MAQAAAAwAAAAA+t5xcQAAACw8cGxpc3QgdmVyc2lvbj0iMS4wIj48ZGljdC8+PC9wbGlzdD763nFyAAAACjAA+t4LAQAAAAg="),
        "thin3": Fixture(limit: 173, prefix: "z/rt/gwAAAEAAAAAAgAAAAEAAAAQAAAAAAAAAAAAAAAdAAAAEAAAAK0AAACRAQAAAAAAAAAAAAAAAAAAAAAAAA==",
            signature: "+t4MwAAAAZEAAAAFAAAAAAAAADQAAAACAAABRwAAAAUAAAFTAAAABwAAAX8AAQAAAAABifreDAIAAAETAAICAAAAAAIAAADXAAAANAAAAAcAAAADAAAArRQDAAYAAAAAAAAAAAAAAEFvd25lZC5yZWFkZXIAT1dORURURUFNAF7nBHLcYKHeMbH7QaK8GOt/o++ZAAAAAAAAAAAAAAAAAAAAAAAAAAAHgmCiNj9mEc5B3E3valflhwK4sQAAAAAAAAAAAAAAAAAAAAAAAAAAScoPlt8pMIhHrgb/4VGiZaa/EbqYeSCQTqtlDnV4jAVKoLBSTmqAv1KjMhrLzBbc4/hNV4aVVCztQab9s2T4y5D5AhU+05HHuw66uJWreZv2HyzoxizW/BkzRUKgAsiT32LRl7oKnQBuwe8KcpRvwitHtDF7N8Xy+t4MAQAAAAwAAAAA+t5xcQAAACw8cGxpc3QgdmVyc2lvbj0iMS4wIj48ZGljdC8+PC9wbGlzdD763nFyAAAACjAA+t4LAQAAAAg="),
        "thin4": Fixture(limit: 173, prefix: "z/rt/gwAAAEAAAAAAgAAAAEAAAAQAAAAAAAAAAAAAAAdAAAAEAAAAK0AAACpAgAAAAAAAAAAAAAAAAAAAAAAAA==",
            signature: "+t4MwAAAAqkAAAAFAAAAAAAAADQAAAACAAACXwAAAAUAAAJrAAAABwAAApcAAQAAAAACofreDAIAAAIrAAICAAAAAAIAAAGbAAAANAAAAAcAAAADAAAArTAEAAYAAAAAAAAAAAAAAEFvd25lZC5yZWFkZXIAT1dORURURUFNAEb1MsfRU9N0IE40HOnWH3T4h3un2QHzufJ42WVvPelRvkJvkeLCfmDSiMibRpU2agAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAONNjhShknMRgaDtnTz9yoaInri6iWl1Epk4rZfdSDqYg6/NBAS6SwZcrGdZpfT6lAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGwAHhlP60K7i7shR+ycq5p4yja7XE5AiVqMrzEBJ6S/qjRuAKmUUVgwn2XI25C5Pd+bd+eH3PD2aVKXPzCb56wHGFWHkunhCYSiYjEEgDTTHN0gjWX9OBQ6jZauzTIITfHfm7yNmLRHaovv84Fi1+R6fHPxTal6OTMIlz5cl6F9jp3dQAAuq1lUlLC7Ekmy/JA+n1kjCmiIwIEnHq9skk0nKLXuk9YFhGGqYc41PJtjS0E16o8pHHnErhq/ZsDhwj9rszMbU0Is9ZR8vM3LMejSoJ/4+VrWGZolfKeUFJNSvWc1zhYX8dH2olsjmsXVQrlroOalwEIo5BjqzUY1Xvpih8d2v7uI7aPxdVvuLEvJMXFUwjKvteiRGi0DXAv7+vreDAEAAAAMAAAAAPrecXEAAAAsPHBsaXN0IHZlcnNpb249IjEuMCI+PGRpY3QvPjwvcGxpc3Q++t5xcgAAAAowAPreCwEAAAAI"),
        "infinite": Fixture(limit: 173, prefix: "z/rt/gwAAAEAAAAAAgAAAAEAAAAQAAAAAAAAAAAAAAAdAAAAEAAAAK0AAADJAQAAAAAAAAAAAAAAAAAAAAAAAA==",
            signature: "+t4MwAAAAckAAAAFAAAAAAAAADQAAAACAAABfwAAAAUAAAGLAAAABwAAAbcAAQAAAAABwfreDAIAAAFLAAICAAAAAAIAAAErAAAANAAAAAcAAAABAAAArSACAAAAAAAAAAAAAAAAAEFvd25lZC5yZWFkZXIAT1dORURURUFNAF7nBHLcYKHeMbH7QaK8GOt/o++Z/kPnFOKti7Pb8rC8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAHgmCiNj9mEc5B3E3valflhwK4sTWECzJIk8+LwBdulgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAScoPlt8pMIhHrgb/4VGiZaa/Ebq7Fcz9vSVQThXJyzSYeSCQTqtlDnV4jAVKoLBSTmqAv8caoy340jemF0P5hlKjMhrLzBbc4/hNV4aVVCztQab9l+snf2wMf/v30R2DAPgz3dbtRnQENhhSS1UMxlZ9RiEMfe76oQAYJ9A3Cx363gwBAAAADAAAAAD63nFxAAAALDxwbGlzdCB2ZXJzaW9uPSIxLjAiPjxkaWN0Lz48L3BsaXN0PvrecXIAAAAKMAD63gsBAAAACA=="),
        "alternate": Fixture(limit: 173, prefix: "z/rt/gwAAAEAAAAAAgAAAAEAAAAQAAAAAAAAAAAAAAAdAAAAEAAAAK0AAAA8BAAAAAAAAAAAAAAAAAAAAAAAAA==",
            signature: "+t4MwAAABDwAAAAGAAAAAAAAADwAABAAAAABxwAAAAIAAAPyAAAABQAAA/4AAAAHAAAEKgABAAAAAAQ0+t4MAgAAAYsAAgIAAAAAAgAAASsAAAA0AAAABwAAAAMAAACtIAIABgAAAAAAAAAAAAAAQW93bmVkLnJlYWRlcgBPV05FRFRFQU0AXucEctxgod4xsftBorwY63+j75n+Q+cU4q2Ls9vysLwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAeCYKI2P2YRzkHcTe9qV+WHArixNYQLMkiTz4vAF26WAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABJyg+W3ykwiEeuBv/hUaJlpr8RursVzP29JVBOFcnLNJh5IJBOq2UOdXiMBUqgsFJOaoC/xxqjLfjSN6YXQ/mGUqMyGsvMFtzj+E1XhpVULO1Bpv2X6yd/bAx/+/fRHYMz8RJUC/4+CK+c0GQEDfSKlJlgyZ8NHHgS/PYipHpjuPYfLOjGLNb8GTNFQqACyJPfYtGXkYzdG2a7XbvZWTRCugqdAG7B7wpylG/CK0e0MXs3xfJa9feq2mXyLfYzdyf63gwCAAACKwACAgAAAAACAAABmwAAADQAAAAHAAAAAwAAAK0wBAAGAAAAAAAAAAAAAABBb3duZWQucmVhZGVyAE9XTkVEVEVBTQBG9TLH0VPTdCBONBzp1h90+Id7p9kB87nyeNllbz3pUb5Cb5Hiwn5g0ojIm0aVNmoAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADjTY4UoZJzEYGg7Z08/cqGiJ64uolpdRKZOK2X3Ug6mIOvzQQEuksGXKxnWaX0+pQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABsAB4ZT+tCu4u7IUfsnKuaeMo2u1xOQIlajK8xASekv6o0bgCplFFYMJ9lyNuQuT3fm3fnh9zw9mlSlz8wm+esBxhVh5Lp4QmEomIxBIA00xzdII1l/TgUOo2Wrs0yCE3x35u8jZi0R2qL7/OBYtfkenxz8U2pejkzCJc+XJehfY6d3UAALqtZVJSwuxJJsvxpx0vnq/Ovr0r7Xi80JrlOEnllKElHAgMdgq/1x2a9OcMv1rWpW8h5QGINOTUKUaA/a7MzG1NCLPWUfLzNyzHo0qCf+Pla1hmaJXynlBSTUr1nNc4WF/HR9qJbI5rF1UK5a6DmpcBCKOQY6s1GNV76YofHdr+7iO2j8XVb7ixLyTFxVMIyr7XokRotA1wL+/r63gwBAAAADAAAAAD63nFxAAAALDxwbGlzdCB2ZXJzaW9uPSIxLjAiPjxkaWN0Lz48L3BsaXN0PvrecXIAAAAKMAD63gsBAAAACA=="),
        "largePage": Fixture(limit: 131089, prefix: "z/rt/gwAAAEAAAAAAgAAAAEAAAAQAAAAAAAAAAAAAAAdAAAAEAAAABEAAgDpAQAAAAAAAAAAAAAAAAAAAAAAAA==",
            signature: "+t4MwAAAAekAAAAFAAAAAAAAADQAAAACAAABnwAAAAUAAAGrAAAABwAAAdcAAQAAAAAB4freDAIAAAFrAAICAAAAAAIAAAErAAAANAAAAAcAAAACAAIAESACABEAAAAAAAAAAAAAAEFvd25lZC5yZWFkZXIAT1dORURURUFNAF7nBHLcYKHeMbH7QaK8GOt/o++Z/kPnFOKti7Pb8rC8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAHgmCiNj9mEc5B3E3valflhwK4sTWECzJIk8+LwBdulgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAScoPlt8pMIhHrgb/4VGiZaa/Ebq7Fcz9vSVQThXJyzSYeSCQTqtlDnV4jAVKoLBSTmqAv8caoy340jemF0P5hlKjMhrLzBbc4/hNV4aVVCztQab9l+snf2wMf/v30R2DOFwSKZmzz4Q/fbZk2M4j6OLqr2y7pr/KGi3rTb9wx4NkgxMilBZU+aSfgs9gUV7hXmY6oWDij+YWd8vLlauEZPreDAEAAAAMAAAAAPrecXEAAAAsPHBsaXN0IHZlcnNpb249IjEuMCI+PGRpY3QvPjwvcGxpc3Q++t5xcgAAAAowAPreCwEAAAAI"),
        "secondCPU": Fixture(limit: 173, prefix: "z/rt/gcAAAEAAAAAAgAAAAEAAAAQAAAAAAAAAAAAAAAdAAAAEAAAAK0AAACpAgAAAAAAAAAAAAAAAAAAAAAAAA==",
            signature: "+t4MwAAAAqkAAAAFAAAAAAAAADQAAAACAAACXwAAAAUAAAJrAAAABwAAApcAAQAAAAACofreDAIAAAIrAAICAAAAAAIAAAGbAAAANAAAAAcAAAADAAAArTAEAAYAAAAAAAAAAAAAAEFvd25lZC5yZWFkZXIAT1dORURURUFNAEb1MsfRU9N0IE40HOnWH3T4h3un2QHzufJ42WVvPelRvkJvkeLCfmDSiMibRpU2agAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAONNjhShknMRgaDtnTz9yoaInri6iWl1Epk4rZfdSDqYg6/NBAS6SwZcrGdZpfT6lAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGwAHhlP60K7i7shR+ycq5p4yja7XE5AiVqMrzEBJ6S/qjRuAKmUUVgwn2XI25C5Pd+bd+eH3PD2aVKXPzCb56wHGFWHkunhCYSiYjEEgDTTHN0gjWX9OBQ6jZauzTIITfHfm7yNmLRHaovv84Fi1+R6fHPxTal6OTMIlz5cl6F9jp3dQAAuq1lUlLC7Ekmy/OtXQf6Elm+4g1GVQH9pQ3vq/25P258COoU0iVedCL/ExCYGvj8XaoCpSyF4k67C6T9rszMbU0Is9ZR8vM3LMejSoJ/4+VrWGZolfKeUFJNSvWc1zhYX8dH2olsjmsXVQrlroOalwEIo5BjqzUY1Xvpih8d2v7uI7aPxdVvuLEvJMXFUwjKvteiRGi0DXAv7+vreDAEAAAAMAAAAAPrecXEAAAAsPHBsaXN0IHZlcnNpb249IjEuMCI+PGRpY3QvPjwvcGxpc3Q++t5xcgAAAAowAPreCwEAAAAI"),
        "bare": Fixture(limit: 173, prefix: "z/rt/gwAAAEAAAAAAgAAAAEAAAAQAAAAAAAAAAAAAAAdAAAAEAAAAK0AAADPAAAAAAAAAAAAAAAAAAAAAAAAAA==",
            signature: "+t4MwAAAAM8AAAACAAAAAAAAABwAAQAAAAAAx/reDAIAAACrAAICAAAAAAIAAABLAAAANAAAAAAAAAADAAAArSACAAYAAAAAAAAAAAAAAEFvd25lZC5yZWFkZXIAT1dORURURUFNACoj0GYyFNtZ2oLyp5lAk82UmWnfFAPbyromKBRlh4eu9h8s6MYs1vwZM0VCoALIk99i0ZeRjN0bZrtdu9lZNEK6Cp0AbsHvCnKUb8IrR7QxezfF8lr196raZfIt9jN3J/reCwEAAAAI"),
        "unsupportedSpecial": Fixture(limit: 173, prefix: "z/rt/gwAAAEAAAAAAgAAAAEAAAAQAAAAAAAAAAAAAAAdAAAAEAAAAK0AAACpAgAAAAAAAAAAAAAAAAAAAAAAAA==",
            signature: "+t4MwAAAAqkAAAAFAAAAAAAAADQAAAACAAACXwAAAAUAAAJrAAAABwAAApcAAQAAAAACofreDAIAAAIrAAICAAAAAAIAAAHLAAAANAAAAAwAAAADAAAArSACAAYAAAAAAAAAAAAAAEFvd25lZC5yZWFkZXIAT1dORURURUFNAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABe5wRy3GCh3jGx+0GivBjrf6Pvmf5D5xTirYuz2/KwvAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB4JgojY/ZhHOQdxN72pX5YcCuLE1hAsySJPPi8AXbpYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEnKD5bfKTCIR64G/+FRomWmvxG6uxXM/b0lUE4Vycs0mHkgkE6rZQ51eIwFSqCwUk5qgL/HGqMt+NI3phdD+YZSozIay8wW3OP4TVeGlVQs7UGm/ZfrJ39sDH/799Edg3OPT53zfgKPYPx6Yo8h1QsUddAi4jqdq57Zf/a9ejTg9h8s6MYs1vwZM0VCoALIk99i0ZeRjN0bZrtdu9lZNEK6Cp0AbsHvCnKUb8IrR7QxezfF8lr196raZfIt9jN3J/reDAEAAAAMAAAAAPrecXEAAAAsPHBsaXN0IHZlcnNpb249IjEuMCI+PGRpY3QvPjwvcGxpc3Q++t5xcgAAAAowAPreCwEAAAAI"),
    ]
}
