import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import LegadoRuntime

private struct RuntimeWorkerObservation: Sendable {
    let operation: String
    let isMainThread: Bool
    #if canImport(Darwin)
    let signalProbeStatus: Int32
    let nativeThreadID: UInt64
    let nativeThreadIDStatus: Int32
    #endif

    init(_ operation: String) {
        self.operation = operation
        isMainThread = Thread.isMainThread
        #if canImport(Darwin)
        // Signal zero checks whether this actual worker can be targeted without
        // delivering a signal or installing a process-wide signal handler.
        signalProbeStatus = pthread_kill(pthread_self(), 0)
        var identifier: UInt64 = 0
        nativeThreadIDStatus = pthread_threadid_np(nil, &identifier)
        nativeThreadID = identifier
        #endif
    }
}

private final class RecordingTransport: LegadoRuntimeTransport, @unchecked Sendable {
    private let lock = NSLock()
    var started = 0
    var calls: [String] = []
    private var configuredSources: [(String, String)] = []
    private var observedWorkers: [RuntimeWorkerObservation] = []
    var sessionOptions: [(String, String)] { lock.withLock { configuredSources } }
    var workerObservations: [RuntimeWorkerObservation] { lock.withLock { observedWorkers } }
    func start(_ configuration: LegadoRuntime.Configuration) throws {
        lock.withLock { started += 1; observedWorkers.append(RuntimeWorkerObservation("start")) }
    }
    func createSession(_ source: String) throws -> String {
        lock.withLock { observedWorkers.append(RuntimeWorkerObservation("create")) }
        return "{\"ok\":true,\"sessionId\":\"source-1\"}"
    }
    func createSession(_ source: String, optionsJSON: String) throws -> String {
        lock.withLock {
            configuredSources.append((source, optionsJSON))
            observedWorkers.append(RuntimeWorkerObservation("configuredCreate"))
        }
        return "{\"ok\":true,\"sessionId\":\"source-1\"}"
    }
    func execute(_ session: String, _ task: String, _ operation: String, _ request: String) throws -> String {
        lock.withLock { calls.append(request); observedWorkers.append(RuntimeWorkerObservation("execute")) }
        return "{\"ok\":true,\"taskId\":\"\(task)\",\"result\":\(request)}"
    }
    func cancel(_ task: String) throws -> String {
        lock.withLock { observedWorkers.append(RuntimeWorkerObservation("cancel")) }
        return "{\"ok\":true}"
    }
    func closeSession(_ session: String) throws -> String {
        lock.withLock { observedWorkers.append(RuntimeWorkerObservation("close")) }
        return "{\"ok\":true}"
    }
}
private final class BlockingTransport: LegadoRuntimeTransport, @unchecked Sendable {
    private let response: String
    init(response: String = "{\"ok\":true}") { self.response = response }
    let entered = DispatchSemaphore(value: 0)
    let cancelReturned = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var observedWorkers: [RuntimeWorkerObservation] = []
    var workerObservations: [RuntimeWorkerObservation] { lock.withLock { observedWorkers } }
    func start(_ configuration: LegadoRuntime.Configuration) throws {}
    func createSession(_ source: String) throws -> String { "{\"ok\":true,\"sessionId\":\"blocking\"}" }
    func execute(_ session: String, _ task: String, _ operation: String, _ request: String) throws -> String {
        lock.withLock { observedWorkers.append(RuntimeWorkerObservation("execute")) }
        entered.signal()
        guard finished.wait(timeout: .now() + 5) == .success else {
            throw LegadoRuntimeError(code: "test_timeout", message: "Cancel was not delivered on another worker")
        }
        return response
    }
    func cancel(_ task: String) throws -> String {
        defer { cancelReturned.signal() }
        lock.withLock { observedWorkers.append(RuntimeWorkerObservation("cancel")) }
        finished.signal()
        return "{\"ok\":true}"
    }
    func closeSession(_ session: String) throws -> String { "{\"ok\":true}" }
}
@MainActor final class LegadoRuntimeTests: XCTestCase {
    private func waitForSignal(_ signal: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            // Waiting for a test transport's real event must not block main.
            DispatchQueue(label: "io.yuedu.legado.test-event").async {
                continuation.resume(returning: signal.wait(timeout: .now() + 5) == .success)
            }
        }
    }
    private func assertSignalableBackgroundWorkers(_ observations: [RuntimeWorkerObservation], file: StaticString = #filePath, line: UInt = #line) {
        for worker in observations {
            XCTAssertFalse(worker.isMainThread, worker.operation, file: file, line: line)
            #if canImport(Darwin)
            XCTAssertEqual(worker.signalProbeStatus, 0, worker.operation, file: file, line: line)
            XCTAssertEqual(worker.nativeThreadIDStatus, 0, worker.operation, file: file, line: line)
            XCTAssertNotEqual(worker.nativeThreadID, 0, worker.operation, file: file, line: line)
            #endif
        }
    }
    private func diagnosticsFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        return folder
    }
    private func diagnosticsConfiguration(_ root: URL) -> LegadoRuntime.Configuration {
        .init(javaHome: URL(fileURLWithPath: "/unused"), classPath: [], diagnosticsDirectory: root)
    }
    func testInspectingMissingDiagnosticsDoesNotCreateFiles() throws {
        let parent = try diagnosticsFolder()
        let missing = parent.appendingPathComponent("not-created", isDirectory: true)
        XCTAssertEqual(try LegadoRuntime.savedDiagnostics(configuration: diagnosticsConfiguration(missing)), [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }
    func testSavedDiagnosticsPreserveBothAttemptsAndVMOutput() throws {
        let root = try diagnosticsFolder()
        for attempt in ["current", "previous"] {
            let folder = root.appendingPathComponent(attempt, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("stage=JNI_CreateJavaVM.before".utf8).write(to: folder.appendingPathComponent("stages.log"))
            try Data("VM initialization failed".utf8).write(to: folder.appendingPathComponent("vm-output.log"))
            try Data("fatal header".utf8).write(to: folder.appendingPathComponent("hs_err_pid123.log"))
        }
        let configuration = diagnosticsConfiguration(root)
        let first = try LegadoRuntime.savedDiagnostics(configuration: configuration)
        XCTAssertEqual(first.count, 6)
        XCTAssertEqual(first["previous/vm-output.log"], "VM initialization failed")
        XCTAssertEqual(first["current/hs_err_pid123.log"], "fatal header")
        XCTAssertEqual(try LegadoRuntime.savedDiagnostics(configuration: configuration), first)
    }

    func testSavedTaskTracesUseOnlyFixedNamesAndIndependentBounds() throws {
        let root = try diagnosticsFolder()
        let current = root.appendingPathComponent("current", isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Data("{\"stage\":\"cancel.result\"}\n".utf8).write(to: current.appendingPathComponent("native-task-events.jsonl"))
        try Data(repeating: 120, count: LegadoSavedDiagnostics.taskTraceLimit + 100).write(to: current.appendingPathComponent("runtime-events.jsonl"))
        try Data("DO_NOT_READ".utf8).write(to: current.appendingPathComponent("arbitrary-events.jsonl"))
        let reports = try LegadoSavedDiagnostics.read(root)
        XCTAssertEqual(reports.count, 2)
        XCTAssertTrue(reports["current/native-task-events.jsonl"]?.contains("cancel.result") == true)
        let bounded = try XCTUnwrap(reports["current/runtime-events.jsonl"])
        XCTAssertTrue(bounded.contains("[truncated:"))
        XCTAssertLessThan(bounded.utf8.count, LegadoSavedDiagnostics.taskTraceLimit + 256)
    }
    func testLargeFatalLogRetainsHeaderAndTailWithinReadLimit() throws {
        let root = try diagnosticsFolder()
        let current = root.appendingPathComponent("current", isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        let contents = "FATAL HEADER\n" + String(repeating: "x", count: 300_000) + "\nVM OPTIONS TAIL"
        try Data(contents.utf8).write(to: current.appendingPathComponent("hs_err_pid1.log"))
        let reports = try LegadoRuntime.savedDiagnostics(configuration: diagnosticsConfiguration(root))
        let saved = try XCTUnwrap(reports["current/hs_err_pid1.log"])
        XCTAssertTrue(saved.hasPrefix("FATAL HEADER"))
        XCTAssertTrue(saved.hasSuffix("VM OPTIONS TAIL"))
        XCTAssertTrue(saved.contains("[truncated:"))
        XCTAssertLessThan(saved.utf8.count, LegadoSavedDiagnostics.fatalLimit + 256)
    }
    func testInvalidAttemptPathIsAnExplicitReadError() throws {
        let root = try diagnosticsFolder()
        try Data("not a directory".utf8).write(to: root.appendingPathComponent("current"))
        XCTAssertThrowsError(try LegadoRuntime.savedDiagnostics(configuration: diagnosticsConfiguration(root))) { error in
            XCTAssertEqual((error as? LegadoRuntimeError)?.code, "invalid_diagnostics_path")
        }
    }
    func testMissingPayloadIsExplicit() {
        let diagnostics = LegadoRuntime.diagnose(configuration: .init(javaHome: URL(fileURLWithPath: "/nonexistent-legado-runtime"), classPath: []))
        XCTAssertFalse(diagnostics.available)
        XCTAssertTrue(diagnostics.issues.contains { $0.contains("java.xml") })
        XCTAssertTrue(diagnostics.issues.contains { $0.contains("java.desktop") })
        XCTAssertTrue(diagnostics.issues.contains { $0.contains("conf/security/java.security") })
        XCTAssertTrue(diagnostics.deviceValidationRequired)
    }
    private func moduleImageDiagnostics(version: UInt32 = 0x0001_0001, table: UInt32 = 1) throws -> LegadoRuntimeDiagnostics {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ModuleImage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("lib"), withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("Could not remove owned image fixture: \(error)") }
        }
        var header = Data()
        let words: [UInt32] = [0xcafe_dada, version, 0, 1, table, 1, 23]
        for word in words {
            for shift in stride(from: 0, through: 24, by: 8) { header.append(UInt8(truncatingIfNeeded: word >> shift)) }
        }
        header.append(Data(repeating: 0, count: 64))
        try header.write(to: root.appendingPathComponent("lib/modules"))
        return LegadoRuntime.diagnose(configuration: .init(javaHome: root, classPath: []))
    }
    func testModuleImageValidHeader() throws {
        let diagnostics = try moduleImageDiagnostics()
        XCTAssertFalse(diagnostics.issues.contains { $0.hasPrefix("invalid_module_image:") })
        XCTAssertFalse(diagnostics.issues.contains { $0.hasPrefix("missing_module:") || $0.hasPrefix("missing_class:") })
        // An image header alone is never a complete usable runtime.
        XCTAssertFalse(diagnostics.available)
        XCTAssertTrue(diagnostics.issues.contains { $0.contains("conf/security/java.security") })
    }
    func testModuleImageRejectsUnsupportedVersion() throws {
        let diagnostics = try moduleImageDiagnostics(version: 0x0001_0000)
        XCTAssertTrue(diagnostics.issues.contains { $0.contains("image version 1.1") })
        XCTAssertFalse(diagnostics.issues.contains { $0.hasPrefix("missing_module:") })
    }
    func testModuleImageRejectsTruncatedIndex() throws {
        let diagnostics = try moduleImageDiagnostics(table: UInt32.max)
        XCTAssertTrue(diagnostics.issues.contains { $0.contains("index exceeds file bounds") })
        XCTAssertFalse(diagnostics.issues.contains { $0.hasPrefix("missing_module:") })
    }
    func testJSONErrorEnvelopeIsNotAcceptedAsSuccess() {
        XCTAssertThrowsError(try LegadoRuntime.envelope("{\"ok\":false,\"error\":{\"code\":\"cancelled\",\"message\":\"Stopped\"}}")) { error in
            XCTAssertEqual((error as? LegadoRuntimeError)?.code, "cancelled")
        }
        XCTAssertThrowsError(try LegadoRuntime.envelope("{}"))
    }
    func testPlatformDeadlineIsBoundedAndCanExpire() {
        XCTAssertEqual(LegadoHostRequest.timeoutSeconds("{\"deadlineEpochMs\":105000,\"remainingTimeoutMs\":9000,\"timeoutMs\":20000}", now: 100), 5)
        XCTAssertEqual(LegadoHostRequest.timeoutSeconds("{\"deadlineEpochMs\":99000}", now: 100), 0)
        XCTAssertEqual(LegadoHostRequest.timeoutSeconds("{}", now: 100), 180)
    }
    func testGBKRequestUsesOriginalBytesInsteadOfUTF8Text() throws {
        let gbk = Data([0xC4, 0xE3, 0xBA, 0xC3]) // 你好 encoded as GBK.
        let result = try LegadoHTTPBodyCodec.requestBody(text: "你好", base64: gbk.base64EncodedString())
        XCTAssertEqual(result, gbk)
        XCTAssertNotEqual(result, Data("你好".utf8))
        XCTAssertThrowsError(try LegadoHTTPBodyCodec.requestBody(text: "ignored", base64: "%%%"))
    }
    func testBinaryAndGBKResponsesRemainBytesForJVMCharsetDecoder() throws {
        for body in [Data([0xC4, 0xE3, 0xBA, 0xC3]), Data([0x00, 0xFF, 0x80, 0x01])] {
            let encoded = try LegadoHTTPBodyCodec.response(body: body, status: 200, url: "https://fixture.invalid", headers: [:])
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
            XCTAssertNil(response["body"])
            XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(response["bodyBase64"] as? String)), body)
        }
    }
    func testSessionAndUnicodeRequestRoundTrip() async throws {
        let transport = RecordingTransport()
        let runtime = LegadoRuntime(configuration: .init(javaHome: URL(fileURLWithPath: "/unused"), classPath: []), host: UnsupportedLegadoHost(), transport: transport)
        let session = try await runtime.createSession(sourceJSON: "{\"name\":\"阅读😀\"}")
        let request = "{\"query\":\"中文😀\\u0000末尾\"}"
        let result = try await runtime.execute(session: session, operation: "search", requestJSON: request, taskID: "task-1")
        XCTAssertTrue(result.contains("中文😀"))
        try await runtime.close(session: session)
        XCTAssertEqual(transport.started, 1)
        XCTAssertEqual(transport.calls, [request])
    }
    func testInvalidInputIsRejectedBeforeJNI() async {
        let transport = RecordingTransport()
        let runtime = LegadoRuntime(configuration: .init(javaHome: URL(fileURLWithPath: "/unused"), classPath: []), host: UnsupportedLegadoHost(), transport: transport)
        do { _ = try await runtime.createSession(sourceJSON: "[]"); XCTFail("Expected object validation") }
        catch { XCTAssertEqual((error as? LegadoRuntimeError)?.code, "invalid_json") }
        XCTAssertEqual(transport.started, 0)
    }
    func testConfiguredSessionKeepsTransportOptionsOutsideSourceData() async throws {
        let transport = RecordingTransport()
        let runtime = LegadoRuntime(configuration: .init(javaHome: URL(fileURLWithPath: "/unused"), classPath: []), host: UnsupportedLegadoHost(), transport: transport)
        let source = "{\"bookSourceName\":\"中文😀\",\"mainJs\":\"function search(){return [];}\"}"
        _ = try await runtime.createSession(sourceJSON: source, options: .init(httpTransport: .jvmOkHttp))
        let call = try XCTUnwrap(transport.sessionOptions.first)
        XCTAssertEqual(call.0, source)
        let options = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(call.1.utf8)) as? [String: String])
        XCTAssertEqual(options, ["httpTransport": "jvm-okhttp"])
        XCTAssertEqual(transport.sessionOptions.count, 1)
    }
    func testConfiguredSessionCannotSilentlyUseLegacyTransport() async throws {
        let transport = BlockingTransport()
        let runtime = LegadoRuntime(configuration: .init(javaHome: URL(fileURLWithPath: "/unused"), classPath: []), host: UnsupportedLegadoHost(), transport: transport)
        do {
            _ = try await runtime.createSession(sourceJSON: "{}", options: .init(httpTransport: .jvmOkHttp))
            XCTFail("Explicit JVM HTTP selection must not fall back to the legacy transport")
        } catch {
            XCTAssertEqual((error as? LegadoRuntimeError)?.code, "unsupported_session_options")
        }
    }
    func testRuntimeOperationsRunOnSignalableBackgroundThreads() async throws {
        let transport = RecordingTransport()
        let runtime = LegadoRuntime(configuration: .init(javaHome: URL(fileURLWithPath: "/unused"), classPath: []), host: UnsupportedLegadoHost(), transport: transport)
        let session = try await runtime.createSession(sourceJSON: "{}")
        _ = try await runtime.execute(session: session, operation: "search", taskID: "worker-test")
        try await runtime.cancel(taskID: "worker-test")
        try await runtime.close(session: session)

        let workers = transport.workerObservations
        XCTAssertEqual(workers.map(\.operation), ["start", "create", "execute", "cancel", "close"])
        assertSignalableBackgroundWorkers(workers)
    }
    func testCancelledExecutePreservesReportedEffectsFromSuccessAndErrorEnvelopes() async throws {
        let effects = ["chapterContentMayCommit", "chapterContentCommitted"]
        let responses = [
            #"{"ok":true,"result":{},"completedEffects":["chapterContentMayCommit","chapterContentCommitted"]}"#,
            #"{"ok":false,"error":{"code":"CANCELLED","message":"Stopped","completedEffects":["chapterContentMayCommit","chapterContentCommitted"]}}"#
        ]
        for response in responses {
            let transport = BlockingTransport(response: response)
            let runtime = LegadoRuntime(configuration: .init(javaHome: URL(fileURLWithPath: "/unused"), classPath: []),
                host: UnsupportedLegadoHost(), transport: transport)
            let session = try await runtime.createSession(sourceJSON: "{}")
            let task = Task { try await runtime.execute(session: session, operation: "blocking", taskID: "effect-cancel") }
            let started = await waitForSignal(transport.entered)
            XCTAssertTrue(started)
            task.cancel()
            let terminal = await task.result
            switch terminal {
            case .success: XCTFail("A cancelled task cannot report success after platform effects")
            case .failure(let error):
                let typed = try XCTUnwrap(error as? LegadoRuntimeError)
                XCTAssertEqual(typed.code, "CANCELLED")
                XCTAssertEqual(typed.completedEffects, effects)
            }
            let drained = await waitForSignal(transport.cancelReturned)
            XCTAssertTrue(drained)
            try await runtime.close(session: session)
        }
    }
    func testCancelReachesRuntimeWhileExecuteWorkerIsBlocked() async throws {
        let transport = BlockingTransport()
        let runtime = LegadoRuntime(configuration: .init(javaHome: URL(fileURLWithPath: "/unused"), classPath: []), host: UnsupportedLegadoHost(), transport: transport)
        let session = try await runtime.createSession(sourceJSON: "{}")
        let task = Task { try await runtime.execute(session: session, operation: "blocking", taskID: "cancel-test") }
        let started = await waitForSignal(transport.entered)
        XCTAssertTrue(started)
        task.cancel()
        let result = await task.result
        switch result {
        case .success: XCTFail("A cancelled task must not report success")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
        let cancellationDrained = await waitForSignal(transport.cancelReturned)
        XCTAssertTrue(cancellationDrained)
        let workers = transport.workerObservations
        XCTAssertEqual(workers.map(\.operation), ["execute", "cancel"])
        assertSignalableBackgroundWorkers(workers)
        #if canImport(Darwin)
        if workers.count == 2 {
            XCTAssertNotEqual(workers[0].nativeThreadID, workers[1].nativeThreadID, "Cancel must reach a separate worker while execute is blocked")
        }
        #endif
    }
}
