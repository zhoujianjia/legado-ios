import Foundation
import Testing
@testable import yuedu_app

@Suite("Self-renewal unpacked material observations, owned fixtures only")
struct SelfRenewalMaterialInventoryTests {
    private typealias Reader = SelfRenewalMaterialInventory
    private static let mainIdentifier = "owned.reader"

    @Test("XML and binary metadata parsing stays bounded and treats metadata as untrusted")
    func parsesBoundedMetadataAndRejectsDamagedOrUnsafeValues() throws {
        let values = Self.info(identifier: Self.mainIdentifier, executable: "Owned Reader")
        for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
            let bytes = try PropertyListSerialization.data(fromPropertyList: values, format: format, options: 0)
            let parsed = try Reader.parseInfoPlist(bytes)
            #expect(parsed.bundleIdentifier == Self.mainIdentifier)
            #expect(parsed.executableName == "Owned Reader")
            #expect(parsed.version == "1.0")
            #expect(parsed.build == "12")
            #expect(parsed.extensionPointIdentifier == nil)
        }
        #expect(throws: Reader.Failure.malformedInfoPlist) {
            try Reader.parseInfoPlist(Data([0xFF, 0x00, 0xFF]))
        }
        #expect(throws: Reader.Failure.plistSizeLimit) {
            try Reader.parseInfoPlist(Data(repeating: 0, count: Reader.Limits.plistBytes + 1))
        }
        for (key, value) in [("CFBundleExecutable", "../outside"), ("CFBundleExecutable", "folder\\outside"),
                             ("CFBundleIdentifier", "owned..reader"), ("CFBundleVersion", String(repeating: "1", count: 65))] {
            var changed = values
            changed[key] = value
            let bytes = try PropertyListSerialization.data(fromPropertyList: changed, format: .binary, options: 0)
            #expect(throws: Reader.Failure.invalidInfoMetadata) { try Reader.parseInfoPlist(bytes) }
        }
    }

    @Test("A real owned three-bundle tree records exact mappings and presence without authorizing replacement")
    func readsThreeBundleFactsWithoutTrustAssertion() async throws {
        try await Self.withFixture { root in
            try Self.makeExpectedTree(root)
            let observed = try await Reader.read(unpackedApplication: root)
            #expect(observed.verification == .unverified)
            #expect(!observed.cryptographicVerificationPerformed)
            #expect(!observed.accountIdentityEstablished)
            #expect(!observed.replacementAuthorized)
            #expect(observed.issues.isEmpty)
            #expect(observed.components.count == 3)
            #expect(observed.codeFiles.count == 3)
            #expect(observed.files.filter { $0.relativePath.hasSuffix("Info.plist") }.count == 3)
            #expect(observed.files.allSatisfy { $0.byteCount >= 0 })
            #expect(observed.directories.contains("PlugIns/W.appex/_CodeSignature"))
            #expect(observed.bytesRead < Reader.Limits.totalReadBytes)
            let app = try #require(observed.components.first { $0.role == .application })
            #expect(app.relativePath == ".")
            #expect(app.parentBundleIdentifier == nil)
            #expect(app.metadata?.bundleIdentifier == Self.mainIdentifier)
            #expect(app.executable?.header == .thin64)
            #expect(app.embeddedProvisioningProfile?.byteCount == 19)
            #expect(app.codeResources?.byteCount == 12)
            for (role, identifier) in [(Reader.Role.widgetExtension, "owned.reader.widget"), (.shareExtension, "owned.reader.share")] {
                let component = try #require(observed.components.first { $0.role == role })
                #expect(component.parentBundleIdentifier == Self.mainIdentifier)
                #expect(component.metadata?.bundleIdentifier == identifier)
                #expect(component.metadata?.version == "1.0")
                #expect(component.metadata?.build == "12")
            }
        }
    }

    @Test("Unknown extensions, framework containers and unnamed Mach-O files remain visible")
    func retainsAdditionalPotentialSignedComponents() async throws {
        try await Self.withFixture { root in
            try Self.makeExpectedTree(root)
            try Self.writeComponent(root, path: "PlugIns/Other.appex", identifier: "owned.reader.other",
                point: "owned.unknown-extension")
            try Self.writeComponent(root, path: "Frameworks/Owned.framework", identifier: "owned.framework", package: "FMWK")
            let helper = root.appendingPathComponent("Resources/unnamed-helper")
            try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0xCA, 0xFE, 0xBA, 0xBF, 1, 2, 3]).write(to: helper)
            try Data([1, 2, 3, 4]).write(to: root.appendingPathComponent("Resources/damaged.dylib"))
            let observed = try await Reader.read(unpackedApplication: root)
            #expect(observed.components.count == 5)
            #expect(observed.issues.contains(.unexpectedComponent("PlugIns/Other.appex")))
            #expect(observed.issues.contains(.unexpectedComponent("Frameworks/Owned.framework")))
            #expect(observed.codeFiles.contains { $0.file.relativePath == "Resources/unnamed-helper" && $0.header == .fat64 })
            #expect(observed.codeFiles.contains { $0.file.relativePath == "Resources/damaged.dylib" && $0.header == nil })
            #expect(observed.verification == .unverified)
        }
    }

    @Test("Damaged, duplicate and misplaced extension roles cannot disappear from the inventory")
    func reportsIncompleteAndConflictingRoleStructure() async throws {
        try await Self.withFixture { root in
            try Self.makeExpectedTree(root)
            try FileManager.default.removeItem(at: root.appendingPathComponent("PlugIns/S.appex/Info.plist"))
            try Data("damaged fixture".utf8).write(to: root.appendingPathComponent("PlugIns/S.appex/Info.plist"))
            try Self.writeComponent(root, path: "Elsewhere/Second.appex", identifier: "unrelated.widget",
                point: "com.apple.widgetkit-extension")
            let observed = try await Reader.read(unpackedApplication: root)
            #expect(observed.components.count == 4)
            #expect(observed.issues.contains(.missingOrInvalidInfo("PlugIns/S.appex")))
            #expect(observed.issues.contains(.unexpectedComponent("PlugIns/S.appex")))
            #expect(observed.issues.contains(.missingRole(.shareExtension)))
            #expect(observed.issues.contains(.duplicateRole(.widgetExtension)))
            #expect(observed.issues.contains(.invalidRoleLocation("Elsewhere/Second.appex")))
            #expect(observed.issues.contains(.invalidParentIdentifier("Elsewhere/Second.appex")))
        }
    }

    @Test("Root and descendant links, including profile hardlinks, are rejected without following them")
    func rejectsLinkedMaterials() async throws {
        try await Self.withFixture { root in
            try Self.makeExpectedTree(root)
            let alias = root.deletingLastPathComponent().appendingPathComponent("Alias.app")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
            await Self.expectFailure(.linkNotAllowed, at: alias)
            let link = root.appendingPathComponent("Resources")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.deletingLastPathComponent())
            await Self.expectFailure(.linkNotAllowed, at: root)
            try FileManager.default.removeItem(at: link)
            let profile = root.appendingPathComponent("embedded.mobileprovision")
            let extra = root.appendingPathComponent("linked.mobileprovision")
            try FileManager.default.linkItem(at: profile, to: extra)
            await Self.expectFailure(.linkNotAllowed, at: root)
        }
    }

    @Test("Missing main material, oversized plists, depth and component limits fail closed")
    func enforcesDirectoryAndByteLimits() async throws {
        try await Self.withFixture { root in
            await Self.expectFailure(.missingApplicationInfo, at: root)
            try Data(repeating: 0, count: Reader.Limits.plistBytes + 1).write(to: root.appendingPathComponent("Info.plist"))
            await Self.expectFailure(.plistSizeLimit, at: root)
            try Self.makeExpectedTree(root)
            var deep = root
            for _ in 0...Reader.Limits.depth { deep.appendPathComponent("d") }
            try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
            await Self.expectFailure(.depthLimit, at: root)
            try FileManager.default.removeItem(at: root.appendingPathComponent("d"))
            for index in 0..<Reader.Limits.components {
                try FileManager.default.createDirectory(at: root.appendingPathComponent("Extra\(index).appex"), withIntermediateDirectories: true)
            }
            await Self.expectFailure(.componentLimit, at: root)
        }
    }

    private static func info(identifier: String, executable: String = "Owned Reader", package: String = "APPL", point: String? = nil) -> [String: Any] {
        var values: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": executable,
            "CFBundleShortVersionString": "1.0", "CFBundleVersion": "12", "CFBundlePackageType": package]
        if let point { values["NSExtension"] = ["NSExtensionPointIdentifier": point] }
        return values
    }

    private static func makeExpectedTree(_ root: URL) throws {
        try writeComponent(root, path: ".", identifier: mainIdentifier)
        try writeComponent(root, path: "PlugIns/W.appex", identifier: "owned.reader.widget", point: "com.apple.widgetkit-extension")
        try writeComponent(root, path: "PlugIns/S.appex", identifier: "owned.reader.share", point: "com.apple.share-services")
    }

    private static func writeComponent(_ root: URL, path: String, identifier: String, package: String? = nil, point: String? = nil) throws {
        let component = path == "." ? root : root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: component.appendingPathComponent("_CodeSignature"), withIntermediateDirectories: true)
        let values = info(identifier: identifier, package: package ?? (point == nil ? "APPL" : "XPC!"), point: point)
        let bytes = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        try bytes.write(to: component.appendingPathComponent("Info.plist"))
        // A recognizable header is deliberately insufficient to be valid code.
        try Data([0xCF, 0xFA, 0xED, 0xFE, 0, 0, 0, 0]).write(to: component.appendingPathComponent("Owned Reader"))
        try Data("owned profile blob!".utf8).write(to: component.appendingPathComponent("embedded.mobileprovision"))
        try Data("owned seal!!".utf8).write(to: component.appendingPathComponent("_CodeSignature/CodeResources"))
    }

    private static func expectFailure(_ expected: Reader.Failure, at root: URL) async {
        do {
            _ = try await Reader.read(unpackedApplication: root)
            Issue.record("Owned fixture unexpectedly produced a material inventory")
        } catch let failure as Reader.Failure {
            #expect(failure == expected)
        } catch {
            Issue.record("Owned fixture produced an unexpected error type")
        }
    }

    private static func withFixture(_ body: @escaping @Sendable (URL) async throws -> Void) async throws {
        let worker = Task.detached {
            let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("OwnedRenewalInventory-" + UUID().uuidString)
            let root = parent.appendingPathComponent("Owned.app")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer {
                do { try FileManager.default.removeItem(at: parent) }
                catch { Issue.record("Owned material fixture cleanup failed") }
            }
            try await body(root)
        }
        try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
