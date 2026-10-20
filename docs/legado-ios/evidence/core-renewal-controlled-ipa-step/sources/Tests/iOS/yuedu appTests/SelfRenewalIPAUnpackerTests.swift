import Foundation
import Testing
@testable import yuedu_app

@Suite("Controlled IPA snapshot, bounded ZIP and sealed application materials", .serialized)
struct SelfRenewalIPAUnpackerTests {
    private typealias Unpacker = SelfRenewalIPAUnpacker
    private typealias Validator = SelfRenewalIPAArchiveValidator
    private typealias Fixture = SelfRenewalIPAArchiveFixture
    private typealias Trust = SelfRenewalCMSFixture

    @Test("stored owned IPA traverses the actual existing whole-application verifier")
    func verifiesOwnedStoredIPAThroughSealedMaterials() async throws {
        try await Self.worker {
            let bytes = try Fixture.archive(Fixture.ownedMembers())
            try await Self.withFile(bytes) { url, _ in
                let material = try await Self.verify(url)
                #expect(material.entryCount == 15)
                #expect(material.archiveBytes == bytes.count)
                #expect(material.application.bundles.count == 3)
                #expect(material.applicationPath == "Payload/Owned.app")
                #expect(material.application.profileAndCodeIdentityConsistencyVerified)
                #expect(!material.appleSigningAuthorityEstablished && !material.accountIdentityEstablished)
                #expect(!material.deviceEligibilityEstablished && !material.replacementAuthorized)
            }
        }
    }

    @Test("deflate and signed or unsigned descriptors use the same pinned archive source")
    func verifiesDeflateAndBothDataDescriptorForms() async throws {
        try await Self.worker {
            for descriptor in [true, false] {
                let bytes = try Fixture.archive(Fixture.ownedMembers(method: 8, descriptor: descriptor))
                try await Self.withFile(bytes) { url, _ in
                    let material = try await Self.verify(url)
                    #expect(material.application.bundles.count == 3)
                    #expect(material.entryCount == 15 && !material.replacementAuthorized)
                }
            }
        }
    }

    @Test("traversal absolute alternate separator and normalized collision paths are rejected")
    func rejectsTraversalAndAmbiguousPaths() async throws {
        try await Self.worker {
            for path in ["/Payload/Owned.app/a", "Payload/Owned.app/../a", "Payload//Owned.app/a",
                         "Payload/Owned.app/a\\b", "Payload/Owned.app/C:a", "Payload/Owned.app/a\u{0}b",
                         "Payload/Owned.app/a.", "Payload/Owned.app/a "] {
                let bytes = try Fixture.archive([.init(path: path, bytes: Data())])
                try Self.reject(Validator.Failure.unsafePath) { _ = try Self.inspect(bytes) }
            }
            for paths in [["Payload/Owned.app/A", "Payload/Owned.app/a"],
                          ["Payload/Owned.app/\u{e9}", "Payload/Owned.app/e\u{301}"],
                          ["Payload/Owned.app/parent", "Payload/Owned.app/parent/child"]] {
                let bytes = try Fixture.archive(paths.map { .init(path: $0, bytes: Data()) })
                try Self.reject(Validator.Failure.duplicatePath) { _ = try Self.inspect(bytes) }
            }
        }
    }

    @Test("links special files duplicate entries unknown encodings and extra path overrides fail closed")
    func rejectsLinksTypesDuplicatesAndEncodingOverrides() async throws {
        try await Self.worker {
            for attributes in [UInt32(0o120777 << 16), 0o010644 << 16, 0o060644 << 16, 0x10] {
                let bytes = try Fixture.archive([.init(path: "Payload/Owned.app/a", bytes: Data(), attributes: attributes)])
                try Self.reject(Validator.Failure.unsupportedFileType) { _ = try Self.inspect(bytes) }
            }
            let duplicate = Fixture.Member(path: "Payload/Owned.app/a", bytes: Data())
            try Self.reject(Validator.Failure.duplicatePath) { _ = try Self.inspect(Fixture.archive([duplicate, duplicate])) }
            let encoding = Fixture.Member(path: "Payload/Owned.app/\u{e9}", bytes: Data(), flags: 0)
            try Self.reject(Validator.Failure.unsupportedEncoding) { _ = try Self.inspect(Fixture.archive([encoding])) }
            for identifier in [UInt16(0x0001), 0x7075, 0x000d, 0x9901] {
                var extra = Data(); Fixture.u16(identifier, to: &extra); Fixture.u16(0, to: &extra)
                let member = Fixture.Member(path: "Payload/Owned.app/a", bytes: Data(), extra: extra)
                try Self.reject(Validator.Failure.unsupportedZIPFeature) { _ = try Self.inspect(Fixture.archive([member])) }
            }
        }
    }

