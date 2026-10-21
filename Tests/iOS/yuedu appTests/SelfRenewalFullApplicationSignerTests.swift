import CryptoKit
import Foundation
import Testing
@testable import yuedu_app

/// A required same-job real iPhoneOS build is input DATA to the Simulator
/// signing test. The packaged device executable/JVM is never run as Simulator
/// code, and no platform, permission or trust check is disabled.
@Suite("Complete current-source iPhoneOS JVM package through the production signing owners", .serialized)
struct SelfRenewalFullApplicationSignerTests {
    typealias Vault = SelfRenewalSigningMaterialVault
    typealias Unpacker = SelfRenewalIPAUnpacker
    typealias PKI = SelfRenewalSigningOwnedPKIFixture

    @Test("real main Widget Share framework JVM JAR and Java resources survive controlled re-signing and independent archive verification")
    func signsFullCurrentIPhoneOSJVMApplicationThroughSameProductionOwners() async throws {
        let worker = Task.detached(priority: .utility) {
            precondition(!Thread.isMainThread)
            let input = try FullApplicationSigningInput.load()
            let started = SourcePerfTrace.now
            defer { SourcePerfTrace.record("renewal.package.full-application-test",
                "bytes=\(input.metadata.archiveBytes) main=\(Thread.isMainThread)", since: started, thresholdMs: 0) }
            let date = Date(timeIntervalSince1970: TimeInterval(input.metadata.verificationEpochSeconds))
            let baseline = try await Unpacker.withOwnedApplication(ipa: input.archive,
                codeAnchors: [input.metadata.anchor], profileAnchors: [input.metadata.anchor], at: date) { scope in
                try #require(scope.originalArchiveBytes == input.metadata.archiveBytes)
                try #require(scope.originalArchiveSHA256 == (try FullApplicationSigningInput.hash(input.metadata.archiveSHA256)))
                return (scope.original, try await FullApplicationSigningInput.verifyPackage(scope, metadata: input.metadata))
            }
            let original = baseline.0
            let inventory = original.resources.executableMaterials.inventory
            let runtime = baseline.1.filter { FullApplicationSigningInput.isRuntimeResource($0.key) }
            let classes = runtime.keys.filter { $0.hasPrefix("lib/modules/") && $0.hasSuffix(".class") }
            // This app may statically link all frameworks. Preserve exactly the
            // real components; never insert a synthetic fourth Mach-O.
            var allowedChanges = Set<String>()
            for component in inventory.components {
                let executable = try #require(component.executable)
                let resources = try #require(component.codeResources)
                allowedChanges.formUnion([executable.file.relativePath, resources.relativePath])
                if let profile = component.embeddedProvisioningProfile { allowedChanges.insert(profile.relativePath) }
            }

            let issuer = try PKI.issuer(at: date)
            let vault = Vault(codeAnchors: issuer.certificateChainDER, profileAnchors: issuer.certificateChainDER, clock: { date })
            let namespace = try await vault.create(identity: original)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("full-application-signing-" + UUID().uuidString)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let generation = try await vault.generation(in: namespace)
                let key = try await vault.generateKey(in: namespace, expectedGeneration: generation)
                let leaf = try PKI.certificate(for: key.privateKey, signedBy: issuer, at: date)
                let profiles = try original.bundles.map { bundle -> Vault.ProfileInput in
                    let prior = try #require(original.profiles.profiles.first { $0.file.relativePath == bundle.profileRelativePath })
                    return .init(componentRelativePath: bundle.componentRelativePath,
                        bytes: try PKI.profile(from: prior, developerCertificate: leaf, issuer: issuer, at: date))
                }
                let lease = try await vault.publish(in: namespace, keyID: key.id, expectedGeneration: key.generation,
                    certificateChainDER: [leaf] + issuer.certificateChainDER, profiles: profiles)
                // This is the same actual production signer and one Vault;
                // unsupported real layouts/bounds remain a failing test.
                let result = try await SelfRenewalControlledPackageSigner.resign(ipa: input.archive, vault: vault, lease: lease,
                    originalCodeAnchors: [input.metadata.anchor], originalProfileAnchors: [input.metadata.anchor])
                #expect(result.originalArchiveSHA256 == (try FullApplicationSigningInput.hash(input.metadata.archiveSHA256)))
                #expect(result.originalArchiveBytes == input.metadata.archiveBytes)
                #expect(result.changes.count == inventory.components.count && result.signed.bundles.count == 3)
                #expect(Set(result.changes.map(\.relativePath)) == Set(input.metadata.componentPaths))
                #expect(result.signed.resources.resourceEnvelopesVerified)
                #expect(!result.appleSigningAuthorityEstablished && !result.accountIdentityEstablished)
                #expect(!result.deviceEligibilityEstablished && !result.replacementAuthorized)
                for before in original.bundles {
                    let after = try #require(result.signed.bundles.first { $0.componentRelativePath == before.componentRelativePath })
                    #expect(before.bundleIdentifier == after.bundleIdentifier)
                    #expect(before.slices.map(\.appGroups) == after.slices.map(\.appGroups))
                    #expect(before.slices.map(\.keychainAccessGroups) == after.slices.map(\.keychainAccessGroups))
                }
                let output = directory.appendingPathComponent("independently-read-full.ipa")
                guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
                let handle = try FileHandle(forWritingTo: output)
                do {
                    var offset = 0
                    var digest = SHA256()
                    while offset < result.archive.byteCount {
                        try Task.checkCancellation()
                        let count = min(SelfRenewalIPAArchiveValidator.Limits.chunkBytes, result.archive.byteCount - offset)
                        let bytes = try await result.archive.read(at: offset, count: count)
                        guard bytes.count == count else { throw CocoaError(.fileReadCorruptFile) }
                        try handle.write(contentsOf: bytes); digest.update(data: bytes); offset += bytes.count
                    }
                    try #require(Data(digest.finalize()) == result.archive.sha256)
                    try handle.synchronize(); try handle.close()
                } catch { do { try handle.close() } catch { Issue.record(error) }; throw error }
                let independentlyRead = try await Unpacker.withOwnedApplication(ipa: output,
                    codeAnchors: issuer.certificateChainDER, profileAnchors: issuer.certificateChainDER, at: date) { scope in
                    try #require(scope.originalArchiveSHA256 == result.archive.sha256 && scope.originalArchiveBytes == result.archive.byteCount)
                    try #require(scope.original == result.signed)
                    return try await FullApplicationSigningInput.verifyPackage(scope, metadata: input.metadata)
                }
                // Every real JDK class, JAR, license and runtime resource is
                // checked from the independently reopened replacement bytes.
                #expect(independentlyRead.filter { FullApplicationSigningInput.isRuntimeResource($0.key) } == runtime)
                #expect(Set(independentlyRead.keys) == Set(baseline.1.keys))
                for (path, hash) in baseline.1 where !allowedChanges.contains(path) {
                    #expect(independentlyRead[path] == hash, "Unrelated signed-package file changed: \(path)")
                }
                print("YUEDU_FULL_APPLICATION_SIGNING source=\(input.metadata.sourceCommit) inputBytes=\(input.metadata.archiveBytes) outputBytes=\(result.archive.byteCount) classes=\(classes.count) components=\(inventory.components.count) runtimeFiles=\(runtime.count) independentlyVerified=true")
            } catch {
                do { try await FullApplicationSigningInput.cleanup(vault: vault, namespace: namespace, directory: directory) }
                catch { Issue.record(error) }
                throw error
            }
            try await FullApplicationSigningInput.cleanup(vault: vault, namespace: namespace, directory: directory)
        }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}

