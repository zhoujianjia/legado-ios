import Foundation
import Testing
@testable import yuedu_app

@Suite("CodeResources actual owned resources and Apple rule semantics")
struct SelfRenewalResourceSealVerifierTests {
    private typealias Verifier = SelfRenewalResourceSealVerifier
    private typealias Inventory = SelfRenewalMaterialInventory

    @Test("Four algorithms stream independent abc, empty and multi-chunk vectors")
    func hashesIndependentVectorsWithBoundedChunks() throws {
        for (name, bytes) in [("abc", Data("abc".utf8)), ("empty", Data()), ("large", Self.large)] {
            var ranges: [SelfRenewalMachOSignatureReader.ByteRange] = []
            let hashes = try Verifier.hashFile(byteCount: Int64(bytes.count), hashTypes: [1, 2, 3, 4]) { range in
                ranges.append(range)
                return bytes.subdata(in: Int(range.offset)..<Int(range.end))
            }
            let expected = try #require(SelfRenewalResourceFixture.vectors[name])
            for (type, hex) in expected { #expect(hashes[type] == Self.hex(hex)) }
            #expect(ranges.allSatisfy { $0.byteCount <= 65_536 })
            if name == "empty" { #expect(ranges.isEmpty) }
            if name == "large" { #expect(ranges.map(\.byteCount) == [65_536, 65_536, 5]) }
        }
        let data = try Self.envelope(files: ["a": Self.hashes("abc")], rules: ["^.*": true])
        #expect(try Self.verify(data, content: ["a": Data("abc".utf8)], types: [1, 2, 3, 4]).hashedFiles == 1)
    }

    @Test("Version two selects files2/rules2; legacy data and legacy fallback stay distinct")
    func selectsEnvelopeVersionAndLegacyHashFallback() throws {
        let abc = Self.hex(SelfRenewalResourceFixture.vectors["abc"]![1]!)
        let legacy = try Self.envelope(files: ["a": abc], rules: ["^.*": true], version: 1)
        let old = try Self.verify(legacy, content: ["a": Data("abc".utf8)], types: [1])
        #expect(old.version == 1 && old.hashedFiles == 1)
        var values = try #require(PropertyListSerialization.propertyList(from: legacy, format: nil) as? [String: Any])
        values["files2"] = ["b": ["hash": Self.hex(SelfRenewalResourceFixture.vectors["abc"]![2]!)]]
        values["rules2"] = ["^.*": true]
        let modern = try Self.verify(Self.plist(values), content: ["b": Data("abc".utf8)], types: [2])
        #expect(modern.version == 2 && modern.hashedFiles == 1 && modern.hasExactCatchAll)
        #expect(throws: Verifier.Failure.invalidDigest("a")) {
            try Self.verify(legacy, content: ["a": Data("abc".utf8)], types: [2])
        }
    }

    @Test("POSIX character classes and numeric weights select actual file rules")
    func appliesPOSIXWeightedRules() throws {
        let data = try Self.envelope(files: ["Resources/keep12.txt": Self.hashes("abc")], rules: [
            "^.*": true,
            "[[:digit:]]": ["omit": true, "weight": 20],
            "keep[[:digit:]]": ["weight": 30],
        ])
        let result = try Self.verify(data, content: ["Resources/12.txt": Data("ignored".utf8), "Resources/keep12.txt": Data("abc".utf8)])
        #expect(result.hashedFiles == 1 && result.omittedFiles == 1)
        #expect(result.resourceEnvelopeVerified && !result.strictResourcePolicyVerified)
    }

    @Test("Optional seals allow absence; present files must match and rule optional does not excuse a missing seal")
    func preservesOptionalSealSemantics() throws {
        var optional = Self.hashes("abc")
        optional["optional"] = true
        let data = try Self.envelope(files: ["a": optional], rules: ["^.*": true])
        #expect(try Self.verify(data, content: [:]).absentOptionalFiles == 1)
        #expect(try Self.verify(data, content: ["a": Data("abc".utf8)]).hashedFiles == 1)
        #expect(throws: Verifier.Failure.digestMismatch("a")) { try Self.verify(data, content: ["a": Data("abd".utf8)]) }
        let ruleOptional = try Self.envelope(files: ["a": Self.hashes("abc")], rules: ["^.*": ["optional": true]])
        #expect(throws: Verifier.Failure.missingResource("a")) { try Self.verify(ruleOptional, content: [:]) }
    }

    @Test("Changed, added, missing and wrong file types cannot pass as matching resources")
    func rejectsChangedAddedMissingAndWrongTypes() throws {
        let data = try Self.envelope(files: ["a": Self.hashes("abc")], rules: ["^.*": true])
        #expect(throws: Verifier.Failure.digestMismatch("a")) { try Self.verify(data, content: ["a": Data("abd".utf8)]) }
        #expect(throws: Verifier.Failure.addedResource("extra")) {
            try Self.verify(data, content: ["a": Data("abc".utf8), "extra": Data()])
        }
        #expect(throws: Verifier.Failure.missingResource("a")) { try Self.verify(data, content: [:]) }
        let link = try Self.envelope(files: ["a": ["symlink": "other"]], rules: ["^.*": true])
        #expect(throws: Verifier.Failure.resourceTypeMismatch("a")) { try Self.verify(link, content: ["a": Data()]) }
        let omittedButSealed = try Self.envelope(files: ["a": Self.hashes("abc")], rules: ["^.*": false])
        #expect(throws: Verifier.Failure.missingResource("a")) { try Self.verify(omittedButSealed, content: ["a": Data("abc".utf8)]) }
    }

    @Test("Nested dotted directories stop descent; ordinary directory omission does not")
    func traversesNestedAndOmittedDirectoriesWithoutTrustClaims() throws {
        let data = try Self.envelope(files: [
            "PlugIns/Owned.appex": ["requirement": "identifier owned.reader.child", "cdhash": Data(repeating: 1, count: 20)],
            "Data/a": Self.hashes("abc"), "Plain/a": Self.hashes("abc"),
        ], rules: ["^.*": true,
            "^PlugIns/.*": ["nested": true, "weight": 10],
            "^Plain$": ["nested": true, "weight": 10],
            "^Data$": ["omit": true, "weight": 10]])
        let result = try Self.verify(data, content: [
            "PlugIns/Owned.appex/anything": Data("sealed by child".utf8),
            "Data/a": Data("abc".utf8), "Plain/a": Data("abc".utf8),
        ], directories: ["PlugIns", "PlugIns/Owned.appex", "Data", "Plain"])
        #expect(result.hashedFiles == 2)
        #expect(result.unresolvedNestedResources.map(\.relativePath) == ["PlugIns/Owned.appex"])
        #expect(result.resourceDigestsVerified && !result.resourceEnvelopeVerified)
        let reserved = try Self.envelope(files: [:], rules: ["^.*": true])
        let excluded = try Self.verify(reserved, content: [
            "Owned": Data(), "_CodeSignature/CodeResources": Data(), "_MASReceipt/receipt": Data(), "CodeResources": Data(),
        ], executable: "Owned")
        #expect(excluded.hashedFiles == 0 && excluded.resourceEnvelopeVerified)
        let infoIsResource = try Self.envelope(files: ["Info.plist": Self.hashes("abc")], rules: ["^.*": true])
        #expect(try Self.verify(infoIsResource, content: ["Info.plist": Data("abc".utf8)]).hashedFiles == 1)
    }

    @Test("Malformed paths, regexes, weights, digests and hard limits fail explicitly")
    func rejectsMalformedEnvelopeAndLimits() throws {
        #expect(throws: Verifier.Failure.malformedEnvelope) { try Self.verify(Data([0xff]), content: [:]) }
        for path in ["../a", "/a", "a//b", "a/./b", "a\u{0}b"] {
            let data = try Self.envelope(files: [path: Self.hashes("abc")], rules: ["^.*": true])
            #expect(throws: Verifier.Failure.invalidPath) { try Self.verify(data, content: [:]) }
        }
        let invalidRegex = try Self.envelope(files: [:], rules: ["[": true])
        #expect(throws: Verifier.Failure.invalidRule) { try Self.verify(invalidRegex, content: [:]) }
        for weight in [NSNumber(value: -1), NSNumber(value: 0.5), NSNumber(value: true)] {
            let data = try Self.envelope(files: [:], rules: ["^.*": ["weight": weight]])
            #expect(throws: Verifier.Failure.invalidRule) { try Self.verify(data, content: [:]) }
        }
        let badDigest = try Self.envelope(files: ["a": ["hash2": "text", "hash": Data(repeating: 0, count: 32)]], rules: ["^.*": true])
        #expect(throws: Verifier.Failure.invalidDigest("a")) { try Self.verify(badDigest, content: ["a": Data()]) }
        #expect(throws: Verifier.Failure.envelopeLimit) {
            try Self.verify(Data(repeating: 0, count: Verifier.Limits.envelopeBytes + 1), content: [:])
        }
        let tooMany = Dictionary(uniqueKeysWithValues: (0...Verifier.Limits.rules).map { ("^\($0)$", true) })
        #expect(throws: Verifier.Failure.ruleLimit) { try Self.verify(Self.envelope(files: [:], rules: tooMany), content: [:]) }
    }

