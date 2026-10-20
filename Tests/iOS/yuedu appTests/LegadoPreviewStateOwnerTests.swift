import Foundation
import LegadoRuntime
import Testing
@testable import yuedu_app

private struct PreviewFixtureNoSourceState: LegadoOwnedStateBacking {
    func read(sourceURL: String, domain: LegadoOwnedStateDomain, fields: Set<String>) throws -> LegadoOwnedStateSnapshot {
        throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY", message: "This fixture grants only real context files")
    }
    func commit(sourceURL: String, domain: LegadoOwnedStateDomain, expected: LegadoOwnedStateSnapshot,
                changes: [String: Data?]) throws -> Bool {
        throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY", message: "This fixture grants only real context files")
    }
}

/// The executor replaces the unavailable native engine, not the state owner. Every
/// entity read/commit below dispatches the production Host into actual owned files.
private actor PreviewFixtureExecutor: LegadoOriginalPreviewExecuting {
    enum Mode: Sendable, Equatable {
        case normal, failAfterCommit, staleCAS, changeAfterSeal, waitBeforeCommit, failWrite, scopeChecks, unicodeURLs
        case unicodeRawSmallMap, unicodeLargeAccess, unicodeCrossCompartment
    }
    let host = LegadoPersistentStateHost(backing: PreviewFixtureNoSourceState())
    let directory: URL
    let entered: AsyncStream<Bool>
    private let event: AsyncStream<Bool>.Continuation
    private var gate: CheckedContinuation<Void, Never>?
    private var mode: Mode = .normal
    private var calls: [String] = []
    private var lastOwner: String?
    private var lastWire: String?
    private var activeTaskID = ""
    private var searchVariable: String?
    private var rawSmallCommit = "{}"
    private var unicodeNames = ("\u{00e9}", "e\u{0301}")
    private var chapterLiteral: String?
    private(set) var staleWasRejected = false
    private(set) var scopeWasRejected = false
    let large = String(repeating: "L", count: 10_000)

    init(directory: URL) {
        self.directory = directory
        let pair = AsyncStream<Bool>.makeStream(); entered = pair.stream; event = pair.continuation
    }
    func setMode(_ value: Mode) { mode = value }
    func setSearchVariable(_ value: String?) { searchVariable = value }
    func setRawSmallCommit(_ value: String) { rawSmallCommit = value; mode = .unicodeRawSmallMap }
    func setUnicodeNames(_ first: String, _ second: String, crossCompartment: Bool) {
        unicodeNames = (first, second); mode = crossCompartment ? .unicodeCrossCompartment : .unicodeLargeAccess
    }
    func setChapterLiteral(_ value: String?) { chapterLiteral = value }
    func operations() -> [String] { calls }
    func openGate() { gate?.resume(); gate = nil }
    func oldGrantIsRejected() async throws -> Bool {
        guard let lastOwner, let lastWire else { return false }
        do { _ = try await read(owner: lastOwner, keys: [lastWire]); return false }
        catch let error as LegadoRuntimeError { return error.code == "INVALID_STATE_OWNER" }
    }
    func execute(sourceJSON: String, sourceURL: String, sourceRevision: String,
                 grant: OriginalRuntimePreviewGrant?, operation: LegadoOriginalPreviewOperation,
                 deadline: Date) async throws -> LegadoOriginalPreviewResult {
        if case .search = operation {
            calls.append("search")
            var book = LegadoOriginalBook(bookURL: "https://preview-owned.invalid/book", origin: sourceURL,
                name: "Owned preview", author: "Fixture", tocURL: "https://preview-owned.invalid/book/toc")
            if let searchVariable { book.variable = searchVariable }
            else { book.variable = try json(["seed": "kept"]) }
            return .search([book])
        }
        let grant = try #require(grant)
        let owner = try await host.bindPreview(grant: grant)
        activeTaskID = grant.taskID
        lastOwner = owner
        do {
            let result: LegadoOriginalPreviewResult
            switch operation {
            case .search: throw LegadoRuntimeError(code: "INVALID_ARGUMENT", message: "Unexpected search state")
            case .explore, .openExploreContext, .evaluateExploreContext, .savePendingExploreContext, .sourceCallback:
                throw LegadoRuntimeError(code: "INVALID_ARGUMENT", message: "This entity fixture does not execute exploration contexts")
            case .details(var book):
                calls.append("details")
                let small = try key(grant, chapter: nil); let big = try key(grant, chapter: nil, large: "large")
                lastWire = small
                let before = try await read(owner: owner, keys: [small, big])
                var values = try map(before, key: small) ?? [:]
                if mode == .unicodeRawSmallMap {
                    _ = try await commit(owner: owner, read: before, changes: [small: Data(rawSmallCommit.utf8).base64EncodedString()])
                    throw LegadoRuntimeError(code: "FIXTURE_ERROR", message: "Ambiguous raw small names were accepted")
                }
                if mode == .unicodeLargeAccess || mode == .unicodeCrossCompartment {
                    let first = try key(grant, chapter: nil, large: unicodeNames.0)
                    let second = try key(grant, chapter: nil, large: unicodeNames.1)
                    let firstRead = try await read(owner: owner, keys: [first])
                    #expect(try await commit(owner: owner, read: firstRead, changes: [first: Data("first".utf8).base64EncodedString()]))
                    if mode == .unicodeCrossCompartment {
                        let next = try await read(owner: owner, keys: [small])
                        _ = try await commit(owner: owner, read: next, changes: [small: try data([unicodeNames.1: "cross"]).base64EncodedString()])
                    } else {
                        // Alias GET must reject, while a second exact-name GET/PUT still
                        // uses the genuine file owner and preserves the stored name bytes.
                        do { _ = try await read(owner: owner, keys: [second]); Issue.record("Alias get must not return another Java name") }
                        catch let error as LegadoRuntimeError { #expect(error.code == "UNSUPPORTED_CAPABILITY") }
                        let wrongWireProof = try await read(owner: owner, keys: [first])
                        let revision = try #require(wrongWireProof["revision"] as? NSNumber)
                        let quote: (String) throws -> String = { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
                        let rawRequest = "{\"owner\":" + (try quote(owner)) + ",\"revision\":" + revision.stringValue
                            + ",\"changes\":{" + (try quote(first)) + ":\"b25l\"," + (try quote(second)) + ":\"dHdv\"}}"
                        do {
                            _ = try await host.dispatch(.init(taskID: activeTaskID, operation: "state.commit", requestJSON: rawRequest))
                            Issue.record("Raw wire names must not fold before preview validation")
                        } catch let error as LegadoRuntimeError { #expect(error.code == "UNSUPPORTED_CAPABILITY") }
                        do {
                            _ = try await commit(owner: owner, read: wrongWireProof, changes: [second: Data("must not alias".utf8).base64EncodedString()])
                            Issue.record("A canonical alias cannot borrow an exact read-wire proof")
                        } catch let error as LegadoRuntimeError { #expect(error.code == "UNSUPPORTED_CAPABILITY") }
                        let next = try await read(owner: owner, keys: [first])
                        let payload = try #require((next["values"] as? [String: String])?[first])
                        #expect(String(data: try #require(Data(base64Encoded: payload)), encoding: .utf8) == "first")
                        #expect(try await commit(owner: owner, read: next, changes: [first: Data("updated".utf8).base64EncodedString()]))
                        _ = try await read(owner: owner, keys: [second])
                    }
                    throw LegadoRuntimeError(code: "FIXTURE_ERROR", message: "Ambiguous variable compartment was accepted")
                }
                if mode == .waitBeforeCommit {
                    event.yield(true)
                    await withCheckedContinuation { gate = $0 }
                }
                if mode == .scopeChecks {
                    let wrong = try key(grant, chapter: nil, bookURL: grant.bookURL + "/other")
                    do { _ = try await read(owner: owner, keys: [wrong]); Issue.record("A preview must not grant another book") }
                    catch let error as LegadoRuntimeError { scopeWasRejected = error.code == "UNSUPPORTED_CAPABILITY" }
                    let chapter = try key(grant, chapter: grant.bookURL + "/chapter")
                    do { _ = try await read(owner: owner, keys: [small, chapter]); Issue.record("Details must not grant chapters") }
                    catch let error as LegadoRuntimeError { scopeWasRejected = scopeWasRejected && error.code == "UNSUPPORTED_CAPABILITY" }
                    do {
                        _ = try await call("state.read", ["owner": owner, "keys": [small]], taskID: "foreign-preview-task")
                        Issue.record("Another task must not borrow a preview owner")
                    } catch let error as LegadoRuntimeError { scopeWasRejected = scopeWasRejected && error.code == "INVALID_STATE_OWNER" }
                }
                values["persisted"] = "details"
                let staleRead: [String: Any]?
                if mode == .staleCAS { staleRead = try await read(owner: owner, keys: [small, big]) }
                else { staleRead = nil }
                if mode == .failWrite {
                    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
                }
                defer {
                    if mode == .failWrite {
                        do { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
                        catch { Issue.record("Owned permissions could not be restored: \(error)") }
                    }
                }
                let committed = try await commit(owner: owner, read: before, changes: [small: try data(values).base64EncodedString(), big: Data(large.utf8).base64EncodedString()])
                #expect(committed)
                if let staleRead {
                    staleWasRejected = try await !commit(owner: owner, read: staleRead, changes: [small: Data("{}".utf8).base64EncodedString()])
                }
                if mode == .failAfterCommit { throw LegadoRuntimeError(code: "RULE_ERROR", message: "Owned failure after accepted state commit") }
                // A real original direct setter is only in the returned DTO. It must
                // survive final CAS without deleting the independently stored big value.
                values["direct"] = "setter"
                book.variable = try json(values)
                result = .details(book)
            case .toc(var book, _):
                calls.append("toc")
                let bookKey = try key(grant, chapter: nil)
                book.variable = try map(await read(owner: owner, keys: [bookKey]), key: bookKey).map { try json($0) }
                let urls = mode == .unicodeURLs ? [book.bookURL + "/\u{00E9}", book.bookURL + "/e\u{0301}"] : [book.bookURL + "/chapter/1"]
                var chapters: [LegadoOriginalChapter] = []
                for (index, url) in urls.enumerated() {
                    var chapter = LegadoOriginalChapter(bookURL: book.bookURL, url: url,
                        index: Int32(index), title: "Owned chapter", baseURL: book.tocURL)
                    let small = try key(grant, chapter: chapter.url)
                    let before = try await read(owner: owner, keys: [small]) // New chapter constructor restoreVariables.
                    var values = try map(before, key: small) ?? [:]; values["chapter"] = "toc"
                    values["ownedIndex"] = String(index)
                    if let chapterLiteral { values["raw"] = chapterLiteral }
                    #expect(try await commit(owner: owner, read: before, changes: [small: try data(values).base64EncodedString()]))
                    chapter.variable = try json(values)
                    chapters.append(chapter)
                }
                result = .toc(book, chapters)
            case .content(var book, var chapter, _):
                calls.append("content")
                let small = try key(grant, chapter: chapter.url)
                let before = try await read(owner: owner, keys: [small])
                var values = try map(before, key: small) ?? [:]; values["content"] = "yes"
                #expect(try await commit(owner: owner, read: before, changes: [small: try data(values).base64EncodedString()]))
                chapter.variable = try json(values)
                let bookKey = try key(grant, chapter: nil)
                book.variable = try map(await read(owner: owner, keys: [bookKey]), key: bookKey).map { try json($0) }
                result = .content(book, chapter, "Owned preview body\nSecond line")
            }
            try grant.sealExecution(deadline: deadline)
            if mode == .changeAfterSeal {
                let path = directory.appendingPathComponent(grant.recordID + ".json")
                var record = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
                var book = try #require(record["book"] as? [String: Any])
                book["variable"] = try json(["foreign": "must remain"]); record["book"] = book
                record["revision"] = (try #require(record["revision"] as? NSNumber)).uint64Value + 1
                try data(record).write(to: path, options: .atomic)
            }
            await host.revoke(owner: owner)
            return result
        } catch {
            await host.revoke(owner: owner)
            throw error
        }
    }
    private func key(_ grant: OriginalRuntimePreviewGrant, chapter: String?, large: String? = nil, bookURL: String? = nil) throws -> String {
        var parts = [grant.sourceURL, large == nil ? "variables" : "big-variable", chapter == nil ? "book" : "chapter", bookURL ?? grant.bookURL, chapter ?? ""]
        if let large { parts.append(large) }
        return try json(parts)
    }
    private func call(_ operation: String, _ input: [String: Any], taskID: String? = nil) async throws -> [String: Any] {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let value = try await host.dispatch(.init(taskID: taskID ?? activeTaskID, operation: operation, requestJSON: try json(input)))
        return try #require(try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
    }
    private func read(owner: String, keys: [String]) async throws -> [String: Any] {
        try await call("state.read", ["owner": owner, "keys": keys])
    }
    private func commit(owner: String, read: [String: Any], changes: [String: Any]) async throws -> Bool {
        let result = try await call("state.commit", ["owner": owner, "revision": try #require(read["revision"]), "changes": changes])
        return try #require(result["committed"] as? Bool)
    }
    private func map(_ read: [String: Any], key: String) throws -> [String: String]? {
        let values = try #require(read["values"] as? [String: String])
        guard let raw = values[key] else { return nil }
        return try JSONDecoder().decode([String: String].self, from: #require(Data(base64Encoded: raw)))
    }
    private func json(_ value: Any) throws -> String { String(decoding: try data(value), as: UTF8.self) }
    private func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) }
}

@Suite("Original preview context owner", .serialized)
struct LegadoPreviewStateOwnerTests {
    private struct Fixture {
        let root: URL
        let directory: URL
        let source: BookSource
        let executor: PreviewFixtureExecutor
        let service: LegadoMainJSSourceService
        let fetcher: BookSourceFetcher
    }
    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("owned-preview-" + UUID().uuidString)
        let directory = root.appendingPathComponent("existing-context")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var source = BookSource(); source.bookSourceName = "Owned preview"; source.bookSourceUrl = "https://preview-owned.invalid/source"
        source.enabledCookieJar = false; source.lastUpdateTime = 1
        let executor = PreviewFixtureExecutor(directory: directory)
        let service = LegadoMainJSSourceService(contextDirectory: directory, originalExecutor: executor)
        return Fixture(root: root, directory: directory, source: source, executor: executor,
            service: service, fetcher: BookSourceFetcher(mainJSService: service))
    }
    private func cleanup(_ f: Fixture) {
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.root.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.directory.path)
            try FileManager.default.removeItem(at: f.root)
        } catch { Issue.record("Owned preview cleanup failed: \(error)") }
    }
    private func search(_ f: Fixture) async throws -> OnlineBook {
        try #require(try await f.fetcher.searchOriginalPreview(query: "owned", source: f.source).first)
    }
    private func details(_ f: Fixture, _ book: OnlineBook) async throws -> BookInfoPackage {
        try await f.fetcher.fetchOriginalPreviewBookInfo(url: book.bookUrl, source: f.source,
            runtimeVariables: book.runtimeVariables, knownBook: book)
    }
    private func expectError(_ code: String, _ body: () async throws -> Void) async {
        do { try await body(); Issue.record("Expected \(code)") }
        catch let error as LegadoRuntimeError { #expect(error.code == code) }
        catch { Issue.record("Expected typed \(code), received \(error)") }
    }
    private func contextBytes(_ f: Fixture) throws -> Data {
        let files = try FileManager.default.contentsOfDirectory(at: f.directory, includingPropertiesForKeys: nil)
        return try Data(contentsOf: #require(files.first))
    }

    @Test("Explicit original four-stage preview uses real Host context files and reopens without a library record")
    func explicitBusinessPreviewUsesExistingContextAndRestart() async throws {
        let options = NativeLegadoOriginalPreviewExecutor.embeddingOptions(owner: "owned-preview-only")
        #expect(options.stateOwner == "owned-preview-only")
        #expect(options.sourceMode == .originalTraditional)
        #expect(options.httpTransport.rawValue == "jvm-okhttp")
        #expect(options.cookieAccess.rawValue == "app-owner-text")
        let f = try fixture(); defer { cleanup(f) }
        let book = try await search(f)
        let detail = try await details(f, book)
        #expect(detail.runtimeVariables?["seed"] == "kept")
        #expect(detail.runtimeVariables?["persisted"] == "details")
        #expect(detail.runtimeVariables?["direct"] == "setter")
        #expect(detail.runtimeVariables?["large"] == String(repeating: "L", count: 10_000))
        let toc = try await f.fetcher.fetchOriginalPreviewTOC(url: detail.tocUrl, source: f.source, runtimeVariables: detail.runtimeVariables)
        let ref = try #require(toc.chapters.first)
        #expect(ref.runtimeVariables?["chapter"] == "toc")
        #expect(try await f.fetcher.fetchOriginalPreviewContent(ref: ref, source: f.source) == "Owned preview body\nSecond line")
        let beforeReopen = try contextBytes(f)
        let nextExecutor = PreviewFixtureExecutor(directory: f.directory)
        let reopened = LegadoMainJSSourceService(contextDirectory: f.directory, originalExecutor: nextExecutor)
        #expect(try await reopened.originalContent(ref: ref, source: f.source) == "Owned preview body\nSecond line")
        #expect(try contextBytes(f) == beforeReopen)
        let refreshed = try await reopened.originalTOC(url: detail.tocUrl, source: f.source, runtimeVariables: detail.runtimeVariables)
        #expect(refreshed.chapters.first?.id == ref.id)
        #expect(refreshed.chapters.first?.runtimeVariables?["content"] == "yes")
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.path) == ["existing-context"])
        #expect(await f.executor.operations() == ["search", "details", "toc", "content"])
        #expect(try await f.executor.oldGrantIsRejected())
    }

    @Test("Preview source UUID, source revision and business URL cannot be borrowed by another source")
    func previewSourceRevisionAndURLAreExplicit() async throws {
        let f = try fixture(); defer { cleanup(f) }; let book = try await search(f)
        await expectError("CONTEXT_MISMATCH") { _ = try await f.service.originalDetails(url: book.bookUrl + "/wrong", source: f.source, runtimeVariables: book.runtimeVariables) }
        var other = f.source; other.id = UUID()
        await expectError("CONTEXT_MISMATCH") { _ = try await f.service.originalDetails(url: book.bookUrl, source: other, runtimeVariables: book.runtimeVariables) }
        var revised = f.source; revised.ruleBookInfo.name = "changed"; revised.lastUpdateTime += 1
        await expectError("CONTEXT_MISMATCH") { _ = try await f.service.originalDetails(url: book.bookUrl, source: revised, runtimeVariables: book.runtimeVariables) }
        #expect(await f.executor.operations() == ["search"])
    }

    @Test("The shared Host CAS rejects stale leases and details cannot write foreign books or undiscovered chapters")
    func staleCASAndForeignEntityScopesAreRejected() async throws {
        let f = try fixture(); defer { cleanup(f) }; let book = try await search(f)
        await f.executor.setMode(.staleCAS); _ = try await details(f, book)
        #expect(await f.executor.staleWasRejected)
        await f.executor.setMode(.scopeChecks); _ = try await details(f, book)
        #expect(await f.executor.scopeWasRejected)
    }

    @Test("A later rule failure preserves accepted short and large Host commits in the same context record")
    func failedBusinessKeepsAcceptedVariables() async throws {
        let f = try fixture(); defer { cleanup(f) }; let book = try await search(f)
        await f.executor.setMode(.failAfterCommit)
        await expectError("RULE_ERROR") { _ = try await details(f, book) }
        let raw = try contextBytes(f)
        let object = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let dto = try #require(object["book"] as? [String: Any])
        let variables = try JSONDecoder().decode([String: String].self, from: Data(try #require(dto["variable"] as? String).utf8))
        #expect(variables["persisted"] == "details")
        #expect(variables["direct"] == nil)
        #expect((object["bookLargeVariables"] as? [String: String])?["large"] == String(repeating: "L", count: 10_000))
        let reopened = LegadoMainJSSourceService(contextDirectory: f.directory, originalExecutor: PreviewFixtureExecutor(directory: f.directory))
        let next = try await reopened.originalDetails(url: book.bookUrl, source: f.source, runtimeVariables: book.runtimeVariables)
        #expect(next.runtimeVariables?["persisted"] == "details")
    }

    @Test("A foreign file revision after the task's sealed completion rejects its returned DTO without overwriting newer bytes")
    func changedContextRejectsReturnedSetter() async throws {
        let f = try fixture(); defer { cleanup(f) }; let book = try await search(f)
        await f.executor.setMode(.changeAfterSeal)
        await expectError("STATE_CONFLICT") { _ = try await details(f, book) }
        let raw = try contextBytes(f)
        let object = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let dto = try #require(object["book"] as? [String: Any])
        #expect(dto["variable"] as? String == #"{"foreign":"must remain"}"#)
    }

    @Test("Durable preview revocation survives restart and never deletes or invents an App file")
    func explicitRevocationSurvivesContextRestart() async throws {
        let f = try fixture(); defer { cleanup(f) }; let book = try await search(f)
        try await f.fetcher.revokeOriginalPreview(source: f.source, runtimeVariables: book.runtimeVariables)
        let executor = PreviewFixtureExecutor(directory: f.directory)
        let reopened = LegadoMainJSSourceService(contextDirectory: f.directory, originalExecutor: executor)
        await expectError("INVALID_STATE_OWNER") { _ = try await reopened.originalDetails(url: book.bookUrl, source: f.source, runtimeVariables: book.runtimeVariables) }
        #expect(await executor.operations().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.directory.path).count == 1)
    }

    @Test("Cancellation closes the operation grant before a stalled executor can make a late Host commit")
    func cancellationPreventsLateContextCommit() async throws {
        let f = try fixture(); defer { cleanup(f) }; let book = try await search(f)
        let before = try contextBytes(f)
        await f.executor.setMode(.waitBeforeCommit)
        let pending = Task { try await details(f, book) }
        var iterator = f.executor.entered.makeAsyncIterator()
        _ = await iterator.next()
        pending.cancel(); await f.executor.openGate()
        do { _ = try await pending.value; Issue.record("Cancelled preview cannot return a successful result") }
        catch is CancellationError { }
        #expect(try contextBytes(f) == before)
        #expect(try await f.executor.oldGrantIsRejected())
    }

    @Test("An actual owned context directory write failure preserves old bytes and returns typed STATE_IO")
    func realContextWriteFailurePreservesPriorRecord() async throws {
        let f = try fixture(); defer { cleanup(f) }; let book = try await search(f)
        let before = try contextBytes(f)
        await f.executor.setMode(.failWrite)
        await expectError("STATE_IO") { _ = try await details(f, book) }
        #expect(try contextBytes(f) == before)
    }

    @Test("Corrupt chapter indexes, repeated identities, oversized files and linked contexts fail before calling the engine")
    func corruptOversizedAndLinkedContextsFailBeforeExecution() async throws {
        let f = try fixture(); defer { cleanup(f) }; let book = try await search(f)
        let detail = try await details(f, book)
        _ = try await f.service.originalTOC(url: detail.tocUrl, source: f.source, runtimeVariables: detail.runtimeVariables)
        let path = try #require(FileManager.default.contentsOfDirectory(at: f.directory, includingPropertiesForKeys: nil).first)
        let old = try Data(contentsOf: path)
        let calls = await f.executor.operations()
        var record = try #require(try JSONSerialization.jsonObject(with: old) as? [String: Any])
        var chapters = try #require(record["chapters"] as? [[String: Any]])
        chapters[0]["index"] = Int32.max; record["chapters"] = chapters
        let badIndex = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        try badIndex.write(to: path, options: .atomic)
        await expectError("CONTEXT_CORRUPT") { _ = try await details(f, book) }
        #expect(try Data(contentsOf: path) == badIndex)
        record = try #require(try JSONSerialization.jsonObject(with: old) as? [String: Any])
        chapters = try #require(record["chapters"] as? [[String: Any]])
        record["chapters"] = [chapters[0], chapters[0]]
        record["chapterIDs"] = [UUID().uuidString, UUID().uuidString]
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: path, options: .atomic)
        await expectError("CONTEXT_CORRUPT") { _ = try await details(f, book) }
        // Different valid indexes/UUIDs cannot conceal the same original URL primary key.
        chapters[0]["index"] = 0
        var duplicateURL = chapters[0]; duplicateURL["index"] = 1
        record["chapters"] = [chapters[0], duplicateURL]
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: path, options: .atomic)
        await expectError("CONTEXT_CORRUPT") { _ = try await details(f, book) }
        try Data(repeating: 0x20, count: 8_388_609).write(to: path, options: .atomic)
        await expectError("STATE_LIMIT") { _ = try await details(f, book) }
        let target = f.root.appendingPathComponent("owned-context-copy.json")
        try old.write(to: target, options: .atomic)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
        await expectError("STATE_IO") { _ = try await details(f, book) }
        #expect(try Data(contentsOf: target) == old)
        #expect(await f.executor.operations() == calls)
        try FileManager.default.removeItem(at: path)
        try old.write(to: path, options: .atomic)
        await f.executor.setMode(.unicodeURLs)
        let toc = try await f.service.originalTOC(url: detail.tocUrl, source: f.source, runtimeVariables: detail.runtimeVariables)
        #expect(toc.chapters.count == 2)
        #expect(Data(toc.chapters[0].url.utf8) != Data(toc.chapters[1].url.utf8))
        #expect(toc.chapters[0].runtimeVariables?["ownedIndex"] == "0")
        #expect(toc.chapters[1].runtimeVariables?["ownedIndex"] == "1")
        _ = try await f.service.originalContent(ref: toc.chapters[1], source: f.source)
        let refreshed = try await f.service.originalTOC(url: detail.tocUrl, source: f.source, runtimeVariables: detail.runtimeVariables)
        #expect(refreshed.chapters[0].runtimeVariables?["content"] == nil)
        #expect(refreshed.chapters[1].runtimeVariables?["content"] == "yes")
    }

    @Test("Transfer uses a real off-shelf App UUID and original metadata owner, retains its TOC identities and revokes the preview")
    @MainActor
    func transferUsesExistingOffShelfIdentityAndOriginalFile() async throws {
        let f = try fixture(); defer { cleanup(f) }; let preview = try await search(f)
        let detail = try await details(f, preview)
        let toc = try await f.service.originalTOC(url: detail.tocUrl, source: f.source, runtimeVariables: detail.runtimeVariables)
        let metadata = f.root.appendingPathComponent("books_meta.json")
        let store = BookStore(metadataFileURL: metadata)
        var book = ReadingBook(title: detail.name, author: detail.author, source: preview.bookUrl, contentFilename: "")
        book.isOnline = true; book.isInBookshelf = false; book.bookSourceId = f.source.id; book.bookInfoURL = preview.bookUrl
        book.tocURL = detail.tocUrl; book.runtimeVariables = toc.runtimeVariables; book.onlineChapters = toc.chapters
        store.saveReadingBook(book); await BookStore.queuedWritesLanded()
        let receipt = try await f.fetcher.transferOriginalPreview(source: f.source, runtimeVariables: toc.runtimeVariables, to: store, bookID: book.id)
        #expect(receipt.bookID == book.id)
        #expect(store.readingBook(id: book.id)?.isInBookshelf == false)
        #expect(store.chapters(for: book.id)?.first?.id == toc.chapters.first?.id)
        #expect(store.readingBook(id: book.id)?.runtimeVariables?["direct"] == "setter")
        await expectError("INVALID_STATE_OWNER") { _ = try await details(f, preview) }
        let reopened = BookStore(metadataFileURL: metadata)
        #expect(reopened.readingBook(id: book.id)?.runtimeVariables?["large"] == String(repeating: "L", count: 10_000))
        #expect(reopened.readingBook(id: book.id)?.isInBookshelf == false)
        // Explicit user shelving retains this exact already-owned UUID.
        #expect(store.addReadingBookToShelf(id: book.id)?.id == receipt.bookID)
        await BookStore.queuedWritesLanded()
    }

    @Test("Missing App UUID or conflicting actual book/chapter variables reject transfer before retiring the preview")
    @MainActor
    func transferRejectsInventedIdentityAndChangedAppVariables() async throws {
        let f = try fixture(); defer { cleanup(f) }; let preview = try await search(f)
        let detail = try await details(f, preview)
        let store = BookStore(metadataFileURL: f.root.appendingPathComponent("books_meta.json"))
        await expectError("UNSUPPORTED_CAPABILITY") {
            _ = try await f.service.transferOriginalPreview(source: f.source, runtimeVariables: detail.runtimeVariables, to: store, bookID: UUID())
        }
        var book = ReadingBook(title: detail.name, source: preview.bookUrl, contentFilename: "")
        book.isOnline = true; book.isInBookshelf = false; book.bookSourceId = f.source.id; book.bookInfoURL = preview.bookUrl
        book.runtimeVariables = ["direct": "new App edit"]
        store.saveReadingBook(book); await BookStore.queuedWritesLanded()
        await expectError("STATE_CONFLICT") {
            _ = try await f.service.transferOriginalPreview(source: f.source, runtimeVariables: detail.runtimeVariables, to: store, bookID: book.id)
        }
        #expect(store.readingBook(id: book.id)?.runtimeVariables == ["direct": "new App edit"])
        #expect(try await details(f, preview).runtimeVariables?["direct"] == "setter")
    }

    @Test("An actual App write failure retains the non-writable transfer intent; reopening resumes into the same off-shelf UUID")
    @MainActor
    func failedAppWriteRetainsTransferIntentAndReopens() async throws {
        let f = try fixture(); defer { cleanup(f) }; let preview = try await search(f)
        let detail = try await details(f, preview)
        let metadata = f.root.appendingPathComponent("books_meta.json")
        let store = BookStore(metadataFileURL: metadata)
        var book = ReadingBook(title: detail.name, source: preview.bookUrl, contentFilename: "")
        book.isOnline = true; book.isInBookshelf = false; book.bookSourceId = f.source.id
        book.bookInfoURL = preview.bookUrl; book.tocURL = detail.tocUrl
        store.saveReadingBook(book); await BookStore.queuedWritesLanded()
        let reading = metadata.deletingPathExtension().appendingPathExtension("reading.json")
        let oldBytes = try Data(contentsOf: reading)
        // Parent write permission blocks only the actual metadata atomic replacement.
        // The existing context child remains writable, so its real intent lands first.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: f.root.path)
        await expectError("STATE_IO") {
            _ = try await f.service.transferOriginalPreview(source: f.source, runtimeVariables: detail.runtimeVariables, to: store, bookID: book.id)
        }
        #expect(try Data(contentsOf: reading) == oldBytes)
        let pending = try #require(try JSONSerialization.jsonObject(with: contextBytes(f)) as? [String: Any])
        #expect(pending["status"] as? String == "transferring")
        #expect(pending["transferBookID"] as? String == book.id.uuidString)
        await expectError("INVALID_STATE_OWNER") { _ = try await details(f, preview) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.root.path)
        let reopenedStore = BookStore(metadataFileURL: metadata)
        let reopened = LegadoMainJSSourceService(contextDirectory: f.directory, originalExecutor: PreviewFixtureExecutor(directory: f.directory))
        let receipt = try await reopened.transferOriginalPreview(source: f.source, runtimeVariables: detail.runtimeVariables, to: reopenedStore, bookID: book.id)
        #expect(receipt.bookID == book.id)
        #expect(reopenedStore.readingBook(id: book.id)?.runtimeVariables?["direct"] == "setter")
        #expect(reopenedStore.readingBook(id: book.id)?.isInBookshelf == false)
        let finished = try #require(try JSONSerialization.jsonObject(with: contextBytes(f)) as? [String: Any])
        #expect(finished["status"] as? String == "transferred")
    }

    @Test("Both raw Unicode key orders reject before DTO/Host acceptance or nested record decoding; exact duplicates keep last value")
    func rawVariableMapsRejectAliasingBeforeDictionaryDecode() async throws {
        let maps = [#"{"\u00e9":"first","e\u0301":"second"}"#, #"{"e\u0301":"first","\u00e9":"second"}"#]
        for rawMap in maps {
            let f = try fixture(); defer { cleanup(f) }
            await f.executor.setSearchVariable(rawMap)
            await expectError("UNSUPPORTED_CAPABILITY") { _ = try await search(f) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: f.directory.path).isEmpty)
            await f.executor.setSearchVariable(#"{"same":"first","same":"last","e\u0301":"e\u0301"}"#)
            let book = try await search(f)
            #expect(book.runtimeVariables?["same"] == "last")
            let decomposed = "e\u{0301}"
            let original = try #require(book.runtimeVariables?.first { Data($0.key.utf8) == Data(decomposed.utf8) })
            #expect(Data(original.value.utf8) == Data(decomposed.utf8))
            let before = try contextBytes(f)
            await f.executor.setRawSmallCommit(rawMap)
            await expectError("UNSUPPORTED_CAPABILITY") { _ = try await details(f, book) }
            #expect(try contextBytes(f) == before)
            let path = try #require(FileManager.default.contentsOfDirectory(at: f.directory, includingPropertiesForKeys: nil).first)
            let calls = await f.executor.operations()
            for field in ["bookLargeVariables", "chapterVariables", "chapterLargeVariables"] {
                var record = try #require(try JSONSerialization.jsonObject(with: before) as? [String: Any])
                let marker = ["RAW_TOKEN": "marker"]
                if field == "bookLargeVariables" { record[field] = marker }
                else { record[field] = [Data((book.bookUrl + "/pending").utf8).base64EncodedString(): marker] }
                let encoded = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
                let text = try #require(String(data: encoded, encoding: .utf8))
                let needle = #"{"RAW_TOKEN":"marker"}"#
                #expect(text.components(separatedBy: needle).count == 2)
                let malformed = Data(text.replacingOccurrences(of: needle, with: rawMap).utf8)
                try malformed.write(to: path, options: .atomic)
                await expectError("UNSUPPORTED_CAPABILITY") { _ = try await details(f, book) }
                #expect(try Data(contentsOf: path) == malformed)
                #expect(await f.executor.operations() == calls)
            }
        }
    }

    @Test("Both Unicode name orders preserve exact multi-step big get/put and reject cross-compartment or wire aliasing")
    func unicodeHostNamesAndCompartmentProjectionFailClosed() async throws {
        let names = [("\u{00e9}", "e\u{0301}"), ("e\u{0301}", "\u{00e9}")]
        for (first, second) in names {
            for cross in [false, true] {
                let f = try fixture(); defer { cleanup(f) }; let book = try await search(f)
                await f.executor.setUnicodeNames(first, second, crossCompartment: cross)
                await expectError("UNSUPPORTED_CAPABILITY") { _ = try await details(f, book) }
                let object = try #require(try JSONSerialization.jsonObject(with: contextBytes(f)) as? [String: Any])
                let large = try #require(object["bookLargeVariables"] as? [String: String])
                #expect(large.count == 1)
                #expect(Data(try #require(large.keys.first).utf8) == Data(first.utf8))
                #expect(large.values.first == (cross ? "first" : "updated"))
                let dto = try #require(object["book"] as? [String: Any])
                let small = try JSONDecoder().decode([String: String].self, from: Data(try #require(dto["variable"] as? String).utf8))
                #expect(small == ["seed": "kept"])
                #expect(try await f.executor.oldGrantIsRejected())
            }
        }
    }

    @Test("Actual App book/chapter handoff rejects canonically equal variable names or values with different UTF-8 bytes")
    @MainActor
    func transferRequiresExactVariableNamesAndValues() async throws {
        let values = [("\u{00e9}", "e\u{0301}"), ("e\u{0301}", "\u{00e9}")]
        for (previewValue, appValue) in values {
            for scope in ["book-value", "book-name", "chapter-value"] {
                let f = try fixture(); defer { cleanup(f) }
                let initial = scope == "book-name" ? [previewValue: "token"] : ["raw": previewValue]
                await f.executor.setSearchVariable(String(decoding: try JSONEncoder().encode(initial), as: UTF8.self))
                if scope == "chapter-value" { await f.executor.setChapterLiteral(previewValue) }
                let preview = try await search(f); let detail = try await details(f, preview)
                let toc = try await f.service.originalTOC(url: detail.tocUrl, source: f.source, runtimeVariables: detail.runtimeVariables)
                let metadata = f.root.appendingPathComponent("books_meta.json")
                let store = BookStore(metadataFileURL: metadata)
                var book = ReadingBook(title: detail.name, source: preview.bookUrl, contentFilename: "")
                book.isOnline = true; book.isInBookshelf = false; book.bookSourceId = f.source.id
                book.bookInfoURL = preview.bookUrl; book.tocURL = detail.tocUrl
                book.runtimeVariables = toc.runtimeVariables; book.onlineChapters = toc.chapters
                if scope == "book-value" { book.runtimeVariables?["raw"] = appValue }
                if scope == "book-name" {
                    book.runtimeVariables?.removeValue(forKey: previewValue)
                    book.runtimeVariables?[appValue] = "token"
                }
                if scope == "chapter-value" { book.onlineChapters?[0].runtimeVariables?["raw"] = appValue }
                store.saveReadingBook(book); await BookStore.queuedWritesLanded()
                let before = try contextBytes(f)
                let expected = scope == "book-name" ? "UNSUPPORTED_CAPABILITY" : "STATE_CONFLICT"
                await expectError(expected) {
                    _ = try await f.service.transferOriginalPreview(source: f.source, runtimeVariables: toc.runtimeVariables, to: store, bookID: book.id)
                }
                #expect(try contextBytes(f) == before)
                let reopened = BookStore(metadataFileURL: metadata)
                let actual = try #require(reopened.readingBook(id: book.id))
                if scope == "book-value" { #expect(Data(try #require(actual.runtimeVariables?["raw"]).utf8) == Data(appValue.utf8)) }
                if scope == "book-name" {
                    let exact = try #require(actual.runtimeVariables?.first { Data($0.key.utf8) == Data(appValue.utf8) })
                    #expect(exact.value == "token")
                }
                if scope == "chapter-value" {
                    let chapter = try #require(reopened.chapters(for: book.id)?.first)
                    #expect(Data(try #require(chapter.runtimeVariables?["raw"]).utf8) == Data(appValue.utf8))
                    #expect(!LegadoPreviewIdentity.sameChapter(chapter, toc.chapters[0]))
                }
            }
        }
    }
}
