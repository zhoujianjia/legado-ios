import Foundation
import CLegadoJNI
import os

public struct LegadoRuntimeError: Error, LocalizedError, Codable, Sendable, Equatable {
    public let code: String
    public let message: String
    public init(code: String, message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { "\(code): \(message)" }
}

public struct LegadoSourceSession: Hashable, Sendable {
    public let id: String
    public let sourceMode: LegadoSessionOptions.SourceMode
    public init(id: String, sourceMode: LegadoSessionOptions.SourceMode = .existing) {
        self.id = id; self.sourceMode = sourceMode
    }
}

/// Runtime configuration stays separate from imported/exported book-source data.
public struct LegadoSessionOptions: Encodable, Sendable {
    public enum HTTPTransport: String, Encodable, Sendable {
        case platformHost = "platform-host"
        case jvmOkHttp = "jvm-okhttp"
    }
    public enum SourceMode: String, Encodable, Sendable, Hashable {
        case existing
        case originalTraditional = "original-traditional"
    }
    public let httpTransport: HTTPTransport
    public let userAgent: String?
    /// Granted explicitly by the embedding host; imported source JSON cannot
    /// choose this owner or a persistence path. Nil preserves isolated memory.
    public let stateOwner: String?
    public let sourceMode: SourceMode
    public init(httpTransport: HTTPTransport, userAgent: String? = nil, stateOwner: String? = nil, sourceMode: SourceMode = .existing) {
        self.httpTransport = httpTransport
        self.userAgent = userAgent
        self.stateOwner = stateOwner
        self.sourceMode = sourceMode
    }
    private enum CodingKeys: String, CodingKey { case httpTransport, userAgent, stateOwner, sourceMode }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(httpTransport, forKey: .httpTransport)
        try values.encodeIfPresent(userAgent, forKey: .userAgent)
        try values.encodeIfPresent(stateOwner, forKey: .stateOwner)
        // Preserve the previous embedding JSON for the default route.
        if sourceMode != .existing { try values.encode(sourceMode, forKey: .sourceMode) }
    }
}

public struct LegadoRuntimeDiagnostics: Sendable, Equatable {
    public let nativeBridgePresent: Bool
    public let available: Bool
    public let issues: [String]
    /// File inspection does not prove successful JVM startup or on-device compatibility.
    public let deviceValidationRequired: Bool
}