    @Test("Real app uses content-hash proof, actual CodeResources and streamed regular files")
    func verifiesOwnedApplicationAndRejectsResourceChanges() async throws {
        try await Self.withFixture { root in
            let result = try await Verifier.read(unpackedApplication: root)
            let component = try #require(result.components.first)
            #expect(result.components.count == 1 && component.boundCodeDirectories == 1)
            #expect(component.resources.hashedFiles == 3 && component.resources.hashedBytes == 131_080)
            #expect(component.resources.omittedFiles == 1)
            #expect(result.resourceEnvelopesVerified && !result.appleSigningAuthorityVerified && !result.replacementAuthorized)
            #expect(result.executableMaterials.inventory.files.contains { $0.relativePath == "empty.dat" && $0.byteCount == 0 })
            #expect(result.executableMaterials.inventory.directories.contains("Resources"))
            try Data("abd".utf8).write(to: root.appendingPathComponent("chapter.txt"))
            await #expect(throws: Verifier.Failure.digestMismatch("chapter.txt")) { try await Verifier.read(unpackedApplication: root) }
            try Data("abc".utf8).write(to: root.appendingPathComponent("chapter.txt"))
            try Data().write(to: root.appendingPathComponent("extra"))
            await #expect(throws: Verifier.Failure.addedResource("extra")) { try await Verifier.read(unpackedApplication: root) }
            try FileManager.default.removeItem(at: root.appendingPathComponent("extra"))
            try FileManager.default.removeItem(at: root.appendingPathComponent("empty.dat"))
            await #expect(throws: Verifier.Failure.missingResource("empty.dat")) { try await Verifier.read(unpackedApplication: root) }
        }
    }