private struct FullApplicationSigningInput: Sendable {
    struct Jar: Decodable, Sendable { let path: String; let bytes: Int; let sha256: String }
    struct PublicFileFact: Decodable, Sendable { let bytes: Int; let sha256: String }
    struct Metadata: Decodable, Sendable {
        let schema: Int; let kind: String; let sourceCommit: String
        let archiveFile: String; let archiveBytes: Int; let archiveSHA256: String
        let anchor: Data; let verificationEpochSeconds: Int64
        let ordinaryJar: Jar; let realJavaClassResourceCount: Int
        let componentPaths: [String]; let bundlePaths: [String]
        let originalBuildManifest: PublicFileFact; let sameJobNativeReuse: PublicFileFact
        let allUnrelatedDeviceBuildFilesPreserved: Bool
        let privateMaterialArtifacts: Int; let realAppleAccountUsed: Bool
        let controlledOriginalSigningOnly: Bool; let realDeviceExecution: Bool
    }
    let archive: URL; let metadata: Metadata
    nonisolated static func load() throws -> Self {
        precondition(!Thread.isMainThread)
        let started = SourcePerfTrace.now
        var metadataBytes = 0
        defer { SourcePerfTrace.record("renewal.package.full-input",
            "bytes=\(metadataBytes) main=\(Thread.isMainThread)", since: started, thresholdMs: 0) }
        let bundle = Bundle(for: FullApplicationSigningResourceBundle.self)
        guard let url = bundle.url(forResource: "full-sdk-owned-package", withExtension: "json"),
              let archive = bundle.url(forResource: "full-sdk-owned-package", withExtension: "ipa") else { throw CocoaError(.fileNoSuchFile) }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 1_048_576 else { throw CocoaError(.fileReadTooLarge) }
        let raw = try Data(contentsOf: url)
        metadataBytes = raw.count
        guard raw.count == size.intValue, raw.count <= 1_048_576 else { throw CocoaError(.fileReadTooLarge) }
        let metadata = try JSONDecoder().decode(Metadata.self, from: raw)
        let archiveAttributes = try FileManager.default.attributesOfItem(atPath: archive.path)
        guard metadata.schema == 1, metadata.kind == "full-current-source-iphoneos-jvm-application",
              metadata.sourceCommit.utf8.count == 40, metadata.archiveFile == "full-sdk-owned-package.ipa",
              metadata.archiveBytes > 0, metadata.archiveBytes <= SelfRenewalIPAArchiveValidator.Limits.archiveBytes,
              archiveAttributes[.type] as? FileAttributeType == .typeRegular,
              (archiveAttributes[.size] as? NSNumber)?.intValue == metadata.archiveBytes,
              !metadata.anchor.isEmpty, metadata.anchor.count <= 65_536,
              metadata.ordinaryJar.path == "LegadoRuntime/legado-runtime.jar", metadata.ordinaryJar.bytes > 0,
              metadata.realJavaClassResourceCount > 10_000,
              metadata.verificationEpochSeconds >= 315_532_800, metadata.verificationEpochSeconds < 4_354_819_200,
              Set(metadata.bundlePaths) == Set([".", "PlugIns/yuedu_app_Widget.appex", "PlugIns/yuedu_app_ShareExtension.appex"]),
              metadata.bundlePaths.count == 3, (3...19).contains(metadata.componentPaths.count),
              Set(metadata.componentPaths).count == metadata.componentPaths.count,
              metadata.componentPaths.allSatisfy({ validComponent($0) }),
              Set(metadata.bundlePaths).isSubset(of: Set(metadata.componentPaths)),
              metadata.originalBuildManifest.bytes > 0, metadata.sameJobNativeReuse.bytes > 0,
              metadata.allUnrelatedDeviceBuildFilesPreserved, metadata.privateMaterialArtifacts == 0,
              !metadata.realAppleAccountUsed, metadata.controlledOriginalSigningOnly, !metadata.realDeviceExecution else { throw CocoaError(.coderInvalidValue) }
        _ = try hash(metadata.sourceCommit + String(repeating: "0", count: 24))
        _ = try hash(metadata.archiveSHA256); _ = try hash(metadata.ordinaryJar.sha256)
        _ = try hash(metadata.originalBuildManifest.sha256); _ = try hash(metadata.sameJobNativeReuse.sha256)
        // Both sides are real same-job products. A syntactically valid hash in
        // an old resource does not bind it to this Simulator test's checkout.
        guard Bundle.main.object(forInfoDictionaryKey: "YueduExperienceSourceCommit") as? String == metadata.sourceCommit,
              Bundle.main.object(forInfoDictionaryKey: "GitCommitSHA") as? String == String(metadata.sourceCommit.prefix(7)) else { throw CocoaError(.coderInvalidValue) }
        return Self(archive: archive, metadata: metadata)
    }
    nonisolated static func hash(_ hex: String) throws -> Data {
        guard hex.utf8.count == 64, hex.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw CocoaError(.coderInvalidValue) }
        let bytes = Array(hex.utf8)
        return Data(stride(from: 0, to: 64, by: 2).map { index in
            let value: (UInt8) -> UInt8 = { $0 <= 57 ? $0 - 48 : $0 - 87 }
            return value(bytes[index]) << 4 | value(bytes[index + 1])
        })
    }
    nonisolated static func validComponent(_ path: String) -> Bool {
        if path == "." { return true }
        return !path.isEmpty && path.utf8.count <= 1_024 && !path.hasPrefix("/") && !path.contains("\\") &&
            !path.utf8.contains(0) && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    nonisolated static func isRuntimeResource(_ path: String) -> Bool {
        path.hasPrefix("LegadoRuntime/") || path.hasPrefix("lib/")
    }
    nonisolated static func verifyPackage(_ scope: SelfRenewalIPAUnpacker.OwnedApplication,
        metadata: Metadata) async throws -> [String: Data] {
        precondition(!Thread.isMainThread)
        let original = scope.original
        let inventory = original.resources.executableMaterials.inventory
        let started = SourcePerfTrace.now
        defer { SourcePerfTrace.record("renewal.package.full-owned-verify",
            "files=\(inventory.files.count) bytes=\(inventory.declaredFileBytes) main=\(Thread.isMainThread)",
            since: started, thresholdMs: 0) }
        try #require(original.resources.resourceEnvelopesVerified)
        try #require(original.bundles.count == 3 && Set(original.bundles.map(\.componentRelativePath)) == Set(metadata.bundlePaths))
        try #require(inventory.components.count == metadata.componentPaths.count && Set(inventory.components.map(\.relativePath)) == Set(metadata.componentPaths))
        for component in inventory.components {
            try Task.checkCancellation()
            let facts = try #require(component.metadata)
            let executable = try #require(component.executable)
            let infoPath = component.relativePath == "." ? "Info.plist" : component.relativePath + "/Info.plist"
            let infoBytes = try await scope.read(infoPath, maximumBytes: SelfRenewalMaterialInventory.Limits.plistBytes)
            let info = try #require(try PropertyListSerialization.propertyList(from: infoBytes, options: [], format: nil) as? [String: Any])
            try #require(info["CFBundleIdentifier"] as? String == facts.bundleIdentifier)
            try #require(info["CFBundleExecutable"] as? String == facts.executableName)
            if metadata.bundlePaths.contains(component.relativePath) {
                try #require(info["CFBundleSupportedPlatforms"] as? [String] == ["iPhoneOS"])
                try #require(info["YueduExperienceSourceCommit"] as? String == metadata.sourceCommit)
                try #require(info["GitCommitSHA"] as? String == String(metadata.sourceCommit.prefix(7)))
            } else {
                try #require(component.kind == .framework && info["CFBundlePackageType"] as? String == "FMWK")
            }
            let code = try #require(original.resources.executableMaterials.code.first { $0.file == executable.file })
            try #require(code.structure.slices.count == 1 && code.structure.slices[0].cpuType == 0x0100000c && code.structure.slices[0].is64Bit)
            try #require(code.signedCodeVerification?.allLoadedDirectoriesAuthenticated == true)
            let bytes = try await scope.read(executable.file.relativePath, maximumBytes: SelfRenewalControlledMachOSigner.Limits.fileBytes)
            try requireDevicePlatform(bytes)
        }
        let hashes = try await scope.hashes()
        let classes = hashes.keys.filter { $0.hasPrefix("lib/modules/") && $0.hasSuffix(".class") }
        try #require(classes.count == metadata.realJavaClassResourceCount && classes.count > 10_000)
        try #require(!hashes.keys.contains { $0.hasPrefix("LegadoRuntime/java-home/") })
        try #require(hashes[metadata.ordinaryJar.path] == (try hash(metadata.ordinaryJar.sha256)))
        try #require(inventory.files.first { $0.relativePath == metadata.ordinaryJar.path }?.byteCount == Int64(metadata.ordinaryJar.bytes))
        try #require(hashes.keys.contains { $0.hasPrefix("LegadoRuntime/Notices/") })
        let manifest = try await scope.read("LegadoRuntime/runtime-manifest.json", maximumBytes: 1_048_576)
        let staging = try #require(try JSONSerialization.jsonObject(with: manifest) as? [String: Any])
        try #require(staging["jarSHA256"] as? String == metadata.ordinaryJar.sha256)
        // Class bytes are actual resources, not empty placeholder entries.
        for path in ["lib/modules/java.base/java/lang/Object.class", "lib/modules/java.base/java/lang/String.class"] {
            let bytes = try await scope.read(path, maximumBytes: 1_048_576)
            try #require(bytes.count >= 8 && bytes.prefix(4) == Data([0xca, 0xfe, 0xba, 0xbe]))
        }
        return hashes
    }
    /// Only characterizes the real native load-command bytes. No platform flag
    /// is patched and a Simulator object with an iPhoneOS plist still fails.
    nonisolated static func requireDevicePlatform(_ bytes: Data) throws {
        func word(_ offset: Int) throws -> UInt32 {
            guard offset >= 0, offset <= bytes.count - 4 else { throw CocoaError(.coderInvalidValue) }
            return (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
        }
        guard bytes.count >= 32, try word(0) == 0xfeedfacf, try word(4) == 0x0100000c else { throw CocoaError(.coderInvalidValue) }
        let count = Int(try word(16)), size = Int(try word(20))
        guard count > 0, count <= 16_384, size >= 8, size <= 1_048_576, size <= bytes.count - 32 else { throw CocoaError(.coderInvalidValue) }
        var cursor = 32, platforms: [UInt32] = []
        for _ in 0..<count {
            guard cursor <= 32 + size - 8 else { throw CocoaError(.coderInvalidValue) }
            let command = try word(cursor), length = Int(try word(cursor + 4))
            guard length >= 8, length % 8 == 0, length <= 32 + size - cursor else { throw CocoaError(.coderInvalidValue) }
            if command == 0x32 {
                guard length >= 24 else { throw CocoaError(.coderInvalidValue) }
                platforms.append(try word(cursor + 8))
            }
            cursor += length
        }
        guard cursor == 32 + size, platforms == [2] else { throw CocoaError(.coderInvalidValue) }
    }
    /// Cleanup runs with an uncancelled task so cancellation cannot bypass the
    /// real Vault's generation/destroy checks and leave its permanent test key.
    nonisolated static func cleanup(vault: SelfRenewalSigningMaterialVault,
        namespace: SelfRenewalSigningMaterialVault.Namespace, directory: URL) async throws {
        try await Task.detached(priority: .utility) {
            let started = SourcePerfTrace.now
            defer { SourcePerfTrace.record("renewal.package.full-owned-cleanup",
                "directories=1 main=\(Thread.isMainThread)", since: started, thresholdMs: 0) }
            var failure: Error?
            do { let current = try await vault.generation(in: namespace); try await vault.destroy(namespace, expectedGeneration: current) }
            catch { failure = error }
            do { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) } }
            catch { if failure == nil { failure = error } else { Issue.record(error) } }
            if let failure { throw failure }
        }.value
    }
}
private final class FullApplicationSigningResourceBundle: NSObject {}
