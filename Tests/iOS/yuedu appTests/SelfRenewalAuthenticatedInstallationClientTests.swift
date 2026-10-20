import CryptoKit
import Foundation
import Testing
@testable import yuedu_app

struct SelfRenewalAuthenticatedInstallationClientTests {
    typealias Fixture = SelfRenewalAuthenticatedInstallationFixture
    typealias Client = SelfRenewalAuthenticatedInstallationClient
    typealias Transport = SelfRenewalAuthenticatedDeviceTransport

    @Test
    func uploadsRealTLSChunksAndRequiresCompleteLookupCleanupAndStop() async throws {
        try await Fixture.withPeer { context in
            let receipt = try await context.upgrade { submission in
                #expect(submission.archiveSHA256 == context.archive.sha256)
                #expect(submission.uploadedBytes == context.bytes.count)
                #expect(submission.remotePackagePath.hasPrefix("PublicStaging/reader-renewal-"))
                #expect(context.observed.snapshot.uploaded == context.bytes)
                #expect(context.observed.snapshot.upgradeRequests == 0)
            }
            let observed = context.observed.snapshot
            #expect(observed.authenticatedChannels == 3)
            #expect(observed.uploaded == context.bytes)
            #expect(receipt.uploadedBytes == context.bytes.count)
            #expect(receipt.archiveSHA256 == Data(SHA256.hash(data: context.bytes)))
            #expect(receipt.bundleIdentifier == context.bundle)
            #expect(receipt.bundleVersion == context.version)
            #expect(receipt.progressMessages == 2)
            #expect(observed.upgradeRequests == 1)
            #expect(observed.lookupRequests == 1)
            #expect(observed.removedPaths.count == 1)
            #expect(observed.stoppedSessions == ["owned-session"])
            #expect(receipt.remoteStagingRemoved)
            #expect(receipt.lockdownAuthentication.negotiatedTLSVersion == "TLS1.2")
            #expect(receipt.afcAuthentication.peerCertificateSHA256 == receipt.installationAuthentication.peerCertificateSHA256)
            #expect(receipt.upgradeReportedComplete && receipt.exactLookupIdentityObserved)
            #expect(!receipt.appleInstallationAuthorityVerified && !receipt.samePhysicalDeviceVerified)
            #expect(!receipt.noVPNRouteVerified && !receipt.unattendedRenewalVerified)
        }
    }

    @Test
    func rejectsActualWrongDeviceHostAndExpiredTLSCertificates() async throws {
        for mode: Fixture.Mode in [.wrongDeviceCertificate, .wrongHostCertificate, .expiredPeer] {
            try await Fixture.withPeer(mode) { context in
                let error = await Self.rejected { try await context.upgrade() }
                let failure = error as? Client.OperationFailure
                #expect(failure != nil)
                #expect(failure?.upgradeMayHaveExecuted == false)
                #expect(context.observed.snapshot.uploaded.isEmpty)
                #expect(context.observed.snapshot.upgradeRequests == 0)
            }
        }
    }