/// Experimental, opt-in runtime. It never changes the reader's production parser.
/// Keep one instance for the lifetime of the app: a JVM cannot be restarted in-process.
public final class LegadoRuntime: @unchecked Sendable {
    private static let logger = Logger(subsystem: "io.yuedu.legado.runtime", category: "JNI")
    public struct Configuration: Sendable {
        public let javaHome: URL
        public let classPath: [URL]
        public let maximumHeapMegabytes: Int
        public let diagnosticsDirectory: URL?
        public init(javaHome: URL, classPath: [URL], maximumHeapMegabytes: Int = 128, diagnosticsDirectory: URL? = nil) {
            self.javaHome = javaHome; self.classPath = classPath; self.maximumHeapMegabytes = maximumHeapMegabytes
            self.diagnosticsDirectory = diagnosticsDirectory
        }
        public static func bundled(in bundle: Bundle = .main) -> Configuration? {
            guard let resources = bundle.resourceURL else { return nil }
            let root = resources.appendingPathComponent("LegadoRuntime", isDirectory: true)
            let jars = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "jar" }.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
            let diagnostics = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("LegadoRuntimeDiagnostics", isDirectory: true)
            // A statically linked iOS JVM derives this home from the executable
            // before parsing -Djava.home. Keep the packaged location identical.
            return Configuration(javaHome: resources.appendingPathComponent("lib", isDirectory: true), classPath: jars, diagnosticsDirectory: diagnostics)
        }
    }

    private let configuration: Configuration
    private let transport: any LegadoRuntimeTransport
    private let host: any LegadoPlatformHost
    private let startupLock = NSLock()
    private var started = false

    public init(configuration: Configuration, host: any LegadoPlatformHost = UnsupportedLegadoHost()) {
        self.configuration = configuration; self.host = host; self.transport = NativeLegadoTransport(host: host)
    }
    internal init(configuration: Configuration, host: any LegadoPlatformHost, transport: any LegadoRuntimeTransport) {
        self.configuration = configuration; self.host = host; self.transport = transport
    }

    public static func diagnose(configuration: Configuration? = Configuration.bundled()) -> LegadoRuntimeDiagnostics {
        let present = LGRBridgeAvailable() != 0
        var issues: [String] = []
        if !present { issues.append("missing_runtime: build the pinned OpenJDK Mobile Zero XCFramework on macOS") }
        if let configuration {
            let manager = FileManager.default
            for module in ["java.base", "java.xml", "java.desktop", "java.datatransfer", "java.prefs", "java.logging", "jdk.charsets", "java.compiler", "java.instrument", "java.net.http", "java.sql", "java.transaction.xa", "jdk.unsupported"] {
                var directory: ObjCBool = false
                let path = configuration.javaHome.appendingPathComponent("modules/\(module)").path
                if !manager.fileExists(atPath: path, isDirectory: &directory) || !directory.boolValue {
                    issues.append("missing_module: \(module)")
                }
            }
            let probes = ["java.base/java/lang/Object.class", "java.xml/javax/xml/parsers/DocumentBuilderFactory.class", "java.desktop/java/beans/Introspector.class"]
            for probe in probes where !manager.fileExists(atPath: configuration.javaHome.appendingPathComponent("modules/\(probe)").path) {
                issues.append("missing_class: \(probe)")
            }
            let runtimeFiles = ["conf/security/java.security",
                                "conf/security/policy/unlimited/default_US_export.policy",
                                "conf/security/policy/unlimited/default_local.policy",
                                "lib/tzdb.dat", "lib/security/cacerts"]
            for file in runtimeFiles where !manager.isReadableFile(atPath: configuration.javaHome.appendingPathComponent(file).path) {
                issues.append("missing_runtime_file: \(file)")
            }
            if configuration.classPath.isEmpty { issues.append("missing_jars: bundled JVM facade and locked dependencies") }
            for jar in configuration.classPath where !manager.isReadableFile(atPath: jar.path) { issues.append("missing_jar: \(jar.lastPathComponent)") }
            if !(32...2048).contains(configuration.maximumHeapMegabytes) { issues.append("invalid_heap: expected 32...2048 MiB") }
        } else { issues.append("missing_configuration: runtime resources not found") }
        return LegadoRuntimeDiagnostics(nativeBridgePresent: present, available: issues.isEmpty, issues: issues, deviceValidationRequired: true)
    }

    /// Read on a worker/actor. This never starts a JVM, creates a directory or
    /// rotates evidence. Keys identify current/previous startup attempt files.
    public static func savedDiagnostics(configuration: Configuration? = Configuration.bundled()) throws -> [String: String] {
        guard let directory = configuration?.diagnosticsDirectory else { return [:] }
        return try LegadoSavedDiagnostics.read(directory)
    }

    public func createSession(sourceJSON: String, options: LegadoSessionOptions? = nil) async throws -> LegadoSourceSession {
        if options?.sourceMode == .originalTraditional {
            try await work {
                try Self.requireOriginalRequestBudget(sourceJSON.utf8.count)
                try Self.requireJSONObject(sourceJSON)
            }
        } else { try Self.requireJSONObject(sourceJSON) }
        let optionsJSON = try options.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        let response = try await work {
            try self.ensureStarted()
            if let optionsJSON { return try self.transport.createSession(sourceJSON, optionsJSON: optionsJSON) }
            return try self.transport.createSession(sourceJSON)
        }
        let envelope = try Self.envelope(response)
        guard let id = envelope.sessionId, !id.isEmpty else { throw LegadoRuntimeError(code: "invalid_response", message: "createSession omitted sessionId") }
        return LegadoSourceSession(id: id, sourceMode: options?.sourceMode ?? .existing)
    }

    /// Returns the complete JVM JSON envelope, keeping model conversion outside JNI.
    public func execute(session: LegadoSourceSession, operation: String, requestJSON: String = "{}", taskID: String = UUID().uuidString) async throws -> String {
        if session.sourceMode == .originalTraditional {
            try await work {
                try Self.requireOriginalRequestBudget(requestJSON.utf8.count)
                try Self.requireJSONObject(requestJSON)
            }
        } else { try Self.requireJSONObject(requestJSON) }
        guard !taskID.isEmpty, !operation.isEmpty else { throw LegadoRuntimeError(code: "invalid_request", message: "taskID and operation are required") }
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            let response = try await work {
                try self.ensureStarted()
                return try self.transport.execute(session.id, taskID, operation, requestJSON)
            }
            try Task.checkCancellation()
            _ = try Self.envelope(response)
            return response
        } onCancel: {
            // A different worker must deliver cancel while an execute worker is inside Rhino.
            self.enqueue {
                do { try self.ensureStarted(); _ = try self.transport.cancel(taskID) }
                catch { Self.logger.error("Could not deliver runtime cancellation: \(error.localizedDescription, privacy: .public)") }
            }
            Task { await self.host.cancel(taskID: taskID) }
        }
    }

    public func cancel(taskID: String) async throws {
        await host.cancel(taskID: taskID)
        let response = try await work { try self.ensureStarted(); return try self.transport.cancel(taskID) }
        _ = try Self.envelope(response)
    }
    public func close(session: LegadoSourceSession) async throws {
        let response = try await work { try self.ensureStarted(); return try self.transport.closeSession(session.id) }
        _ = try Self.envelope(response)
    }

    /// Opt-in retained WebBook business API. The host must grant the same source owner;
    /// missing Cookie/book/chapter capabilities remain typed runtime errors.
    public func searchOriginal(session: LegadoSourceSession, key: String, page: Int32? = 1,
                               timeoutMilliseconds: Int64 = 30_000, taskID: String = UUID().uuidString) async throws -> LegadoOriginalSearchResult {
        try await executeOriginal(session, "search", OriginalSearchRequest(key: key, page: page, timeoutMs: timeoutMilliseconds), timeoutMilliseconds, taskID)
    }
    public func detailsOriginal(session: LegadoSourceSession, book: LegadoOriginalBook, canReName: Bool = true,
                                timeoutMilliseconds: Int64 = 30_000, taskID: String = UUID().uuidString) async throws -> LegadoOriginalDetailsResult {
        try await executeOriginal(session, "details", OriginalDetailsRequest(book: book, canReName: canReName, timeoutMs: timeoutMilliseconds), timeoutMilliseconds, taskID)
    }
    public func chaptersOriginal(session: LegadoSourceSession, book: LegadoOriginalBook, runPreUpdateJs: Bool = false,
                                 isFromBookInfo: Bool = false, timeoutMilliseconds: Int64 = 30_000,
                                 taskID: String = UUID().uuidString) async throws -> LegadoOriginalChaptersResult {
        try await executeOriginal(session, "toc", OriginalChaptersRequest(book: book, runPreUpdateJs: runPreUpdateJs, isFromBookInfo: isFromBookInfo, timeoutMs: timeoutMilliseconds), timeoutMilliseconds, taskID)
    }
    /// Returns text and updated business entities; the existing App pipeline must own saving.
    /// No App UUID or ChapterCacheRepository generation is synthesized here.
    public func contentOriginal(session: LegadoSourceSession, book: LegadoOriginalBook, chapter: LegadoOriginalChapter,
                                nextChapterURL: String? = nil, timeoutMilliseconds: Int64 = 30_000,
                                taskID: String = UUID().uuidString) async throws -> LegadoOriginalContentResult {
        try await executeOriginal(session, "content", OriginalContentRequest(book: book, chapter: chapter, nextChapterUrl: nextChapterURL, timeoutMs: timeoutMilliseconds), timeoutMilliseconds, taskID)
    }
    private func executeOriginal<Request: Encodable & Sendable, Response: Decodable & Sendable>(
        _ session: LegadoSourceSession, _ operation: String, _ request: Request, _ timeoutMilliseconds: Int64, _ taskID: String
    ) async throws -> Response {
        guard session.sourceMode == .originalTraditional else {
            throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY", message: "Original business API requires an explicitly configured original-traditional session")
        }
        guard (1...300_000).contains(timeoutMilliseconds) else {
            throw LegadoRuntimeError(code: "INVALID_ARGUMENT", message: "timeout must be between 1 and 300000 milliseconds")
        }
        try Task.checkCancellation()
        let requestJSON = try await work {
            let data = try JSONEncoder().encode(request)
            try Self.requireOriginalRequestBudget(data.count)
            Self.logger.debug("original.dto.encode bytes=\(data.count) main=\(Thread.isMainThread)")
            return String(decoding: data, as: UTF8.self)
        }
        let raw = try await execute(session: session, operation: operation, requestJSON: requestJSON, taskID: taskID)
        let result: Response = try await work {
            // The JVM bounds the business result to 8 MiB; reserve a finite envelope allowance.
            guard raw.utf8.count <= 8 * 1024 * 1024 + 64 * 1024 else {
                throw LegadoRuntimeError(code: "PAYLOAD_TOO_LARGE", message: "Original response exceeds the bridge budget")
            }
            let data = Data(raw.utf8)
            Self.logger.debug("original.dto.decode bytes=\(data.count) main=\(Thread.isMainThread)")
            do { return try JSONDecoder().decode(OriginalBusinessEnvelope<Response>.self, from: data).result }
            catch { throw LegadoRuntimeError(code: "invalid_response", message: "Original runtime omitted or returned an incompatible business DTO") }
        }
        try Task.checkCancellation()
        return result
    }
    private static func requireOriginalRequestBudget(_ bytes: Int) throws {
        guard bytes <= 4 * 1024 * 1024 else {
            throw LegadoRuntimeError(code: "PAYLOAD_TOO_LARGE", message: "Original traditional request exceeds 4 MiB UTF-8")
        }
    }
    private func ensureStarted() throws {
        try startupLock.withLock {
            guard !started else { return }
            try transport.start(configuration)
            started = true
        }
    }
    private func work<T: Sendable>(_ action: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            enqueue { continuation.resume(with: Result(catching: action)) }
        }
    }
    private func enqueue(_ action: @escaping @Sendable () -> Void) {
        // Darwin workqueue threads can reject the pthread signal that the JVM
        // needs to interrupt socket I/O. Each invocation owns a regular thread;
        // cancellation must be able to enter while another invocation blocks.
        let thread = Thread(block: action)
        thread.qualityOfService = .userInitiated
        thread.start()
    }
    internal struct Envelope: Decodable { let ok: Bool; let sessionId: String?; let error: LegadoRuntimeError? }
    internal static func envelope(_ json: String) throws -> Envelope {
        guard let data = json.data(using: .utf8), let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw LegadoRuntimeError(code: "invalid_response", message: "JVM response is not an envelope")
        }
        if !envelope.ok { throw envelope.error ?? LegadoRuntimeError(code: "runtime_error", message: "JVM operation failed") }
        return envelope
    }
    private static func requireJSONObject(_ json: String) throws {
        guard let data = json.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw LegadoRuntimeError(code: "invalid_json", message: "Expected a JSON object")
        }
    }
}

internal protocol LegadoRuntimeTransport: Sendable {
    func start(_ configuration: LegadoRuntime.Configuration) throws
    func createSession(_ source: String) throws -> String
    func createSession(_ source: String, optionsJSON: String) throws -> String
    func execute(_ session: String, _ task: String, _ operation: String, _ request: String) throws -> String
    func cancel(_ task: String) throws -> String
    func closeSession(_ session: String) throws -> String
}

extension LegadoRuntimeTransport {
    func createSession(_ source: String, optionsJSON: String) throws -> String {
        throw LegadoRuntimeError(code: "unsupported_session_options", message: "This transport does not support configured sessions")
    }
}
