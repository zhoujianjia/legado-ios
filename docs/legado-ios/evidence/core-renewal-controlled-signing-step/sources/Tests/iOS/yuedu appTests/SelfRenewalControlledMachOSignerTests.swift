import Foundation
import Security
import Testing
@testable import yuedu_app

struct SelfRenewalControlledMachOSignerTests {
    private typealias Signer = SelfRenewalControlledMachOSigner
    private typealias Fixture = SelfRenewalControlledSigningFixture
    private typealias Reader = SelfRenewalMachOSignatureReader
    private typealias Hashes = SelfRenewalCodeDirectoryHashVerifier
    private static let date = Date(timeIntervalSince1970: 1_792_540_800) // 2026-10-21 UTC

    @Test("In-memory RSA and EC keys create actual detached CMS authenticated to their actual certificate")
    func signsRealRSAAndECDSAAndAuthenticatesActualLeaf() async throws {
        for ec in [false, true] {
            let identity = try await Self.identity(ec: ec)
            for (encoded, anchor) in [(Fixture.sha256Base64, Fixture.originalRSAAnchorBase64),
                                      (Fixture.ecOriginalBase64, Fixture.originalECAnchorBase64)] {
                let input = try Fixture.data(encoded)
                let result = try await Self.sign(input, identity: identity, anchor: Fixture.data(anchor))
                #expect(result.signatures.allLoadedDirectoriesAuthenticated)
                let certificateHash = try Hashes.digest(identity.certificateChainDER[0], hashType: 2)
                #expect(result.signatures.slices[0].signers[0].certificateSHA256 == certificateHash)
                let cms = try await Task.detached {
                    try SelfRenewalCMSVerifier.verify(result.detachedCMS, detachedContent: result.codeDirectories[0],
                        anchors: identity.certificateChainDER, at: Self.date)
                }.value
                #expect(cms.content == result.codeDirectories[0])
                #expect(result.originalSignatures.allLoadedDirectoriesAuthenticated)
                #expect(!result.appleSigningAuthorityEstablished && !result.provisioningProfileAuthorized)
                #expect(!result.resourceTreeVerified && !result.replacementAuthorized)
            }
        }
    }

