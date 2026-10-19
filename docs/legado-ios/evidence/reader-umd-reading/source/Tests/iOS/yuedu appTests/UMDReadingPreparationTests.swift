import Foundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("Unregistered UMD literal reading preparation", .serialized)
@MainActor
struct UMDReadingPreparationTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/UMD")
    private static let fixtureIDs = ["chinese-two-chapters", "paragraph-separators", "non-bmp-utf16",
                                     "multi-chapter-optional-metadata", "cross-compression-blocks"]

    @Test("Five original Java fixtures use the existing document with exact titles and all fifteen bodies")
    func originalGoldenDocumentsAndDirectory() async throws {
        for id in Self.fixtureIDs {
            let folder = Self.root.appendingPathComponent(id)
            let snapshot = try await UMDBookParser.load(url: folder.appendingPathComponent("fixture.umd"))
            let golden = try await Task.detached {
                try JSONDecoder().decode(UMDReadingGolden.self,
                    from: Data(contentsOf: folder.appendingPathComponent("reader-output.json")))
            }.value
            let chapters = try await UMDReadingPreparation.prepare(snapshot.document)
            try #require(chapters.count == golden.chapters.count)
            try await Task.detached {
                let book = ReadingBook(title: snapshot.document.title ?? "", author: snapshot.document.author ?? "",
                                       contentFilename: "owned-unregistered.umd")
                let document = TXTBookDocument(book: book, chapters: chapters)
                #expect(document.metadata.id == book.id)
                #expect(document.tableOfContents.count == golden.chapters.count)
                for index in chapters.indices {
                    let chapter = chapters[index]
                    let expected = golden.chapters[index]
                    #expect(chapter.index == index)
                    #expect(chapter.sourceHref == String(index))
                    #expect(chapter.paragraphs.count == 1)
                    #expect(Array(chapter.title.utf16) == Array(expected.title.value.utf16))
                    #expect(Array(chapter.plainText.utf16) == Array(expected.getContentString.value.utf16))
                    #expect(snapshot.document.chapters[index].rawByteOffset == expected.offset.value)
                    #expect(snapshot.document.chapters[index].rawUTF16LE == Data(base64Encoded: expected.rawContent.valueBase64))
                    #expect(chapter.plainText.utf16.count * 2 == snapshot.document.chapters[index].rawUTF16LE.count)
                    #expect(document.tableOfContents[index].id == String(index))
                    #expect(Array(document.tableOfContents[index].title.utf16) == Array(expected.title.value.utf16))
                    let content = try await document.loadContent(for: String(index))
                    guard case .text(let text) = content else { Issue.record("Expected the existing TXT text document"); continue }
                    #expect(Array(text.utf16) == Array(expected.getContentString.value.utf16))
                }
            }.value
        }
    }

    @Test("Literal mode preserves HTML, Aozora marks, whitespace, empty lines and original CR/LF")
    func literalBodyAndLegacyControl() async throws {
        let raw = " \t<p>A &amp; B</p>\r\n\r\n\u{3000}\u{FF5C}\u{6F22}\u{5B57}\u{300A}\u{304B}\u{3093}\u{3058}\u{300B}\u{FF3B}\u{FF03}note\u{FF3D}  \nlast\r\t "
        let source = try Self.synthetic([raw])
        let chapters = try await UMDReadingPreparation.prepare(source)
        let literal = try TXTLazyAttributedStringBuilder(literalChapters: chapters, replacementRules: [])
        let result = try await literal.buildChapter(at: 0, settings: Self.settings(),
                                                   themeTextColor: .label, themeBackgroundColor: .systemBackground)
        #expect(Array(result.attributedString.string.utf16) == Array(raw.utf16))
        #expect(await literal.chapterPlainText(at: 0) == raw)
        #expect(result.attributedString.attribute(HTMLAttributedStringBuilder.rubyAnnotationAttribute,
                                                at: 0, effectiveRange: nil) == nil)
        // This old initializer still uses the existing paragraph/HTML/Aozora policy.
        let index = TXTChapterIndex(index: 0, title: "Title 0", contentRange: NSRange(location: 0, length: raw.utf16.count))
        let legacy = TXTLazyAttributedStringBuilder(text: raw, chapterIndexes: [index])
        let legacyResult = try await legacy.buildChapter(at: 0, settings: Self.settings(),
                                                        themeTextColor: .label, themeBackgroundColor: .systemBackground)
        #expect(legacyResult.attributedString.string != raw)
        #expect(!legacyResult.attributedString.string.contains("<p>"))
        #expect(!legacyResult.attributedString.string.contains("\u{FF3B}\u{FF03}"))
        #expect(legacyResult.attributedString.string.hasSuffix("\n"))
        #expect(source.chapters[0].text == raw)
    }

    @Test("Independent chapter strings do not grow across combining, CRLF, ZWJ or regional-indicator seams")
    func chapterSeamsDoNotMerge() async throws {
        let bodies = ["e", "\u{0301}", "\r", "\n", "\u{1F469}\u{200D}", "\u{1F4BB}", "\u{1F1E8}", "\u{1F1F3}", "\u{1F600}\u{2029}end"]
        let source = try Self.synthetic(bodies)
        let chapters = try await UMDReadingPreparation.prepare(source)
        let builder = try TXTLazyAttributedStringBuilder(literalChapters: chapters, replacementRules: [])
        let book = ReadingBook(title: "Seams", author: "Owned", contentFilename: "seams.umd")
        let document = TXTBookDocument(book: book, chapters: chapters)
        for index in chapters.indices {
            let expected = bodies[index].replacingOccurrences(of: "\u{2029}", with: "\n")
            let content = try await document.loadContent(for: String(index))
            guard case .text(let text) = content else { Issue.record("Expected TXT chapter"); continue }
            #expect(Array(text.utf16) == Array(expected.utf16))
            #expect(builder.chapterTitle(at: index) == "Title \(index)")
            #expect(builder.chapterSourceHref(at: index) == String(index))
            #expect(builder.chapterIndex(for: String(index)) == index)
            let rendered = try await builder.buildChapter(at: index, settings: Self.settings(),
                                                         themeTextColor: .label, themeBackgroundColor: .systemBackground)
            #expect(Array(rendered.attributedString.string.utf16) == Array(expected.utf16))
        }
        #expect(builder.chapterCount == bodies.count)
    }

    @Test("Bad offsets, UTF-16 projections, metadata and budgets fail without automatic repair")
    func rejectsInconsistentProjectionAndBudgets() async throws {
        let valid = try Self.synthetic(["A", "B"])
        let first = valid.chapters[0]
        let second = valid.chapters[1]
        let invalid: [UMDTextDocument] = [
            .init(metadata: [:], chapters: []),
            .init(metadata: [:], chapters: [.init(title: "A", rawByteOffset: 2, rawUTF16LE: first.rawUTF16LE, text: "A")]),
            .init(metadata: [:], chapters: [first, .init(title: "B", rawByteOffset: Int.max, rawUTF16LE: second.rawUTF16LE, text: "B")]),
            .init(metadata: [:], chapters: [.init(title: "A", rawByteOffset: 0, rawUTF16LE: Data([0x41]), text: "A")]),
            .init(metadata: [:], chapters: [.init(title: "A", rawByteOffset: 0, rawUTF16LE: first.rawUTF16LE, text: "B")]),
            .init(metadata: [:], chapters: [.init(title: "A", rawByteOffset: 0, rawUTF16LE: first.rawUTF16LE, text: "AA")]),
            .init(metadata: [99: "unknown"], chapters: valid.chapters),
            .init(metadata: [2: String(repeating: "x", count: 126)], chapters: valid.chapters),
            .init(metadata: [:], chapters: [.init(title: String(repeating: "x", count: 128), rawByteOffset: 0, rawUTF16LE: first.rawUTF16LE, text: "A")]),
        ]
        for input in invalid {
            await #expect(throws: (any Error).self) { try await UMDReadingPreparation.prepare(input) }
        }
        var limits = UMDReadingPreparation.Limits(); limits.utf16Bytes = 3
        await #expect(throws: UMDReadingPreparation.Failure.budgetExceeded) {
            try await UMDReadingPreparation.prepare(valid, limits: limits)
        }
        limits = .init(); limits.chapters = 1
        await #expect(throws: UMDReadingPreparation.Failure.budgetExceeded) {
            try await UMDReadingPreparation.prepare(valid, limits: limits)
        }
        limits = .init(); limits.utf16Bytes = 0
        await #expect(throws: UMDReadingPreparation.Failure.budgetExceeded) {
            try await UMDReadingPreparation.prepare(valid, limits: limits)
        }
        #expect(valid.chapters[1].rawByteOffset == 2)
    }

    @Test("Literal initializer rejects holes and duplicate IDs; empty chapters remain distinct from missing chapters")
    func literalMetadataAndEmptyChapter() async throws {
        let chapters = try await UMDReadingPreparation.prepare(Self.synthetic(["", "body"]))
        let builder = try TXTLazyAttributedStringBuilder(literalChapters: chapters, replacementRules: [])
        #expect(await builder.chapterPlainText(at: 0) == "")
        #expect(await builder.chapterPlainText(at: 2) == nil)
        let rendered = try await builder.buildChapter(at: 0, settings: Self.settings(),
                                                     themeTextColor: .label, themeBackgroundColor: .systemBackground)
        #expect(rendered.attributedString.string.isEmpty)
        await #expect(throws: AttributedStringBuildingError.chapterOutOfRange(2)) {
            try await builder.buildChapter(at: 2, settings: Self.settings(),
                                           themeTextColor: .label, themeBackgroundColor: .systemBackground)
        }
        let body = chapters[1]
        let bad: [[UnifiedChapter]] = [[], [body], [chapters[0], chapters[0]],
            [.init(index: 0, title: "x", paragraphs: ["body"], sourceHref: nil)],
            [.init(index: 0, title: "x", paragraphs: ["body"], sourceHref: "1")],
            [.init(index: 0, title: "x", paragraphs: [], sourceHref: "0")],
            [.init(index: 0, title: "x", paragraphs: ["body", "other"], sourceHref: "0")],
            [.init(index: 0, title: String(repeating: "x", count: 128), paragraphs: ["body"], sourceHref: "0")]]
        for input in bad {
            #expect(throws: (any Error).self) { try TXTLazyAttributedStringBuilder(literalChapters: input, replacementRules: []) }
        }
        await Task.detached {
            let tooMany = Array(repeating: body, count: 16_385)
            #expect(throws: TXTLazyAttributedStringBuilder.LiteralChapterFailure.budgetExceeded) {
                try TXTLazyAttributedStringBuilder(literalChapters: tooMany, replacementRules: [])
            }
            let tooLarge = [UnifiedChapter(index: 0, title: "x", paragraphs: [String(repeating: "x", count: 16 * 1_024 * 1_024 + 1)], sourceHref: "0")]
            #expect(throws: TXTLazyAttributedStringBuilder.LiteralChapterFailure.budgetExceeded) {
                try TXTLazyAttributedStringBuilder(literalChapters: tooLarge, replacementRules: [])
            }
        }.value
        let book = ReadingBook(title: "Empty", author: "Owned", contentFilename: "empty.umd")
        let document = TXTBookDocument(book: book, chapters: chapters)
        let content = try await document.loadContent(for: "0")
        guard case .text(let text) = content else { Issue.record("Expected legitimate empty text"); return }
        #expect(text == "")
        await #expect(throws: BookDocumentError.self) { try await document.loadContent(for: "2") }
    }

    @Test("Rendered positions are relative to their spine and include an actually rendered title prefix")
    func positionsUseRenderedSpineAndTitlePrefix() async throws {
        let marker = "\u{1F600}marker-unique"
        let body = "before " + marker
        let source = try Self.synthetic([String(repeating: "a", count: 200), body])
        let chapters = try await UMDReadingPreparation.prepare(source)
        let builder = try TXTLazyAttributedStringBuilder(literalChapters: chapters, replacementRules: [])
        var settings = Self.settings(); settings.chapterTitleStyle.visible = true
        let result = try await builder.buildChapter(at: 1, settings: settings,
                                                   themeTextColor: .label, themeBackgroundColor: .systemBackground)
        let string = result.attributedString.string as NSString
        let bodyRange = string.range(of: body)
        let markerRange = string.range(of: marker)
        try #require(bodyRange.location != NSNotFound)
        try #require(markerRange.location != NSNotFound)
        #expect(bodyRange.location > 0)
        let bodyMarker = (body as NSString).range(of: marker)
        let position = CoreTextReadingPosition(spineIndex: 1, charOffset: markerRange.location)
        #expect(position.spineIndex == 1)
        #expect(position.charOffset == bodyRange.location + bodyMarker.location)
        #expect(position.charOffset != source.chapters[1].rawByteOffset / 2 + bodyMarker.location)
        #expect(string.substring(with: markerRange) == marker)
        #expect(builder.chapterIndex(for: "1") == position.spineIndex)
        // No reading-position store, disk index, migration or persistence is used.
    }

    @Test("Explicit rule snapshots and conversion affect rendering without changing the source document")
    func explicitTransformsPreserveOriginalDocument() async throws {
        let raw = "\u{6F22}\u{5B57}REMOVE\u{1F600}marker"
        let source = try Self.synthetic([raw])
        let chapters = try await UMDReadingPreparation.prepare(source)
        var rules = [ReplaceRule(name: "Owned", pattern: "REMOVE", replacement: "", isRegex: false)]
        let builder = try TXTLazyAttributedStringBuilder(literalChapters: chapters, replacementRules: rules)
        rules[0].replacement = "MUTATED-AFTER-SNAPSHOT"
        var settings = Self.settings(); settings.textConversion = .toSimplified
        let result = try await builder.buildChapter(at: 0, settings: settings,
                                                   themeTextColor: .label, themeBackgroundColor: .systemBackground)
        let expected = "\u{6C49}\u{5B57}\u{1F600}marker"
        #expect(Array(result.attributedString.string.utf16) == Array(expected.utf16))
        #expect(await builder.chapterPlainText(at: 0) == "\u{6F22}\u{5B57}\u{1F600}marker")
        let rawMarker = (raw as NSString).range(of: "marker")
        let renderedMarker = (result.attributedString.string as NSString).range(of: "marker")
        try #require(renderedMarker.location != NSNotFound)
        let position = CoreTextReadingPosition(spineIndex: 0, charOffset: renderedMarker.location)
        #expect(position.charOffset != rawMarker.location)
        #expect(source.chapters[0].text == raw)
        let book = ReadingBook(title: "Transform", author: "Owned", contentFilename: "transform.umd")
        let document = TXTBookDocument(book: book, chapters: chapters)
        let content = try await document.loadContent(for: "0")
        guard case .text(let text) = content else { Issue.record("Expected original document text"); return }
        #expect(Array(text.utf16) == Array(raw.utf16))
    }

    @Test("Cancelled preparation, initializer and render entries fail before producing a result")
    func cancellationDoesNotReturnPreparedContent() async throws {
        let source = try Self.synthetic(["body"])
        let preparing = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await UMDReadingPreparation.prepare(source)
        }
        await #expect(throws: CancellationError.self) { try await preparing.value }
        let chapters = try await UMDReadingPreparation.prepare(source)
        let initializing = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try TXTLazyAttributedStringBuilder(literalChapters: chapters, replacementRules: [])
        }
        await #expect(throws: CancellationError.self) { try await initializing.value }
        let builder = try TXTLazyAttributedStringBuilder(literalChapters: chapters, replacementRules: [])
        let rendering = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await builder.buildChapter(at: 0, settings: Self.settings(),
                                               themeTextColor: .label, themeBackgroundColor: .systemBackground)
        }
        await #expect(throws: CancellationError.self) { try await rendering.value }
    }

    private static func settings() -> ReaderRenderSettings {
        var settings = EPUBTestFixtures.renderSettings()
        settings.chapterTitleStyle.visible = false
        settings.chapterTitleStyle.advancedCSSEnabled = false
        settings.chapterTitleStyle.topSpacing = 0
        settings.chapterTitleStyle.bottomSpacing = 0
        settings.textConversion = .original
        return settings
    }

    private static func synthetic(_ bodies: [String]) throws -> UMDTextDocument {
        var chapters: [UMDTextDocument.Chapter] = []
        var offset = 0
        for (index, body) in bodies.enumerated() {
            let bytes = try #require(body.data(using: .utf16LittleEndian))
            chapters.append(.init(title: "Title \(index)", rawByteOffset: offset, rawUTF16LE: bytes,
                                  text: body.replacingOccurrences(of: "\u{2029}", with: "\n")))
            offset += bytes.count
        }
        return UMDTextDocument(metadata: [:], chapters: chapters)
    }
}

private struct UMDReadingGolden: Decodable, Sendable {
    let chapters: [Chapter]
    struct Value<T: Decodable & Sendable>: Decodable, Sendable { let value: T }
    struct Chapter: Decodable, Sendable {
        let title: Value<String>
        let offset: Value<Int>
        let rawContent: Raw
        let getContentString: Value<String>
        struct Raw: Decodable, Sendable { let valueBase64: String }
    }
}