    @Test("EOCD central local and descriptor disagreements cannot reach extraction")
    func rejectsHeaderLayoutAndDescriptorDisagreements() async throws {
        try await Self.worker {
            let original = try Fixture.archive([.init(path: "Payload/Owned.app/a", bytes: Data("abc".utf8))])
            var changed = original; changed.append(0)
            try Self.reject(Validator.Failure.malformedZIP) { _ = try Self.inspect(changed) }
            changed = original; Fixture.set16(2, at: changed.count - 22 + 8, in: &changed)
            try Self.reject(Validator.Failure.unsupportedZIPFeature) { _ = try Self.inspect(changed) }
            changed = original; changed[30] = UInt8(ascii: "X")
            try Self.reject(Validator.Failure.inconsistentLocalHeader) { _ = try Self.inspect(changed) }
            changed = original; Fixture.set16(0x0801, at: 6, in: &changed)
            try Self.reject(Validator.Failure.inconsistentLocalHeader) { _ = try Self.inspect(changed) }
            let descriptor = try Fixture.archive([.init(path: "Payload/Owned.app/a", bytes: Data("abc".utf8), descriptor: true)])
            let plan = try Self.inspect(descriptor)
            changed = descriptor; changed[plan.entries[0].dataOffset + 3 + 4] ^= 1
            try Self.reject(Validator.Failure.invalidDescriptor) { _ = try Self.inspect(changed) }
            var extraRoot = try Fixture.archive([.init(path: "Payload/Other.app/a", bytes: Data()), .init(path: "Payload/Owned.app/a", bytes: Data())])
            try Self.reject(Validator.Failure.invalidPayload) { _ = try Self.inspect(extraRoot) }
            extraRoot = try Fixture.archive([.init(path: "outside/a", bytes: Data())])
            try Self.reject(Validator.Failure.invalidPayload) { _ = try Self.inspect(extraRoot) }
        }
    }

    @Test("archive entry compressed expanded and ratio limits reject hostile declarations")
    func enforcesCompressedExpandedAndEntryBudgets() async throws {
        try await Self.worker {
            struct Oversized: SelfRenewalIPAArchiveBytes {
                let byteCount = Validator.Limits.archiveBytes + 1
                func read(at offset: Int, count: Int) throws -> Data { Issue.record("Oversized input was read"); return Data() }
            }
            try Self.reject(Validator.Failure.archiveLimit) { _ = try Validator.inspect(Oversized()) }
            var bytes = try Fixture.archive([.init(path: "Payload/Owned.app/a", bytes: Data())])
            Fixture.set16(8_193, at: bytes.count - 22 + 8, in: &bytes)
            Fixture.set16(8_193, at: bytes.count - 22 + 10, in: &bytes)
            try Self.reject(Validator.Failure.entryLimit) { _ = try Self.inspect(bytes) }
            let oversized = Fixture.Member(path: "Payload/Owned.app/a", bytes: Data(), method: 8,
                compressed: Data([3, 0]), expandedSize: UInt32(Validator.Limits.expandedEntryBytes + 1))
            try Self.reject(Validator.Failure.expandedLimit) { _ = try Self.inspect(Fixture.archive([oversized])) }
            let ratio = Fixture.Member(path: "Payload/Owned.app/a", bytes: Data(), method: 8,
                compressed: Data([3, 0]), expandedSize: 1_000_000)
            try Self.reject(Validator.Failure.compressionRatioLimit) { _ = try Self.inspect(Fixture.archive([ratio])) }
            bytes = try Fixture.archive([.init(path: "Payload/Owned.app/a", bytes: Data(), method: 8)])
            let end = bytes.count - 22
            let central = Int(UInt32(bytes[end + 16]) | UInt32(bytes[end + 17]) << 8
                | UInt32(bytes[end + 18]) << 16 | UInt32(bytes[end + 19]) << 24)
            Fixture.set32(UInt32(Validator.Limits.compressedEntryBytes + 1), at: central + 20, in: &bytes)
            try Self.reject(Validator.Failure.expandedLimit) { _ = try Self.inspect(bytes) }
            let placeholder = Data(repeating: 0, count: 1_048_576)
            let total = (0..<5).map { index in Fixture.Member(path: "Payload/Owned.app/\(index)", bytes: Data(),
                method: 8, compressed: placeholder, expandedSize: UInt32(Validator.Limits.expandedEntryBytes)) }
            try Self.reject(Validator.Failure.expandedLimit) { _ = try Self.inspect(Fixture.archive(total)) }
            let directories = (0..<128).map { index in Fixture.Member(path: "Payload/Owned.app/d\(index)/a", bytes: Data()) }
            try Self.reject(Validator.Failure.directoryLimit) { _ = try Self.inspect(Fixture.archive(directories)) }
        }
    }

