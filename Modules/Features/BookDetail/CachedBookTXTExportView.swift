import SwiftUI

struct CachedBookTXTExportView: View {
    let request: CachedBookTXTExportRequest
    @Environment(\.dismiss) private var dismiss
    @State private var result: CachedBookTXTExportResult?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let result {
                        LabeledContent(localized("已快取章節"), value: "\(result.cachedChapterCount) / \(result.totalChapterCount)")
                        ShareLink(item: result.fileURL) {
                            Label(localized("儲存或分享 TXT"), systemImage: "square.and.arrow.up")
                        }
                    } else if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(DSColor.textSecondary)
                    } else {
                        ProgressView(localized("正在整理已快取正文…"))
                    }
                } footer: {
                    Text(localized("僅匯出本機已快取的正文，不會自動下載；未快取章節與圖片不包含在 TXT 中。"))
                        .dsSectionFooter()
                }
            }
            .navigationTitle(localized("匯出已快取 TXT"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(localized("關閉"))
                }
            }
            .task(id: request.id) {
                do {
                    result = try await CachedBookTXTExportService.export(request)
                } catch is CancellationError {
                    // Dismissing the sheet cancels its local file generation.
                } catch {
                    AppLogger.error("Cached TXT export failed", error: error)
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

#Preview {
    CachedBookTXTExportView(request: CachedBookTXTExportRequest(
        bookID: UUID(), title: "示例", author: "", chapters: []
    ))
}
