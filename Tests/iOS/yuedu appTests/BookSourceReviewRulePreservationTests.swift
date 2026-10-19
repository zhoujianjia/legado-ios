import Foundation
import Testing
@testable import yuedu_app

@Suite("Book source review-rule field preservation", .serialized)
struct BookSourceReviewRulePreservationTests {
    // The 29 nullable text fields in the pinned original ReviewRule.kt. All
    // fixtures are synthetic wire data; none of these rules is executed.
    private static let textFields = [
        "reviewUrl", "avatarRule", "contentRule", "postTimeRule", "reviewQuoteUrl",
        "voteUpUrl", "voteDownUrl", "postReviewUrl", "postQuoteUrl", "deleteUrl",
        "reviewSummaryUrl", "summaryListRule", "summaryParagraphIndexRule",
        "summaryParagraphDataRule", "summaryCountRule", "reviewDetailUrl",
        "reviewDetailNextPageUrl", "detailListRule", "detailIdRule", "detailAvatarRule",
        "detailNameRule", "detailBadgeRule", "detailContentRule", "replyListRule",
        "replyIdRule", "replyAvatarRule", "replyNameRule", "replyBadgeRule", "replyContentRule",
    ]

    @Test("absent and null original fields preserve legacy data and default to disabled")
    func legacyAndNullRulesRemainCompatible() throws {
        var nulls = Dictionary(uniqueKeysWithValues: Self.textFields.map { ($0, NSNull() as Any) })
        nulls["enabled"] = NSNull()
        nulls["review"] = "legacy@text"
        let cases: [[String: Any]] = [["review": "legacy@text"], nulls]
        for object in cases {
            let rule = try JSONDecoder().decode(ReviewRule.self,
                from: JSONSerialization.data(withJSONObject: object))
            #expect(rule.review == "legacy@text")
            #expect(!rule.enabled)
            let encoded = try wireObject(rule)
            #expect(encoded["review"] as? String == "legacy@text")
            #expect(encoded["enabled"] as? Bool == false)
            for field in Self.textFields {
                #expect(encoded[field] == nil, "Absent/null review field must remain optional: \(field)")
            }
        }
    }

    @Test("object and double-encoded review rules survive import, raw JSON editing and export",
          arguments: [false, true])
    func importEditorAndExportPreserveEveryField(doubleEncodedRule: Bool) throws {
        let rule = fixtureRule()
        let encodedRule: Any = doubleEncodedRule
            ? String(decoding: try JSONSerialization.data(withJSONObject: rule), as: UTF8.self)
            : rule
        let identity = UUID()
        let object: [String: Any] = ["id": identity.uuidString,
            "bookSourceUrl": "https://review-rule.invalid", "bookSourceName": "Owned review-rule fixture",
            "bookSourceGroup": "Fixture,Owned", "ruleReview": encodedRule]
        let shapes: [Any] = [object, [object], ["bookSources": [object]]]
        for shape in shapes {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: shape), as: UTF8.self)
            let imported = try #require(BookSourceStore.parseSources(json)?.first)
            try expectFields(imported, equals: rule)
            #expect(imported.id == identity)
            #expect(imported.bookSourceGroup == "Fixture,Owned")

