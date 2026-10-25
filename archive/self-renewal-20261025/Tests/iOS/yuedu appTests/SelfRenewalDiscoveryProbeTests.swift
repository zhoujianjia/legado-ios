import Foundation
import Darwin
@preconcurrency import Network
import Testing
@testable import yuedu_app

@Suite("Bounded same-device discovery", .serialized, .timeLimit(.minutes(1)))
struct SelfRenewalDiscoveryProbeTests {
    @Test func acceptsOnlyOwnedAddresses() throws {
        let local = v4([192, 168, 7, 23])
        let snapshot = try #require(SelfRenewalLocalAddressSnapshot(entries: [entry(local)]))
        #expect(snapshot.category(for: endpoint(local)) == .localInterface)
        #expect(snapshot.category(for: endpoint(v4([192, 168, 7, 24]))) == nil)
        #expect(snapshot.category(for: endpoint(local, port: 0)) == nil)
        let loop = try #require(SelfRenewalLocalAddressSnapshot(entries: [entry(v4([127, 0, 0, 1]), loopback: true)]))
        #expect(loop.category(for: endpoint(v4([127, 0, 0, 1]))) == .loopback)
        #expect(loop.category(for: endpoint(v4([127, 0, 0, 2]))) == nil)
    }

    @Test func rejectsNonUnicastAndMalformedAddresses() {
        for bytes: [UInt8] in [[0, 0, 0, 0], [0, 1, 2, 3], [224, 0, 0, 1], [239, 1, 2, 3], [255, 255, 255, 255], [240, 1, 2, 3]] {
            #expect(!v4(bytes).isEligibleUnicast)
        }
        for bytes: [UInt8] in [[], [127], [127, 0, 0, 1, 2]] {
            #expect(SelfRenewalNumericAddress(family: .ipv4, bytes: bytes) == nil)
        }
        for bytes: [UInt8] in [Array(repeating: 0, count: 16), [0xff] + Array(repeating: 0, count: 15),
                              Array(repeating: 0, count: 10) + [0xff, 0xff, 127, 0, 0, 1],
                              Array(repeating: 0, count: 12) + [192, 168, 7, 23]] {
            #expect(SelfRenewalNumericAddress(family: .ipv6, bytes: bytes)?.isEligibleUnicast == false)
        }
        #expect(!v4([127, 0, 0, 1], scope: 4).isEligibleUnicast)
        // Darwin sockaddr_in is length/family, network port, then IPv4 bytes.
        let raw = Data([16, 2, 0, 0, 192, 168, 7, 23] + Array(repeating: 0, count: 8))
        #expect(SelfRenewalDiscoveryNativeDriver.numericAddressForTesting(bytes: raw, interfaceIndex: 4) == v4([192, 168, 7, 23]))
        #expect(SelfRenewalDiscoveryNativeDriver.numericAddressForTesting(bytes: Data([16, 2, 0]), interfaceIndex: 4) == nil)
        #expect(SelfRenewalDiscoveryNativeDriver.numericAddressForTesting(bytes: Data([0, 2]), interfaceIndex: 4) == nil)
    }

    @Test func scopedIPv6NeedsExactInterface() throws {
        let bytes: [UInt8] = [0xfe, 0x80] + Array(repeating: 0, count: 13) + [9]
        let scoped = try #require(SelfRenewalNumericAddress(family: .ipv6, bytes: bytes, scopeID: 4))
        let missing = try #require(SelfRenewalNumericAddress(family: .ipv6, bytes: bytes))
        let wrong = try #require(SelfRenewalNumericAddress(family: .ipv6, bytes: bytes, scopeID: 7))
        let snapshot = try #require(SelfRenewalLocalAddressSnapshot(entries: [entry(scoped)]))
        #expect(snapshot.category(for: endpoint(scoped)) == .localInterface)
        #expect(snapshot.category(for: endpoint(missing)) == nil)
        #expect(snapshot.category(for: endpoint(wrong)) == nil)
        // An explicit DNS-SD callback interface is authoritative; a browse hint alone is not.
        var raw = [UInt8]([28, 30, 0, 0, 0, 0, 0, 0]) + bytes + [0, 0, 0, 0]
        #expect(SelfRenewalDiscoveryNativeDriver.numericAddressForTesting(bytes: Data(raw), interfaceIndex: 4) == scoped)
        #expect(SelfRenewalDiscoveryNativeDriver.numericAddressForTesting(bytes: Data(raw), interfaceIndex: 0) == nil)
        raw[24] = 7 // Darwin's sin6_scope_id is host byte order on this arm64 test target.
        #expect(SelfRenewalDiscoveryNativeDriver.numericAddressForTesting(bytes: Data(raw), interfaceIndex: 4) == nil)
        #expect(scoped.numericHost.hasSuffix("%4"))
        let loopbackIndex = if_nametoindex("lo0")
        try #require(loopbackIndex > 0)
        let sdkScoped = try #require(SelfRenewalNumericAddress(family: .ipv6, bytes: bytes, scopeID: loopbackIndex))
        #expect(SelfRenewalTransportProbe.acceptsNativeAddressForTesting(sdkScoped))
        #expect(SelfRenewalTransportProbe.acceptsNativeAddressForTesting(v4([192, 168, 7, 23])))
    }

