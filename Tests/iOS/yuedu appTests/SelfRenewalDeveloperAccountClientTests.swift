import CryptoKit
import Foundation
import Security
import Testing
@testable import yuedu_app

@Suite("Controlled developer-services peer through the actual account URLSession and Vault", .serialized)
struct SelfRenewalDeveloperAccountClientTests {
    typealias Client = SelfRenewalDeveloperAccountClient
    typealias Vault = SelfRenewalSigningMaterialVault
    typealias PKI = SelfRenewalSigningOwnedPKIFixture

    @Test("real CSR signature exact portal fields and all three signed profiles publish through the same Vault")
    func submitsRealVaultCSRAndPublishesOnlyVerifiedOriginalIdentity() async throws {
        try await Self.fixture { f in
            let client = try await f.client()
            let observation = try await client.connect(f.credentials)
            #expect(observation.personalTeamMatched && !observation.appleSigningAuthorityEstablished)
            let lease = try await client.refreshMaterials(keyID: f.pending.id,
                expectedGeneration: f.pending.generation, machineName: "Owned Fixture")
            #expect(lease.keyID == f.pending.id && lease.generation == f.pending.generation + 1)
            #expect(lease.profiles.count == f.material.bundles.count)
            #expect(!lease.appleSigningAuthorityEstablished && !lease.replacementAuthorized && !lease.remoteRevocationEstablished)
            try await f.vault.validate(lease, for: f.material)
            let pending = try await client.pendingEnrollment()
            #expect(pending == nil)
            let stored = try f.storage.load(namespace: f.namespace.id)
            #expect(stored?.contains("owned-fresh-otp") == false)
            let facts = await f.peer.facts()
            #expect(facts.validCSRs == 1 && facts.profileRequests == 3)
            #expect(facts.paths == ["viewDeveloper.action", "listTeams.action", "viewDeveloper.action", "listTeams.action",
                "ios/listAppIds.action", "certificates", "ios/submitDevelopmentCSR.action", "ios/downloadTeamProvisioningProfile.action",
                "ios/downloadTeamProvisioningProfile.action", "ios/downloadTeamProvisioningProfile.action",
                "viewDeveloper.action", "listTeams.action"])
        }
    }

    @Test("wrong returned public key cannot reach profiles or replace the previous publication")
    func rejectsWrongCertificateKeyBeforeProfileRequests() async throws {
        try await Self.fixture { f in
            let client = try await f.client(); _ = try await client.connect(f.credentials)
            await f.peer.set(.wrongCertificate)
            do {
                _ = try await client.refreshMaterials(keyID: f.pending.id, expectedGeneration: f.pending.generation, machineName: "Owned")
                Issue.record("Wrong certificate key was accepted")
            } catch let error as Client.EnrollmentFailure {
                #expect(error.underlying as? Client.Failure == .keyMismatch)
                #expect(error.remoteCertificateMayHaveBeenIssued && !error.remoteProfilesMayHaveBeenRefreshed)
            }
            let current = try await f.vault.lease(in: f.namespace)
            let facts = await f.peer.facts()
            #expect(current.keyID == f.oldKeyID && current.generation == f.pending.generation)
            #expect(facts.profileRequests == 0)
            let pending = try await client.pendingEnrollment()
            #expect(pending?.phase == .certificateRequestIntent)
        }
    }

    @Test("tampered remote CMS is rejected by the existing Vault and preserves original material")
    func rejectsTamperedRemoteProfilesWithoutChangingPublication() async throws {
        try await Self.fixture { f in
            let client = try await f.client(); _ = try await client.connect(f.credentials)
            await f.peer.set(.tamperedProfile)
            do {
                _ = try await client.refreshMaterials(keyID: f.pending.id, expectedGeneration: f.pending.generation, machineName: "Owned")
                Issue.record("Tampered profile was accepted")
            } catch let error as Client.EnrollmentFailure {
                #expect(error.underlying is SelfRenewalCMSVerifier.Failure)
                #expect(error.remoteCertificateMayHaveBeenIssued && error.remoteProfilesMayHaveBeenRefreshed)
            }
            let current = try await f.vault.lease(in: f.namespace)
            #expect(current.keyID == f.oldKeyID && current.generation == f.pending.generation)
        }
    }

    @Test("server expiry and changed account/team invalidate credential reuse before any remote write")
    func invalidatesExpiredOrChangedPortalSession() async throws {
        for mode in [Mode.expired, .changedAccount, .changedTeam] {
            try await Self.fixture { f in
                let client = try await f.client(); _ = try await client.connect(f.credentials)
                await f.peer.set(mode)
                do { _ = try await client.observeSession(); Issue.record("Invalid remote session was retained") }
                catch let error as Client.Failure { #expect([.sessionExpired, .accountChanged, .teamChanged].contains(error)) }
                let before = await f.peer.facts()
                do { _ = try await client.observeSession(); Issue.record("Invalidated credentials were reused") }
                catch let error as Client.Failure { #expect(error == .signedOut) }
                let after = await f.peer.facts()
                #expect(before.paths == after.paths && after.validCSRs == 0)
                let stored = try f.storage.load(namespace: f.namespace.id)
                #expect(stored?.contains(f.credentials.xcodeToken) == false)
            }
        }
    }

    @Test("cancelled lost CSR ACK retains durable intent and refuses a second issue after client restart")
    func cancellationRetainsRemoteIntentAndPreventsDuplicateIssuance() async throws {
        try await Self.fixture { f in
            let client = try await f.client(); _ = try await client.connect(f.credentials)
            await f.peer.set(.holdCSR)
            let task = Task {
                do {
                    let lease = try await client.refreshMaterials(keyID: f.pending.id,
                        expectedGeneration: f.pending.generation, machineName: "Owned")
                    await f.peer.refreshFinished()
                    return lease
                } catch {
                    await f.peer.refreshFinished()
                    throw error
                }
            }
            let firstEvent = await withTaskCancellationHandler {
                await f.peer.waitForCSROrRefreshCompletion()
            } onCancel: { task.cancel() }
            if firstEvent == .refreshFinished {
                // Read the ACTUAL completed task, preserving its original
                // error. Even a pre-CSR failure now reaches fixture cleanup.
                _ = try await task.value
                Issue.record("Refresh completed before the controlled peer observed its CSR")
                return
            }
            task.cancel()
            do { _ = try await task.value; Issue.record("Cancelled remote enrollment was accepted") }
            catch let error as Client.EnrollmentFailure {
                #expect(error.underlying is CancellationError)
                #expect(error.remoteCertificateMayHaveBeenIssued && !error.remoteProfilesMayHaveBeenRefreshed)
            }
            let durableIntent = try await client.pendingEnrollment()
            #expect(durableIntent?.keyID == f.pending.id && durableIntent?.phase == .certificateRequestIntent)
            let reopened = try await f.client()
            let before = await f.peer.facts()
            do {
                _ = try await reopened.refreshMaterials(keyID: f.pending.id, expectedGeneration: f.pending.generation, machineName: "Owned")
                Issue.record("Uncertain issue was sent twice")
            } catch let error as Client.Failure { #expect(error == .reconciliationRequired) }
            let after = await f.peer.facts()
            #expect(before.paths == after.paths && after.validCSRs == 1)
        }
    }

    @Test("failed final account save retains actual Vault commit and reconciles without another request")
    func retainsCommittedPublicationWhenAccountFinalizationFails() async throws {
        try await Self.fixture { f in
            let client = try await f.client(); _ = try await client.connect(f.credentials)
            f.storage.failSave(afterSuccessfulSaves: 2)
            do {
                _ = try await client.refreshMaterials(keyID: f.pending.id, expectedGeneration: f.pending.generation, machineName: "Owned")
                Issue.record("Final account save failure was hidden")
            } catch let error as Client.PublicationFinalizationFailure {
                #expect(error.publishedLease.keyID == f.pending.id)
                let current = try await f.vault.lease(in: f.namespace)
                #expect(current.generation == error.publishedLease.generation)
            }
            let pending = try await client.pendingEnrollment()
            #expect(pending?.phase == .certificateObserved)
            let before = await f.peer.facts()
            let observed = try await client.finalizeObservedPublication()
            let after = await f.peer.facts()
            #expect(observed.keyID == f.pending.id && before.paths == after.paths)
            let cleared = try await client.pendingEnrollment()
            #expect(cleared == nil)
        }
    }

    @Test("stale revoked keys and absent original App IDs never dispatch a CSR")
    func rejectsStaleKeysAndMissingOriginalAppIDsBeforeRemoteMutation() async throws {
        try await Self.fixture { f in
            let client = try await f.client(); _ = try await client.connect(f.credentials)
            do {
                _ = try await client.refreshMaterials(keyID: f.pending.id, expectedGeneration: f.pending.generation - 1, machineName: "Owned")
                Issue.record("Stale generation was accepted")
            } catch let error as Client.EnrollmentFailure { #expect(error.underlying as? Vault.Failure == .staleGeneration) }
            await f.peer.set(.missingApp)
            do {
                _ = try await client.refreshMaterials(keyID: f.pending.id, expectedGeneration: f.pending.generation, machineName: "Owned")
                Issue.record("Missing original App ID was recreated")
            } catch let error as Client.EnrollmentFailure {
                #expect(error.underlying as? Client.Failure == .appIdentifierMissing)
                #expect(!error.remoteCertificateMayHaveBeenIssued)
            }
            try await f.vault.revoke(f.pending.id, in: f.namespace, expectedGeneration: f.pending.generation)
            let generation = try await f.vault.generation(in: f.namespace)
            do {
                _ = try await client.refreshMaterials(keyID: f.pending.id, expectedGeneration: generation, machineName: "Owned")
                Issue.record("Revoked key was submitted")
            } catch let error as Client.EnrollmentFailure { #expect(error.underlying as? Vault.Failure == .revoked) }
            let facts = await f.peer.facts()
            #expect(facts.validCSRs == 0)
        }
    }

    @Test("actual transport rejects redirect oversized and unauthenticated responses and redacts candidates")
    func rejectsUnsafeResponseEnvelopesAndRedactsCredentialDescriptions() async throws {
        for mode in [Mode.redirect, .oversized, .unauthorized, .malformedSuccess] {
            try await Self.fixture { f in
                let client = try await f.client()
                await f.peer.set(mode)
                do { _ = try await client.connect(f.credentials); Issue.record("Unsafe response was accepted as a session") }
                catch let error as Client.Failure {
                    switch mode {
                    case .redirect: #expect(error == .transport(SelfRenewalDeveloperAccountTransportFailure.redirect.rawValue))
                    case .oversized: #expect(error == .transport(SelfRenewalDeveloperAccountTransportFailure.responseLimit.rawValue))
                    case .unauthorized: #expect(error == .sessionExpired)
                    case .malformedSuccess: #expect(error == .malformedResponse)
                    default: Issue.record("Unexpected response fixture")
                    }
                }
                #expect(!String(reflecting: f.credentials).contains(f.credentials.xcodeToken))
                #expect(!String(describing: f.credentials).contains(f.credentials.dsid))
                let stored = try f.storage.load(namespace: f.namespace.id)
                #expect(stored == nil)
                let facts = await f.peer.facts()
                #expect(facts.paths == ["viewDeveloper.action"] && facts.validCSRs == 0)
            }
        }
    }

    @Test("erase-only stored logout preserves an unresolved CSR and refuses corrupt storage without needing a lease")
    func erasesStoredCredentialsWithoutMaterialAuthorityAndPreservesIntent() async throws {
        try await Self.fixture { f in
            let client = try await f.client(); _ = try await client.connect(f.credentials)
            await f.peer.set(.wrongCertificate)
            do {
                _ = try await client.refreshMaterials(keyID: f.pending.id,
                    expectedGeneration: f.pending.generation, machineName: "Owned")
                Issue.record("Wrong certificate was accepted")
            } catch let error as Client.EnrollmentFailure {
                #expect(error.underlying as? Client.Failure == .keyMismatch)
            }
            let before = try #require(try f.storage.load(namespace: f.namespace.id))
            let original = try #require(try JSONSerialization.jsonObject(with: Data(before.utf8)) as? [String: Any])
            let facts = await f.peer.facts()
            f.storage.failSave(afterSuccessfulSaves: 0)
            do {
                try Client.signOutStoredCredentials(namespaceID: f.namespace.id, storage: f.storage)
                Issue.record("Credential erasure acknowledged a failed real Keychain write")
            } catch let failure as Client.Failure { #expect(failure == .storage) }
            let afterFailure = try f.storage.load(namespace: f.namespace.id)
            #expect(afterFailure == before)
            try Client.signOutStoredCredentials(namespaceID: f.namespace.id, storage: f.storage)
            let erased = try #require(try f.storage.load(namespace: f.namespace.id))
            let decoded = try #require(try JSONSerialization.jsonObject(with: Data(erased.utf8)) as? [String: Any])
            #expect(decoded["credentials"] == nil)
            for key in ["namespaceID", "identitySHA256", "pin", "pending"] {
                let oldValue = try #require(original[key]); let newValue = try #require(decoded[key])
                let old = try JSONSerialization.data(withJSONObject: [key: oldValue], options: [.sortedKeys])
                let new = try JSONSerialization.data(withJSONObject: [key: newValue], options: [.sortedKeys])
                #expect(old == new)
            }
            let after = await f.peer.facts()
            #expect(after.paths == facts.paths && after.validCSRs == 1)
            try f.storage.save(namespace: f.namespace.id, value: "{corrupt}")
            do {
                try Client.signOutStoredCredentials(namespaceID: f.namespace.id, storage: f.storage)
                Issue.record("Corrupt storage was silently replaced")
            } catch let failure as Client.Failure { #expect(failure == .storage) }
            let corrupt = try f.storage.load(namespace: f.namespace.id)
            #expect(corrupt == "{corrupt}")
        }
    }

    @Test("lost CSR ACK recovers one exact new key-bound list candidate through actual profiles and Vault without another issue")
    func reconcilesLostCertificateACKWithUniqueActualCandidate() async throws {
        for published in [true, false] {
        try await Self.fixture(includePublishedMaterial: published) { f in
            let client = try await f.client(); _ = try await client.connect(f.credentials)
            try await Self.loseCertificateACK(client, peer: f.peer, keyID: f.pending.id, generation: f.pending.generation)
            let pending = try #require(try await client.pendingEnrollment())
            #expect(pending.phase == .certificateRequestIntent)
            let baseline = try #require(pending.reconciliationBaseline)
            #expect(baseline.requestDERSHA256.count == 32 && baseline.certificateSHA256s.count == (published ? 1 : 0))
            #expect((baseline.priorPublishedLeafSHA256 != nil) == published)
            await f.peer.usePEMCertificateList()
            let reopened = try await f.client()
            let lease = try await reopened.reconcilePendingMaterials()
            try await f.vault.validate(lease, for: f.material)
            #expect(lease.keyID == f.pending.id && lease.generation == f.pending.generation + 1 && lease.profiles.count == 3)
            #expect(!lease.appleSigningAuthorityEstablished && !lease.remoteRevocationEstablished && !lease.replacementAuthorized)
            let left = try await reopened.pendingEnrollment()
            #expect(left == nil)
            let facts = await f.peer.facts()
            #expect(facts.validCSRs == 1 && facts.certificateListRequests == 2 && facts.profileRequests == 3)
        }
        }
    }

    @Test("same-key reconciliation excludes every baseline DER and the old published leaf even when omitted from the baseline list")
    func excludesBaselineAndPublishedLeafWhenReusingTheKey() async throws {
        for omitPublished in [false, true] {
            try await Self.fixture { f in
                let old = try await f.vault.lease(in: f.namespace)
                let leaf = try #require(old.keyMaterial.certificateChainDER.first)
                let spare = try PKI.certificate(for: old.keyMaterial.privateKey, signedBy: f.issuer, at: f.date.addingTimeInterval(30))
                let prior = omitPublished ? [] : [leaf, spare]
                let peer = Peer(material: f.material, issuer: f.issuer, key: old.keyMaterial, date: f.date, priorCertificates: prior)
                PeerProtocol.install(peer)
                let client = try await f.client(); _ = try await client.connect(f.credentials)
                try await Self.loseCertificateACK(client, peer: peer, keyID: old.keyID, generation: old.generation)
                let before = try #require(try await client.pendingEnrollment())
                #expect(before.reconciliationBaseline?.priorPublishedLeafSHA256 == Data(SHA256.hash(data: leaf)))
                #expect(before.reconciliationBaseline?.certificateSHA256s.count == prior.count)
                await peer.usePEMCertificateList()
                await peer.setCertificateList(omitPublished ? .publishedOnly : .priorOnly)
                do { _ = try await client.reconcilePendingMaterials(); Issue.record("An old same-key certificate was called a new issue") }
                catch let failure as Client.EnrollmentFailure { #expect(failure.underlying as? Client.Failure == .reconciliationRequired) }
                let retained = try await client.pendingEnrollment()
                #expect(retained == before)
                let unchanged = try await f.vault.lease(in: f.namespace)
                #expect(unchanged.generation == old.generation)
                await peer.setCertificateList(.normal)
                let lease = try await client.reconcilePendingMaterials()
                let newLeaf = try #require(lease.keyMaterial.certificateChainDER.first)
                #expect(newLeaf != leaf && !prior.contains(newLeaf) && lease.keyID == old.keyID)
                // The original test time is still inside the genuinely signed
                // new certificate validity, verified by the real Vault chain.
                try await f.vault.validate(lease, for: f.material)
                let facts = await peer.facts()
                #expect(facts.validCSRs == 1 && facts.profileRequests == 3)
            }
        }
    }

    @Test("ambiguous missing or incompletely enumerated remote certificates preserve the exact pending bytes and original publication")
    func retainsIntentForAmbiguousMissingAndIncompleteCertificateLists() async throws {
        for mode in [CertificateListMode.priorOnly, .ambiguous, .missingCompleteness, .paginated, .nextCursor, .truncatedMetadata, .missingDER, .wrongMachine] {
            try await Self.fixture { f in
                let client = try await f.client(); _ = try await client.connect(f.credentials)
                try await Self.loseCertificateACK(client, peer: f.peer, keyID: f.pending.id, generation: f.pending.generation)
                let before = try f.storage.load(namespace: f.namespace.id)
                await f.peer.setCertificateList(mode)
                let reopened = try await f.client()
                do { _ = try await reopened.reconcilePendingMaterials(); Issue.record("Uncertain certificate list was accepted") }
                catch let failure as Client.EnrollmentFailure {
                    let code = failure.underlying as? Client.Failure
                    #expect(code == .reconciliationRequired || code == .ambiguousCertificate || code == .incompleteCertificateList || code == .malformedResponse)
                    #expect(failure.remoteCertificateMayHaveBeenIssued && !failure.remoteProfilesMayHaveBeenRefreshed)
                }
                let after = try f.storage.load(namespace: f.namespace.id)
                #expect(before == after)
                let old = try await f.vault.lease(in: f.namespace)
                #expect(old.keyID == f.oldKeyID && old.generation == f.pending.generation)
                let facts = await f.peer.facts()
                #expect(facts.validCSRs == 1 && facts.profileRequests == 0)
            }
        }
    }

    @Test("legacy pending and changed CSR key digest DER binding or actual Vault generation cannot trigger a second CSR or publication")
    func rejectsLegacyCSRBindingAndChangedGenerationWithoutReissue() async throws {
        try await Self.fixture { f in
            let client = try await f.client(); _ = try await client.connect(f.credentials)
            try await Self.loseCertificateACK(client, peer: f.peer, keyID: f.pending.id, generation: f.pending.generation)
            let original = try #require(try f.storage.load(namespace: f.namespace.id))
            for field in ["legacy", "keyID", "requestPublicKeySHA256", "requestDERSHA256", "futureIntent"] {
                let root = try JSONSerialization.jsonObject(with: Data(original.utf8))
                var record = try #require(root as? [String: Any])
                var pending = try #require(record["pending"] as? [String: Any])
                if field == "legacy" { pending.removeValue(forKey: "reconciliationBaseline") }
                else if field == "keyID" { pending[field] = UUID().uuidString }
                else if field == "requestPublicKeySHA256" { pending[field] = Data(repeating: 0x7a, count: 32).base64EncodedString() }
                else if field == "futureIntent" {
                    let timestamp = try #require(pending["startedAt"] as? NSNumber)
                    pending["startedAt"] = timestamp.doubleValue + 60
                }
                else {
                    var baseline = try #require(pending["reconciliationBaseline"] as? [String: Any])
                    baseline[field] = Data(repeating: 0x7b, count: 32).base64EncodedString(); pending["reconciliationBaseline"] = baseline
                }
                record["pending"] = pending
                let bytes = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                let modified = try #require(String(data: bytes, encoding: .utf8))
                try f.storage.save(namespace: f.namespace.id, value: modified)
                let reopened = try await f.client()
                do { _ = try await reopened.reconcilePendingMaterials(); Issue.record("Unbound persisted CSR was accepted") }
                catch let error as Client.Failure { #expect(error == .reconciliationRequired) }
                catch let error as Client.EnrollmentFailure {
                    #expect(error.underlying as? Client.Failure == .keyMismatch || error.underlying as? Vault.Failure == .missingKey)
                }
                catch let error as Vault.Failure { #expect(error == .clockMovedBackwards) }
                let kept = try f.storage.load(namespace: f.namespace.id)
                #expect(kept == modified)
                try f.storage.save(namespace: f.namespace.id, value: original)
            }
            _ = try await f.vault.generateKey(in: f.namespace, expectedGeneration: f.pending.generation)
            let reopened = try await f.client()
            do { _ = try await reopened.reconcilePendingMaterials(); Issue.record("Stale Vault generation was accepted") }
            catch let error as Vault.Failure { #expect(error == .staleGeneration) }
            let facts = await f.peer.facts()
            #expect(facts.validCSRs == 1 && facts.profileRequests == 0 && facts.certificateListRequests == 1)
        }
    }

    @Test("observed-certificate recovery reuses exact candidate then preserves actual Vault publication on a lost finalization write")
    func resumesObservedCertificateAndFinalizesItsActualPublicationLocally() async throws {
        try await Self.fixture { f in
            let client = try await f.client(); _ = try await client.connect(f.credentials)
            await f.peer.set(.tamperedProfile)
            do { _ = try await client.refreshMaterials(keyID: f.pending.id, expectedGeneration: f.pending.generation, machineName: "Owned") }
            catch let error as Client.EnrollmentFailure { #expect(error.underlying is SelfRenewalCMSVerifier.Failure) }
            let observed = try #require(try await client.pendingEnrollment())
            #expect(observed.phase == .certificateObserved)
            await f.peer.set(.normal)
            f.storage.failSave(afterSuccessfulSaves: 1)
            let reopened = try await f.client()
            do { _ = try await reopened.reconcilePendingMaterials(); Issue.record("Failed finalization write was hidden") }
            catch let error as Client.PublicationFinalizationFailure {
                #expect(error.publishedLease.generation == f.pending.generation + 1)
                try await f.vault.validate(error.publishedLease, for: f.material)
            }
            // A legacy observed pending record with credentials erased can
            // finalize ONLY the real generation+1 publication, without network.
            let raw = try #require(try f.storage.load(namespace: f.namespace.id))
            let value = try JSONSerialization.jsonObject(with: Data(raw.utf8))
            var record = try #require(value as? [String: Any])
            var pending = try #require(record["pending"] as? [String: Any])
            pending.removeValue(forKey: "reconciliationBaseline"); record["pending"] = pending
            let bytes = try JSONSerialization.data(withJSONObject: record)
            try f.storage.save(namespace: f.namespace.id, value: String(decoding: bytes, as: UTF8.self))
            try Client.signOutStoredCredentials(namespaceID: f.namespace.id, storage: f.storage)
            let before = await f.peer.facts()
            let finalizer = try await f.client()
            let lease = try await finalizer.reconcilePendingMaterials()
            let after = await f.peer.facts()
            #expect(before.paths == after.paths && after.validCSRs == 1 && lease.keyID == f.pending.id)
            let empty = try await finalizer.pendingEnrollment()
            #expect(empty == nil)
        }
    }

    @Test("cancelling the real held list request preserves durable unknown intent and later resumes without another issue")
    func cancellationDuringCertificateListRetainsUnknownIntent() async throws {
        try await Self.fixture { f in
            let client = try await f.client(); _ = try await client.connect(f.credentials)
            try await Self.loseCertificateACK(client, peer: f.peer, keyID: f.pending.id, generation: f.pending.generation)
            let before = try f.storage.load(namespace: f.namespace.id)
            await f.peer.set(.holdCertificateList)
            let operation = Task {
                do { let lease = try await client.reconcilePendingMaterials(); await f.peer.reconciliationFinished(); return lease }
                catch { await f.peer.reconciliationFinished(); throw error }
            }
            let event = await withTaskCancellationHandler { await f.peer.waitForListOrCompletion() } onCancel: { operation.cancel() }
            if event == .operationFinished {
                _ = try await operation.value
                Issue.record("Reconciliation finished before its actual list reached the peer")
                return
            }
            operation.cancel()
            do { _ = try await operation.value; Issue.record("Cancelled list became a publication") }
            catch let failure as Client.EnrollmentFailure {
                #expect(failure.underlying is CancellationError)
                #expect(failure.remoteCertificateMayHaveBeenIssued && !failure.remoteProfilesMayHaveBeenRefreshed)
            }
            let kept = try f.storage.load(namespace: f.namespace.id)
            #expect(kept == before)
            await f.peer.set(.normal)
            let lease = try await client.reconcilePendingMaterials()
            try await f.vault.validate(lease, for: f.material)
            let facts = await f.peer.facts()
            #expect(facts.validCSRs == 1 && facts.profileRequests == 3)
        }
    }

    private static func loseCertificateACK(_ client: Client, peer: Peer, keyID: UUID, generation: UInt64) async throws {
        await peer.set(.lostCSRACK)
        do { _ = try await client.refreshMaterials(keyID: keyID, expectedGeneration: generation, machineName: "Owned lost ACK"); Issue.record("Controlled lost ACK was hidden") }
        catch let error as Client.EnrollmentFailure {
            #expect(error.remoteCertificateMayHaveBeenIssued && !error.remoteProfilesMayHaveBeenRefreshed)
        }
        let pending = try #require(try await client.pendingEnrollment())
        #expect(pending.phase == .certificateRequestIntent)
        let certificate = await peer.certificate
        #expect(certificate != nil)
        await peer.set(.normal)
    }

    enum Mode: Sendable {
        case normal, wrongCertificate, tamperedProfile, expired, changedAccount, changedTeam, holdCSR, missingApp
        case redirect, oversized, unauthorized, malformedSuccess, lostCSRACK, holdCertificateList
    }
    enum CertificateListMode: Sendable {
        case normal, priorOnly, publishedOnly, ambiguous, missingCompleteness, paginated, nextCursor, truncatedMetadata, missingDER, wrongMachine
    }
    actor Peer {
        let material: SelfRenewalApplicationMaterialVerifier.Materials
        let issuer: Vault.KeyMaterial
        let key: Vault.KeyMaterial
        let date: Date
        private var issuedMaterialDate: Date
        var mode: Mode = .normal
        var paths: [String] = []
        var validCSRs = 0, profileRequests = 0
        var certificate: Data?
        var certificateMachineID: UUID?
        let priorCertificates: [Data]
        var certificateListMode: CertificateListMode = .normal
        private var pemCertificateList = false
        var certificateListRequests = 0
        enum ListEvent: Sendable, Equatable { case listArrived, operationFinished }
        private var firstListEvent: ListEvent?
        private var listWaiters: [CheckedContinuation<ListEvent, Never>] = []
        enum EnrollmentEvent: Sendable, Equatable { case csrArrived, refreshFinished }
        private var firstEnrollmentEvent: EnrollmentEvent?
        private var enrollmentWaiters: [CheckedContinuation<EnrollmentEvent, Never>] = []
        init(material: SelfRenewalApplicationMaterialVerifier.Materials, issuer: Vault.KeyMaterial, key: Vault.KeyMaterial,
            date: Date, priorCertificates: [Data]? = nil) {
            self.material = material; self.issuer = issuer; self.key = key; self.date = date
            issuedMaterialDate = date
            self.priorCertificates = priorCertificates ?? key.certificateChainDER.first.map { [$0] } ?? []
        }
        func set(_ mode: Mode) { self.mode = mode }
        func issueNewMaterial(at date: Date) { issuedMaterialDate = date }
        func setCertificateList(_ value: CertificateListMode) { certificateListMode = value }
        func usePEMCertificateList() { pemCertificateList = true }
        func waitForListOrCompletion() async -> ListEvent {
            if let firstListEvent { return firstListEvent }
            return await withCheckedContinuation { listWaiters.append($0) }
        }
        func reconciliationFinished() { observeList(.operationFinished) }
        private func observeList(_ event: ListEvent) {
            guard firstListEvent == nil else { return }
            firstListEvent = event; let waiting = listWaiters; listWaiters.removeAll()
            waiting.forEach { $0.resume(returning: event) }
        }
        func waitForCSROrRefreshCompletion() async -> EnrollmentEvent {
            if let firstEnrollmentEvent { return firstEnrollmentEvent }
            return await withCheckedContinuation { enrollmentWaiters.append($0) }
        }
        func refreshFinished() { observe(.refreshFinished) }
        private func observe(_ event: EnrollmentEvent) {
            guard firstEnrollmentEvent == nil else { return }
            firstEnrollmentEvent = event
            let waiting = enrollmentWaiters; enrollmentWaiters.removeAll()
            waiting.forEach { $0.resume(returning: event) }
        }
        struct Facts: Sendable { let paths: [String]; let validCSRs: Int; let profileRequests: Int; let certificateListRequests: Int }
        func facts() -> Facts { Facts(paths: paths, validCSRs: validCSRs, profileRequests: profileRequests, certificateListRequests: certificateListRequests) }
        func statusCode() -> Int { mode == .redirect ? 302 : (mode == .unauthorized ? 401 : 200) }
        func handle(_ request: URLRequest) async throws -> Data {
            #expect(request.url?.host == "developerservices2.apple.com" && request.url?.scheme == "https")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "X-Apple-GS-Token") == "OWNED-CONTROLLED-PEER-TOKEN-CANARY")
            #expect(request.value(forHTTPHeaderField: "X-Apple-App-Info") == "com.apple.gs.xcode.auth")
            let prefix = "/services/QH65B2/"
            let url = try #require(request.url)
            if url.path == "/services/v1/certificates" { return try await certificateList(request) }
            #expect(url.path.hasPrefix(prefix))
            let path = String(url.path.dropFirst(prefix.count)); paths.append(path)
            let body = try Self.requestBody(request)
            #expect(body["clientId"] as? String == "XABBG36SBA" && body["protocolVersion"] as? String == "QH65B2")
            if mode == .oversized { return Data(repeating: 0x61, count: 1_048_577) }
            if mode == .redirect || mode == .unauthorized { return Data() }
            if mode == .malformedSuccess { return try Self.plist(["resultCode": true]) }
            if mode == .expired { return try Self.plist(["resultCode": 1100]) }
            switch path {
            case "viewDeveloper.action":
                return try Self.plist(["resultCode": 0, "developer": ["personId": mode == .changedAccount ? 9001 : 2001,
                    "email": "owned@example.invalid", "firstName": "Owned", "lastName": "Account"]])
            case "listTeams.action":
                return try Self.plist(["resultCode": 0, "teams": [["teamId": mode == .changedTeam ? "OTHERTEAM1" : material.bundles[0].slices[0].teamIdentifier,
                    "type": "Individual", "memberships": [["name": "Free Provisioning"]]]]])
            case "ios/listAppIds.action":
                let entries = mode == .missingApp ? [] : material.bundles.enumerated().map { ["identifier": $0.element.bundleIdentifier, "appIdId": String($0.offset)] }
                return try Self.plist(["resultCode": 0, "appIds": entries])
            case "ios/submitDevelopmentCSR.action":
                #expect(body["teamId"] as? String == material.bundles[0].slices[0].teamIdentifier)
                let pem = try #require(body["csrContent"] as? String)
                try verifyCSR(pem)
                validCSRs += 1
                observe(.csrArrived)
                if mode == .holdCSR {
                    let pair = AsyncStream<Void>.makeStream()
                    for await _ in pair.stream {}
                    throw CancellationError()
                }
                let signerKey = mode == .wrongCertificate ? issuer.privateKey : key.privateKey
                // A same-key issue must actually be a different signed
                // certificate, rather than deterministic DER of its old leaf.
                let leaf = try PKI.certificate(for: signerKey, signedBy: issuer, at: issuedMaterialDate.addingTimeInterval(60))
                certificate = leaf
                let rawMachineID = try #require(body["machineId"] as? String)
                certificateMachineID = try #require(UUID(uuidString: rawMachineID))
                if mode == .lostCSRACK { throw URLError(.networkConnectionLost) }
                return try Self.plist(["resultCode": 0, "certRequest": ["certContent": leaf]])
            case "ios/downloadTeamProvisioningProfile.action":
                profileRequests += 1
                let id = try #require(body["appIdId"] as? String)
                let index = try #require(Int(id))
                #expect(material.bundles.indices.contains(index))
                let bundle = material.bundles[index]
                let original = try #require(material.profiles.profiles.first { $0.file.relativePath == bundle.profileRelativePath })
                let leaf = try #require(certificate)
                var bytes = try PKI.profile(from: original, developerCertificate: leaf, issuer: issuer, at: issuedMaterialDate)
                if mode == .tamperedProfile { bytes[10] ^= 1 }
                return try Self.plist(["resultCode": 0, "provisioningProfile": ["encodedProfile": bytes]])
            default: throw CocoaError(.coderInvalidValue)
            }
        }
        private func certificateList(_ request: URLRequest) async throws -> Data {
            paths.append("certificates"); certificateListRequests += 1
            #expect(request.value(forHTTPHeaderField: "X-HTTP-Method-Override") == "GET")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/vnd.api+json")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.api+json")
            let data = try Self.requestBytes(request)
            let object = try JSONSerialization.jsonObject(with: data)
            let body = try #require(object as? [String: String])
            #expect(Set(body.keys) == ["urlEncodedQueryParams"])
            let encoded = try #require(body["urlEncodedQueryParams"])
            var components = URLComponents(); components.query = encoded
            let items = try #require(components.queryItems)
            #expect(items.count == 2)
            #expect(items.first { $0.name == "teamId" }?.value == material.bundles[0].slices[0].teamIdentifier)
            #expect(items.first { $0.name == "filter[certificateType]" }?.value == "IOS_DEVELOPMENT")
            if mode == .holdCertificateList {
                observeList(.listArrived)
                let pair = AsyncStream<Void>.makeStream()
                for await _ in pair.stream {}
                throw CancellationError()
            }
            var certs = priorCertificates
            if certificateListMode == .publishedOnly { certs = key.certificateChainDER.first.map { [$0] } ?? [] }
            else if certificateListMode != .priorOnly, let certificate { certs.append(certificate) }
            if certificateListMode == .ambiguous {
                certs.append(try PKI.certificate(for: key.privateKey, signedBy: issuer, at: issuedMaterialDate.addingTimeInterval(120)))
            }
            var rows: [[String: Any]] = []
            for (index, bytes) in certs.enumerated() {
                let wireBytes: Data
                if pemCertificateList {
                    wireBytes = Data(("-----BEGIN CERTIFICATE-----\r\n" + bytes.base64EncodedString() + "\r\n-----END CERTIFICATE-----\r\n").utf8)
                } else { wireBytes = bytes }
                var attributes: [String: Any] = ["certificateContent": wireBytes.base64EncodedString()]
                if bytes == certificate, let machine = certificateMachineID {
                    attributes["machineId"] = certificateListMode == .wrongMachine ? UUID().uuidString : machine.uuidString
                }
                if certificateListMode == .missingDER { attributes.removeValue(forKey: "certificateContent") }
                rows.append(["type": "certificates", "id": "owned-certificate-" + String(index), "attributes": attributes])
            }
            var result: [String: Any] = ["data": rows, "meta": ["paging": ["total": rows.count, "limit": rows.isEmpty ? 0 : 200, "nextCursor": NSNull()]], "links": ["next": NSNull()]]
            if certificateListMode == .missingCompleteness { result.removeValue(forKey: "meta") }
            if certificateListMode == .paginated { result["links"] = ["next": "https://developerservices2.apple.com/services/v1/certificates?page=2"] }
            if certificateListMode == .nextCursor { result["meta"] = ["paging": ["total": rows.count, "limit": 200, "nextCursor": "owned-next-page"]] }
            if certificateListMode == .truncatedMetadata { result["meta"] = ["paging": ["total": rows.count, "limit": 256], "truncated": true] }
            return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        }
        private func verifyCSR(_ pem: String) throws {
            let lines = pem.split(separator: "\n")
            #expect(lines.first == "-----BEGIN CERTIFICATE REQUEST-----" && lines.last == "-----END CERTIFICATE REQUEST-----")
            let encoded = lines.dropFirst().dropLast().joined()
            let der = try #require(Data(base64Encoded: encoded))
            let fields = try SelfRenewalCMSVerifier.children(of: SelfRenewalCMSVerifier.parseDER(der))
            #expect(fields.count == 3)
            let info = try SelfRenewalCMSVerifier.children(of: fields[0])
            let spki = try SelfRenewalCMSVerifier.children(of: info[2])
            let publicBytes = Data(spki[1].body.dropFirst())
            var error: Unmanaged<CFError>?
            let rawKey = SecKeyCreateWithData(publicBytes as CFData, [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPublic, kSecAttrKeySizeInBits as String: 2048] as CFDictionary, &error)
            if let error { _ = error.takeRetainedValue() }
            let publicKey = try #require(rawKey)
            #expect(SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, fields[0].originalDER as CFData,
                Data(fields[2].body.dropFirst()) as CFData, nil))
            let keyPublic = try #require(SecKeyCopyPublicKey(key.privateKey))
            let expected = try #require(SecKeyCopyExternalRepresentation(keyPublic, nil) as Data?)
            #expect(publicBytes == expected)
        }
        private static func plist(_ value: [String: Any]) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        }
        private static func requestBody(_ request: URLRequest) throws -> [String: Any] {
            let raw = try PropertyListSerialization.propertyList(from: requestBytes(request), options: [], format: nil)
            return try #require(raw as? [String: Any])
        }
        private static func requestBytes(_ request: URLRequest) throws -> Data {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0, data.count + count <= 32_768 else { throw CocoaError(.fileReadTooLarge) }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            return data
        }
    }

    final class PeerProtocol: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var peer: Peer?
        private let operationLock = NSLock()
        private var operation: Task<Void, Never>?
        private var stopped = false
        static func install(_ peer: Peer?) { lock.lock(); defer { lock.unlock() }; self.peer = peer }
        private static func current() -> Peer? { lock.lock(); defer { lock.unlock() }; return peer }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let peer = Self.current() else { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return }
            let started = Task {
                do {
                    let data = try await peer.handle(request)
                    try Task.checkCancellation()
                    let statusCode = await peer.statusCode()
                    let mediaType = request.url?.path == "/services/v1/certificates" ? "application/vnd.api+json" : "text/x-xml-plist"
                    let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": mediaType, "Content-Length": String(data.count)])!
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
                } catch { client?.urlProtocol(self, didFailWithError: URLError(error is CancellationError ? .cancelled : .badServerResponse)) }
            }
            operationLock.lock(); let alreadyStopped = stopped
            if !alreadyStopped { operation = started }; operationLock.unlock()
            if alreadyStopped { started.cancel() }
        }
        override func stopLoading() {
            operationLock.lock(); stopped = true; let current = operation; operation = nil; operationLock.unlock()
            current?.cancel()
        }
    }
    final class FaultStorage: @unchecked Sendable, SelfRenewalDeveloperSessionStorage {
        let base = SelfRenewalDeveloperKeychainSessionStorage()
        private let lock = NSLock(); private var remaining: Int?
        func failSave(afterSuccessfulSaves count: Int) { lock.lock(); defer { lock.unlock() }; remaining = count }
        func load(namespace: UUID) throws -> String? { try base.load(namespace: namespace) }
        func save(namespace: UUID, value: String) throws {
            lock.lock(); let fail = remaining == 0
            if let count = remaining { remaining = count == 0 ? nil : count - 1 }; lock.unlock()
            if fail { throw Client.Failure.storage }; try base.save(namespace: namespace, value: value)
        }
        func cleanup(namespace: UUID) throws {
            guard KeychainHelper.delete(account: namespace.uuidString, service: "com.yuedu.selfRenewal.developerSession.v1", synchronizable: false) else { throw Client.Failure.storage }
        }
    }
    final class Fixture: @unchecked Sendable {
        let directory: URL; let material: SelfRenewalApplicationMaterialVerifier.Materials
        let date: Date; let vault: Vault; let namespace: Vault.Namespace; let pending: Vault.PendingKey
        let oldKeyID: UUID; let issuer: Vault.KeyMaterial; let storage = FaultStorage(); let peer: Peer
        var credentials: Client.Credentials { .init(dsid: "2000000", xcodeToken: "OWNED-CONTROLLED-PEER-TOKEN-CANARY", expiresAt: date.addingTimeInterval(3_600)) }
        init(directory: URL, material: SelfRenewalApplicationMaterialVerifier.Materials, date: Date,
            vault: Vault, namespace: Vault.Namespace, pending: Vault.PendingKey, oldKeyID: UUID, issuer: Vault.KeyMaterial,
            priorCertificate: Data?) {
            self.directory = directory; self.material = material; self.date = date; self.vault = vault; self.namespace = namespace
            self.pending = pending; self.oldKeyID = oldKeyID; self.issuer = issuer
            peer = Peer(material: material, issuer: issuer,
                key: Vault.KeyMaterial(privateKey: pending.privateKey, certificateChainDER: []), date: date, priorCertificates: priorCertificate.map { [$0] } ?? [])
        }
        func client() async throws -> Client {
            let date = date
            return try await Client.open(vault: vault, namespace: namespace, identity: material, issuerChainDER: issuer.certificateChainDER,
                transport: SelfRenewalDeveloperURLSessionTransport(protocolClasses: [PeerProtocol.self]), storage: storage,
                freshAnisette: { Client.Anisette(machineID: "owned-machine", oneTimePassword: "owned-fresh-otp", localUserID: "owned-local-user",
                    routingInfo: 1, deviceID: "owned-device-id", clientInfo: "Owned controlled peer", issuedAt: date, locale: "en_US", timeZone: "UTC") }, clock: { date })
        }
        func cleanup() async throws {
            // Cleanup owns only this fixture's exact resources. Await it even
            // when the real test worker was cancelled; do not cancel cleanup.
            try await Task.detached {
                PeerProtocol.install(nil)
                // AppSession may have published through its own Vault actor.
                // Reopen the actual manifest before destroying these owned keys.
                let current = try await self.vault.resume(namespaceID: self.namespace.id, identity: self.material)
                let generation = try await self.vault.generation(in: current)
                try await self.vault.destroy(current, expectedGeneration: generation)
                try self.storage.cleanup(namespace: current.id)
                try FileManager.default.removeItem(at: self.directory)
            }.value
        }
        static func make(includePublishedMaterial: Bool = true, nearOriginalProfileExpiry: Bool = false) async throws -> Fixture {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-developer-account-" + UUID().uuidString)
            let root = directory.appendingPathComponent("Owned.app")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var cleanupVault: Vault?; var cleanupNamespace: Vault.Namespace?
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
                let originalDate = Date(timeIntervalSince1970: 1_792_540_800)
                let originalMaterial = try await SelfRenewalApplicationMaterialVerifier.read(unpackedApplication: root,
                    codeAnchors: [SelfRenewalCMSFixture.rootCertificate], profileAnchors: [SelfRenewalCMSFixture.rootCertificate], at: originalDate)
                let date: Date
                let material: SelfRenewalApplicationMaterialVerifier.Materials
                if nearOriginalProfileExpiry {
                    date = try #require(originalMaterial.profiles.profiles.map(\.summary.expiresAt).min()).addingTimeInterval(-1800)
                    material = try await SelfRenewalApplicationMaterialVerifier.read(unpackedApplication: root,
                        codeAnchors: [SelfRenewalCMSFixture.rootCertificate], profileAnchors: [SelfRenewalCMSFixture.rootCertificate], at: date)
                } else { date = originalDate; material = originalMaterial }
                let issuer = try PKI.issuer(at: date)
                let vault = Vault(codeAnchors: issuer.certificateChainDER, profileAnchors: issuer.certificateChainDER, clock: { date }); cleanupVault = vault
                let namespace = try await vault.create(identity: material); cleanupNamespace = namespace
                let generation = try await vault.generation(in: namespace)
                let old = try await vault.generateKey(in: namespace, expectedGeneration: generation)
                let leaf = try PKI.certificate(for: old.privateKey, signedBy: issuer, at: date)
                let profiles = try material.bundles.map { bundle -> Vault.ProfileInput in
                    let original = try #require(material.profiles.profiles.first { $0.file.relativePath == bundle.profileRelativePath })
                    return .init(componentRelativePath: bundle.componentRelativePath,
                        bytes: try PKI.profile(from: original, developerCertificate: leaf, issuer: issuer, at: date))
                }
                if includePublishedMaterial {
                    _ = try await vault.publish(in: namespace, keyID: old.id, expectedGeneration: old.generation,
                        certificateChainDER: [leaf] + issuer.certificateChainDER, profiles: profiles)
                }
                let currentGeneration = try await vault.generation(in: namespace)
                let pending = try await vault.generateKey(in: namespace, expectedGeneration: currentGeneration)
                let fixture = Fixture(directory: directory, material: material, date: date, vault: vault, namespace: namespace,
                    pending: pending, oldKeyID: old.id, issuer: issuer, priorCertificate: includePublishedMaterial ? leaf : nil)
                PeerProtocol.install(fixture.peer)
                return fixture
            } catch {
                let vault = cleanupVault, namespace = cleanupNamespace
                await Task.detached {
                    if let vault, let namespace {
                        do { let generation = try await vault.generation(in: namespace); try await vault.destroy(namespace, expectedGeneration: generation) }
                        catch { Issue.record(error) }
                    }
                    do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
                }.value
                throw error
            }
        }
    }
    nonisolated static func fixture(includePublishedMaterial: Bool = true, nearOriginalProfileExpiry: Bool = false,
        _ action: @escaping @Sendable (Fixture) async throws -> Void) async throws {
        let worker = Task.detached {
            let value = try await Fixture.make(includePublishedMaterial: includePublishedMaterial, nearOriginalProfileExpiry: nearOriginalProfileExpiry)
            do { try await action(value); try await value.cleanup() }
            catch { do { try await value.cleanup() } catch { Issue.record(error) }; throw error }
        }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
