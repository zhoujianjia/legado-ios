import Foundation
import Testing
@testable import yuedu_app

@Suite("Actual nested CodeResources requirements, owned CMS bundles only")
struct SelfRenewalNestedCodeRequirementsVerifierTests {
    private typealias Requirements = SelfRenewalNestedCodeRequirementsVerifier
    private typealias Resources = SelfRenewalResourceSealVerifier
    private typealias Signed = SelfRenewalSignedCodeVerifier
    private typealias Reader = SelfRenewalMachOSignatureReader
    private typealias Value = SelfRenewalDERPropertyList.Value
    private typealias Fixture = SelfRenewalNestedResourceFixture
    private static let child = "Frameworks/Child.framework"
    private static let anchors = [SelfRenewalCMSFixture.rootCertificate]
    private static let date = SelfRenewalCMSFixture.validationDate

    @Test("Full expression syntax evaluates actual identity, certificate, Info and entitlement matches")
    func evaluatesBooleanCertificateAndAttributeGrammar() async throws {
        try await Task.detached {
            let attributes = Self.attributes
            let positives = [
                "true and !false or never", "/* owned */ (identifier owned.child) and always; # eof",
                "certificate leaf = H\"\(Fixture.leafSHA1)\" and anchor = H\"\(Fixture.rootSHA1)\"",
                "cert 0[subject.CN] = \"Yuedu Owned Fixture leaf\" and cert -1[subject.CN] = \"Yuedu Owned Fixture Root\"",
                "certificate root[extension.2.5.29.19] exists and cert leaf[policy.1.2.3.4] absent",
                "identifier == \"owned.child\" and platform = 2 and cdhash H\"\(String(repeating: "12", count: 20))\"",
                "info[name] = \"Book\"* and info[name] = *\"Name\" and info[name] = *\"ook Na\"*",
                "info[name] ~ \"ook\" and info[version] > \"2.9\" and info[version] <= \"2.10\"",
                "info[missing] absent and ! info[disabled] and info[disabled] absent or true",
                "entitlement[values] = 0x62657461 and entitlement[enabled] and ! entitlement[disabled]",
                "info[date] = timestamp \"20261020000000Z\" and info[date] >= timestamp \"20261019000000Z\"",
            ]
            for text in positives {
                let result = try Requirements.evaluate(text, attributes: attributes)
                #expect(result == .matched)
            }
            let negatives = ["identifier \"other\"", "info[disabled] absent", "info[enabled] = \"true\"",
                "certificate 12[subject.CN] absent", "certificate leaf[subject.OU] absent",
                "entitlement[missing] exists", "info[name] = \"book Name\"", "platform 3"]
            for text in negatives {
                let result = try Requirements.evaluate(text, attributes: attributes)
                #expect(result == .notMatched)
            }
        }.value
    }

