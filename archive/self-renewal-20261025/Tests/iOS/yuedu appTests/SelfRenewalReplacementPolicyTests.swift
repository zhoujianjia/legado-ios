import Foundation
import Testing
@testable import yuedu_app

@Suite("Self-renewal metadata replacement preflight, synthetic inputs only")
struct SelfRenewalReplacementPolicyTests {
    private typealias Policy = SelfRenewalReplacementPolicy
    private static let now = Date(timeIntervalSinceReferenceDate: 10_000)

    @Test("Account, Team, exact bundle mapping and parent identity cannot change")
    func rejectsAccountTeamAndBundleMappingChanges() {
        let old = Self.snapshot(.installed)
        var candidate = Self.snapshot(.candidate)
        candidate.accountIdentity = "owned-other-account"
        #expect(Policy.evaluate(installed: old, candidate: candidate, at: Self.now) == .rejected(.accountChanged))
        candidate = Self.snapshot(.candidate)
        for index in candidate.bundles.indices { candidate.bundles[index].teamIdentifier = "OTHERTEAM" }
        #expect(Policy.evaluate(installed: old, candidate: candidate, at: Self.now) == .rejected(.teamChanged(.application)))
        candidate = Self.snapshot(.candidate)
        candidate.bundles[1].teamIdentifier = "OTHERTEAM"
        #expect(Policy.evaluate(installed: old, candidate: candidate, at: Self.now) == .rejected(.inconsistentTeam(.candidate, .widgetExtension)))
        candidate = Self.snapshot(.candidate)
        candidate.bundles[1].bundleIdentifier += "-changed"
        candidate.bundles[1].applicationIdentifier += "-changed"
        #expect(Policy.evaluate(installed: old, candidate: candidate, at: Self.now) == .rejected(.bundleMappingChanged(.widgetExtension)))
        candidate = Self.snapshot(.candidate)
        candidate.bundles[2].parentBundleIdentifier = "owned.other.app"
        #expect(Policy.evaluate(installed: old, candidate: candidate, at: Self.now) == .rejected(.invalidParentRelationship(.candidate, .shareExtension)))
        candidate = Self.snapshot(.candidate)
        candidate.bundles[0].applicationIdentifierPrefix = "CHANGEDPREFIX"
        candidate.bundles[0].applicationIdentifier = "CHANGEDPREFIX." + candidate.bundles[0].bundleIdentifier
        #expect(Policy.evaluate(installed: old, candidate: candidate, at: Self.now) == .rejected(.applicationIdentifierChanged(.application)))
        candidate = Self.snapshot(.candidate); candidate.bundles[0].version = "changed"
        #expect(Policy.evaluate(installed: old, candidate: candidate, at: Self.now) == .rejected(.versionChangeOutsideRenewalScope(.application)))
        candidate = Self.snapshot(.candidate); candidate.bundles[0].build = "13"
        #expect(Policy.evaluate(installed: old, candidate: candidate, at: Self.now) == .rejected(.buildChangeOutsideRenewalScope(.application)))
    }

    @Test("Every role must occur exactly once in a complete adapter-asserted inventory")
    func rejectsMissingDuplicateOrIncompleteBundleInventory() {
        let old = Self.snapshot(.installed)
        var candidate = Self.snapshot(.candidate)
        candidate.bundles.removeLast()
        #expect(Policy.evaluate(installed: old, candidate: candidate, at: Self.now) == .rejected(.missingBundle(.candidate, .shareExtension)))
        candidate = Self.snapshot(.candidate)
        candidate.bundles[2] = candidate.bundles[1]
        #expect(Policy.evaluate(installed: old, candidate: candidate, at: Self.now) == .rejected(.duplicateRole(.candidate, .widgetExtension)))
        candidate = Self.snapshot(.candidate)
        candidate.bundles[2].bundleIdentifier = candidate.bundles[1].bundleIdentifier
        #expect(Policy.evaluate(installed: old, candidate: candidate, at: Self.now) == .rejected(.duplicateBundleIdentifier(.candidate)))
        candidate = Self.snapshot(.candidate)
        candidate.bundles.append(candidate.bundles[1])
        #expect(Policy.evaluate(installed: old, candidate: candidate, at: Self.now) == .rejected(.tooManyBundles(.candidate)))
        candidate = Self.snapshot(.candidate)
        candidate.evidence = .platformAdapterAssertion(kind: .candidate, completeInventory: false, binding: UUID())
        #expect(Policy.evaluate(installed: old, candidate: candidate, at: Self.now) == .rejected(.incompleteInventory(.candidate)))
        var missingInstalled = old; missingInstalled.bundles.removeFirst()
        #expect(Policy.evaluate(installed: missingInstalled, candidate: Self.snapshot(.candidate), at: Self.now) == .rejected(.missingBundle(.installed, .application)))
    }

