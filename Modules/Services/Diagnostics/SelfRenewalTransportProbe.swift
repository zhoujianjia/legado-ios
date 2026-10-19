import Foundation
@preconcurrency import Network

enum SelfRenewalLoopbackAddress: String, Codable, Sendable, CaseIterable {
    case ipv4 = "127.0.0.1"
    case ipv6 = "::1"
}

enum SelfRenewalTransportOutcome: String, Codable, Sendable {
    case lockdownConfirmed, protocolError, unexpectedService, invalidResponse
    case transportFailed, peerClosed, timedOut, cancelled, internalError
}

enum SelfRenewalTransportPhase: String, Codable, Sendable {
    case connecting, sendingQuery, receivingHeader, receivingPayload, completed
}

struct SelfRenewalTransportNetworkError: Codable, Sendable {
    let domain: String
    let code: Int

    init(_ error: NWError) {
        switch error {
        case .posix(let code): domain = "posix"; self.code = Int(code.rawValue)
        case .dns(let code): domain = "dns"; self.code = Int(code)
        case .tls(let code): domain = "tls"; self.code = Int(code)
        @unknown default: domain = "unknown"; code = 0
        }
    }
}

struct SelfRenewalTransportAttempt: Codable, Sendable {
    let address: SelfRenewalLoopbackAddress
    let port: UInt16
    let outcome: SelfRenewalTransportOutcome
    let phase: SelfRenewalTransportPhase
    let tcpConnected: Bool
    let lockdownConfirmed: Bool
    let elapsedMilliseconds: Double
    let receivedByteCount: Int
    let networkError: SelfRenewalTransportNetworkError?
    let lastWaitingError: SelfRenewalTransportNetworkError?
    let protocolError: String?
    /// Only the exact expected service constant may be exported, never an arbitrary reply.
    let lockdownType: String?

}

struct SelfRenewalTransportProbeReport: Codable, Sendable {
    let schemaVersion: Int
    let startedAt: Date
    let finishedAt: Date
    let executionEnvironment: String
    let attempts: [SelfRenewalTransportAttempt]
    let cancelled: Bool
    let testTransportInjected: Bool
    let tlsAttempted: Bool
    let sessionStarted: Bool
    let pairingAttempted: Bool
    let accountAccessed: Bool
    let signingAttempted: Bool
    let installationAttempted: Bool
    let renewalProven: Bool
    let remotePairingDiscovery: SelfRenewalRemotePairingDiscoveryReport?
}

/// Read-only endpoint evidence. No host/port input, credentials, pairing or installation APIs.
struct SelfRenewalTransportProbe: Sendable {
    static let port: UInt16 = 62078
    static let maximumResponseBytes = 16 * 1024
    static let timeoutSeconds: TimeInterval = 3

    func run() async -> SelfRenewalTransportProbeReport {
        await Self.run(timeout: Self.timeoutSeconds, testTransportInjected: false) { address in
            NWConnection(host: NWEndpoint.Host(address.rawValue), port: NWEndpoint.Port(rawValue: Self.port)!, using: .tcp)
        }
    }

    #if DEBUG
    /// Unit tests connect only to listeners they own, never to the device's real service.
    static func runForTesting(
        timeout: TimeInterval,
        connectionFactory: @escaping @Sendable (SelfRenewalLoopbackAddress) -> NWConnection
    ) async -> SelfRenewalTransportProbeReport {
        await run(timeout: timeout, testTransportInjected: true, connectionFactory: connectionFactory)
    }
    #endif

    private static func run(
        timeout: TimeInterval,
        testTransportInjected: Bool,
        connectionFactory: @escaping @Sendable (SelfRenewalLoopbackAddress) -> NWConnection
    ) async -> SelfRenewalTransportProbeReport {
        let startedAt = Date()
        let attempts = await SourcePerfTrace.spanAsync(
            "diagnostic.selfRenewalTransport", "main=\(Thread.isMainThread) endpoints=2"
        ) {
            var results: [SelfRenewalTransportAttempt] = []
            for address in SelfRenewalLoopbackAddress.allCases {
                let attempt = SelfRenewalQueryTypeAttempt(
                    address: address, timeout: timeout, connection: connectionFactory(address)
                )
                results.append(await attempt.run())
            }
            return results
        }
        #if targetEnvironment(simulator)
        let environment = "simulator"
        #else
        let environment = "device"
        #endif
        return SelfRenewalTransportProbeReport(
            schemaVersion: 1, startedAt: startedAt, finishedAt: Date(), executionEnvironment: environment,
            attempts: attempts, cancelled: Task.isCancelled || attempts.contains { $0.outcome == .cancelled },
            testTransportInjected: testTransportInjected, tlsAttempted: false, sessionStarted: false,
            pairingAttempted: false, accountAccessed: false, signingAttempted: false,
            installationAttempted: false, renewalProven: false, remotePairingDiscovery: nil
        )
    }
}

