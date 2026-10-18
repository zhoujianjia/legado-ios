import SwiftUI

/// The standalone reader has its own support links and no upstream account,
/// commercial terms, mailing address or member-only TestFlight application.
struct LocalReaderAboutView: View {
    let appVersion: String
    private let links = ReaderProjectLinks()

    var body: some View {
        List {
            Section {
                SettingsValueLabel(title: localized("版本"), systemImage: "number", value: appVersion)
            } header: {
                Text(localized("本地書架"))
            } footer: {
                Text(localized("本地閱讀與書源管理"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()

            Section {
                Link(destination: links.sourceURL) {
                    SettingsRowLabel(localized(links.sourceCommit == nil ? "專案原始碼" : "本版本原始碼"),
                                     systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: ReaderProjectLinks.issuesURL) {
                    SettingsRowLabel(localized("問題與建議"), systemImage: "exclamationmark.bubble")
                }
                Link(destination: links.licenseOverviewURL) {
                    SettingsRowLabel(localized("原始碼與開源授權"), systemImage: "doc.text")
                }
            } footer: {
                if links.sourceCommit == nil {
                    Text(localized("此版本未記錄來源提交；原始碼連結指向 main 分支。"))
                        .dsSectionFooter()
                }
            }
            .interfaceSectionSurface()

            Section {
                Link(destination: URL(string: "https://github.com/gedoor/legado")!) {
                    Text(verbatim: "Legado")
                }
                Link(destination: URL(string: "https://github.com/CHANG-JUI-LIN/Yuedu-reader")!) {
                    Text(verbatim: "Yuedu Reader")
                }
            } header: {
                Text(localized("開源致謝"))
            } footer: {
                Text(localized("獨立的本地閱讀器，與 Legado、Yuedu Reader 官方無關，亦未獲其背書。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()
        }
        .softScrollEdges()
        .navigationTitle(localized("關於本地書架"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
    }
}

#Preview {
    NavigationStack {
        LocalReaderAboutView(appVersion: "3.0.0")
    }
}
