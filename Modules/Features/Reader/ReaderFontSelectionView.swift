import SwiftUI
import UIKit

/// Uses the same selection and imported-font records as Reading Settings. This
/// page only renders choices; registration, deletion and persistence stay with
/// the existing settings service and the reader's first-level importer.
struct ReaderFontSelectionView: View {
    @Binding var selection: String?
    let defaultFontName: String
    let usesPublicationFontDefault: Bool
    let userFonts: [UserFontInfo]
    let onImport: () -> Void
    let onDelete: (UserFontInfo) -> Void

    @State private var fontToDelete: UserFontInfo?

    var body: some View {
        Form {
            Section {
                // One picker owns every choice, including nil (the publication
                // or system default); selecting a bundled/imported face updates
                // the existing theme/global-scoped setting through its binding.
                Picker(localized(ReadingSettingsScopeItem.font.titleKey), selection: $selection) {
                    ReaderFontPreviewRow(title: defaultFontName, postScriptName: nil)
                        .tag(nil as String?)

                    ForEach(ReaderFontCatalog.bundledFonts) { font in
                        fontChoice(title: localized(font.titleKey), postScriptName: font.postScriptName)
                    }

                    ForEach(userFonts) { font in
                        Group {
                            // Importing an included face can create a user record
                            // for the same PostScript name; a picker needs one tag
                            // per face. The imported record remains deletable below.
                            if !ReaderFontCatalog.isBundled(postScriptName: font.postScriptName) {
                                fontChoice(title: font.displayName, postScriptName: font.postScriptName)
                            }
                        }
                    }

                    if let selection, !containsSelection(selection) {
                        fontChoice(title: selection, postScriptName: selection)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .accessibilityIdentifier("reader.font.selection")
            } footer: {
                if selection == nil && usesPublicationFontDefault {
                    Text(localized("Reader.FontPreview.PublicationDefault"))
                        .dsSectionFooter()
                }
            }
            .interfaceSectionSurface()

            Section {
                Button(action: onImport) {
                    SettingsRowLabel(localized("匯入字體..."), systemImage: "plus", role: .action)
                }

                if !userFonts.isEmpty {
                    Menu {
                        ForEach(userFonts) { font in
                            Button(role: .destructive) {
                                fontToDelete = font
                            } label: {
                                Label(font.displayName, systemImage: "trash")
                            }
                        }
                    } label: {
                        SettingsRowLabel(localized("刪除字體"), systemImage: "trash", role: .action)
                    }
                }
            }
            .interfaceSectionSurface()
        }
        .softScrollEdges()
        .themedAppSurface(for: .settings)
        .navigationTitle(localized(ReadingSettingsScopeItem.font.titleKey))
        .toolbarTitleDisplayMode(.inline)
        .alert(
            localized("刪除此字體？"),
            isPresented: Binding(
                get: { fontToDelete != nil },
                set: { if !$0 { fontToDelete = nil } }
            ),
            presenting: fontToDelete
        ) { font in
            Button(localized("刪除"), role: .destructive) {
                onDelete(font)
                fontToDelete = nil
            }
            Button(localized("取消"), role: .cancel) {
                fontToDelete = nil
            }
        } message: { font in
            Text(font.displayName + "\n" + localized("刪除後，全局字體與閱讀設定將無法再使用此字體。"))
        }
    }

    private func containsSelection(_ postScriptName: String) -> Bool {
        ReaderFontCatalog.isBundled(postScriptName: postScriptName)
            || userFonts.contains { $0.postScriptName == postScriptName }
    }

    private func fontChoice(title: String, postScriptName: String) -> some View {
        ReaderFontPreviewRow(title: title, postScriptName: postScriptName)
            .tag(Optional(postScriptName))
            .disabled(!ReaderFontPreviewRow.isAvailable(postScriptName: postScriptName))
    }
}

/// Labels keep the interface font. Only the sample uses the chosen face, scaled
/// from the semantic body style so large accessibility sizes can wrap naturally.
private struct ReaderFontPreviewRow: View {
    let title: String
    let postScriptName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(title)
                .font(DSFont.body)
                .foregroundStyle(DSColor.textPrimary)

            if Self.isAvailable(postScriptName: postScriptName) {
                Text(localized("Reader.FontPreview.Sample"))
                    .font(DSFont.readerFontPreview(postScriptName: postScriptName))
                    .foregroundStyle(DSColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(String(
                    format: localized("找不到字體「%@」，目前使用系統字體。重新匯入後會自動恢復。"),
                    title
                ))
                .font(DSFont.footnote)
                .foregroundStyle(DSColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, DSSpacing.xs)
        .accessibilityElement(children: .combine)
    }

    static func isAvailable(postScriptName: String?) -> Bool {
        guard let postScriptName else { return true }
        return UIFont(name: postScriptName, size: UIFont.labelFontSize) != nil
    }
}

#Preview {
    NavigationStack {
        ReaderFontSelectionView(
            selection: .constant("LXGWWenKaiLite-Regular"),
            defaultFontName: localized("系統字體"),
            usesPublicationFontDefault: false,
            userFonts: [],
            onImport: {},
            onDelete: { _ in }
        )
    }
}

#Preview("Large type and a missing font") {
    NavigationStack {
        ReaderFontSelectionView(
            selection: .constant("Unavailable-Reader-Font"),
            defaultFontName: localized("書籍預設字體"),
            usesPublicationFontDefault: true,
            userFonts: [],
            onImport: {},
            onDelete: { _ in }
        )
    }
    .environment(\.dynamicTypeSize, .accessibility5)
}
