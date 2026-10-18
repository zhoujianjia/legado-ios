import Foundation

/// Local Chinese UI uses simplified translations. Source scripts, metadata and
/// book text remain unchanged; the existing reading conversion is independent.
enum ReaderInterfaceLanguage {
    private static let simplifiedBundle: Bundle? = {
        guard let path = Bundle.main.path(forResource: "zh-Hans", ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }()

    static func localizationBundle(for bundle: Bundle) -> Bundle {
        localizationBundle(for: bundle, preferredLocalization: bundle.preferredLocalizations.first,
                           isLocalExperience: ReaderExperienceConfiguration.isLocalExperience)
    }

    static func localizationBundle(for bundle: Bundle, preferredLocalization: String?,
                                   isLocalExperience: Bool) -> Bundle {
        guard bundle == Bundle.main, isLocalExperience,
              preferredLocalization?.hasPrefix("zh") == true else { return bundle }
        return simplifiedBundle ?? bundle
    }
}
