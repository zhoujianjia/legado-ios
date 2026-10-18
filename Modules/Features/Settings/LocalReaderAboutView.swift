import SwiftUI

/// The standalone reader has its own support links and no upstream account,
/// commercial terms, mailing address or member-only TestFlight application.
struct LocalReaderAboutView: View {
    let appVersion: String

    var body: some View {
        List {
            Section {
                SettingsValueLabel(title: localized("版本"), systemImage: "number", value: appVersion)
            } header: {
                Text(localized("Legado iOS"))
            } footer: {
                Text(localized("本地閱讀與書源管理"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()

            Section {
                Link(destination: URL(string: "https://github.com/zhoujianjia/legado-ios")!) {
                    SettingsRowLabel(localized("專案原始碼"), systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: URL(string: "https://github.com/zhoujianjia/legado-ios/issues")!) {
                    SettingsRowLabel(localized("問題與建議"), systemImage: "exclamationmark.bubble")
                }
                Link(destination: URL(string: "https://github.com/zhoujianjia/legado-ios/blob/main/LICENSE")!) {
                    SettingsRowLabel(localized("原始碼與開源授權"), systemImage: "doc.text")
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
                Text(localized("沿用 Yuedu Reader 的原生閱讀介面，書源相容以 Legado 為目標。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()
        }
        .softScrollEdges()
        .navigationTitle(localized("關於 Legado iOS"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
    }
}

#Preview {
    NavigationStack {
        LocalReaderAboutView(appVersion: "3.0.0")
    }
}
