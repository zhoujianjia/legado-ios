import Foundation

internal enum LegadoSavedDiagnostics {
    // Read at most 704 KiB across both attempts, plus truncation notices. Keep the fatal
    // header/native frames and the tail containing VM options/runtime details.
    static let stageLimit = 32 * 1024
    static let outputLimit = 64 * 1024
    static let fatalLimit = 128 * 1024
    static let taskTraceLimit = 64 * 1024

    static func read(_ root: URL) throws -> [String: String] {
        var reports: [String: String] = [:]
        for attempt in ["current", "previous"] {
            let directory = root.appendingPathComponent(attempt, isDirectory: true)
            let files: [URL]
            do {
                let attributes = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard attributes.isDirectory == true, attributes.isSymbolicLink != true else {
                    throw LegadoRuntimeError(code: "invalid_diagnostics_path", message: "Diagnostics attempt must be a directory: \(attempt)")
                }
                files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            } catch let error as NSError where
                (error.domain == NSCocoaErrorDomain && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError)) ||
                (error.domain == NSPOSIXErrorDomain && error.code == Int(POSIXErrorCode.ENOENT.rawValue)) {
                continue
            }
            let fatal = files.filter { $0.lastPathComponent.hasPrefix("hs_err_pid") && $0.pathExtension == "log" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }.last
            for (name, limit) in [("stages.log", stageLimit), ("vm-output.log", outputLimit),
                                  ("native-task-events.jsonl", taskTraceLimit), ("runtime-events.jsonl", taskTraceLimit),
                                  (fatal?.lastPathComponent ?? "", fatalLimit)] where !name.isEmpty {
                guard let file = files.first(where: { $0.lastPathComponent == name }) else { continue }
                let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else {
                    throw LegadoRuntimeError(code: "invalid_diagnostics_file", message: "Diagnostics must be a regular file: \(attempt)/\(name)")
                }
                reports["\(attempt)/\(name)"] = try boundedText(file, limit: limit)
            }
        }
        return reports
    }

    private static func boundedText(_ url: URL, limit: Int) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        do {
            let size = try file.seekToEnd()
            try file.seek(toOffset: 0)
            let text: String
            if size <= UInt64(limit) {
                let data = try file.read(upToCount: limit) ?? Data()
                text = String(decoding: data, as: UTF8.self)
            } else {
                let half = limit / 2
                let head = try file.read(upToCount: half) ?? Data()
                try file.seek(toOffset: size - UInt64(half))
                let tail = try file.read(upToCount: half) ?? Data()
                text = String(decoding: head, as: UTF8.self)
                    + "\n[truncated: retaining first and last \(half) bytes of \(size)]\n"
                    + String(decoding: tail, as: UTF8.self)
            }
            try file.close()
            return text
        } catch {
            let readError = error
            do { try file.close() }
            catch {
                throw LegadoRuntimeError(code: "diagnostics_read_failed", message: "\(readError.localizedDescription); close: \(error.localizedDescription)")
            }
            throw readError
        }
    }
}
