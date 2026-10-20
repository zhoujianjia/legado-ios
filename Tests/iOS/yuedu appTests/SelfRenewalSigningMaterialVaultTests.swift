import Foundation
import Security
import Testing
@testable import yuedu_app

@Suite("Owned software-Keychain signing material lifecycle", .serialized)
struct SelfRenewalSigningMaterialVaultTests {
    private typealias Vault = SelfRenewalSigningMaterialVault
    private typealias PKI = SelfRenewalSigningOwnedPKIFixture

    @Test("real permanent handle publishes verified profiles reopens signs verifies and revokes only its tag")
    func publishesReloadsSignsAndRevokesOwnedKeychainMaterial() async throws {
        try await Self.fixture { f in
            let namespace = try await f.namespace()
            let pending = try await f.generate(namespace)
            let protection = try Self.attributes(Self.tag(pending.privateKey))
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
            let otherTag = try Self.tag(otherKey.privateKey)
            let tag = try Self.tag(pending.privateKey)
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
    nonisolated private static func tag(_ key: SecKey) throws -> Data {
        let attributes = try #require(SecKeyCopyAttributes(key) as? [String: Any])
        return try #require(attributes[kSecAttrApplicationTag as String] as? Data)
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
        func failSave(afterSuccessfulSaves count: Int) { lock.lock(); defer { lock.unlock() }; remaining = count }
        func load(account: String) throws -> String? { try base.load(account: account) }
        func save(account: String, value: String) throws {
            lock.lock()
            let fail = remaining == 0
            if let count = remaining { remaining = count == 0 ? nil : count - 1 }
            lock.unlock()
            if fail { throw Vault.Failure.manifestWrite }
            try base.save(account: account, value: value)
        }
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
