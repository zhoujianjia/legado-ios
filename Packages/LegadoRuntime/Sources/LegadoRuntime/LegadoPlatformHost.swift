import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Request-local control facts, never source state or a persistence owner. The
/// native callback can read conservative issued-side-effect facts even when an
/// asynchronous platform completion has not returned at the absolute deadline.
internal final class LegadoHostEffectRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var effects: [String] = []
    private var closed = false
    func record(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 256 else { return false }
        return lock.withLock {
            guard !closed else { return false }
            if effects.contains(value) { return true }
            guard effects.count < 32 else { return false }
            effects.append(value)
            return true
        }
    }
    func snapshot() -> [String] { lock.withLock { effects } }
    func close() -> [String] { lock.withLock { closed = true; return effects } }
}

public struct LegadoHostRequest: Sendable {
    public let taskID: String
    public let operation: String
    public let requestJSON: String
    private let effectRecorder = LegadoHostEffectRecorder()
    /// False means the native callback has already sealed its response. A
    /// platform mutation must claim its possible effect before issuing IPC or
    /// entering a noninterruptible commit, and must not start when denied.
    @discardableResult public func recordPossibleEffect(_ name: String) -> Bool { effectRecorder.record(name) }
    internal var possibleEffects: [String] { effectRecorder.snapshot() }
    internal func closePossibleEffects() -> [String] { effectRecorder.close() }
    public init(taskID: String, operation: String, requestJSON: String) {
        self.taskID = taskID; self.operation = operation; self.requestJSON = requestJSON
    }
    public var remainingTimeoutSeconds: TimeInterval { Self.timeoutSeconds(requestJSON) }
    internal static func timeoutSeconds(_ json: String, now: TimeInterval = Date().timeIntervalSince1970) -> TimeInterval {
        struct Limits: Decodable { let deadlineEpochMs: Double?; let remainingTimeoutMs: Double?; let timeoutMs: Double? }
        guard let limits = try? JSONDecoder().decode(Limits.self, from: Data(json.utf8)) else { return 180 }
        var values: [Double] = [180]
        if let deadline = limits.deadlineEpochMs, deadline.isFinite { values.append(deadline / 1000 - now) }
        if let remaining = limits.remainingTimeoutMs, remaining.isFinite { values.append(remaining / 1000) }
        if let timeout = limits.timeoutMs, timeout.isFinite { values.append(timeout / 1000) }
        return max(0, values.min() ?? 180)
    }
}
/// Called off the main thread by JNI. Async browser adapters can hop to MainActor;
/// the caller waits on a worker and never blocks the UI executor.
public protocol LegadoPlatformHost: Sendable {
    func dispatch(_ request: LegadoHostRequest) async throws -> String
    func cancel(taskID: String) async
}
public extension LegadoPlatformHost { func cancel(taskID: String) async {} }

public struct UnsupportedLegadoHost: LegadoPlatformHost {
    public init() {}
    public func dispatch(_ request: LegadoHostRequest) async throws -> String {
        throw LegadoRuntimeError(code: "unsupported_host", message: "Platform operation \(request.operation) is not configured")
    }
}

internal enum LegadoHTTPBodyCodec {
    static func requestBody(text: String?, base64: String?) throws -> Data? {
        if let base64 {
            guard let bytes = Data(base64Encoded: base64) else {
                throw LegadoRuntimeError(code: "invalid_body_base64", message: "HTTP bodyBase64 is malformed")
            }
            return bytes
        }
        return text.map { Data($0.utf8) }
    }
    static func response(body: Data, status: Int, url: String, headers: [String: String]) throws -> String {
        // Leave decoding to the JVM's source charset. A lossy UTF-8 body would take
        // precedence over bodyBase64 in SourceHosts and corrupt GBK/binary responses.
        let object: [String: Any] = ["status": status, "url": url, "headers": headers, "bodyBase64": body.base64EncodedString()]
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
}

/// Optional HTTP adapter for the prototype. Cookie state remains in the JVM;
/// browser, filesystem, notifications and media operations require explicit adapters.
/// Repeated field lines are rejected because URLSession cannot preserve their
/// wire representation. Full HTTP parity requires the original JVM transport.
public actor URLSessionLegadoHost: LegadoPlatformHost {
    private let session: URLSession
    private var requests: [String: [UUID: Task<String, Error>]] = [:]
    private var cancelledTasks: Set<String> = []
    private var cancellationOrder: [String] = []
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        self.session = URLSession(configuration: configuration)
    }
    public func dispatch(_ request: LegadoHostRequest) async throws -> String {
        guard !cancelledTasks.contains(request.taskID) else { throw CancellationError() }
        guard request.remainingTimeoutSeconds > 0 else { throw LegadoRuntimeError(code: "host_timeout", message: "Task deadline has expired") }
        guard request.operation == "http.request" else {
            throw LegadoRuntimeError(code: "unsupported_host", message: "Platform operation \(request.operation) is not configured")
        }
        struct Input: Decodable {
            let url: String; let method: String?; let headers: LegadoHTTPHeaders?; let body: String?; let bodyBase64: String?; let timeoutMs: Double?
        }
        let input = try JSONDecoder().decode(Input.self, from: Data(request.requestJSON.utf8))
        guard let url = URL(string: input.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw LegadoRuntimeError(code: "invalid_url", message: "HTTP adapter requires http or https URL")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = input.method ?? "GET"
        urlRequest.allHTTPHeaderFields = try input.headers?.urlSessionFields()
        urlRequest.httpBody = try LegadoHTTPBodyCodec.requestBody(text: input.body, base64: input.bodyBase64)
        urlRequest.timeoutInterval = min(170, max(0.001, min(request.remainingTimeoutSeconds, (input.timeoutMs ?? 30_000) / 1000)))
        let client = session
        let pending = Task<String, Error> {
            let (body, response) = try await client.data(for: urlRequest)
            guard let response = response as? HTTPURLResponse else {
                throw LegadoRuntimeError(code: "invalid_response", message: "Expected HTTP response")
            }
            var headers: [String: String] = [:]
            for (name, value) in response.allHeaderFields { headers[String(describing: name)] = String(describing: value) }
            return try LegadoHTTPBodyCodec.response(body: body, status: response.statusCode, url: response.url?.absoluteString ?? input.url, headers: headers)
        }
        let requestID = UUID()
        requests[request.taskID, default: [:]][requestID] = pending
        defer {
            requests[request.taskID]?.removeValue(forKey: requestID)
            if requests[request.taskID]?.isEmpty == true { requests.removeValue(forKey: request.taskID) }
        }
        return try await withTaskCancellationHandler { try await pending.value } onCancel: { pending.cancel() }
    }
    public func cancel(taskID: String) async {
        if cancelledTasks.insert(taskID).inserted { cancellationOrder.append(taskID) }
        if cancellationOrder.count > 1024 { cancelledTasks.remove(cancellationOrder.removeFirst()) }
        if let pendingRequests = requests[taskID] { for pending in pendingRequests.values { pending.cancel() } }
    }
}