    @Test("Known empty groups differ from unknown; changed/default keychain groups are rejected")
    func rejectsChangedOrUnknownEntitlementGroups() {
        let old = Self.snapshot(.installed)
        var candidate = Self.snapshot(.candidate)
        candidate.bundles[1].appGroups = ["group.owned.changed"]
        #expect(Policy.evaluate(installed: old, candidate: candidate, at: Self.now) == .rejected(.groupsChanged(.widgetExtension, .appGroups)))
        candidate = Self.snapshot(.candidate); candidate.bundles[2].keychainAccessGroups = ["OLDPREFIX.changed"]
        #expect(Policy.evaluate(installed: old, candidate: candidate, at: Self.now) == .rejected(.groupsChanged(.shareExtension, .keychainAccessGroups)))
        candidate = Self.snapshot(.candidate); candidate.bundles[0].appGroups = nil
        #expect(Policy.evaluate(installed: old, candidate: candidate, at: Self.now) == .rejected(.groupsUnknown(.candidate, .application, .appGroups)))
        candidate = Self.snapshot(.candidate); candidate.bundles[0].keychainAccessGroups = nil
        #expect(Policy.evaluate(installed: old, candidate: candidate, at: Self.now) == .rejected(.groupsUnknown(.candidate, .application, .keychainAccessGroups)))
        candidate = Self.snapshot(.candidate); candidate.bundles[0].appGroups = ["group.owned.shared", "group.owned.shared"]
        #expect(Policy.evaluate(installed: old, candidate: candidate, at: Self.now) == .rejected(.invalidGroups(.candidate, .application, .appGroups)))
        var twoGroups = old
        twoGroups.bundles[0].keychainAccessGroups = ["OLDPREFIX.first", "OLDPREFIX.second"]
        candidate = Self.snapshot(.candidate); candidate.bundles[0].keychainAccessGroups = ["OLDPREFIX.second", "OLDPREFIX.first"]
        #expect(Policy.evaluate(installed: twoGroups, candidate: candidate, at: Self.now) == .rejected(.groupsChanged(.application, .keychainAccessGroups)))
        var unknownInstalled = old; unknownInstalled.bundles[1].appGroups = nil
        #expect(Policy.evaluate(installed: unknownInstalled, candidate: Self.snapshot(.candidate), at: Self.now) == .rejected(.groupsUnknown(.installed, .widgetExtension, .appGroups)))

        // A profile-bound signed namespace group is retained as a literal,
        // including its position as the default group; it grants no pattern match.
        var literalInstalled = old
        var literalCandidate = Self.snapshot(.candidate)
        for index in literalInstalled.bundles.indices {
            literalInstalled.bundles[index].keychainAccessGroups = ["OLDPREFIX.*", "OLDPREFIX.owned.shared"]
            literalCandidate.bundles[index].keychainAccessGroups = ["OLDPREFIX.*", "OLDPREFIX.owned.shared"]
        }
        let literalDecision = Policy.evaluate(installed: literalInstalled, candidate: literalCandidate, at: Self.now)
        if case .metadataCompatible(let plan) = literalDecision {
            #expect(plan.authenticatedTransportGateStillRequired && plan.signedCandidateAndIdentityRevalidationStillRequired)
            #expect(!plan.cryptographicVerificationPerformed && !plan.signingPerformed && !plan.installationPerformed && !plan.renewalProven)
        } else {
            Issue.record("Identical synthetic literal keychain groups did not retain metadata compatibility")
        }
        var changedLiteral = literalCandidate
        changedLiteral.bundles[0].keychainAccessGroups = ["OTHERPREFIX.*", "OLDPREFIX.owned.shared"]
        #expect(Policy.evaluate(installed: literalInstalled, candidate: changedLiteral, at: Self.now) == .rejected(.groupsChanged(.application, .keychainAccessGroups)))
        changedLiteral = literalCandidate
        changedLiteral.bundles[0].keychainAccessGroups = ["OLDPREFIX.owned.shared", "OLDPREFIX.*"]
        #expect(Policy.evaluate(installed: literalInstalled, candidate: changedLiteral, at: Self.now) == .rejected(.groupsChanged(.application, .keychainAccessGroups)))
        changedLiteral = literalCandidate
        changedLiteral.bundles[0].keychainAccessGroups = ["OLDPREFIX." + changedLiteral.bundles[0].bundleIdentifier, "OLDPREFIX.owned.shared"]
        #expect(Policy.evaluate(installed: literalInstalled, candidate: changedLiteral, at: Self.now) == .rejected(.groupsChanged(.application, .keychainAccessGroups)))
        for malformed in ["*", ".*", "OLD*PREFIX.*", "OLDPREFIX.*.shared", "OLDPREFIX.**", "OLDPREFIX..*"] {
            var invalidCandidate = literalCandidate
            invalidCandidate.bundles[0].keychainAccessGroups = [malformed]
            #expect(Policy.evaluate(installed: literalInstalled, candidate: invalidCandidate, at: Self.now) == .rejected(.invalidGroups(.candidate, .application, .keychainAccessGroups)))
            var invalidInstalled = literalInstalled
            invalidInstalled.bundles[0].keychainAccessGroups = [malformed]
            #expect(Policy.evaluate(installed: invalidInstalled, candidate: literalCandidate, at: Self.now) == .rejected(.invalidGroups(.installed, .application, .keychainAccessGroups)))
        }
        var duplicateLiteral = literalCandidate
        duplicateLiteral.bundles[0].keychainAccessGroups = ["OLDPREFIX.*", "OLDPREFIX.*"]
        #expect(Policy.evaluate(installed: literalInstalled, candidate: duplicateLiteral, at: Self.now) == .rejected(.invalidGroups(.candidate, .application, .keychainAccessGroups)))
        var wildcardAppGroup = literalCandidate
        wildcardAppGroup.bundles[0].appGroups = ["group.owned.*"]
        #expect(Policy.evaluate(installed: literalInstalled, candidate: wildcardAppGroup, at: Self.now) == .rejected(.invalidGroups(.candidate, .application, .appGroups)))
    }

