import Foundation

/// Links describe this fork's source, never an upstream release or storefront.
/// Only a complete Git SHA may be presented as the installed version's source.
struct ReaderProjectLinks {
    static let repositoryURL = URL(string: "https://github.com/zhoujianjia/legado-ios")!
    static let issuesURL = URL(string: "https://github.com/zhoujianjia/legado-ios/issues")!

    let sourceCommit: String?

    init(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) {
        let raw = infoDictionary?["YueduExperienceSourceCommit"] as? String
        if let raw, raw.utf8.count == 40,
           raw.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) {
            sourceCommit = raw.lowercased()
        } else {
            sourceCommit = nil
        }
    }

    var sourceURL: URL {
        Self.repositoryURL.appendingPathComponent("tree").appendingPathComponent(sourceCommit ?? "main")
    }

    var licenseURL: URL {
        Self.repositoryURL.appendingPathComponent("blob").appendingPathComponent(sourceCommit ?? "main")
            .appendingPathComponent("LICENSE")
    }

    var licenseOverviewURL: URL {
        Self.repositoryURL.appendingPathComponent("blob").appendingPathComponent(sourceCommit ?? "main")
            .appendingPathComponent("docs/legado-ios/redistribution-notes.md")
    }
}
