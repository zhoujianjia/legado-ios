import XCTest
@testable import LegadoRuntime

private final class RecordingTransport: LegadoRuntimeTransport, @unchecked Sendable {
    private let lock = NSLock()
    var started = 0
    var calls: [String] = []
    func start(_ configuration: LegadoRuntime.Configuration) throws { lock.withLock { started += 1 } }
    func createSession(_ source: String) throws -> String { "{\"ok\":true,\"sessionId\":\"source-1\"}" }
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
    func testCancelReachesRuntimeWhileExecuteWorkerIsBlocked() async throws {
        let transport = BlockingTransport()
        let runtime = LegadoRuntime(configuration: .init(javaHome: URL(fileURLWithPath: "/unused"), classPath: []), host: UnsupportedLegadoHost(), transport: transport)
        let session = try await runtime.createSession(sourceJSON: "{}")
        let task = Task { try await runtime.execute(session: session, operation: "blocking", taskID: "cancel-test") }
        let startSignal = Task.detached { transport.entered.wait(timeout: .now() + 5) == .success }
        let started = await startSignal.value
        XCTAssertTrue(started)
        task.cancel()
        let result = await task.result
        switch result {
        case .success: XCTFail("A cancelled task must not report success")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
    }
}
