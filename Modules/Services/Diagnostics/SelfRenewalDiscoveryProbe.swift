import Foundation
@preconcurrency import Network

/// The driver is single-use. Tests replace SDK adapters without browsing a network.
struct SelfRenewalDiscoveryDependencies: Sendable {
    let events: @Sendable () -> AsyncStream<SelfRenewalDiscoveryEvent>
    let stop: @Sendable () -> Void
    let snapshot: @Sendable () async -> SelfRenewalLocalAddressSnapshot?
    let connect: @Sendable (SelfRenewalDiscoveredEndpoint, SelfRenewalDiscoveryAddressCategory, TimeInterval) async -> SelfRenewalDiscoveryTCPAttempt
    let uptime: @Sendable () -> TimeInterval
}

extension SelfRenewalTransportProbe {
    /// Only dynamic discovery is run here. The previous fixed-port experiment is separate.
    func runDiscovery() async -> SelfRenewalTransportProbeReport {
        let driver = SelfRenewalDiscoveryNativeDriver()
        let dependencies = SelfRenewalDiscoveryDependencies(
            events: { driver.start() }, stop: { driver.cancel() },
            snapshot: { await SelfRenewalDiscoveryNativeDriver.interfaceSnapshot() },
            connect: { endpoint, category, timeout in
                await SelfRenewalDiscoveredTCPAttempt(endpoint: endpoint, category: category, timeout: timeout).run()
            },
            uptime: { ProcessInfo.processInfo.systemUptime }
        )
        return await Self.discoveryReport(dependencies: dependencies, timeout: 8, injected: false)
    }

    #if DEBUG
    static func runDiscoveryForTesting(
        dependencies: SelfRenewalDiscoveryDependencies, timeout: TimeInterval = 8
    ) async -> SelfRenewalTransportProbeReport {
        await discoveryReport(dependencies: dependencies, timeout: timeout, injected: true)
    }

    static func connectDiscoveredForTesting(
        endpoint: SelfRenewalDiscoveredEndpoint, timeout: TimeInterval
    ) async -> SelfRenewalDiscoveryTCPAttempt {
        await SelfRenewalDiscoveredTCPAttempt(endpoint: endpoint, category: .loopback, timeout: timeout).run()
    }

    static func acceptsNativeAddressForTesting(_ address: SelfRenewalNumericAddress) -> Bool {
        SelfRenewalDiscoveredTCPAttempt.checkedHost(address) != nil
    }
    #endif

    private static func discoveryReport(
        dependencies: SelfRenewalDiscoveryDependencies, timeout: TimeInterval, injected: Bool
    ) async -> SelfRenewalTransportProbeReport {
        let startedAt = Date()
        let result = await SourcePerfTrace.spanAsync(
            "diagnostic.selfRenewalDiscovery", "main=\(Thread.isMainThread) servicesMax=8 addressCallbacksMax=32 selectedMax=4"
        ) {
            await SelfRenewalDiscoveryOperation(dependencies: dependencies, timeout: timeout).run()
        }
        #if targetEnvironment(simulator)
        let environment = "simulator"
        #else
        let environment = "device"
        #endif
        return SelfRenewalTransportProbeReport(
            schemaVersion: 2, startedAt: startedAt, finishedAt: Date(), executionEnvironment: environment,
            attempts: [], cancelled: result.outcome == .cancelled, testTransportInjected: injected,
            tlsAttempted: false, sessionStarted: false, pairingAttempted: false, accountAccessed: false,
            signingAttempted: false, installationAttempted: false, renewalProven: false,
            remotePairingDiscovery: result
        )
    }
}