    @Test func rejectsBroadcastAndExcludedInterfaces() throws {
        let broadcast = v4([192, 168, 7, 255])
        for item in [entry(broadcast), entry(v4([192, 168, 7, 23]), pointToPoint: true),
                     entry(v4([192, 168, 7, 23]), eligible: false), entry(v4([192, 168, 7, 23]), up: false),
                     entry(v4([192, 168, 7, 23]), mask: [255, 0, 255, 0])] {
            let snapshot = try #require(SelfRenewalLocalAddressSnapshot(entries: [item]))
            #expect(snapshot.category(for: endpoint(item.address)) == nil)
        }
        let shortMask = Data([7, 0, 0, 0, 255, 255, 255])
        #expect(SelfRenewalDiscoveryNativeDriver.ipv4MaskForTesting(bytes: shortMask) == [255, 255, 255, 0])
        #expect(SelfRenewalDiscoveryNativeDriver.ipv4MaskForTesting(bytes: Data([9, 0, 0, 0, 255])) == nil)
        let hostRoute = try #require(SelfRenewalLocalAddressSnapshot(entries: [entry(v4([192, 168, 7, 255]), mask: [255, 255, 255, 255])]))
        #expect(hostRoute.category(for: endpoint(v4([192, 168, 7, 255]))) == .localInterface)
    }

    @Test func snapshotsDetectRelevantTopologyChanges() throws {
        let local = v4([192, 168, 7, 23])
        let first = try #require(SelfRenewalLocalAddressSnapshot(entries: [entry(local)]))
        for other in [[entry(local, rawFlags: 2)], [entry(local, index: 5)],
                      [entry(local, mask: [255, 255, 0, 0])], [entry(local), entry(v4([10, 0, 0, 1]), eligible: false)], []] {
            #expect(SelfRenewalLocalAddressSnapshot(entries: other) != first)
        }
        #expect(SelfRenewalLocalAddressSnapshot(entries: Array(repeating: entry(local), count: 129)) == nil)
        #expect(SelfRenewalLocalAddressSnapshot(entries: [entry(local), entry(local)]) == first)
    }

    @Test func connectsOnlyAfterClosedWindowAndKeepsReportRedacted() async throws {
        let id = UUID(uuidString: "b2cabcd1-1234-4567-9876-123456789abc")!
        let local = v4([192, 168, 7, 23])
        let fixture = try fixture(events: [.ready, .found(id), .resolved(id, endpoint(local)), .windowEnded])
        let report = await run(fixture)
        let discovery = try #require(report.remotePairingDiscovery)
        #expect(report.schemaVersion == 2 && report.attempts.isEmpty && report.testTransportInjected)
        #expect(discovery.outcome == .tcpConnected && discovery.tcpConnectionAttemptsStarted == 1)
        #expect(discovery.tcpApplicationPayloadBytesSent == 0 && !discovery.serviceIdentityVerified)
        #expect(fixture.state().connectedAfterWindowClosed)
        #expect(fixture.state().destinations == [endpoint(local)])
        let data = try JSONEncoder().encode(report)
        let text = String(decoding: data, as: UTF8.self)
        for secret in [id.uuidString, id.uuidString.lowercased(), "192.168.7.23", "64099", "scopeID", "hostname", "serviceName", "TXT"] {
            #expect(!text.contains(secret))
        }
        noRenewal(report)
    }

    @Test func removalsAndExpiredRecordsCannotConnect() async throws {
        let id = UUID()
        let local = v4([192, 168, 7, 23])
        for events: [SelfRenewalDiscoveryEvent] in [
            [.found(id), .resolved(id, endpoint(local)), .removed(id), .resolved(id, endpoint(local)), .windowEnded],
            [.found(id), .resolved(id, endpoint(local)), .addressRemoved(id, local), .windowEnded],
            [.found(id), .resolved(id, endpoint(local, expiry: 999)), .windowEnded],
            [.found(id), .resolved(id, endpoint(local)), .resolved(id, endpoint(local, expiry: 999)), .windowEnded],
        ] {
            let fixture = try fixture(events: events)
            let report = await run(fixture)
            #expect(report.remotePairingDiscovery?.outcome == .noLocalCandidate)
            #expect(fixture.state().destinations.isEmpty)
            noRenewal(report)
        }
    }

