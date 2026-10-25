import CryptoKit
import Foundation

/// Recovery for a current grant issued by the actual durable journal owner.
/// This consumes the existing TLS/Lockdown/AFC implementation; it never opens,
/// uploads or upgrades a package and never interprets Lookup as a safe-delete
/// predicate for a possibly running installation.
enum SelfRenewalInstallationRecovery {
    typealias Journal = SelfRenewalTransactionJournal
    typealias Installer = SelfRenewalAuthenticatedInstallationClient
    typealias Transport = SelfRenewalAuthenticatedDeviceTransport
    enum Failure: Error, Sendable, Equatable {
        case invalidGrant, invalidOwnedPath, wrongDevice, invalidDate
    }
    enum Removal: String, Sendable, Equatable {
        case removedAcknowledged
        case alreadyAbsentAcknowledged
    }
    enum FileCloseAcknowledgement: Sendable, Equatable {
        /// An AFC file handle belongs to its old service connection. Recovery
        /// never reuses it or falsely reports a FileClose ACK on a fresh channel.
        case noRemoteFileOpenedInRecovery
    }
    struct Outcome: Sendable {
        let grantID: UUID
        let remotePackagePath: String
        let deviceCertificateSHA256: Data
        let removal: Removal?
        var removalVerified: Bool { removal != nil }
        let stopSessionAcknowledged: Bool
        let lookup: Installer.LookupObservation?
        let fileCloseAcknowledgement: FileCloseAcknowledgement
        let afcChannelReleasedLocally: Bool
        let lockdownChannelReleasedLocally: Bool
        var retainedForUnknownSubmission: Bool { lookup != nil && removal == nil }
        var installedRenewedProfileVerified: Bool { false }
        var samePhysicalDeviceVerified: Bool { false }
        var noVPNRouteVerified: Bool { false }
        var selfRenewalVerified: Bool { false }
        fileprivate init(grant: Journal.RemoteCleanupGrant, removal: Removal?, stopAcknowledged: Bool,
            lookup: Installer.LookupObservation?, afcReleased: Bool, lockdownReleased: Bool) {
            grantID = grant.id; remotePackagePath = grant.remotePackagePath
            deviceCertificateSHA256 = grant.deviceCertificateSHA256; self.removal = removal
            stopSessionAcknowledged = stopAcknowledged; self.lookup = lookup
            fileCloseAcknowledgement = .noRemoteFileOpenedInRecovery
            afcChannelReleasedLocally = afcReleased; lockdownChannelReleasedLocally = lockdownReleased
        }
    }
    /// Actual Remove/ENOENT facts survive a later StopSession or journal error.
    /// The prior installation failure is an attachment, never delete authority.
    struct RecoveryFailure: Error, @unchecked Sendable {
        let underlying: Error
        let originalOperationError: Error?
        let grantReleaseError: Error?
        let grantID: UUID?
        let remotePackagePath: String?
        let removal: Removal?
        let stopSessionAcknowledged: Bool
        let afcChannelReleasedLocally: Bool
        let lockdownChannelReleasedLocally: Bool
        /// Present only if all network checks finished but persisting their
        /// sealed outcome failed. A new journal grant is still required to retry.
        let networkOutcome: Outcome?
        var removalAcknowledged: Bool { removal != nil }
    }
    private struct Progress {
        var removal: Removal?
        var stopAcknowledged = false
        var afcReleased = false
        var lockdownReleased = false
    }
    private struct NetworkFailure: Error, @unchecked Sendable {
        let underlying: Error
        let progress: Progress
    }

    /// One explicit recovery attempt uses a NEW cancellation owner and absolute
    /// deadline. The journal's grant blocks submission/record mutation/close for
    /// the complete network operation, not only for the initial snapshot read.
    nonisolated static func cleanup(journal: Journal, expected: Journal.Snapshot,
        pairing: Transport.PairingIdentity, lockdownEndpoint: Transport.Endpoint,
        at date: Date, timeoutSeconds: TimeInterval = 30,
        originalOperationError: Error? = nil) async throws -> Outcome {
        let grant: Journal.RemoteCleanupGrant
        do { grant = try await journal.acquireRemoteCleanup(expected) }
        catch {
            throw RecoveryFailure(underlying: error, originalOperationError: originalOperationError,
                grantReleaseError: nil,
                grantID: nil, remotePackagePath: nil, removal: nil, stopSessionAcknowledged: false,
                afcChannelReleasedLocally: false, lockdownChannelReleasedLocally: false, networkOutcome: nil)
        }
        var completedNetwork: Outcome?
        do {
            try Task.checkCancellation()
            try validate(grant, expected: expected, pairing: pairing, at: date)
            let cancellation = Transport.Cancellation()
            let worker = Task.detached(priority: .utility) {
                let started = SourcePerfTrace.now
                defer {
                    SourcePerfTrace.record("renewal.install.recovery",
                        "candidateBytes=\(grant.archiveBytes) main=\(Thread.isMainThread)", since: started, thresholdMs: 0)
                }
                switch grant.disposition {
                case .unknownSubmission:
                    // Even Lookup notFound is insufficient evidence that a
                    // submitted asynchronous Upgrade no longer reads its IPA.
                    let observation = try await Installer.lookup(pairing: pairing, lockdownEndpoint: lockdownEndpoint,
                        bundleIdentifier: grant.bundleIdentifier, at: date, timeoutSeconds: timeoutSeconds)
                    try cancellation.check()
                    return Outcome(grant: grant, removal: nil, stopAcknowledged: true,
                        lookup: observation, afcReleased: false, lockdownReleased: true)
                case .safeBeforeSubmission, .reportedComplete:
                    return try remove(grant, pairing: pairing, endpoint: lockdownEndpoint, at: date,
                        cancellation: cancellation, deadline: Transport.Stream.deadline(seconds: timeoutSeconds))
                }
            }
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: {
                cancellation.cancel(); worker.cancel()
            }
            completedNetwork = result
            // Still holds the same owner-issued grant. Only its actual outcome
            // may atomically advance that journal; failure never drops a pending
            // submission or fabricates a negative Upgrade result.
            _ = try await journal.completeRemoteCleanup(grant, outcome: result, at: date)
            try await journal.releaseRemoteCleanup(grant)
            return result
        } catch {
            var releaseError: Error?
            do { try await journal.releaseRemoteCleanup(grant) }
            catch { releaseError = error }
            let network = error as? NetworkFailure
            let progress = network?.progress
            throw RecoveryFailure(underlying: network?.underlying ?? error,
                originalOperationError: originalOperationError, grantReleaseError: releaseError, grantID: grant.id,
                remotePackagePath: grant.remotePackagePath, removal: completedNetwork?.removal ?? progress?.removal,
                stopSessionAcknowledged: completedNetwork?.stopSessionAcknowledged ?? progress?.stopAcknowledged ?? false,
                afcChannelReleasedLocally: completedNetwork?.afcChannelReleasedLocally ?? progress?.afcReleased ?? false,
                lockdownChannelReleasedLocally: completedNetwork?.lockdownChannelReleasedLocally ?? progress?.lockdownReleased ?? false,
                networkOutcome: completedNetwork)
        }
    }