            let edited = try #require(BookSource.importParse(editedJSON: imported.importEditableJSON))
            try expectFields(edited, equals: rule)
            #expect(edited.id == identity)
            #expect(edited.hasSameContent(as: imported))
            let restored = try #require(try JSONDecoder().decode([BookSource].self,
                from: JSONEncoder().encode([edited])).first)
            try expectFields(restored, equals: rule)
            #expect(restored.hasSameContent(as: imported))
        }
    }

    @Test("present blank text stays distinct from missing or null", arguments: ["", " \t\r\n"])
    func blankFieldsPreserveExactText(text: String) throws {
        let object = Dictionary(uniqueKeysWithValues: Self.textFields.map { ($0, text) })
        let rule = try JSONDecoder().decode(ReviewRule.self,
            from: JSONSerialization.data(withJSONObject: object))
        let encoded = try wireObject(rule)
        let restored = try JSONDecoder().decode(ReviewRule.self, from: JSONEncoder().encode(rule))
        let reopened = try wireObject(restored)
        for field in Self.textFields {
            #expect(Data(try #require(encoded[field] as? String).utf8) == Data(text.utf8))
            #expect(Data(try #require(reopened[field] as? String).utf8) == Data(text.utf8))
        }
    }

    @Test("a non-string text field is isolated without erasing the remaining review rule",
          arguments: ["{}", "[]", "true", "42"])
    func nonStringTextFieldKeepsOtherFields(raw: String) throws {
        var object = fixtureRule()
        object["reviewUrl"] = try JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed)
        let rule = try JSONDecoder().decode(ReviewRule.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(rule.reviewUrl == nil)
        let encoded = try wireObject(rule)
        #expect(encoded["reviewUrl"] == nil)
        #expect(rule.enabled)
        for field in Self.textFields where field != "reviewUrl" {
            #expect(encoded[field] as? String == object[field] as? String)
        }
    }

    @Test("enabled retains its original false default and supported boolean wire forms",
          arguments: ["null", "true", "false", #""true""#, #""TRUE""#, #""false""#, #""unexpected""#, "1", "{}", "[]"])
    func enabledWireForms(raw: String) throws {
        let json = #"{"reviewUrl":"kept","enabled":\#(raw)}"#
        let rule = try JSONDecoder().decode(ReviewRule.self, from: Data(json.utf8))
        let expected = ["true", #""true""#, #""TRUE""#].contains(raw)
        #expect(rule.enabled == expected)
        #expect(rule.reviewUrl == "kept")
        #expect(try JSONDecoder().decode(ReviewRule.self,
            from: JSONEncoder().encode(rule)).enabled == expected)
    }

    @Test("editing each original field participates in the existing content comparison")
    func eachFieldEditChangesContentComparison() throws {
        let original = try source(rule: fixtureRule())
        for field in Self.textFields {
            var changed = fixtureRule()
            changed[field] = try #require(changed[field] as? String) + " "
            let edited = try source(rule: changed, id: original.id)
            #expect(!original.hasSameContent(as: edited), "A review-rule edit must be retained: \(field)")
            #expect(edited.id == original.id)
        }
        var disabled = original
        disabled.ruleReview.enabled = false
        #expect(!original.hasSameContent(as: disabled))
    }

    @Test("the existing streamed library writer preserves every original review field")
    func storedLibraryPreservesFields() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookSourceReviewRulePreservation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Could not remove owned review-rule fixture: \(error)") }
        }
        let original = try source(rule: fixtureRule())
        let url = root.appendingPathComponent("book_sources.json")
        try BookSourceStore.writeLibrary([original], to: url)
        let restored = try #require(try JSONDecoder().decode([BookSource].self,
            from: Data(contentsOf: url)).first)
        try expectFields(restored, equals: fixtureRule())
        #expect(restored.id == original.id)
        #expect(restored.hasSameContent(as: original))
    }

    private func fixtureRule() -> [String: Any] {
        var rule = Dictionary(uniqueKeysWithValues: Self.textFields.map {
            ($0, " \t\r\n\($0): 子正文 e\u{301} \\\"\r\n@js:result;\t " as Any)
        })
        rule["enabled"] = true
        rule["review"] = "legacy@text"
        return rule
    }

    private func source(rule: [String: Any], id: UUID = UUID()) throws -> BookSource {
        let object: [String: Any] = ["id": id.uuidString,
            "bookSourceUrl": "https://review-rule.invalid", "bookSourceName": "Owned review-rule fixture",
            "ruleReview": rule]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        return try #require(BookSource.importParse(editedJSON: json))
    }

    private func wireObject(_ rule: ReviewRule) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as? [String: Any])
    }

    private func expectFields(_ source: BookSource, equals expected: [String: Any]) throws {
        let actual = try wireObject(source.ruleReview)
        #expect(Set(actual.keys) == Set(Self.textFields + ["enabled", "review"]))
        #expect(source.ruleReview.enabled == (try #require(expected["enabled"] as? Bool)))
        #expect(source.ruleReview.review == (try #require(expected["review"] as? String)))
        for field in Self.textFields {
            let value = try #require(actual[field] as? String)
            let original = try #require(expected[field] as? String)
            #expect(Data(value.utf8) == Data(original.utf8), "Original UTF-8 review field must survive: \(field)")
        }
    }
}