    @Test func incompleteOrOverflowedDiscoveryNeverConnects() async throws {
        let id = UUID()
        var valid: [SelfRenewalDiscoveryEvent] = [.found(id)]
        for port in UInt16(64_001)...UInt16(64_005) {
            valid.append(.resolved(id, endpoint(v4([192, 168, 7, 23]), port: port)))
        }
        for (tail, expected): ([SelfRenewalDiscoveryEvent], SelfRenewalDiscoveryOutcome) in [
            ([], .discoveryUnavailable), ([.limitExceeded], .limitExceeded),
            ([.invalidated], .discoveryChanged), ([.windowEnded, .windowEnded], .discoveryChanged),
        ] {
            let fixture = try fixture(events: valid + tail)
            let report = await run(fixture)
            #expect(report.remotePairingDiscovery?.outcome == expected)
            #expect(report.remotePairingDiscovery?.eligibleEndpointCount == nil)
            #expect(report.remotePairingDiscovery?.skippedEndpointCount == nil)
            #expect(report.remotePairingDiscovery?.endpointSelectionLimit == nil)
            #expect(fixture.state().destinations.isEmpty)
            noRenewal(report)
        }
    }

    @Test func revalidatesOwnershipAndTTLBeforeEachConnection() async throws {
        let id = UUID()
        let events: [SelfRenewalDiscoveryEvent] = [.found(id), .resolved(id, endpoint(v4([192, 168, 7, 23]), expiry: 1_002)), .windowEnded]
        let changed = try fixture(events: events)
        changed.configure(changeOnRevalidation: true)
        #expect(await run(changed).remotePairingDiscovery?.outcome == .interfaceChanged)
        #expect(changed.state().destinations.isEmpty)
        let expired = try fixture(events: events)
        expired.configure(advanceOnRevalidation: 3)
        #expect(await run(expired).remotePairingDiscovery?.outcome == .noLocalCandidate)
        #expect(expired.state().destinations.isEmpty)
        let deadline = try fixture(events: events)
        deadline.configure(advanceOnRevalidation: 9)
        #expect(await run(deadline).remotePairingDiscovery?.outcome == .timedOut)
        #expect(deadline.state().destinations.isEmpty)
    }

