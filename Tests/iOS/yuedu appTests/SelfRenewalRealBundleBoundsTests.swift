import Darwin
import Foundation
import Testing
@testable import yuedu_app

@Suite("Actual exploded Java-home cardinality, bounded FDs and stored ZIP output", .serialized)
struct SelfRenewalRealBundleBoundsTests {
    typealias Unpacker = SelfRenewalIPAUnpacker
    typealias Validator = SelfRenewalIPAArchiveValidator
    typealias Inventory = SelfRenewalMaterialInventory

    @Test("the shipped Java header is a resource while unknown CAFEBABE and real fat candidates remain visible")
    func distinguishesShippedJavaClassHeaderWithoutFilenameBypass() async throws {
        try await Self.worker {
            try await Self.withApplication { root in
                let java = Data([0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 72])
                for index in 0..<160 {
                    try java.write(to: root.appendingPathComponent("class-\(index).class"))
                }
                // Filename alone grants nothing. A supported fat count still
                // enters the native verifier even when named as a Java class.
                try Data([0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 1]).write(to: root.appendingPathComponent("native.class"))
                try Data([0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 71]).write(to: root.appendingPathComponent("unknown.class"))
                let value = try await Inventory.read(unpackedApplication: root)
                #expect(value.codeFiles.map(\.file.relativePath) == ["Owned", "native.class", "unknown.class"])
                #expect(value.files.count == 164)
                #expect(!value.cryptographicVerificationPerformed && !value.replacementAuthorized)
            }
        }
    }

    @Test("the actual shipped Java-home name count fits the one existing inventory")
    func inventoriesSeventeenThousandClassResourcesWithinHardBounds() async throws {
        try await Self.worker {
            try await Self.withApplication { root in
                let resources = root.appendingPathComponent("LegadoRuntime/java-home")
                try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
                let java = Data([0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 72])
                for index in 0..<17_241 {
                    if index % 256 == 0 { try Task.checkCancellation() }
                    try java.write(to: resources.appendingPathComponent("C\(index).class"))
                }
                let value = try await Inventory.read(unpackedApplication: root)
                #expect(value.files.count == 17_243)
                #expect(value.codeFiles.count == 1)
                #expect(value.entriesVisited <= Inventory.Limits.entries)
                #expect(value.bytesRead <= Inventory.Limits.totalReadBytes)
            }
        }
    }

    @Test("615 sibling directories retain only a fixed number of open directory descriptors")
    func reopensOwnedDirectoriesWithoutHoldingOneDescriptorPerDirectory() async throws {
        try await Self.worker {
            let before = Self.openDescriptors()
            try Self.withTree { tree in
                for index in 0..<615 {
                    let descriptor = try tree.file("Payload/Owned.app/java-home/d\(index)/resource")
                    try Unpacker.OwnedTree.write(Data([1, 2, 3]), to: descriptor)
                    #expect(Darwin.close(descriptor) == 0)
                }
                let during = Self.openDescriptors()
                #expect(during <= before + Validator.Limits.directoryDescriptors)
                try tree.validateNames()
                try tree.replace("Payload/Owned.app/java-home/d614/resource", bytes: Data([4, 5]))
                try tree.validateNames()
            }
            #expect(Self.openDescriptors() <= before + Validator.Limits.directoryDescriptors)
        }
    }

