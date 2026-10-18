import CloudKit
import Foundation
import Testing
@testable import yuedu_app

@Suite("Auth and iCloud configuration")
struct AuthAndICloudConfigurationTests {
    @Test("local experience requires an explicit Info boolean and defaults off")
    func localExperienceRequiresExplicitInfoBoolean() {
        #expect(!ReaderExperienceConfiguration.isLocalExperience(in: nil))
        #expect(!ReaderExperienceConfiguration.isLocalExperience(in: [:]))
        #expect(!ReaderExperienceConfiguration.isLocalExperience(in: ["YueduLocalExperience": false]))
        #expect(!ReaderExperienceConfiguration.isLocalExperience(in: ["YueduLocalExperience": "true"]))
        #expect(ReaderExperienceConfiguration.isLocalExperience(in: ["YueduLocalExperience": true]))
        #expect(ReaderExperienceConfiguration.cloudKitEnabled == !ReaderExperienceConfiguration.isLocalExperience)
        #expect(ReaderExperienceConfiguration.storeKitEnabled(in: nil))
        #expect(ReaderExperienceConfiguration.storeKitEnabled(in: [:]))
        #expect(ReaderExperienceConfiguration.storeKitEnabled(in: ["YueduLocalExperience": false]))
        #expect(ReaderExperienceConfiguration.storeKitEnabled(in: ["YueduLocalExperience": "true"]))
        #expect(!ReaderExperienceConfiguration.storeKitEnabled(in: ["YueduLocalExperience": true]))
        #expect(ReaderExperienceConfiguration.storeKitEnabled == !ReaderExperienceConfiguration.isLocalExperience)
        #expect(ReaderExperienceConfiguration.accountServicesEnabled(in: nil))
        #expect(ReaderExperienceConfiguration.accountServicesEnabled(in: ["YueduLocalExperience": false]))
        #expect(!ReaderExperienceConfiguration.accountServicesEnabled(in: ["YueduLocalExperience": true]))
        #expect(ReaderExperienceConfiguration.accountServicesEnabled == !ReaderExperienceConfiguration.isLocalExperience)
        #expect(ReaderExperienceConfiguration.feedbackServicesEnabled == ReaderExperienceConfiguration.accountServicesEnabled)
        #expect(ReaderExperienceConfiguration.localFeaturesEnabled == ReaderExperienceConfiguration.isLocalExperience)
    }

    @Test("local reader keeps every local feature available without claiming a purchase")
    @MainActor
    func localReaderCapabilitiesNeedNoAccountOrTransaction() async {
        let rememberedEnvironment = UserDefaults.standard.string(forKey: "subscription_running_environment")
        // Even an accidental enabled StoreKit input cannot start Apple work in
        // local mode. This exercises production observer defaults, not a stub.
        let store = SubscriptionStore(storeKitEnabled: true, localFeaturesEnabled: true)
        #expect(store.hasResolvedEntitlements)
        #expect(!store.isProActive)
        #expect(store.hasUnrestrictedFeatureAccess)
        for feature in PremiumFeature.allCases {
            #expect(store.hasAccess(feature))
        }
        await store.loadProducts()
        await store.reloadProductsIfStorefrontChanged()
        await store.refreshAllEntitlements()
        await store.authenticationDidChange(isAuthenticated: false)
        store.debugForceProActive = false
        store.testFlightAccessDidChange()

        #expect(!store.isProActive)
        #expect(store.hasUnrestrictedFeatureAccess)
        #expect(store.products.isEmpty)
        #expect(store.purchasedProductIDs.isEmpty)
        #expect(!store.storeKitIsProActive)
        #expect(!store.accountIsProActive)
        #expect(!store.iCloudIsProActive)
        #expect(!store.isLoadingProducts)
        #expect(!store.isPurchasing)
        #expect(UserDefaults.standard.string(forKey: "subscription_running_environment") == rememberedEnvironment)

        let reader = ReaderPremiumVisibilityPolicy(isProActive: store.hasUnrestrictedFeatureAccess)
        #expect(reader.allowsFontImport)
        #expect(reader.allowsParagraphNoteEditing)
        #expect(reader.allowsAI)
        #expect(reader.showsReaderDecoration)
        #expect(reader.showsLayoutPresetImport)
        #expect(reader.showsBackgroundImageImport)
        #expect(reader.showsTouchZoneEditor)
        #expect(reader.showsBottomTabCustomization)
    }

