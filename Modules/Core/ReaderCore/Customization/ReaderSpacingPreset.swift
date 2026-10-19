import Foundation

/// Built-in starting points, expressed through the existing sparse settings writer.
/// The selection is derived from live values; a manual adjustment becomes custom.
/// Font, type size, margins, reading mode and the publication's anchor are untouched.
enum ReaderSpacingPreset: String, CaseIterable, Identifiable {
    case compact
    case balanced
    case relaxed

    var id: String { rawValue }
    var titleKey: String { "Reader.SpacingPreset.\(rawValue)" }

    var readingSettings: AppearanceThemeReadingSettings {
        var reading = AppearanceThemeReadingSettings()
        switch self {
        case .compact:
            reading.lineHeightMultiple = 1.35
            reading.letterSpacing = 0
            reading.paragraphSpacingMultiplier = 0.5
        case .balanced:
            reading.lineHeightMultiple = 1.65
            reading.letterSpacing = 0
            reading.paragraphSpacingMultiplier = 0.8
        case .relaxed:
            reading.lineHeightMultiple = 1.9
            reading.letterSpacing = 0.5
            reading.paragraphSpacingMultiplier = 1.1
        }
        return reading
    }

    static func matching(
        lineHeightMultiple: Double,
        letterSpacing: Double,
        paragraphSpacingMultiplier: Double
    ) -> Self? {
        allCases.first { preset in
            let reading = preset.readingSettings
            return reading.lineHeightMultiple.map { abs($0 - lineHeightMultiple) < 0.001 } == true
                && reading.letterSpacing.map { abs($0 - letterSpacing) < 0.001 } == true
                && reading.paragraphSpacingMultiplier.map { abs($0 - paragraphSpacingMultiplier) < 0.001 } == true
        }
    }
}