private actor SelfRenewalDiscoveryOperation {
    private let dependencies: SelfRenewalDiscoveryDependencies
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<SelfRenewalRemotePairingDiscoveryReport, Never>?
    private var worker: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var finished = false
    private var cancellationRequested = false
    private var started: TimeInterval = 0
    private var discoveryStarted = false
    private var phase = SelfRenewalDiscoveryPhase.snapshotting
    private var services = Set<UUID>()
    private var liveServices = Set<UUID>()
    private var candidates: [UUID: [SelfRenewalDiscoveredEndpoint]] = [:]
    private var resolved = 0
    private var rejected = 0
    private var approved = 0
    private var eligible: Int?
    private var skipped: Int?
    private var selectionLimit: Int?
    private var attemptsStarted = 0
    private var attempts: [SelfRenewalDiscoveryTCPAttempt] = []
    private var networkError: SelfRenewalTransportNetworkError?
    private var waitingError: SelfRenewalTransportNetworkError?

    init(dependencies: SelfRenewalDiscoveryDependencies, timeout: TimeInterval) {
        self.dependencies = dependencies
        self.timeout = timeout.isFinite ? max(0.01, min(timeout, 8)) : 8
    }

    func run() async -> SelfRenewalRemotePairingDiscoveryReport {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                self.started = dependencies.uptime()
                if cancellationRequested || Task.isCancelled { finish(.cancelled); return }
                guard started.isFinite, started >= 0 else { finish(.internalError); return }
                // The overall diagnostic deadline includes discovery, resolution and TCP.
                deadline = Task { [weak self] in
                    guard let timeout = self?.timeout else { return }
                    do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
                    catch { return }
                    await self?.finish(.timedOut)
                }
                worker = Task { [weak self] in await self?.perform() }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    private func cancel() {
        cancellationRequested = true
        if continuation != nil { finish(.cancelled) }
    }

    private func perform() async {
        guard let initial = await dependencies.snapshot() else {
            if !finished { finish(.internalError) }
            return
        }
        guard !finished, !Task.isCancelled else { return }
        phase = .discovering
        discoveryStarted = true
        var endedNormally = false
        for await event in dependencies.events() {
            guard !finished, !Task.isCancelled else { return }
            guard !endedNormally else { finish(.discoveryChanged); return }
            switch event {
            case .ready: break
            case .found(let id):
                guard !services.contains(id) else { continue }
                services.insert(id)
                liveServices.insert(id)
                guard services.count <= 8 else { finish(.limitExceeded); return }
                phase = .resolving
            case .resolved(let id, let endpoint):
                // A late callback cannot bring back a removed service generation.
                guard liveServices.contains(id) else { continue }
                resolved += 1
                guard resolved <= 32 else { finish(.limitExceeded); return }
                candidates[id]?.removeAll { $0.address == endpoint.address && $0.port == endpoint.port }
                let now = dependencies.uptime()
                guard now.isFinite, now >= started, endpoint.expiresAtUptime.isFinite,
                      endpoint.expiresAtUptime > now, initial.category(for: endpoint) != nil else {
                    rejected += 1
                    continue
                }
                var current = candidates[id] ?? []
                current.removeAll { $0.address == endpoint.address && $0.port == endpoint.port }
                current.append(endpoint)
                candidates[id] = current
            case .addressRemoved(let id, let address):
                candidates[id]?.removeAll { $0.address == address }
            case .removed(let id):
                liveServices.remove(id)
                candidates.removeValue(forKey: id)
            case .waiting(let error): waitingError = error
            case .resolutionFailed(let error): networkError = error
            case .failed(let error): networkError = error; finish(.discoveryUnavailable); return
            case .limitExceeded: finish(.limitExceeded); return
            case .invalidated: finish(.discoveryChanged); return
            case .windowEnded:
                // The producer cancels its SDK objects before this terminal event.
                endedNormally = true
            }
        }
        guard !finished, !Task.isCancelled else { return }
        dependencies.stop()
        // An overflow or unexpected producer termination must never authorize TCP.
        guard endedNormally else { finish(.discoveryUnavailable); return }
        phase = .checkingOwnership
        var unique: [SelfRenewalDiscoveredEndpoint] = []
        let now = dependencies.uptime()
        guard now.isFinite, now >= started else { finish(.internalError); return }
        for endpoints in candidates.values {
            for endpoint in endpoints {
                guard endpoint.expiresAtUptime > now else { rejected += 1; continue }
                if let index = unique.firstIndex(where: { $0.address == endpoint.address && $0.port == endpoint.port }) {
                    // The same destination may have several service records: keep the shorter TTL.
                    if endpoint.expiresAtUptime < unique[index].expiresAtUptime { unique[index] = endpoint }
                } else {
                    unique.append(endpoint)
                }
            }
        }
        // This does not relax the discovery budget: all callbacks must have fit
        // its 32-address cap and the producer must have closed normally above.
        guard unique.count <= 32 else { finish(.limitExceeded); return }
        // A stable numeric ordering makes bounded attempts reproducible without exporting destinations.
        unique.sort {
            if $0.address.family != $1.address.family { return $0.address.family == .ipv4 }
            if $0.address.bytes != $1.address.bytes { return $0.address.bytes.lexicographicallyPrecedes($1.address.bytes) }
            if $0.address.scopeID != $1.address.scopeID { return $0.address.scopeID < $1.address.scopeID }
            return $0.port < $1.port
        }
        // More than four eligible destinations is selection, not an incomplete
        // discovery. Preserve the existing order and authorize at most four TCP
        // attempts; never refill this prefix after expiry or a topology change.
        let selected = Array(unique.prefix(4))
        eligible = unique.count
        approved = selected.count
        skipped = unique.count - selected.count
        selectionLimit = 4
        guard !selected.isEmpty else {
            if networkError != nil { finish(.resolutionFailed) }
            else if resolved > 0 { finish(.noLocalCandidate) }
            else if waitingError != nil { finish(.discoveryUnavailable) }
            else { finish(.discoveryTimedOut) }
            return
        }
        for endpoint in selected {
            phase = .checkingOwnership
            guard let current = await dependencies.snapshot() else {
                if !finished { finish(.internalError) }
                return
            }
            guard !finished, !Task.isCancelled else { return }
            guard current == initial else { finish(.interfaceChanged); return }
            let now = dependencies.uptime()
            guard now.isFinite, now >= started else { finish(.internalError); return }
            let remaining = timeout - (now - started)
            guard remaining > 0 else { finish(.timedOut); return }
            guard endpoint.expiresAtUptime > now, let category = current.category(for: endpoint) else {
                rejected += 1
                continue
            }
            phase = .connecting
            attemptsStarted += 1
            let attempt = await dependencies.connect(endpoint, category, min(2, remaining, endpoint.expiresAtUptime - now))
            guard !finished, !Task.isCancelled else { return }
            attempts.append(attempt)
            if attempt.outcome == .tcpConnected { phase = .completed; finish(.tcpConnected); return }
            if attempt.outcome == .cancelled { finish(.cancelled); return }
        }
        if !finished { finish(attempts.isEmpty ? .noLocalCandidate : .transportFailed) }
    }

    private func finish(_ outcome: SelfRenewalDiscoveryOutcome) {
        guard !finished, let continuation else { return }
        finished = true
        self.continuation = nil
        worker?.cancel(); worker = nil
        deadline?.cancel(); deadline = nil
        dependencies.stop()
        let elapsed = dependencies.uptime() - started
        continuation.resume(returning: SelfRenewalRemotePairingDiscoveryReport(
            discoveryStarted: discoveryStarted, outcome: outcome, phase: phase,
            elapsedMilliseconds: elapsed.isFinite ? max(0, elapsed * 1_000) : 0,
            discoveredServiceCount: services.count, resolvedAddressCount: resolved,
            rejectedAddressCount: rejected, approvedEndpointCount: approved,
            eligibleEndpointCount: eligible, skippedEndpointCount: skipped, endpointSelectionLimit: selectionLimit,
            tcpConnectionAttemptsStarted: attemptsStarted, tcpAttempts: attempts,
            networkError: networkError, lastWaitingError: waitingError,
            tcpApplicationPayloadBytesSent: 0, serviceIdentityVerified: false
        ))
    }
}

/// A separate TCP-only state machine. It never calls send/receive or negotiates TLS.
private actor SelfRenewalDiscoveredTCPAttempt {
    private let endpoint: SelfRenewalDiscoveredEndpoint
    private let category: SelfRenewalDiscoveryAddressCategory
    private let timeout: TimeInterval
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<SelfRenewalDiscoveryTCPAttempt, Never>?
    private var deadline: Task<Void, Never>?
    private var cancelled = false
    private var finished = false
    private var started = SourcePerfTrace.now
    private var waitingError: SelfRenewalTransportNetworkError?

    init(endpoint: SelfRenewalDiscoveredEndpoint, category: SelfRenewalDiscoveryAddressCategory, timeout: TimeInterval) {
        self.endpoint = endpoint
        self.category = category
        self.timeout = max(0.001, min(timeout, 2))
    }

    func run() async -> SelfRenewalDiscoveryTCPAttempt {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                self.started = SourcePerfTrace.now
                if cancelled || Task.isCancelled { finish(.cancelled); return }
                guard endpoint.address.isEligibleUnicast, endpoint.expiresAtUptime > started,
                      let port = NWEndpoint.Port(rawValue: endpoint.port) else { finish(.internalError); return }
                let parameters = NWParameters.tcp
                parameters.includePeerToPeer = false
                guard let host = Self.checkedHost(endpoint.address) else { finish(.internalError); return }
                let connection = NWConnection(host: host, port: port, using: parameters)
                self.connection = connection
                connection.stateUpdateHandler = { [weak self] state in Task { await self?.changed(state) } }
                // This is the real TCP deadline, never a UI settling delay.
                deadline = Task { [weak self] in
                    guard let timeout = self?.timeout else { return }
                    do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
                    catch { return }
                    await self?.finish(.timedOut)
                }
                connection.start(queue: .global(qos: .utility))
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    private func cancel() {
        cancelled = true
        if continuation != nil { finish(.cancelled) }
    }

    static func checkedHost(_ address: SelfRenewalNumericAddress) -> NWEndpoint.Host? {
        let host = NWEndpoint.Host(address.numericHost)
        // Prove an exact SDK round trip, including the authoritative link-local scope.
        switch host {
        case .ipv4(let value):
            guard address.family == .ipv4, Array(value.rawValue) == address.bytes else { return nil }
        case .ipv6(let value):
            guard address.family == .ipv6, Array(value.rawValue) == address.bytes else { return nil }
            if address.isLinkLocal, value.interface?.index != Int(address.scopeID) { return nil }
        default: return nil
        }
        return host
    }

    private func changed(_ state: NWConnection.State) {
        guard !finished else { return }
        switch state {
        case .ready:
            finish(SourcePerfTrace.now < endpoint.expiresAtUptime ? .tcpConnected : .timedOut)
        case .waiting(let error): waitingError = SelfRenewalTransportNetworkError(error)
        case .failed(let error): finish(.transportFailed, error: error)
        case .cancelled: finish(.cancelled)
        default: break
        }
    }

    private func finish(_ outcome: SelfRenewalDiscoveryOutcome, error: NWError? = nil) {
        guard !finished, let continuation else { return }
        finished = true
        self.continuation = nil
        deadline?.cancel(); deadline = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel(); connection = nil
        continuation.resume(returning: SelfRenewalDiscoveryTCPAttempt(
            family: endpoint.address.family, addressCategory: category, outcome: outcome,
            elapsedMilliseconds: max(0, (SourcePerfTrace.now - started) * 1_000),
            networkError: error.map(SelfRenewalTransportNetworkError.init), lastWaitingError: waitingError
        ))
    }
}