    @Test("Re-reading the envelope and directories binds their exact bytes to the genuine earlier proof")
    func rejectsEnvelopeOrCodeDirectoryChangedAfterHashPass() async throws {
        try await Self.withFixture { root in
            let materials = try await SelfRenewalCodeDirectoryHashVerifier.read(unpackedApplication: root)
            var envelope = try #require(Data(base64Encoded: SelfRenewalResourceFixture.envelopeBase64))
            envelope[envelope.count - 2] ^= 1
            try envelope.write(to: root.appendingPathComponent("_CodeSignature/CodeResources"))
            await #expect(throws: Verifier.Failure.digestMismatch("_CodeSignature/CodeResources")) {
                try await Verifier.verify(unpackedApplication: root, executableMaterials: materials)
            }
            try #require(Data(base64Encoded: SelfRenewalResourceFixture.envelopeBase64)).write(to: root.appendingPathComponent("_CodeSignature/CodeResources"))
            var code = try #require(Data(base64Encoded: SelfRenewalResourceFixture.machOBase64))
            code[173 + 28 + 13] ^= 1
            try code.write(to: root.appendingPathComponent("Owned"))
            await #expect(throws: Verifier.Failure.changedCodeDirectory) {
                try await Verifier.verify(unpackedApplication: root, executableMaterials: materials)
            }
        }
    }

    @Test("Short reads and cancellation never publish a resource result")
    func rejectsShortReadsAndCancellation() async throws {
        #expect(throws: SelfRenewalMachOSignatureReader.Failure.truncatedRead) {
            try Verifier.hashFile(byteCount: 3, hashTypes: [2], read: { _ in Data() })
        }
        let task = Task.detached { () throws -> Void in
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try Self.verify(Self.envelope(files: [:], rules: ["^.*": true]), content: [:])
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    private static var large: Data { Data((0..<131_077).map { UInt8(($0 * 13 + 7) % 256) }) }
    private static func hashes(_ name: String) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: SelfRenewalResourceFixture.vectors[name]!.map { type, hex in
            (type == 1 ? "hash" : "hash\(type)", Self.hex(hex) as Any)
        })
    }
    private static func plist(_ values: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
    }
    private static func envelope(files: [String: Any], rules: [String: Any], version: Int = 2) throws -> Data {
        if version == 1 { return try plist(["files": files, "rules": rules]) }
        return try plist(["files": [:] as [String: Any], "rules": [:] as [String: Any], "files2": files, "rules2": rules])
    }
    private static func verify(_ data: Data, content: [String: Data], directories: [String] = [],
        executable: String? = nil, types: [UInt8] = [2]) throws -> Verifier.EnvelopeVerification {
        let facts = content.map { Inventory.FileFact(relativePath: $0.key, byteCount: Int64($0.value.count)) }
        return try Verifier.verifyEnvelope(data, files: facts, directories: directories,
            executablePath: executable, hashTypes: types) { fact, algorithms in
            let bytes = try #require(content[fact.relativePath])
            return try Verifier.hashFile(byteCount: fact.byteCount, hashTypes: algorithms) { range in
                bytes.subdata(in: Int(range.offset)..<Int(range.end))
            }
        }
    }
    private static func hex(_ string: String) -> Data {
        var data = Data()
        for offset in stride(from: 0, to: string.utf8.count, by: 2) {
            let start = string.index(string.startIndex, offsetBy: offset)
            let end = string.index(start, offsetBy: 2)
            if let byte = UInt8(string[start..<end], radix: 16) { data.append(byte) }
        }
        return data
    }
    private static func withFixture(_ action: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("resource-owned-" + UUID().uuidString)
        let root = directory.appendingPathComponent("Owned.app")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("_CodeSignature"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("Owned resource fixture cleanup failed") }
        }
        for (name, encoded) in [("Info.plist", SelfRenewalResourceFixture.infoBase64),
                                ("Owned", SelfRenewalResourceFixture.machOBase64),
                                ("_CodeSignature/CodeResources", SelfRenewalResourceFixture.envelopeBase64)] {
            try #require(Data(base64Encoded: encoded)).write(to: root.appendingPathComponent(name))
        }
        try Data("abc".utf8).write(to: root.appendingPathComponent("chapter.txt"))
        try Data().write(to: root.appendingPathComponent("empty.dat"))
        try large.write(to: root.appendingPathComponent("Resources/large.dat"))
        try await action(root)
    }
}
