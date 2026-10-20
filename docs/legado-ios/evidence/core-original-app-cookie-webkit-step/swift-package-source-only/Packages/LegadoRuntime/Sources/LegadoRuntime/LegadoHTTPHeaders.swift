import Foundation

/// One HTTP field line. Repeated names are represented by separate entries.
public struct LegadoHTTPHeader: Codable, Equatable, Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// The current bridge sends an ordered array. Older callers may still supply a
/// single-value object; decoding it cannot recover repetitions already lost there.
public struct LegadoHTTPHeaders: Codable, Equatable, Sendable {
    public let entries: [LegadoHTTPHeader]

    public init(entries: [LegadoHTTPHeader]) { self.entries = entries }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            entries = try container.decode([LegadoHTTPHeader].self)
        } catch DecodingError.typeMismatch(_, let context) where context.codingPath.count == decoder.codingPath.count {
            let legacy = try container.decode([String: String].self)
            entries = legacy.map { LegadoHTTPHeader(name: $0.key, value: $0.value) }.sorted { $0.name < $1.name }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entries)
    }

    public func values(for name: String) -> [String] {
        entries.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    /// URLRequest has a single-value header dictionary. Reject repeated field
    /// names before creating a request instead of silently merging their values.
    /// This adapter does not establish equivalence to OkHttp's on-wire request.
    internal func urlSessionFields() throws -> [String: String] {
        var seen = Set<String>()
        var fields: [String: String] = [:]
        let token = Set("!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
        for entry in entries {
            guard !entry.name.isEmpty, entry.name.utf8.allSatisfy(token.contains),
                  entry.value.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }) else {
                throw LegadoRuntimeError(code: "invalid_http_header", message: "Invalid HTTP header field")
            }
            guard seen.insert(entry.name.lowercased()).inserted else {
                throw LegadoRuntimeError(code: "unsupported_duplicate_headers",
                    message: "URLSession cannot preserve repeated HTTP field lines: \(entry.name). An ordered-header transport is required.")
            }
            fields[entry.name] = entry.value
        }
        return fields
    }
}
