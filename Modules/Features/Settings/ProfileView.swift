import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var store: BookStore
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @Bindable private var gs = GlobalSettings.shared
    @State private var showAggregationSettings = false
    @State private var showDownloadManager = false
    @State private var showReplaceRules = false
    @State private var showBackupSync = false
    @State private var showCacheManagement = false
    @State private var showLanServer = false
    @State private var showLegadoMigration = false
    @State private var showTTSSettings = false
    @State private var showNetworkSettings = false
    @State private var showAISettings = false
    @State private var showAIPaywall = false
    #if DEBUG
    @State private var autoOpenDiagnostics = false
    @State private var autoOpenFeedbackCenter = false
    #endif
    private var appLanguageFooter: String {
        if ReaderExperienceConfiguration.isLocalExperience {
            return localized("中文介面使用簡體；其他語言可在系統設定中選擇。")
        }
        // The name iOS Settings lists the app under: the display name (閱讀), not the bundle name.
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "App"
        let template = localized("跟隨系統語言。可在「設定 → %@ → 語言」單獨設定")
        return String(format: template, appName)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private var appearanceThemeName: String {
        gs.appearanceTheme(
            for: colorScheme,
            isProActive: subscriptionStore.hasAccess(.readerThemePacks)
        ).localizedName
    }

    var body: some View {
        NavigationStack {
                Form {
                    if ReaderExperienceConfiguration.accountServicesEnabled {
                        Section {
                            NavigationLink(destination: UserDetailView()) {
                                AccountRowContent()
                            }
                            .accessibilityIdentifier("settings_account_row")
                        }
                        .interfaceSectionSurface()
                    }
                    // ── App Language ──
                    Section {
                        DSSettingsRow(
                            icon: "globe",
                            title: localized("語言"),
                            action: {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    openURL(url)
                                }
                            }
                        )
                        .rootTabTitleScrollAnchor()
                    } header: {
                        Text(localized("App 語言"))
                            .foregroundStyle(DSColor.textSecondary)
                    } footer: {
                        Text(appLanguageFooter)
                            .dsSectionFooter()
                    }
                    .interfaceSectionSurface()

                    Section(header: Text(localized("外觀")).foregroundStyle(DSColor.textSecondary)) {
                        NavigationLink {
                            AppearanceThemeView()
                        } label: {
                            HStack {
                                Label(localized("外觀主題"), systemImage: "paintpalette.fill")
                                    .foregroundColor(DSColor.textPrimary)
                                    .labelStyle(IconConsistentLabelStyle())
                                Spacer(minLength: 12)
                                Text(appearanceThemeName)
                                    .font(DSFont.caption)
                                    .foregroundColor(DSColor.textSecondary)
                            }
                        }
                    }
                    .interfaceSectionSurface()

                    // 書架顯示 (每列欄數, 預設封面) lives in 外觀主題's 介面 since 2026-09-29.

                    // ── Book Source Management ──
                    // 管理來源配置 and 遠端書庫 are 資源庫's since 5h (Phase 5 plan, decision 30).
                    Section(header: Text(localized("來源配置管理")).foregroundStyle(DSColor.textSecondary)) {
                        // 聚合設定 (unified library 5d-3d, decision 21): here only, as Emby's
                        // aggregation settings sit in its user settings.
                        DSSettingsRow(
                            icon: "square.stack.3d.up.fill",
                            title: localized("聚合設定"),
                            action: { showAggregationSettings = true }
                        )
                        .accessibilityIdentifier("settings_aggregation")

                        DSSettingsRow(
                            icon: "arrow.down.circle.fill",
                            title: localized("下載管理"),
                            detail: String(format: localized("%d 本"), downloadedBooksCount),
                            action: { showDownloadManager = true }
                        )


                        DSSettingsRow(
                            icon: "network",
                            title: localized("網路設定"),
                            action: { showNetworkSettings = true }
                        )
                    }
                    .interfaceSectionSurface()

                    // ── Reading Tools ──
                    Section(header: Text(localized("閱讀工具")).foregroundStyle(DSColor.textSecondary)) {
                        DSSettingsRow(
                            icon: "waveform",
                            title: localized("語音朗讀設定"),
                            action: { showTTSSettings = true }
                        )

                        DSSettingsRow(
                            icon: "sparkles",
                            // Named for what it is — the reader's panel is also called
                            // 「AI 助手」, and someone looking for 人物卡 went here first.
                            title: localized("AI 助手設定"),
                            detail: isAILocked ? localized("需要 Pro") : aiAssistantDetail,
                            isLocked: isAILocked,
                            action: {
                                if isAILocked { showAIPaywall = true } else { showAISettings = true }
                            }
                        )
                        
                        DSSettingsRow(
                            icon: "text.magnifyingglass",
                            title: localized("替換規則"),
                            action: { showReplaceRules = true }
                        )

                    }
                    .interfaceSectionSurface()

                    // ── Data Management ──
                    Section(header: Text(localized("資料管理")).foregroundStyle(DSColor.textSecondary)) {
                        DSSettingsRow(
                            icon: "arrow.triangle.2.circlepath.icloud",
                            title: localized("備份與同步"),
                            detail: ReaderExperienceConfiguration.cloudKitEnabled
                                ? localized("iCloud、WebDAV") : localized("WebDAV 同步"),
                            action: { showBackupSync = true }
                        )

                        DSSettingsRow(
                            icon: "externaldrive.fill",
                            title: localized("快取管理"),
                            action: { showCacheManagement = true }
                        )

                        DSSettingsRow(
                            icon: "wifi",
                            title: localized("局域網服務"),
                            action: { showLanServer = true }
                        )
                        DSSettingsRow(
                            icon: "arrow.down.doc.fill",
                            title: localized("Legado 資料遷移"),
                            action: { showLegadoMigration = true }
                        )
                    }
                    .interfaceSectionSurface()

                    // ── Advanced ──
                    Section(header: Text(localized("進階")).foregroundStyle(DSColor.textSecondary)) {
                        NavigationLink {
                            SelfRenewalSettingsView()
                        } label: {
                            SettingsRowLabel(localized("自簽與續簽"), systemImage: "signature")
                        }
                        .accessibilityIdentifier("settings_self_renewal_probe")
                        NavigationLink {
                            LegadoRuntimeProbeView()
                        } label: {
                            Label(localized("Legado 核心驗證"), systemImage: "testtube.2")
                                .foregroundColor(DSColor.textPrimary)
                                .labelStyle(IconConsistentLabelStyle())
                        }
                        .accessibilityIdentifier("settings_legado_runtime_probe")
                        // 回饋中心 replaced 診斷與回報 (2026-10-15): reports, replies, and the
                        // diagnostic log viewer as its 診斷紀錄 row.
                        if ReaderExperienceConfiguration.feedbackServicesEnabled {
                            NavigationLink {
                                FeedbackCenterView()
                            } label: {
                                SettingsRowLabel(localized("回饋中心"), systemImage: "exclamationmark.bubble")
                            }
                            .accessibilityIdentifier("settings_feedback_center")
                        } else {
                            NavigationLink {
                                DiagnosticsView()
                            } label: {
                                SettingsRowLabel(localized("診斷紀錄"), systemImage: "waveform.path.ecg")
                            }
                            .accessibilityIdentifier("settings_diagnostics")
                        }
                    }
                    .interfaceSectionSurface()

                    // ── About ──
                    Section(header: Text(localized("關於")).foregroundStyle(DSColor.textSecondary)) {
                        NavigationLink {
                            LocalReaderAboutView(appVersion: appVersion)
                        } label: {
                            HStack {
                                Label(localized("關於本地書架"), systemImage: "info.circle.fill")
                                    .foregroundColor(DSColor.textPrimary)
                                    .labelStyle(IconConsistentLabelStyle())
                                Spacer(minLength: 12)
                                Text(appVersion)
                                    .font(DSFont.caption)
                                    .foregroundColor(DSColor.textSecondary)
                            }
                        }
                    }
                    .interfaceSectionSurface()
                }
            .softScrollEdges()
            .themedAppSurface(for: .settings)
            .rootTabTitle(localized("設定"), onScroll: .minimizesBar)
            // Back from 外觀主題: its 淺色／深色 preview ends here.
            .onAppear { gs.endAppearanceSlotPreview() }
            .navigationDestination(isPresented: $showAggregationSettings) {
                AggregationSettingsView()
            }
            #if DEBUG
            // Screenshot/driver hooks: `-open-diagnostics` pushes 診斷紀錄 and
            // `-open-feedback-center` pushes 回饋中心 straight from launch, so their
            // appearance can be inspected without driving the tab bar. Same shape as the
            // `-browser-overlay` launch flags in `yuedu_appApp.init()`, and compiled out
            // of Release.
            .navigationDestination(isPresented: $autoOpenDiagnostics) {
                DiagnosticsView()
            }
            .navigationDestination(isPresented: $autoOpenFeedbackCenter) {
                FeedbackCenterView()
            }
            .onAppear {
                let arguments = ProcessInfo.processInfo.arguments
                if arguments.contains("-open-diagnostics") {
                    autoOpenDiagnostics = true
                } else if arguments.contains("-open-feedback-center"),
                          ReaderExperienceConfiguration.feedbackServicesEnabled {
                    autoOpenFeedbackCenter = true
                }
            }
            #endif
            .sheet(isPresented: $showDownloadManager) {
                DownloadManagementView()
                    .environmentObject(store)
            }
            .sheet(isPresented: $showNetworkSettings) {
                NetworkSettingsView()
            }
            .sheet(isPresented: $showAISettings) {
                AISettingsView()
            }
            .sheet(isPresented: $showAIPaywall) {
                PaywallView(highlightedFeature: .aiReading)
                    .environmentObject(subscriptionStore)
            }
            .sheet(isPresented: $showReplaceRules) {
                ReplaceRuleListView()
            }
            .sheet(isPresented: $showBackupSync) {
                BackupSyncView()
            }
            .sheet(isPresented: $showCacheManagement) {
                CacheManagementView()
            }
            .sheet(isPresented: $showLanServer) {
                LanServerView().environmentObject(store)
            }
            .sheet(isPresented: $showLegadoMigration) {
                LegadoMigrationView().environmentObject(store)
            }
            .sheet(isPresented: $showTTSSettings) {
                TTSSettingsView()
            }
        }
    }

    private var downloadedBooksCount: Int {
        store.books.filter { $0.isOnline && $0.offlineDownloadState == .available }.count
    }

    /// Standalone local features use capability access rather than membership.
    private var isAILocked: Bool {
        !ReaderPremiumVisibilityPolicy(isProActive: subscriptionStore.hasUnrestrictedFeatureAccess).allowsAI
    }

    /// Says whether AI is usable at a glance. A reader who has not set it up should not have
    /// to open the screen to find that out.
    private var aiAssistantDetail: String {
        AIProviderStore.shared.hasConfiguredProfile ? localized("已啟用") : localized("未設定")
    }

    @ViewBuilder func AccountRowContent() -> some View {
        HStack(spacing: 15) {
            AccountAvatarView(size: 50)

            VStack(alignment: .leading, spacing: 4) {
                Text(gs.isLoggedIn ? (gs.accountDisplayName.isEmpty ? localized("已登入") : gs.accountDisplayName) : localized("尚未登入"))
                    .font(DSFont.headline)
                    .foregroundStyle(DSColor.textPrimary)
                Text(gs.accountSubtitle)
                    .font(DSFont.caption).foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()
        }
    }

}

#Preview {
    SettingsView()
        .environmentObject(BookStore())
        .environmentObject(SubscriptionStore.shared)
}
