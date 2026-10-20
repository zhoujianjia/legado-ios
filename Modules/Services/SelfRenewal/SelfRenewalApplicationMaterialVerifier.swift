import CryptoKit
import Foundation

/// One read-only material path: executable pages/CMS -> resource/nested checks
/// -> independently signed modern profiles -> actual signer/Info/entitlement
/// identity consistency. Generic explicit anchors never authorize installation.
enum SelfRenewalApplicationMaterialVerifier {
    typealias Inventory = SelfRenewalMaterialInventory
    typealias Value = SelfRenewalDERPropertyList.Value
    enum Failure: Error, Sendable, Equatable {
        case missingComponentMaterial(String), changedInfo(String), unsignedCode(String)
        case missingDEREntitlements(String), malformedIdentity(String), signerNotInProfile(String)
        case applicationIdentifierMismatch(String), teamMismatch(String), groupNotInProfile(String)
        case changedProfileResource(String)
    }
    enum ProfileResourceBinding: Sendable, Equatable {
        case matched([UInt8]), notInResourceSeal
    }
    struct SliceIdentity: Sendable, Equatable {
        let sliceOffset: UInt64
        let codeSigningIdentifier: String
        let codeDirectoryTeamIdentifier: String?
        let teamIdentifier: String
        let applicationIdentifierPrefix: String
        let applicationIdentifier: String
        let codeSignerCertificateSHA256: Data
        let appGroups: [String]
        /// Preserve signed order: the first keychain group may be the default.
        let keychainAccessGroups: [String]
        let unassessedEntitlementKeys: [String]
        fileprivate init(offset: UInt64, identifier: String, directoryTeam: String?, team: String,
            prefix: String, applicationIdentifier: String, certificateHash: Data,
            appGroups: [String], keychainGroups: [String], unassessed: [String]) {
            sliceOffset = offset; codeSigningIdentifier = identifier; codeDirectoryTeamIdentifier = directoryTeam
            teamIdentifier = team; applicationIdentifierPrefix = prefix
            self.applicationIdentifier = applicationIdentifier; codeSignerCertificateSHA256 = certificateHash
            self.appGroups = appGroups; keychainAccessGroups = keychainGroups; unassessedEntitlementKeys = unassessed
        }
    }
    struct BundleIdentity: Sendable, Equatable {
        let componentRelativePath: String
        let role: Inventory.Role?
        let bundleIdentifier: String
        let profileRelativePath: String
        let profileUUID: String
        let profileResourceBinding: ProfileResourceBinding
        let slices: [SliceIdentity]
        var appleAuthorizationEstablished: Bool { false }
        fileprivate init(component: Inventory.Component, identifier: String,
            profile: SelfRenewalProvisioningProfileVerifier.ModernProfile,
            resourceBinding: ProfileResourceBinding, slices: [SliceIdentity]) {
            componentRelativePath = component.relativePath; role = component.role; bundleIdentifier = identifier
            profileRelativePath = profile.file.relativePath; profileUUID = profile.summary.uuid
            profileResourceBinding = resourceBinding; self.slices = slices
        }
    }
    struct Materials: Sendable, Equatable {
        let resources: SelfRenewalResourceSealVerifier.Materials
        let profiles: SelfRenewalProvisioningProfileVerifier.ModernMaterials
        let bundles: [BundleIdentity]
        var profileAndCodeIdentityConsistencyVerified: Bool { !bundles.isEmpty }
        var appleSigningAuthorityEstablished: Bool { false }
        var fullEntitlementAuthorizationEstablished: Bool { false }
        var deviceEligibilityEstablished: Bool { false }
        var accountIdentityEstablished: Bool { false }
        var replacementAuthorized: Bool { false }
        fileprivate init(resources: SelfRenewalResourceSealVerifier.Materials,
            profiles: SelfRenewalProvisioningProfileVerifier.ModernMaterials, bundles: [BundleIdentity]) {
            self.resources = resources; self.profiles = profiles; self.bundles = bundles
        }
    }

