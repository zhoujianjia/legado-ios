import CryptoKit
import Foundation
import LegadoRuntime
@preconcurrency import Network
import XCTest
@testable import yuedu_app

/// One fixed native product-chain test. No fake executor, external website or user source.
final class LegadoNativeMainJSReaderTests: XCTestCase {
    func testNativeMainJSProductReadingChain() async throws {
        executionTimeAllowance = 180
        // This single synthetic suite starts the process JVM. Never enable trace
        // for an ordinary app launch or change a JVM already running in-process.
        let previousTrace = getenv("LEGADO_RUNTIME_TASK_TRACE").map { String(cString: $0) }
        guard setenv("LEGADO_RUNTIME_TASK_TRACE", "1", 1) == 0 else {
            throw NativeReaderTestError.failed("Cannot enable synthetic task trace")
        }
        defer {
            if let previousTrace { setenv("LEGADO_RUNTIME_TASK_TRACE", previousTrace, 1) }
            else { unsetenv("LEGADO_RUNTIME_TASK_TRACE") }
        }
        let diagnostics = await Task.detached { LegadoRuntime.diagnose() }.value
        let required: Bool
        #if LEGADO_REQUIRE_NATIVE_MAINJS
        required = true
        #else
        required = ProcessInfo.processInfo.environment["LEGADO_REQUIRE_NATIVE_MAINJS"] == "1"
            || UserDefaults.standard.bool(forKey: "LEGADO_REQUIRE_NATIVE_MAINJS")
        #endif
        guard diagnostics.available else {
            attach(["nativeBridgePresent": diagnostics.nativeBridgePresent, "issues": diagnostics.issues,
                    "required": required], name: "LegadoNativeMainJS-preflight")
            if required { throw NativeReaderTestError.failed("Required native payload is unavailable: \(diagnostics.issues.joined(separator: "; "))") }
            throw XCTSkip("Native mainJs test requires the ordinary JVM payload")
        }

        let runID = UUID().uuidString.lowercased()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NativeMainJS-\(runID)", isDirectory: true)
        var readingBook = ReadingBook(title: "Native Book", source: "native-mainjs-fixture", contentFilename: "")
        let bookID = readingBook.id
        let server = try NativeReaderLoopbackServer(runID: runID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let initialService = LegadoMainJSSourceService(contextDirectory: directory, operationTimeout: 45)
        let initialFetcher = BookSourceFetcher(mainJSService: initialService)
        var readerService: LegadoMainJSSourceService?
        var readerFetcher: BookSourceFetcher?
        var pending: Task<ChapterPackage, Error>?
        var problem: Error?
        var report: [String: Any] = ["schemaVersion": 1, "suite": "LegadoNativeMainJSReaderTests",
            "runID": runID, "processID": ProcessInfo.processInfo.processIdentifier,
            "startedAtEpochSeconds": Date().timeIntervalSince1970, "nativeBridgePresent": diagnostics.nativeBridgePresent,
            "nativePayloadAvailable": diagnostics.available, "requiredPayload": required,
            "timingObserverEffect": "Synchronous trace serialization, locks and native fsync are included in measured execution/cancellation latency. Diagnostic timings differ from an untraced run; these events alone do not establish the cause.",
            "taskTraceInterpretation": "http.cancel.before/after observe cancellation propagation. http.finished.callCancelled follows unconditional cleanup and is not propagation evidence. Missing stages are not attributed automatically to either tracing or business execution.",
            "readerUIRendered": false, "deviceValidationPassed": false, "g4ValidationPassed": false]
        #if targetEnvironment(simulator)
        report["executionPlatform"] = "ios-simulator"
        #else
        report["executionPlatform"] = "ios-device"
        #endif
        report["bundleSourceCommit"] = Bundle.main.object(forInfoDictionaryKey: "YueduExperienceSourceCommit") as? String ?? "not-stamped"
        var stages: [String: String] = [:]
        var cleanup: [String: Bool] = [:]
        do {
            let ready = expectation(description: "Loopback listener is ready")
            server.start { ready.fulfill() }
            await fulfillment(of: [ready], timeout: 10)
            let base = try server.readyBaseURL()
            report["fixtureBaseURL"] = base
            let source = try Self.source(base: base, runID: runID)
            stages["source"] = try Self.json(source)
            report["mainJsSHA256"] = SHA256.hash(data: Data((source.mainJs ?? "").utf8)).map { String(format: "%02x", $0) }.joined()
            attach(["stage": "search.begin", "runID": runID], name: "LegadoNativeMainJS-progress-search")
            let books = try await initialFetcher.search(query: "native-query", in: source)
            stages["search"] = try Self.json(books)
            try check(books.count == 1, "Search must return exactly one native book")
            let book = try XCTUnwrap(books.first)
            let detail = try await initialFetcher.fetchBookInfoPackage(url: book.bookUrl, source: source,
                runtimeVariables: book.runtimeVariables, knownBook: book)
            stages["details"] = try Self.json(detail)
            try check(detail.intro == "Details fetched over native TCP", "Details must use the wire response")
            let toc = try await initialFetcher.fetchTOCPackage(tocUrl: detail.tocUrl, source: source,
                runtimeVariables: detail.runtimeVariables)
            stages["toc"] = try Self.json(toc)
            try check(toc.chapters.count == 2, "TOC must contain both wire chapters")
            let persistedTOC = try JSONDecoder().decode(TOCPackage.self, from: JSONEncoder().encode(toc))
            try await initialService.closeSessions()
            cleanup["initialSessionCloseReturned"] = true

            // New product service, same durable DTO directory and process-wide JVM.
            let reopened = LegadoMainJSSourceService(contextDirectory: directory, operationTimeout: 45)
            readerService = reopened
            let fetcher = BookSourceFetcher(mainJSService: reopened)
            readerFetcher = fetcher
            let first = try await fetcher.fetchChapterPackage(ref: persistedTOC.chapters[0], bookId: bookID, source: source)
            let second = try await fetcher.fetchChapterPackage(ref: persistedTOC.chapters[1], bookId: bookID, source: source)
            stages["contentOne"] = try Self.json(first)
            stages["contentTwo"] = try Self.json(second)
            try check(first.content == "LEGADO_NATIVE_RAW_ONE", "E4X/Java marker for chapter one differs")
            try check(second.content == "LEGADO_NATIVE_RAW_TWO", "E4X/Java marker for chapter two differs")
            try check(first.rawHTMLFilename == nil && first.normalizedHTMLFilename == nil
                && second.rawHTMLFilename == nil && second.normalizedHTMLFilename == nil,
                "Plain JVM text must not claim source HTML artifacts")
            readingBook.title = detail.name
            readingBook.source = source.bookSourceUrl
            readingBook.isOnline = true
            readingBook.bookSourceId = source.id
            readingBook.bookInfoURL = detail.bookURL
            readingBook.tocURL = persistedTOC.tocURL
            readingBook.runtimeVariables = persistedTOC.runtimeVariables
            readingBook.onlineChapters = persistedTOC.chapters
            let requestsBeforeReader = server.snapshot.requests.count
            let reader = OnlineChapterContentService(book: readingBook, store: nil)
            let payload = try await reader.payload(at: 0, policy: .cacheOnly)
            try check(payload.plainText == first.content && payload.title == persistedTOC.chapters[0].title
                && payload.sourceHref == persistedTOC.chapters[0].url,
                "The actual cache-only reader payload must preserve the JVM content and chapter identity")
            guard case .html(let xhtml) = payload.body else {
                throw NativeReaderTestError.failed("The native reader must wrap cached JVM text as XHTML")
            }
            stages["readerCacheOnlyXHTML"] = xhtml
            stages["readerCacheOnlyPlainText"] = payload.plainText
            try check(xhtml.contains("<article id=\"reader-content\">") && xhtml.contains(first.content),
                "The actual reader XHTML must contain the JVM result")
            try check(server.snapshot.requests.count == requestsBeforeReader,
                "The cache-only reader must not issue an additional HTTP request")

            let headersSent = expectation(description: "Fixture wrote headers and a partial body")
            let peerClosed = expectation(description: "Cancelled native client closes the held TCP connection")
            server.armHeldBody(headersSent: { headersSent.fulfill() }, peerClosed: { peerClosed.fulfill() })
            let task = Task { try await fetcher.fetchChapterPackage(ref: persistedTOC.chapters[0], bookId: bookID, source: source) }
            pending = task
            await fulfillment(of: [headersSent], timeout: 15)
            let held = server.snapshot.heldHeadersSent
            let cancelledAt = Date()
            report["cancelRequestedAtEpochMs"] = cancelledAt.timeIntervalSince1970 * 1000
            task.cancel()
            let outcome = await task.result
            pending = nil
            try check(held, "Cancellation requires an actual held wire request")
            switch outcome {
            case .success: throw NativeReaderTestError.failed("Cancelled native request returned content")
            case .failure(let error):
                try check(error is CancellationError || (error as? LegadoRuntimeError)?.code == "CANCELLED",
                    "Cancellation returned an unrelated error: \(error)")
                report["cancellationErrorType"] = String(reflecting: type(of: error))
            }
            let cancellationMilliseconds = Date().timeIntervalSince(cancelledAt) * 1000
            report["cancellationMilliseconds"] = cancellationMilliseconds
            // Always consume this expectation, including when the unchanged
            // latency gate below fails; peer-close timing is retained separately.
            await fulfillment(of: [peerClosed], timeout: 10)
            // Prevent a broken cancel that merely waits for the 45-second task deadline
            // from being mistaken for successful cancellation.
            try check(cancellationMilliseconds < 15_000, "Native cancellation waited for its natural deadline")
            try check(server.snapshot.heldPeerClosed, "Held native connection did not report peer EOF/reset")
            let recovery = try await fetcher.fetchChapterPackage(ref: persistedTOC.chapters[0], bookId: bookID, source: source)
            stages["recovery"] = try Self.json(recovery)
            try check(recovery.content == first.content, "Native source did not recover after cancellation")

            let trace = server.snapshot
            let expectedTargets = ["/\(runID)/search?key=native-query&page=1", "/\(runID)/details", "/\(runID)/toc",
                                   "/\(runID)/content/1", "/\(runID)/content/2", "/\(runID)/content/1", "/\(runID)/content/1"]
            try check(trace.requests.map(\.target) == expectedTargets, "Actual TCP request sequence differs")
            try check(trace.requests.allSatisfy { $0.method == "GET" && $0.fixtureHeader == runID }, "Wire method/source header differs")
            try check(trace.requests.filter(\.completeResponseWritten).count == 6 && trace.requests.filter(\.heldBody).count == 1,
                "Every ordinary response and exactly one held response must be written")
            try check(trace.requests.allSatisfy { !$0.responseBody.contains("LEGADO_NATIVE_") }, "Server must never supply the final marker")
            try check(trace.errors.isEmpty, "Fixture errors: \(trace.errors)")
        } catch { problem = error }

        // Always drain the real public cancellation/close paths before closing the server.
        if let pending {
            pending.cancel()
            _ = await pending.result
            cleanup["pendingTaskFinished"] = true
        } else { cleanup["pendingTaskFinished"] = true }
        do { try await initialService.closeSessions(); cleanup["initialSessionCloseReturned"] = true }
        catch { cleanup["initialSessionCloseReturned"] = false; if problem == nil { problem = error } }
        if let readerService {
            do { try await readerService.closeSessions(); cleanup["readerSessionCloseReturned"] = true }
            catch { cleanup["readerSessionCloseReturned"] = false; if problem == nil { problem = error } }
        }
        let stopped = expectation(description: "Listener cancelled and owned connections drained")
        server.stop { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 10)
        let finalTrace = server.snapshot
        cleanup["listenerCancelled"] = finalTrace.listenerCancelled
        cleanup["connectionsDrained"] = finalTrace.activeConnections == 0
        if !finalTrace.listenerCancelled || finalTrace.activeConnections != 0 {
            if problem == nil { problem = NativeReaderTestError.failed("Loopback server cleanup did not complete") }
        }
        if !finalTrace.errors.isEmpty, problem == nil {
            problem = NativeReaderTestError.failed("Fixture errors during cleanup: \(finalTrace.errors)")
        }
        readerFetcher?.clearAllChapterCache(bookId: bookID)
        initialFetcher.clearAllChapterCache(bookId: bookID)
        do {
            var records: [String: String] = [:]
            for path in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                records[path.lastPathComponent] = try String(contentsOf: path, encoding: .utf8)
            }
            report["durableContextRecords"] = records
            try FileManager.default.removeItem(at: directory)
            cleanup["temporaryContextsRemoved"] = true
        } catch { cleanup["temporaryContextsRemoved"] = false; if problem == nil { problem = error } }
        report["stages"] = stages
        report["wire"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(finalTrace))
        report["cleanup"] = cleanup
        do {
            let saved = try await Task.detached { try LegadoRuntime.savedDiagnostics() }.value
            let names = ["current/native-task-events.jsonl", "current/runtime-events.jsonl"]
            var evidence: [String: String] = [:]
            for name in names { if let value = saved[name] { evidence[name] = value } }
            report["taskTrace"] = evidence
            report["taskTraceSwitchSetBeforeTestOperations"] = true
            let nativeTraceFault = saved["current/stages.log"].map {
                $0.contains("stage=task.trace.limit") || $0.contains("stage=task.trace.write.failed")
            } ?? false
            let jvmTraceFault = evidence["current/runtime-events.jsonl"]?.contains("\"stage\":\"trace.limit\"") == true || (saved["current/vm-output.log"].map {
                $0.contains("LEGADO_TASK_TRACE_OPEN_FAILED") || $0.contains("LEGADO_TASK_TRACE_WRITE_FAILED") || $0.contains("LEGADO_TASK_TRACE_LIMIT")
            } ?? false)
            report["taskTraceObservedFailureMarkerPresent"] = nativeTraceFault || jvmTraceFault
            if evidence.count != names.count || evidence.values.contains(where: { $0.isEmpty || $0.contains("[truncated:") }) {
                report["taskTraceFilesReadable"] = false
                if problem == nil { problem = NativeReaderTestError.failed("Opt-in task trace is missing or truncated") }
            } else {
                var eventCounts: [String: [String: Int]] = [:]
                var stagePresence: [String: [String: Bool]] = [:]
                let nativeStages = ["execute.before", "execute.result", "cancel.before", "cancel.result"]
                let jvmStages = ["execute.registered", "execute.finished", "cancel.lookup", "job.cancel.before", "job.cancel.after",
                    "deadline.fired", "deadline.cancel.after", "http.registered", "http.execute.before", "http.headers",
                    "http.body.before", "http.body.after", "http.cancel.before", "http.cancel.after", "http.finished", "trace.limit"]
                for (name, value) in evidence {
                    let known = name == names[0] ? nativeStages : jvmStages
                    var counts = Dictionary(uniqueKeysWithValues: known.map { ($0, 0) })
                    counts["unknown"] = 0
                    for line in value.split(separator: "\n") {
                        guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                              let stage = object["stage"] as? String, object["taskId"] is String else {
                            throw NativeReaderTestError.failed("Invalid bounded task trace event")
                        }
                        counts[known.contains(stage) ? stage : "unknown", default: 0] += 1
                    }
                    eventCounts[name] = counts
                    stagePresence[name] = Dictionary(uniqueKeysWithValues: known.map { ($0, counts[$0, default: 0] > 0) })
                }
                report["taskTraceEventCounts"] = eventCounts
                report["taskTraceStagePresence"] = stagePresence
                // File readability is separate from proving every intended
                // event was persisted; JVM stderr is also retained by XCTest.
                report["taskTraceFilesReadable"] = true
                if (nativeTraceFault || jvmTraceFault) && problem == nil {
                    problem = NativeReaderTestError.failed("Opt-in task trace has an observed failure or limit marker")
                }
            }
        } catch {
            report["taskTraceFilesReadable"] = false
            report["taskTraceReadFailed"] = true
            if problem == nil { problem = error }
        }
        report["status"] = problem == nil ? "passed" : "failed"
        report["completedAtEpochSeconds"] = Date().timeIntervalSince1970
        report["errors"] = problem.map { [String(describing: $0)] } ?? []
        attach(report, name: "LegadoNativeMainJSReader-report-\(runID)")
        if let problem { throw problem }
    }

