import CoreText
import CryptoKit
import Foundation
import Testing
import UIKit
@testable import yuedu_app

@MainActor
@Suite("Bundled Chinese reader fonts", .serialized)
struct ReaderFontCatalogTests {
    @Test("bundled font and license bytes match provenance, and iOS registers real Chinese faces")
    func bundledFontsAreRegisteredWithLicensedResources() throws {
        let manifestURL = try #require(Bundle.main.url(forResource: "ReaderFonts-provenance", withExtension: "json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        let registeredFiles = try #require(Bundle.main.object(forInfoDictionaryKey: "UIAppFonts") as? [String])
        #expect(manifest.fonts.count == ReaderFontCatalog.bundledFonts.count)
        for entry in manifest.fonts {
            let definition = try #require(ReaderFontCatalog.bundledFonts.first { $0.fileName == entry.fileName })
            #expect(registeredFiles.contains(entry.fileName))
            let fontURL = try #require(Bundle.main.url(forResource: entry.fileName, withExtension: nil))
            let fontData = try Data(contentsOf: fontURL)
            #expect(fontData.count == entry.bytes)
            #expect(sha256(fontData) == entry.sha256)
            let licenseURL = try #require(Bundle.main.url(forResource: entry.licenseFile, withExtension: nil))
            let licenseData = try Data(contentsOf: licenseURL)
            #expect(licenseData.count == entry.licenseBytes)
            #expect(sha256(licenseData) == entry.licenseSHA256)
            #expect(!entry.modified)

            let font = try #require(UIFont(name: definition.postScriptName, size: 20))
            #expect(font.fontName == definition.postScriptName)
            let characters = Array("简体中文阅读书籍章节字号行距".utf16)
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            let coversText = characters.withUnsafeBufferPointer { characters in
                glyphs.withUnsafeMutableBufferPointer { glyphs in
                    CTFontGetGlyphsForCharacters(font as CTFont, characters.baseAddress!, glyphs.baseAddress!, characters.count)
                }
            }
            #expect(coversText)
            #expect(glyphs.allSatisfy { $0 != 0 })
        }
    }

    @Test("bundled font selection is accepted without importing files or claiming membership")
    func bundledSelectionsReachGlobalAndReaderFontResolvers() throws {
        let settings = GlobalSettings.shared
        let previousGlobal = settings.selectedGlobalFontPostScript
        let previousReader = settings.selectedReaderFontPostScript
        defer {
            settings.selectedGlobalFontPostScript = previousGlobal
            settings.selectedReaderFontPostScript = previousReader
        }
        for font in ReaderFontCatalog.bundledFonts {
            settings.selectedGlobalFontPostScript = font.postScriptName
            settings.validateGlobalFontSelection()
            #expect(settings.resolvedGlobalFontPostScript == font.postScriptName)
            #expect(settings.globalFontDisplayName == localized(font.titleKey))
            settings.selectedReaderFontPostScript = font.postScriptName
            #expect(UserReaderFontResolver.bodyFont(size: 20).fontName == font.postScriptName)
        }
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct Manifest: Decodable {
        let fonts: [Entry]
        struct Entry: Decodable {
            let fileName: String
            let bytes: Int
            let sha256: String
            let licenseFile: String
            let licenseBytes: Int
            let licenseSHA256: String
            let modified: Bool
        }
    }
}
