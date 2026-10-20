import Foundation
import XCTest
@testable import LegadoRuntime

private final class ExploreAPITransport: LegadoRuntimeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [(String, String)] = []
    var calls: [(String, String)] { lock.withLock { requests } }
    func start(_ configuration: LegadoRuntime.Configuration) throws {}
    func createSession(_ source: String) throws -> String { "{\"ok\":true,\"sessionId\":\"explore\"}" }
    func execute(_ session: String, _ task: String, _ operation: String, _ request: String) throws -> String {
        lock.withLock { requests.append((operation, request)) }
        if operation == "explore" { return "{\"ok\":true,\"result\":{\"books\":[]}}" }
        return "{\"ok\":true,\"result\":{\"infoMap\":{\"genre\":\"fiction\"},\"needSave\":true,\"result\":null}}"
    }
    func cancel(_ task: String) throws -> String { "{\"ok\":true}" }
    func closeSession(_ session: String) throws -> String { "{\"ok\":true}" }
}

@MainActor final class LegadoExploreAPITests: XCTestCase {
    func testExploreUsesOriginalPublicActionAndPreservesExplicitNullPage() async throws {
        let transport = ExploreAPITransport()
        let runtime = LegadoRuntime(configuration: .init(javaHome: URL(fileURLWithPath: "/unused"), classPath: []), host: UnsupportedLegadoHost(), transport: transport)
        let session = LegadoSourceSession(id: "explore", sourceMode: .originalTraditional)
        let result = try await runtime.exploreOriginal(session: session, url: "https://owned.invalid/list", page: nil)
        XCTAssertTrue(result.books.isEmpty)
        let call = try XCTUnwrap(transport.calls.first)
        XCTAssertEqual(call.0, "explore")
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(call.1.utf8)) as? [String: Any])
        XCTAssertEqual(input["url"] as? String, "https://owned.invalid/list")
        XCTAssertTrue(input["page"] is NSNull)
        XCTAssertEqual(Set(input.keys), ["url", "page", "timeoutMs"])
        do { _ = try await runtime.exploreOriginal(session: .init(id: "old-default"), url: "https://owned.invalid"); XCTFail("Original mode must be explicit") }
        catch let error as LegadoRuntimeError { XCTAssertEqual(error.code, "UNSUPPORTED_CAPABILITY") }
        XCTAssertEqual(transport.calls.count, 1)
    }
    func testExplicitContextLifecycleUsesTypedBusinessDtoAndDoesNotExposeScopeAuthority() async throws {
        let transport = ExploreAPITransport()
        let runtime = LegadoRuntime(configuration: .init(javaHome: URL(fileURLWithPath: "/unused"), classPath: []), host: UnsupportedLegadoHost(), transport: transport)
        let session = LegadoSourceSession(id: "explore", sourceMode: .originalTraditional)
        let open = try await runtime.openExploreContextOriginal(session: session)
        XCTAssertEqual(open.infoMap, ["genre": "fiction"]); XCTAssertTrue(open.needSave); XCTAssertNil(open.result)
        _ = try await runtime.evaluateExploreContextOriginal(session: session, script: "infoMap.save(); 'done'")
        _ = try await runtime.savePendingExploreContextOriginal(session: session)
        XCTAssertEqual(transport.calls.map { $0.0 }, ["exploreContext", "exploreContext", "exploreContext"])
        for (index, call) in transport.calls.enumerated() {
            let input = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(call.1.utf8)) as? [String: Any])
            XCTAssertEqual(input["action"] as? String, ["open", "evaluate", "savePending"][index])
            XCTAssertEqual(input["script"] as? String, index == 1 ? "infoMap.save(); 'done'" : nil)
            XCTAssertNil(input["scope"]); XCTAssertNil(input["owner"])
        }
    }
}