    private func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NativeReaderTestError.failed(message) }
    }
    private func attach(_ value: [String: Any], name: String) {
        do {
            let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]),
                uniformTypeIdentifier: "public.json")
            attachment.name = name + ".json"
            attachment.lifetime = .keepAlways
            add(attachment)
        } catch { XCTFail("Could not attach native test evidence: \(error)") }
    }
    private static func json<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    private static func source(base: String, runID: String) throws -> BookSource {
        var source = BookSource(bookSourceUrl: base, bookSourceName: "Native product fixture")
        source.header = try json(["X-Legado-Native-Fixture": runID, "Accept-Encoding": "identity", "Connection": "close"])
        let literal = try json(base)
        source.mainJs = """
        var fixtureBase = \(literal);
        function search(key,page) { return JSON.parse(String(java.ajax(fixtureBase+'/search?key='+encodeURIComponent(key)+'&page='+page))); }
        function getBookInfo(book) {
          if (JSON.parse(String(book.variable)).search !== 'wire') throw new Error('search DTO variable lost');
          return JSON.parse(String(java.connect(fixtureBase+'/details').body()));
        }
        function getChapters(book) { return JSON.parse(String(java.ajax(book.tocUrl))); }
        function getContent(chapter,book,nextChapterUrl) {
          if (JSON.parse(String(book.variable)).detail !== 'wire') throw new Error('book DTO variable lost');
          if (JSON.parse(String(chapter.variable)).chapter !== chapter.index+1) throw new Error('chapter DTO variable lost');
          var raw = String(java.connect(chapter.url).body());
          var xml = <payload><part>{raw}</part></payload>;
          var builder = new Packages.java.lang.StringBuilder();
          builder.append(new Packages.java.lang.String('LEGADO_NATIVE_'));
          builder.append(new Packages.java.lang.String(String(xml.part)));
          return String(builder.toString());
        }
        """
        return source
    }
}

