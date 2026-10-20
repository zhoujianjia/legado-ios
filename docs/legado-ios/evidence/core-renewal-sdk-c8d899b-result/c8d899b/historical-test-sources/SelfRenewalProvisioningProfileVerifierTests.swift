import CryptoKit
import Foundation
import Testing
@testable import yuedu_app

@Suite("Owned provisioning CMS envelopes, authorization still unverified")
struct SelfRenewalProvisioningProfileVerifierTests {
    private typealias Profile = SelfRenewalProvisioningProfileVerifier
    private typealias Fixture = SelfRenewalCMSFixture

    @Test("Signed plist fields are observed with exact expiry boundaries and no entitlement authority")
    func readsSignedSummaryAndRejectsValidityFailures() async throws {
        try await Task.detached {
            let summary = try Profile.parseSignedPlist(Fixture.profilePayload, at: Fixture.validationDate)
            #expect(summary.teamIdentifiers == ["FIXTURE123"])
            #expect(summary.applicationIdentifier == "FIXTURE123.test.owned.reader")
            #expect(summary.developerCertificateSHA256 == [Data(SHA256.hash(data: Fixture.leafCertificate))])
            #expect(summary.containsDEREncodedProfile && !summary.authorizationVerified)
            #expect(throws: Profile.Failure.profileNotYetValid) {
                try Profile.parseSignedPlist(Fixture.profilePayload, at: summary.createdAt.addingTimeInterval(-1))
            }
            #expect(throws: Profile.Failure.profileExpired) {
                try Profile.parseSignedPlist(Fixture.profilePayload, at: summary.expiresAt)
            }
            #expect(throws: Profile.Failure.malformedProfile) {
                try Profile.parseSignedPlist(Data("<plist><dict/></plist>".utf8), at: Fixture.validationDate)
            }
        }.value
    }

    @Test("Owned app inventory feeds no-follow CMS reads and rejects unsigned or missing profiles")
    func verifiesOwnedProfileThroughInventory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("owned-profile-" + UUID().uuidString + ".app", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let plist: [String: Any] = ["CFBundleIdentifier":"test.owned.reader", "CFBundleExecutable":"Reader",
            "CFBundleShortVersionString":"1", "CFBundleVersion":"1", "CFBundlePackageType":"APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Info.plist"))
        try Data([0xcf,0xfa,0xed,0xfe]).write(to: root.appendingPathComponent("Reader"))
        let path = root.appendingPathComponent("embedded.mobileprovision")
        try Fixture.embedded.write(to: path)
        let result = try await Profile.read(unpackedApplication: root, anchors: [Fixture.rootCertificate], at: Fixture.validationDate)
        #expect(result.profiles.count == 1 && result.profileBytesRead == Fixture.embedded.count)
        let profile = try #require(result.profiles.first)
        #expect(profile.envelope.signers.allSatisfy(\.signatureVerified))
        #expect(!profile.appleProvisioningAuthorityEstablished && !profile.entitlementAuthorizationEstablished)
        #expect(!result.accountIdentityEstablished && !result.replacementAuthorized)
        try Fixture.profilePayload.write(to: path)
        await #expect(throws: SelfRenewalCMSVerifier.Failure.self) {
            try await Profile.read(unpackedApplication: root, anchors: [Fixture.rootCertificate], at: Fixture.validationDate)
        }
        try FileManager.default.removeItem(at: path)
        await #expect(throws: Profile.Failure.missingProfile) {
            try await Profile.read(unpackedApplication: root, anchors: [Fixture.rootCertificate], at: Fixture.validationDate)
        }
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: root.appendingPathComponent("Info.plist"))
        await #expect(throws: SelfRenewalMaterialInventory.Failure.linkNotAllowed) {
            try await Profile.read(unpackedApplication: root, anchors: [Fixture.rootCertificate], at: Fixture.validationDate)
        }
    }
}
