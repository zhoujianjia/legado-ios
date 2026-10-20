from pathlib import Path
p=Path('F:/yuedu-reader/.build/s4-authenticated-installation-gap-step/work/Tests/iOS/yuedu appTests/SelfRenewalAuthenticatedInstallationClientTests.swift')
b=p.read_bytes(); assert b.count(b'\r\n')==218
marker=b'    @Test\r\n    func cancellationWakesActualStalledTLSHandshakeWithoutLateWrites() async throws {'
assert b.count(marker)==1
position=b.index(marker)
old=b[:position]
end=b'    }\r\n\r\n'
assert old.endswith(end)
block='''        // Lookup is a status stream, not a one-frame identity ACK. The
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
'''
old=old[:-len(end)]+block.replace('\n','\r\n').encode()+end
b=old+b[position:]
marker=b'    @Test\r\n    func enforcesActualFrameProgressDeadlineAndArchiveBudgets() async throws {'
position=b.index(marker);old=b[:position];assert old.endswith(end)
block='''        let result: [String: Client.Value] = ["owned.reader": .dictionary([
            "CFBundleIdentifier": .string("owned.reader"), "CFBundleVersion": .string("42")])]
        let pending: [String: Client.Value] = ["Status": .string("LookingUp"), "LookupResult": .dictionary(result)]
        try await Fixture.withPeer(.lookupOnly, lookupResponses: [pending], holdLookupAfterReplies: true) { context in
            let operation = Task { try await context.lookup() }
            var replies = context.lookupRepliesSent.makeAsyncIterator()
            let sent = await replies.next()
            #expect(sent != nil && context.observed.snapshot.lookupRepliesSent == 1)
            operation.cancel()
            let error = await Self.rejected { try await operation.value }
            #expect(error as? Transport.Failure == .cancelled)
            #expect(context.observed.snapshot.upgradeRequests == 0)
            #expect(context.observed.snapshot.stoppedSessions.isEmpty)
        }
'''
old=old[:-len(end)]+block.replace('\n','\r\n').encode()+end;b=old+b[position:]
marker=b'    private static func rejected<T>'
position=b.index(marker);old=b[:position];assert old.endswith(end)
block='''        let pending: [String: Client.Value] = ["Status": .string("LookingUp")]
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
'''
old=old[:-len(end)]+block.replace('\n','\r\n').encode()+end;b=old+b[position:]
p.write_bytes(b)