    nonisolated static func read(unpackedApplication root: URL, codeAnchors: [Data], profileAnchors: [Data],
        at date: Date) async throws -> Materials {
        let code = try await SelfRenewalSignedCodeVerifier.read(unpackedApplication: root, anchors: codeAnchors, at: date)
        let resources = try await SelfRenewalResourceSealVerifier.verify(unpackedApplication: root, executableMaterials: code)
        let profiles = try await SelfRenewalProvisioningProfileVerifier.readModern(unpackedApplication: root,
            inventory: code.inventory, anchors: profileAnchors, at: date)
        let worker = Task.detached(priority: .utility) { try bind(resources: resources, profiles: profiles) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    /// The inputs contain genuine sealed verifier results, not caller-provided
    /// success Booleans. Reuses selected-CD-bound attributes already loaded by
    /// the resource verifier; this phase performs no I/O or second enumeration.
    static func bind(resources: SelfRenewalResourceSealVerifier.Materials,
        profiles: SelfRenewalProvisioningProfileVerifier.ModernMaterials) throws -> Materials {
        precondition(!Thread.isMainThread, "Application material binding must stay off main")
        try Task.checkCancellation()
        let started = SourcePerfTrace.now
        var identities: [BundleIdentity] = []
        defer {
            SourcePerfTrace.record("renewal.material.application-binding",
                "bundles=\(identities.count) profiles=\(profiles.profiles.count) main=\(Thread.isMainThread)",
                since: started, thresholdMs: 0)
        }
        guard resources.executableMaterials.inventory == profiles.inventory else { throw Failure.changedInfo(".") }
        for component in profiles.inventory.components {
            try Task.checkCancellation()
            guard component.kind == .application || component.kind == .appExtension else { continue }
            let path = component.relativePath
            guard let metadata = component.metadata, let executable = component.executable,
                  let profileFact = component.embeddedProvisioningProfile,
                  let profile = profiles.profiles.first(where: { $0.file == profileFact }),
                  let resource = resources.components.first(where: { $0.relativePath == path }),
                  let code = resources.executableMaterials.code.first(where: { $0.file == executable.file }),
                  let signed = code.signedCodeVerification,
                  let loaded = resources.codeAttributes[executable.file.relativePath] else { throw Failure.missingComponentMaterial(path) }
            let profilePath = path == "." ? profileFact.relativePath : String(profileFact.relativePath.dropFirst(path.count + 1))
            let resourceBinding: ProfileResourceBinding
            if let digests = resource.resources.verifiedFileDigests[profilePath] {
                guard !digests.isEmpty, digests.allSatisfy({ profile.rawFileDigests[$0.key] == $0.value }) else {
                    throw Failure.changedProfileResource(path)
                }
                resourceBinding = .matched(digests.keys.sorted())
            } else {
                // An original resource rule may omit an independently signed
                // profile. Preserve that fact instead of inventing a seal.
                resourceBinding = .notInResourceSeal
            }
            guard case .dictionary(let properties) = profile.properties,
                  case .dictionary(let permitted)? = properties["Entitlements"] else { throw Failure.malformedIdentity(path) }
            var slices: [SliceIdentity] = []
            for loadedSlice in loaded.slices {
                try Task.checkCancellation()
                guard loadedSlice.selectedDirectorySignerAuthenticated, !loadedSlice.adHoc,
                      let signature = signed.slices.first(where: { $0.sliceOffset == loadedSlice.offset }),
                      let certificate = signature.signers.first?.verifiedCertificateChainDER.first else { throw Failure.unsignedCode(path) }
                let certificateHash = Data(SHA256.hash(data: certificate))
                guard profile.summary.developerCertificateSHA256.contains(certificateHash) else { throw Failure.signerNotInProfile(path) }
                let attributes = loadedSlice.attributes
                guard case .dictionary(let info)? = attributes.info,
                      info["CFBundleIdentifier"] == .string(metadata.bundleIdentifier),
                      info["CFBundleExecutable"] == .string(metadata.executableName),
                      info["CFBundleShortVersionString"] == .string(metadata.version),
                      info["CFBundleVersion"] == .string(metadata.build) else { throw Failure.changedInfo(path) }
                guard case .dictionary(let claims)? = attributes.entitlements else { throw Failure.missingDEREntitlements(path) }
                guard case .string(let appID)? = claims["application-identifier"],
                      case .string(let team)? = claims["com.apple.developer.team-identifier"],
                      !team.isEmpty, !appID.isEmpty, !appID.contains("*"),
                      let prefix = profile.summary.applicationIdentifierPrefixes.first(where: { appID == $0 + "." + metadata.bundleIdentifier }) else {
                    throw Failure.applicationIdentifierMismatch(path)
                }
                guard matchesProfilePattern(profile.summary.applicationIdentifier, claim: appID) else { throw Failure.applicationIdentifierMismatch(path) }
                guard profile.summary.teamIdentifiers.contains(team),
                      profile.summary.entitlementTeamIdentifier == nil || profile.summary.entitlementTeamIdentifier == team else { throw Failure.teamMismatch(path) }
                let directoryTeam = code.structure.slices.first(where: { $0.range.offset == loadedSlice.offset })?
                    .signature?.codeDirectories.first(where: { $0.slot == signature.selectedDirectorySlot })?.teamIdentifier
                if let directoryTeam, directoryTeam != team { throw Failure.teamMismatch(path) }
                let groups = try groupClaims("com.apple.security.application-groups", claims: claims, permitted: permitted, path: path)
                let keychain = try groupClaims("keychain-access-groups", claims: claims, permitted: permitted, path: path)
                let assessed: Set<String> = ["application-identifier", "com.apple.developer.team-identifier",
                    "com.apple.security.application-groups", "keychain-access-groups"]
                slices.append(SliceIdentity(offset: loadedSlice.offset, identifier: attributes.identifier,
                    directoryTeam: directoryTeam, team: team, prefix: prefix, applicationIdentifier: appID,
                    certificateHash: certificateHash, appGroups: groups, keychainGroups: keychain,
                    unassessed: claims.keys.filter { !assessed.contains($0) }.sorted()))
            }
            guard !slices.isEmpty, slices.count == signed.slices.count else { throw Failure.missingComponentMaterial(path) }
            identities.append(BundleIdentity(component: component, identifier: metadata.bundleIdentifier,
                profile: profile, resourceBinding: resourceBinding, slices: slices))
        }
        guard !identities.isEmpty, identities.count == profiles.profiles.count else { throw Failure.missingComponentMaterial(".") }
        return Materials(resources: resources, profiles: profiles, bundles: identities)
    }
    private static func groupClaims(_ key: String, claims: [String: Value], permitted: [String: Value], path: String) throws -> [String] {
        guard let raw = claims[key] else { return [] }
        guard case .array(let values) = raw else { throw Failure.groupNotInProfile(path) }
        if values.isEmpty { return [] }
        guard case .array(let allowed)? = permitted[key] else { throw Failure.groupNotInProfile(path) }
        var result: [String] = []
        for value in values {
            try Task.checkCancellation()
            guard case .string(let claim) = value, !claim.isEmpty, !claim.contains("*"),
                  allowed.contains(where: { if case .string(let pattern) = $0 { return matchesProfilePattern(pattern, claim: claim) }; return false }) else {
                throw Failure.groupNotInProfile(path)
            }
            result.append(claim)
        }
        return result
    }
    private static func matchesProfilePattern(_ pattern: String, claim: String) -> Bool {
        if pattern == claim { return true }
        guard pattern.last == "*", pattern.dropLast().contains("*") == false else { return false }
        return claim.hasPrefix(String(pattern.dropLast()))
    }
}
