import CryptoKit
import Foundation

/// Controlled main/two-extension and bounded-framework orchestration using the one vault and one IPA
/// extractor. Ordinary SDK layouts/frameworks that the current Mach-O signer
/// cannot preserve are rejected; this is not full IPA or installation support.
enum SelfRenewalControlledPackageSigner {
    typealias Vault = SelfRenewalSigningMaterialVault
    typealias App = SelfRenewalApplicationMaterialVerifier
    typealias Inventory = SelfRenewalMaterialInventory
    typealias Unpacker = SelfRenewalIPAUnpacker
    enum Failure: Error, Sendable, Equatable {
        case unsupportedComponents, unsupportedCode(String), missingMaterial(String)
        case unresolvedRequirement(String), profileIdentityChanged(String), changedIdentity(String)
        case changedUnrelatedFile(String), profileBytesNotBound, missingSelectedSignature(String)
    }
    struct ComponentChange: Sendable {
        let relativePath: String
        let originalExecutableSHA256: Data
        let signedExecutableSHA256: Data
        let originalProfileSHA256: Data?
        let signedProfileSHA256: Data?
        let selectedCDHash: Data
    }
    struct Result: Sendable {
        let archive: Unpacker.ControlledArchive
        let original: App.Materials
        let originalArchiveSHA256: Data
        let originalArchiveBytes: Int
        let signed: App.Materials
        let changes: [ComponentChange]
        var appleSigningAuthorityEstablished: Bool { false }
        var accountIdentityEstablished: Bool { false }
        var deviceEligibilityEstablished: Bool { false }
        var replacementAuthorized: Bool { false }
        fileprivate init(archive: Unpacker.ControlledArchive, original: App.Materials,
            signed: App.Materials, changes: [ComponentChange], originalArchiveSHA256: Data, originalArchiveBytes: Int) {
            self.archive = archive; self.original = original; self.signed = signed; self.changes = changes
            self.originalArchiveSHA256 = originalArchiveSHA256; self.originalArchiveBytes = originalArchiveBytes
        }
    }
    nonisolated static func resign(ipa: URL, vault: Vault, lease requestedLease: Vault.Lease,
        originalCodeAnchors: [Data], originalProfileAnchors: [Data]) async throws -> Result {
        try Task.checkCancellation()
        try await vault.validate(requestedLease)
        let lease = try await vault.lease(in: requestedLease.namespace)
        guard lease.generation == requestedLease.generation, lease.keyID == requestedLease.keyID else { throw Vault.Failure.staleGeneration }
        guard let replacementCodeAnchor = lease.keyMaterial.certificateChainDER.last else { throw Failure.profileBytesNotBound }
        var profileAnchors: [Data] = []
        for profile in lease.profiles {
            for signer in profile.outerEnvelope.signers + profile.derEnvelope.signers {
                guard let anchor = signer.verifiedCertificateChainDER.last else { throw Failure.profileBytesNotBound }
                if !profileAnchors.contains(anchor) { profileAnchors.append(anchor) }
            }
        }
        guard !profileAnchors.isEmpty else { throw Failure.profileBytesNotBound }
        let replacementProfileAnchors = profileAnchors
        let date = lease.verifiedAt
        return try await Unpacker.withOwnedApplication(ipa: ipa, codeAnchors: originalCodeAnchors,
            profileAnchors: originalProfileAnchors, at: date) { scope in
            let started = SourcePerfTrace.now
            defer { SourcePerfTrace.record("renewal.package.resign",
                "bytes=\(scope.original.resources.executableMaterials.inventory.declaredFileBytes) main=\(Thread.isMainThread)",
                since: started, thresholdMs: 0) }
            let original = scope.original
            let inventory = original.resources.executableMaterials.inventory
            try await vault.validate(lease, for: original)
            try preflight(original, lease: lease)
            let originals = try await scope.hashes()
            var allowedChanges = Set<String>()
            var oldInfo: [String: Data] = [:]
            var oldResources: [String: Data] = [:]
            var oldExecutables: [String: Data] = [:]
            var profileInputs: [String: Data] = [:]
            // Read everything needed for authenticating original signatures
            // before any profile/resource/executable mutation takes place.
            for component in inventory.components {
                try Task.checkCancellation()
                guard let executable = component.executable, let resources = component.codeResources,
                      let _ = component.metadata else {
                    throw Failure.missingMaterial(component.relativePath)
                }
                let infoPath = path(component.relativePath, "Info.plist")
                oldInfo[component.relativePath] = try await scope.read(infoPath, maximumBytes: Inventory.Limits.plistBytes)
                oldResources[component.relativePath] = try await scope.read(resources.relativePath, maximumBytes: SelfRenewalResourceSealVerifier.Limits.envelopeBytes)
                let oldCode = try await scope.read(executable.file.relativePath,
                    maximumBytes: SelfRenewalControlledMachOSigner.Limits.fileBytes)
                // Structural admission above uses the existing verified reader.
                // Before any staged mutation, keep the actual FAT32 scope to the
                // big-endian wrapper emitted by this Xcode lipo path.
                if executable.header == .fat32, !oldCode.starts(with: [0xca, 0xfe, 0xba, 0xbe]) {
                    throw Failure.unsupportedCode(component.relativePath)
                }
                oldExecutables[component.relativePath] = oldCode
                if let profile = component.embeddedProvisioningProfile {
                    guard let input = lease.profileInputs.first(where: { $0.componentRelativePath == component.relativePath }) else { throw Failure.missingMaterial(component.relativePath) }
                    profileInputs[component.relativePath] = input.bytes; allowedChanges.insert(profile.relativePath)
                }
                allowedChanges.formUnion([executable.file.relativePath, resources.relativePath])
            }
            try await vault.validate(lease)
            // A containing bundle can seal child code as ordinary file hashes
            // rather than a nested requirement/cdhash (actual SDK frameworks do
            // both). Keep only fixed-size hashes of files this signer replaces.
            var changedResourceDigests: [String: [UInt8: Data]] = [:]
            for component in inventory.components where component.kind != .framework {
                guard let profile = component.embeddedProvisioningProfile,
                      let bytes = profileInputs[component.relativePath], let oldHash = originals[profile.relativePath] else {
                    throw Failure.missingMaterial(component.relativePath)
                }
                try await scope.replace(profile.relativePath, with: bytes, expectedSHA256: oldHash, maximumBytes: Vault.Limits.profileBytes)
                changedResourceDigests[profile.relativePath] = try resourceDigests(bytes)
            }
            var hashes: [String: Data] = [:]
            var changes: [ComponentChange] = []
            let ordered = inventory.components.sorted {
                let left = $0.relativePath == "." ? 0 : $0.relativePath.split(separator: "/").count
                let right = $1.relativePath == "." ? 0 : $1.relativePath.split(separator: "/").count
                return left == right ? $0.relativePath < $1.relativePath : left > right
            }
            for component in ordered {
                try Task.checkCancellation()
                let key = component.relativePath
                guard let executable = component.executable, let resource = component.codeResources,
                      let resourceProof = original.resources.components.first(where: { $0.relativePath == key }),
                      let info = oldInfo[key], let resources = oldResources[key], let oldCode = oldExecutables[key],
                      let oldCodeHash = originals[executable.file.relativePath], let oldResourceHash = originals[resource.relativePath] else {
                    throw Failure.missingMaterial(key)
                }
                var nested: [String: Data] = [:]
                for proof in resourceProof.resources.verifiedNestedResources {
                    let child = path(key, proof.relativePath)
                    guard let hash = hashes[child] else { throw Failure.unsupportedCode(child) }
                    nested[proof.relativePath] = hash
                }
                var freshProfiles: [String: Data] = [:]
                var oldProfileHash: Data?; var freshProfileHash: Data?
                if let profile = component.embeddedProvisioningProfile {
                    guard let fresh = profileInputs[key], let old = originals[profile.relativePath] else { throw Failure.missingMaterial(key) }
                    let profilePath = key == "." ? profile.relativePath : String(profile.relativePath.dropFirst(key.count + 1))
                    freshProfiles[profilePath] = fresh; oldProfileHash = old; freshProfileHash = Data(SHA256.hash(data: fresh))
                }
                let prefix = key == "." ? "" : key + "/"
                var ordinary: [String: [UInt8: Data]] = [:]
                for (absolutePath, digests) in changedResourceDigests where absolutePath.hasPrefix(prefix) {
                    let relative = String(absolutePath.dropFirst(prefix.count))
                    // This component's own profile uses the existing profile
                    // path above. Descendant ordinary seals must already have
                    // been authenticated in the original resource proof.
                    if freshProfiles[relative] == nil, resourceProof.resources.verifiedFileDigests[relative] != nil {
                        ordinary[relative] = digests
                    }
                }
                let updated = try SelfRenewalPackageResourceUpdater.update(resources, component: resourceProof,
                    freshProfiles: freshProfiles, nestedCDHashes: nested, changedResources: ordinary)
                try await scope.replace(resource.relativePath, with: updated.bytes, expectedSHA256: oldResourceHash,
                    maximumBytes: SelfRenewalResourceSealVerifier.Limits.envelopeBytes)
                try await vault.validate(lease)
                let signed = try await SelfRenewalControlledMachOSigner.resign(oldCode, identity: lease.keyMaterial,
                    originalAnchors: originalCodeAnchors, replacementAnchors: [replacementCodeAnchor], at: date,
                    externalSpecialSlots: [1: info, 3: resources], replacementExternalSpecialSlots: [3: updated.bytes])
                guard let signature = signed.signatures.slices.first, signature.selectedDirectoryAuthenticated,
                      let directory = signature.directories.first(where: { $0.slot == signature.selectedDirectorySlot }),
                      directory.signerAuthenticated, directory.cdHash.count == 20 else { throw Failure.missingSelectedSignature(key) }
                try await scope.replace(executable.file.relativePath, with: signed.signedMachO, expectedSHA256: oldCodeHash,
                    maximumBytes: SelfRenewalControlledMachOSigner.Limits.fileBytes)
                changedResourceDigests[resource.relativePath] = try resourceDigests(updated.bytes)
                changedResourceDigests[executable.file.relativePath] = try resourceDigests(signed.signedMachO)
                hashes[key] = directory.cdHash
                changes.append(ComponentChange(relativePath: key, originalExecutableSHA256: oldCodeHash,
                    signedExecutableSHA256: Data(SHA256.hash(data: signed.signedMachO)), originalProfileSHA256: oldProfileHash,
                    signedProfileSHA256: freshProfileHash, selectedCDHash: directory.cdHash))
            }
            let signed = try await scope.verifyCurrent(codeAnchors: [replacementCodeAnchor],
                profileAnchors: replacementProfileAnchors, at: date)
            try compare(original: original, signed: signed)
            try await vault.validate(lease, for: signed)
            let after = try await scope.hashes()
            guard Set(originals.keys) == Set(after.keys) else { throw Failure.changedUnrelatedFile("entries") }
            for (path, hash) in originals where !allowedChanges.contains(path) {
                guard after[path] == hash else { throw Failure.changedUnrelatedFile(path) }
            }
            try await vault.validate(lease)
            let archive = try await scope.archive(codeAnchors: [replacementCodeAnchor], profileAnchors: replacementProfileAnchors, at: date, expectedFileHashes: after)
            try compare(original: signed, signed: archive.verification.application)
            try await vault.validate(lease, for: archive.verification.application)
            try Task.checkCancellation()
            return Result(archive: archive, original: original, signed: archive.verification.application, changes: changes,
                originalArchiveSHA256: scope.originalArchiveSHA256, originalArchiveBytes: scope.originalArchiveBytes)
        }
    }
    /// Reuses actual in-memory replacement bytes; never loads the whole IPA or
    /// hashes an arbitrary archive path supplied by a caller.
    private static func resourceDigests(_ bytes: Data) throws -> [UInt8: Data] {
        try Task.checkCancellation()
        return try SourcePerfTrace.span("renewal.package.changed-resource-hashes",
            "main=\(Thread.isMainThread) bytes=\(bytes.count)") {
            let sha256 = try SelfRenewalCodeDirectoryHashVerifier.digest(bytes, hashType: 2)
            return [1: try SelfRenewalCodeDirectoryHashVerifier.digest(bytes, hashType: 1),
                2: sha256, 3: Data(sha256.prefix(20)),
                4: try SelfRenewalCodeDirectoryHashVerifier.digest(bytes, hashType: 4)]
        }
    }
    private static func preflight(_ original: App.Materials, lease: Vault.Lease) throws {
        let inventory = original.resources.executableMaterials.inventory
        let expected: Set<Inventory.Role> = [.application, .widgetExtension, .shareExtension]
        let allowedInventoryIssues = inventory.issues.allSatisfy { issue in
            if case .unexpectedComponent(let path) = issue {
                return inventory.components.first(where: { $0.relativePath == path })?.kind == .framework
            }
            return false
        }
        guard allowedInventoryIssues, (3...19).contains(inventory.components.count), inventory.codeFiles.count == inventory.components.count,
              original.bundles.count == 3, Set(original.bundles.compactMap(\.role)) == expected,
              Set(lease.profileInputs.map(\.componentRelativePath)) == Set(original.bundles.map(\.componentRelativePath)),
              lease.profileInputs.count == 3, lease.profiles.count == 3 else { throw Failure.unsupportedComponents }
        try resolved(original)
        for component in inventory.components {
            guard component.kind == .application || component.kind == .appExtension || component.kind == .framework,
                  let code = component.executable, code.header == .thin64 || code.header == .fat32,
                  inventory.codeFiles.contains(code),
                  let material = original.resources.executableMaterials.code.first(where: { $0.file == code.file }),
                  SelfRenewalControlledMachOSigner.supportsSingleArm64Container(material.structure,
                    fileByteCount: UInt64(code.file.byteCount)),
                  let metadata = component.metadata, component.codeResources != nil else { throw Failure.unsupportedCode(component.relativePath) }
            if component.kind == .framework {
                guard component.embeddedProvisioningProfile == nil else { throw Failure.unsupportedCode(component.relativePath) }
                continue
            }
            guard let old = original.bundles.first(where: { $0.componentRelativePath == component.relativePath }),
                  old.bundleIdentifier == metadata.bundleIdentifier,
                  let input = lease.profileInputs.first(where: { $0.componentRelativePath == component.relativePath }),
                  let fresh = lease.profiles.first(where: { $0.file.relativePath == old.profileRelativePath }),
                  fresh.file.byteCount == Int64(input.bytes.count), fresh.rawFileDigests[2] == Data(SHA256.hash(data: input.bytes)),
                  let previous = original.profiles.profiles.first(where: { $0.file.relativePath == old.profileRelativePath }),
                  case .dictionary(let oldProperties) = previous.properties,
                  case .dictionary(let newProperties) = fresh.properties,
                  oldProperties["Entitlements"] == newProperties["Entitlements"],
                  previous.summary.teamIdentifiers == fresh.summary.teamIdentifiers,
                  previous.summary.applicationIdentifierPrefixes == fresh.summary.applicationIdentifierPrefixes else {
                throw Failure.profileIdentityChanged(component.relativePath)
            }
        }
    }
    private static func resolved(_ material: App.Materials) throws {
        for component in material.resources.components {
            guard component.resources.resourceEnvelopeVerified, component.resources.unresolvedNestedResources.isEmpty,
                  component.resources.unresolvedRequirementCapabilities.isEmpty else { throw Failure.unresolvedRequirement(component.relativePath) }
        }
    }
    private static func compare(original: App.Materials, signed: App.Materials) throws {
        try resolved(signed)
        let leftInventory = original.resources.executableMaterials.inventory
        let rightInventory = signed.resources.executableMaterials.inventory
        for before in leftInventory.components {
            guard let after = rightInventory.components.first(where: { $0.relativePath == before.relativePath }),
                  before.kind == after.kind, before.metadata == after.metadata, before.role == after.role,
                  let path = before.executable?.file.relativePath, path == after.executable?.file.relativePath,
                  let old = original.resources.codeAttributes[path], let new = signed.resources.codeAttributes[path],
                  old.slices.count == new.slices.count else { throw Failure.changedIdentity(before.relativePath) }
            for (left, right) in zip(old.slices, new.slices) {
                guard left.attributes.identifier == right.attributes.identifier, left.attributes.platform == right.attributes.platform,
                      left.attributes.info == right.attributes.info, left.attributes.entitlements == right.attributes.entitlements else {
                    throw Failure.changedIdentity(before.relativePath)
                }
            }
        }
        guard leftInventory.components.count == rightInventory.components.count,
              original.bundles.count == signed.bundles.count else { throw Failure.changedIdentity("bundles") }
        for before in original.bundles {
            guard let after = signed.bundles.first(where: { $0.componentRelativePath == before.componentRelativePath }),
                  before.role == after.role, before.bundleIdentifier == after.bundleIdentifier,
                  before.profileRelativePath == after.profileRelativePath,
                  before.slices.count == after.slices.count,
                  let oldComponent = leftInventory.components.first(where: { $0.relativePath == before.componentRelativePath }),
                  let newComponent = rightInventory.components.first(where: { $0.relativePath == before.componentRelativePath }),
                  oldComponent.metadata == newComponent.metadata,
                  let file = oldComponent.executable?.file.relativePath,
                  let oldAttributes = original.resources.codeAttributes[file], let newAttributes = signed.resources.codeAttributes[file],
                  oldAttributes.slices.count == newAttributes.slices.count else { throw Failure.changedIdentity(before.componentRelativePath) }
            for (old, new) in zip(before.slices, after.slices) {
                guard old.codeSigningIdentifier == new.codeSigningIdentifier, old.codeDirectoryTeamIdentifier == new.codeDirectoryTeamIdentifier,
                      old.teamIdentifier == new.teamIdentifier, old.applicationIdentifierPrefix == new.applicationIdentifierPrefix,
                      old.applicationIdentifier == new.applicationIdentifier, old.appGroups == new.appGroups,
                      old.keychainAccessGroups == new.keychainAccessGroups, old.unassessedEntitlementKeys == new.unassessedEntitlementKeys else {
                    throw Failure.changedIdentity(before.componentRelativePath)
                }
            }
            for (old, new) in zip(oldAttributes.slices, newAttributes.slices) {
                guard old.attributes.info == new.attributes.info, old.attributes.entitlements == new.attributes.entitlements,
                      old.attributes.identifier == new.attributes.identifier, old.attributes.platform == new.attributes.platform else {
                    throw Failure.changedIdentity(before.componentRelativePath)
                }
            }
        }
    }
    private static func path(_ component: String, _ leaf: String) -> String { component == "." ? leaf : component + "/" + leaf }
}