    private static func validate(_ grant: Journal.RemoteCleanupGrant, expected: Journal.Snapshot,
        pairing: Transport.PairingIdentity, at date: Date) throws {
        guard date.timeIntervalSince1970.isFinite else { throw Failure.invalidDate }
        let record = grant.snapshot.record
        guard record.id == expected.record.id,
              grant.archiveSHA256.count == 32, grant.deviceCertificateSHA256.count == 32,
              (1...Installer.Limits.archiveBytes).contains(grant.archiveBytes),
              record.candidate?.sha256 == grant.archiveSHA256, record.candidate?.byteCount == grant.archiveBytes,
              record.bundleIdentifier == grant.bundleIdentifier, record.bundleVersion == grant.bundleVersion,
              !grant.bundleIdentifier.isEmpty, grant.bundleIdentifier.utf8.count <= 255,
              !grant.bundleVersion.isEmpty, grant.bundleVersion.utf8.count <= 64 else { throw Failure.invalidGrant }
        guard Data(SHA256.hash(data: pairing.deviceCertificateDER)) == grant.deviceCertificateSHA256 else { throw Failure.wrongDevice }
        try validateOwnedPath(grant.remotePackagePath)
    }
    /// Literal ASCII path, a single canonical random UUID v4 component, no
    /// aliases/traversal/alternate encoding, never a caller-provided device path.
    static func validateOwnedPath(_ path: String) throws {
        let prefix = "PublicStaging/reader-renewal-"
        guard path.hasPrefix(prefix), path.hasSuffix(".ipa"),
              path.utf8.count == prefix.utf8.count + 36 + 4 else { throw Failure.invalidOwnedPath }
        let token = String(path.dropFirst(prefix.count).dropLast(4))
        guard let uuid = UUID(uuidString: token), uuid.uuidString.lowercased() == token,
              Array(token.utf8)[14] == 0x34,
              [UInt8(0x38), 0x39, 0x61, 0x62].contains(Array(token.utf8)[19]) else { throw Failure.invalidOwnedPath }
    }

    private static func remove(_ grant: Journal.RemoteCleanupGrant, pairing: Transport.PairingIdentity,
        endpoint: Transport.Endpoint, at date: Date, cancellation: Transport.Cancellation,
        deadline: UInt64) throws -> Outcome {
        precondition(!Thread.isMainThread)
        var progress = Progress()
        var lockdown: Transport.Stream?
        var afc: Transport.Stream?
        do {
            let session = try Transport.Stream(endpoint: endpoint, cancellation: cancellation, deadline: deadline)
            lockdown = session
            let channel = Installer.PlistChannel(session)
            let authenticated = try Installer.openSession(channel, pairing: pairing, at: date)
            guard authenticated.authentication.peerCertificateSHA256 == grant.deviceCertificateSHA256 else { throw Failure.wrongDevice }
            let service = try Installer.startService("com.apple.afc", on: channel, endpoint: endpoint)
            let files = try Transport.Stream(endpoint: service, cancellation: cancellation, deadline: deadline)
            afc = files
            try files.authenticate(identity: pairing.hostIdentity, expectedPeerDER: pairing.deviceCertificateDER,
                rootDER: pairing.rootCertificateDER, at: date)
            guard files.authentication?.peerCertificateSHA256 == grant.deviceCertificateSHA256 else { throw Failure.wrongDevice }
            let remote = Installer.AFCChannel(files)
            do { try remote.remove(grant.remotePackagePath); progress.removal = .removedAcknowledged }
            catch Installer.Failure.afcStatus(8) { progress.removal = .alreadyAbsentAcknowledged }
            files.close(); progress.afcReleased = true
            try Installer.stopSession(channel, sessionID: authenticated.id)
            progress.stopAcknowledged = true
            try cancellation.check(); try session.check()
            session.close(); progress.lockdownReleased = true
            return Outcome(grant: grant, removal: progress.removal, stopAcknowledged: progress.stopAcknowledged,
                lookup: nil, afcReleased: progress.afcReleased, lockdownReleased: progress.lockdownReleased)
        } catch {
            if let afc { afc.close(); progress.afcReleased = true }
            if let lockdown { lockdown.close(); progress.lockdownReleased = true }
            throw NetworkFailure(underlying: error, progress: progress)
        }
    }
}