    @Test("a rebound directory or symlink cannot redirect checked reads or cleanup to replacement bytes")
    func rejectsReboundDirectoryAndPreservesUnrelatedReplacementBytes() async throws {
        try await Self.worker {
            for symlink in [false, true] {
                let tree = try Unpacker.OwnedTree()
                let outside = FileManager.default.temporaryDirectory.appendingPathComponent("renewal-bounds-fixture-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
                defer {
                    do { try FileManager.default.removeItem(at: outside) } catch { Issue.record(error) }
                    if FileManager.default.fileExists(atPath: tree.url.path) {
                        do { try FileManager.default.removeItem(at: tree.url) } catch { Issue.record(error) }
                    }
                }
                let descriptor = try tree.file("child/owned")
                try Unpacker.OwnedTree.write(Data([7]), to: descriptor)
                #expect(Darwin.close(descriptor) == 0)
                let child = tree.url.appendingPathComponent("child")
                try FileManager.default.moveItem(at: child, to: outside.appendingPathComponent("original"))
                let replacement = symlink ? outside.appendingPathComponent("replacement") : child
                try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
                let sentinel = Data("unrelated replacement".utf8)
                try sentinel.write(to: replacement.appendingPathComponent("owned"))
                if symlink { try FileManager.default.createSymbolicLink(at: child, withDestinationURL: replacement) }
                #expect(throws: Unpacker.Failure.stagingChanged) { try tree.boundFile("child/owned", maximumBytes: 100) }
                #expect(throws: Unpacker.Failure.cleanupFailed) { try tree.cleanup() }
                #expect(try Data(contentsOf: replacement.appendingPathComponent("owned")) == sentinel)
                #expect(try Data(contentsOf: outside.appendingPathComponent("original/owned")) == Data([7]))
            }
        }
    }

    @Test("one stored writer emits exact local offsets, CRC and central metadata for a Java-sized archive")
    func streamsStoredArchiveOnceAndUsesExactMetadataBudget() async throws {
        try await Self.worker {
            try Self.withTree { tree in
                let paths = (0..<17_241).map { "Payload/Owned.app/java-home/C\($0).class" }
                let bytes = Data([0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 72])
                let writer = try Unpacker.StoredArchiveWriter(tree: tree, name: "actual.ipa", paths: paths,
                    expandedBytes: paths.count * bytes.count, date: SelfRenewalCMSFixture.validationDate)
                var calls = 0
                for path in paths {
                    try writer.append(path: path, directory: false, byteCount: bytes.count) { offset, count in
                        calls += 1
                        #expect(offset == 0 && count == bytes.count)
                        return bytes
                    }
                }
                try writer.finish()
                let raw = try Data(contentsOf: tree.url.appendingPathComponent("actual.ipa"))
                let expected = 22 + paths.reduce(0) { $0 + 76 + 2 * $1.utf8.count + bytes.count }
                #expect(raw.count == expected && calls == paths.count)
                let source = SelfRenewalIPAArchiveFixture.Bytes(data: raw)
                let plan = try Validator.inspect(source)
                #expect(plan.entries.count == paths.count)
                #expect(plan.expandedBytes == paths.count * bytes.count)
                try Unpacker.validatePayloads(source, plan: plan)
            }
        }
    }

    @Test("a truncated provider cannot finalize a package or escape the owned staging cleanup")
    func rejectsTruncatedStoredProviderAndCleansStaging() async throws {
        try await Self.worker {
            try Self.withTree { tree in
                let writer = try Unpacker.StoredArchiveWriter(tree: tree, name: "bad.ipa",
                    paths: ["Payload/Owned.app/resource"], expandedBytes: 3,
                    date: SelfRenewalCMSFixture.validationDate)
                #expect(throws: Unpacker.Failure.actualSizeMismatch("Payload/Owned.app/resource")) {
                    try writer.append(path: "Payload/Owned.app/resource", directory: false, byteCount: 3) { _, _ in Data([1]) }
                }
                #expect(throws: Unpacker.Failure.readBudget) { try writer.finish() }
            }
        }
    }

    nonisolated private static func openDescriptors() -> Int {
        (0..<4_096).reduce(0) { count, descriptor in count + (Darwin.fcntl(Int32(descriptor), F_GETFD) >= 0 ? 1 : 0) }
    }
    nonisolated private static func withTree(_ operation: (Unpacker.OwnedTree) throws -> Void) throws {
        let tree = try Unpacker.OwnedTree()
        do { try operation(tree); try tree.cleanup() }
        catch {
            do { try tree.cleanup() } catch { Issue.record(error) }
            throw error
        }
    }
    nonisolated private static func withApplication(_ operation: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("renewal-bounds-" + UUID().uuidString + ".app")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let info = ["CFBundleIdentifier": "owned.reader", "CFBundleExecutable": "Owned",
            "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: root.appendingPathComponent("Info.plist"))
        try Data([0xcf, 0xfa, 0xed, 0xfe, 0, 0, 0, 0]).write(to: root.appendingPathComponent("Owned"))
        try await operation(root)
    }
    nonisolated private static func worker(_ action: @escaping @Sendable () async throws -> Void) async throws {
        try await Task.detached { try await action() }.value
    }
}
