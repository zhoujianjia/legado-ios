import CryptoKit
import Foundation
import Testing
@testable import yuedu_app

@Suite("Owned CMS signatures and explicit certificate anchors, no Apple authority")
struct SelfRenewalCMSVerifierTests {
    private typealias CMS = SelfRenewalCMSVerifier
    private typealias Fixture = SelfRenewalCMSFixture

    @Test("OpenSSL RSA attributed, direct, detached and SKI signatures verify actual bytes")
    func verifiesIndependentRSAAndDetachedVectors() async throws {
        try await Task.detached {
            for message in [Fixture.embedded, Fixture.noAttributes, Fixture.subjectKeyIdentifier] {
                let verified = try CMS.verify(message, anchors: [Fixture.rootCertificate], at: Fixture.validationDate)
                #expect(verified.content == Fixture.profilePayload)
                #expect(verified.signers.count == 1)
                let signer = try #require(verified.signers.first)
                #expect(signer.certificateSHA256 == Data(SHA256.hash(data: Fixture.leafCertificate)))
                #expect(signer.signatureVerified && signer.chainValidatedToExplicitAnchors)
                #expect(!signer.appleProvisioningAuthorityEstablished)
                #expect(!verified.accountIdentityEstablished && !verified.replacementAuthorized)
            }
            let detached = try CMS.verify(Fixture.detached, detachedContent: Fixture.profilePayload,
                anchors: [Fixture.rootCertificate], at: Fixture.validationDate)
            #expect(detached.content == Fixture.profilePayload)
        }.value
    }

    @Test("ECDSA SHA384 and two different signer certificates are independently verified")
    func verifiesECDSAAndEverySigner() async throws {
        try await Task.detached {
            let ec = try CMS.verify(Fixture.ecdsaSHA384, anchors: [Fixture.rootCertificate], at: Fixture.validationDate)
            #expect(ec.content == Fixture.profilePayload && ec.signers.count == 1)
            let multiple = try CMS.verify(Fixture.multipleSigners, anchors: [Fixture.rootCertificate], at: Fixture.validationDate)
            #expect(multiple.signers.count == 2)
            #expect(Set(multiple.signers.map(\.certificateSHA256)).count == 2)
            #expect(multiple.signers.allSatisfy { $0.explicitAnchorSHA256 == [Data(SHA256.hash(data: Fixture.rootCertificate))] })
        }.value
    }

    @Test("Changed content and direct signature bytes fail actual cryptographic verification")
    func rejectsChangedContentAndSignatures() async throws {
        try await Task.detached {
            var contentTamper = Fixture.embedded
            let payload = try #require(contentTamper.range(of: Fixture.profilePayload))
            contentTamper[payload.lowerBound] ^= 1
            #expect(throws: CMS.Failure.digestMismatch) {
                try CMS.verify(contentTamper, anchors: [Fixture.rootCertificate], at: Fixture.validationDate)
            }
            var signatureTamper = Fixture.noAttributes
            signatureTamper[signatureTamper.endIndex - 1] ^= 1
            #expect(throws: CMS.Failure.invalidSignature) {
                try CMS.verify(signatureTamper, anchors: [Fixture.rootCertificate], at: Fixture.validationDate)
            }
            var changedDetached = Fixture.profilePayload
            changedDetached[changedDetached.startIndex] ^= 1
            #expect(throws: CMS.Failure.digestMismatch) {
                try CMS.verify(Fixture.detached, detachedContent: changedDetached,
                    anchors: [Fixture.rootCertificate], at: Fixture.validationDate)
            }
        }.value
    }

    @Test("Unrelated anchors and expired certificates cannot pass generic chain validation")
    func rejectsUntrustedAndExpiredChains() async throws {
        try await Task.detached {
            #expect(throws: CMS.Failure.untrustedChain) {
                try CMS.verify(Fixture.ecdsaSHA384, anchors: [Fixture.leafCertificate], at: Fixture.validationDate)
            }
            #expect(throws: CMS.Failure.untrustedChain) {
                try CMS.verify(Fixture.embedded, anchors: [Fixture.rootCertificate],
                    at: Fixture.validationDate.addingTimeInterval(12 * 366 * 86_400))
            }
            #expect(throws: CMS.Failure.untrustedChain) {
                try CMS.verify(Fixture.embedded, anchors: [Fixture.rootCertificate], at: Date(timeIntervalSince1970: 0))
            }
        }.value
    }

    @Test("Detached and encapsulated content are never confused or silently substituted")
    func rejectsMissingAndAmbiguousContent() async throws {
        try await Task.detached {
            #expect(throws: CMS.Failure.missingContent) {
                try CMS.verify(Fixture.detached, anchors: [Fixture.rootCertificate], at: Fixture.validationDate)
            }
            #expect(throws: CMS.Failure.ambiguousContent) {
                try CMS.verify(Fixture.embedded, detachedContent: Fixture.profilePayload,
                    anchors: [Fixture.rootCertificate], at: Fixture.validationDate)
            }
        }.value
    }

    @Test("DER truncation, trailing bytes, indefinite lengths and hard bounds reject input")
    func rejectsMalformedDERAndOversizedInputs() async throws {
        try await Task.detached {
            var nestedAttribute = Fixture.embedded
            let signingTimeMarker = Data([0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,1,9,5,0x31,0x0f,0x17,0x0d])
            let marker = try #require(nestedAttribute.range(of: signingTimeMarker))
            // Claim a constructed value whose time bytes are invalid nested DER.
            // Reject its encoding before considering the now-invalid signature.
            nestedAttribute[marker.lowerBound + 13] = 0x37
            for malformed in [Data(Fixture.embedded.dropLast()), Fixture.embedded + Data([0]), Data([0x30,0x80,0,0]), nestedAttribute] {
                #expect(throws: CMS.Failure.malformedDER) {
                    try CMS.verify(malformed, anchors: [Fixture.rootCertificate], at: Fixture.validationDate)
                }
            }
            #expect(throws: CMS.Failure.sizeLimit) {
                try CMS.verify(Data(repeating: 0, count: CMS.Limits.messageBytes + 1),
                    anchors: [Fixture.rootCertificate], at: Fixture.validationDate)
            }
            #expect(throws: CMS.Failure.invalidAnchors) {
                try CMS.verify(Fixture.embedded, anchors: [], at: Fixture.validationDate)
            }
            #expect(throws: CMS.Failure.invalidAnchors) {
                try CMS.verify(Fixture.embedded, anchors: [Fixture.rootCertificate, Fixture.rootCertificate], at: Fixture.validationDate)
            }
            #expect(throws: CMS.Failure.invalidAnchors) {
                try CMS.verify(Fixture.embedded, anchors: [Data(repeating: 0, count: CMS.Limits.certificateBytes + 1)], at: Fixture.validationDate)
            }
        }.value
    }

    @Test("Cancellation is checked before the first CMS or certificate operation")
    func rejectsCancelledVerification() async throws {
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) {
                try CMS.verify(Fixture.embedded, anchors: [Fixture.rootCertificate], at: Fixture.validationDate)
            }
        }
        await task.value
    }
}