    @Test func cancellationAndGlobalDeadlineCloseAllWork() async throws {
        let cancelled = try fixture(events: [.ready], holdOpen: true)
        let task = Task { await run(cancelled) }
        await cancelled.waitForStart()
        task.cancel()
        let first = await task.value
        #expect(first.cancelled && first.remotePairingDiscovery?.outcome == .cancelled)
        #expect(cancelled.state().stopped && cancelled.state().destinations.isEmpty)
        let pre = try fixture(events: [.ready], holdOpen: true)
        let preTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await run(pre)
        }
        let second = await preTask.value
        #expect(second.cancelled && second.remotePairingDiscovery?.discoveryStarted == false)
        #expect(!pre.state().started)
        let deadline = try fixture(events: [.ready], holdOpen: true)
        let third = await SelfRenewalTransportProbe.runDiscoveryForTesting(dependencies: deadline.dependencies(), timeout: 0.03)
        #expect(third.remotePairingDiscovery?.outcome == .timedOut)
        #expect(deadline.state().stopped && deadline.state().destinations.isEmpty)
        noRenewal(first); noRenewal(second); noRenewal(third)
    }

    @Test func enforcesBudgetsAndPreservesDistinctFailures() async throws {
        let id = UUID()
        let local = v4([192, 168, 7, 23])
        // Keep each bounded fixture concrete: a nested map/array-concatenation
        // expression exceeds the Xcode 26.2 test target's type-checking budget.
        var serviceEvents: [SelfRenewalDiscoveryEvent] = []
        for _ in 0..<9 { serviceEvents.append(.found(UUID())) }
        serviceEvents.append(.windowEnded)
        var addressEvents: [SelfRenewalDiscoveryEvent] = [.found(id)]
        let repeatedEndpoint = endpoint(local)
        for _ in 0..<33 { addressEvents.append(.resolved(id, repeatedEndpoint)) }
        addressEvents.append(.windowEnded)
        var endpointEvents: [SelfRenewalDiscoveryEvent] = [.found(id)]
        for offset in 1...5 {
            let port = UInt16(64_000 + offset)
            endpointEvents.append(.resolved(id, endpoint(local, port: port)))
        }
        endpointEvents.append(.windowEnded)
        for events in [serviceEvents, addressEvents] {
            let fixture = try fixture(events: events)
            let report = await run(fixture)
            #expect(report.remotePairingDiscovery?.outcome == .limitExceeded)
            #expect(report.remotePairingDiscovery?.eligibleEndpointCount == nil)
            #expect(fixture.state().destinations.isEmpty)
        }
        // Five eligible destinations is a complete discovery, not a hard overflow.
        let selected = try fixture(events: endpointEvents)
        selected.configure(connectOutcome: .transportFailed)
        let selectionReport = await run(selected)
        #expect(selectionReport.remotePairingDiscovery?.outcome == .transportFailed)
        #expect(selectionReport.remotePairingDiscovery?.eligibleEndpointCount == 5)
        #expect(selectionReport.remotePairingDiscovery?.approvedEndpointCount == 4)
        #expect(selectionReport.remotePairingDiscovery?.skippedEndpointCount == 1)
        #expect(selectionReport.remotePairingDiscovery?.endpointSelectionLimit == 4)
        #expect(selectionReport.remotePairingDiscovery?.tcpConnectionAttemptsStarted == 4)
        #expect(selected.state().destinations.count == 4)
        noRenewal(selectionReport)
        let dns = SelfRenewalTransportNetworkError(.dns(-65570))
        let failureScenarios: [([SelfRenewalDiscoveryEvent], SelfRenewalDiscoveryOutcome)] = [
            ([.ready, .windowEnded], .discoveryTimedOut),
            ([.waiting(dns), .windowEnded], .discoveryUnavailable),
            ([.failed(dns)], .discoveryUnavailable),
            ([.found(id), .resolutionFailed(dns), .windowEnded], .resolutionFailed),
            ([.found(id), .resolved(id, endpoint(local)), .removed(id), .resolutionFailed(dns), .windowEnded], .resolutionFailed),
        ]
        for (events, expected) in failureScenarios {
            let fixture = try fixture(events: events)
            let report = await run(fixture)
            #expect(report.remotePairingDiscovery?.outcome == expected)
            #expect(fixture.state().destinations.isEmpty)
        }
    }

    @Test func selectsFourOwnedEndpointsFromReportedAddressShape() async throws {
        let first = UUID()
        let second = UUID()
        let lan = v4([192, 168, 7, 23])
        let other = v4([10, 0, 0, 23])
        let loopback = v4([127, 0, 0, 1])
        let foreign = v4([192, 168, 7, 24])
        let snapshot = try #require(SelfRenewalLocalAddressSnapshot(entries: [
            entry(lan), entry(other), entry(loopback, loopback: true)
        ]))
        let events: [SelfRenewalDiscoveryEvent] = [
            .found(first), .found(second),
            .resolved(second, endpoint(lan, port: 64_092)),
            .resolved(first, endpoint(loopback, port: 64_091)),
            .resolved(second, endpoint(foreign, port: 64_092)),
            .resolved(first, endpoint(lan, port: 64_091)),
            .resolved(second, endpoint(other, port: 64_092)),
            .resolved(first, endpoint(other, port: 64_091)), .windowEnded
        ]
        let fixture = DiscoveryFixture(snapshot: snapshot, events: events, holdOpen: false)
        fixture.configure(connectOutcome: .transportFailed)
        let report = await run(fixture)
        let discovery = try #require(report.remotePairingDiscovery)
        #expect(discovery.discoveredServiceCount == 2 && discovery.resolvedAddressCount == 6)
        #expect(discovery.rejectedAddressCount == 1 && discovery.eligibleEndpointCount == 5)
        #expect(discovery.approvedEndpointCount == 4 && discovery.skippedEndpointCount == 1)
        #expect(discovery.endpointSelectionLimit == 4 && discovery.tcpConnectionAttemptsStarted == 4)
        #expect(discovery.outcome == .transportFailed && discovery.tcpAttempts.count == 4)
        for attempt in discovery.tcpAttempts {
            #expect(attempt.networkError?.domain == "posix")
            #expect(attempt.networkError?.code == Int(ECONNREFUSED))
        }
        let expected = [endpoint(other, port: 64_091), endpoint(other, port: 64_092),
                        endpoint(loopback, port: 64_091), endpoint(lan, port: 64_091)]
        #expect(fixture.state().destinations == expected)
        #expect(fixture.state().timeouts == [2, 2, 2, 2])
        #expect(fixture.state().snapshotReads == 5 && fixture.state().connectedAfterWindowClosed)
        let data = try JSONEncoder().encode(report)
        let restored = try JSONDecoder().decode(SelfRenewalTransportProbeReport.self, from: data)
        #expect(restored.remotePairingDiscovery?.eligibleEndpointCount == 5)
        #expect(restored.remotePairingDiscovery?.skippedEndpointCount == 1)
        #expect(restored.remotePairingDiscovery?.endpointSelectionLimit == 4)
        let text = String(decoding: data, as: UTF8.self)
        for secret in [first.uuidString, second.uuidString, "192.168.7.23", "192.168.7.24", "10.0.0.23",
                       "127.0.0.1", "64091", "64092", "serviceName", "hostname", "expiresAtUptime"] {
            #expect(!text.contains(secret))
        }
        noRenewal(report)
    }

    @Test func selectionIsStableAcrossOrderAndUsesShorterDuplicateTTL() async throws {
        let first = UUID()
        let second = UUID()
        let two = v4([10, 0, 0, 2])
        let ten = v4([10, 0, 0, 10])
        let lan = v4([192, 168, 7, 23])
        let bytes: [UInt8] = [0xfe, 0x80] + Array(repeating: 0, count: 13) + [9]
        let ipv6 = try #require(SelfRenewalNumericAddress(family: .ipv6, bytes: bytes, scopeID: 4))
        let snapshot = try #require(SelfRenewalLocalAddressSnapshot(entries: [entry(two), entry(ten), entry(lan), entry(ipv6)]))
        let short = endpoint(two, port: 64_001, expiry: 1_001)
        let resolutions: [SelfRenewalDiscoveryEvent] = [
            .resolved(second, endpoint(ipv6, port: 64_001)),
            .resolved(first, endpoint(ten, port: 64_001)),
            .resolved(first, endpoint(two, port: 64_001)),
            .resolved(first, endpoint(ipv6, port: 64_002)),
            .resolved(first, endpoint(lan, port: 64_001)),
            .resolved(second, short), .resolved(first, endpoint(two, port: 64_002))
        ]
        var rotated = Array(resolutions.dropFirst(2))
        rotated.append(contentsOf: resolutions.prefix(2))
        let orderings: [[SelfRenewalDiscoveryEvent]] = [resolutions, Array(resolutions.reversed()), rotated]
        let expected = [short, endpoint(two, port: 64_002), endpoint(ten, port: 64_001), endpoint(lan, port: 64_001)]
        for resolutionOrder in orderings {
            var events: [SelfRenewalDiscoveryEvent] = [.found(first), .found(second)]
            events.append(contentsOf: resolutionOrder)
            events.append(.windowEnded)
            let fixture = DiscoveryFixture(snapshot: snapshot, events: events, holdOpen: false)
            fixture.configure(connectOutcome: .transportFailed)
            let report = await run(fixture)
            let discovery = try #require(report.remotePairingDiscovery)
            #expect(discovery.eligibleEndpointCount == 6 && discovery.approvedEndpointCount == 4)
            #expect(discovery.skippedEndpointCount == 2 && discovery.endpointSelectionLimit == 4)
            #expect(discovery.tcpConnectionAttemptsStarted == 4 && discovery.rejectedAddressCount == 0)
            #expect(fixture.state().destinations == expected)
            #expect(fixture.state().timeouts == [1, 2, 2, 2])
            #expect(fixture.state().connectedAfterWindowClosed)
            noRenewal(report)
        }
    }

    @Test func selectionPreservesHardLimitsCancellationAndSnapshotChecks() async throws {
        let id = UUID()
        let local = v4([192, 168, 7, 23])
        var boundary: [SelfRenewalDiscoveryEvent] = [.found(id)]
        for index in 0..<32 {
            boundary.append(.resolved(id, endpoint(local, port: UInt16(64_001 + index % 5))))
        }
        let atLimit = try fixture(events: boundary + [.windowEnded])
        atLimit.configure(connectOutcome: .transportFailed)
        let boundedReport = await run(atLimit)
        #expect(boundedReport.remotePairingDiscovery?.resolvedAddressCount == 32)
        #expect(boundedReport.remotePairingDiscovery?.eligibleEndpointCount == 5)
        #expect(boundedReport.remotePairingDiscovery?.tcpConnectionAttemptsStarted == 4)
        var overflow = boundary
        overflow.append(.resolved(id, endpoint(local)))
        overflow.append(.windowEnded)
        let exceeded = try fixture(events: overflow)
        let exceededReport = await run(exceeded)
        #expect(exceededReport.remotePairingDiscovery?.outcome == .limitExceeded)
        #expect(exceededReport.remotePairingDiscovery?.eligibleEndpointCount == nil)
        #expect(exceededReport.remotePairingDiscovery?.skippedEndpointCount == nil)
        #expect(exceededReport.remotePairingDiscovery?.endpointSelectionLimit == nil)
        #expect(exceeded.state().destinations.isEmpty && exceeded.state().stopped)

        var events: [SelfRenewalDiscoveryEvent] = [.found(id)]
        for port in UInt16(64_001)...UInt16(64_005) { events.append(.resolved(id, endpoint(local, port: port))) }
        events.append(.windowEnded)
        let changed = try fixture(events: events)
        changed.configure(changeOnRevalidation: true, connectOutcome: .transportFailed, changeAfterSnapshotRead: 2)
        let changedReport = await run(changed)
        #expect(changedReport.remotePairingDiscovery?.outcome == .interfaceChanged)
        #expect(changedReport.remotePairingDiscovery?.tcpConnectionAttemptsStarted == 1)
        #expect(changed.state().destinations == [endpoint(local, port: 64_001)])
        #expect(changed.state().snapshotReads == 3 && changed.state().stopped)

        var expiring: [SelfRenewalDiscoveryEvent] = [.found(id), .resolved(id, endpoint(local, port: 64_001, expiry: 1_000.25))]
        for port in UInt16(64_002)...UInt16(64_005) { expiring.append(.resolved(id, endpoint(local, port: port))) }
        expiring.append(.windowEnded)
        let expired = try fixture(events: expiring)
        expired.configure(advanceOnRevalidation: 0.5, connectOutcome: .transportFailed)
        let expiredReport = await run(expired)
        #expect(expiredReport.remotePairingDiscovery?.eligibleEndpointCount == 5)
        #expect(expiredReport.remotePairingDiscovery?.approvedEndpointCount == 4)
        #expect(expiredReport.remotePairingDiscovery?.skippedEndpointCount == 1)
        #expect(expiredReport.remotePairingDiscovery?.rejectedAddressCount == 1)
        #expect(expiredReport.remotePairingDiscovery?.tcpConnectionAttemptsStarted == 3)
        #expect(expired.state().destinations == [endpoint(local, port: 64_002), endpoint(local, port: 64_003), endpoint(local, port: 64_004)])

        let cancelled = try fixture(events: events)
        let base = cancelled.dependencies()
        let entered = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let held = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let dependencies = SelfRenewalDiscoveryDependencies(
            events: base.events, stop: base.stop, snapshot: base.snapshot,
            connect: { endpoint, category, _ in
                entered.continuation.yield(true)
                // A real signal holds the injected connection until cancellation;
                // AsyncStream terminates its iterator when the worker is cancelled.
                for await _ in held.stream { break }
                return SelfRenewalDiscoveryTCPAttempt(family: endpoint.address.family, addressCategory: category,
                    outcome: .cancelled, elapsedMilliseconds: 0, networkError: nil, lastWaitingError: nil)
            }, uptime: base.uptime
        )
        let task = Task { await SelfRenewalTransportProbe.runDiscoveryForTesting(dependencies: dependencies) }
        defer { task.cancel(); entered.continuation.finish(); held.continuation.finish() }
        var iterator = entered.stream.makeAsyncIterator()
        let signal = await iterator.next()
        try #require(signal == true)
        task.cancel()
        let cancelledReport = await task.value
        #expect(cancelledReport.cancelled && cancelledReport.remotePairingDiscovery?.outcome == .cancelled)
        #expect(cancelledReport.remotePairingDiscovery?.eligibleEndpointCount == 5)
        #expect(cancelledReport.remotePairingDiscovery?.approvedEndpointCount == 4)
        #expect(cancelledReport.remotePairingDiscovery?.skippedEndpointCount == 1)
        #expect(cancelledReport.remotePairingDiscovery?.tcpConnectionAttemptsStarted == 1)
        #expect(cancelled.state().stopped && cancelled.state().destinations.isEmpty)
        noRenewal(boundedReport); noRenewal(exceededReport); noRenewal(changedReport)
        noRenewal(expiredReport); noRenewal(cancelledReport)
    }

    @Test func retainsSchemaOneReportCompatibility() throws {
        let old = Data("""
        {"schemaVersion":1,"startedAt":0,"finishedAt":1,"executionEnvironment":"simulator","attempts":[],
         "cancelled":false,"testTransportInjected":true,"tlsAttempted":false,"sessionStarted":false,
         "pairingAttempted":false,"accountAccessed":false,"signingAttempted":false,"installationAttempted":false,"renewalProven":false}
        """.utf8)
        let report = try JSONDecoder().decode(SelfRenewalTransportProbeReport.self, from: old)
        #expect(report.schemaVersion == 1 && report.remotePairingDiscovery == nil)
        let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(!encoded.contains("remotePairingDiscovery"))
        noRenewal(report)
        let previousSchemaTwo = Data("""
        {"schemaVersion":2,"startedAt":0,"finishedAt":1,"executionEnvironment":"device","attempts":[],
         "cancelled":false,"testTransportInjected":true,"tlsAttempted":false,"sessionStarted":false,
         "pairingAttempted":false,"accountAccessed":false,"signingAttempted":false,"installationAttempted":false,"renewalProven":false,
         "remotePairingDiscovery":{"discoveryStarted":true,"outcome":"limitExceeded","phase":"checkingOwnership",
          "elapsedMilliseconds":1,"discoveredServiceCount":2,"resolvedAddressCount":6,"rejectedAddressCount":1,
          "approvedEndpointCount":0,"tcpConnectionAttemptsStarted":0,"tcpAttempts":[],
          "tcpApplicationPayloadBytesSent":0,"serviceIdentityVerified":false}}
        """.utf8)
        let prior = try JSONDecoder().decode(SelfRenewalTransportProbeReport.self, from: previousSchemaTwo)
        let discovery = try #require(prior.remotePairingDiscovery)
        #expect(discovery.eligibleEndpointCount == nil && discovery.skippedEndpointCount == nil && discovery.endpointSelectionLimit == nil)
        let priorEncoded = String(decoding: try JSONEncoder().encode(prior), as: UTF8.self)
        for key in ["eligibleEndpointCount", "skippedEndpointCount", "endpointSelectionLimit"] {
            #expect(!priorEncoded.contains(key))
        }
        noRenewal(prior)
    }

    @Test func tcpAdapterConnectsAndClosesWithoutSendingPayload() async throws {
        let server = try DiscoveryTCPFixtureServer()
        do {
            let port = try await server.start()
            let local = endpoint(v4([127, 0, 0, 1]), port: port.rawValue, expiry: ProcessInfo.processInfo.systemUptime + 10)
            let result = await SelfRenewalTransportProbe.connectDiscoveredForTesting(endpoint: local, timeout: 2)
            #expect(result.outcome == .tcpConnected && result.addressCategory == .loopback)
            let count = try await server.receivedBytesUntilClose()
            #expect(count == 0)
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }

    private func v4(_ bytes: [UInt8], scope: UInt32 = 0) -> SelfRenewalNumericAddress {
        SelfRenewalNumericAddress(family: .ipv4, bytes: bytes, scopeID: scope)!
    }
    private func endpoint(_ address: SelfRenewalNumericAddress, port: UInt16 = 64_099, expiry: TimeInterval = 2_000) -> SelfRenewalDiscoveredEndpoint {
        SelfRenewalDiscoveredEndpoint(address: address, port: port, expiresAtUptime: expiry)
    }
    private func entry(_ address: SelfRenewalNumericAddress, index: UInt32 = 4, rawFlags: UInt32 = 1,
                       loopback: Bool = false, pointToPoint: Bool = false, eligible: Bool = true,
                       up: Bool = true, mask: [UInt8] = [255, 255, 255, 0]) -> SelfRenewalLocalInterfaceAddress {
        SelfRenewalLocalInterfaceAddress(address: address, interfaceIndex: index, rawFlags: rawFlags, isUp: up,
            isLoopback: loopback, isPointToPoint: pointToPoint, isEligibleInterface: eligible,
            ipv4Netmask: address.family == .ipv4 ? mask : nil, ipv4Broadcast: nil)
    }
    private func fixture(events: [SelfRenewalDiscoveryEvent], holdOpen: Bool = false) throws -> DiscoveryFixture {
        DiscoveryFixture(snapshot: try #require(SelfRenewalLocalAddressSnapshot(entries: [entry(v4([192, 168, 7, 23]))])),
                         events: events, holdOpen: holdOpen)
    }
    private func run(_ fixture: DiscoveryFixture) async -> SelfRenewalTransportProbeReport {
        await SelfRenewalTransportProbe.runDiscoveryForTesting(dependencies: fixture.dependencies())
    }
    private func noRenewal(_ report: SelfRenewalTransportProbeReport) {
        #expect(!report.tlsAttempted && !report.sessionStarted && !report.pairingAttempted)
        #expect(!report.accountAccessed && !report.signingAttempted && !report.installationAttempted && !report.renewalProven)
        if let discovery = report.remotePairingDiscovery {
            #expect(discovery.tcpApplicationPayloadBytesSent == 0 && !discovery.serviceIdentityVerified)
            #expect(discovery.approvedEndpointCount <= 4 && discovery.tcpConnectionAttemptsStarted <= 4)
            if let eligible = discovery.eligibleEndpointCount {
                #expect(eligible <= 32 && eligible >= discovery.approvedEndpointCount)
                #expect(discovery.skippedEndpointCount == eligible - discovery.approvedEndpointCount)
                #expect(discovery.endpointSelectionLimit == 4)
            } else {
                #expect(discovery.skippedEndpointCount == nil && discovery.endpointSelectionLimit == nil)
            }
        }
    }
}

