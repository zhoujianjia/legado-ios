import Foundation

/// Pure metadata preflight for this app's three-bundle renewal shape.
/// No production adapter exists here. An adapter assertion is a prerequisite
/// supplied by a future real platform adapter, not cryptographic proof created
/// by this type. Tests use owned synthetic assertions only.
enum SelfRenewalReplacementPolicy {
    enum BundleRole: String, CaseIterable, Sendable {
        case application
        case widgetExtension
        case shareExtension
    }

    enum SnapshotKind: Sendable, Equatable { case installed, candidate }

    enum Evidence: Sendable, Equatable {
        case unverified
        /// The future adapter must verify the complete app/extension inventory,
        /// actual identities, resolved signed entitlements and account binding
        /// before asserting these values. No boolean here performs that work.
        /// An unknown/extra extension must make this inventory incomplete; it
        /// cannot be silently omitted. Other nested signed-code verification
        /// remains part of the separate real signing adapter gate.
        case platformAdapterAssertion(kind: SnapshotKind, completeInventory: Bool, binding: UUID)
    }

    struct Validity: Sendable, Equatable {
        var notBefore: Date
        var expiresAt: Date
    }

    struct BundleSnapshot: Sendable, Equatable {
        var role: BundleRole
        var bundleIdentifier: String
        var parentBundleIdentifier: String?
        var teamIdentifier: String
        /// App ID prefix can differ from Team ID for an existing app.
        var applicationIdentifierPrefix: String
        var applicationIdentifier: String
        var version: String
        var build: String
        /// nil means unknown. [] means the adapter established an empty list.
        var appGroups: [String]?
        /// Order is retained: the first keychain group can be the default.
        var keychainAccessGroups: [String]?
        /// Candidate: adapter-established intersection of the relevant signing
        /// authorization validity windows. This does not inspect a certificate
        /// or provisioning profile or establish that either one is trustworthy.
        var authorizationValidity: Validity?
    }

    struct Snapshot: Sendable, Equatable {
        var evidence: Evidence
        /// Opaque, non-secret account binding from the future adapter, never an
        /// Apple ID, credential, token or account implementation in this policy.
        var accountIdentity: String?
        var bundles: [BundleSnapshot]
    }

    enum GroupKind: Sendable, Equatable { case appGroups, keychainAccessGroups }
    enum MetadataField: Sendable, Equatable {
        case bundleIdentifier, teamIdentifier, applicationIdentifierPrefix
        case applicationIdentifier, version, build
    }

    /// Errors contain only fixed reasons/roles, never an account or Team value.
    enum Rejection: Error, Sendable, Equatable {
        case invalidEvaluationTime
        case unverifiedSnapshot(SnapshotKind)
        case wrongSnapshotKind(SnapshotKind)
        case incompleteInventory(SnapshotKind)
        case accountIdentityUnavailable(SnapshotKind)
        case accountChanged
        case tooManyBundles(SnapshotKind)
        case missingBundle(SnapshotKind, BundleRole)
        case duplicateRole(SnapshotKind, BundleRole)
        case duplicateBundleIdentifier(SnapshotKind)
        case invalidMetadata(SnapshotKind, BundleRole, MetadataField)
        case invalidParentRelationship(SnapshotKind, BundleRole)
        case inconsistentTeam(SnapshotKind, BundleRole)
        case groupsUnknown(SnapshotKind, BundleRole, GroupKind)
        case invalidGroups(SnapshotKind, BundleRole, GroupKind)
        case bundleMappingChanged(BundleRole)
        case teamChanged(BundleRole)
        case applicationIdentifierChanged(BundleRole)
        case groupsChanged(BundleRole, GroupKind)
        case versionChangeOutsideRenewalScope(BundleRole)
        case buildChangeOutsideRenewalScope(BundleRole)
        case candidateValidityUnknown(BundleRole)
        case invalidValidity(SnapshotKind, BundleRole)
        case candidateNotYetValid(BundleRole)
        case candidateExpired(BundleRole)
    }

    struct BundleMapping: Sendable, Equatable {
        let role: BundleRole
        let bundleIdentifier: String
        let parentBundleIdentifier: String?
        let version: String
        let build: String
    }

    struct ReplacementPreflightPlan: Sendable, Equatable {
        let installedSnapshotBinding: UUID
        let candidateSnapshotBinding: UUID
        let bundles: [BundleMapping]
        let evaluatedAt: Date
        let candidateAuthorizationExpiresAt: Date

