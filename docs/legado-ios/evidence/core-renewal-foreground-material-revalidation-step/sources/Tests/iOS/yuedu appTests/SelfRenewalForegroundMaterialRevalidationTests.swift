import Darwin
import Foundation
import Security
import Testing
@testable import yuedu_app

@Suite("Bounded foreground signing-material revalidation", .serialized)
struct SelfRenewalForegroundMaterialRevalidationTests {
    typealias Package = SelfRenewalControlledPackageSignerTests
    typealias Coordinator = SelfRenewalControlledRenewalCoordinator
    typealias Journal = SelfRenewalTransactionJournal
    typealias Vault = SelfRenewalSigningMaterialVault
    typealias Peer = SelfRenewalAuthenticatedInstallationFixture
    typealias Session = SelfRenewalAppSession
    typealias PKI = SelfRenewalSigningOwnedPKIFixture

    @Test("nil and unsubmitted records must validate the real expiring lease before returning")
    func revalidatesActualLeaseBeforeNilAndUnsubmittedReturns() async throws {
        for prepared in [false, true] {
            try await Package.fixture { f in
                let clock = Clock(f.date)
                let baseline = try await SelfRenewalIPAUnpacker.verify(ipa: f.input,
                    codeAnchors: [f.oldAnchor], profileAnchors: [f.oldAnchor], at: f.date)
                let vault = Vault(codeAnchors: f.issuer.certificateChainDER,
                    profileAnchors: f.issuer.certificateChainDER, clock: { clock.now })
                let namespace = try await vault.resume(namespaceID: f.namespace.id, identity: baseline.application)
                let lease = try await vault.lease(in: namespace)
                try await Self.withJournal(f) { journal, root in
                    let coordinator = Coordinator(journal: journal, vault: vault, namespace: namespace, clock: { clock.now })
                    if prepared { _ = try await Self.prepare(coordinator, f, lease: lease) }
                    let healthy = try await coordinator.observeCurrentProcess()
                    #expect(healthy?.record.installedMaterial == nil)
                    #expect(healthy?.record.phase == (prepared ? .candidateReady : nil))
                    let before = try Self.recordBytes(root)
                    let expiry = try #require(lease.profiles.map(\.summary.expiresAt).min())
                    clock.set(expiry.addingTimeInterval(1))
                    do { _ = try await coordinator.observeCurrentProcess(); Issue.record("expired lease passed a foreground early return") }
                    catch let error as SelfRenewalProvisioningProfileVerifier.Failure { #expect(error == .profileExpired) }
                    let after = try Self.recordBytes(root); #expect(before == after)
                }
            }
        }
    }

    @Test("uploadIntent rechecks actual revocation; only an explicit existing cleanup performs another RPC")
    func revokedUploadRetainsOnlyExistingAuthenticatedRecovery() async throws {
        try await Package.fixture { f in
            try await Self.withJournal(f) { journal, root in
                let coordinator = Coordinator(journal: journal, vault: f.vault, namespace: f.namespace, clock: { f.date })
                let ready = try await Self.prepare(coordinator, f, lease: f.lease)
                let candidate = try await journal.candidateURL(ready); let bytes = try Data(contentsOf: candidate)
                try await Peer.withPeer(.partialUploadThenRecover, bytes: bytes,
                    bundle: ready.record.bundleIdentifier, version: ready.record.bundleVersion, at: f.date) { peer in
                    do { _ = try await coordinator.submit(pairing: peer.pairing, endpoint: peer.endpoint, timeoutSeconds: 12) }
                    catch let error as Coordinator.Interrupted { #expect(!error.mayHaveSubmittedUpgrade) }
                    let before = try Self.recordBytes(root)
                    let generation = try await f.vault.generation(in: f.namespace)
                    try await f.vault.revoke(f.lease.keyID, in: f.namespace, expectedGeneration: generation)
                    do { _ = try await coordinator.observeCurrentProcess(); Issue.record("uploadIntent skipped actual revoked publication") }
                    catch let error as Vault.Failure { #expect(error == .namespaceUnavailable) }
                    let after = try Self.recordBytes(root); #expect(before == after)
                    #expect(peer.observed.snapshot.removedPaths.isEmpty && peer.observed.snapshot.upgradeRequests == 0)
                    let recovery = try await Coordinator.recoveryOnly(journal: journal, clock: { f.date })
                    let result = try await recovery.recover(pairing: peer.pairing, endpoint: peer.endpoint, timeoutSeconds: 12)
                    guard case .remoteCleanup(let saved, let outcome) = result else { Issue.record("existing explicit cleanup missing"); return }
                    #expect(saved.record.phase == .candidateReady && outcome.removalVerified && !saved.record.renewalVerified)
                    let retained = try Data(contentsOf: candidate); #expect(retained == bytes)
                    #expect(peer.observed.snapshot.openedFileHandles == 1 && peer.observed.snapshot.removedPaths.count == 1)
                }
            }
        }
    }

    @Test("real App foreground detects signed profile expiry before its still-valid replacement lease without rereading the application")
    func appForegroundExpiresKnownProfileWithoutRereadingApplication() async throws {
        #if DEBUG
        for denyStatusWrite in [false, true] {
            try await Self.withAppFixture { f in
                let owner = await MainActor.run { SelfRenewalAppOwner(root: f.root, currentApplicationRoot: f.application, clock: { f.clock.now }) }
                do {
                    await owner.bootstrap(); await owner.importConfiguration(f.configurationFile)
                    let initial = await MainActor.run { owner.status }; #expect(initial?.access == .signing && initial?.state == .ready)
                    let configuration = f.root.appendingPathComponent("configuration.json")
                    let before = try Data(contentsOf: configuration)
                    // The DEBUG input is genuinely verified once. Removing its
                    // old path proves a healthy foreground does not reread it;
                    // no owned fixture is asserted to be the current process.
                    try FileManager.default.moveItem(at: f.application, to: f.application.appendingPathExtension("not-read-again"))
                    await owner.becameActive()
                    let unchanged = try Data(contentsOf: configuration); #expect(unchanged == before)
                    f.clock.set(f.profileExpiry.addingTimeInterval(1))
                    let liveLease = try await f.vault.lease(in: f.namespace)
                    #expect(liveLease.profiles.allSatisfy { $0.summary.expiresAt > f.clock.now })
                    if denyStatusWrite { guard chmod(f.root.path, 0o500) == 0 else { throw POSIXError(.EIO) } }
                    defer { if denyStatusWrite && chmod(f.root.path, 0o700) != 0 { Issue.record("owned status directory permissions not restored") } }
                    await owner.becameActive()
                    let failed = await MainActor.run { (owner.status, owner.problem, owner.signingMaterialProblem, owner.recoveryAvailable) }
                    #expect(failed.0?.access == nil && failed.0?.state == .unavailable)
                    #expect(failed.1 == (denyStatusWrite ? .localStorage : .signingMaterials))
                    #expect(failed.2 == .signingMaterials && !failed.3)
                    if denyStatusWrite { let raw = try Data(contentsOf: configuration); #expect(raw == before) }
                    try await owner.close()
                } catch { do { try await owner.close() } catch { Issue.record(error) }; throw error }
            }
        }
        #endif
    }

    @Test("the actual App owner downgrades revoked upload material and preserves manual owned cleanup without automatic submission")
    func appForegroundRevocationKeepsUploadCleanupExplicit() async throws {
        #if DEBUG
        try await Package.fixture { f in
            let application = try await Self.copyOwnedApplication(f)
            try await Self.withJournal(f) { journal, root in
                let original = Coordinator(journal: journal, vault: f.vault, namespace: f.namespace, clock: { f.date })
                let ready = try await Self.prepare(original, f, lease: f.lease)
                let candidate = try await journal.candidateURL(ready); let bytes = try Data(contentsOf: candidate)
                try await Peer.withPeer(.partialUploadThenRecover, bytes: bytes,
                    bundle: ready.record.bundleIdentifier, version: ready.record.bundleVersion, at: f.date) { peer in
                    do { _ = try await original.submit(pairing: peer.pairing, endpoint: peer.endpoint, timeoutSeconds: 12) }
                    catch let error as Coordinator.Interrupted { #expect(!error.mayHaveSubmittedUpgrade) }
                    try await journal.close()
                    let owner = await MainActor.run { SelfRenewalAppOwner(root: root, currentApplicationRoot: application, clock: { f.date }) }
                    do {
                        await owner.bootstrap()
                        let device = try Self.device(peer)
                        let anchors = [f.oldAnchor] + f.issuer.certificateChainDER
                        let configuration = Session.Configuration(schema: 1, namespaceID: f.namespace.id,
                            codeAnchors: anchors, profileAnchors: anchors, device: device)
                        let input = f.directory.appendingPathComponent("actual-foreground-configuration.json")
                        try JSONEncoder().encode(configuration).write(to: input)
                        await owner.importConfiguration(input)
                        let connected = await MainActor.run { owner.status }; #expect(connected?.access == .signing && connected?.phase == .uploadIntent)
                        let generation = try await f.vault.generation(in: f.namespace)
                        try await f.vault.revoke(f.lease.keyID, in: f.namespace, expectedGeneration: generation)
                        await owner.becameActive()
                        let downgraded = await MainActor.run { (owner.status, owner.signingMaterialProblem, owner.recoveryAvailable) }
                        #expect(downgraded.0?.access == .recoveryOnly && downgraded.0?.state == .recoveryRequired)
                        #expect(downgraded.1 == .signingMaterials && downgraded.2)
                        #expect(peer.observed.snapshot.removedPaths.isEmpty && peer.observed.snapshot.upgradeRequests == 0)
                        await owner.recoverExplicitly()
                        let cleaned = await MainActor.run { owner.status }
                        #expect(cleaned?.access == .recoveryOnly && cleaned?.state == .candidateReady)
                        await owner.becameActive()
                        let retained = try Data(contentsOf: candidate); #expect(retained == bytes)
                        #expect(peer.observed.snapshot.openedFileHandles == 1 && peer.observed.snapshot.removedPaths.count == 1)
                        #expect(peer.observed.snapshot.upgradeRequests == 0 && peer.observed.snapshot.lookupRequests == 0)
                        try await owner.close()
                    } catch { do { try await owner.close() } catch { Issue.record(error) }; throw error }
                }
            }
        }
        #endif
    }

    @Test("real Keychain corruption remains typed storage failure, while pre-admission cancellation leaves the healthy connection unchanged")
    func preservesTypedKeychainFailureAndForegroundCancellation() async throws {
        #if DEBUG
        try await Self.withAppFixture { f in
            let session = Session(root: f.root, currentApplicationRoot: f.application, clock: { f.clock.now })
            let handoff = await MainActor.run { SelfRenewalUserDataHandoff() }
            do {
                _ = try await session.bootstrap(handoff: handoff)
                let connected = try await session.configure(from: f.configurationFile, handoff: handoff)
                #expect(connected.access == .signing)
                let file = f.root.appendingPathComponent("configuration.json"); let before = try Data(contentsOf: file)
                let cancelled = Task.detached {
                    withUnsafeCurrentTask { $0?.cancel() }
                    do { _ = try await session.bootstrap(handoff: handoff); Issue.record("cancelled foreground completed") }
                    catch is CancellationError { }
                }
                try await cancelled.value
                let afterCancellation = try Data(contentsOf: file); #expect(afterCancellation == before)
                let healthy = try await session.bootstrap(handoff: handoff); #expect(healthy.access == .signing)
                let storage = SelfRenewalSigningKeychainManifestStorage()
                let account = "owned-v1-" + f.namespace.id.uuidString.lowercased()
                let loaded = try storage.load(account: account); let original = try #require(loaded)
                defer { do { try storage.save(account: account, value: original) } catch { Issue.record(error) } }
                let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: "com.yuedu.selfRenewal.publicSigningManifest.v1",
                    kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
                guard SecItemUpdate(query as CFDictionary,[kSecValueData as String:Data([0xff])] as CFDictionary) == errSecSuccess else { throw POSIXError(.EIO) }
                do { _ = try await session.bootstrap(handoff: handoff); Issue.record("malformed actual Keychain material retained signing") }
                catch let error as Session.Unavailable {
                    #expect(error.problem == .storage)
                    let observations = try #require(error.underlying as? Session.ObservationFailures)
                    #expect(observations.installedMaterial as? KeychainHelper.ReadFailure == .invalidUTF8)
                }
                let unavailable = await session.status(); #expect(unavailable?.access == nil && unavailable?.state == .unavailable)
                let recovery = await session.recoveryIsAvailable(); #expect(!recovery)
                let material = await session.signingMaterialFailure()
                #expect(material?.underlying as? KeychainHelper.ReadFailure == .invalidUTF8)
                try await session.close()
            } catch { do { try await session.close() } catch { Issue.record(error) }; throw error }
        }
        #endif
    }

    @Test("an owned application test root cannot generate a current-process observation for a completed transport")
    func refusesOwnedApplicationAsCurrentProcessEvidence() async throws {
        #if DEBUG
        try await Package.fixture { f in
            let application = try await Self.copyOwnedApplication(f)
            try await Self.withJournal(f) { journal, root in
                let original = Coordinator(journal: journal, vault: f.vault, namespace: f.namespace, clock: { f.date })
                let ready = try await Self.prepare(original, f, lease: f.lease)
                let candidate = try await journal.candidateURL(ready); let bytes = try Data(contentsOf: candidate)
                try await Peer.withPeer(bytes: bytes, bundle: ready.record.bundleIdentifier, version: ready.record.bundleVersion, at: f.date) { peer in
                    let completion = try await original.submit(pairing: peer.pairing, endpoint: peer.endpoint, timeoutSeconds: 12)
                    #expect(completion.snapshot.record.phase == .receiptObserved)
                    let before = try Self.recordBytes(root); try await journal.close()
                    let session = Session(root: root, currentApplicationRoot: application, clock: { f.date })
                    let handoff = await MainActor.run { SelfRenewalUserDataHandoff() }
                    do {
                        _ = try await session.bootstrap(handoff: handoff)
                        let anchors = [f.oldAnchor] + f.issuer.certificateChainDER
                        let configuration = Session.Configuration(schema: 1, namespaceID: f.namespace.id,
                            codeAnchors: anchors, profileAnchors: anchors, device: nil)
                        let input = f.directory.appendingPathComponent("owned-not-process.json")
                        try JSONEncoder().encode(configuration).write(to: input)
                        do { _ = try await session.configure(from: input, handoff: handoff); Issue.record("owned fixture became current-process evidence") }
                        catch let error as Session.Unavailable {
                            let observations = try #require(error.underlying as? Session.ObservationFailures)
                            #expect(observations.installedMaterial as? Session.Failure == .ownedApplicationIsNotCurrentProcess)
                        }
                        let after = try Self.recordBytes(root); #expect(before == after)
                        let denied = await session.status(); #expect(denied?.access == nil)
                        #expect(peer.observed.snapshot.lookupRequests == 0 && peer.observed.snapshot.upgradeRequests == 1)
                        try await session.close()
                    } catch { do { try await session.close() } catch { Issue.record(error) }; throw error }
                }
            }
        }
        #endif
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date
        init(_ date: Date) { self.date = date }
        var now: Date { lock.lock(); defer { lock.unlock() }; return date }
        func set(_ date: Date) { lock.lock(); defer { lock.unlock() }; self.date = date }
    }
    private struct AppFixture: @unchecked Sendable {
        let root: URL; let application: URL; let configurationFile: URL
        let vault: Vault; let namespace: Vault.Namespace; let clock: Clock; let profileExpiry: Date
    }
    nonisolated private static func withAppFixture(_ action: @escaping @Sendable (AppFixture) async throws -> Void) async throws {
        try await Package.fixture { original in
            let application = try await copyOwnedApplication(original)
            let proof = try await SelfRenewalApplicationMaterialVerifier.read(unpackedApplication: application,
                codeAnchors: [original.oldAnchor], profileAnchors: [original.oldAnchor], at: original.date)
            let expiry = try #require(proof.profiles.profiles.map(\.summary.expiresAt).min())
            let date = expiry.addingTimeInterval(-1800); let clock = Clock(date)
            let verified = try await SelfRenewalApplicationMaterialVerifier.read(unpackedApplication: application,
                codeAnchors: [original.oldAnchor], profileAnchors: [original.oldAnchor], at: date)
            let issuer = try PKI.issuer(at: date)
            let anchors = [original.oldAnchor] + issuer.certificateChainDER
            let vault = Vault(codeAnchors: anchors, profileAnchors: anchors, clock: { clock.now })
            let namespace = try await vault.create(identity: verified)
            do {
                let generation = try await vault.generation(in: namespace)
                let key = try await vault.generateKey(in: namespace, expectedGeneration: generation)
                let certificate = try PKI.certificate(for: key.privateKey, signedBy: issuer, at: date)
                let profiles = try verified.profiles.profiles.map { profile -> Vault.ProfileInput in
                    let bundle = try #require(verified.bundles.first { $0.profileRelativePath == profile.file.relativePath })
                    return Vault.ProfileInput(componentRelativePath: bundle.componentRelativePath,
                        bytes: try PKI.profile(from: profile, developerCertificate: certificate, issuer: issuer, at: date,
                            transform: { $0["ExpirationDate"] = .date(expiry.addingTimeInterval(3600)) }))
                }
                _ = try await vault.publish(in: namespace, keyID: key.id, expectedGeneration: key.generation,
                    certificateChainDER: [certificate] + issuer.certificateChainDER, profiles: profiles)
                let root = original.directory.appendingPathComponent("SelfRenewalApp")
                let configuration = Session.Configuration(schema: 1, namespaceID: namespace.id,
                    codeAnchors: anchors, profileAnchors: anchors, device: nil)
                let input = original.directory.appendingPathComponent("foreground-real-materials.json")
                try JSONEncoder().encode(configuration).write(to: input)
                try await action(AppFixture(root: root, application: application, configurationFile: input,
                    vault: vault, namespace: namespace, clock: clock, profileExpiry: expiry))
                let finalGeneration = try await vault.generation(in: namespace)
                try await vault.destroy(namespace, expectedGeneration: finalGeneration)
            } catch {
                do { let generation = try await vault.generation(in: namespace); try await vault.destroy(namespace, expectedGeneration: generation) }
                catch { Issue.record(error) }
                throw error
            }
        }
    }
    nonisolated private static func copyOwnedApplication(_ f: Package.Fixture) async throws -> URL {
        // The original fixture has already passed the production Unpacker.
        // Reuse its real validated classic-ZIP plan solely to copy its stored
        // public test bytes; the new directory is independently fully verified.
        let plan = try SelfRenewalIPAArchiveValidator.inspect(SelfRenewalIPAArchiveFixture.Bytes(data: f.originalBytes))
        let container = f.directory.appendingPathComponent("foreground-owned-" + UUID().uuidString)
        for entry in plan.entries {
            guard entry.compressionMethod == 0 && entry.compressedBytes == entry.expandedBytes else { throw CocoaError(.coderReadCorrupt) }
            let path = container.appendingPathComponent(entry.path)
            if entry.directory { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true); continue }
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try f.originalBytes.subdata(in: entry.dataOffset..<entry.dataOffset + entry.expandedBytes).write(to: path, options: .withoutOverwriting)
        }
        let application = container.appendingPathComponent(plan.applicationPath)
        _ = try await SelfRenewalApplicationMaterialVerifier.read(unpackedApplication: application,
            codeAnchors: [f.oldAnchor], profileAnchors: [f.oldAnchor], at: f.date)
        return application
    }
    nonisolated private static func withJournal(_ f: Package.Fixture,
        _ action: @escaping @Sendable (Journal, URL) async throws -> Void) async throws {
        let root = f.directory.appendingPathComponent("SelfRenewalApp")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let journal = try await Journal.open(at: root.appendingPathComponent("SelfRenewalTransactions"))
        do { try await action(journal, root); try await journal.close() }
        catch { do { try await journal.close() } catch { Issue.record(error) }; throw error }
    }
    nonisolated private static func prepare(_ coordinator: Coordinator, _ f: Package.Fixture, lease: Vault.Lease) async throws -> Journal.Snapshot {
        try await coordinator.prepare(ipa: f.input, lease: lease, originalCodeAnchors: [f.oldAnchor], originalProfileAnchors: [f.oldAnchor])
    }
    nonisolated private static func recordBytes(_ root: URL) throws -> Data? {
        let file = root.appendingPathComponent("SelfRenewalTransactions/transaction.json")
        return FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
    }
    nonisolated private static func device(_ peer: Peer.Context) throws -> Session.DeviceConfiguration {
        let query: [String: Any] = [kSecClass as String:kSecClassIdentity,
            kSecValueRef as String:peer.pairing.hostIdentity,kSecReturnPersistentRef as String:true]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&value) == errSecSuccess, let reference = value as? Data else { throw POSIXError(.EIO) }
        return Session.DeviceConfiguration(identityPersistentReference: reference,
            deviceCertificateDER: peer.pairing.deviceCertificateDER, rootCertificateDER: peer.pairing.rootCertificateDER,
            hostID: peer.pairing.hostID, systemBUID: peer.pairing.systemBUID,
            numericAddress: peer.endpoint.numericAddress, port: peer.endpoint.port, interfaceIndex: peer.endpoint.interfaceIndex)
    }
}