    @Test("actual CRC size deflate termination trailing data and truncation are checked before output")
    func rejectsCRCDeflateTailTruncationAndActualExpansion() async throws {
        try await Self.worker {
            let plain = Data("owned compressed data".utf8)
            let compressed = try Fixture.deflated(plain)
            let cases: [(Fixture.Member, Unpacker.Failure)] = [
                (.init(path: "Payload/Owned.app/a", bytes: plain, checksum: 1), .crcMismatch("Payload/Owned.app/a")),
                (.init(path: "Payload/Owned.app/a", bytes: plain, method: 8, compressed: compressed + Data([0])), .malformedCompression("Payload/Owned.app/a")),
                (.init(path: "Payload/Owned.app/a", bytes: plain, method: 8, compressed: Data(compressed.dropLast())), .malformedCompression("Payload/Owned.app/a")),
                (.init(path: "Payload/Owned.app/a", bytes: plain, method: 8, expandedSize: 1), .actualSizeMismatch("Payload/Owned.app/a"))
            ]
            for (member, error) in cases {
                let bytes = try Fixture.archive([member])
                let source = Fixture.Bytes(data: bytes)
                let plan = try Validator.inspect(source)
                try Self.reject(error) { try Unpacker.validatePayloads(source, plan: plan) }
            }
        }
    }

    @Test("source leaf symlinks hardlinks and caller cancellation never grant archive ownership")
    func rejectsSourceLinksAndPropagatesCancellation() async throws {
        try await Self.worker {
            let bytes = try Fixture.archive([.init(path: "Payload/Owned.app/a", bytes: Data())])
            try await Self.withFile(bytes) { url, root in
                let symlink = root.appendingPathComponent("owned-link.ipa")
                try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: url)
                do { _ = try await Self.verify(symlink); Issue.record("Source symlink was accepted") }
                catch let error as Unpacker.Failure { #expect(error == .invalidInput) }
                let hardlink = root.appendingPathComponent("owned-hardlink.ipa")
                try FileManager.default.linkItem(at: url, to: hardlink)
                do { _ = try await Self.verify(hardlink); Issue.record("Source hardlink was accepted") }
                catch let error as Unpacker.Failure { #expect(error == .invalidInput) }
                let cancelled = Task.detached {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return try await Self.verify(url)
                }
                do { _ = try await cancelled.value; Issue.record("Cancellation was lost") }
                catch is CancellationError {}
            }
        }
    }

    @Test("failure cleans only the new owned staging directory and retains source and unrelated bytes")
    func cleansOwnedStagingOnArchiveAndMaterialFailure() async throws {
        try await Self.worker {
            for bytes in [Data(repeating: 0, count: 22), try Fixture.archive([.init(path: "Payload/Owned.app/a", bytes: Data())])] {
                try await Self.withFile(bytes) { url, root in
                    let unrelated = root.appendingPathComponent("keep-existing.txt")
                    let sentinel = Data("owned unrelated sentinel".utf8)
                    try sentinel.write(to: unrelated)
                    let before = try Self.stagingNames()
                    do { _ = try await Self.verify(url); Issue.record("Invalid material was accepted") }
                    catch is Validator.Failure {}
                    catch is SelfRenewalMaterialInventory.Failure {}
                    catch is SelfRenewalSignedCodeVerifier.Failure {}
                    let after = try Self.stagingNames()
                    #expect(before == after)
                    let kept = try Data(contentsOf: unrelated)
                    let input = try Data(contentsOf: url)
                    #expect(kept == sentinel && input == bytes)
                }
            }
        }
    }

    nonisolated private static func worker(_ action: @escaping @Sendable () async throws -> Void) async throws {
        try await Task.detached { try await action() }.value
    }
    nonisolated private static func inspect(_ bytes: Data) throws -> Validator.Plan { try Validator.inspect(Fixture.Bytes(data: bytes)) }
    nonisolated private static func verify(_ url: URL) async throws -> Unpacker.Materials {
        try await Unpacker.verify(ipa: url, codeAnchors: [Trust.rootCertificate], profileAnchors: [Trust.rootCertificate], at: Trust.validationDate)
    }
    nonisolated private static func reject<E: Error & Equatable>(_ expected: E, _ action: () throws -> Void) throws {
        do { try action(); Issue.record("Expected \(expected)") }
        catch let error as E { #expect(error == expected) }
    }
    nonisolated private static func stagingNames() throws -> Set<String> {
        // Names only, in CI's temp directory. Cleanup never acts on this list.
        Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("renewal-owned-ipa-") })
    }
    nonisolated private static func withFile(_ bytes: Data, action: @Sendable (URL, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ipa-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let file = root.appendingPathComponent("owned.ipa")
        try bytes.write(to: file, options: .withoutOverwriting)
        try await action(file, root)
    }
}