    @Test("local account router rejects both routes before any Firebase construction")
    @MainActor
    func localReaderAccountRoutesAreUnavailable() async {
        let router = AccountBackendRouter(accountServicesEnabled: false)
        let current = router.current
        #expect(current === router.backend(for: .direct))
        #expect(current === router.backend(for: .gateway))

        do {
            _ = try await current.accountToken()
            Issue.record("A disabled account service must not supply a token")
        } catch AccountBackendError.disabledForLocalReader {
        } catch { Issue.record("Unexpected disabled service error: \(error)") }
        do {
            _ = try await current.refreshEntitlement(uid: "local-reader-test")
            Issue.record("A disabled account service must not supply an entitlement")
        } catch AccountBackendError.disabledForLocalReader {
        } catch { Issue.record("Unexpected disabled service error: \(error)") }
        do {
            _ = try await current.uploadAvatar(data: Data())
            Issue.record("A disabled account service must not claim an avatar upload")
        } catch AccountBackendError.disabledForLocalReader {
        } catch { Issue.record("Unexpected disabled service error: \(error)") }
        do {
            _ = try await current.verifyTestFlightAccess()
            Issue.record("A disabled account service must not grant a TestFlight seat")
        } catch AccountBackendError.disabledForLocalReader {
        } catch { Issue.record("Unexpected disabled service error: \(error)") }
        do {
            try await current.deleteRemoteData(uid: "local-reader-test")
            Issue.record("A disabled account service must not claim a remote deletion")
        } catch AccountBackendError.disabledForLocalReader {
        } catch { Issue.record("Unexpected disabled service error: \(error)") }
    }

    @Test("disabled StoreKit resolves without observing or requesting Apple services")
    @MainActor
    func disabledStoreKitDoesNotStartAutomaticWork() async {
        let rememberedEnvironment = UserDefaults.standard.string(forKey: "subscription_running_environment")
        // Keep observeTransactions at its production default: the capability
        // itself must prevent the listener and launch task from being created.
        let store = SubscriptionStore(storeKitEnabled: false, localFeaturesEnabled: false)
        #expect(store.hasResolvedEntitlements)
        #expect(!store.isProActive)
        #expect(store.products.isEmpty)
        #expect(store.purchasedProductIDs.isEmpty)

        await Task.yield()
        await store.loadProducts()
        await store.reloadProductsIfStorefrontChanged()
        await store.refreshEntitlements()
        await store.refreshAllEntitlements()
        await store.authenticationDidChange(isAuthenticated: true)
        await store.authenticationDidChange(isAuthenticated: false)
        await store.restore()
        await store.redeemOfferCode(in: nil)

        #expect(store.hasResolvedEntitlements)
        #expect(store.products.isEmpty)
        #expect(store.purchasedProductIDs.isEmpty)
        #expect(!store.storeKitIsProActive)
        #expect(!store.accountIsProActive)
        #expect(!store.iCloudIsProActive)
        #expect(!store.isProActive)
        #expect(!store.isLoadingProducts)
        #expect(!store.isPurchasing)
        #expect(!store.isRestoring)
        #expect(!store.isRedeemingOfferCode)
        #expect(UserDefaults.standard.string(forKey: "subscription_running_environment") == rememberedEnvironment)
    }

    @Test("disabled CloudKit sync constructs safely and rejects remote work")
    func disabledCloudKitSyncDoesNotConstructContainer() async throws {
        // Inject the explicit capability policy without constructing a CKContainer
        // in the call site or requiring a CloudKit entitlement in the test host.
        let sync = ICloudSyncManager(cloudKitEnabled: false)
        #expect(sync.accountStatus == .restricted)
        #expect(await sync.refreshAccountStatus() == .restricted)
        do {
            try await sync.sync(reason: "local-experience-construction-test")
            Issue.record("An explicitly disabled CloudKit service must reject sync")
        } catch ICloudSyncError.accountUnavailable(let status) {
            #expect(status == .restricted)
        } catch {
            Issue.record("Unexpected disabled CloudKit error: \(error)")
        }
        #expect(!sync.isSyncing)
    }

