import Foundation
import Darwin
import LegadoRuntime
import os
import UIKit

/// Owns one process-scoped runtime and runs all inspection/JSON work off MainActor.
actor ProbeRunner {
    private let host = ProbeFixtureHost()
    private var runtime: LegadoRuntime?
    private let clock = ContinuousClock()
    private var measurements: [[String: Any]] = []
    private var running = false
    private var diagnosticsDirectory: URL?
    private let logger = Logger(subsystem: "local.legado.runtime-probe", category: "Fixture")

    func inspect() throws -> String {
        let diagnostics = LegadoRuntime.diagnose()
        return try json(["fixtureOnly": true, "nativeBridgePresent": diagnostics.nativeBridgePresent,
                         "payloadPreflightPassed": diagnostics.available, "deviceValidationRequired": true,
                         "issues": diagnostics.issues,
                         "sourceCommit": sourceCommit,
                         "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                         "buildNumber": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                         "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                         "hardwareIdentifier": hardwareIdentifier,
                         "packagedJavaHomeRelativePath": "lib",
                         "savedDiagnostics": try LegadoRuntime.savedDiagnostics(),
                         "probeProgress": try savedProgress()])
    }

    func failureReport(_ message: String) throws -> String {
        if diagnosticsDirectory != nil { try recordProgress("failed", failure: message) }
        return try json(["fixtureOnly": true, "passed": false, "failure": message,
                         "sourceCommit": sourceCommit,
                         "savedDiagnostics": try LegadoRuntime.savedDiagnostics(),
                         "probeProgress": try savedProgress()])
    }

    func shareableReport(_ report: String) throws -> URL {
        guard let directory = LegadoRuntime.Configuration.bundled()?.diagnosticsDirectory else {
            throw LegadoRuntimeError(code: "MISSING_DIAGNOSTICS_DIRECTORY", message: "No report export directory is configured")
        }
        let exports = directory.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let file = exports.appendingPathComponent("LegadoProbe-report.json")
        try Data(report.utf8).write(to: file, options: .atomic)
        return file
    }
    func run() async throws -> String {
        guard !running else { throw mismatch("A fixture is already running") }
        running = true
        defer { running = false }
        measurements.removeAll()
        let diagnostics = LegadoRuntime.diagnose()
        guard diagnostics.available, let configuration = LegadoRuntime.Configuration.bundled() else {
            throw LegadoRuntimeError(code: "MISSING_RUNTIME", message: diagnostics.issues.joined(separator: "\n"))
        }
        diagnosticsDirectory = configuration.diagnosticsDirectory
        try beginProgress()
        var device = await MainActor.run {
            let current = UIDevice.current
            return ["model": current.model, "systemName": current.systemName, "systemVersion": current.systemVersion]
        }
        device["hardwareIdentifier"] = hardwareIdentifier
        guard let payloadDirectory = Bundle.main.resourceURL?.appendingPathComponent("LegadoRuntime", isDirectory: true) else {
            throw LegadoRuntimeError(code: "MISSING_FIXTURE", message: "The runtime payload resource directory is absent")
        }
        // The JAR/manifest remain resources; the static JVM's Java home is a
        // separate sibling at App.app/lib. Neither path derives from the other.
        let manifestURL = payloadDirectory.appendingPathComponent("runtime-manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        guard let runtimeManifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
            throw mismatch("runtime-manifest.json is not a JSON object")
        }
        logger.notice("Starting synthetic JVM fixture; main=\(Thread.isMainThread)")
        let coldStart = runtime == nil
        let engine: LegadoRuntime
        if let existing = runtime { engine = existing }
        else { engine = LegadoRuntime(configuration: configuration, host: host); runtime = engine }
        await host.reset()
        guard let sourceURL = Bundle.main.url(forResource: "main-source", withExtension: "js") else {
            throw LegadoRuntimeError(code: "MISSING_FIXTURE", message: "main-source.js is absent")
        }
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let sourceJSON = try json(["bookSourceName": "Synthetic fixture", "bookSourceUrl": "https://fixture.invalid", "mainJs": source])
        let started = clock.now
        let memoryBefore = memory()
        try recordProgress("create_session.begin")
        let session = try await engine.createSession(sourceJSON: sourceJSON)
        let startupAndSessionMS = milliseconds(since: started)
        var closeAttempted = false
        do {
            try recordProgress("create_session.returned")
            let runtimeDiagnostics = try result(await call(engine, session, "diagnostics"))
            guard let runtimeValues = runtimeDiagnostics as? [String: Any],
                  let javaVersion = runtimeValues["javaVersion"] as? String, !javaVersion.isEmpty else {
                throw mismatch("Runtime diagnostics omitted the actual Java version")
            }
            let semanticSuite = try result(await call(engine, session, "semanticSuite", ["timeoutMs": 300_000]))
            try verifySemanticSuite(semanticSuite, javaVersion: javaVersion)
            let semantics = try result(await call(engine, session, "semanticProbe"))
            guard let semanticValues = semantics as? [String: Any], semanticValues["e4x"] as? String == "ok",
                  semanticValues["indirect"] as? String == "function", semanticValues["dynamicThis"] as? Bool == true,
                  semanticValues["legacy"] as? Int == 42 else { throw mismatch("Customized Rhino/E4X semantics") }
            guard try result(await call(engine, session, "login")) as? Bool == true else { throw mismatch("Login") }
            guard let books = try result(await call(engine, session, "search", ["key": "书", "page": 1])) as? [[String: Any]], let first = books.first,
                  first["name"] as? String == "Fixture" else { throw mismatch("Search") }
            guard let book = try result(await call(engine, session, "details", ["book": first])) as? [String: Any], book["intro"] as? String == "Introduction" else { throw mismatch("Details/Jsoup") }
            guard let chapters = try result(await call(engine, session, "toc", ["book": book])) as? [[String: Any]], chapters.count == 2 else { throw mismatch("TOC") }
            guard try result(await call(engine, session, "content", ["book": book, "chapter": chapters[0]])) as? String == "第一章\ncontent one" else { throw mismatch("Content") }
            guard let batch = try result(await call(engine, session, "batch", ["book": book, "chapters": chapters])) as? [String: Any],
                  (batch["saved"] as? [Any])?.count == 2, (batch["missing"] as? [Any])?.isEmpty == true else { throw mismatch("Batch") }
            let state = try result(await call(engine, session, "snapshot"))
            guard let snapshot = state as? [String: Any], let variables = snapshot["variables"] as? [String: Any],
                  variables["@variable"] as? String == "logged-in", let cache = snapshot["cache"] as? [String: Any],
                  cache["lastKey"] as? String == "书" else { throw mismatch("Source variable/cache state") }
            let cancelStarted = clock.now
            try recordProgress("cancellation.begin")
            try await verifyCancellation(engine, session: session)
            try recordProgress("cancellation.returned")
            measurements.append(["operation": "cancel", "milliseconds": milliseconds(since: cancelStarted)])
            try Task.checkCancellation()
            closeAttempted = true
            try recordProgress("close_session.begin")
            try await engine.close(session: session)
            let report: [String: Any] = ["fixtureOnly": true, "passed": true, "coldJVMStartAttempt": coldStart,
                "device": device, "executionPlatform": executionPlatform,
                "sourceCommit": sourceCommit, "runtimeManifest": runtimeManifest,
                "packagedJavaHomeRelativePath": "lib",
                "savedDiagnostics": try LegadoRuntime.savedDiagnostics(configuration: configuration),
                "probeProgress": try savedProgress(),
                "timingNote": "Includes durable diagnostic checkpoints and native journal writes; not production performance measurements.",
                "runtimeDiagnostics": runtimeDiagnostics, "runtimeJavaVersion": javaVersion,
                "semanticSuite": semanticSuite,
                "startupAndSessionMilliseconds": startupAndSessionMS, "totalMilliseconds": milliseconds(since: started),
                "payloadBytes": try payloadSize([configuration.javaHome, payloadDirectory]),
                "memoryBefore": memoryBefore, "memoryAfter": memory(), "steps": measurements,
                "semantics": semantics, "state": state, "requests": await host.capturedRequests(),
                "limits": "Covers the packaged original 25 JsEngineCapabilitiesTest cases, the explicit java.beans probe and synthetic mainJs fixtures. This is not exhaustive proof of Java collection, byte-array or overload conversion compatibility. Full G4 reference-trace parity and G5 network/browser timeouts, concurrent isolation and sustained sessions remain unverified. Peak RSS is process lifetime; payloadBytes excludes the linked native JVM binary. Gate 1 also requires launching Release on a physical iPhone from the Home Screen without a debugger."]
            let serialized = try json(report)
            try recordProgress("passed")
            return serialized
        } catch {
            let original = error
            if !closeAttempted {
                do { try await engine.close(session: session) }
                catch { throw LegadoRuntimeError(code: "PROBE_CLEANUP_FAILED", message: "\(original.localizedDescription); close: \(error.localizedDescription)") }
            }
            throw original
        }
    }

    private func call(_ engine: LegadoRuntime, _ session: LegadoSourceSession, _ operation: String, _ request: [String: Any] = [:]) async throws -> Data {
        let before = clock.now
        try recordProgress("execute.begin", operation: operation)
        let response = try await engine.execute(session: session, operation: operation, requestJSON: json(request))
        try recordProgress("execute.returned", operation: operation)
        measurements.append(["operation": operation, "milliseconds": milliseconds(since: before)])
        return Data(response.utf8)
    }
    private func result(_ response: Data) throws -> Any {
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any], let result = object["result"] else {
            throw LegadoRuntimeError(code: "INVALID_PROBE_RESPONSE", message: "JVM result is missing")
        }
        return result
    }

    private func verifySemanticSuite(_ report: Any, javaVersion: String) throws {
        guard let suite = report as? [String: Any] else {
            throw LegadoRuntimeError(code: "SEMANTIC_SUITE_FAILED", message: "Invalid semantic suite report:\n\(try json(["semanticSuite": report]))")
        }
        var failures: [String] = []
        if suite["suite"] as? String != "JsEngineCapabilitiesTest" { failures.append("Unexpected original test suite") }
        if suite["total"] as? Int != 25 || suite["passed"] as? Int != 25 || suite["failed"] as? Int != 0 || suite["skipped"] as? Int != 0 {
            failures.append("Expected 25 original tests passed, 0 failed and 0 skipped")
        }
        let tests = suite["tests"] as? [[String: Any]] ?? []
        let names = tests.compactMap { $0["name"] as? String }.filter { !$0.isEmpty }
        if tests.count != 25 || Set(names).count != 25 || !tests.allSatisfy({ $0["passed"] as? Bool == true }) {
            failures.append("Each of the 25 distinct original cases must report success")
        }
        if let beans = suite["javaBeans"] as? [String: Any] {
            if beans["passed"] as? Bool != true || beans["propertyName"] as? String != "value" || beans["readMethod"] as? String != "getValue" || beans["writeMethod"] as? String != "setValue" {
                failures.append("java.beans property introspection/read/write probe failed")
            }
        } else { failures.append("java.beans functional probe was omitted") }
        if suite["javaVersion"] as? String != javaVersion { failures.append("Semantic suite Java version differs from runtime diagnostics") }
        if !failures.isEmpty {
            // The existing UI displays thrown errors; retain every case/error there as
            // well as in successful reports, rather than reducing a failure to a count.
            throw LegadoRuntimeError(code: "SEMANTIC_SUITE_FAILED", message: failures.joined(separator: "\n") + "\n" + (try json(["semanticSuite": report])))
        }
    }

    private func verifyCancellation(_ engine: LegadoRuntime, session: LegadoSourceSession) async throws {
        let taskID = UUID().uuidString
        let ready = await host.cancellationSignal(taskID: taskID)
        let request = try json(["script": "java.ajax(baseUrl+'/cancel-ready');while(true){}", "timeoutMs": 5000])
        let host = self.host
        let pending = Task { () -> Result<String, Error> in
            let outcome: Result<String, Error>
            do { outcome = .success(try await engine.execute(session: session, operation: "evaluate", requestJSON: request, taskID: taskID)) }
            catch { outcome = .failure(error) }
            await host.executionEnded(taskID: taskID)
            return outcome
        }
        try await withTaskCancellationHandler {
            var signalled = false
            for await value in ready { signalled = value; break }
            guard signalled else {
                let outcome = await pending.value
                switch outcome {
                case .failure(let error): throw error
                case .success: throw mismatch("Cancellation script did not reach the host handshake")
                }
            }
            try await engine.cancel(taskID: taskID)
            let outcome = await pending.value
            switch outcome {
            case .failure(let error as LegadoRuntimeError) where error.code == "CANCELLED": break
            case .failure(let error): throw error
            case .success: throw mismatch("Cancelled infinite script reported success")
            }
        } onCancel: { pending.cancel() }
    }
    private func mismatch(_ step: String) -> LegadoRuntimeError { LegadoRuntimeError(code: "FIXTURE_MISMATCH", message: step) }
    private var sourceCommit: String { Bundle.main.object(forInfoDictionaryKey: "LegadoSourceCommit") as? String ?? "not_injected" }
    private var hardwareIdentifier: String {
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else { return "unknown" }
        return withUnsafeBytes(of: systemInfo.machine) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// A small operation checkpoint complements the lower-level JNI journal. It
    /// contains no book-source scripts, HTTP bodies, cookies, or account details.
    /// All disk access stays on this actor, never in a view or on MainActor.
    private func beginProgress() throws {
        guard let directory = diagnosticsDirectory else {
            throw LegadoRuntimeError(code: "MISSING_DIAGNOSTICS_DIRECTORY", message: "The probe requires a writable diagnostics directory")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let current = directory.appendingPathComponent("probe-progress.json")
        if FileManager.default.fileExists(atPath: current.path) {
            let previous = try readProgress(current)
            try JSONSerialization.data(withJSONObject: previous, options: [.sortedKeys])
                .write(to: directory.appendingPathComponent("previous-probe-progress.json"), options: .atomic)
        }
        try recordProgress("preparing_runtime")
    }

    private func recordProgress(_ stage: String, operation: String? = nil, failure: String? = nil) throws {
        guard let directory = diagnosticsDirectory else { return }
        var checkpoint: [String: Any] = ["stage": stage, "recordedAt": Date().timeIntervalSince1970,
                                       "sourceCommit": sourceCommit, "executionPlatform": executionPlatform,
                                       "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                                       "hardwareIdentifier": hardwareIdentifier,
                                       "processIdentifier": ProcessInfo.processInfo.processIdentifier]
        if let operation { checkpoint["operation"] = operation }
        if let failure { checkpoint["failure"] = String(failure.prefix(4096)) }
        let data = try JSONSerialization.data(withJSONObject: checkpoint, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent("probe-progress.json"), options: .atomic)
    }

    private func savedProgress() throws -> [String: Any] {
        guard let directory = LegadoRuntime.Configuration.bundled()?.diagnosticsDirectory else { return [:] }
        var result: [String: Any] = [:]
        for name in ["probe-progress.json", "previous-probe-progress.json"] {
            let file = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) { result[name] = try readProgress(file) }
        }
        return result
    }

    private func readProgress(_ file: URL) throws -> [String: Any] {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 32_768 else {
            throw LegadoRuntimeError(code: "INVALID_PROGRESS_FILE", message: "Probe checkpoint exceeds its size limit")
        }
        let data = try Data(contentsOf: file)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LegadoRuntimeError(code: "INVALID_PROGRESS_FILE", message: "Probe checkpoint is not a JSON object")
        }
        return object
    }
    private var executionPlatform: String {
#if targetEnvironment(simulator)
        "ios-simulator"
#else
        "ios-device"
#endif
    }
    private func json(_ object: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self) }
    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: clock.now).components
        return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
    }
    private func memory() -> [String: UInt64] {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return ["machError": UInt64(status)] }
        return ["residentBytes": UInt64(info.resident_size), "processLifetimePeakRSSBytes": UInt64(info.resident_size_max)]
    }
    private func payloadSize(_ folders: [URL]) throws -> UInt64 {
        var size: UInt64 = 0
        for folder in folders {
            guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
                throw mismatch("Cannot enumerate runtime payload")
            }
            for case let file as URL in files {
                let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if values.isRegularFile == true { size += UInt64(values.fileSize ?? 0) }
            }
        }
        return size
    }
}
