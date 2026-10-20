import CryptoKit
import Foundation

/// Explicit controlled execution only. Uses the real package signer, vault,
/// authenticated installer and a single durable journal. No background trigger,
/// Apple account, companion, VPN or installation authority is manufactured here.
actor SelfRenewalControlledRenewalCoordinator {
    typealias Journal = SelfRenewalTransactionJournal
    typealias Vault = SelfRenewalSigningMaterialVault
    typealias Installer = SelfRenewalAuthenticatedInstallationClient
    typealias Transport = SelfRenewalAuthenticatedDeviceTransport
    typealias Unpacker = SelfRenewalIPAUnpacker
    typealias App = SelfRenewalApplicationMaterialVerifier
    enum Failure: Error, Sendable, Equatable {
        case busy, missingTransaction, inputChanged, leaseChanged, identityChanged, wrongPeer
        case candidateNotReady, invalidHook, noSubmissionIntent
    }
    struct Interrupted: Error, @unchecked Sendable {
        let underlying: Error
        let persistedIntent: Journal.Snapshot?
        let persistedUpload: Journal.Snapshot?
        let journalUpdateError: Error?
        var mayHaveSubmittedUpgrade: Bool { persistedIntent != nil }
    }
    enum Recovery: Sendable {
        case noTransaction
        case preparationInterrupted(Journal.Snapshot)
        case candidateReady(Journal.Snapshot)
        case remoteCleanup(Journal.Snapshot, SelfRenewalInstallationRecovery.Outcome)
        case authenticatedLookup(Journal.Snapshot, Installer.LookupObservation)
    }
    struct TransportCompletion: Sendable {
        let snapshot: Journal.Snapshot
        let receipt: Installer.Receipt
        var installedRenewedProfileVerified: Bool { false }
        var coldLaunchAndUserDataPreservationVerified: Bool { false }
        var automaticSelfRenewalImplemented: Bool { false }
    }
    private let journal: Journal
    private let vault: Vault
    private let namespace: Vault.Namespace
    private let clock: @Sendable () -> Date
    private var busy = false
    private var submitted: Journal.Snapshot?
    private var uploading: Journal.Snapshot?
    init(journal: Journal, vault: Vault, namespace: Vault.Namespace,
        clock: @escaping @Sendable () -> Date = { Date() }) {
        self.journal = journal; self.vault = vault; self.namespace = namespace
        self.clock = clock
    }

    func prepare(ipa: URL, lease: Vault.Lease, originalCodeAnchors: [Data],
        originalProfileAnchors: [Data]) async throws -> Journal.Snapshot {
        guard !busy else { throw Failure.busy }
        busy = true; defer { busy = false }
        try Task.checkCancellation()
        guard lease.namespace == namespace else { throw Failure.leaseChanged }
        try await vault.validate(lease)
        let original = try await Unpacker.verify(ipa: ipa, codeAnchors: originalCodeAnchors,
            profileAnchors: originalProfileAnchors, at: lease.verifiedAt)
        try await vault.validate(lease, for: original.application)
        let target = try Self.target(original.application)
        let initial = try await journal.create(namespace: lease.namespace.id, generation: lease.generation,
            originalSHA256: original.archiveSHA256, identitySHA256: Self.identityDigest(original.application),
            bundleIdentifier: target.identifier, bundleVersion: target.build, at: clock())
        let signing = try await journal.beginSigning(initial, at: clock())
        let result = try await SelfRenewalControlledPackageSigner.resign(ipa: ipa, vault: vault, lease: lease,
            originalCodeAnchors: originalCodeAnchors, originalProfileAnchors: originalProfileAnchors)
        guard result.originalArchiveSHA256 == original.archiveSHA256,
              result.originalArchiveBytes == original.archiveBytes else { throw Failure.inputChanged }
        try await vault.validate(lease, for: result.signed)
        guard try Self.identityDigest(result.signed) == initial.record.identitySHA256 else { throw Failure.identityChanged }
        let archive = result.archive
        let input = Journal.ArchiveInput(byteCount: archive.byteCount, sha256: archive.sha256,
            read: { try await archive.read(at: $0, count: $1) })
        let ready = try await journal.storeCandidate(signing, archive: input, at: clock())
        // Re-read the actual persisted ZIP using the same extractor and complete
        // verifier before this coordinator can make it available for submission.
        _ = try await verifyCandidate(ready, lease: lease)
        return ready
    }

    func submit(pairing: Transport.PairingIdentity, endpoint: Transport.Endpoint,
        timeoutSeconds: TimeInterval = 300) async throws -> TransportCompletion {
        guard !busy else { throw Failure.busy }
        busy = true; submitted = nil; uploading = nil
        defer { busy = false; submitted = nil; uploading = nil }
        guard let ready = try await journal.load(), ready.record.phase == .candidateReady,
              let candidate = ready.record.candidate else { throw Failure.candidateNotReady }
        let lease = try await currentLease(ready)
        let proof = try await verifyCandidate(ready, lease: lease)
        let expectedPeer = Data(SHA256.hash(data: pairing.deviceCertificateDER))
        let input = Installer.ArchiveInput(byteCount: candidate.byteCount, sha256: candidate.sha256,
            read: { [self] offset, count in try await readForUpload(transaction: ready.record.id, at: offset, count: count) })
        do {
            let receipt = try await Installer.upgrade(input, pairing: pairing, lockdownEndpoint: endpoint,
                bundleIdentifier: ready.record.bundleIdentifier, bundleVersion: ready.record.bundleVersion,
                at: clock(), timeoutSeconds: timeoutSeconds, beforeUploadCreation: { [self] intent in
                    try await beforeCreation(ready, intent: intent, lease: lease,
                        material: proof.application, expectedPeer: expectedPeer)
                }, beforeUpgradeSubmission: { [self] submission in
                    try await beforeSubmission(submission: submission, lease: lease,
                        material: proof.application, expectedPeer: expectedPeer)
                })
            guard let intent = submitted else { throw Failure.noSubmissionIntent }
            let saved = try await journal.noteTransportReceipt(intent, receipt: receipt, at: clock())
            return TransportCompletion(snapshot: saved, receipt: receipt)
        } catch {
            let intent = submitted
            var journalError: Error?
            if let intent {
                do { _ = try await journal.noteSubmissionInterruption(intent, at: clock()) }
                catch { journalError = error }
            }
            // A cancelled writer may retain upgradeIntent instead of updating
            // it. That durable intent already forces Lookup-only recovery.
            throw Interrupted(underlying: error, persistedIntent: intent, persistedUpload: uploading, journalUpdateError: journalError)
        }
    }

    /// Crash/restart recovery never uploads or resubmits Upgrade. A same-version
    /// Lookup cannot tell whether the renewed profile was actually installed.
    func recover(pairing: Transport.PairingIdentity, endpoint: Transport.Endpoint,
        timeoutSeconds: TimeInterval = 30) async throws -> Recovery {
        guard !busy else { throw Failure.busy }
        busy = true; defer { busy = false }
        guard let snapshot = try await journal.load() else { return .noTransaction }
        switch snapshot.record.phase {
        case .created, .signing, .attentionRequired:
            return .preparationInterrupted(snapshot)
        case .candidateReady:
            return .candidateReady(snapshot)
        case .uploadIntent, .receiptObserved, .upgradeIntent, .installationUnknown, .lookupObserved:
            guard let intent = snapshot.record.submission,
                  Data(SHA256.hash(data: pairing.deviceCertificateDER)) == intent.deviceCertificateSHA256 else { throw Failure.wrongPeer }
            let outcome = try await SelfRenewalInstallationRecovery.cleanup(journal: journal, expected: snapshot,
                pairing: pairing, lockdownEndpoint: endpoint, at: clock(), timeoutSeconds: timeoutSeconds)
            guard let saved = try await journal.load(), saved.record.id == snapshot.record.id else { throw Failure.missingTransaction }
            if let observation = outcome.lookup { return .authenticatedLookup(saved, observation) }
            return .remoteCleanup(saved, outcome)
        }
    }

    func close() async throws {
        guard !busy else { throw Failure.busy }
        try await journal.close()
    }

    private func beforeCreation(_ expected: Journal.Snapshot, intent: Installer.UploadIntent,
        lease: Vault.Lease, material: App.Materials, expectedPeer: Data) async throws {
        guard busy, uploading == nil, submitted == nil, intent.deviceCertificateSHA256 == expectedPeer else { throw Failure.invalidHook }
        try Task.checkCancellation()
        try await vault.validate(lease, for: material)
        uploading = try await journal.noteUploadIntent(expected, intent: intent, at: clock())
    }

    private func readForUpload(transaction: UUID, at offset: Int, count: Int) async throws -> Data {
        guard busy, submitted == nil, let upload = uploading,
              upload.record.id == transaction, upload.record.phase == .uploadIntent else { throw Failure.invalidHook }
        return try await journal.readCandidate(upload, at: offset, count: count)
    }

    private func beforeSubmission(submission: Installer.UpgradeSubmission,
        lease: Vault.Lease, material: App.Materials, expectedPeer: Data) async throws {
        guard busy, submitted == nil, let expected = uploading,
              submission.deviceCertificateSHA256 == expectedPeer else { throw Failure.invalidHook }
        try Task.checkCancellation()
        try await vault.validate(lease, for: material)
        guard try Self.identityDigest(material) == expected.record.identitySHA256 else { throw Failure.identityChanged }
        // This fsync/rename boundary completes before the transport is allowed
        // to write the first byte of its Upgrade request frame.
        submitted = try await journal.noteUpgradeIntent(expected, submission: submission, at: clock())
    }

    private func currentLease(_ snapshot: Journal.Snapshot) async throws -> Vault.Lease {
        // The namespace remains an opaque vault handle. Reopen uses a real
        // sealed material proof at the coordinator construction/resume boundary.
        // A live owner can enumerate its exact namespace by its public UUID.
        guard namespace.id == snapshot.record.materialNamespace else { throw Failure.leaseChanged }
        let lease = try await vault.lease(in: namespace)
        guard lease.generation == snapshot.record.materialGeneration else { throw Failure.leaseChanged }
        return lease
    }

    private func verifyCandidate(_ snapshot: Journal.Snapshot, lease: Vault.Lease) async throws -> Unpacker.Materials {
        guard let candidate = snapshot.record.candidate,
              let codeAnchor = lease.keyMaterial.certificateChainDER.last else { throw Failure.candidateNotReady }
        var anchors: [Data] = []
        for profile in lease.profiles {
            for signer in profile.outerEnvelope.signers + profile.derEnvelope.signers {
                guard let anchor = signer.verifiedCertificateChainDER.last else { throw Failure.identityChanged }
                if !anchors.contains(anchor) { anchors.append(anchor) }
            }
        }
        guard !anchors.isEmpty else { throw Failure.identityChanged }
        let input = try await journal.candidateURL(snapshot)
        let material = try await Unpacker.verify(ipa: input, codeAnchors: [codeAnchor], profileAnchors: anchors, at: clock())
        guard material.archiveSHA256 == candidate.sha256, material.archiveBytes == candidate.byteCount,
              try Self.identityDigest(material.application) == snapshot.record.identitySHA256 else { throw Failure.inputChanged }
        try await vault.validate(lease, for: material.application)
        return material
    }

    private static func target(_ material: App.Materials) throws -> (identifier: String, build: String) {
        guard let main = material.resources.executableMaterials.inventory.components.first(where: { $0.role == .application }),
              let info = main.metadata else { throw Failure.identityChanged }
        return (info.bundleIdentifier, info.build)
    }

    private static func identityDigest(_ material: App.Materials) throws -> Data {
        let components = material.resources.executableMaterials.inventory.components
        let identities: [[String: Any]] = try material.bundles.sorted { $0.componentRelativePath < $1.componentRelativePath }.map { bundle in
            guard let metadata = components.first(where: { $0.relativePath == bundle.componentRelativePath })?.metadata else { throw Failure.identityChanged }
            return ["path": bundle.componentRelativePath, "bundle": bundle.bundleIdentifier,
                "version": metadata.version, "build": metadata.build,
                "slices": bundle.slices.map { slice in
                    ["identifier": slice.codeSigningIdentifier,
                     "codeDirectoryTeam": slice.codeDirectoryTeamIdentifier as Any? ?? NSNull(),
                     "team": slice.teamIdentifier, "prefix": slice.applicationIdentifierPrefix,
                     "applicationIdentifier": slice.applicationIdentifier,
                     "appGroups": slice.appGroups, "keychainAccessGroups": slice.keychainAccessGroups,
                     "unassessedEntitlementKeys": slice.unassessedEntitlementKeys.sorted()] as [String: Any]
                }]
        }
        return Data(SHA256.hash(data: try JSONSerialization.data(withJSONObject: identities, options: [.sortedKeys])))
    }
}