    @Test("Unverified and partial material, expired/future/invalid windows never pass")
    func rejectsUnverifiedExpiredOrInvalidCandidateMaterial() {
        let old = Self.snapshot(.installed)
        var candidate = Self.snapshot(.candidate); candidate.evidence = .unverified
        #expect(Policy.evaluate(installed: old, candidate: candidate, at: Self.now) == .rejected(.unverifiedSnapshot(.candidate)))
        var unverifiedOld = old; unverifiedOld.evidence = .unverified
        #expect(Policy.evaluate(installed: unverifiedOld, candidate: Self.snapshot(.candidate), at: Self.now) == .rejected(.unverifiedSnapshot(.installed)))
        candidate = Self.snapshot(.candidate)
        candidate.evidence = .platformAdapterAssertion(kind: .installed, completeInventory: true, binding: UUID())
        #expect(Policy.evaluate(installed: old, candidate: candidate, at: Self.now) == .rejected(.wrongSnapshotKind(.candidate)))
        candidate = Self.snapshot(.candidate); candidate.accountIdentity = nil
        #expect(Policy.evaluate(installed: old, candidate: candidate, at: Self.now) == .rejected(.accountIdentityUnavailable(.candidate)))
        candidate = Self.snapshot(.candidate); candidate.bundles[1].authorizationValidity = nil
        #expect(Policy.evaluate(installed: old, candidate: candidate, at: Self.now) == .rejected(.candidateValidityUnknown(.widgetExtension)))
        candidate = Self.snapshot(.candidate)
        candidate.bundles[2].authorizationValidity = .init(notBefore: Self.now.addingTimeInterval(-10), expiresAt: Self.now)
        #expect(Policy.evaluate(installed: old, candidate: candidate, at: Self.now) == .rejected(.candidateExpired(.shareExtension)))
        candidate = Self.snapshot(.candidate)
        candidate.bundles[0].authorizationValidity = .init(notBefore: Self.now.addingTimeInterval(1), expiresAt: Self.now.addingTimeInterval(2))
        #expect(Policy.evaluate(installed: old, candidate: candidate, at: Self.now) == .rejected(.candidateNotYetValid(.application)))
        candidate = Self.snapshot(.candidate)
        candidate.bundles[0].authorizationValidity = .init(notBefore: Self.now, expiresAt: Self.now)
        #expect(Policy.evaluate(installed: old, candidate: candidate, at: Self.now) == .rejected(.invalidValidity(.candidate, .application)))
        #expect(Policy.evaluate(installed: old, candidate: Self.snapshot(.candidate), at: Date(timeIntervalSinceReferenceDate: .nan)) == .rejected(.invalidEvaluationTime))
    }