private enum NativeReaderTestError: Error { case failed(String) }

/// A finite HTTP server, never a replacement client/parser for production traffic.
private final class NativeReaderLoopbackServer: @unchecked Sendable {
    struct Request: Codable {
        let method: String
        let target: String
        let rawRequestBase64: String
        let fixtureHeader: String
        let responseBody: String
        var heldBody: Bool
        var headersSent = false
        var completeResponseWritten = false
    }
    struct Snapshot: Codable {
        let requests: [Request]
        let errors: [String]
        let heldHeadersSent: Bool
        let heldPeerClosed: Bool
        let heldHeadersAtEpochMs: Double?
        let heldPeerClosedAtEpochMs: Double?
        let listenerCancelled: Bool
        let activeConnections: Int
    }
    private let runID: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LegadoNativeMainJS.loopback")
    private let lock = NSLock()
    private var base: String?
    private var requests: [Request] = []
    private var errors: [String] = []
    private var connections: [UUID: NWConnection] = [:]
    private var heldConnection: UUID?
    private var holdNext = false
    private var heldHeaders = false
    private var peerClosed = false
    private var heldHeadersAtEpochMs: Double?
    private var heldPeerClosedAtEpochMs: Double?
    private var cancelled = false
    private var stopping = false
    private var readyCallback: (() -> Void)?
    private var stopCallback: (() -> Void)?
    private var headersCallback: (() -> Void)?
    private var peerCallback: (() -> Void)?

