import Foundation
@preconcurrency import Network
import Testing
@testable import yuedu_app

@Suite("Read-only self-renewal transport probe", .serialized)
struct SelfRenewalTransportProbeTests {
    @Test("QueryType confirms only its exact service and excludes all unrelated response data")
    func confirmsQueryTypeWithoutExportingPrivateFields() async throws {
        let secret = "synthetic-private-value-never-export"
        let payload = try plist([
            "Request": "QueryType", "Type": "com.apple.mobile.lockdown",
            "UniqueDeviceID": secret, "PairRecord": ["HostPrivateKey": secret]
        ])
        let frame = framed(payload)
        let pieces = [Data(frame.prefix(1)), Data(frame.dropFirst().prefix(2)), Data(frame.dropFirst(3))]
        try await withServer(.reply(pieces)) { server, port in
            let report = await probe(port)
            #expect(report.attempts.map(\.address) == [.ipv4, .ipv6])
            #expect(report.attempts.allSatisfy { $0.port == 62078 && $0.tcpConnected && $0.lockdownConfirmed })
            #expect(report.attempts.allSatisfy { $0.outcome == .lockdownConfirmed && $0.phase == .completed })
            #expect(report.attempts.allSatisfy { $0.receivedByteCount == frame.count })
            let requests = await server.requests()
            #expect(requests.count == 2)
            #expect(requests.allSatisfy { Set($0.keys) == ["Request", "Label"] && $0["Request"] == "QueryType" })
            let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
            #expect(!json.contains(secret) && !json.contains("HostPrivateKey") && !json.contains("UniqueDeviceID"))
            #expect(report.testTransportInjected)
            expectNoRenewalOperations(report)
        }
    }

    @Test("binary plist responses use the same bounded QueryType contract")
    func acceptsBinaryPropertyListResponse() async throws {
        let payload = try plist(["Request": "QueryType", "Type": "com.apple.mobile.lockdown"], format: .binary)
        try await withServer(.reply([framed(payload)])) { _, port in
            let report = await probe(port)
            #expect(report.attempts.allSatisfy { $0.lockdownConfirmed })
            expectNoRenewalOperations(report)
        }
    }

    @Test("an established TCP peer without a response reaches its deadline without claiming lockdown")
    func tcpConnectionAloneIsNotServiceSuccess() async throws {
        try await withServer(.stall) { server, port in
            let report = await probe(port, timeout: 1)
            #expect(report.attempts.allSatisfy { $0.tcpConnected && $0.outcome == .timedOut })
            #expect(report.attempts.allSatisfy { !$0.lockdownConfirmed && $0.lockdownType == nil })
            #expect(await server.requests().count == 2)
            expectNoRenewalOperations(report)
        }
    }

    @Test("protocol errors and unexpected service types are normalized without leaking arbitrary strings")
    func normalizesErrorsAndRejectsWrongService() async throws {
        let secret = "synthetic-private-error-and-service"
        let cases: [([String: Any], SelfRenewalTransportOutcome, String?)] = [
            (["Request": "QueryType", "Error": "MissingPairRecord"], .protocolError, "MissingPairRecord"),
            (["Request": "QueryType", "Error": secret, "Type": "com.apple.mobile.lockdown"], .protocolError, "unrecognized_error"),
            (["Request": "QueryType", "Type": secret], .unexpectedService, nil),
            (["Request": "OtherRequest", "Type": "com.apple.mobile.lockdown"], .invalidResponse, nil),
        ]
        for (response, outcome, error) in cases {
            try await withServer(.reply([framed(try plist(response))])) { _, port in
                let report = await probe(port)
                #expect(report.attempts.allSatisfy { $0.outcome == outcome && $0.protocolError == error })
                #expect(report.attempts.allSatisfy { !$0.lockdownConfirmed && $0.lockdownType == nil })
                let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
                #expect(!json.contains(secret))
                expectNoRenewalOperations(report)
            }
        }
    }

