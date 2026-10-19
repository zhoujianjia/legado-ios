import Foundation
import Testing
@testable import yuedu_app

@Suite("Book source content-rule field preservation", .serialized)
struct BookSourceContentRulePreservationTests {
    // Synthetic text only, never evaluated. Preserve whitespace and decomposed Unicode.
    private let subContent = " \t\r\n// 子正文 e\u{301}\r\n@js:result;\r\n "
    private let contentBatch = " \r\n@js:chapterList.map(item => item.url);\t "

    @Test("legacy absent and null fields stay optional and do not appear on export")
    func legacyRulesRemainCompatible() throws {
        for json in ["{}", #"{"subContent":null,"contentBatch":null,"maxBatchSize":null}"#] {
            let rule = try JSONDecoder().decode(ContentRule.self, from: Data(json.utf8))
            #expect(rule.subContent == nil)
            #expect(rule.contentBatch == nil)
            #expect(rule.maxBatchSize == nil)
            let exported = try ruleObject(rule)
            #expect(exported["subContent"] == nil)
            #expect(exported["contentBatch"] == nil)
            #expect(exported["maxBatchSize"] == nil)
        }
    }

    @Test("object and double-encoded rules survive each import shape, editor and export",
          arguments: [false, true])
    func importEditorAndExportPreserveFields(doubleEncodedRule: Bool) throws {
        let rule: [String: Any] = ["content": "#content@html", "subContent": subContent,
                                 "contentBatch": contentBatch, "maxBatchSize": 4]
        let ruleValue: Any = doubleEncodedRule
            ? String(decoding: try JSONSerialization.data(withJSONObject: rule), as: UTF8.self)
            : rule
        let identity = UUID()
        let object: [String: Any] = ["id": identity.uuidString,
            "bookSourceName": "Owned content-rule fixture", "bookSourceUrl": "https://content-rule.invalid",
            "bookSourceGroup": "Fixture,Owned", "ruleContent": ruleValue]
        let shapes: [Any] = [object, [object], ["bookSources": [object]]]
        for shape in shapes {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: shape), as: UTF8.self)
            let imported = try #require(BookSourceStore.parseSources(json)?.first)
            try expectFields(imported)
            #expect(imported.id == identity)
            #expect(imported.bookSourceGroup == "Fixture,Owned")

            let edited = try #require(BookSource.importParse(editedJSON: imported.importEditableJSON))
            try expectFields(edited)
            #expect(edited.id == imported.id)
            #expect(edited.hasSameContent(as: imported))
            let restored = try #require(try JSONDecoder().decode([BookSource].self,
                from: JSONEncoder().encode([edited])).first)
            try expectFields(restored)
            #expect(restored.hasSameContent(as: imported))
        }

        // Blank is a present original string, distinct from absent/null.
        for value in ["", " \t\r\n"] {
            let data = try JSONSerialization.data(withJSONObject: ["subContent": value, "contentBatch": value])
            let blank = try JSONDecoder().decode(ContentRule.self, from: data)
            let restored = try JSONDecoder().decode(ContentRule.self, from: JSONEncoder().encode(blank))
            #expect(restored.subContent == value)
            #expect(restored.contentBatch == value)
        }
    }

    @Test("batch-size numbers and integer strings preserve the original decoded value",
          arguments: ["0", "-1", "4", "50", "75", "4.0", "4.5", #""4""#, "2147483647", "-2147483648"])
    func batchSizeNumericForms(raw: String) throws {
        let json = #"{"content":"body@text","maxBatchSize":\#(raw)}"#
        let rule = try JSONDecoder().decode(ContentRule.self, from: Data(json.utf8))
        let expected: Int
        if ["4.0", "4.5", #""4""#].contains(raw) {
            expected = 4
        } else {
            expected = try #require(Int(raw))
        }
        #expect(rule.maxBatchSize == expected)
        #expect(try JSONDecoder().decode(ContentRule.self,
            from: JSONEncoder().encode(rule)).maxBatchSize == expected)
        // This is storage, so values outside the execution limit are not clamped.
        #expect(rule.content == "body@text")
    }

    @Test("malformed or unrepresentable batch sizes stay absent without erasing other rules",
          arguments: [#""bad""#, #""4.0""#, "true", "{}", "[]", "2147483648", "-2147483649", "9223372036854775808"])
    func invalidBatchSizesDoNotFabricateZero(raw: String) throws {
        let json = #"{"content":"body@text","subContent":"kept","contentBatch":"batch()","maxBatchSize":\#(raw)}"#
        let rule = try JSONDecoder().decode(ContentRule.self, from: Data(json.utf8))
        #expect(rule.maxBatchSize == nil)
        #expect(rule.content == "body@text")
        #expect(rule.subContent == "kept")
        #expect(rule.contentBatch == "batch()")
        #expect(try ruleObject(rule)["maxBatchSize"] == nil)
    }

    @Test("edits to each carried field participate in the existing content comparison")
    func editsParticipateInContentComparison() throws {
        let original = fixtureSource()
        var subContentEdit = original
        subContentEdit.ruleContent.subContent = subContent + " "
        #expect(!original.hasSameContent(as: subContentEdit))
        var batchEdit = original
        batchEdit.ruleContent.contentBatch = contentBatch + " "
        #expect(!original.hasSameContent(as: batchEdit))
        var sizeEdit = original
        sizeEdit.ruleContent.maxBatchSize = 5
        #expect(!original.hasSameContent(as: sizeEdit))
    }

    @Test("the existing streamed library writer preserves content-rule fields for reload")
    func storedLibraryPreservesFields() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookSourceContentRulePreservation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Could not remove owned source fixture: \(error)") }
        }
        let url = root.appendingPathComponent("book_sources.json")
        let source = fixtureSource()
        try BookSourceStore.writeLibrary([source], to: url)
        let restored = try #require(try JSONDecoder().decode([BookSource].self,
            from: Data(contentsOf: url)).first)
        try expectFields(restored)
        #expect(restored.id == source.id)
        #expect(restored.hasSameContent(as: source))
    }

    private func fixtureSource() -> BookSource {
        var source = BookSource(bookSourceUrl: "https://content-rule.invalid", bookSourceName: "Owned content-rule fixture")
        source.ruleContent.subContent = subContent
        source.ruleContent.contentBatch = contentBatch
        source.ruleContent.maxBatchSize = 4
        return source
    }

    private func ruleObject(_ rule: ContentRule) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as? [String: Any])
    }

    private func expectFields(_ source: BookSource) throws {
        #expect(source.ruleContent.subContent == subContent)
        #expect(source.ruleContent.contentBatch == contentBatch)
        #expect(source.ruleContent.maxBatchSize == 4)
        let encoded = try ruleObject(source.ruleContent)
        #expect(Data(try #require(encoded["subContent"] as? String).utf8) == Data(subContent.utf8))
        #expect(Data(try #require(encoded["contentBatch"] as? String).utf8) == Data(contentBatch.utf8))
        #expect(encoded["maxBatchSize"] as? Int == 4)
    }
}
