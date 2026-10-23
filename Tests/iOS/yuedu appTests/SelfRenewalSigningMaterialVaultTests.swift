import CryptoKit
import Foundation
import Security
import Testing
@testable import yuedu_app

@Suite("Owned software-Keychain signing material lifecycle", .serialized)
struct SelfRenewalSigningMaterialVaultTests {
    private typealias Vault = SelfRenewalSigningMaterialVault
    private typealias PKI = SelfRenewalSigningOwnedPKIFixture

    @Test("publication metadata nil means genuinely absent while stale corrupt cancelled and locked reads remain errors")
    func observesPublicationBaselineWithoutGrantingMaterialAuthority() async throws {
        try await Self.fixture { f in
            let namespace = try await f.namespace()
            let generation = try await f.vault.generation(in: namespace)
            let missing = try await f.vault.publicationBaseline(in: namespace, expectedGeneration: generation)
            #expect(missing == nil)
            // Fault injection checks preservation of the real storage error
            // category; this does not simulate actually locking an iOS device.
            f.storage.failNextLoad(.keychain(errSecInteractionNotAllowed))
            try await Self.failure(.keychain(errSecInteractionNotAllowed)) {
                _ = try await f.vault.publicationBaseline(in: namespace, expectedGeneration: generation)
            }
            let account = "owned-v1-" + namespace.id.uuidString.lowercased()
            let encoded = try #require(try f.storage.load(account: account))
            do {
                defer { do { try f.storage.save(account: account, value: encoded) } catch { Issue.record(error) } }
                try f.storage.delete(account: account)
                try await Self.failure(.namespaceUnavailable) {
                    _ = try await f.vault.publicationBaseline(in: namespace, expectedGeneration: generation)
                }
            }
            do {
                defer { do { try f.storage.save(account: account, value: encoded) } catch { Issue.record(error) } }
                try f.storage.save(account: account, value: "{owned corrupt manifest}")
                try await Self.failure(.staleGeneration) {
                    _ = try await f.vault.publicationBaseline(in: namespace, expectedGeneration: generation)
                }
                let reopened = Vault(codeAnchors: f.issuer.certificateChainDER, profileAnchors: f.issuer.certificateChainDER,
                    storage: f.storage, clock: { f.clock.now() })
                try await Self.failure(.malformedManifest) { _ = try await reopened.resume(namespaceID: namespace.id, identity: f.baseline) }
            }
            try await Self.failure(.staleGeneration) {
                _ = try await f.vault.publicationBaseline(in: namespace, expectedGeneration: generation + 1)
            }
            let key = try await f.generate(namespace)
            let candidate = try f.candidate(key)
            let lease = try await f.vault.publish(in: namespace, keyID: key.id, expectedGeneration: key.generation,
                certificateChainDER: candidate.chain, profiles: candidate.profiles)
            let observation = try #require(try await f.vault.publicationBaseline(in: namespace, expectedGeneration: lease.generation))
            #expect(observation.namespace == namespace && observation.keyID == key.id && observation.generation == lease.generation)
            #expect(observation.leafCertificateSHA256 == Data(SHA256.hash(data: candidate.chain[0])))
            f.clock.set(f.date.addingTimeInterval(31 * 86_400))
            let afterExpiry = try await f.vault.publicationBaseline(in: namespace, expectedGeneration: lease.generation)
            #expect(afterExpiry == observation)
            // It remains old manifest metadata; it has no valid-lease property.
            do { _ = try await f.vault.lease(in: namespace); Issue.record("Expired metadata was treated as a live lease") }
            catch let failure as Vault.Failure { #expect(failure == .invalidProfiles || failure == .untrustedCertificate) }
            f.clock.set(f.date)
            let cancelled = Task.detached {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await f.vault.publicationBaseline(in: namespace, expectedGeneration: lease.generation)
            }
            do { _ = try await cancelled.value; Issue.record("Cancelled metadata read became absence") }
            catch is CancellationError {}
        }
    }

    @Test("real permanent handle publishes verified profiles reopens signs verifies and revokes only its tag")
    func publishesReloadsSignsAndRevokesOwnedKeychainMaterial() async throws {
        try await Self.fixture { f in
            let namespace = try await f.namespace()
            let pending = try await f.generate(namespace)
            let protection = try Self.attributes(Self.tag(namespace: namespace, keyID: pending.id))
            #expect(protection[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
            #expect(protection[kSecAttrSynchronizable as String] as? Bool != true)
            let candidate = try f.candidate(pending)
            let lease = try await f.vault.publish(in: namespace, keyID: pending.id, expectedGeneration: pending.generation,
                certificateChainDER: candidate.chain, profiles: candidate.profiles)
            #expect(lease.profiles.count == 3)
            #expect(!lease.appleSigningAuthorityEstablished && !lease.accountIdentityEstablished)
            #expect(!lease.remoteRevocationEstablished && !lease.replacementAuthorized)
            _ = try await f.vault.resume(namespaceID: namespace.id, identity: f.baseline)
            // lease() calls SecItemCopyMatching on the exact persisted tag; the
            // actor stores no private-key cache to stand in for a reopen.
            let reopened = try await f.vault.lease(in: namespace)
            #expect(reopened.generation == lease.generation)
            #expect(reopened.keyID == pending.id)
            try Self.signAndVerify(reopened.keyMaterial)
            try await f.vault.validate(reopened)
            let other = try await f.namespace()
            let otherKey = try await f.generate(other)
            let otherTag = Self.tag(namespace: other, keyID: otherKey.id)
            let tag = Self.tag(namespace: namespace, keyID: pending.id)
            try await f.vault.revoke(pending.id, in: namespace, expectedGeneration: reopened.generation)
            #expect(Self.status(tag) == errSecItemNotFound)
            #expect(Self.status(otherTag) == errSecSuccess)
            try await Self.failure(.staleGeneration) { try await f.vault.validate(reopened) }
            try await Self.failure(.namespaceUnavailable) { _ = try await f.vault.lease(in: namespace) }
        }
    }

    @Test("signed team app group and certificate mismatches never replace a valid publication")
    func rejectsSignedIdentityAndKeyChangesWithoutReplacingOldMaterial() async throws {
        try await Self.fixture { f in
            let namespace = try await f.namespace()
            let first = try await f.generate(namespace)
            let original = try f.candidate(first)
            let old = try await f.vault.publish(in: namespace, keyID: first.id, expectedGeneration: first.generation,
                certificateChainDER: original.chain, profiles: original.profiles)
            let next = try await f.generate(namespace)
            let changes: [(String, ([String: PKI.Value]) -> [String: PKI.Value])] = [
                ("team", { var values = $0; values["TeamIdentifier"] = .array([.string("WRONGTEAM")]); return values }),
                ("app", { var values = $0; if case .dictionary(var claims)? = values["Entitlements"] {
                    claims["application-identifier"] = .string("WRONGPREFIX.other"); values["Entitlements"] = .dictionary(claims) }; return values }),
                ("groups", { var values = $0; if case .dictionary(var claims)? = values["Entitlements"] {
                    claims["com.apple.security.application-groups"] = .array([.string("group.changed")]); values["Entitlements"] = .dictionary(claims) }; return values }),
            ]
            for (_, change) in changes {
                let candidate = try f.candidate(next) { $0 = change($0) }
                try await Self.failure(.identityChanged) {
                    _ = try await f.vault.publish(in: namespace, keyID: next.id, expectedGeneration: next.generation,
                        certificateChainDER: candidate.chain, profiles: candidate.profiles)
                }
                let kept = try await f.vault.lease(in: namespace)
                #expect(kept.keyID == old.keyID)
                let keptUUIDs = kept.profiles.map(\.summary.uuid)
                let oldUUIDs = old.profiles.map(\.summary.uuid)
                #expect(keptUUIDs == oldUUIDs)
            }
            try await Self.failure(.keyMismatch) {
                _ = try await f.vault.publish(in: namespace, keyID: next.id, expectedGeneration: next.generation,
                    certificateChainDER: original.chain, profiles: original.profiles)
            }
            let kept = try await f.vault.lease(in: namespace)
            #expect(kept.keyID == first.id)
        }
    }

    @Test("stale CAS and observed cancellation leave publication and generation unchanged")
    func rejectsStaleCASAndCancellationBeforePublication() async throws {
        try await Self.fixture { f in
            let namespace = try await f.namespace()
            let first = try await f.generate(namespace)
            let original = try f.candidate(first)
            let old = try await f.vault.publish(in: namespace, keyID: first.id, expectedGeneration: first.generation,
                certificateChainDER: original.chain, profiles: original.profiles)
            let next = try await f.generate(namespace)
            let candidate = try f.candidate(next)
            try await Self.failure(.staleGeneration) {
                _ = try await f.vault.publish(in: namespace, keyID: next.id, expectedGeneration: old.generation,
                    certificateChainDER: candidate.chain, profiles: candidate.profiles)
            }
            let before = try await f.vault.generation(in: namespace)
            let cancelled = Task.detached {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await f.vault.publish(in: namespace, keyID: next.id, expectedGeneration: next.generation,
                    certificateChainDER: candidate.chain, profiles: candidate.profiles)
            }
            do { _ = try await cancelled.value; Issue.record("Cancelled publication was accepted") }
            catch is CancellationError {}
            let after = try await f.vault.generation(in: namespace)
            let kept = try await f.vault.lease(in: namespace)
            #expect(before == after && kept.keyID == first.id)
        }
    }

    @Test("single manifest save failure preserves the old publication across a real reopen")
    func preservesPublicationWhenManifestSaveFails() async throws {
        try await Self.fixture { f in
            let namespace = try await f.namespace()
            let first = try await f.generate(namespace)
            let original = try f.candidate(first)
            _ = try await f.vault.publish(in: namespace, keyID: first.id, expectedGeneration: first.generation,
                certificateChainDER: original.chain, profiles: original.profiles)
            let next = try await f.generate(namespace)
            let candidate = try f.candidate(next)
            f.storage.failSave(afterSuccessfulSaves: 0)
            try await Self.failure(.manifestWrite) {
                _ = try await f.vault.publish(in: namespace, keyID: next.id, expectedGeneration: next.generation,
                    certificateChainDER: candidate.chain, profiles: candidate.profiles)
            }
            _ = try await f.vault.resume(namespaceID: namespace.id, identity: f.baseline)
            let kept = try await f.vault.lease(in: namespace)
            #expect(kept.keyID == first.id && kept.generation == next.generation)
            try Self.signAndVerify(kept.keyMaterial)
        }
    }

    @Test("pending journal survives a ready-save fault and recovery cleans only that generated key")
    func recoversPendingKeyJournalWithoutDeletingPublishedKey() async throws {
        try await Self.fixture { f in
            let namespace = try await f.namespace()
            let first = try await f.generate(namespace)
            let original = try f.candidate(first)
            _ = try await f.vault.publish(in: namespace, keyID: first.id, expectedGeneration: first.generation,
                certificateChainDER: original.chain, profiles: original.profiles)
            let before = try await f.vault.generation(in: namespace)
            f.storage.failSave(afterSuccessfulSaves: 1)
            try await Self.failure(.manifestWrite) { _ = try await f.vault.generateKey(in: namespace, expectedGeneration: before) }
            let storedJournal = try f.storage.load(account: "owned-v1-" + namespace.id.uuidString.lowercased())
            let journal = try #require(storedJournal)
            let object = try #require(try JSONSerialization.jsonObject(with: Data(journal.utf8)) as? [String: Any])
            let keys = try #require(object["keys"] as? [[String: Any]])
            let pending = try #require(keys.first(where: { $0["state"] as? String == "pending" }))
            let id = try #require(pending["id"] as? String)
            let tag = Data(("com.yuedu.selfRenewal.signingKey.v1." + namespace.id.uuidString.lowercased() + "." + id.lowercased()).utf8)
            #expect(Self.status(tag) == errSecItemNotFound)
            _ = try await f.vault.resume(namespaceID: namespace.id, identity: f.baseline)
            let kept = try await f.vault.lease(in: namespace)
            #expect(kept.keyID == first.id)
            try Self.signAndVerify(kept.keyMaterial)
        }
    }

    @Test("expired authenticated profiles and local revocation cannot yield a current lease")
    func rejectsExpiredProfilesAndLocallyRevokedLeases() async throws {
        try await Self.fixture { f in
            let namespace = try await f.namespace()
            let pending = try await f.generate(namespace)
            let expired = try f.candidate(pending) { $0["ExpirationDate"] = .date(f.date.addingTimeInterval(-1)) }
            do {
                _ = try await f.vault.publish(in: namespace, keyID: pending.id, expectedGeneration: pending.generation,
                    certificateChainDER: expired.chain, profiles: expired.profiles)
                Issue.record("Expired profile was published")
            } catch let error as SelfRenewalProvisioningProfileVerifier.Failure { #expect(error == .profileExpired) }
            let candidate = try f.candidate(pending)
            let lease = try await f.vault.publish(in: namespace, keyID: pending.id, expectedGeneration: pending.generation,
                certificateChainDER: candidate.chain, profiles: candidate.profiles)
            f.clock.set(f.date.addingTimeInterval(3_601))
            do { _ = try await f.vault.lease(in: namespace); Issue.record("Expired lease was returned") }
            catch let error as SelfRenewalProvisioningProfileVerifier.Failure { #expect(error == .profileExpired) }
            try await f.vault.revoke(pending.id, in: namespace, expectedGeneration: lease.generation)
            try await Self.failure(.staleGeneration) { try await f.vault.validate(lease) }
            try await Self.failure(.namespaceUnavailable) { _ = try await f.vault.lease(in: namespace) }
        }
    }

    @Test("key namespace and public material budgets remain bounded and scoped cleanup preserves unrelated data")
    func boundsLifetimeAndPreservesUnrelatedKeychainItems() async throws {
        try await Self.fixture { f in
            let service = "owned.signing.sentinel." + UUID().uuidString
            let account = UUID().uuidString
            let saved = KeychainHelper.save(account: account, data: "owned-public-sentinel", service: service,
                accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, synchronizable: false)
            #expect(saved)
            defer { #expect(KeychainHelper.delete(account: account, service: service, synchronizable: false)) }
            let first = try await f.namespace()
            for _ in 0..<Vault.Limits.keysPerNamespace { _ = try await f.generate(first) }
            let generation = try await f.vault.generation(in: first)
            try await Self.failure(.limit) { _ = try await f.vault.generateKey(in: first, expectedGeneration: generation) }
            for _ in 1..<Vault.Limits.namespaces { _ = try await f.namespace() }
            try await Self.failure(.limit) { _ = try await f.vault.create(identity: f.baseline) }
            try await f.vault.destroy(first, expectedGeneration: generation)
            let sentinel = KeychainHelper.load(account: account, service: service, synchronizable: false)
            #expect(sentinel == "owned-public-sentinel")
        }
    }

    @Test("CSR reopens the real owned key and external public key verifies exact PKCS10 bytes")
    func requestsCertificateWithPersistedKeyAndIndependentPublicVerification() async throws {
        try await Self.fixture { f in
            let namespace = try await f.namespace()
            let first = try await f.generate(namespace)
            let original = try f.candidate(first)
            _ = try await f.vault.publish(in: namespace, keyID: first.id, expectedGeneration: first.generation,
                certificateChainDER: original.chain, profiles: original.profiles)
            let pending = try await f.generate(namespace)
            let account = "owned-v1-" + namespace.id.uuidString.lowercased()
            let before = try f.storage.load(account: account)
            let reopened = Vault(codeAnchors: f.issuer.certificateChainDER, profileAnchors: f.issuer.certificateChainDER,
                storage: f.storage, clock: { f.clock.now() })
            let resumed = try await reopened.resume(namespaceID: namespace.id, identity: f.baseline)
            let request = try await reopened.certificateSigningRequest(in: resumed, keyID: pending.id,
                expectedGeneration: pending.generation, commonName: "Owned /CN=literal, + Test", emailAddress: "owned@example.invalid")
            #expect(request.namespace == namespace && request.keyID == pending.id)
            #expect(request.generation == pending.generation && request.publicKeySHA256 == pending.publicKeySHA256)
            #expect(!request.der.isEmpty && request.der.count <= 8192)
            let root = try SelfRenewalCMSVerifier.parseDER(request.der)
            let fields = try SelfRenewalCMSVerifier.children(of: root)
            #expect(root.tag == 0x30)
            try #require(fields.count == 3)
            let info = try SelfRenewalCMSVerifier.children(of: fields[0])
            try #require(info.count == 4)
            #expect(info[0].originalDER == Data([2, 1, 0]))
            #expect(info[3].originalDER == Data([0xa0, 0]))
            let subject = try SelfRenewalCMSVerifier.children(of: info[1])
            try #require(subject.count == 2)
            let nameSet = try SelfRenewalCMSVerifier.children(of: subject[0])
            try #require(nameSet.count == 1)
            let namePair = try SelfRenewalCMSVerifier.children(of: nameSet[0])
            #expect(namePair.last?.body == Data("Owned /CN=literal, + Test".utf8))
            let publicInfo = try SelfRenewalCMSVerifier.children(of: info[2])
            try #require(publicInfo.count == 2)
            let signatureOID = try SelfRenewalCMSVerifier.children(of: fields[1])
            #expect(signatureOID.map(\.originalDER) == [Data([6, 9, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 1, 11]), Data([5, 0])])
            #expect(publicInfo[1].tag == 3 && publicInfo[1].body.first == 0)
            #expect(fields[2].tag == 3 && fields[2].body.first == 0 && fields[2].body.count == 257)
            let publicBytes = Data(publicInfo[1].body.dropFirst())
            let expectedPublicKey = try #require(SecKeyCopyPublicKey(pending.privateKey))
            var exportError: Unmanaged<CFError>?
            let expectedBytes = SecKeyCopyExternalRepresentation(expectedPublicKey, &exportError) as Data?
            if let exportError { _ = exportError.takeRetainedValue() }
            #expect(expectedBytes == publicBytes)
            let publicAlgorithm = try SelfRenewalCMSVerifier.children(of: publicInfo[0])
            #expect(publicAlgorithm.map(\.originalDER) == [Data([6, 9, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 1, 1]), Data([5, 0])])
            let options: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPublic, kSecAttrKeySizeInBits as String: 2048]
            var importError: Unmanaged<CFError>?
            let rawPublicKey = SecKeyCreateWithData(publicBytes as CFData, options as CFDictionary, &importError)
            if let importError { _ = importError.takeRetainedValue() }
            let publicKey = try #require(rawPublicKey)
            let signature = Data(fields[2].body.dropFirst())
            var verifyError: Unmanaged<CFError>?
            let verified = SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                fields[0].originalDER as CFData, signature as CFData, &verifyError)
            if let verifyError { _ = verifyError.takeRetainedValue() }
            #expect(verified)
            var tampered = fields[0].originalDER
            let marker = try #require(tampered.range(of: Data("Owned /CN=literal, + Test".utf8)))
            tampered[marker.lowerBound] ^= 1
            verifyError = nil
            let acceptedTamper = SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                tampered as CFData, signature as CFData, &verifyError)
            if let verifyError { _ = verifyError.takeRetainedValue() }
            #expect(!acceptedTamper)
            let after = try f.storage.load(account: account)
            let kept = try await f.vault.lease(in: namespace)
            #expect(before == after && kept.keyID == first.id && kept.generation == pending.generation)
            try Self.signAndVerify(kept.keyMaterial)
        }
        try await Self.frameworkEnrollmentPreservesPendingIntent()
    }

    @Test("CSR rejects stale revoked foreign and deleted keys despite retained pending handles")
    func rejectsStaleRevokedForeignAndMissingCertificateRequestKeys() async throws {
        try await Self.fixture { f in
            let namespace = try await f.namespace()
            let first = try await f.generate(namespace)
            let second = try await f.generate(namespace)
            try await Self.failure(.staleGeneration) {
                _ = try await f.vault.certificateSigningRequest(in: namespace, keyID: first.id,
                    expectedGeneration: first.generation, commonName: "Owned", emailAddress: "owned@example.invalid")
            }
            let other = try await f.namespace()
            let otherGeneration = try await f.vault.generation(in: other)
            try await Self.failure(.missingKey) {
                _ = try await f.vault.certificateSigningRequest(in: other, keyID: first.id,
                    expectedGeneration: otherGeneration, commonName: "Owned", emailAddress: "owned@example.invalid")
            }
            try await f.vault.revoke(first.id, in: namespace, expectedGeneration: second.generation)
            let generation = try await f.vault.generation(in: namespace)
            try await Self.failure(.revoked) {
                _ = try await f.vault.certificateSigningRequest(in: namespace, keyID: first.id,
                    expectedGeneration: generation, commonName: "Owned", emailAddress: "owned@example.invalid")
            }
            let secondTag = Self.tag(namespace: namespace, keyID: second.id)
            let delete: [String: Any] = [kSecClass as String: kSecClassKey,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate, kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrApplicationTag as String: secondTag, kSecAttrSynchronizable as String: false]
            #expect(SecItemDelete(delete as CFDictionary) == errSecSuccess)
            try await Self.failure(.missingKey) {
                _ = try await f.vault.certificateSigningRequest(in: namespace, keyID: second.id,
                    expectedGeneration: generation, commonName: "Owned", emailAddress: "owned@example.invalid")
            }
        }
    }

    @Test("invalid bounded CSR subjects and cancellation preserve the existing manifest")
    func rejectsInvalidCertificateRequestSubjectsAndCancellationWithoutPublication() async throws {
        try await Self.fixture { f in
            let namespace = try await f.namespace()
            let pending = try await f.generate(namespace)
            let account = "owned-v1-" + namespace.id.uuidString.lowercased()
            let before = try f.storage.load(account: account)
            let invalid: [(String, String)] = [("", "owned@example.invalid"), ("Owned\nOther", "owned@example.invalid"),
                (String(repeating: "a", count: 65), "owned@example.invalid"), ("Owned", String(repeating: "a", count: 129)),
                ("Owned", "user@@example.invalid"), ("Owned", "no-domain"), ("Owned", "@example.invalid"),
                ("Owned", "user@"), ("Owned", "user\n@example.invalid"), ("Owned", "user@\u{4f8b}.invalid")]
            for (name, email) in invalid {
                do {
                    _ = try await f.vault.certificateSigningRequest(in: namespace, keyID: pending.id,
                        expectedGeneration: pending.generation, commonName: name, emailAddress: email)
                    Issue.record("Invalid CSR subject was accepted")
                } catch let error as Vault.CertificateRequestFailure { #expect(error == .invalidSubject) }
            }
            let cancelled = Task.detached {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await f.vault.certificateSigningRequest(in: namespace, keyID: pending.id,
                    expectedGeneration: pending.generation, commonName: "Owned", emailAddress: "owned@example.invalid")
            }
            do { _ = try await cancelled.value; Issue.record("Cancelled CSR was accepted") }
            catch is CancellationError {}
            let after = try f.storage.load(account: account)
            let generation = try await f.vault.generation(in: namespace)
            #expect(before == after && generation == pending.generation)
        }
    }

    nonisolated private static func frameworkEnrollmentPreservesPendingIntent() async throws {
        let observations = try await Task.detached {
            var checks: [Bool] = []
            func required<T>(_ value: T?) throws -> T {
                guard let value else { throw CocoaError(.coderInvalidValue) }
                return value
            }
            func requireCondition(_ value: Bool) throws {
                guard value else { throw CocoaError(.coderInvalidValue) }
            }
            let sdk = try SelfRenewalSDKOwnedPackageFixture.load()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-enrollment-framework-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let input = directory.appendingPathComponent("owned.ipa")
            let storage = FaultStorage()
            let vault = Vault(codeAnchors: [sdk.anchor], profileAnchors: [sdk.anchor], storage: storage, clock: { sdk.date })
            var ownedNamespace: Vault.Namespace?
            func cleanup() async throws {
                storage.clearSaveFailure()
                if let namespace = ownedNamespace {
                    let generation = try await vault.generation(in: namespace)
                    try await vault.destroy(namespace, expectedGeneration: generation)
                    ownedNamespace = nil
                }
                if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
            }
            do {
                try sdk.archive.write(to: input, options: .withoutOverwriting)
                let verified = try await SelfRenewalIPAUnpacker.verify(ipa: input,
                    codeAnchors: [sdk.anchor], profileAnchors: [sdk.anchor], at: sdk.date)
                let observed = verified.application.resources.executableMaterials
                try requireCondition(observed.inventory.components.filter { $0.kind == .framework }.count == 1)
                try requireCondition(observed.inventory.issues.contains { issue in
                    if case .unexpectedComponent(let path) = issue {
                        return observed.inventory.components.first { $0.relativePath == path }?.kind == .framework
                    }
                    return false
                })
                let namespace = try await vault.create(identity: verified.application)
                ownedNamespace = namespace
                let originalGeneration = try await vault.generation(in: namespace)
                // Persist a real generateKey pending intent, then fail only its
                // ready write. The owner removes the issued key but retains the
                // durable pending record; enrollment reads must not retire it.
                storage.failSave(afterSuccessfulSaves: 1)
                do {
                    _ = try await vault.generateKey(in: namespace, expectedGeneration: originalGeneration)
                    checks.append(false)
                } catch let failure as Vault.Failure {
                    checks.append(failure == .manifestWrite)
                }
                let generation = try await vault.generation(in: namespace)
                let account = "owned-v1-" + namespace.id.uuidString.lowercased()
                let before = try required(try storage.load(account: account))
                let manifest = try required(try JSONSerialization.jsonObject(with: Data(before.utf8)) as? [String: Any])
                let keys = try required(manifest["keys"] as? [[String: Any]])
                try requireCondition(keys.count == 1 && keys[0]["state"] as? String == "pending")
                let pendingIDString = try required(keys[0]["id"] as? String)
                let pendingID = try required(UUID(uuidString: pendingIDString))
                checks.append(Self.status(Self.tag(namespace: namespace, keyID: pendingID)) == errSecItemNotFound)
                let reopened = Vault(codeAnchors: [sdk.anchor], profileAnchors: [sdk.anchor], storage: storage, clock: { sdk.date })
                let enrollment = try await reopened.resumeForEnrollment(namespaceID: namespace.id, observed: observed)
                checks.append(enrollment.namespace == namespace && enrollment.bundles.count == 3)
                checks.append(!enrollment.currentSigningMaterialsVerified && !enrollment.appleAuthorizationEstablished)
                let afterGeneration = try await reopened.generation(in: namespace)
                let after = try required(try storage.load(account: account))
                checks.append(afterGeneration == generation && Data(after.utf8) == Data(before.utf8))

                // Negative structural observations copy genuine parsed material;
                // they add no authentication result or caller success flag.
                let inventory = observed.inventory
                let denied: [SelfRenewalMaterialInventory.Issue] = [
                    .missingRole(.shareExtension), .duplicateRole(.widgetExtension),
                    .missingOrInvalidInfo("owned-negative"), .unexpectedComponent("."),
                    .unexpectedComponent("owned-missing.framework"), .invalidRoleLocation("owned-negative"),
                    .invalidParentIdentifier("owned-negative"), .duplicateBundleIdentifier,
                    .missingExecutable("owned-negative"), .unrecognizedExecutableHeader("owned-negative")]
                for issue in denied {
                    let changed = SelfRenewalMaterialInventory.Inventory(components: inventory.components,
                        codeFiles: inventory.codeFiles, files: inventory.files, directories: inventory.directories,
                        issues: inventory.issues + [issue], entriesVisited: inventory.entriesVisited,
                        declaredFileBytes: inventory.declaredFileBytes, bytesRead: inventory.bytesRead)
                    let rejected = SelfRenewalMachOSignatureReader.Materials(inventory: changed, code: observed.code,
                        signatureStructureBytesRead: observed.signatureStructureBytesRead,
                        contentHashBytesRead: observed.contentHashBytesRead,
                        signatureVerificationBytesRead: observed.signatureVerificationBytesRead)
                    do {
                        _ = try await reopened.resumeForEnrollment(namespaceID: namespace.id, observed: rejected)
                        checks.append(false)
                    } catch let failure as Vault.Failure {
                        checks.append(failure == .identityChanged)
                    }
                    let unchanged = try required(try storage.load(account: account))
                    let unchangedGeneration = try await reopened.generation(in: namespace)
                    checks.append(Data(unchanged.utf8) == Data(before.utf8) && unchangedGeneration == generation)
                }
                try await cleanup()
                return checks
            } catch {
                try await cleanup()
                throw error
            }
        }.value
        #expect(observations.count == 25 && observations.allSatisfy { $0 })
    }

    nonisolated private static func failure(_ expected: Vault.Failure, _ action: @Sendable () async throws -> Void) async throws {
        do { try await action(); Issue.record("Expected \(expected)") }
        catch let error as Vault.Failure { #expect(error == expected) }
    }
    nonisolated private static func signAndVerify(_ material: Vault.KeyMaterial) throws {
        let message = Data("owned signing lifecycle challenge".utf8)
        var error: Unmanaged<CFError>?
        let rawSignature = SecKeyCreateSignature(material.privateKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, &error) as Data?
        let signature = try #require(rawSignature)
        let rawCertificate = SecCertificateCreateWithData(nil, material.certificateChainDER[0] as CFData)
        let certificate = try #require(rawCertificate)
        let rawPublicKey = SecCertificateCopyKey(certificate)
        let publicKey = try #require(rawPublicKey)
        let verified = SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, signature as CFData, &error)
        if let error { _ = error.takeRetainedValue() }
        #expect(verified)
    }
    nonisolated private static func tag(namespace: Vault.Namespace, keyID: UUID) -> Data {
        // SecKeyCopyAttributes need not include database application tags.
        // Address this exact fixture-owned permanent item; attributes/status
        // below still query its real Keychain protection/existence/removal.
        Data(("com.yuedu.selfRenewal.signingKey.v1." + namespace.id.uuidString.lowercased()
            + "." + keyID.uuidString.lowercased()).utf8)
    }
    nonisolated private static func status(_ tag: Data) -> OSStatus {
        let query: [String: Any] = [kSecClass as String: kSecClassKey, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrApplicationTag as String: tag,
            kSecAttrSynchronizable as String: false, kSecReturnRef as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result)
    }
    nonisolated private static func attributes(_ tag: Data) throws -> [String: Any] {
        let query: [String: Any] = [kSecClass as String: kSecClassKey, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrApplicationTag as String: tag,
            kSecAttrSynchronizable as String: false, kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        #expect(status == errSecSuccess)
        return try #require(result as? [String: Any])
    }
    nonisolated private static func fixture(_ action: @escaping @Sendable (Fixture) async throws -> Void) async throws {
        try await Task.detached {
            let fixture = try await Fixture.make()
            do { try await action(fixture); try await fixture.cleanup() }
            catch { do { try await fixture.cleanup() } catch { Issue.record(error) }; throw error }
        }.value
    }
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date
        init(_ date: Date) { self.date = date }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
        func set(_ date: Date) { lock.lock(); defer { lock.unlock() }; self.date = date }
    }
    private final class FaultStorage: @unchecked Sendable, SelfRenewalSigningManifestStorage {
        private let base = SelfRenewalSigningKeychainManifestStorage()
        private let lock = NSLock()
        private var remaining: Int?
        private var nextLoadFailure: Vault.Failure?
        func failSave(afterSuccessfulSaves count: Int) { lock.lock(); defer { lock.unlock() }; remaining = count }
        func clearSaveFailure() { lock.lock(); defer { lock.unlock() }; remaining = nil }
        func failNextLoad(_ failure: Vault.Failure) { lock.lock(); defer { lock.unlock() }; nextLoadFailure = failure }
        func load(account: String) throws -> String? {
            lock.lock(); let failure = nextLoadFailure; nextLoadFailure = nil; lock.unlock()
            if let failure { throw failure }
            return try base.load(account: account)
        }
        func save(account: String, value: String) throws {
            lock.lock()
            let fail = remaining == 0
            if let count = remaining { remaining = count == 0 ? nil : count - 1 }
            lock.unlock()
            if fail { throw Vault.Failure.manifestWrite }
            try base.save(account: account, value: value)
        }
        func insert(account: String, value: String) throws { try base.insert(account: account, value: value) }
        func delete(account: String) throws { try base.delete(account: account) }
    }
    private struct Candidate: Sendable { let chain: [Data]; let profiles: [Vault.ProfileInput] }
    private final class Fixture: @unchecked Sendable {
        let directory: URL
        let baseline: SelfRenewalApplicationMaterialVerifier.Materials
        let issuer: Vault.KeyMaterial
        let storage: FaultStorage
        let clock: Clock
        let vault: Vault
        let date: Date
        private var namespaces: [Vault.Namespace] = []
        init(directory: URL, baseline: SelfRenewalApplicationMaterialVerifier.Materials, issuer: Vault.KeyMaterial, date: Date) {
            self.directory = directory; self.baseline = baseline; self.issuer = issuer; self.date = date
            let storage = FaultStorage(); let clock = Clock(date)
            self.storage = storage; self.clock = clock
            vault = Vault(codeAnchors: issuer.certificateChainDER, profileAnchors: issuer.certificateChainDER,
                storage: storage, clock: { clock.now() })
        }
        func namespace() async throws -> Vault.Namespace {
            let value = try await vault.create(identity: baseline); namespaces.append(value); return value
        }
        func generate(_ namespace: Vault.Namespace) async throws -> Vault.PendingKey {
            let generation = try await vault.generation(in: namespace)
            return try await vault.generateKey(in: namespace, expectedGeneration: generation)
        }
        func candidate(_ key: Vault.PendingKey, transform: ((inout [String: PKI.Value]) -> Void)? = nil) throws -> Candidate {
            let leaf = try PKI.certificate(for: key.privateKey, signedBy: issuer, at: date)
            let inputs = try baseline.bundles.map { bundle -> Vault.ProfileInput in
                let original = try #require(baseline.profiles.profiles.first { $0.file.relativePath == bundle.profileRelativePath })
                let bytes = try PKI.profile(from: original, developerCertificate: leaf, issuer: issuer, at: date, transform: transform)
                return Vault.ProfileInput(componentRelativePath: bundle.componentRelativePath, bytes: bytes)
            }
            return Candidate(chain: [leaf] + issuer.certificateChainDER, profiles: inputs)
        }
        func cleanup() async throws {
            for namespace in namespaces {
                do {
                    let generation = try await vault.generation(in: namespace)
                    try await vault.destroy(namespace, expectedGeneration: generation)
                } catch Vault.Failure.namespaceUnavailable {}
            }
            namespaces.removeAll()
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        }
        static func make() async throws -> Fixture {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-vault-" + UUID().uuidString)
            let root = directory.appendingPathComponent("Owned.app")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            do {
                for bundle in SelfRenewalApplicationMaterialFixture.bundles {
                    let target = bundle.relativePath == "." ? root : root.appendingPathComponent(bundle.relativePath)
                    try FileManager.default.createDirectory(at: target.appendingPathComponent("_CodeSignature"), withIntermediateDirectories: true)
                    for (path, encoded) in [("Info.plist", bundle.infoBase64), ("embedded.mobileprovision", bundle.profileBase64),
                                            ("_CodeSignature/CodeResources", bundle.resourcesBase64), ("Owned", bundle.codeBase64)] {
                        let bytes = try #require(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
                        try bytes.write(to: target.appendingPathComponent(path))
                    }
                    try Data("abc".utf8).write(to: target.appendingPathComponent("chapter.txt"))
                }
                let date = Date(timeIntervalSince1970: 1_792_540_800)
                let baseline = try await SelfRenewalApplicationMaterialVerifier.read(unpackedApplication: root,
                    codeAnchors: [SelfRenewalCMSFixture.rootCertificate], profileAnchors: [SelfRenewalCMSFixture.rootCertificate], at: date)
                return Fixture(directory: directory, baseline: baseline, issuer: try PKI.issuer(at: date), date: date)
            } catch {
                do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
                throw error
            }
        }
    }
}
