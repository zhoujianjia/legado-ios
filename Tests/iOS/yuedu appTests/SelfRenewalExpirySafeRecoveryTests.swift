import CryptoKit
import Foundation
import Security
import Testing
@testable import yuedu_app

@Suite("Existing authenticated renewal recovery without live signing materials", .serialized)
struct SelfRenewalExpirySafeRecoveryTests {
    typealias Package = SelfRenewalControlledPackageSignerTests
    typealias Coordinator = SelfRenewalControlledRenewalCoordinator
    typealias Journal = SelfRenewalTransactionJournal
    typealias Vault = SelfRenewalSigningMaterialVault
    typealias Peer = SelfRenewalAuthenticatedInstallationFixture
    typealias Session = SelfRenewalAppSession

    @Test("a genuinely expired modern profile does not prevent existing unknown Upgrade Lookup")
    func recoversExpiredProfileUnknownUpgradeUsingOnlyAuthenticatedLookup() async throws {
        try await Package.fixture { f in
            try await Self.withJournal(f) { journal, _ in
                let original = Coordinator(journal: journal, vault: f.vault, namespace: f.namespace, clock: { f.date })
                let ready = try await Self.prepare(original, f)
                let bytes = try await Self.bytes(journal, ready)
                try await Peer.withPeer(.disconnectAfterUpgradeThenRecover, bytes: bytes,
                    bundle: ready.record.bundleIdentifier, version: ready.record.bundleVersion, at: f.date) { peer in
                    do { _ = try await original.submit(pairing: peer.pairing, endpoint: peer.endpoint, timeoutSeconds: 12); Issue.record("lost Upgrade response accepted") }
                    catch let error as Coordinator.Interrupted { #expect(error.mayHaveSubmittedUpgrade) }
                    let expired = try #require(f.lease.profiles.map(\.summary.expiresAt).max()).addingTimeInterval(60)
                    let baseline = try await SelfRenewalIPAUnpacker.verify(ipa: f.input,
                        codeAnchors: [f.oldAnchor], profileAnchors: [f.oldAnchor], at: f.date)
                    let lateVault = Vault(codeAnchors: f.issuer.certificateChainDER,
                        profileAnchors: f.issuer.certificateChainDER, clock: { expired })
                    let ns = try await lateVault.resume(namespaceID: f.namespace.id, identity: baseline.application)
                    do { _ = try await lateVault.lease(in: ns); Issue.record("expired real profile remained a signing lease") }
                    catch let error as SelfRenewalProvisioningProfileVerifier.Failure { #expect(error == .profileExpired) }
                    let recovery = try await Coordinator.recoveryOnly(journal: journal, clock: { expired })
                    let only = await recovery.isRecoveryOnly(); #expect(only)
                    await Self.rejectSigning(recovery, fixture: f, peer: peer)
                    let result = try await recovery.recover(pairing: peer.pairing, endpoint: peer.endpoint, timeoutSeconds: 12)
                    guard case .authenticatedLookup(let saved, let observation) = result else { Issue.record("expected existing Lookup only"); return }
                    #expect(saved.record.phase == .lookupObserved && !saved.record.renewalVerified)
                    #expect(observation.presence == .reported(bundleIdentifier: peer.bundle, bundleVersion: peer.version))
                    #expect(saved.record.submission != nil && saved.record.safePreSubmissionCleanup == nil)
                    let observed = peer.observed.snapshot
                    #expect(observed.upgradeRequests == 1 && observed.lookupRequests == 1)
                    #expect(observed.openedFileHandles == 1 && observed.removedPaths.isEmpty)
                    let candidate = try await Self.bytes(journal, saved); #expect(candidate == bytes)
                }
            }
        }
    }

    @Test("revoked/unpublished signing material still permits only owned interrupted-upload cleanup")
    func cleansInterruptedUploadWithoutSigningLeaseAndRetainsCandidate() async throws {
        try await Package.fixture { f in
            try await Self.withJournal(f) { journal, _ in
                let original = Coordinator(journal: journal, vault: f.vault, namespace: f.namespace, clock: { f.date })
                let ready = try await Self.prepare(original, f); let bytes = try await Self.bytes(journal, ready)
                try await Peer.withPeer(.partialUploadThenRecover, bytes: bytes,
                    bundle: ready.record.bundleIdentifier, version: ready.record.bundleVersion, at: f.date) { peer in
                    do { _ = try await original.submit(pairing: peer.pairing, endpoint: peer.endpoint, timeoutSeconds: 12); Issue.record("partial upload completed") }
                    catch let error as Coordinator.Interrupted { #expect(!error.mayHaveSubmittedUpgrade) }
                    let generation = try await f.vault.generation(in: f.namespace)
                    try await f.vault.revoke(f.lease.keyID, in: f.namespace, expectedGeneration: generation)
                    do { _ = try await f.vault.lease(in: f.namespace); Issue.record("revoked publication returned a lease") }
                    catch let error as Vault.Failure { #expect(error == .namespaceUnavailable) }
                    let recovery = try await Coordinator.recoveryOnly(journal: journal, clock: { f.date })
                    let result = try await recovery.recover(pairing: peer.pairing, endpoint: peer.endpoint, timeoutSeconds: 12)
                    guard case .remoteCleanup(let saved, let outcome) = result else { Issue.record("expected exact owned cleanup"); return }
                    #expect(saved.record.phase == .candidateReady && outcome.removalVerified)
                    #expect(saved.record.safePreSubmissionCleanup != nil && !saved.record.renewalVerified)
                    let before = try await Self.rawRecord(journal, root: f.directory.appendingPathComponent("SelfRenewalApp"))
                    let again = try await recovery.recover(pairing: peer.pairing, endpoint: peer.endpoint, timeoutSeconds: 12)
                    guard case .candidateReady = again else { Issue.record("recovery-only attempted another phase"); return }
                    let after = try await Self.rawRecord(journal, root: f.directory.appendingPathComponent("SelfRenewalApp"))
                    #expect(before == after)
                    await Self.rejectSigning(recovery, fixture: f, peer: peer)
                    let retained = try await Self.bytes(journal, saved); #expect(retained == bytes)
                    let observed = peer.observed.snapshot
                    #expect(observed.upgradeRequests == 0 && observed.lookupRequests == 0)
                    #expect(observed.openedFileHandles == 1 && observed.removedPaths.count == 1)
                }
            }
        }
    }

    @Test("actual App observable fallback keeps material failure while explicit actual Keychain pairing recovers Lookup")
    func appBootstrapsRecoveryOnlyAndResolvesActualPairingForExplicitLookup() async throws {
        try await Package.fixture { f in
            try await Self.withJournal(f) { journal, root in
                let original = Coordinator(journal: journal, vault: f.vault, namespace: f.namespace, clock: { f.date })
                let ready = try await Self.prepare(original, f); let bytes = try await Self.bytes(journal, ready)
                try await Peer.withPeer(.disconnectAfterUpgradeThenRecover, bytes: bytes,
                    bundle: ready.record.bundleIdentifier, version: ready.record.bundleVersion, at: f.date) { peer in
                    do { _ = try await original.submit(pairing: peer.pairing, endpoint: peer.endpoint, timeoutSeconds: 12) }
                    catch let error as Coordinator.Interrupted { #expect(error.mayHaveSubmittedUpgrade) }
                    try await journal.close()
                    let owner = await MainActor.run { SelfRenewalAppOwner(root: root, clock: { f.date }) }
                    do {
                        await owner.bootstrap()
                        let initial = await MainActor.run { (owner.status?.access, owner.recoveryAvailable, owner.signingMaterialProblem) }
                        #expect(initial.0 == .recoveryOnly && initial.1 && initial.2 == .signingMaterials)
                        let beforeAction = peer.observed.snapshot
                        #expect(beforeAction.lookupRequests == 0)
                        let ref = try Self.persistentReference(peer.pairing.hostIdentity)
                        let device = Session.DeviceConfiguration(identityPersistentReference: ref,
                            deviceCertificateDER: peer.pairing.deviceCertificateDER, rootCertificateDER: peer.pairing.rootCertificateDER,
                            hostID: peer.pairing.hostID, systemBUID: peer.pairing.systemBUID,
                            numericAddress: peer.endpoint.numericAddress, port: peer.endpoint.port, interfaceIndex: peer.endpoint.interfaceIndex)
                        let configuration = Session.Configuration(schema: 1, namespaceID: ready.record.materialNamespace,
                            codeAnchors: [f.oldAnchor], profileAnchors: [f.oldAnchor], device: device)
                        let input = f.directory.appendingPathComponent("owned-recovery-configuration.json")
                        try JSONEncoder().encode(configuration).write(to: input)
                        await owner.importConfiguration(input)
                        let configured = await MainActor.run { (owner.status?.access, owner.status?.state, owner.problem, owner.signingMaterialProblem) }
                        #expect(configured.0 == .recoveryOnly && configured.1 == .recoveryRequired)
                        #expect(configured.2 == nil && configured.3 == .signingMaterials)
                        #expect(peer.observed.snapshot.lookupRequests == 0)
                        await owner.recoverExplicitly()
                        let done = await MainActor.run { (owner.status?.access, owner.status?.state, owner.problem, owner.signingMaterialProblem) }
                        #expect(done.0 == .recoveryOnly && done.1 == .authenticatedRecoveryObserved)
                        #expect(done.2 == nil && done.3 == .signingMaterials)
                        #expect(peer.observed.snapshot.lookupRequests == 1 && peer.observed.snapshot.upgradeRequests == 1)
                        #expect(peer.observed.snapshot.openedFileHandles == 1 && peer.observed.snapshot.removedPaths.isEmpty)
                        try await owner.close()
                    } catch { do { try await owner.close() } catch { Issue.record(error) }; throw error }
                }
            }
        }
        #if DEBUG
        try await Self.retainsCompletedLookupAfterStatusAcknowledgementLoss()
        #endif
    }

    @Test("wrong peer/cancel and ready records cannot manufacture a recovery signing capability")
    func rejectsWrongPinsAndCancellationWithoutCreatingSubmissionAuthority() async throws {
        try await Package.fixture { f in
            try await Self.withJournal(f) { journal, root in
                let original = Coordinator(journal: journal, vault: f.vault, namespace: f.namespace, clock: { f.date })
                let ready = try await Self.prepare(original, f); let bytes = try await Self.bytes(journal, ready)
                do { _ = try await Coordinator.recoveryOnly(journal: journal); Issue.record("ready state granted remote recovery") }
                catch let error as Coordinator.Failure { #expect(error == .invalidRecoveryContext) }
                try await Peer.withPeer(.partialUploadThenRecover, bytes: bytes,
                    bundle: ready.record.bundleIdentifier, version: ready.record.bundleVersion, at: f.date) { peer in
                    do { _ = try await original.submit(pairing: peer.pairing, endpoint: peer.endpoint, timeoutSeconds: 12) }
                    catch let error as Coordinator.Interrupted { #expect(!error.mayHaveSubmittedUpgrade) }
                    let recovery = try await Coordinator.recoveryOnly(journal: journal, clock: { f.date })
                    let raw = try await Self.rawRecord(journal, root: root)
                    let wrong = try SelfRenewalAuthenticatedDeviceTransport.PairingIdentity(hostIdentity: peer.pairing.hostIdentity,
                        deviceCertificateDER: peer.wrongDeviceCertificateDER, rootCertificateDER: peer.pairing.rootCertificateDER,
                        hostID: peer.pairing.hostID, systemBUID: peer.pairing.systemBUID)
                    do { _ = try await recovery.recover(pairing: wrong, endpoint: peer.endpoint); Issue.record("wrong pinned peer recovered") }
                    catch let error as Coordinator.Failure { #expect(error == .wrongPeer) }
                    let cancelled = Task.detached {
                        withUnsafeCurrentTask { $0?.cancel() }
                        do { _ = try await recovery.recover(pairing: peer.pairing, endpoint: peer.endpoint); Issue.record("cancelled recovery admitted") }
                        catch is CancellationError { }
                    }
                    try await cancelled.value
                    let unchanged = try await Self.rawRecord(journal, root: root); #expect(unchanged == raw)
                    #expect(peer.observed.snapshot.removedPaths.isEmpty && peer.observed.snapshot.upgradeRequests == 0)
                    _ = try await recovery.recover(pairing: peer.pairing, endpoint: peer.endpoint, timeoutSeconds: 12)
                    #expect(peer.observed.snapshot.removedPaths.count == 1 && peer.observed.snapshot.openedFileHandles == 1)
                }
            }
        }
    }

    @Test("same Keychain query core preserves missing/malformed/limit/migration errors and legacy return behavior")
    func checkedKeychainReadsKeepMissingMalformedAndBoundsDistinct() async throws {
        let worker = Task.detached(priority: .utility) {
            let service = "owned-renewal-checked-" + UUID().uuidString
            let account = UUID().uuidString
            defer { if !KeychainHelper.delete(account: account, service: service) { Issue.record("owned Keychain cleanup failed") } }
            let absent = try KeychainHelper.loadChecked(account: account, service: service, maximumBytes: 4096)
            #expect(absent == nil)
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: account]
            var add = query; add[kSecValueData as String] = Data([0xff, 0xfe])
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw CocoaError(.coderInvalidValue) }
            do { _ = try KeychainHelper.loadChecked(account: account, service: service, maximumBytes: 4096); Issue.record("invalid UTF8 became missing") }
            catch let error as KeychainHelper.ReadFailure { #expect(error == .invalidUTF8) }
            #expect(KeychainHelper.load(account: account, service: service) == nil)
            guard KeychainHelper.save(account: account, data: "owned value", service: service) else { throw CocoaError(.coderInvalidValue) }
            do { _ = try KeychainHelper.loadChecked(account: account, service: service, maximumBytes: 2); Issue.record("checked byte budget ignored") }
            catch let error as KeychainHelper.ReadFailure { #expect(error == .valueLimit) }
            let badProtection = "owned-invalid-accessibility" as CFString
            do { _ = try KeychainHelper.loadChecked(account: account, service: service, accessibility: badProtection, maximumBytes: 4096); Issue.record("failed migration acknowledged") }
            catch let error as KeychainHelper.ReadFailure {
                guard case .accessibilityMigration(let status) = error else { Issue.record("migration failure lost its type"); return }
                #expect(status != errSecSuccess)
            }
            let legacy = KeychainHelper.load(account: account, service: service, accessibility: badProtection)
            #expect(legacy == "owned value")
            let actual = try KeychainHelper.loadChecked(account: account, service: service, maximumBytes: 4096)
            #expect(actual == "owned value")
        }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    @Test("the real vault manifest adapter preserves invalid UTF8 and never selects a storage-error fallback")
    func vaultPreservesActualMalformedManifestAndStorageFailureTypes() async throws {
        try await Package.fixture { f in
            let storage = SelfRenewalSigningKeychainManifestStorage()
            let account = "owned-v1-" + f.namespace.id.uuidString.lowercased()
            let loaded = try storage.load(account: account); let original = try #require(loaded)
            defer { do { try storage.save(account: account, value: original) } catch { Issue.record(error) } }
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.yuedu.selfRenewal.publicSigningManifest.v1",
                kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
            guard SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data([0xff])] as CFDictionary) == errSecSuccess else { throw CocoaError(.coderInvalidValue) }
            let baseline = try await SelfRenewalIPAUnpacker.verify(ipa: f.input,
                codeAnchors: [f.oldAnchor], profileAnchors: [f.oldAnchor], at: f.date)
            let fresh = Vault(codeAnchors: f.issuer.certificateChainDER, profileAnchors: f.issuer.certificateChainDER, clock: { f.date })
            do { _ = try await fresh.resume(namespaceID: f.namespace.id, identity: baseline.application); Issue.record("bad UTF8 manifest became a namespace") }
            catch let error as KeychainHelper.ReadFailure {
                #expect(error == .invalidUTF8)
                #expect(!Session.isSigningMaterialUnavailable(error))
            }
            // These assertions classify explicit error values; they do not
            // pretend an OS errSecIO or file race was actually injected.
            #expect(!Session.isSigningMaterialUnavailable(KeychainHelper.ReadFailure.lookup(errSecIO)))
            #expect(!Session.isSigningMaterialUnavailable(KeychainHelper.ReadFailure.accessibilityMigration(errSecParam)))
            #expect(!Session.isSigningMaterialUnavailable(Journal.Failure.storageIO))
            #expect(!Session.isSigningMaterialUnavailable(CancellationError()))
            #expect(!Session.isSigningMaterialUnavailable(SelfRenewalMaterialInventory.Failure.fileChangedDuringRead))
            #expect(Session.isSigningMaterialUnavailable(SelfRenewalProvisioningProfileVerifier.Failure.profileExpired))
        }
    }

    #if DEBUG
    nonisolated private static func retainsCompletedLookupAfterStatusAcknowledgementLoss() async throws {
        try await Package.fixture { f in
            try await Self.withJournal(f) { journal, root in
                let original = Coordinator(journal: journal, vault: f.vault, namespace: f.namespace, clock: { f.date })
                let ready = try await Self.prepare(original, f); let bytes = try await Self.bytes(journal, ready)
                try await Peer.withPeer(.disconnectAfterUpgradeThenRecover, bytes: bytes,
                    bundle: ready.record.bundleIdentifier, version: ready.record.bundleVersion, at: f.date) { peer in
                    do { _ = try await original.submit(pairing: peer.pairing, endpoint: peer.endpoint, timeoutSeconds: 12) }
                    catch let error as Coordinator.Interrupted { #expect(error.mayHaveSubmittedUpgrade) }
                    try await journal.close()
                    let session = Session(root: root, publicationFault: .loseNextAuthenticatedRecoveryDirectorySyncAcknowledgement,
                        clock: { f.date })
                    let handoff = await MainActor.run { SelfRenewalUserDataHandoff() }
                    do {
                        _ = try await session.bootstrap(handoff: handoff)
                        let device = Session.DeviceConfiguration(identityPersistentReference: try Self.persistentReference(peer.pairing.hostIdentity),
                            deviceCertificateDER: peer.pairing.deviceCertificateDER, rootCertificateDER: peer.pairing.rootCertificateDER,
                            hostID: peer.pairing.hostID, systemBUID: peer.pairing.systemBUID,
                            numericAddress: peer.endpoint.numericAddress, port: peer.endpoint.port, interfaceIndex: peer.endpoint.interfaceIndex)
                        let configuration = Session.Configuration(schema: 1, namespaceID: ready.record.materialNamespace,
                            codeAnchors: [f.oldAnchor], profileAnchors: [f.oldAnchor], device: device)
                        let input = f.directory.appendingPathComponent("owned-recovery-ack-configuration.json")
                        try JSONEncoder().encode(configuration).write(to: input)
                        _ = try await session.configure(from: input, handoff: handoff)
                        do {
                            _ = try await session.recoverExplicitly(handoff: handoff)
                            Issue.record("lost post-Lookup status acknowledgement reported success")
                        } catch let error as Session.RecoveryFailed {
                            #expect(error.signingMaterials != nil && error.recoveryError == nil)
                            let observationError = error.observationError as? Session.Failure
                            #expect(observationError == .commitDurabilityUnknown)
                            if case .authenticatedLookup(let saved, let observation)? = error.completedRecovery {
                                #expect(saved.record.phase == .lookupObserved && !saved.record.renewalVerified)
                                #expect(observation.presence == .reported(bundleIdentifier: peer.bundle, bundleVersion: peer.version))
                            } else {
                                Issue.record("completed authenticated Lookup disappeared after local status failure")
                            }
                        }
                        let available = await session.recoveryIsAvailable(); #expect(!available)
                        let materialError = await session.signingMaterialFailure(); #expect(materialError != nil)
                        // Fault acknowledgement is withheld only after the actual
                        // atomic rename and directory fsync. The owned bytes must
                        // therefore record the real Lookup despite the thrown ACK.
                        let committed = try Data(contentsOf: root.appendingPathComponent("configuration.json"))
                        let document = try #require(try JSONSerialization.jsonObject(with: committed) as? [String: Any])
                        let status = try #require(document["status"] as? [String: Any])
                        #expect(status["state"] as? String == Session.State.authenticatedRecoveryObserved.rawValue)
                        #expect(status["access"] as? String == Session.Access.recoveryOnly.rawValue)
                        #expect(status["problem"] as? String == Session.Problem.signingMaterials.rawValue)
                        let observed = peer.observed.snapshot
                        #expect(observed.lookupRequests == 1 && observed.upgradeRequests == 1 && observed.removedPaths.isEmpty)
                        let reloaded = try await session.bootstrap(handoff: handoff)
                        #expect(reloaded.access == .recoveryOnly && reloaded.phase == .lookupObserved)
                        #expect(reloaded.problem == .signingMaterials && !reloaded.automaticRenewalVerified)
                        #expect(peer.observed.snapshot.lookupRequests == 1)
                        try await session.close()
                    } catch { do { try await session.close() } catch { Issue.record(error) }; throw error }
                }
            }
        }
    }
    #endif

    nonisolated private static func withJournal(_ f: Package.Fixture,
        _ action: @escaping @Sendable (Journal, URL) async throws -> Void) async throws {
        let root = f.directory.appendingPathComponent("SelfRenewalApp", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let journal = try await Journal.open(at: root.appendingPathComponent("SelfRenewalTransactions"))
        do { try await action(journal, root); try await journal.close() }
        catch { do { try await journal.close() } catch { Issue.record(error) }; throw error }
    }
    nonisolated private static func prepare(_ coordinator: Coordinator, _ f: Package.Fixture) async throws -> Journal.Snapshot {
        try await coordinator.prepare(ipa: f.input, lease: f.lease,
            originalCodeAnchors: [f.oldAnchor], originalProfileAnchors: [f.oldAnchor])
    }
    nonisolated private static func bytes(_ journal: Journal, _ snapshot: Journal.Snapshot) async throws -> Data {
        let path = try await journal.candidateURL(snapshot)
        return try Data(contentsOf: path)
    }
    nonisolated private static func rawRecord(_ journal: Journal, root: URL) async throws -> Data {
        _ = try await journal.load()
        return try Data(contentsOf: root.appendingPathComponent("SelfRenewalTransactions/transaction.json"))
    }
    nonisolated private static func rejectSigning(_ coordinator: Coordinator, fixture f: Package.Fixture, peer: Peer.Context) async {
        do { _ = try await coordinator.prepare(ipa: f.directory.appendingPathComponent("does-not-exist.ipa"),
            lease: f.lease, originalCodeAnchors: [], originalProfileAnchors: []); Issue.record("recovery capability prepared a new IPA") }
        catch let error as Coordinator.Failure { #expect(error == .signingMaterialsUnavailable) }
        catch { Issue.record(error) }
        do { _ = try await coordinator.submit(pairing: peer.pairing, endpoint: peer.endpoint); Issue.record("recovery capability submitted Upgrade") }
        catch let error as Coordinator.Failure { #expect(error == .signingMaterialsUnavailable) }
        catch { Issue.record(error) }
        do { _ = try await coordinator.observeCurrentProcess(); Issue.record("recovery capability manufactured a signing observation") }
        catch let error as Coordinator.Failure { #expect(error == .signingMaterialsUnavailable) }
        catch { Issue.record(error) }
    }
    nonisolated private static func persistentReference(_ identity: SecIdentity) throws -> Data {
        let query: [String: Any] = [kSecClass as String: kSecClassIdentity,
            kSecValueRef as String: identity, kSecReturnPersistentRef as String: true]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let value = value as? Data else { throw CocoaError(.coderInvalidValue) }
        return value
    }
}
