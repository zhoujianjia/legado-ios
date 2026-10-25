import CryptoKit
import Foundation
import Testing
@testable import yuedu_app

@Suite("Actual modern DER profile CMS and bounded typed properties")
struct SelfRenewalModernProfileVerifierTests {
    private typealias Decoder = SelfRenewalDERPropertyList
    private typealias Profile = SelfRenewalProvisioningProfileVerifier
    private typealias Fixture = SelfRenewalModernProfileFixture
    private typealias Trust = SelfRenewalCMSFixture

    @Test("Independent DER plist distinguishes booleans, integers, bytes, arrays, null and dates")
    func decodesIndependentTypedPropertyValues() throws {
        let value = try Decoder.decode(Fixture.propertyValues)
        #expect(value == .dictionary([
            "array": .array([.boolean(true), .boolean(false), .integer(0), .integer(-1), .integer(-129),
                             .integer(128), .string("text"), .data(Data([0, 255])), .null]),
            "utc": .date(Date(timeIntervalSince1970: 1_924_992_000)), "nested": .dictionary(["key": .string("value")]),
        ]))
        let xml: [String: Any] = ["enabled": true, "count": 128, "bytes": Data([0, 255]), "array": ["a", "b"]]
        let data = try PropertyListSerialization.data(fromPropertyList: xml, format: .xml, options: 0)
        #expect(try Decoder.decodeXMLPropertyList(data) == .dictionary([
            "enabled": .boolean(true), "count": .integer(128), "bytes": .data(Data([0, 255])),
            "array": .array([.string("a"), .string("b")]),
        ]))
    }

    @Test("Versioned application-tag16 entitlements use the inner context dictionary")
    func decodesVersionedCoreEntitlementsAndRejectsUnknownVersion() throws {
        #expect(try Decoder.decode(Fixture.entitlements) == .dictionary([
            "identifier": .string("owned.reader"), "enabled": .boolean(true),
            "groups": .array([.string("a"), .string("b")]), "count": .integer(-129),
        ]))
        #expect(try Decoder.decode(Data([0x70, 5, 2, 1, 1, 0xb0, 0])) == .dictionary([:]))
        #expect(throws: Decoder.Failure.unsupportedValue) {
            try Decoder.decode(Data([0x70, 5, 2, 1, 2, 0xb0, 0]))
        }
        #expect(throws: Decoder.Failure.unsupportedValue) {
            try Decoder.decode(Data([0x70, 3, 2, 1, 1]))
        }
    }

    @Test("Canonical DER rejects duplicate dictionary keys, invalid primitive encodings and trailing bytes")
    func rejectsAmbiguousAndMalformedProperties() throws {
        let pair = Data([0x30, 6, 0x0c, 1, 0x61, 0x02, 1, 1])
        #expect(throws: Decoder.Failure.duplicateKey) { try Decoder.decode(Self.wire(0x31, pair + pair)) }
        for bytes: [UInt8] in [
            [0x01, 1, 1], [0x02, 2, 0, 1], [0x02, 0], [0x0c, 1, 0xff],
            [0x30, 0x80, 0, 0], [0x04, 0x81, 1, 0], [0x05, 1, 0], [0x30, 0, 0],
        ] {
            #expect(throws: SelfRenewalCMSVerifier.Failure.self) { try Decoder.decode(Data(bytes)) }
        }
        #expect(throws: Decoder.Failure.unsupportedValue) { try Decoder.decode(Self.wire(0x02, Data(repeating: 0x11, count: 9))) }
    }

    @Test("UTC and generalized times retain canonical year boundaries and reject normalized invalid dates")
    func decodesCanonicalDatesAndRejectsInvalidCalendarValues() throws {
        #expect(try Decoder.decode(Self.wire(0x17, Data("500101000000Z".utf8))) == .date(Date(timeIntervalSince1970: -631_152_000)))
        #expect(try Decoder.decode(Self.wire(0x17, Data("490101000000Z".utf8))) == .date(Date(timeIntervalSince1970: 2_493_072_000)))
        #expect(try Decoder.decode(Self.wire(0x18, Data("20310101000000.125Z".utf8))) == .date(Date(timeIntervalSince1970: 1_924_992_000.125)))
        for text in ["310230000000Z", "311301000000Z", "310101240000Z", "310101000060Z", "310101000000+0000"] {
            #expect(throws: Decoder.Failure.invalidDate) { try Decoder.decode(Self.wire(0x17, Data(text.utf8))) }
        }
        #expect(throws: Decoder.Failure.invalidDate) { try Decoder.decode(Self.wire(0x18, Data("20310101000000.10Z".utf8))) }
    }

    @Test("Byte/depth budgets and caller cancellation stop property decoding")
    func enforcesPropertyBudgetsAndCancellation() async throws {
        #expect(throws: Decoder.Failure.sizeLimit) { try Decoder.decode(Data(repeating: 0, count: Decoder.Limits.bytes + 1)) }
        var deep = Data([0x05, 0])
        for _ in 0...Decoder.Limits.depth { deep = Self.wire(0x30, deep) }
        #expect(throws: SelfRenewalCMSVerifier.Failure.sizeLimit) { try Decoder.decode(deep) }
        let cancelled = Task.detached { () throws -> Void in
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try Decoder.decode(Fixture.derPayload)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }

    @Test("Both actual CMS signatures pass and authoritative DER wins over unrelated expired legacy XML")
    func authenticatesBothCMSLayersAndUsesModernSourceOfTruth() async throws {
        try await Task.detached {
            let profile = try Self.verify(Fixture.modern)
            #expect(profile.summary.uuid == "11111111-2222-3333-4444-555555555555")
            #expect(profile.summary.teamIdentifiers == ["FIXTURE123"])
            #expect(profile.summary.applicationIdentifierPrefixes == ["OLDPREFIX"])
            #expect(profile.summary.applicationIdentifier == "OLDPREFIX.test.owned.reader")
            #expect(profile.summary.entitlementTeamIdentifier == "FIXTURE123")
            #expect(profile.summary.developerCertificateSHA256 == [Data(SHA256.hash(data: Trust.leafCertificate))])
            #expect(profile.outerEnvelope.signers.count == 1 && profile.derEnvelope.signers.count == 1)
            #expect(profile.rawFileDigests[2] == Data(SHA256.hash(data: Fixture.modern)))
            #expect(profile.sourceOfTruthCryptographicallyAuthenticated)
            #expect(!profile.appleProvisioningAuthorityEstablished && !profile.entitlementAuthorizationEstablished)
            #expect(!profile.summary.authorizationVerified)
        }.value
    }

    @Test("A valid outer signature never covers tampered/untrusted inner CMS or expired/future authoritative dates")
    func rejectsInvalidInnerCMSAndAuthoritativeValidity() async throws {
        try await Task.detached {
            #expect(throws: SelfRenewalCMSVerifier.Failure.digestMismatch) { try Self.verify(Fixture.badInner) }
            #expect(throws: SelfRenewalCMSVerifier.Failure.untrustedChain) { try Self.verify(Fixture.untrustedInner) }
            #expect(throws: Profile.Failure.profileExpired) { try Self.verify(Fixture.expired) }
            #expect(throws: Profile.Failure.profileNotYetValid) { try Self.verify(Fixture.future) }
            // A different certificate hash is a signed profile observation; the
            // whole-app binding must compare it to the actual code signer.
            let different = try Self.verify(Fixture.wrongCertificateHash)
            #expect(different.summary.developerCertificateSHA256 == [Data(repeating: 0x44, count: 32)])
            #expect(!different.entitlementAuthorizationEstablished)
        }.value
    }

    @Test("Existing inventory feeds actual no-follow profile bytes without a second directory scan")
    func readsModernProfileFromSameInventoryAndRejectsReplacedLinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("modern-owned-" + UUID().uuidString + ".app")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let info = try #require(Data(base64Encoded: SelfRenewalResourceFixture.infoBase64))
        try info.write(to: root.appendingPathComponent("Info.plist"))
        try Data([0xcf, 0xfa, 0xed, 0xfe]).write(to: root.appendingPathComponent("Owned"))
        let path = root.appendingPathComponent("embedded.mobileprovision")
        try Fixture.modern.write(to: path)
        let inventory = try await SelfRenewalMaterialInventory.read(unpackedApplication: root)
        let materials = try await Profile.readModern(unpackedApplication: root, inventory: inventory,
            anchors: [Trust.rootCertificate], at: Trust.validationDate)
        #expect(materials.inventory == inventory && materials.profiles.count == 1)
        #expect(materials.profileBytesRead == Fixture.modern.count)
        #expect(!materials.accountIdentityEstablished && !materials.replacementAuthorized)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: root.appendingPathComponent("Info.plist"))
        await #expect(throws: SelfRenewalMachOSignatureReader.Failure.unreadableFile) {
            try await Profile.readModern(unpackedApplication: root, inventory: inventory,
                anchors: [Trust.rootCertificate], at: Trust.validationDate)
        }
    }

    private static func verify(_ data: Data) throws -> Profile.ModernProfile {
        try Profile.verifyModern(data, file: .init(relativePath: "embedded.mobileprovision", byteCount: Int64(data.count)),
            anchors: [Trust.rootCertificate], at: Trust.validationDate)
    }
    private static func wire(_ tag: UInt8, _ body: Data) -> Data {
        precondition(body.count < 128)
        return Data([tag, UInt8(body.count)]) + body
    }
}
