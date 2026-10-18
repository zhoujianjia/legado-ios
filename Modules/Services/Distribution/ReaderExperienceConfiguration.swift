import Foundation

/// Explicit distribution mode for the locally signed reader experience build.
/// Ordinary builds keep their existing capabilities when the flag is absent.
enum ReaderExperienceConfiguration {
    static var isLocalExperience: Bool {
        isLocalExperience(in: Bundle.main.infoDictionary)
    }

    static var cloudKitEnabled: Bool { !isLocalExperience }

    static var storeKitEnabled: Bool {
        storeKitEnabled(in: Bundle.main.infoDictionary)
    }

    static func storeKitEnabled(in infoDictionary: [String: Any]?) -> Bool {
        !isLocalExperience(in: infoDictionary)
    }

    static func isLocalExperience(in infoDictionary: [String: Any]?) -> Bool {
        infoDictionary?["YueduLocalExperience"] as? Bool ?? false
    }
}