    @Test("Same version/build and expired old authorization yield metadata compatibility only")
    func sameVersionAndBuildYieldOnlyMetadataPreflight() throws {
        var old = Self.snapshot(.installed)
        var candidate = Self.snapshot(.candidate)
        for index in old.bundles.indices {
            old.bundles[index].authorizationValidity = .init(notBefore: Self.now.addingTimeInterval(-20), expiresAt: Self.now.addingTimeInterval(-10))
            old.bundles[index].appGroups = []; old.bundles[index].keychainAccessGroups = []
            candidate.bundles[index].appGroups = []; candidate.bundles[index].keychainAccessGroups = []
        }
        candidate.bundles[1].authorizationValidity = .init(notBefore: Self.now, expiresAt: Self.now.addingTimeInterval(5))
        candidate.bundles.reverse() // mapping is by role, not input order
        let decision = Policy.evaluate(installed: old, candidate: candidate, at: Self.now)
        guard case .metadataCompatible(let plan) = decision else { Issue.record("Expected synthetic metadata compatibility only"); return }
        #expect(plan.bundles.map(\.role) == Policy.BundleRole.allCases)
        #expect(plan.bundles.allSatisfy { $0.version == "1.2.0" && $0.build == "12" })
        #expect(plan.candidateAuthorizationExpiresAt == Self.now.addingTimeInterval(5))
        #expect(plan.authenticatedTransportGateStillRequired && plan.realSigningAdapterStillRequired)
        #expect(plan.signedCandidateAndIdentityRevalidationStillRequired && plan.installationAndDataRetentionVerificationStillRequired)
        #expect(!plan.cryptographicVerificationPerformed && !plan.deviceVerificationPerformed)
        #expect(!plan.signingPerformed && !plan.installationPerformed && !plan.renewalProven)
        // No real certificate/profile/account/device was read or attested here.
        var changedBuild = candidate
        for index in changedBuild.bundles.indices { changedBuild.bundles[index].build = "11" }
        #expect(Policy.evaluate(installed: old, candidate: changedBuild, at: Self.now) == .rejected(.buildChangeOutsideRenewalScope(.application)))
    }

    private static func snapshot(_ kind: Policy.SnapshotKind) -> Policy.Snapshot {
        let main = "owned.example.reader"
        let roles = Policy.BundleRole.allCases
        let bundles = roles.map { role in
            let identifier: String
            switch role {
            case .application: identifier = main
            case .widgetExtension: identifier = main + ".owned-widget"
            case .shareExtension: identifier = main + ".owned-share"
            }
            return Policy.BundleSnapshot(role: role, bundleIdentifier: identifier,
                parentBundleIdentifier: role == .application ? nil : main, teamIdentifier: "OWNEDTEAM",
                applicationIdentifierPrefix: "OLDPREFIX", applicationIdentifier: "OLDPREFIX." + identifier,
                version: "1.2.0", build: "12", appGroups: ["group.owned.shared"],
                keychainAccessGroups: ["OLDPREFIX.owned.shared"],
                authorizationValidity: .init(notBefore: now.addingTimeInterval(-1), expiresAt: now.addingTimeInterval(100)))
        }
        return Policy.Snapshot(evidence: .platformAdapterAssertion(kind: kind, completeInventory: true, binding: UUID()),
                               accountIdentity: "owned-local-account-binding", bundles: bundles)
    }
}
