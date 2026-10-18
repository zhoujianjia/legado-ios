import Foundation
import Testing
@testable import yuedu_app

@Suite("Local reader product", .serialized)
@MainActor
struct ReaderLocalProductTests {
    @Test func localChineseUsesActualSimplifiedTranslations() throws {
        let bundle = ReaderInterfaceLanguage.localizationBundle(
            for: .main, preferredLocalization: "zh-Hant", isLocalExperience: true)
        #expect(bundle != Bundle.main)
        #expect(bundle.localizedString(forKey: "設定", value: nil, table: nil) == "设置")
        #expect(bundle.localizedString(forKey: "來源配置", value: nil, table: nil) == "来源配置")
        #expect(ReaderInterfaceLanguage.localizationBundle(
            for: .main, preferredLocalization: "en", isLocalExperience: true) == .main)
        #expect(ReaderInterfaceLanguage.localizationBundle(
            for: .main, preferredLocalization: "zh-Hant", isLocalExperience: false) == .main)
    }

    @Test func disabledBuiltInsStayHiddenAcrossStorefrontChanges() throws {
        let name = "ReaderLocalProductTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let libraries = PublicLibraryAvailability(defaults: defaults, builtInLibrariesEnabled: false)
        #expect(!libraries.isAvailable)
        libraries.receive(countryCode: "USA")
        #expect(!libraries.isAvailable)
        let registry = SourceProviderRegistry(availability: libraries)
        let providers = registry.browsableProviders()
        #expect(!providers.contains { $0.instance.type == .gutenberg || $0.instance.type == .aozora })
        #expect(!PublicLibraryAvailability.shared.isAvailable)
    }

    @Test func disabledRemoteCatalogKeepsCacheWithoutFetchingOrStamping() async throws {
        let name = "ReaderLocalProductTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: name)
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
        var requests = 0
        let store = AozoraCatalogStore(directory: directory, defaults: defaults, fetch: { _ in
            requests += 1
            Issue.record("A disabled catalog must not contact the upstream service")
            throw URLError(.notConnectedToInternet)
        }, remoteCatalogEnabled: false)
        struct CachedCatalog: Encodable {
            let data: Data
            let sha256: String
        }
        let data = try AozoraCatalogTests.fixture
        let cached = try JSONEncoder().encode(CachedCatalog(data: data, sha256: AozoraCatalogStore.hash(data)))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try cached.write(to: store.cacheURL)

        await store.load(forceRefresh: true)

        #expect(requests == 0)
        #expect(store.catalog?.newWorks.count == 2)
        #expect(!store.isRefreshing)
        #expect(!defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("aozora.catalog.lastCheck.") })
        #expect(try Data(contentsOf: store.cacheURL) == cached)
    }
}
