import Foundation
import LegadoRuntime

// MARK: - A source's explore controls

/// One of a source's explore entries that is a control rather than a category — legado-E
/// and MD3's `button`, `text` and `toggle` explore kinds. 發現頁設定 lists them under
/// 快捷操作. Each reads and writes the source's explore `infoMap` under its title, and a
/// tap or an edit runs the kind's `action` script.
struct DiscoverQuickAction: Identifiable {
    enum Kind: String {
        case button, text, toggle
    }

    let kind: Kind
    let title: String
    /// What a tap or an edit runs. A button without an `action` runs its `url` as script,
    /// as the original Legado's explore buttons do.
    let script: String?
    /// A toggle's values, cycled in order.
    let options: [String]
    let defaultValue: String?
    let viewName: String?
    /// A toggle draws its value after the title rather than before it
    /// (`layout_justifySelf: right` in legado-E).
    let valueTrails: Bool

    var id: String { kind.rawValue + "\u{1F}" + title }

    init?(_ raw: ModernParserBridge.DiscoverItem) {
        guard let kind = raw.type.flatMap(Kind.init(rawValue:)) else { return nil }
        let title = (raw.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        self.kind = kind
        self.title = title
        let action = raw.action?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url = raw.url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !action.isEmpty {
            script = action
        } else if kind == .button, !url.isEmpty {
            script = ModernParserBridge.isJSExploreRule(url) ? ModernParserBridge.jsCode(fromExploreRule: url) : url
        } else {
            script = nil
        }
        let chars = (raw.chars ?? []).filter { !$0.isEmpty }
        // legado-E shows a toggle without values as these two words rather than hiding it.
        options = chars.isEmpty ? ["chars", "is null"] : chars
        defaultValue = raw.default
        viewName = raw.viewName
        valueTrails = raw.style?["layout_justifySelf"] == "right"
    }

    /// A display name written out in the source: `'名稱'`, 3 to 19 characters with the
    /// quotes, as Legado reads one. Any other `viewName` is a script.
    var literalDisplayName: String? {
        guard let viewName, (3...19).contains(viewName.count),
              viewName.first == "'", viewName.last == "'" else { return nil }
        return String(viewName.dropFirst().dropLast())
    }

    /// A `viewName` to evaluate for the display name.
    var displayNameScript: String? {
        guard let viewName, !viewName.isEmpty, literalDisplayName == nil else { return nil }
        return viewName
    }

    /// A toggle's value: the stored one, else its default, else its first value.
    func toggleValue(in values: [String: String]) -> String {
        if let stored = values[title], !stored.isEmpty { return stored }
        return defaultValue ?? options[0]
    }

    /// The value after `current`, wrapping round.
    func toggleValue(after current: String) -> String {
        let index = options.firstIndex(of: current).map { ($0 + 1) % options.count } ?? 0
        return options[index]
    }

    /// The source's controls, each once, in the order the source lists them.
    static func actions(from raw: [ModernParserBridge.DiscoverItem]) -> [DiscoverQuickAction] {
        var seen = Set<String>()
        return raw.compactMap(DiscoverQuickAction.init).filter { seen.insert($0.id).inserted }
    }
}

// MARK: - Running a control's script

/// What one explore control's script asked of the page.
struct DiscoverQuickActionOutcome {
    /// `java.refreshExplore()` ran: reload the source's categories.
    var refreshesExplore = false
    var errorMessage: String?
}

enum DiscoverQuickActionRunner {
    static func run(_ script: String, title: String, source: BookSource,
                    presentToast: @escaping @MainActor (String) -> Void) async -> DiscoverQuickActionOutcome {
        do {
            _ = try await evaluate(script, source: source)
            return .init(refreshesExplore: false, errorMessage: nil)
        } catch {
            AppLogger.error("Original explore action failed", error: error)
            return .init(refreshesExplore: false, errorMessage: error.localizedDescription)
        }
    }

    static func displayName(_ script: String, source: BookSource) async -> String {
        do { let result = try await evaluate(script, source: source); return result.isEmpty ? "null" : result }
        catch { AppLogger.error("Original explore display name failed", error: error); return "err" }
    }

    static func infoMapValues(source: BookSource) async -> [String: String] {
        do { return try await BookSourceFetcher.shared.openOriginalExploreContext(source: source).infoMap ?? [:] }
        catch { AppLogger.error("Original explore values could not be read", error: error); return [:] }
    }

    static func setInfoMapValue(_ value: String, forKey key: String, source: BookSource) async {
        do {
            let name = String(decoding: try JSONEncoder().encode(key), as: UTF8.self)
            let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
            _ = try await evaluate("infoMap.put(" + name + "," + text + "); infoMap.save();", source: source)
        } catch { AppLogger.error("Original explore value did not change", error: error) }
    }

    private static func evaluate(_ script: String, source: BookSource) async throws -> String {
        let fetcher = BookSourceFetcher.shared
        if source.isJsSource { return try await fetcher.mainJSService.evaluateMainJSExplore(script: script, page: 1, source: source) }
        _ = try await fetcher.openOriginalExploreContext(source: source)
        return try await fetcher.evaluateOriginalExploreContext(script: script, source: source).result ?? ""
    }
}