    @Test("Malformed syntax and bounds reject; parsed OS policy remains explicitly unresolved")
    func preservesUnresolvedPolicyWithoutRejectingComplexSupportedExpressions() async throws {
        try await Task.detached {
            for text in ["", "identifier", "identifier true", "identifier bad..key", "true trailing", "(true", "true && false", "cdhash H\"12\"", "info[x] = \"bad\\n\"", "true /* missing"] {
                #expect(throws: (any Error).self) { try Requirements.evaluate(text, attributes: Self.attributes) }
            }
            #expect(throws: Requirements.Failure.limit) {
                try Requirements.evaluate(String(repeating: "!", count: 65) + "true", attributes: Self.attributes)
            }
            #expect(throws: Requirements.Failure.limit) {
                try Requirements.evaluate(String(repeating: " ", count: Requirements.Limits.textBytes + 1), attributes: Self.attributes)
            }
            let policies: [(String, Requirements.Capability)] = [
                ("anchor apple", .appleAnchor), ("anchor generic apple", .appleGenericAnchor),
                ("anchor apple generic", .appleGenericAnchor), ("anchor apple namedRoot", .namedAnchor("namedRoot")),
                ("certificate trusted", .trustSettings), ("cert -1 trusted", .trustSettings),
                ("notarized", .notarization), ("legacy", .legacyDeveloperID), ("(namedCode)", .namedCode("namedCode")),
                ("anchor = \"/owned/certificate\"", .externalCertificateFile("/owned/certificate")),
            ]
            for (text, capability) in policies {
                let result = try Requirements.evaluate("identifier owned.child and (\(text))", attributes: Self.attributes)
                #expect(result == .unresolved([capability]))
            }
        }.value
    }

    @Test("Four real CMS bundles recursively verify resources and every universal nested slice")
    func verifiesActualNestedBundlesAndPublishesBoundDERAttributes() async throws {
        for name in ["valid", "cdHashRequirement"] {
          try await Self.withFixture(name) { root in
            let materials = try await Self.signed(root)
            let result = try await Resources.verify(unpackedApplication: root, executableMaterials: materials)
            #expect(result.components.count == 4 && result.resourceEnvelopesVerified)
            #expect(result.codeAttributes.count == 4 && result.nestedAttributeBytesRead > 0)
            let parent = try #require(result.components.first { $0.relativePath == "." })
            #expect(parent.resources.verifiedNestedResources.count == 2)
            #expect(parent.resources.unresolvedNestedResources.isEmpty)
            let nested = try #require(parent.resources.verifiedNestedResources.first { $0.relativePath == Self.child })
            #expect(nested.verifiedSlices == 2 && nested.signerAuthenticatedSlices == 2)
            #expect(nested.cdHashHintMatchesAnySelectedDirectory == true)
            let loaded = try #require(result.codeAttributes[Self.child + "/Child"])
            #expect(loaded.slices.count == 2)
            for slice in loaded.slices {
                #expect(slice.attributes.identifier == "owned.child")
                #expect(slice.attributes.certificateChainDER == [SelfRenewalCMSFixture.leafCertificate, SelfRenewalCMSFixture.rootCertificate])
                let entitlements = try #require(slice.attributes.entitlements)
                guard case .dictionary(let values) = entitlements else { Issue.record("Missing actual DER dictionary"); return }
                #expect(values["com.owned.feature"] == .boolean(true))
            }
            #expect(!result.appleSigningAuthorityVerified && !result.replacementAuthorized)
          }
        }
    }

    @Test("False nested requirement, selected alternate identity and one wrong fat slice reject")
    func rejectsFalseRequirementAndWrongSelectedOrUniversalIdentity() async throws {
        for name in ["falseRequirement", "wrongIdentity", "fatMismatch"] {
            try await Self.withFixture(name) { root in
                let materials = try await Self.signed(root)
                await #expect(throws: Resources.Failure.nestedRequirementFailed(Self.child)) {
                    try await Resources.verify(unpackedApplication: root, executableMaterials: materials)
                }
            }
        }
    }

    @Test("cdhash hint does not replace requirements and legacy unbound alternate stays visible")
    func preservesHintAndLegacyAuthenticationMeaning() async throws {
        try await Self.withFixture("wrongHint") { root in
            let result = try await Resources.verify(unpackedApplication: root, executableMaterials: Self.signed(root))
            let parent = try #require(result.components.first { $0.relativePath == "." })
            let nested = try #require(parent.resources.verifiedNestedResources.first { $0.relativePath == Self.child })
            #expect(result.resourceEnvelopesVerified && nested.cdHashHintMatchesAnySelectedDirectory == false)
        }
        try await Self.withFixture("legacyUnbound") { root in
            let result = try await Resources.verify(unpackedApplication: root, executableMaterials: Self.signed(root))
            let parent = try #require(result.components.first { $0.relativePath == "." })
            let nested = try #require(parent.resources.verifiedNestedResources.first { $0.relativePath == Self.child })
            #expect(nested.verifiedSlices == 2 && nested.signerAuthenticatedSlices == 0)
            #expect(!nested.allSelectedDirectoriesSignerAuthenticated && !result.appleSigningAuthorityVerified)
        }
    }

    @Test("Unavailable Apple/system policy is retained as unresolved rather than fabricated authorization")
    func retainsActualSystemPolicyAsUnresolved() async throws {
        try await Self.withFixture("systemPolicy") { root in
            let result = try await Resources.verify(unpackedApplication: root, executableMaterials: Self.signed(root))
            let parent = try #require(result.components.first { $0.relativePath == "." })
            #expect(!result.resourceEnvelopesVerified)
            #expect(parent.resources.unresolvedNestedResources.map(\.relativePath) == [Self.child])
            #expect(parent.resources.unresolvedRequirementCapabilities == [.appleGenericAnchor, .appleGenericAnchor])
            #expect(!result.appleSigningAuthorityVerified && !result.replacementAuthorized)
        }
    }

    @Test("Actual nested resource or CMS signature tampering fails genuine verification")
    func rejectsNestedResourceAndCMSTampering() async throws {
        try await Self.withFixture("valid") { root in
            let materials = try await Self.signed(root)
            try await Task.detached {
                try Data("changed nested resource".utf8).write(to: root.appendingPathComponent(Self.child + "/child.txt"))
            }.value
            await #expect(throws: (any Error).self) {
                try await Resources.verify(unpackedApplication: root, executableMaterials: materials)
            }
            try await Task.detached {
                let files = try Fixture.files("valid")
                try #require(files[Self.child + "/child.txt"]).write(to: root.appendingPathComponent(Self.child + "/child.txt"))
                var code = try #require(files[Self.child + "/Child"])
                code[code.count - 1] ^= 1
                try code.write(to: root.appendingPathComponent(Self.child + "/Child"))
            }.value
            await #expect(throws: SelfRenewalCMSVerifier.Failure.invalidSignature) { try await Self.signed(root) }
        }
    }

    @Test("Earlier proof cannot bless changed Info or DER entitlements; cancellation stays effective")
    func rejectsChangedBoundAttributesAndCancellation() async throws {
        try await Self.withFixture("valid") { root in
            let materials = try await Self.signed(root)
            let child = try #require(materials.code.first { $0.file.relativePath == Self.child + "/Child" })
            let component = try #require(materials.inventory.components.first { $0.relativePath == Self.child })
            try await Task.detached {
                #expect(throws: Requirements.Failure.limit) {
                    try Requirements.load(root: root, code: child, component: component, files: materials.inventory.files,
                        maximumReadBytes: Requirements.Limits.attributeReadBytes + 1)
                }
                let files = try Fixture.files("valid")
                let old = try #require(files[Self.child + "/Info.plist"])
                let info = Data(String(decoding: old, as: UTF8.self).replacingOccurrences(of: ">1.0<", with: ">2.0<").utf8)
                try info.write(to: root.appendingPathComponent(Self.child + "/Info.plist"))
                #expect(throws: Requirements.Failure.unboundAttributes) {
                    try Requirements.load(root: root, code: child, component: component, files: materials.inventory.files,
                        maximumReadBytes: Requirements.Limits.attributeReadBytes)
                }
                try old.write(to: root.appendingPathComponent(Self.child + "/Info.plist"))
                var raw = try #require(files[Self.child + "/Child"])
                let slice = try #require(child.structure.slices.first)
                let signature = try #require(slice.signature)
                let der = try #require(signature.blobs.first { $0.slot == 7 })
                raw[Int(signature.range.offset + der.range.end) - 1] ^= 1
                try raw.write(to: root.appendingPathComponent(Self.child + "/Child"))
                #expect(throws: Requirements.Failure.unboundAttributes) {
                    try Requirements.load(root: root, code: child, component: component, files: materials.inventory.files,
                        maximumReadBytes: Requirements.Limits.attributeReadBytes)
                }
            }.value
            let cancelled = Task.detached { () throws -> Void in
                withUnsafeCurrentTask { $0?.cancel() }
                _ = try Requirements.load(root: root, code: child, component: component, files: materials.inventory.files,
                    maximumReadBytes: Requirements.Limits.attributeReadBytes)
            }
            await #expect(throws: CancellationError.self) { try await cancelled.value }
        }
    }

    private static var attributes: Requirements.Attributes {
        Requirements.Attributes(identifier: "owned.child", platform: 2, cdHash: Data(repeating: 0x12, count: 20),
            info: .dictionary(["name": .string("Book Name"), "version": .string("2.10"), "enabled": .boolean(true),
                "disabled": .boolean(false), "date": .date(Date(timeIntervalSince1970: 1_792_454_400))]),
            entitlements: .dictionary(["enabled": .boolean(true), "disabled": .boolean(false),
                "values": .array([.string("alpha"), .string("beta")])]),
            certificateChainDER: [SelfRenewalCMSFixture.leafCertificate, SelfRenewalCMSFixture.rootCertificate])
    }
    private static func signed(_ root: URL) async throws -> Reader.Materials {
        try await Signed.read(unpackedApplication: root, anchors: anchors, at: date)
    }
    private static func withFixture(_ name: String, _ action: (URL) async throws -> Void) async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("nested-owned-" + UUID().uuidString)
        let root = base.appendingPathComponent("Owned.app")
        try await Task.detached {
            for (path, bytes) in try Fixture.files(name) {
                let target = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: target)
            }
        }.value
        defer {
            do { try FileManager.default.removeItem(at: base) }
            catch { Issue.record("Owned nested fixture cleanup failed: \(error)") }
        }
        try await action(root)
    }
}
