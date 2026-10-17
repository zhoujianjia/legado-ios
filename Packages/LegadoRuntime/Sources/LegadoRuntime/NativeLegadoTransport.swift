import Foundation
import CLegadoJNI

/// This box is retained for the process lifetime after JVM startup because RegisterNatives
/// can call it until process termination. JavaVM destruction/recreation is unsupported.
private final class HostBox: @unchecked Sendable {
    let host: any LegadoPlatformHost
    init(_ host: any LegadoPlatformHost) { self.host = host }
}
private final class HostResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ value: String) { lock.withLock { self.value = value } }
    func get() -> String? { lock.withLock { value } }
}
private func hostFailure(_ code: String, _ message: String) -> String {
    let object: [String: Any] = ["ok": false, "error": ["code": code, "message": message]]
    return String(data: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), encoding: .utf8) ?? "{}"
}
private func read(_ string: LGRString) -> String {
    guard string.count > 0, let bytes = string.bytes else { return "" }
    return String(decoding: UnsafeBufferPointer(start: bytes, count: string.count), as: UTF8.self)
}
private func dispatchHost(_ context: UnsafeMutableRawPointer?, _ task: LGRString, _ operation: LGRString, _ request: LGRString) -> LGRResult {
    let response: String
    if Thread.isMainThread {
        response = hostFailure("host_main_thread", "Synchronous Java host calls must run on a worker thread")
    } else if let context {
        let box = Unmanaged<HostBox>.fromOpaque(context).takeUnretainedValue()
        let input = LegadoHostRequest(taskID: read(task), operation: read(operation), requestJSON: read(request))
        let semaphore = DispatchSemaphore(value: 0)
        let output = HostResponse()
        let pending = Task {
            do {
                if input.operation == "task.cancel" {
                    await box.host.cancel(taskID: input.taskID)
                    output.set("{\"ok\":true}")
                } else { output.set(try await box.host.dispatch(input)) }
            }
            catch let error as LegadoRuntimeError { output.set(hostFailure(error.code, error.message)) }
            catch { output.set(hostFailure("host_failure", error.localizedDescription)) }
            semaphore.signal()
        }
        // JVM injects the task deadline; also bound adapters whose presenter disappears.
        if semaphore.wait(timeout: .now() + input.remainingTimeoutSeconds) == .timedOut {
            pending.cancel()
            Task { await box.host.cancel(taskID: input.taskID) }
            response = hostFailure("host_timeout", "Platform adapter exceeded the task deadline")
        } else { response = output.get() ?? hostFailure("host_failure", "Missing platform response") }
    } else { response = hostFailure("unsupported_host", "No host adapter was configured") }
    return Array(response.utf8).withUnsafeBufferPointer { LGRMakeResult($0.baseAddress, $0.count, 0) }
}

internal final class NativeLegadoTransport: LegadoRuntimeTransport, @unchecked Sendable {
    let host: any LegadoPlatformHost
    init(host: any LegadoPlatformHost) { self.host = host }
    func start(_ configuration: LegadoRuntime.Configuration) throws {
        let diagnostics = LegadoRuntime.diagnose(configuration: configuration)
        guard diagnostics.available else { throw LegadoRuntimeError(code: "missing_runtime", message: diagnostics.issues.joined(separator: "; ")) }
        if let directory = configuration.diagnosticsDirectory {
            _ = try strings([directory.path]) { LGRSetDiagnosticsDirectory($0[0]) }
        }
        let box = Unmanaged.passRetained(HostBox(host))
        do {
            _ = try strings([configuration.classPath.map(\.path).joined(separator: ":"), configuration.javaHome.path]) { values in
                LGRStart(values[0], values[1], Int32(configuration.maximumHeapMegabytes), dispatchHost, box.toOpaque())
            }
        } catch {
            // The callback is only invoked after successful facade registration/start.
            box.release()
            throw error
        }
    }
    func createSession(_ source: String) throws -> String { try strings([source]) { LGRCreateSession($0[0]) } }
    func execute(_ session: String, _ task: String, _ operation: String, _ request: String) throws -> String {
        try strings([session, task, operation, request]) { LGRExecute($0[0], $0[1], $0[2], $0[3]) }
    }
    func cancel(_ task: String) throws -> String { try strings([task]) { LGRCancel($0[0]) } }
    func closeSession(_ session: String) throws -> String { try strings([session]) { LGRCloseSession($0[0]) } }
    private func strings(_ values: [String], _ action: ([LGRString]) -> LGRResult) throws -> String {
        let buffers = values.map { Array($0.utf8) }
        func call(_ index: Int, _ inputs: [LGRString]) -> LGRResult {
            if index == buffers.count { return action(inputs) }
            return buffers[index].withUnsafeBufferPointer { buffer in
                call(index + 1, inputs + [LGRString(bytes: buffer.baseAddress, count: buffer.count)])
            }
        }
        let result = call(0, [])
        defer { LGRFreeResult(result) }
        let message: String
        if let bytes = result.bytes { message = String(decoding: UnsafeBufferPointer(start: bytes, count: result.count), as: UTF8.self) }
        else { message = "" }
        guard result.code == 0 else { throw LegadoRuntimeError(code: "jni_\(result.code)", message: message) }
        return message
    }
}