    @Test("zero and oversized length prefixes are rejected before receiving or allocating a payload")
    func rejectsInvalidFrameLengths() async throws {
        for length in [UInt32(0), UInt32(SelfRenewalTransportProbe.maximumResponseBytes + 1)] {
            try await withServer(.reply([header(length)])) { _, port in
                let report = await probe(port)
                #expect(report.attempts.allSatisfy { $0.outcome == .invalidResponse && $0.receivedByteCount == 4 })
                #expect(report.attempts.allSatisfy { $0.phase == .receivingHeader && !$0.lockdownConfirmed })
            }
        }
    }

    @Test("malformed and truncated frames finish without accepting a service")
    func rejectsMalformedAndTruncatedResponses() async throws {
        for (bytes, outcome) in [
            (framed(Data("not a property list".utf8)), SelfRenewalTransportOutcome.invalidResponse),
            (header(20) + Data("short".utf8), SelfRenewalTransportOutcome.peerClosed),
        ] {
            try await withServer(.reply([bytes])) { _, port in
                let report = await probe(port)
                #expect(report.attempts.allSatisfy { $0.outcome == outcome && !$0.lockdownConfirmed })
            }
        }
    }

    @Test("cancellation closes the pending attempt and never starts a subsequent endpoint")
    func cancellationAndPreCancellationFinishOnce() async throws {
        try await withServer(.stall) { server, port in
            let task = Task { await probe(port) }
            try await server.waitForRequest()
            task.cancel()
            let report = await task.value
            #expect(report.cancelled)
            #expect(report.attempts.count == 2)
            #expect(report.attempts.allSatisfy { $0.outcome == .cancelled })
            #expect(report.attempts[0].tcpConnected && !report.attempts[1].tcpConnected)
            #expect(await server.requests().count == 1)
            expectNoRenewalOperations(report)

            let preCancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return await probe(port)
            }
            let second = await preCancelled.value
            #expect(second.cancelled && second.attempts.allSatisfy { $0.outcome == .cancelled && !$0.tcpConnected })
            #expect(await server.requests().count == 1)
        }
    }

    @Test("a refused owned fixture port reports numeric network evidence without guessing pairing or TLS")
    func recordsNetworkFailureWithoutCredentialClaims() async throws {
        let server = try QueryTypeProbeTestServer(reply: .stall)
        let port = try await server.start()
        await server.stop()
        let report = await probe(port, timeout: 0.5)
        #expect(report.attempts.allSatisfy { !$0.tcpConnected && !$0.lockdownConfirmed })
        #expect(report.attempts.allSatisfy { $0.outcome == .transportFailed || $0.outcome == .timedOut })
        #expect(report.attempts.allSatisfy { ($0.networkError ?? $0.lastWaitingError)?.domain == "posix" })
        #expect(report.attempts.allSatisfy { $0.protocolError == nil })
        expectNoRenewalOperations(report)
    }

    private func expectNoRenewalOperations(_ report: SelfRenewalTransportProbeReport) {
        #expect(!report.tlsAttempted && !report.sessionStarted && !report.pairingAttempted)
        #expect(!report.accountAccessed && !report.signingAttempted && !report.installationAttempted && !report.renewalProven)
    }

    private func probe(_ port: NWEndpoint.Port, timeout: TimeInterval = 2) async -> SelfRenewalTransportProbeReport {
        await SelfRenewalTransportProbe.runForTesting(timeout: timeout) { _ in
            NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        }
    }

    private func plist(_ value: [String: Any], format: PropertyListSerialization.PropertyListFormat = .xml) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: format, options: 0)
    }

    private func header(_ length: UInt32) -> Data {
        var length = length.bigEndian
        return Data(bytes: &length, count: 4)
    }

    private func framed(_ payload: Data) -> Data { header(UInt32(payload.count)) + payload }

    private func withServer(
        _ reply: QueryTypeProbeTestServer.Reply,
        body: (QueryTypeProbeTestServer, NWEndpoint.Port) async throws -> Void
    ) async throws {
        let server = try QueryTypeProbeTestServer(reply: reply)
        do {
            let port = try await server.start()
            try await body(server, port)
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }
}

