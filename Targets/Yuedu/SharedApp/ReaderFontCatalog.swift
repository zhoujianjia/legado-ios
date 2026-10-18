import Foundation

/// These fonts ship in the app and are registered by UIAppFonts, with no download step.
/// PostScript names are read from the unmodified upstream font name tables.
enum ReaderFontCatalog {
    struct BundledFont: Identifiable {
        let titleKey: String
        let postScriptName: String
        let fileName: String
        var id: String { postScriptName }
    }

    static let bundledFonts: [BundledFont] = [
        BundledFont(
            titleKey: "霞鶩文楷（輕便版）", postScriptName: "LXGWWenKaiLite-Regular",
            fileName: "LXGWWenKaiLite-Regular.ttf"
        ),
        BundledFont(
            titleKey: "霞鶩新致宋", postScriptName: "LXGWNeoZhiSong",
            fileName: "LXGWNeoZhiSong.ttf"
        ),
    ]

    static func bundledFont(postScriptName: String) -> BundledFont? {
        bundledFonts.first { $0.postScriptName == postScriptName }
    }

    static func isBundled(postScriptName: String) -> Bool {
        bundledFont(postScriptName: postScriptName) != nil
    }
}
