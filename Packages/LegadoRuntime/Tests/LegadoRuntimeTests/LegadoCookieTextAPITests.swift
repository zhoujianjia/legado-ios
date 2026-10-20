import Foundation
import XCTest
@testable import LegadoRuntime

private final class CookieTextAPITransport: LegadoRuntimeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var savedOptions: String?
    var options: String? { lock.withLock { savedOptions } }
    func start(_ configuration: LegadoRuntime.Configuration) throws {}
    func createSession(_ source: String) throws -> String { "{\"ok\":true,\"sessionId\":\"text-owned\"}" }
    func createSession(_ source: String, optionsJSON: String) throws -> String {
        lock.withLock { savedOptions = optionsJSON }; return try createSession(source)
    }
    func execute(_ session: String, _ task: String, _ operation: String, _ request: String) throws -> String {
        "{\"ok\":false,\"error\":{\"code\":\"STATE_IO\",\"message\":\"Cookie text was committed; login header failed\",\"completedEffects\":[\"cookieText\"]}}"
    }
    func cancel(_ task: String) throws -> String { "{\"ok\":true}" }
    func closeSession(_ session: String) throws -> String { "{\"ok\":true}" }
}

@MainActor final class LegadoCookieTextAPITests: XCTestCase {
    func testTextCookieAccessRequiresExplicitEmbeddingOptionsAndPreservesDefaultEncoding() async throws {
        let transport = CookieTextAPITransport()
        let runtime = LegadoRuntime(configuration: .init(javaHome: URL(fileURLWithPath: "/unused"), classPath: []), host: UnsupportedLegadoHost(), transport: transport)
        let session = try await runtime.createSession(sourceJSON: "{\"bookSourceUrl\":\"https://owned.invalid\"}",
            options: .init(httpTransport: .jvmOkHttp, stateOwner: "explicit-owner", sourceMode: .originalTraditional, cookieAccess: .appOwnerText))
        XCTAssertEqual(session.sourceMode, .originalTraditional)
        let raw = try XCTUnwrap(transport.options)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: String])
        XCTAssertEqual(encoded, ["httpTransport": "jvm-okhttp", "stateOwner": "explicit-owner", "sourceMode": "original-traditional", "cookieAccess": "app-owner-text"])
        let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(LegadoSessionOptions(httpTransport: .jvmOkHttp))) as? [String: String]
        XCTAssertEqual(defaults, ["httpTransport": "jvm-okhttp"])
    }
    func testPartialSequentialEffectMetadataSurvivesPublicExecutionAndOldErrorsDecode() async throws {
        let transport = CookieTextAPITransport()
        let runtime = LegadoRuntime(configuration: .init(javaHome: URL(fileURLWithPath: "/unused"), classPath: []), host: UnsupportedLegadoHost(), transport: transport)
        do {
            _ = try await runtime.execute(session: .init(id: "text-owned"), operation: "search", requestJSON: "{}", taskID: "partial-text")
            XCTFail("The later owner failure must remain an error")
        } catch let error as LegadoRuntimeError {
            XCTAssertEqual(error.code, "STATE_IO"); XCTAssertEqual(error.completedEffects, ["cookieText"])
            XCTAssertTrue(error.message.contains("Cookie text was committed"))
        }
        let old = try JSONDecoder().decode(LegadoRuntimeError.self, from: Data("{\"code\":\"STATE_IO\",\"message\":\"old error\"}".utf8))
        XCTAssertNil(old.completedEffects)
        XCTAssertEqual(old, LegadoRuntimeError(code: "STATE_IO", message: "old error"))
    }
}
