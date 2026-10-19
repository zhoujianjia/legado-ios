import XCTest
@testable import LegadoRuntime

private final class RecordingTransport: LegadoRuntimeTransport, @unchecked Sendable {
    private let lock = NSLock()
    var started = 0
    var calls: [String] = []
    private var configuredSources: [(String, String)] = []
    var sessionOptions: [(String, String)] { lock.withLock { configuredSources } }
    func start(_ configuration: LegadoRuntime.Configuration) throws { lock.withLock { started += 1 } }
    func createSession(_ source: String) throws -> String { "{\"ok\":true,\"sessionId\":\"source-1\"}" }
    func createSession(_ source: String, optionsJSON: String) throws -> String {
        lock.withLock { configuredSources.append((source, optionsJSON)) }
        return "{\"ok\":true,\"sessionId\":\"source-1\"}"
    }
    func execute(_ session: String, _ task: String, _ operation: String, _ request: String) throws -> String {
        lock.withLock { calls.append(request) }
        return "{\"ok\":true,\"taskId\":\"\(task)\",\"result\":\(request)}"
    }
    func cancel(_ task: String) throws -> String { "{\"ok\":true}" }
    func closeSession(_ session: String) throws -> String { "{\"ok\":true}" }
}
private final class BlockingTransport: LegadoRuntimeTransport, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    func start(_ configuration: LegadoRuntime.Configuration) throws {}
    func createSession(_ source: String) throws -> String { "{\"ok\":true,\"sessionId\":\"blocking\"}" }
    func execute(_ session: String, _ task: String, _ operation: String, _ request: String) throws -> String {
        entered.signal()
        guard finished.wait(timeout: .now() + 5) == .success else {
            throw LegadoRuntimeError(code: "test_timeout", message: "Cancel was not delivered on another worker")
        }
        return "{\"ok\":true}"
    }
    func cancel(_ task: String) throws -> String { finished.signal(); return "{\"ok\":true}" }
    func closeSession(_ session: String) throws -> String { "{\"ok\":true}" }
}
@MainActor final class LegadoRuntimeTests: XCTestCase {
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
    func testCancelReachesRuntimeWhileExecuteWorkerIsBlocked() async throws {
        let transport = BlockingTransport()
        let runtime = LegadoRuntime(configuration: .init(javaHome: URL(fileURLWithPath: "/unused"), classPath: []), host: UnsupportedLegadoHost(), transport: transport)
        let session = try await runtime.createSession(sourceJSON: "{}")
        let task = Task { try await runtime.execute(session: session, operation: "blocking", taskID: "cancel-test") }
        let started = await withCheckedContinuation { continuation in
            // Wait for the real entry signal on a blocking worker, with a test deadline.
            DispatchQueue(label: "io.yuedu.legado.test-entry").async {
                let entered = transport.entered.wait(timeout: .now() + 5) == .success
                continuation.resume(returning: entered)
            }
        }
        XCTAssertTrue(started)
        task.cancel()
        let result = await task.result
        switch result {
        case .success: XCTFail("A cancelled task must not report success")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
    }
}