    init(runID: String) throws {
        self.runID = runID
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    var snapshot: Snapshot {
        lock.withLock { Snapshot(requests: requests, errors: errors, heldHeadersSent: heldHeaders,
            heldPeerClosed: peerClosed, heldHeadersAtEpochMs: heldHeadersAtEpochMs,
            heldPeerClosedAtEpochMs: heldPeerClosedAtEpochMs,
            listenerCancelled: cancelled, activeConnections: connections.count) }
    }
    func readyBaseURL() throws -> String {
        try lock.withLock {
            guard let base, errors.isEmpty else { throw NativeReaderTestError.failed("Listener not ready: \(errors)") }
            return base
        }
    }
    func start(ready: @escaping () -> Void) {
        lock.withLock { readyCallback = ready }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lock.withLock {
                    if let port = self.listener.port { self.base = "http://127.0.0.1:\(port.rawValue)/\(self.runID)" }
                    else { self.errors.append("Listener has no port") }
                }
                self.signalReady()
            case .failed(let error): self.recordError("Listener failed: \(error)"); self.signalReady()
            case .cancelled: self.lock.withLock { self.cancelled = true }; self.signalReady(); self.finishStop()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.accept(connection)
        }
        listener.start(queue: queue)
    }
    func armHeldBody(headersSent: @escaping () -> Void, peerClosed: @escaping () -> Void) {
        lock.withLock { holdNext = true; headersCallback = headersSent; peerCallback = peerClosed }
    }
    func stop(completed: @escaping () -> Void) {
        let open = lock.withLock { stopping = true; stopCallback = completed; return Array(connections.values) }
        listener.newConnectionHandler = nil
        listener.cancel()
        open.forEach { $0.cancel() }
        finishStop()
    }
    private func signalReady() {
        let callback = lock.withLock { let value = readyCallback; readyCallback = nil; return value }
        callback?()
    }
    private func finishStop() {
        let callback = lock.withLock { () -> (() -> Void)? in
            guard stopping, cancelled, connections.isEmpty else { return nil }
            let value = stopCallback; stopCallback = nil; return value
        }
        callback?()
    }
    private func recordError(_ value: String) { lock.withLock { errors.append(value) } }
    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let accepted = lock.withLock { () -> Bool in
            guard !stopping else { return false }
            connections[id] = connection
            return true
        }
        guard accepted else { connection.cancel(); return }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let error):
                if !self.isExpectedPeerClose(error, id: id) { self.recordError("Connection failed: \(error)") }
                connection.cancel()
            case .cancelled:
                connection.stateUpdateHandler = nil
                _ = self.lock.withLock { self.connections.removeValue(forKey: id) }
                self.finishStop()
            default: break
            }
        }
        connection.start(queue: queue)
        receive(connection, id: id, data: Data())
    }
    private func receive(_ connection: NWConnection, id: UUID, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] chunk, _, done, error in
            guard let self else { connection.cancel(); return }
            var bytes = data
            if let chunk { bytes.append(chunk) }
            guard error == nil, bytes.count < 65_536 else { self.recordError("Invalid fixture request size/transport"); connection.cancel(); return }
            if let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) {
                do { try self.respond(connection, id: id, bytes: bytes, boundary: boundary) }
                catch { self.recordError(String(describing: error)); connection.cancel() }
            } else if !done { self.receive(connection, id: id, data: bytes) }
            else { self.recordError("Incomplete request headers"); connection.cancel() }
        }
    }
    private func respond(_ connection: NWConnection, id: UUID, bytes: Data, boundary: Range<Data.Index>) throws {
        guard bytes.count == boundary.upperBound,
              let head = String(data: bytes[..<boundary.lowerBound], encoding: .utf8) else { throw NativeReaderTestError.failed("Expected header-only GET") }
        let lines = head.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ").map(String.init)
        guard first.count == 3, first[0] == "GET", first[2] == "HTTP/1.1" else { throw NativeReaderTestError.failed("Unexpected request line") }
        let target = first[1]
        let headers = try lines.dropFirst().map { line -> (String, String) in
            guard let colon = line.firstIndex(of: ":") else { throw NativeReaderTestError.failed("Malformed request header") }
            return (String(line[..<colon]).lowercased(), String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        }
        guard !headers.contains(where: { $0.0 == "transfer-encoding" || ($0.0 == "content-length" && $0.1 != "0") }) else {
            throw NativeReaderTestError.failed("Unexpected GET body")
        }
        let base = try readyBaseURL()
        let prefix = "/\(runID)"
        let body: String
        if target == prefix + "/search?key=native-query&page=1" {
            let books: [[String: Any]] = [["bookUrl": base + "/book", "tocUrl": base + "/toc", "name": "Native Book", "author": "Fixture",
                                          "type": 8, "variable": #"{"search":"wire"}"#]]
            body = try Self.json(books)
        } else if target == prefix + "/details" {
            let details: [String: Any] = ["intro": "Details fetched over native TCP", "tocUrl": base + "/toc", "variable": ["detail": "wire"]]
            body = try Self.json(details)
        } else if target == prefix + "/toc" {
            body = try Self.json((1...2).map { ["url": base + "/content/\($0)", "title": "Chapter \($0)", "variable": "{\"chapter\":\($0)}"] })
        } else if target == prefix + "/content/1" { body = "RAW_ONE" }
        else if target == prefix + "/content/2" { body = "RAW_TWO" }
        else { throw NativeReaderTestError.failed("Unknown fixture route: \(target)") }
        let entry = lock.withLock { () -> (Int, Bool) in
            let held = holdNext && target == prefix + "/content/1"
            if held { holdNext = false; heldConnection = id }
            let index = requests.count
            requests.append(Request(method: first[0], target: target, rawRequestBase64: bytes.base64EncodedString(),
                fixtureHeader: headers.first(where: { $0.0 == "x-legado-native-fixture" })?.1 ?? "", responseBody: body, heldBody: held))
            return (index, held)
        }
        guard entry.0 < 16 else { throw NativeReaderTestError.failed("Fixture request limit exceeded") }
        let content = Data(body.utf8)
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(content.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(entry.1 ? Data(content.prefix(1)) : content)
        connection.send(content: response, contentContext: entry.1 ? .defaultMessage : .finalMessage, isComplete: !entry.1,
            completion: .contentProcessed { [weak self] error in
                guard let self else { connection.cancel(); return }
                if let error { self.recordError("Response write failed: \(error)"); connection.cancel(); return }
                let callback = self.lock.withLock { () -> (() -> Void)? in
                    self.requests[entry.0].headersSent = true
                    self.requests[entry.0].completeResponseWritten = !entry.1
                    guard entry.1 else { return nil }
                    self.heldHeaders = true
                    self.heldHeadersAtEpochMs = Date().timeIntervalSince1970 * 1000
                    let value = self.headersCallback; self.headersCallback = nil; return value
                }
                if entry.1 { self.monitorPeer(connection, id: id); callback?() }
                else { connection.cancel() }
            })
    }
    private func monitorPeer(_ connection: NWConnection, id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] bytes, _, done, error in
            guard let self else { connection.cancel(); return }
            if done && error == nil && (bytes == nil || bytes?.isEmpty == true) { self.signalPeerClose(id: id) }
            else if let error, self.isExpectedPeerClose(error, id: id) { /* Recorded reset from the cancelled client. */ }
            else { self.recordError("Held connection did not end with peer EOF/reset") }
            connection.cancel()
        }
    }
    private func isExpectedPeerClose(_ error: NWError, id: UUID) -> Bool {
        guard case .posix(.ECONNRESET) = error, lock.withLock({ heldConnection == id && !stopping }) else { return false }
        signalPeerClose(id: id)
        return true
    }
    private func signalPeerClose(id: UUID) {
        let callback = lock.withLock { () -> (() -> Void)? in
            guard heldConnection == id, !stopping else { return nil }
            peerClosed = true
            heldPeerClosedAtEpochMs = Date().timeIntervalSince1970 * 1000
            let value = peerCallback; peerCallback = nil; return value
        }
        callback?()
    }
    private static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
}
