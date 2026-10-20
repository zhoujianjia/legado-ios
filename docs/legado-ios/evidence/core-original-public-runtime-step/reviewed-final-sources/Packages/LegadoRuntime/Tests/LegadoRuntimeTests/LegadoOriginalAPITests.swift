import XCTest
@testable import LegadoRuntime

private final class OriginalAPITransport: LegadoRuntimeTransport, @unchecked Sendable {
    struct Call: Sendable { let task: String; let operation: String; let request: String; let main: Bool }
    private let lock = NSLock()
    private var savedCalls: [Call] = []
    private var savedOptions: String?
    private var nextResponse: String?
    var calls: [Call] { lock.withLock { savedCalls } }
    var options: String? { lock.withLock { savedOptions } }
    func respondNext(_ response: String) { lock.withLock { nextResponse = response } }
    func start(_ configuration: LegadoRuntime.Configuration) throws {}
    func createSession(_ source: String) throws -> String { "{\"ok\":true,\"sessionId\":\"owned\"}" }
    func createSession(_ source: String, optionsJSON: String) throws -> String {
        lock.withLock { savedOptions = optionsJSON }
        return "{\"ok\":true,\"sessionId\":\"owned\"}"
    }
    func execute(_ session: String, _ task: String, _ operation: String, _ request: String) throws -> String {
        let configured = lock.withLock {
            savedCalls.append(Call(task: task, operation: operation, request: request, main: Thread.isMainThread))
            let response = nextResponse; nextResponse = nil; return response
        }
        if let configured { return configured }
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any])
        let book = input["book"] ?? Self.object(Self.book())
        let result: [String: Any]
        switch operation {
        case "search": result = ["books": [book]]
        case "details": result = ["book": book]
        case "toc": result = ["book": book, "chapters": [Self.object(Self.chapter())]]
        case "content": result = ["book": book, "chapter": input["chapter"] ?? Self.object(Self.chapter()), "content": "owned text"]
        default: throw LegadoRuntimeError(code: "fixture_operation", message: operation)
        }
        let bytes = try JSONSerialization.data(withJSONObject: ["ok": true, "taskId": task, "result": result])
        return String(decoding: bytes, as: UTF8.self)
    }
    func cancel(_ task: String) throws -> String { "{\"ok\":true}" }
    func closeSession(_ session: String) throws -> String { "{\"ok\":true}" }
    static func object<Value: Encodable>(_ value: Value) -> Any {
        // Owned valid fixture values only; any encoding failure should fail the fixture.
        do { return try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
        catch { XCTFail("Fixture encoding failed: \(error)"); return NSNull() }
    }
    static func book() -> LegadoOriginalBook {
        var value = LegadoOriginalBook(bookURL: "https://owned.invalid/book", origin: "https://owned.invalid", name: "阅读", author: "Author", tocURL: "https://owned.invalid/toc")
        value.variable = "{\"owned\":\"kept\"}"; value.infoHTML = "<h1>owned</h1>"; value.reverseToc = true
        return value
    }
    static func chapter() -> LegadoOriginalChapter {
        var value = LegadoOriginalChapter(bookURL: "https://owned.invalid/book", url: "/chapter", index: 0, title: "One", baseURL: "https://owned.invalid/toc")
        value.variable = "{\"chapter\":\"kept\"}"; value.imgURL = "https://owned.invalid/image"; return value
    }
}

