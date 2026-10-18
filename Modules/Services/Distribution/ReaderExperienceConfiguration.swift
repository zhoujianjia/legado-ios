import Foundation

/// Explicit distribution mode for the locally signed reader experience build.
/// Ordinary builds keep their existing capabilities when the flag is absent.
enum ReaderExperienceConfiguration {
    static var isLocalExperience: Bool {
        isLocalExperience(in: Bundle.main.infoDictionary)
    }

    static var cloudKitEnabled: Bool { !isLocalExperience }

    /// The fork is a standalone local reader. These are application accounts,
    /// not the website credentials, cookies or CAPTCHA used by book sources.
    static var accountServicesEnabled: Bool { accountServicesEnabled(in: Bundle.main.infoDictionary) }
    static var feedbackServicesEnabled: Bool { accountServicesEnabled }
    static var localFeaturesEnabled: Bool { isLocalExperience }

    static func accountServicesEnabled(in infoDictionary: [String: Any]?) -> Bool {
        !isLocalExperience(in: infoDictionary)
    }

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
