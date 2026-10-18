import Foundation
import Testing
@testable import yuedu_app

@Suite("Book source mainJs preservation", .serialized)
struct BookSourceMainJSPreservationTests {
    // Synthetic source text only: never evaluated or sent over the network. CRLF,
    // decomposed Unicode, escapes and outer whitespace must survive every JSON route.
    private let program = " \t\r\n// \u{4e66}\u{6e90} e\u{301}\r\nfunction search(key, page) {\r\n  return [{name: '\u{4e66}', bookUrl: '/book/1', note: '\\\\n'}];\r\n}\r\n\t "

    @Test("old sources with absent or null mainJs still decode")
    func legacySourcesRemainCompatible() throws {
        for field in ["", ",\"mainJs\":null"] {
            let json = "{\"bookSourceName\":\"Legacy\",\"bookSourceUrl\":\"https://legacy.invalid\"\(field)}"
            let source = try JSONDecoder().decode(BookSource.self, from: Data(json.utf8))
            #expect(source.mainJs == nil)
            #expect(!source.isJsSource)
            let roundTrip = try JSONDecoder().decode(BookSource.self, from: JSONEncoder().encode(source))
            #expect(roundTrip.mainJs == nil)
            #expect(roundTrip.hasSameContent(as: source))
        }
    }

    @Test("classification leaves empty, whitespace and nonblank programs unchanged")
    func classificationDoesNotRewritePrograms() throws {
        for text in ["", " \t\r\n\u{2003}", program] {
            let source = try importedSource(program: text)
            try expectProgram(in: source, equals: text)
            #expect(source.isJsSource == (text == program))
            let restored = try JSONDecoder().decode(BookSource.self, from: JSONEncoder().encode(source))
            try expectProgram(in: restored, equals: text)
        }
    }

    @Test("all importer shapes retain mainJs through the row editor and JSON export")
    func importEditorAndExportPreserveProgram() throws {
        let object = sourceObject(program: program)
        let shapes: [Any] = [object, [object], ["bookSources": [object]]]
        for shape in shapes {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: shape), as: UTF8.self)
            let imported = try #require(BookSourceStore.parseSources(json)?.first)
            try expectProgram(in: imported, equals: program)
            #expect(imported.searchUrl.isEmpty, "pure-JS sources need not contain declarative searchUrl")

            let editorJSON = imported.importEditableJSON
            let editorObject = try #require(
                try JSONSerialization.jsonObject(with: Data(editorJSON.utf8)) as? [String: Any]
            )
            #expect(Data(try #require(editorObject["mainJs"] as? String).utf8) == Data(program.utf8))
            let edited = try #require(BookSource.importParse(editedJSON: editorJSON))
            try expectProgram(in: edited, equals: program)
            #expect(imported.hasSameContent(as: edited))

            let exported = try JSONEncoder().encode([edited])
            let restored = try #require(try JSONDecoder().decode([BookSource].self, from: exported).first)
            try expectProgram(in: restored, equals: program)
            #expect(restored.hasSameContent(as: imported))
        }
    }

    @Test("editing, removing or changing only whitespace in mainJs is a content change")
    func programEditsParticipateInContentComparison() throws {
        let original = try importedSource(program: program)
        var editorObject = try #require(
            try JSONSerialization.jsonObject(with: Data(original.importEditableJSON.utf8)) as? [String: Any]
        )
        let replacement = program + "\r\n// edited"
        editorObject["mainJs"] = replacement
        let editorJSON = String(decoding: try JSONSerialization.data(withJSONObject: editorObject), as: UTF8.self)
        let edited = try #require(BookSource.importParse(editedJSON: editorJSON))
        try expectProgram(in: edited, equals: replacement)
        #expect(edited.id == original.id)
        #expect(!original.hasSameContent(as: edited))

        var reclocked = original
        reclocked.lastUpdateTime += 1
        #expect(original.hasSameContent(as: reclocked))
        var whitespaceEdit = original
        whitespaceEdit.mainJs = program + " "
        #expect(!original.hasSameContent(as: whitespaceEdit))
        var removed = original
        removed.mainJs = nil
        #expect(!original.hasSameContent(as: removed))
    }

    @Test("the streamed library writer preserves mainJs for reload")
    func storedLibraryPreservesProgram() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("book_sources.json")
        let source = try importedSource(program: program)

        try BookSourceStore.writeLibrary([source], to: url)

        let reloaded = try #require(
            try JSONDecoder().decode([BookSource].self, from: Data(contentsOf: url)).first
        )
        try expectProgram(in: reloaded, equals: program)
        #expect(reloaded.hasSameContent(as: source))
    }

    @Test("a stored mainJs edit advances the session clock while an unchanged save reuses it")
    @MainActor
    func storedEditRefreshesExistingSession() async throws {
        let directory = try temporaryDirectory()
        let store = BookSourceStore(directory: directory)
        await store.waitUntilLoaded()
        var original = try importedSource(program: program)
        original.bookSourceUrl = "https://\(UUID().uuidString).invalid"
        original.lastUpdateTime = 1
        store.replaceSourcesFromSync([original])
        // Session construction is lazy; this test never evaluates the source program.
        let oldSession = BookSourceSession.session(for: original)

        var edited = original
        edited.mainJs = program + "\r\n// updated"
        store.update(edited)
        let stored = try #require(store.source(id: original.id))
        #expect(stored.lastUpdateTime > original.lastUpdateTime)
        try expectProgram(in: stored, equals: try #require(edited.mainJs))
        let newSession = BookSourceSession.session(for: stored)
        #expect(newSession !== oldSession)
        #expect(newSession.source.mainJs == stored.mainJs)

        store.update(stored)
        let unchanged = try #require(store.source(id: original.id))
        #expect(unchanged.lastUpdateTime == stored.lastUpdateTime)
        #expect(BookSourceSession.session(for: unchanged) === newSession)

        // Drain the existing persistence queue off main before deleting this scratch store.
        await Task.detached { store.waitForQueuedWrites() }.value
        try FileManager.default.removeItem(at: directory)
    }

    private func sourceObject(program: String) -> [String: Any] {
        ["bookSourceName": "MainJS preservation fixture",
         "bookSourceUrl": "https://main-js.invalid",
         "mainJs": program]
    }

    private func importedSource(program: String) throws -> BookSource {
        let data = try JSONSerialization.data(withJSONObject: sourceObject(program: program))
        return try JSONDecoder().decode(BookSource.self, from: data)
    }

    private func expectProgram(in source: BookSource, equals expected: String) throws {
        let actual = try #require(source.mainJs)
        #expect(Data(actual.utf8) == Data(expected.utf8), "mainJs must retain the original UTF-8 text")
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookSourceMainJSPreservationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