        // This plan cannot authorize an operation or bypass signerIntegration's
        // authenticated installation transport gate. Adapters must revalidate
        // actual materials/snapshots at use, then verify installation and data.
        var authenticatedTransportGateStillRequired: Bool { true }
        var realSigningAdapterStillRequired: Bool { true }
        var signedCandidateAndIdentityRevalidationStillRequired: Bool { true }
        var installationAndDataRetentionVerificationStillRequired: Bool { true }
        var cryptographicVerificationPerformed: Bool { false }
        var deviceVerificationPerformed: Bool { false }
        var signingPerformed: Bool { false }
        var installationPerformed: Bool { false }
        var renewalProven: Bool { false }
    }

    enum Decision: Sendable, Equatable {
        case metadataCompatible(ReplacementPreflightPlan)
        case rejected(Rejection)
    }

    /// Synchronous, bounded, value-only comparison. The clock is an input.
    /// Same version AND build are intentional: this is renewal preflight, not
    /// a general update/downgrade policy. A version change needs a separate flow.
    static func evaluate(installed: Snapshot, candidate: Snapshot, at now: Date) -> Decision {
        guard now.timeIntervalSinceReferenceDate.isFinite else { return .rejected(.invalidEvaluationTime) }
        let old: [BundleRole: BundleSnapshot]
        let new: [BundleRole: BundleSnapshot]
        let oldBinding: UUID
        let newBinding: UUID
        switch inventory(installed, kind: .installed) {
        case .failure(let reason): return .rejected(reason)
        case .success(let result):
            old = result.0
            oldBinding = result.1
        }
        switch inventory(candidate, kind: .candidate) {
        case .failure(let reason): return .rejected(reason)
        case .success(let result):
            new = result.0
            newBinding = result.1
        }
        guard installed.accountIdentity == candidate.accountIdentity else { return .rejected(.accountChanged) }
        var mappings: [BundleMapping] = []
        var earliestExpiry: Date?
        for role in BundleRole.allCases {
            // Inventory validation below established one bundle for every role.
            guard let current = old[role], let replacement = new[role] else {
                return .rejected(.missingBundle(.candidate, role))
            }
            guard current.bundleIdentifier == replacement.bundleIdentifier,
                  current.parentBundleIdentifier == replacement.parentBundleIdentifier else {
                return .rejected(.bundleMappingChanged(role))
            }
            guard current.teamIdentifier == replacement.teamIdentifier else { return .rejected(.teamChanged(role)) }
            guard current.applicationIdentifierPrefix == replacement.applicationIdentifierPrefix,
                  current.applicationIdentifier == replacement.applicationIdentifier else {
                return .rejected(.applicationIdentifierChanged(role))
            }
            guard let currentAppGroups = current.appGroups else { return .rejected(.groupsUnknown(.installed, role, .appGroups)) }
            guard let replacementAppGroups = replacement.appGroups else { return .rejected(.groupsUnknown(.candidate, role, .appGroups)) }
            guard Set(currentAppGroups) == Set(replacementAppGroups) else {
                return .rejected(.groupsChanged(role, .appGroups))
            }
            guard let currentKeychainGroups = current.keychainAccessGroups else { return .rejected(.groupsUnknown(.installed, role, .keychainAccessGroups)) }
            guard let replacementKeychainGroups = replacement.keychainAccessGroups else { return .rejected(.groupsUnknown(.candidate, role, .keychainAccessGroups)) }
            guard currentKeychainGroups == replacementKeychainGroups else {
                return .rejected(.groupsChanged(role, .keychainAccessGroups))
            }
            guard current.version == replacement.version else { return .rejected(.versionChangeOutsideRenewalScope(role)) }
            guard current.build == replacement.build else { return .rejected(.buildChangeOutsideRenewalScope(role)) }
            guard let validity = replacement.authorizationValidity else { return .rejected(.candidateValidityUnknown(role)) }
            guard now >= validity.notBefore else { return .rejected(.candidateNotYetValid(role)) }
            guard now < validity.expiresAt else { return .rejected(.candidateExpired(role)) }
            earliestExpiry = min(earliestExpiry ?? validity.expiresAt, validity.expiresAt)
            mappings.append(BundleMapping(role: role, bundleIdentifier: replacement.bundleIdentifier,
                parentBundleIdentifier: replacement.parentBundleIdentifier, version: replacement.version, build: replacement.build))
        }
        guard let earliestExpiry else { return .rejected(.candidateValidityUnknown(.application)) }
        return .metadataCompatible(ReplacementPreflightPlan(installedSnapshotBinding: oldBinding,
            candidateSnapshotBinding: newBinding, bundles: mappings, evaluatedAt: now,
            candidateAuthorizationExpiresAt: earliestExpiry))
    }

