import XCTest
import os
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
        case "contentBatch": result = ["book": book, "missingChapters": Array((input["chapters"] as? [Any] ?? []).suffix(1))]
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
    func testDismissPersistenceUsesPureOperationAndKeepsRejectedAndCommittedFactsDistinct() async throws {
        let transport = OriginalAPITransport(); let runtime = runtime(transport); let source = try await session(runtime)
        transport.respondNext(#"{"ok":true,"result":{"credentialsStored":true,"credentialsCleared":false,"executed":false},"completedEffects":["sourceLoginInfoMayCommit","sourceLoginInfoCommitted"]}"#)
        let value = try await runtime.persistLoginInfoOriginal(session: source,
            credentials: ["hidden": "synthetic-hidden", "password": ""], taskID: "pure-dismiss")
        XCTAssertTrue(value.credentialsStored); XCTAssertFalse(value.credentialsCleared); XCTAssertFalse(value.executed)
        let call = try XCTUnwrap(transport.calls.last)
        XCTAssertEqual(call.operation, "persistLoginInfo"); XCTAssertEqual(call.task, "pure-dismiss")
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(call.request.utf8)) as? [String: Any])
        XCTAssertEqual(request["credentials"] as? [String: String], ["hidden": "synthetic-hidden", "password": ""])
        XCTAssertNil(request["action"]); XCTAssertNil(request["loginJS"])
        transport.respondNext(#"{"ok":true,"result":{"credentialsStored":false,"credentialsCleared":false,"executed":false}}"#)
        let rejected = try await runtime.persistLoginInfoOriginal(session: source, credentials: ["hidden": "new"])
        XCTAssertFalse(rejected.credentialsStored); XCTAssertFalse(rejected.credentialsCleared); XCTAssertFalse(rejected.executed)
        transport.respondNext(#"{"ok":false,"error":{"code":"CANCELLED","message":"cancelled after accepted mutation","completedEffects":["sourceLoginInfoMayCommit","sourceLoginInfoCommitted"]}}"#)
        do {
            _ = try await runtime.persistLoginInfoOriginal(session: source, credentials: [:])
            XCTFail("Cancellation must not masquerade as a successful close")
        } catch let failure as LegadoRuntimeError {
            XCTAssertEqual(failure.code, "CANCELLED")
            XCTAssertEqual(failure.completedEffects, ["sourceLoginInfoMayCommit", "sourceLoginInfoCommitted"])
        }
    }

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
    func testTypedBatchReturnsMissingChapterIdentitiesAndDoesNotGrantSaves() async throws {
        let transport = OriginalAPITransport(); let runtime = runtime(transport); let source = try await session(runtime)
        let book = OriginalAPITransport.book()
        let a = OriginalAPITransport.chapter()
        let b = LegadoOriginalChapter(bookURL: book.bookURL, url: a.url, index: 1, title: "Second same URL", baseURL: a.baseURL)
        let value = try await runtime.contentBatchOriginal(session: source, book: book, chapters: [a, b], taskID: "typed-batch")
        XCTAssertEqual(value.missingChapters, [b]); XCTAssertEqual(value.book, book)
        let call = try XCTUnwrap(transport.calls.first)
        XCTAssertEqual(call.operation, "contentBatch"); XCTAssertEqual(call.task, "typed-batch"); XCTAssertFalse(call.main)
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(call.request.utf8)) as? [String: Any])
        XCTAssertNil(input["needSave"]); XCTAssertNil(input["owner"]); XCTAssertEqual((input["chapters"] as? [Any])?.count, 2)
        do { _ = try await runtime.contentBatchOriginal(session: source, book: book, chapters: [a,a]); XCTFail("Duplicate indexes must reject before transport") }
        catch let error as LegadoRuntimeError { XCTAssertEqual(error.code, "INVALID_ARGUMENT") }
        transport.respondNext("{\"ok\":false,\"error\":{\"code\":\"INVALID_STATE_OWNER\",\"message\":\"revoked\",\"completedEffects\":[\"chapterContentCommitted\"]}}")
        do { _ = try await runtime.contentBatchOriginal(session: source, book: book, chapters: [a,b]); XCTFail("Host failure is not missing success") }
        catch let error as LegadoRuntimeError { XCTAssertEqual(error.code, "INVALID_STATE_OWNER"); XCTAssertEqual(error.completedEffects, ["chapterContentCommitted"]) }
    }
    func testTypedBusinessApiDoesNotSelectTheExistingRoute() async throws {
        let transport = OriginalAPITransport(); let runtime = runtime(transport)
        do { _ = try await runtime.searchOriginal(session: .init(id: "existing"), key: "owned"); XCTFail("Expected explicit mode gate") }
        catch let error as LegadoRuntimeError { XCTAssertEqual(error.code, "UNSUPPORTED_CAPABILITY") }
        XCTAssertTrue(transport.calls.isEmpty)
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
        // The embedding must retain exact completion facts through its later
        // session close or final App publication; they are not DTO authority.
        let observed = OSAllocatedUnfairLock(initialState: [String]())
        transport.respondNext(#"{"ok":true,"result":{"books":[]},"completedEffects":["previewTOCMayCommit","previewTOCCommitted"]}"#)
        let success = try await runtime.searchOriginal(session: source, key: "owned",
            onReportedEffects: { effects in observed.withLock { $0 = effects } })
        XCTAssertTrue(success.books.isEmpty)
        XCTAssertEqual(observed.withLock { $0 }, ["previewTOCMayCommit", "previewTOCCommitted"])
        transport.respondNext(#"{"ok":true,"result":{"books":[{"name":"missing identity"}]},"completedEffects":["chapterContentMayCommit"]}"#)
        do { _ = try await runtime.searchOriginal(session: source, key: "owned"); XCTFail("DTO failure cannot erase prior effects") }
        catch let error as LegadoRuntimeError {
            XCTAssertEqual(error.code, "invalid_response"); XCTAssertEqual(error.completedEffects, ["chapterContentMayCommit"])
        }
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
    func testOriginalLoginUIEventsPreserveOrderNullResetAndFailureFacts() async throws {
        let transport = OriginalAPITransport(); let runtime = runtime(transport); let source = try await session(runtime)
        let events = [
            LegadoOriginalLoginUIEvent(taskID: "ui-events", sequence: 1, kind: .updateData,
                entries: [.init(key: "nullable", value: nil), .init(key: "empty", value: "")]),
            .init(taskID: "ui-events", sequence: 2, kind: .updateData, entries: []),
            .init(taskID: "ui-events", sequence: 3, kind: .updateData),
            .init(taskID: "ui-events", sequence: 4, kind: .render, deltaUp: false)
        ]
        func encoded(_ value: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        }
        let raw = OriginalAPITransport.object(events)
        let observed = OSAllocatedUnfairLock(initialState: [LegadoOriginalLoginUIEvent]())
        transport.respondNext(try encoded(["ok": true, "result": ["executed": true, "loginUIEvents": raw], "loginUIEvents": raw]))
        let value = try await runtime.loginActionOriginal(session: source, action: "synthetic", credentials: [:], taskID: "ui-events",
            onReportedLoginUIEvents: { events in observed.withLock { $0 = events } })
        XCTAssertEqual(value.loginUIEvents, events); XCTAssertEqual(observed.withLock { $0 }, events)
        XCTAssertEqual(value.loginUIEvents?[0].entries?[0].value, nil)
        XCTAssertEqual(value.loginUIEvents?[1].entries, []); XCTAssertNil(value.loginUIEvents?[2].entries)
        transport.respondNext(try encoded(["ok": false, "error": ["code": "SCRIPT_ERROR", "message": "safe failure",
            "loginUIEvents": raw, "completedEffects": ["sourceStateCommitted"],
            "secondaryFailures": [["code": "STATE_IO", "message": "safe cleanup failure"]]]]))
        do {
            _ = try await runtime.loginActionOriginal(session: source, action: "synthetic", credentials: [:], taskID: "ui-events",
                onReportedLoginUIEvents: { events in observed.withLock { $0 = events } })
            XCTFail("A callback cannot convert the script error to success")
        } catch let failure as LegadoRuntimeError {
            XCTAssertEqual(failure.code, "SCRIPT_ERROR"); XCTAssertEqual(failure.loginUIEvents, events)
            XCTAssertEqual(failure.completedEffects, ["sourceStateCommitted"])
            XCTAssertEqual(failure.secondaryFailures?.map(\.code), ["STATE_IO"])
            XCTAssertEqual(observed.withLock { $0 }, events)
        }
    }

    func testLoginUIEventsRejectWrongTaskOrSequenceBeforePublicationAndKeepDtoFailureFacts() async throws {
        let transport = OriginalAPITransport(); let runtime = runtime(transport); let source = try await session(runtime)
        let observed = OSAllocatedUnfairLock(initialState: [LegadoOriginalLoginUIEvent]())
        for raw in [
            #"{"ok":true,"result":{"executed":true},"loginUIEvents":[{"taskId":"another-task","sequence":1,"kind":"updateData"}]}"#,
            #"{"ok":true,"result":{"executed":true},"loginUIEvents":[{"taskId":"dto-event","sequence":2,"kind":"updateData"}]}"#,
            #"{"ok":true,"result":{"executed":true},"loginUIEvents":[{"taskId":"dto-event","sequence":1,"kind":"render","deltaUp":true}]}"#
        ] {
            transport.respondNext(raw)
            do {
                _ = try await runtime.loginActionOriginal(session: source, action: "synthetic", credentials: [:], taskID: "dto-event",
                    onReportedLoginUIEvents: { events in observed.withLock { $0 = events } })
                XCTFail("Untrusted task events must reject")
            } catch let failure as LegadoRuntimeError { XCTAssertEqual(failure.code, "invalid_response") }
            XCTAssertTrue(observed.withLock { $0.isEmpty })
        }
        transport.respondNext(#"{"ok":true,"result":{"executed":"invalid-bool"},"loginUIEvents":[{"taskId":"dto-event","sequence":1,"kind":"updateData"}]}"#)
        do {
            _ = try await runtime.loginActionOriginal(session: source, action: "synthetic", credentials: [:], taskID: "dto-event",
                onReportedLoginUIEvents: { events in observed.withLock { $0 = events } })
            XCTFail("DTO decoding failure cannot erase accepted callbacks")
        } catch let failure as LegadoRuntimeError {
            XCTAssertEqual(failure.code, "invalid_response"); XCTAssertEqual(failure.loginUIEvents?.count, 1)
            XCTAssertEqual(failure.loginUIEvents, observed.withLock { $0 })
        }
    }

    func testCallbackOnlyFactsSurviveCancellationAfterTerminalResponseWithoutBecomingPlainCancellation() async throws {
        let transport = OriginalAPITransport(); let runtime = runtime(transport); let source = try await session(runtime)
        let running = OSAllocatedUnfairLock(initialState: Optional<Task<Void, Never>>.none)
        let failureBox = OSAllocatedUnfairLock(initialState: Optional<LegadoRuntimeError>.none)
        transport.respondNext(#"{"ok":true,"result":{"executed":true,"loginUIEvents":[{"taskId":"late-event","sequence":1,"kind":"updateData"}]},"loginUIEvents":[{"taskId":"late-event","sequence":1,"kind":"updateData"}]}"#)
        let task = Task {
            do {
                _ = try await runtime.loginActionOriginal(session: source, action: "synthetic", credentials: [:], taskID: "late-event",
                    onReportedLoginUIEvents: { _ in running.withLock { $0?.cancel() } })
                XCTFail("Late cancellation must remain a failure")
            } catch let failure as LegadoRuntimeError { failureBox.withLock { $0 = failure } }
            catch { XCTFail("Accepted callbacks require a typed failure, not a plain cancellation") }
        }
        running.withLock { $0 = task }
        await task.value
        running.withLock { $0 = nil }
        let failure = try XCTUnwrap(failureBox.withLock { $0 })
        XCTAssertEqual(failure.code, "CANCELLED"); XCTAssertEqual(failure.loginUIEvents?.count, 1)
        XCTAssertNil(failure.completedEffects)
    }

}
