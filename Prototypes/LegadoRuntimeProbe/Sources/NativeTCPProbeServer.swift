import Foundation
import LegadoRuntime
import Network

/// A single-use, loopback-only peer for exercising the JVM's real Socket natives.
/// All mutable state and Network callbacks belong to `queue`; none runs on main.
final class NativeTCPProbeServer: @unchecked Sendable {
    static let requestBytes = Data("LEGADO_NATIVE_TCP\n".utf8)
    static let replyLine = "LEGADO_NATIVE_OK"

    private let queue = DispatchQueue(label: "local.legado.probe.tcp")
    private let listener: NWListener
    private var startup: CheckedContinuation<UInt16, Error>?
    private var startupTimeout: DispatchWorkItem?
    private var connections: [UUID: NWConnection] = [:]
    private var captured = Data()
    private var stopped = false

    private init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    static func start() async throws -> (server: NativeTCPProbeServer, port: UInt16) {
        let server = try NativeTCPProbeServer()
        var started = false
        defer { if !started { server.stop() } }
        let port: UInt16 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                server.queue.async {
                    guard !server.stopped else { continuation.resume(throwing: CancellationError()); return }
                    server.startup = continuation
                    server.listener.stateUpdateHandler = { [weak server] state in
                        guard let server else { return }
                        switch state {
                        case .ready:
                            guard let port = server.listener.port else {
                                server.finishStartup(.failure(server.failure("Listener has no bound port")))
                                return
                            }
                            server.finishStartup(.success(port.rawValue))
                        case .failed(let error): server.finishStartup(.failure(error))
                        case .cancelled: server.finishStartup(.failure(CancellationError()))
                        default: break
                        }
                    }
                    server.listener.newConnectionHandler = { [weak server] connection in
                        guard let server, !server.stopped else { connection.cancel(); return }
                        let id = UUID()
                        server.connections[id] = connection
                        connection.start(queue: server.queue)
                        server.receive(connection, id: id, bytes: Data())
                    }
                    let timeout = DispatchWorkItem { [weak server] in
                        guard let server, server.startup != nil else { return }
                        server.finishStartup(.failure(server.failure("Loopback listener startup timed out")))
                        server.stopOnQueue()
                    }
                    server.startupTimeout = timeout
                    // This is a bounded networking timeout, not a UI settling delay.
                    server.queue.asyncAfter(deadline: .now() + 5, execute: timeout)
                    server.listener.start(queue: server.queue)
                }
            }
        } onCancel: { server.stop() }
        started = true
        return (server, port)
    }

    func receivedBytes() async -> Data {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.captured) }
        }
    }

    func stop() { queue.async { self.stopOnQueue() } }

    private func finishStartup(_ result: Result<UInt16, Error>) {
        guard let continuation = startup else { return }
        startup = nil
        startupTimeout?.cancel()
        startupTimeout = nil
        continuation.resume(with: result)
    }

    private func receive(_ connection: NWConnection, id: UUID, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { [weak self] chunk, _, complete, error in
            guard let self, !self.stopped else { connection.cancel(); return }
            var bytes = bytes
            if let chunk { bytes.append(chunk) }
            self.captured = bytes
            guard error == nil, bytes.count <= Self.requestBytes.count, Self.requestBytes.starts(with: bytes) else {
                self.close(connection, id: id)
                return
            }
            if bytes == Self.requestBytes {
                let reply = Data((Self.replyLine + "\n").utf8)
                connection.send(content: reply, completion: .contentProcessed { [weak self] _ in
                    self?.close(connection, id: id)
                })
            } else if complete {
                self.close(connection, id: id)
            } else {
                self.receive(connection, id: id, bytes: bytes)
            }
        }
    }

    private func close(_ connection: NWConnection, id: UUID) {
        connection.cancel()
        connections.removeValue(forKey: id)
    }

    private func stopOnQueue() {
        guard !stopped else { return }
        stopped = true
        finishStartup(.failure(CancellationError()))
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }

    private func failure(_ message: String) -> LegadoRuntimeError {
        LegadoRuntimeError(code: "NATIVE_TCP_PROBE", message: message)
    }
}