/// Owned, bounded injected events; no Bonjour operation or credential input occurs here.
private final class DiscoveryFixture: @unchecked Sendable {
    struct State {
        var started = false
        var stopped = false
        var windowClosed = false
        var connectedAfterWindowClosed = false
        var destinations: [SelfRenewalDiscoveredEndpoint] = []
        var timeouts: [TimeInterval] = []
        var now: TimeInterval = 1_000
        var snapshotReads = 0
        var changeOnRevalidation = false
        var advanceOnRevalidation: TimeInterval = 0
        var connectOutcome = SelfRenewalDiscoveryOutcome.tcpConnected
        var changeAfterSnapshotRead = 1
        var stream: AsyncStream<SelfRenewalDiscoveryEvent>.Continuation?
        var startWaiter: CheckedContinuation<Void, Never>?
    }
    private let lock = NSLock()
    private var storage = State()
    private let original: SelfRenewalLocalAddressSnapshot
    private let scripted: [SelfRenewalDiscoveryEvent]
    private let holdOpen: Bool

    init(snapshot: SelfRenewalLocalAddressSnapshot, events: [SelfRenewalDiscoveryEvent], holdOpen: Bool) {
        original = snapshot; scripted = events; self.holdOpen = holdOpen
    }
    func state() -> State { lock.withLock { storage } }
    func configure(changeOnRevalidation: Bool = false, advanceOnRevalidation: TimeInterval = 0,
                   connectOutcome: SelfRenewalDiscoveryOutcome = .tcpConnected, changeAfterSnapshotRead: Int = 1) {
        lock.withLock {
            storage.changeOnRevalidation = changeOnRevalidation
            storage.advanceOnRevalidation = advanceOnRevalidation
            storage.connectOutcome = connectOutcome
            storage.changeAfterSnapshotRead = changeAfterSnapshotRead
        }
    }
    func dependencies() -> SelfRenewalDiscoveryDependencies {
        SelfRenewalDiscoveryDependencies(events: { self.start() }, stop: { self.stop() },
            snapshot: { self.snapshot() }, connect: { endpoint, category, timeout in self.connect(endpoint, category, timeout) },
            uptime: { self.state().now })
    }
    func waitForStart() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if storage.started { return true }
                storage.startWaiter = continuation
                return false
            }
            if ready { continuation.resume() }
        }
    }
    private func start() -> AsyncStream<SelfRenewalDiscoveryEvent> {
        AsyncStream(bufferingPolicy: .bufferingOldest(128)) { continuation in
            let waiter = lock.withLock {
                storage.started = true
                storage.stream = continuation
                let waiter = storage.startWaiter
                storage.startWaiter = nil
                return waiter
            }
            waiter?.resume()
            for event in scripted {
                if case .windowEnded = event { lock.withLock { storage.windowClosed = true } }
                continuation.yield(event)
            }
            if !holdOpen { continuation.finish() }
        }
    }
    private func stop() {
        let stream = lock.withLock {
            storage.stopped = true
            let value = storage.stream
            storage.stream = nil
            return value
        }
        stream?.finish()
    }
    private func snapshot() -> SelfRenewalLocalAddressSnapshot? {
        lock.withLock {
            storage.snapshotReads += 1
            if storage.snapshotReads > 1 {
                storage.now += storage.advanceOnRevalidation
                if storage.changeOnRevalidation && storage.snapshotReads > storage.changeAfterSnapshotRead {
                    return SelfRenewalLocalAddressSnapshot(entries: [])
                }
            }
            return original
        }
    }
    private func connect(_ endpoint: SelfRenewalDiscoveredEndpoint, _ category: SelfRenewalDiscoveryAddressCategory,
                         _ timeout: TimeInterval) -> SelfRenewalDiscoveryTCPAttempt {
        let outcome = lock.withLock {
            storage.connectedAfterWindowClosed = storage.windowClosed && storage.stopped
            storage.destinations.append(endpoint)
            storage.timeouts.append(timeout)
            return storage.connectOutcome
        }
        return SelfRenewalDiscoveryTCPAttempt(family: endpoint.address.family, addressCategory: category,
            outcome: outcome, elapsedMilliseconds: 0,
            networkError: outcome == .transportFailed ? SelfRenewalTransportNetworkError(.posix(.ECONNREFUSED)) : nil,
            lastWaitingError: nil)
    }
}