/// Each fixture binds only its own IPv4 loopback listener on an OS-assigned port.
/// It neither probes 62078 nor uses another device/service or any pairing material.
private actor QueryTypeProbeTestServer {
    enum Reply: Sendable { case reply([Data]), stall }
    private let listener: NWListener
    private let reply: Reply
    private var connections: [NWConnection] = []
    private var observed: [[String: String]] = []
    private var startWaiter: CheckedContinuation<NWEndpoint.Port, Error>?
    private var requestWaiter: CheckedContinuation<Void, Error>?
    private var stopWaiter: CheckedContinuation<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var stopped = false
    private var stopping = false
    private var expired = false

    init(reply: Reply) throws {
        self.reply = reply
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() async throws -> NWEndpoint.Port {
        try await withCheckedThrowingContinuation { continuation in
            startWaiter = continuation
            listener.stateUpdateHandler = { [weak self] state in Task { await self?.stateChanged(state) } }
            listener.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection) } }
            // Bound the fixture's startup/request wait independently of the production probe.
            deadline = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { return }
                await self?.fixtureDeadline()
            }
            listener.start(queue: .global(qos: .utility))
        }
    }

    func requests() -> [[String: String]] { observed }

    func waitForRequest() async throws {
        if !observed.isEmpty { return }
        if expired { throw CocoaError(.fileReadUnknown) }
        if stopped || stopping { throw CancellationError() }
        try await withCheckedThrowingContinuation { requestWaiter = $0 }
    }

    func stop() async {
        stopping = true
        deadline?.cancel()
        deadline = nil
        requestWaiter?.resume(throwing: CancellationError()); requestWaiter = nil
        for connection in connections { connection.cancel() }
        if stopped { return }
        await withCheckedContinuation { continuation in
            stopWaiter = continuation
            listener.cancel()
        }
    }

    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener.port { startWaiter?.resume(returning: port); startWaiter = nil }
        case .failed(let error):
            stopped = true
            startWaiter?.resume(throwing: error); startWaiter = nil
            requestWaiter?.resume(throwing: error); requestWaiter = nil
            stopWaiter?.resume(); stopWaiter = nil
        case .cancelled:
            stopped = true
            startWaiter?.resume(throwing: CancellationError()); startWaiter = nil
            requestWaiter?.resume(throwing: CancellationError()); requestWaiter = nil
            stopWaiter?.resume(); stopWaiter = nil
        default: break
        }
    }

    private func fixtureDeadline() {
        expired = true
        startWaiter?.resume(throwing: CocoaError(.fileReadUnknown)); startWaiter = nil
        requestWaiter?.resume(throwing: CocoaError(.fileReadUnknown)); requestWaiter = nil
    }

    private func accept(_ connection: NWConnection) {
        guard !stopping, !stopped else { connection.cancel(); return }
        connections.append(connection)
        connection.start(queue: .global(qos: .utility))
        readRequest(connection, buffer: Data())
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096 - buffer.count) { [weak self] bytes, _, complete, error in
            Task { await self?.receivedRequest(connection, buffer: buffer, bytes: bytes, complete: complete, error: error) }
        }
    }

    private func receivedRequest(_ connection: NWConnection, buffer: Data, bytes: Data?, complete: Bool, error: NWError?) {
        guard error == nil, let bytes, !bytes.isEmpty else { return }
        let buffer = buffer + bytes
        if buffer.count >= 4 {
            let size = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard size > 0, size < 4092 else { connection.cancel(); return }
            if buffer.count >= Int(size) + 4 {
                do {
                    let value = try PropertyListSerialization.propertyList(from: Data(buffer.dropFirst(4).prefix(Int(size))), options: [], format: nil)
                    guard let request = value as? [String: String] else { connection.cancel(); return }
                    observed.append(request)
                    requestWaiter?.resume(); requestWaiter = nil
                    if case .reply(let pieces) = reply { send(pieces, index: 0, connection: connection) }
                } catch { connection.cancel() }
                return
            }
        }
        guard !complete, buffer.count < 4096 else { connection.cancel(); return }
        readRequest(connection, buffer: buffer)
    }

    private func send(_ pieces: [Data], index: Int, connection: NWConnection) {
        guard index < pieces.count else {
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
            return
        }
        connection.send(content: pieces[index], completion: .contentProcessed { [weak self] error in
            if error == nil { Task { await self?.send(pieces, index: index + 1, connection: connection) } }
        })
    }
}