    @Test
    func rejectsInvalidSessionServicePortsAndPlaintextDowngrades() async throws {
        for mode: Fixture.Mode in [.falseSession, .missingServiceSSL, .invalidPort, .wrongSession] {
            try await Fixture.withPeer(mode) { context in
                let error = await Self.rejected { try await context.upgrade() }
                let failure = error as? Client.OperationFailure
                #expect(failure != nil)
                #expect(failure?.upgradeMayHaveExecuted == (mode == .wrongSession))
                if mode == .wrongSession {
                    let underlying = failure?.underlying as? Client.Failure
                    #expect(underlying == .sessionMismatch)
                    #expect(context.observed.snapshot.removedPaths.count == 1)
                } else { #expect(context.observed.snapshot.upgradeRequests == 0) }
            }
        }
    }

    @Test
    func rejectsActualAFCSequenceTruncationErrorsAndChangedArchiveDigest() async throws {
        for mode: Fixture.Mode in [.badAFCSequence, .truncatedAFC, .afcError] {
            try await Fixture.withPeer(mode) { context in
                let error = await Self.rejected { try await context.upgrade() }
                let failure = error as? Client.OperationFailure
                #expect(failure?.stage == .upload)
                #expect(failure?.upgradeMayHaveExecuted == false)
                #expect(context.observed.snapshot.upgradeRequests == 0)
            }
        }
        try await Fixture.withPeer(.unusedInput) { context in
            let changed = Client.ArchiveInput(byteCount: context.archive.byteCount, sha256: Data(repeating: 7, count: 32), read: context.archive.read)
            let error = await Self.rejected { try await context.upgrade(archive: changed) }
            let underlying = (error as? Client.OperationFailure)?.underlying as? Client.Failure
            #expect(underlying == .archiveChanged)
            let failure = error as? Client.OperationFailure
            #expect(failure?.remoteStagingRemovalVerified == true)
            #expect(failure?.cleanupAttempted == true)
            #expect(context.observed.snapshot.uploaded == context.bytes)
            #expect(context.observed.snapshot.upgradeRequests == 0)
        }
        for mode in [Fixture.Mode.midUploadError, .midUploadCleanupError] {
            try await Fixture.withPeer(mode) { context in
                let error = await Self.rejected { try await context.upgrade() }
                let failure = error as? Client.OperationFailure
                let original = failure?.underlying as? Client.Failure
                #expect(original == .afcStatus(10))
                #expect(failure?.remoteCreationAttempted == true)
                #expect(failure?.cleanupAttempted == true)
                #expect(failure?.remoteStagingRemovalVerified == (mode == .midUploadError))
                #expect(failure?.cleanupErrors.count == (mode == .midUploadCleanupError ? 1 : 0))
                #expect(context.observed.snapshot.uploaded.count == 65_536)
                #expect(context.observed.snapshot.closedFileHandles == 1)
                #expect(context.observed.snapshot.removeAttempts == 1)
                #expect(context.observed.snapshot.upgradeRequests == 0)
            }
        }
        try await Fixture.withPeer(.unusedInput) { context in
            let error = await Self.rejected {
                try await context.upgrade(beforeCreation: { intent in
                    #expect(intent.expectedArchiveSHA256 == context.archive.sha256)
                    #expect(context.observed.snapshot.openedFileHandles == 0)
                    throw Fixture.FixtureFailure.invalidRequest
                })
            }
            let failure = error as? Client.OperationFailure
            #expect(failure?.remoteCreationAttempted == false)
            #expect(failure?.cleanupAttempted == false)
            #expect(context.observed.snapshot.openedFileHandles == 0)
        }
        try await Fixture.withPeer(.unusedInput) { context in
            let error = await Self.rejected {
                try await context.upgrade { _ in throw Fixture.FixtureFailure.invalidRequest }
            }
            let failure = error as? Client.OperationFailure
            #expect(failure?.stage == .upload)
            #expect(failure?.upgradeMayHaveExecuted == false)
            #expect(failure?.remoteStagingRemovalVerified == true)
            #expect(context.observed.snapshot.upgradeRequests == 0)
        }
    }

    @Test
    func requiresTerminalCompleteAndExactPostUpgradeLookupIdentity() async throws {
        for mode: Fixture.Mode in [.installError, .noComplete, .wrongLookup] {
            try await Fixture.withPeer(mode) { context in
                let error = await Self.rejected { try await context.upgrade(timeout: mode == .noComplete ? 3 : 8) }
                let failure = error as? Client.OperationFailure
                #expect(failure?.upgradeMayHaveExecuted == true)
                #expect(context.observed.snapshot.upgradeRequests == 1)
                if mode == .wrongLookup {
                    let underlying = failure?.underlying as? Client.Failure
                    #expect(underlying == .lookupMismatch)
                    #expect(context.observed.snapshot.lookupRequests == 1)
                } else { #expect(context.observed.snapshot.lookupRequests == 0) }
            }
        }
        for mode: Fixture.Mode in [.lookupOnly, .lookupMissing] {
            try await Fixture.withPeer(mode) { context in
                let lookup = try await context.lookup()
                let expected: Client.LookupObservation.Presence = mode == .lookupMissing ? .notFound : .reported(bundleIdentifier: "owned.reader", bundleVersion: "42")
                #expect(lookup.presence == expected)
                #expect(!lookup.installedArchiveDigestVerified && !lookup.installedProfileOrEntitlementsVerified)
                #expect(!lookup.appRelaunchOrDataPreservationVerified)
                #expect(context.observed.snapshot.upgradeRequests == 0)
                #expect(context.observed.snapshot.uploaded.isEmpty)
            }
        }
        try await Fixture.withPeer(.disconnectAfterUpgradeThenRecover) { context in
            let error = await Self.rejected { try await context.upgrade() }
            let failure = error as? Client.OperationFailure
            #expect(failure?.stage == .upgrade)
            #expect(failure?.upgradeMayHaveExecuted == true)
            let lookup = try await context.lookup()
            #expect(lookup.presence == .reported(bundleIdentifier: "owned.reader", bundleVersion: "42"))
            #expect(context.observed.snapshot.upgradeRequests == 1)
            #expect(context.observed.snapshot.lookupRequests == 1)
            #expect(context.observed.snapshot.authenticatedChannels == 5)
            #expect(context.observed.snapshot.stoppedSessions == ["owned-recovery-session"])
            #expect(!lookup.installedProfileOrEntitlementsVerified)
        }
        // Lookup is a status stream, not a one-frame identity ACK. The
        // same real mTLS peer may send data before the terminal Complete.
        let result: [String: Client.Value] = ["owned.reader": .dictionary([
            "CFBundleIdentifier": .string("owned.reader"), "CFBundleVersion": .string("42")])]
        let complete: [String: Client.Value] = ["Status": .string("Complete")]
        let pending: [String: Client.Value] = ["Status": .string("LookingUp"), "LookupResult": .dictionary(result)]
        let separateComplete: [[String: Client.Value]] = [
            ["LookupResult": .dictionary(result)], ["Status": .string("Resolving")], complete]
        try await Fixture.withPeer(.lookupOnly, lookupResponses: separateComplete) { context in
            let observed = try await context.lookup()
            #expect(observed.presence == .reported(bundleIdentifier: context.bundle, bundleVersion: context.version))
            #expect(!observed.installedProfileOrEntitlementsVerified && !observed.installedArchiveDigestVerified)
            #expect(context.observed.snapshot.stoppedSessions == ["owned-session"])
        }
        // Match the upstream callback: each LookupResult replaces its prior
        // snapshot, including an empty final snapshot. It does not merge them.
        let matchingThenEmpty: [[String: Client.Value]] = [pending,
            ["Status": .string("Complete"), "LookupResult": .dictionary([:])]]
        try await Fixture.withPeer(.lookupOnly, lookupResponses: matchingThenEmpty) { context in
            let observed = try await context.lookup()
            #expect(observed.presence == .notFound)
        }
        let emptyThenMatching: [[String: Client.Value]] = [["LookupResult": .dictionary([:])],
            ["Status": .string("Complete"), "LookupResult": .dictionary(result)]]
        try await Fixture.withPeer(.lookupOnly, lookupResponses: emptyThenMatching) { context in
            let observed = try await context.lookup()
            #expect(observed.presence == .reported(bundleIdentifier: context.bundle, bundleVersion: context.version))
        }
        let errorWithMatchingResult: [String: Client.Value] = ["Error": .string("OwnedLookupError"),
            "Status": .string("Complete"), "LookupResult": .dictionary(result)]
        let rejectedReplies: [[[String: Client.Value]]] = [[pending, errorWithMatchingResult], [pending], [complete]]
        for (index, replies) in rejectedReplies.enumerated() {
            try await Fixture.withPeer(.lookupOnly, lookupResponses: replies) { context in
                let error = await Self.rejected { try await context.lookup() }
                if index == 0 { #expect(error as? Client.Failure == .remoteError("OwnedLookupError")) }
                else if index == 1 { #expect(error as? Transport.Failure == .endOfStream) }
                else { #expect(error as? Client.Failure == .malformedResponse) }
                #expect(context.observed.snapshot.upgradeRequests == 0)
                #expect(context.observed.snapshot.stoppedSessions.isEmpty)
            }
        }
        try await Fixture.withPeer(.unusedInput, lookupResponses: [pending, errorWithMatchingResult]) { context in
            let error = await Self.rejected { try await context.upgrade() }
            let failure = error as? Client.OperationFailure
            #expect(failure?.stage == .lookup && failure?.upgradeMayHaveExecuted == true)
            #expect(failure?.underlying as? Client.Failure == .remoteError("OwnedLookupError"))
            #expect(context.observed.snapshot.upgradeRequests == 1 && context.observed.snapshot.lookupRequests == 1)
            #expect(context.observed.snapshot.stoppedSessions.isEmpty)
        }
    }

    @Test
    func cancellationWakesActualStalledTLSHandshakeWithoutLateWrites() async throws {
        try await Fixture.withPeer(.stallSession) { context in
            let operation = Task { try await context.upgrade(timeout: 8) }
            var events = context.sessionRequestReceived.makeAsyncIterator()
            let received = await events.next()
            if received != true { operation.cancel(); _ = await operation.result }
            try #require(received == true)
            operation.cancel()
            let error = await Self.rejected { try await operation.value }
            let underlying = (error as? Client.OperationFailure)?.underlying as? Transport.Failure
            #expect(underlying == .cancelled)
            #expect(context.observed.snapshot.upgradeRequests == 0)
            #expect(context.observed.snapshot.uploaded.isEmpty)
        }
        let result: [String: Client.Value] = ["owned.reader": .dictionary([
            "CFBundleIdentifier": .string("owned.reader"), "CFBundleVersion": .string("42")])]
        let pending: [String: Client.Value] = ["Status": .string("LookingUp"), "LookupResult": .dictionary(result)]
        try await Fixture.withPeer(.lookupOnly, lookupResponses: [pending], holdLookupAfterReplies: true) { context in
            let operation = Task { try await context.lookup() }
            var replies = context.lookupRepliesSent.makeAsyncIterator()
            let sent = await replies.next()
            let replyCount = context.observed.snapshot.lookupRepliesSent
            if sent != true || replyCount != 1 { operation.cancel(); _ = await operation.result }
            try #require(sent == true && replyCount == 1)
            operation.cancel()
            let error = await Self.rejected { try await operation.value }
            #expect(error as? Transport.Failure == .cancelled)
            // The actual socket peer has exited after cancellation. Its event
            // stream must terminate before the enclosing action returns.
            let finished = await replies.next()
            #expect(finished == nil)
            #expect(context.observed.snapshot.upgradeRequests == 0)
            #expect(context.observed.snapshot.stoppedSessions.isEmpty)
        }
    }

    @Test
    func enforcesActualFrameProgressDeadlineAndArchiveBudgets() async throws {
        for mode: Fixture.Mode in [.excessivePlist, .excessiveProgress] {
            try await Fixture.withPeer(mode) { context in
                let error = await Self.rejected { try await context.upgrade() }
                let failure = error as? Client.OperationFailure
                #expect(failure?.stage == .upgrade)
                #expect(failure?.upgradeMayHaveExecuted == true)
                #expect(context.observed.snapshot.lookupRequests == 0)
            }
        }
        try await Fixture.withPeer(.unusedInput) { context in
            let empty = Client.ArchiveInput(byteCount: 0, sha256: Data(repeating: 0, count: 32), read: context.archive.read)
            let error = await Self.rejected { try await context.upgrade(archive: empty) }
            #expect(error as? Client.Failure == .invalidArchive)
            let badDeadline = await Self.rejected { try await context.upgrade(timeout: 901) }
            #expect(badDeadline as? Transport.Failure == .invalidLimit)
            #expect(context.observed.snapshot.authenticatedChannels == 0)
        }
        let pending: [String: Client.Value] = ["Status": .string("LookingUp")]
        let tooManyReplies = Array(repeating: pending, count: Client.Limits.progressMessages + 1)
        let padded: [String: Client.Value] = ["Status": .string("LookingUp"),
            "BoundedPadding": .string(String(repeating: "x", count: 200_000))]
        let tooManyBytes = Array(repeating: padded, count: 43)
        for replies in [tooManyReplies, tooManyBytes] {
            try await Fixture.withPeer(.lookupOnly, lookupResponses: replies) { context in
                let error = await Self.rejected { try await context.lookup() }
                #expect(error as? Client.Failure == .progressLimit)
                #expect(context.observed.snapshot.upgradeRequests == 0)
                #expect(context.observed.snapshot.stoppedSessions.isEmpty)
            }
        }
    }

    private static func rejected<T>(_ action: () async throws -> T) async -> Error {
        do { _ = try await action(); Issue.record("Expected actual protocol operation to reject"); return Fixture.FixtureFailure.invalidRequest }
        catch { return error }
    }
}
