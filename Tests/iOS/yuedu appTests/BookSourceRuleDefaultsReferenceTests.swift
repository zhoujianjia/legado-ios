import CryptoKit
import Foundation
import Testing
@testable import yuedu_app

/// Collects the existing model's real values for a separate comparison report.
/// A passing observer means collection completed, never original-rule parity.
/// Intentionally excluded from the established zero-failure smoke selection.
@Suite("Original rule defaults: fixture contracts and observation only", .serialized)
struct BookSourceRuleDefaultsReferenceTests {
    @Test("the forty public original getter/default-Gson/serializeNulls observations remain distinct")
    func originalReferenceContracts() throws {
        let rows = try referenceRows()
        #expect(rows.count == 40)
        #expect(Set(rows.map(\.identity)).count == 40)
        for model in RuleModel.allCases {
            #expect(Set(rows.filter { $0.model == model.rawValue }.map(\.form)) == Set(Self.forms))
        }
        for row in rows {
            #expect(row.inputHasField == (row.form != "absent"))
            #expect(row.getterReturnType == "java.lang.String")
            switch row.getterValue {
            case .null:
                #expect(row.defaultGson[row.field] == nil)
                #expect(row.serializeNullsGson[row.field] == .null)
            case .text(let value):
                #expect(row.defaultGson[row.field]?.bytes == Data(value.utf8))
                #expect(row.serializeNullsGson[row.field]?.bytes == Data(value.utf8))
            }
            if row.form == "number-exponent" {
                #expect(row.inputValueJSON == "1e3")
                #expect(row.getterValue.bytes == Data("1e3".utf8))
            }
            if row.form == "object" || row.form == "array" {
                #expect(row.getterValue.bytes == Data(row.inputValueJSON.utf8))
            }
            if row.form == "empty" { #expect(row.getterValue.bytes == Data()) }
            if row.form == "whitespace" {
                #expect(row.getterValue.bytes == Data(" \t\r\n\u{2003} ".utf8))
            }
        }
    }

    @Test("observe actual Swift getters and each real import/editor/export route without declaring parity")
    func observeCurrentSwiftRepresentation() throws {
        for row in try referenceRows() {
            let model = try #require(RuleModel(rawValue: row.model))
            let rawRule = row.inputHasField
                ? "{" + (try quoted(row.field)) + ":" + row.inputValueJSON + "}"
                : "{}"
            // inputValueJSON came from the locked Gson JsonElement. Never parse
            // and re-encode it through Any/Double: the 1e3 token is intentional.
            let direct = try model.decodeRule(Data(rawRule.utf8))
            try emit(Observation(kind: "originalRule", identity: row.identity, route: "direct-rule",
                snapshots: [Snapshot(stage: "decoded-rule", getterValue: .init(direct.getter), encodedJSON: direct.json)]))
            for doubleEncoded in [false, true] {
                let ruleWire = doubleEncoded ? try quoted(rawRule) : rawRule
                let sourceJSON = "{\"id\":\"00000000-0000-0000-0000-000000000040\","
                    + "\"bookSourceName\":\"Public original fixture\",\"bookSourceUrl\":\"https://rule-defaults.invalid\","
                    + (try quoted(model.sourceKey)) + ":" + ruleWire + "}"
                for shape in ImportShape.allCases {
                    let imported = try #require(BookSourceStore.parseSources(shape.wrap(sourceJSON))?.first)
                    let editedJSON = try editKnownName(imported.importEditableJSON)
                    let edited = try #require(BookSource.importParse(editedJSON: editedJSON))
                    let restored = try #require(try JSONDecoder().decode([BookSource].self,
                        from: JSONEncoder().encode([edited])).first)
                    #expect(imported.id == edited.id && edited.id == restored.id)
                    #expect(edited.bookSourceName == "Public original fixture edited")
                    let snapshots = try [("imported", imported), ("edited", edited), ("export-reloaded", restored)].map { stage, source in
                        Snapshot(stage: stage, getterValue: .init(model.getter(source)), encodedJSON: try model.encodedRule(source))
                    }
                    try emit(Observation(kind: "originalRule", identity: row.identity,
                        route: shape.rawValue + (doubleEncoded ? ":string-rule" : ":object-rule"), snapshots: snapshots))
                }
            }
        }
    }

    @Test("observe unknown fields through the original import/editor/export/writer chain")
    func observeUnknownFieldRoutes() throws {
        let fixtureURL = Self.root.appendingPathComponent("Tests/iOS/yuedu appTests/Fixtures/RuleDefaultsReference/unknown-field-cases.jsonl")
        let rows = try String(contentsOf: fixtureURL, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(UnknownRow.self, from: Data($0.utf8))
        }
        #expect(rows.count == 13 && Set(rows.map(\.identity)).count == 13)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RuleUnknownObservation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("Could not remove owned reference directory: \(error)") }
        }
        for row in rows {
            for shape in ImportShape.allCases {
                let imported = try #require(BookSourceStore.parseSources(shape.wrap(row.sourceJSON))?.first)
                let edited = try #require(BookSource.importParse(editedJSON: try editKnownName(imported.importEditableJSON)))
                let exported = try JSONEncoder().encode([edited])
                let restored = try #require(try JSONDecoder().decode([BookSource].self, from: exported).first)
                let file = directory.appendingPathComponent("owned-library.json")
                try BookSourceStore.writeLibrary([edited], to: file)
                let stored = try #require(try JSONDecoder().decode([BookSource].self, from: Data(contentsOf: file)).first)
                #expect(imported.id == edited.id && edited.id == restored.id && restored.id == stored.id)
                let snapshots = try [("imported", imported), ("edited", edited), ("export-reloaded", restored), ("stored-reloaded", stored)].map { stage, source in
                    Snapshot(stage: stage, getterValue: .null, encodedJSON: try json(source))
                }
                try emit(Observation(kind: "unknownField", identity: row.identity, route: shape.rawValue, snapshots: snapshots))
            }
        }
    }

    private static let forms = ["absent", "null", "empty", "whitespace", "boolean", "number-exponent", "object", "array"]
    private static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private func referenceRows() throws -> [ReferenceRow] {
        let files = [
            ("rule-defaults-original-cases.json", "78cb973cc7fb97a8bdb32ff13c202c31e1d6c0966c31428c4faf101c01dc1f44"),
            ("rule-defaults-original-results.jsonl", "467bbfe63a14a0f99acfb8e90a40391fdd43077cee5a67b09de52d0e162c931f"),
            ("rule-defaults-original-probe.kt", "f0f01a42b4fc70e4e1972e2516eb8a9d509bf437fa06b96c41d63698718524d1"),
            ("rule-defaults-original-provenance.json", "a37cc35b48e234dbea0a48bd39d7980df4cb9b0684ba3b5d7a671bdbf65cbf0e"),
        ]
        var result: [ReferenceRow] = []
        for (name, expected) in files {
            let data = try Data(contentsOf: Self.root.appendingPathComponent("docs/legado-ios/fixtures/" + name))
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(digest == expected, "The original reference evidence must remain frozen")
            if name.hasSuffix("results.jsonl") {
                result = try String(decoding: data, as: UTF8.self).split(separator: "\n").map {
                    try JSONDecoder().decode(ReferenceRow.self, from: Data($0.utf8))
                }
            }
        }
        return result
    }
    private func quoted(_ value: String) throws -> String { try json(value) }
    private func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    private func editKnownName(_ raw: String) throws -> String {
        let from = try quoted("Public original fixture"), to = try quoted("Public original fixture edited")
        #expect(raw.components(separatedBy: from).count == 2)
        return raw.replacingOccurrences(of: from, with: to)
    }
    private func emit(_ observation: Observation) throws {
        print("SOURCE_RULE_DEFAULTS_SWIFT " + (try json(observation)))
    }

    private enum ImportShape: String, CaseIterable {
        case single, array, envelope
        func wrap(_ source: String) -> String {
            switch self { case .single: return source; case .array: return "[" + source + "]"
            case .envelope: return "{\"bookSources\":[" + source + "]}" }
        }
    }
    private enum RuleModel: String, CaseIterable {
        case search = "SearchRule", explore = "ExploreRule", bookInfo = "BookInfoRule", toc = "TocRule", content = "ContentRule"
        var sourceKey: String {
            switch self { case .search: return "ruleSearch"; case .explore: return "ruleExplore"
            case .bookInfo: return "ruleBookInfo"; case .toc: return "ruleToc"; case .content: return "ruleContent" }
        }
        func getter(_ source: BookSource) -> String? {
            switch self { case .search: return source.ruleSearch.checkKeyWord; case .explore: return source.ruleExplore.bookList
            case .bookInfo: return source.ruleBookInfo.initScript; case .toc: return source.ruleToc.chapterList
            case .content: return source.ruleContent.callBackJs }
        }
        func encodedRule(_ source: BookSource) throws -> String {
            switch self { case .search: return try encode(source.ruleSearch); case .explore: return try encode(source.ruleExplore)
            case .bookInfo: return try encode(source.ruleBookInfo); case .toc: return try encode(source.ruleToc)
            case .content: return try encode(source.ruleContent) }
        }
        func decodeRule(_ data: Data) throws -> (getter: String?, json: String) {
            let decoder = JSONDecoder()
            switch self {
            case .search: let value = try decoder.decode(SearchRule.self, from: data); return (value.checkKeyWord, try encode(value))
            case .explore: let value = try decoder.decode(ExploreRule.self, from: data); return (value.bookList, try encode(value))
            case .bookInfo: let value = try decoder.decode(BookInfoRule.self, from: data); return (value.initScript, try encode(value))
            case .toc: let value = try decoder.decode(TOCRule.self, from: data); return (value.chapterList, try encode(value))
            case .content: let value = try decoder.decode(ContentRule.self, from: data); return (value.callBackJs, try encode(value))
            }
        }
        private func encode<T: Encodable>(_ value: T) throws -> String {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return String(decoding: try encoder.encode(value), as: UTF8.self)
        }
    }
    private enum NullableText: Codable, Equatable {
        case null, text(String)
        init(_ value: String?) { self = value.map(Self.text) ?? .null }
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self = container.decodeNil() ? .null : .text(try container.decode(String.self))
        }
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self { case .null: try container.encodeNil(); case .text(let value): try container.encode(value) }
        }
        var bytes: Data? { if case .text(let value) = self { return Data(value.utf8) }; return nil }
        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.null, .null): return true
            case (.text(let left), .text(let right)): return Data(left.utf8) == Data(right.utf8)
            default: return false
            }
        }
    }
    private struct ReferenceRow: Decodable {
        let model: String, field: String, getter: String, form: String
        let inputHasField: Bool, inputValueJSON: String, getterReturnType: String
        let getterValue: NullableText
        let defaultGson: [String: NullableText], serializeNullsGson: [String: NullableText]
        var identity: String { model + "/" + form }
    }
    private struct UnknownRow: Decodable { let identity: String, sourceJSON: String }
    private struct Snapshot: Encodable { let stage: String, getterValue: NullableText, encodedJSON: String }
    private struct Observation: Encodable {
        let kind: String, identity: String, route: String, snapshots: [Snapshot]
    }
}
