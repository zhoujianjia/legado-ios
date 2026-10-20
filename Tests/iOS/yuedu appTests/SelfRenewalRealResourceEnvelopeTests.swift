import CryptoKit
import Foundation
import Testing
@testable import yuedu_app

@Suite("Java-sized resource envelope preserves complete digest verification")
struct SelfRenewalRealResourceEnvelopeTests {
    @Test("a real Foundation XML envelope above two MiB verifies every resource and rejects one changed digest")
    func verifiesJavaSizedXMLAndRejectsChangedClassDigest() async throws {
        try await Task.detached {
            typealias Verifier = SelfRenewalResourceSealVerifier
            typealias Inventory = SelfRenewalMaterialInventory
            let sha1 = Data(Insecure.SHA1.hash(data: Data()))
            let sha256 = Data(SHA256.hash(data: Data()))
            let paths = (0..<17_241).map {
                "LegadoRuntime/java-home/modules/java.base/java/lang/" + String(repeating: "N", count: 50) + "/C\($0).class"
            }
            let files = paths.map { Inventory.FileFact(relativePath: $0, byteCount: 0) }
            let legacy = Dictionary(uniqueKeysWithValues: paths.map { ($0, sha1) })
            let modern = Dictionary(uniqueKeysWithValues: paths.map { ($0, ["hash2": sha256]) })
            let envelope: [String: Any] = ["files": legacy, "files2": modern,
                "rules": ["^.*": true], "rules2": ["^.*": true]]
            let bytes = try PropertyListSerialization.data(fromPropertyList: envelope, format: .xml, options: 0)
            #expect(bytes.count > 2_097_152 && bytes.count <= Verifier.Limits.envelopeBytes)
            var calls = 0
            let value = try Verifier.verifyEnvelope(bytes, files: files, directories: [],
                executablePath: nil, hashTypes: [2]) { _, types in
                    calls += 1
                    #expect(types == [2])
                    return [2: sha256]
                }
            #expect(value.hashedFiles == paths.count && calls == paths.count)
            #expect(value.resourceEnvelopeVerified)
            #expect(value.verifiedFileDigests.count == paths.count)
            #expect(throws: Verifier.Failure.digestMismatch(paths[0])) {
                try Verifier.verifyEnvelope(bytes, files: files, directories: [], executablePath: nil, hashTypes: [2]) { fact, _ in
                    [2: fact.relativePath == paths[0] ? Data(repeating: 1, count: 32) : sha256]
                }
            }
        }.value
    }
}