private actor SelfRenewalQueryTypeAttempt {
    private let address: SelfRenewalLoopbackAddress
    private let timeout: TimeInterval
    private let connection: NWConnection
    private var continuation: CheckedContinuation<SelfRenewalTransportAttempt, Never>?
    private var deadline: Task<Void, Never>?
    private var cancellationRequested = false
    private var finished = false
    private var started = SourcePerfTrace.now
    private var phase = SelfRenewalTransportPhase.connecting
    private var tcpConnected = false
    private var querySent = false
    private var waitingError: SelfRenewalTransportNetworkError?
    private var data = Data()
    private var responseLength: Int?
    private var receivedBytes = 0

    init(address: SelfRenewalLoopbackAddress, timeout: TimeInterval, connection: NWConnection) {
        self.address = address
        self.timeout = max(0.01, min(timeout, SelfRenewalTransportProbe.timeoutSeconds))
        self.connection = connection
    }

    func run() async -> SelfRenewalTransportAttempt {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                self.started = SourcePerfTrace.now
                if cancellationRequested || Task.isCancelled {
                    finish(.cancelled)
                    return
                }
                connection.stateUpdateHandler = { [weak self] state in
                    Task { await self?.stateChanged(state) }
                }
                // This is the attempt's real wall-clock deadline, including a waiting path
                // and an established peer that never replies. It is not a settling delay.
                let nanoseconds = UInt64(timeout * 1_000_000_000)
                deadline = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: nanoseconds) }
                    catch { return }
                    await self?.deadlineExpired()
                }
                connection.start(queue: .global(qos: .utility))
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    private func cancel() {
        cancellationRequested = true
        if continuation != nil { finish(.cancelled) }
    }

    private func deadlineExpired() { finish(.timedOut) }

    private func stateChanged(_ state: NWConnection.State) {
        guard !finished else { return }
        switch state {
        case .ready:
            tcpConnected = true
            guard !querySent else { return }
            querySent = true
            phase = .sendingQuery
            do {
                let payload = try PropertyListSerialization.data(
                    fromPropertyList: ["Request": "QueryType", "Label": "LocalBookshelfTransportProbe"],
                    format: .xml, options: 0
                )
                var length = UInt32(payload.count).bigEndian
                let frame = Data(bytes: &length, count: 4) + payload
                connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                    Task { await self?.queryDidSend(error: error) }
                })
            } catch {
                // Only a fixed two-string dictionary is serialized; never log reply data.
                AppLogger.error("Transport probe could not encode its fixed QueryType request")
                finish(.internalError)
            }
        case .waiting(let error):
            // Waiting is not a final failure or proof of a denied permission. Keep the
            // bounded deadline and record only the numeric error, allowing a path to recover.
            waitingError = SelfRenewalTransportNetworkError(error)
        case .failed(let error): finish(.transportFailed, networkError: error)
        case .cancelled: finish(.cancelled)
        default: break
        }
    }

    private func queryDidSend(error: NWError?) {
        guard !finished else { return }
        if let error { finish(.transportFailed, networkError: error); return }
        phase = .receivingHeader
        receive()
    }

    private func receive() {
        let target = responseLength ?? 4
        connection.receive(minimumIncompleteLength: 1, maximumLength: target - data.count) { [weak self] bytes, _, complete, error in
            Task { await self?.received(bytes, complete: complete, error: error) }
        }
    }

    private func received(_ bytes: Data?, complete: Bool, error: NWError?) {
        guard !finished else { return }
        if let error { finish(.transportFailed, networkError: error); return }
        if let bytes { data.append(bytes); receivedBytes += bytes.count }
        let target = responseLength ?? 4
        if data.count == target {
            if responseLength == nil {
                let length = data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard length > 0, length <= SelfRenewalTransportProbe.maximumResponseBytes else {
                    finish(.invalidResponse); return
                }
                responseLength = Int(length)
                data.removeAll(keepingCapacity: true)
                phase = .receivingPayload
            } else {
                inspectPayload()
                return
            }
        }
        if complete || bytes?.isEmpty != false { finish(.peerClosed); return }
        receive()
    }

    private func inspectPayload() {
        SourcePerfTrace.span("diagnostic.selfRenewalTransport.parse", "main=\(Thread.isMainThread) bytes=\(data.count)") {
            do {
                let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                guard let response = value as? [String: Any], response["Request"] as? String == "QueryType" else {
                    finish(.invalidResponse); return
                }
                if let error = response["Error"] {
                    guard let text = error as? String else { finish(.invalidResponse); return }
                    let known: Set<String> = [
                        "InvalidResponse", "MissingHostID", "InvalidHostID", "MissingPairRecord", "InvalidPairRecord",
                        "PasswordProtected", "UserDeniedPairing", "PairingDialogResponsePending",
                        "PairingProhibitedOverThisConnection", "ServiceProhibited"
                    ]
                    finish(.protocolError, protocolError: known.contains(text) ? text : "unrecognized_error")
                } else if response["Type"] as? String == "com.apple.mobile.lockdown" {
                    finish(.lockdownConfirmed, lockdownType: "com.apple.mobile.lockdown")
                } else {
                    finish(response["Type"] is String ? .unexpectedService : .invalidResponse)
                }
            } catch {
                // Parser errors can quote the input. Export only the normalized outcome.
                finish(.invalidResponse)
            }
        }
    }

    private func finish(
        _ outcome: SelfRenewalTransportOutcome, networkError: NWError? = nil,
        protocolError: String? = nil, lockdownType: String? = nil
    ) {
        guard !finished, let continuation else { return }
        finished = true
        let result = SelfRenewalTransportAttempt(
            address: address, port: SelfRenewalTransportProbe.port, outcome: outcome,
            phase: outcome == .lockdownConfirmed ? .completed : phase, tcpConnected: tcpConnected,
            lockdownConfirmed: outcome == .lockdownConfirmed,
            elapsedMilliseconds: max(0, (SourcePerfTrace.now - started) * 1000), receivedByteCount: receivedBytes,
            networkError: networkError.map(SelfRenewalTransportNetworkError.init), lastWaitingError: waitingError,
            protocolError: protocolError, lockdownType: lockdownType
        )
        self.continuation = nil
        deadline?.cancel()
        deadline = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        data.removeAll()
        continuation.resume(returning: result)
    }
}
