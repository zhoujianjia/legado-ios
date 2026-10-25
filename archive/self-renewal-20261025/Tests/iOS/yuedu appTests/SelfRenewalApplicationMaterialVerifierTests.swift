import Foundation
import Testing
@testable import yuedu_app

@Suite("Whole owned app, two extensions, CMS, resources, DER profiles and identities")
struct SelfRenewalApplicationMaterialVerifierTests {
    private typealias Verifier = SelfRenewalApplicationMaterialVerifier
    private typealias Fixture = SelfRenewalApplicationMaterialFixture
    private typealias Trust = SelfRenewalCMSFixture

    @Test("Real three-bundle bytes traverse one inventory through code/CMS/resources/nested/modern profiles")
    func verifiesActualThreeBundleChainWithoutClaimingAppleAuthority() async throws {
        try await Self.withFixture { root in
            let materials = try await Self.read(root)
            #expect(materials.bundles.count == 3 && materials.profiles.profiles.count == 3)
            #expect(materials.resources.executableMaterials.inventory.issues.isEmpty)
            #expect(materials.resources.executableMaterials.inventory == materials.profiles.inventory)
            #expect(materials.resources.resourceEnvelopesVerified && materials.profileAndCodeIdentityConsistencyVerified)
            #expect(Set(materials.bundles.compactMap(\.role)) == Set(SelfRenewalReplacementPolicy.BundleRole.allCases))
            for bundle in materials.bundles {
                let slice = try #require(bundle.slices.first)
                #expect(bundle.profileResourceBinding == .matched([2]))
                #expect(bundle.slices.count == 1 && slice.teamIdentifier == "FIXTURE123")
                #expect(slice.applicationIdentifierPrefix == "OLDPREFIX")
                #expect(slice.applicationIdentifier == "OLDPREFIX." + bundle.bundleIdentifier)
                #expect(slice.codeDirectoryTeamIdentifier == "FIXTURE123")
                #expect(slice.appGroups == ["group.test.owned.reader"])
                #expect(slice.keychainAccessGroups == ["OLDPREFIX." + bundle.bundleIdentifier, "OLDPREFIX.shared"])
                #expect(slice.unassessedEntitlementKeys == ["get-task-allow"])
                #expect(!bundle.appleAuthorizationEstablished)
            }
            #expect(!materials.appleSigningAuthorityEstablished && !materials.fullEntitlementAuthorizationEstablished)
            #expect(!materials.accountIdentityEstablished && !materials.deviceEligibilityEstablished && !materials.replacementAuthorized)
        }
        // The detached worker only returns actual observations or throws. All
        // Testing assertions remain in this parent case, avoiding orphan issues.
        let groups = try await Self.readOwnedGroupClaimVectors()
        #expect(groups.componentCount == 3 && groups.profileCount == 3)
        #expect(groups.keychainGroups == [["OLDPREFIX.*"]])
        #expect(groups.actualReads == 8)
        #expect(groups.failures == [
            .keychainGroupNotInProfile("."), .keychainGroupNotInProfile("."),
            .keychainGroupNotInProfile("."), .keychainGroupNotInProfile("."),
            .keychainGroupNotInProfile("."), .keychainGroupNotInProfile("."),
            .groupNotInProfile(".")])
    }

    @Test("Independently valid signatures cannot hide wrong signer certificate, team, App ID or groups")
    func rejectsSignedButInconsistentProfileAndEntitlementIdentities() async throws {
        try await Self.withFixture { root in
            let cases: [(Fixture.Bundle, Verifier.Failure)] = [
                (Fixture.wrongSigner, .signerNotInProfile(".")),
                (Fixture.wrongTeam, .teamMismatch(".")),
                (Fixture.wrongApplication, .applicationIdentifierMismatch(".")),
                (Fixture.wrongGroup, .groupNotInProfile(".")),
            ]
            for (bundle, error) in cases {
                try Self.write(bundle, at: root)
                await #expect(throws: error) { try await Self.read(root) }
            }
        }
    }

    @Test("Later profile reads must match any earlier verified resource seal, even for another valid CMS of equal size")
    func bindsRereadProfileBytesToEarlierResourceSeals() async throws {
        try await Self.withFixture { root in
            let code = try await SelfRenewalSignedCodeVerifier.read(unpackedApplication: root,
                anchors: [Trust.rootCertificate], at: Trust.validationDate)
            let resources = try await SelfRenewalResourceSealVerifier.verify(unpackedApplication: root, executableMaterials: code)
            let changed = try Self.bytes(Fixture.changedProfile.profileBase64)
            let initial = try Self.bytes(Fixture.bundles[0].profileBase64)
            #expect(changed.count == initial.count && changed != initial)
            try changed.write(to: root.appendingPathComponent("embedded.mobileprovision"))
            let profiles = try await SelfRenewalProvisioningProfileVerifier.readModern(unpackedApplication: root,
                inventory: code.inventory, anchors: [Trust.rootCertificate], at: Trust.validationDate)
            let rejected = Task.detached {
                try Verifier.bind(resources: resources, profiles: profiles)
            }
            await #expect(throws: Verifier.Failure.changedProfileResource(".")) { try await rejected.value }
        }
    }

    @Test("Renewed profile UUID can change while the signed bundle, App ID, groups and default keychain group stay identical")
    func acceptsNewProfileUUIDWithPreservedBundleGroupsAndIdentity() async throws {
        try await Self.withFixture { root in
            let before = try await Self.read(root)
            try Self.write(Fixture.changedProfile, at: root)
            let after = try await Self.read(root)
            let old = try #require(before.bundles.first { $0.role == .application })
            let new = try #require(after.bundles.first { $0.role == .application })
            #expect(old.profileUUID != new.profileUUID)
            #expect(old.bundleIdentifier == new.bundleIdentifier && old.slices == new.slices)
            #expect(after.profileAndCodeIdentityConsistencyVerified && !after.replacementAuthorized)
        }
    }

    @Test("Whole-chain reads reject actual changed resources, authoritative profile expiry and cancellation")
    func rejectsWholeChainResourceTamperingExpiryAndCancellation() async throws {
        try await Self.withFixture { root in
            try Data("abd".utf8).write(to: root.appendingPathComponent("chapter.txt"))
            await #expect(throws: SelfRenewalResourceSealVerifier.Failure.digestMismatch("chapter.txt")) { try await Self.read(root) }
            try Data("abc".utf8).write(to: root.appendingPathComponent("chapter.txt"))
            await #expect(throws: SelfRenewalProvisioningProfileVerifier.Failure.profileExpired) {
                try await Verifier.read(unpackedApplication: root, codeAnchors: [Trust.rootCertificate],
                    profileAnchors: [Trust.rootCertificate], at: Date(timeIntervalSince1970: 1_924_992_000))
            }
            let cancelled = Task.detached { () async throws -> Void in
                withUnsafeCurrentTask { $0?.cancel() }
                _ = try await Self.read(root)
            }
            await #expect(throws: CancellationError.self) { try await cancelled.value }
        }
    }

    private enum GroupClaimFixtureFailure: Error {
        case invalidPublicBytes, missingObservation, rejectedVectorWasAccepted, cleanupFailed
    }
    private static func readOwnedGroupClaimVectors() async throws -> (
        componentCount: Int, profileCount: Int, keychainGroups: [[String]],
        failures: [Verifier.Failure], actualReads: Int) {
        try await Task.detached(priority: .utility) {
            let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("owned-group-claim-" + UUID().uuidString)
            let root = directory.appendingPathComponent("Owned.app")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            func write(_ bundle: Fixture.Bundle) throws {
                let target = bundle.relativePath == "." ? root : root.appendingPathComponent(bundle.relativePath)
                try FileManager.default.createDirectory(at: target.appendingPathComponent("_CodeSignature"), withIntermediateDirectories: true)
                for (path, encoded) in [("Info.plist", bundle.infoBase64), ("embedded.mobileprovision", bundle.profileBase64),
                                        ("_CodeSignature/CodeResources", bundle.resourcesBase64), ("Owned", bundle.codeBase64)] {
                    guard let bytes = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
                        throw GroupClaimFixtureFailure.invalidPublicBytes
                    }
                    try bytes.write(to: target.appendingPathComponent(path))
                }
                try Data("abc".utf8).write(to: target.appendingPathComponent("chapter.txt"))
            }
            do {
                for bundle in Fixture.bundles { try write(bundle) }
                typealias Groups = SelfRenewalGroupClaimCompatibilityFixture
                try write(Groups.exactWildcard)
                let positive = try await Self.read(root)
                guard let application = positive.bundles.first(where: { $0.componentRelativePath == "." }),
                      !application.slices.isEmpty else { throw GroupClaimFixtureFailure.missingObservation }
                let observedGroups = application.slices.map(\.keychainAccessGroups)
                var failures: [Verifier.Failure] = []
                for vector in [Groups.broaderWildcard, Groups.middleWildcard, Groups.bareWildcard,
                               Groups.crossPrefix, Groups.narrowerWildcard, Groups.wildcardAgainstConcrete,
                               Groups.appGroupWildcard] {
                    try write(vector)
                    do {
                        _ = try await Self.read(root)
                        throw GroupClaimFixtureFailure.rejectedVectorWasAccepted
                    } catch let failure as Verifier.Failure { failures.append(failure) }
                }
                try FileManager.default.removeItem(at: directory)
                return (componentCount: positive.bundles.count, profileCount: positive.profiles.profiles.count,
                    keychainGroups: observedGroups, failures: failures, actualReads: 1 + failures.count)
            } catch {
                let original = error
                do { try FileManager.default.removeItem(at: directory) }
                catch { throw GroupClaimFixtureFailure.cleanupFailed }
                throw original
            }
        }.value
    }
    private static func read(_ root: URL) async throws -> Verifier.Materials {
        try await Verifier.read(unpackedApplication: root, codeAnchors: [Trust.rootCertificate],
            profileAnchors: [Trust.rootCertificate], at: Trust.validationDate)
    }
    private static func bytes(_ encoded: String) throws -> Data {
        try #require(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
    }
    private static func write(_ bundle: Fixture.Bundle, at root: URL) throws {
        let directory = bundle.relativePath == "." ? root : root.appendingPathComponent(bundle.relativePath)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("_CodeSignature"), withIntermediateDirectories: true)
        for (path, encoded) in [("Info.plist", bundle.infoBase64), ("embedded.mobileprovision", bundle.profileBase64),
                                ("_CodeSignature/CodeResources", bundle.resourcesBase64), ("Owned", bundle.codeBase64)] {
            try bytes(encoded).write(to: directory.appendingPathComponent(path))
        }
        try Data("abc".utf8).write(to: directory.appendingPathComponent("chapter.txt"))
    }
    private static func withFixture(_ action: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("material-owned-" + UUID().uuidString)
        let root = directory.appendingPathComponent("Owned.app")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        for bundle in Fixture.bundles { try write(bundle, at: root) }
        try await action(root)
    }
}