    @Test("disabled subscription mirror constructs safely and reports disabled")
    func disabledSubscriptionMirrorDoesNotConstructContainer() async {
        let mirror = SubscriptionICloudMirror(cloudKitEnabled: false)
        #expect(await mirror.accountStatusDescription() == "disabled")
        #expect(await mirror.load() == nil)
    }

    @Test("main app entitlements enable Apple sign-in and CloudKit")
    func mainAppEntitlementsEnableAppleSignInAndCloudKit() throws {
        let entitlements = try loadMainAppEntitlements()

        #expect(entitlements["com.apple.developer.applesignin"] as? [String] == ["Default"])
        #expect(entitlements["com.apple.developer.icloud-services"] as? [String] == ["CloudKit"])
        #expect(entitlements["com.apple.developer.icloud-container-identifiers"] as? [String] == [
            "iCloud.com.zhangruilin.yuedureader"
        ])
    }

    @Test("iCloud payload covers existing sync data files")
    func iCloudPayloadCoversExistingSyncDataFiles() {
        let applicationSupportDirectory = URL(
            fileURLWithPath: "/tmp/yuedu-application-support",
            isDirectory: true
        )
        let libraryDirectory = URL(fileURLWithPath: "/tmp/yuedu-library", isDirectory: true)
        let bookSourcesFile = applicationSupportDirectory.appendingPathComponent("book_sources.json")
        let booksMetadataFile = applicationSupportDirectory.appendingPathComponent("books_meta.json")

        let files = ICloudSyncPayload.defaultFiles(
            bookSourcesFile: bookSourcesFile,
            booksMetadataFile: booksMetadataFile,
            libraryDirectory: libraryDirectory
        )

        #expect(files.map(\.recordName) == [
            "book_sources",
            "books_meta",
            "replace_rules"
        ])
        #expect(files.map(\.localURL.lastPathComponent) == [
            "book_sources.json",
            "books_meta.json",
            "replace_rules.json"
        ])
        #expect(files.map { $0.localURL.deletingLastPathComponent() } == [
            applicationSupportDirectory,
            applicationSupportDirectory,
            libraryDirectory
        ])
    }

    @Test("sign-in sync waits for choice before overwriting remote backup")
    func signInSyncWaitsForChoiceBeforeOverwritingRemoteBackup() {
        let remoteManifest = ICloudSyncManifest(
            deviceId: "other-device",
            deviceName: "Other iPhone",
            backupDate: Date(timeIntervalSince1970: 100),
            appVersion: "1.0"
        )

        #expect(ICloudSyncManager.signInAction(
            remoteManifest: nil,
            hasLocalData: true,
            currentDeviceId: "this-device"
        ) == .backup)
        #expect(ICloudSyncManager.signInAction(
            remoteManifest: remoteManifest,
            hasLocalData: false,
            currentDeviceId: "this-device"
        ) == .restore)
        #expect(ICloudSyncManager.signInAction(
            remoteManifest: remoteManifest,
            hasLocalData: true,
            currentDeviceId: "this-device"
        ) == .waitForUserChoice)
        #expect(ICloudSyncManager.signInAction(
            remoteManifest: remoteManifest,
            hasLocalData: true,
            currentDeviceId: "other-device"
        ) == .backup)
    }

    private func loadMainAppEntitlements() throws -> [String: Any] {
        let fileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = try #require(findRepoRoot(from: fileURL))
        let entitlementsURL = repoRoot.appendingPathComponent("Resources/Yuedu-Reader.entitlements")
        let data = try Data(contentsOf: entitlementsURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: Any])
    }

    private func findRepoRoot(from fileURL: URL) -> URL? {
        var candidate = fileURL.deletingLastPathComponent()
        while candidate.path != "/" {
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("Yuedu-Reader.xcodeproj").path
            ) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }
}