    @Test("SHA1 SHA256 truncated SHA256 SHA384 and the original agile order all rebuild real page digests")
    func rebuildsAllDigestKindsAndAgileCodeDirectories() async throws {
        let identity = try await Self.identity(ec: true)
        for (encoded, kinds) in [(Fixture.sha256Base64, [UInt8(2)]), (Fixture.agileBase64, [1, 2]),
                                  (Fixture.truncatedBase64, [3]), (Fixture.sha384Base64, [4])] {
            let result = try await Self.sign(Fixture.data(encoded), identity: identity)
            let bindings = result.signatures.slices[0].directories.sorted { $0.hashType < $1.hashType }
            #expect(bindings.map(\.hashType) == kinds)
            #expect(result.signatures.slices[0].hashAgilityV1Present)
            #expect(result.signatures.slices[0].hashAgilityV2Present)
            let allAuthenticated = bindings.allSatisfy { $0.signerAuthenticated }
            #expect(allAuthenticated)
            if kinds == [3] { #expect(bindings[0].fullCDHash.count == 20) }
        }
    }

    @Test("Identifier team requirements XML DER entitlements Info and CodeResources preserve their actual bytes")
    func preservesIdentityAndEverySpecialBlobByte() async throws {
        let original = try Fixture.data(Fixture.agileBase64)
        let identity = try await Self.identity(ec: false)
        let result = try await Self.sign(original, identity: identity)
        #expect(result.identifier == "org.owned.controlled-resign")
        #expect(result.teamIdentifier == "OWNEDTEAM")
        for slot: UInt32 in [2, 5, 7] {
            #expect(try Self.blob(original, slot: slot) == Self.blob(result.signedMachO, slot: slot))
        }
        for directory in result.contentHashes.directories {
            #expect(directory.verifiedSpecialSlots == [1, 2, 3, 5, 7])
        }
        #expect(result.signedMachO.subdata(in: 4096..<4352) == original.subdata(in: 4096..<4352))
        let resourceBytes = Data("owned replacement resource".utf8)
        let resourceDigest = try Hashes.digest(resourceBytes, hashType: 2)
        let replacementEnvelope = try PropertyListSerialization.data(fromPropertyList:
            ["files2": ["owned.txt": ["hash2": resourceDigest]], "rules2": ["^.*": true]], format: .xml, options: 0)
        let renewed = try await Self.sign(original, identity: identity, replacementResources: replacementEnvelope)
        let oldEnvelopeDigest = try Hashes.digest(Fixture.data(Fixture.resourcesBase64), hashType: 2)
        let newEnvelopeDigest = try Hashes.digest(replacementEnvelope, hashType: 2)
        #expect(renewed.originalCodeResourcesSHA256 == oldEnvelopeDigest)
        #expect(renewed.signedCodeResourcesSHA256 == newEnvelopeDigest)
        #expect(renewed.originalCodeResourcesSHA256 != renewed.signedCodeResourcesSHA256)
        #expect(renewed.originalSignatures.allLoadedDirectoriesAuthenticated)
        #expect(renewed.signatures.allLoadedDirectoriesAuthenticated)
        let oldAnchor = try Fixture.data(Fixture.originalRSAAnchorBase64)
        let originalProof = try await Task.detached { try Self.verify(original, anchors: [oldAnchor]) }.value
        #expect(originalProof.allLoadedDirectoriesAuthenticated)
        let newExternal: [UInt32: Data] = [1: try Fixture.data(Fixture.infoBase64), 3: replacementEnvelope]
        // Neither envelope can be substituted for the other's genuinely sealed slot 3.
        await Self.rejects { try await Task.detached { try Self.verify(original, anchors: [oldAnchor], externalSlots: newExternal) }.value }
        await Self.rejects { try await Task.detached { try Self.verify(renewed.signedMachO, anchors: identity.certificateChainDER) }.value }
        for slot: UInt32 in [1, 4, 42] {
            await Self.rejects(.invalidExternalSlots) { try await Signer.resign(original, identity: identity,
                originalAnchors: [oldAnchor], replacementAnchors: identity.certificateChainDER, at: Self.date,
                externalSpecialSlots: Self.external(), replacementExternalSpecialSlots: [slot: replacementEnvelope]) }
        }
        let unsealed = try Fixture.data(Fixture.noResourcesBase64)
        let infoOnly: [UInt32: Data] = [1: try Fixture.data(Fixture.infoBase64)]
        let unsealedProof = try await Task.detached { try Self.verify(unsealed, anchors: [oldAnchor], externalSlots: infoOnly) }.value
        #expect(unsealedProof.allLoadedDirectoriesAuthenticated)
        await Self.rejects(.unboundReplacementResource) { try await Signer.resign(unsealed, identity: identity,
            originalAnchors: [oldAnchor], replacementAnchors: identity.certificateChainDER, at: Self.date,
            externalSpecialSlots: infoOnly, replacementExternalSpecialSlots: [3: replacementEnvelope]) }
    }

    @Test("LC_CODE_SIGNATURE and aligned LINKEDIT are finalized before hashing and old spare signature data is removed")
    func allocatesBeforeHashingAndErasesOldSignatureTail() async throws {
        let identity = try await Self.identity(ec: false)
        for encoded in [Fixture.sha256Base64, Fixture.largeTailBase64] {
            let input = try Fixture.data(encoded)
            let result = try await Self.sign(input, identity: identity)
            let old = try Self.structure(input).slices[0].signature!
            let current = try Self.structure(result.signedMachO).slices[0].signature!
            #expect(result.signatureOffset == 16384)
            #expect(current.range.byteCount == result.allocatedSignatureBytes)
            #expect(current.range.end == UInt64(result.signedMachO.count))
            #expect(result.allocatedSignatureBytes % 16 == 0)
            #expect(result.allocatedSignatureBytes != old.range.byteCount)
            let end = result.signatureOffset + current.superBlobByteCount
            let zeroPadding = result.signedMachO.subdata(in: end..<result.signedMachO.count).allSatisfy { $0 == 0 }
            #expect(zeroPadding)
            // The changed allocation fields are in signed page zero.
            #expect(try Self.blob(input, slot: 0) != Self.blob(result.signedMachO, slot: 0))
            #expect(result.contentHashes.directories[0].codeBytesHashed == 16384)
            if encoded == Fixture.largeTailBase64 { #expect(result.signedMachO.count < input.count) }
        }
    }

    @Test("Wrong private key certificate trust date or original byte tampering cannot produce a verified result")
    func refusesWrongKeysAnchorsAndTamperedOriginal() async throws {
        let input = try Fixture.data(Fixture.sha256Base64)
        let first = try await Self.identity(ec: false); let second = try await Self.identity(ec: false)
        let wrong = Signer.KeyMaterial(privateKey: first.privateKey, certificateChainDER: second.certificateChainDER)
        await Self.rejects(.keyCertificateMismatch) { try await Self.sign(input, identity: wrong) }
        await Self.rejects { try await Signer.resign(input, identity: first,
            originalAnchors: [Fixture.data(Fixture.originalRSAAnchorBase64)], replacementAnchors: second.certificateChainDER,
            at: Self.date, externalSpecialSlots: Self.external()) }
        await Self.rejects { try await Signer.resign(input, identity: first,
            originalAnchors: [Fixture.data(Fixture.originalRSAAnchorBase64)], replacementAnchors: first.certificateChainDER,
            at: Date(timeIntervalSince1970: 2_366_841_600), externalSpecialSlots: Self.external()) }
        var codeChanged = input; codeChanged[4096] ^= 1
        await Self.rejects { try await Self.sign(codeChanged, identity: first) }
        let signed = try await Self.sign(input, identity: first)
        var cmsChanged = signed.signedMachO
        let structure = try Self.structure(cmsChanged); let signature = structure.slices[0].signature!
        let wrapper = signature.blobs.first { $0.slot == 0x10000 }!
        cmsChanged[Int(signature.range.offset + wrapper.range.end - 1)] ^= 1
        let tampered = cmsChanged
        let rejected = await Task.detached { () -> Bool in
            do { _ = try Self.verify(tampered, anchors: first.certificateChainDER); return false }
            catch { return true }
        }.value
        #expect(rejected)
    }

    @Test("Only supported thin arm64 terminal unencrypted layouts are transformed")
    func rejectsUnsupportedLayoutAndUnboundInputs() async throws {
        let input = try Fixture.data(Fixture.sha256Base64); let identity = try await Self.identity(ec: false)
        var architecture = input; Self.put32(&architecture, 4, 0x01000007)
        await Self.rejects(.unsupportedArchitecture) { try await Self.sign(architecture, identity: identity) }
        var trailing = input; trailing.append(0)
        await Self.rejects(.missingTerminalSignature) { try await Self.sign(trailing, identity: identity) }
        var encrypted = input
        // The final UUID command has the same 24-byte size as encryption_info_64.
        Self.put32(&encrypted, 392, 0x2c); Self.put32(&encrypted, 408, 1)
        await Self.rejects(.encryptedCode) { try await Self.sign(encrypted, identity: identity) }
        var unknown = input; Self.put32(&unknown, 392, 0x777)
        await Self.rejects(.unsupportedCommand(0x777)) { try await Self.sign(unknown, identity: identity) }
        var overlap = input; Self.put64(&overlap, 256 + 40, 8192)
        await Self.rejects(.malformedLayout) { try await Self.sign(overlap, identity: identity) }
        var fat = input; fat.replaceSubrange(0..<4, with: Data([0xca, 0xfe, 0xba, 0xbe]))
        await Self.rejects { try await Self.sign(fat, identity: identity) }
        await Self.rejects(.unsupportedDigestCombination) { try await Self.sign(Fixture.data(Fixture.oidCollisionBase64), identity: identity) }
        var adHoc = input
        let primary = try Self.structure(input).slices[0].signature!.codeDirectories.first { $0.slot == 0 }!
        let flags = 16384 + Int(primary.blobRange.offset) + 12
        adHoc.replaceSubrange(flags..<(flags + 4), with: [0, 0, 0, 2])
        await Self.rejects(.unauthenticatedOriginal) { try await Self.sign(adHoc, identity: identity) }
    }

    @Test("Fixed byte and external-slot budgets plus propagated cancellation fail without writing files")
    func cancelsAndEnforcesReadAndCapacityBudgets() async throws {
        let input = try Fixture.data(Fixture.sha256Base64); let identity = try await Self.identity(ec: false)
        let tooLarge = await Task.detached { Data(repeating: 0, count: Signer.Limits.fileBytes + 1) }.value
        await Self.rejects(.sizeLimit) { try await Self.sign(tooLarge, identity: identity) }
        await Self.rejects(.invalidExternalSlots) { try await Signer.resign(input, identity: identity,
            originalAnchors: [Fixture.data(Fixture.originalRSAAnchorBase64)], replacementAnchors: identity.certificateChainDER,
            at: Self.date, externalSpecialSlots: [4: Data()]) }
        let excessive = Data(repeating: 0, count: Signer.Limits.externalSlotBytes + 1)
        await Self.rejects(.invalidExternalSlots) { try await Signer.resign(input, identity: identity,
            originalAnchors: [Fixture.data(Fixture.originalRSAAnchorBase64)], replacementAnchors: identity.certificateChainDER,
            at: Self.date, externalSpecialSlots: [1: excessive]) }
        let task = Task { try await Self.sign(input, identity: identity) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled signing returned a result") }
        catch is CancellationError { }
        catch { Issue.record("Cancellation changed error type: \(error)") }
    }

    private static func sign(_ input: Data, identity: Signer.KeyMaterial, anchor: Data? = nil,
        replacementResources: Data? = nil) async throws -> Signer.Result {
        try await Signer.resign(input, identity: identity,
            originalAnchors: [try anchor ?? Fixture.data(Fixture.originalRSAAnchorBase64)],
            replacementAnchors: identity.certificateChainDER, at: date, externalSpecialSlots: external(),
            replacementExternalSpecialSlots: replacementResources.map { [3: $0] } ?? [:])
    }
    private static func external() throws -> [UInt32: Data] {
        [1: try Fixture.data(Fixture.infoBase64), 3: try Fixture.data(Fixture.resourcesBase64)]
    }
    private static func rejects<T>(_ expected: Signer.Failure? = nil, _ action: () async throws -> T) async {
        do { _ = try await action(); Issue.record("Invalid controlled signing input was accepted") }
        catch { if let expected { #expect(error as? Signer.Failure == expected) } }
    }
    private static func structure(_ data: Data) throws -> Reader.ParsedFile {
        try Reader.parse(fileByteCount: UInt64(data.count)) { range in
            data.subdata(in: Int(range.offset)..<(Int(range.offset) + range.byteCount))
        }
    }
    private static func blob(_ data: Data, slot: UInt32) throws -> Data {
        guard let signature = try structure(data).slices.first?.signature,
              let blob = signature.blobs.first(where: { $0.slot == slot }) else { throw CocoaError(.coderInvalidValue) }
        let start = Int(signature.range.offset + blob.range.offset)
        return data.subdata(in: start..<(start + blob.range.byteCount))
    }
    private static func verify(_ data: Data, anchors: [Data], externalSlots: [UInt32: Data]? = nil) throws -> SelfRenewalSignedCodeVerifier.Verification {
        let read: (Reader.ByteRange) -> Data = { data.subdata(in: Int($0.offset)..<(Int($0.offset) + $0.byteCount)) }
        let material = try externalSlots ?? external()
        let hashes = try Hashes.verify(fileByteCount: UInt64(data.count), readStructureRange: read, readContentRange: read,
            externalSpecialSlot: { slot, _ in material[slot] })
        return try SelfRenewalSignedCodeVerifier.bind(hashes, anchors: anchors, at: date, readRange: read)
    }
    private static func put32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
        data.replaceSubrange(offset..<(offset + 4), with: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    private static func put64(_ data: inout Data, _ offset: Int, _ value: UInt64) {
        data.replaceSubrange(offset..<(offset + 8), with: (0..<8).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    /// Only public representations leave Security. Each fresh nonpermanent
    /// private key stays in memory and is never embedded, written or exported.
    private static func identity(ec: Bool) async throws -> Signer.KeyMaterial {
        try await Task.detached {
            let kind = ec ? kSecAttrKeyTypeECSECPrimeRandom : kSecAttrKeyTypeRSA
            let options: [String: Any] = [kSecAttrKeyType as String: kind, kSecAttrKeySizeInBits as String: ec ? 256 : 2048,
                kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: false]]
            var error: Unmanaged<CFError>?
            defer { if let error { _ = error.takeRetainedValue() } }
            guard let key = SecKeyCreateRandomKey(options as CFDictionary, &error) else {
                throw CocoaError(.coderInvalidValue)
            }
            let certificate = try SelfRenewalSigningOwnedPKIFixture.certificate(for: key, at: Self.date)
            return Signer.KeyMaterial(privateKey: key, certificateChainDER: [certificate])
        }.value
    }
}