    private static func inventory(_ snapshot: Snapshot, kind: SnapshotKind)
        -> Result<([BundleRole: BundleSnapshot], UUID), Rejection> {
        let binding: UUID
        switch snapshot.evidence {
        case .unverified: return .failure(.unverifiedSnapshot(kind))
        case .platformAdapterAssertion(let assertedKind, let complete, let identifier):
            guard assertedKind == kind else { return .failure(.wrongSnapshotKind(kind)) }
            guard complete else { return .failure(.incompleteInventory(kind)) }
            binding = identifier
        }
        guard let account = snapshot.accountIdentity, validToken(account, maximum: 128) else {
            return .failure(.accountIdentityUnavailable(kind))
        }
        guard snapshot.bundles.count <= BundleRole.allCases.count else { return .failure(.tooManyBundles(kind)) }
        var result: [BundleRole: BundleSnapshot] = [:]
        var identifiers = Set<String>()
        for bundle in snapshot.bundles {
            guard result[bundle.role] == nil else { return .failure(.duplicateRole(kind, bundle.role)) }
            for (value, field) in [(bundle.bundleIdentifier, MetadataField.bundleIdentifier),
                                   (bundle.teamIdentifier, .teamIdentifier),
                                   (bundle.applicationIdentifierPrefix, .applicationIdentifierPrefix),
                                   (bundle.applicationIdentifier, .applicationIdentifier)] {
                guard validIdentifier(value) else { return .failure(.invalidMetadata(kind, bundle.role, field)) }
            }
            guard identifiers.insert(bundle.bundleIdentifier).inserted else { return .failure(.duplicateBundleIdentifier(kind)) }
            guard bundle.applicationIdentifier == bundle.applicationIdentifierPrefix + "." + bundle.bundleIdentifier else {
                return .failure(.invalidMetadata(kind, bundle.role, .applicationIdentifier))
            }
            guard validToken(bundle.version, maximum: 64) else { return .failure(.invalidMetadata(kind, bundle.role, .version)) }
            guard validToken(bundle.build, maximum: 64) else { return .failure(.invalidMetadata(kind, bundle.role, .build)) }
            for (groups, groupKind) in [(bundle.appGroups, GroupKind.appGroups), (bundle.keychainAccessGroups, .keychainAccessGroups)] {
                guard let groups else { return .failure(.groupsUnknown(kind, bundle.role, groupKind)) }
                guard groups.count <= 32, groups.allSatisfy(validIdentifier), Set(groups).count == groups.count else {
                    return .failure(.invalidGroups(kind, bundle.role, groupKind))
                }
            }
            if let validity = bundle.authorizationValidity {
                guard validity.notBefore.timeIntervalSinceReferenceDate.isFinite,
                      validity.expiresAt.timeIntervalSinceReferenceDate.isFinite,
                      validity.notBefore < validity.expiresAt else { return .failure(.invalidValidity(kind, bundle.role)) }
            }
            result[bundle.role] = bundle
        }
        for role in BundleRole.allCases where result[role] == nil { return .failure(.missingBundle(kind, role)) }
        guard let main = result[.application] else { return .failure(.missingBundle(kind, .application)) }
        for role in BundleRole.allCases {
            guard let bundle = result[role] else { return .failure(.missingBundle(kind, role)) }
            guard bundle.teamIdentifier == main.teamIdentifier else { return .failure(.inconsistentTeam(kind, role)) }
            if role == .application {
                guard bundle.parentBundleIdentifier == nil else { return .failure(.invalidParentRelationship(kind, role)) }
            } else {
                guard bundle.parentBundleIdentifier == main.bundleIdentifier,
                      bundle.bundleIdentifier.hasPrefix(main.bundleIdentifier + ".") else {
                    return .failure(.invalidParentRelationship(kind, role))
                }
            }
        }
        return .success((result, binding))
    }

    private static func validToken(_ value: String, maximum: Int) -> Bool {
        let bytes = value.utf8.prefix(maximum + 1)
        return !bytes.isEmpty && bytes.count <= maximum && bytes.allSatisfy { (33...126).contains($0) }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        let bytes = value.utf8.prefix(256)
        return !bytes.isEmpty && bytes.count <= 255 && bytes.first != 46 && bytes.last != 46
            && !value.contains("..") && bytes.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46
        }
    }
}