private actor DiscoveryTCPFixtureServer {
    private let listener: NWListener
    private var connection: NWConnection?
    private var startWaiter: CheckedContinuation<NWEndpoint.Port, Error>?
    private var closeWaiter: CheckedContinuation<Int, Error>?
    private var closedBytes: Int?
    private var received = 0
    private var expired = false
    private var deadline: Task<Void, Never>?

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters, on: .any)
    }
    func start() async throws -> NWEndpoint.Port {
        try await withCheckedThrowingContinuation { continuation in
            startWaiter = continuation
            listener.stateUpdateHandler = { [weak self] state in Task { await self?.changed(state) } }
            listener.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection) } }
            // Bound owned fixture startup and EOF observation, independently of the diagnostic.
            deadline = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { return }
                await self?.expire()
            }
            listener.start(queue: .global(qos: .utility))
        }
    }
    func receivedBytesUntilClose() async throws -> Int {
        if let closedBytes { return closedBytes }
        if expired { throw CocoaError(.fileReadUnknown) }
        return try await withCheckedThrowingContinuation { closeWaiter = $0 }
    }
    func stop() {
        deadline?.cancel(); deadline = nil
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        connection?.cancel(); connection = nil
        startWaiter?.resume(throwing: CancellationError()); startWaiter = nil
        closeWaiter?.resume(throwing: CancellationError()); closeWaiter = nil
    }
    private func changed(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener.port { startWaiter?.resume(returning: port); startWaiter = nil }
        case .failed(let error):
            startWaiter?.resume(throwing: error); startWaiter = nil
            closeWaiter?.resume(throwing: error); closeWaiter = nil
        default: break
        }
    }
    private func accept(_ connection: NWConnection) {
        self.connection = connection
        connection.start(queue: .global(qos: .utility))
        receive()
    }
    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] data, _, complete, error in
            Task { await self?.read(data: data, complete: complete, failed: error != nil) }
        }
    }
    private func read(data: Data?, complete: Bool, failed: Bool) {
        received += data?.count ?? 0
        if complete || failed || received > 0 {
            closedBytes = received
            closeWaiter?.resume(returning: received); closeWaiter = nil
        } else { receive() }
    }
    private func expire() {
        expired = true
        startWaiter?.resume(throwing: CocoaError(.fileReadUnknown)); startWaiter = nil
        closeWaiter?.resume(throwing: CocoaError(.fileReadUnknown)); closeWaiter = nil
    }
}