@MainActor final class LegadoOriginalAPITests: XCTestCase {
    private func runtime(_ transport: OriginalAPITransport) -> LegadoRuntime {
        LegadoRuntime(configuration: .init(javaHome: URL(fileURLWithPath: "/unused"), classPath: []), host: UnsupportedLegadoHost(), transport: transport)
    }
    private func session(_ runtime: LegadoRuntime) async throws -> LegadoSourceSession {
        try await runtime.createSession(sourceJSON: "{\"bookSourceUrl\":\"https://owned.invalid\",\"ruleSearch\":{}}",
            options: .init(httpTransport: .jvmOkHttp, stateOwner: "embedding-owner", sourceMode: .originalTraditional))
    }
    func testConfiguredTypedFourStageChainKeepsBusinessIdentitiesAndExplicitNoSave() async throws {
        let transport = OriginalAPITransport(); let runtime = runtime(transport); let source = try await session(runtime)
        XCTAssertEqual(source.sourceMode, .originalTraditional)
        let search = try await runtime.searchOriginal(session: source, key: "阅读", page: 2, taskID: "typed-search")
        let detail = try await runtime.detailsOriginal(session: source, book: XCTUnwrap(search.books.first), taskID: "typed-detail")
        let toc = try await runtime.chaptersOriginal(session: source, book: detail.book, runPreUpdateJs: true, taskID: "typed-toc")
        let content = try await runtime.contentOriginal(session: source, book: toc.book, chapter: XCTUnwrap(toc.chapters.first), nextChapterURL: "/next", taskID: "typed-content")
        XCTAssertEqual(content.book.bookURL, search.books.first?.bookURL); XCTAssertEqual(content.chapter.bookURL, content.book.bookURL)
        XCTAssertEqual(content.book.variable, "{\"owned\":\"kept\"}"); XCTAssertEqual(content.chapter.variable, "{\"chapter\":\"kept\"}")
        XCTAssertEqual(content.book.infoHTML, "<h1>owned</h1>"); XCTAssertTrue(content.book.reverseToc); XCTAssertEqual(content.content, "owned text")
        XCTAssertEqual(transport.calls.map(\.operation), ["search", "details", "toc", "content"])
        XCTAssertTrue(transport.calls.allSatisfy { !$0.main })
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(transport.calls.last).request.utf8)) as? [String: Any])
        XCTAssertEqual(request["needSave"] as? Bool, false); XCTAssertEqual(request["nextChapterUrl"] as? String, "/next")
        let options = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(transport.options).utf8)) as? [String: String])
        XCTAssertEqual(options["sourceMode"], "original-traditional"); XCTAssertEqual(options["stateOwner"], "embedding-owner")
    }
    func testTypedBusinessApiDoesNotSelectTheExistingRoute() async throws {
        let transport = OriginalAPITransport(); let runtime = runtime(transport)
        do { _ = try await runtime.searchOriginal(session: .init(id: "existing"), key: "owned"); XCTFail("Expected explicit mode gate") }
        catch let error as LegadoRuntimeError { XCTAssertEqual(error.code, "UNSUPPORTED_CAPABILITY") }
        XCTAssertTrue(transport.calls.isEmpty())
        let options = try JSONSerialization.jsonObject(with: JSONEncoder().encode(LegadoSessionOptions(httpTransport: .jvmOkHttp))) as? [String: String]
        XCTAssertEqual(options, ["httpTransport": "jvm-okhttp"])
    }
    func testOriginalTypedErrorsAndIncompatibleDtosStayErrors() async throws {
        let transport = OriginalAPITransport(); let runtime = runtime(transport); let source = try await session(runtime)
        transport.respondNext("{\"ok\":false,\"error\":{\"code\":\"UNSUPPORTED_CAPABILITY\",\"message\":\"Cookie owner missing\"}}")
        do { _ = try await runtime.searchOriginal(session: source, key: "owned"); XCTFail("Expected host error") }
        catch let error as LegadoRuntimeError { XCTAssertEqual(error.code, "UNSUPPORTED_CAPABILITY") }
        transport.respondNext("{\"ok\":true,\"result\":{\"books\":[{\"name\":\"missing identity\"}]}}")
        do { _ = try await runtime.searchOriginal(session: source, key: "owned"); XCTFail("Expected DTO error") }
        catch let error as LegadoRuntimeError { XCTAssertEqual(error.code, "invalid_response") }
    }
    func testNullPageAndUtf8RequestBudgetAreExplicit() async throws {
        let transport = OriginalAPITransport(); let runtime = runtime(transport); let source = try await session(runtime)
        _ = try await runtime.searchOriginal(session: source, key: "owned", page: nil)
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(transport.calls.first).request.utf8)) as? [String: Any])
        XCTAssertTrue(request["page"] is NSNull)
        do { _ = try await runtime.searchOriginal(session: source, key: String(repeating: "阅", count: 1_400_000)); XCTFail("Expected UTF-8 budget error") }
        catch let error as LegadoRuntimeError { XCTAssertEqual(error.code, "PAYLOAD_TOO_LARGE") }
        XCTAssertEqual(transport.calls.count, 1)
    }
    func testBusinessCodingPreservesOriginalNamesWithoutEnvironmentOrAppUuid() throws {
        let book = OriginalAPITransport.book(); let chapter = OriginalAPITransport.chapter()
        let encodedBook = try JSONEncoder().encode(book); let encodedChapter = try JSONEncoder().encode(chapter)
        XCTAssertEqual(try JSONDecoder().decode(LegadoOriginalBook.self, from: encodedBook), book)
        XCTAssertEqual(try JSONDecoder().decode(LegadoOriginalChapter.self, from: encodedChapter), chapter)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedChapter) as? [String: Any])
        XCTAssertEqual(raw["bookUrl"] as? String, book.bookURL); XCTAssertEqual(raw["imgUrl"] as? String, chapter.imgURL)
        XCTAssertNil(raw["environment"]); XCTAssertNil(raw["id"]); XCTAssertNil(raw["variableMap"])
    }
}
