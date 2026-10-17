import Observation
import SwiftUI

@MainActor @Observable
private final class LegadoRuntimeProbeModel {
    var report: LegadoPrototypeProbeReport?
    var isRunning = false
    var passed = false
    var errorMessage: String?

    func inspect(using service: LegadoPrototypeProbeService) async {
        report = await service.inspect()
    }

    func run(using service: LegadoPrototypeProbeService) async {
        guard !isRunning else { return }
        isRunning = true
        passed = false
        errorMessage = nil
        defer { isRunning = false }
        do {
            let completed = try await service.run()
            try Task.checkCancellation()
            report = completed
            passed = true
        } catch is CancellationError {
            errorMessage = localized("Legado 驗證已取消")
        } catch {
            errorMessage = error.localizedDescription
            AppLogger.parse("Legado prototype probe failed: \(error.localizedDescription)")
        }
    }
}

struct LegadoRuntimeProbeView: View {
    @Environment(\.appDependencies) private var dependencies
    @State private var model = LegadoRuntimeProbeModel()
    @State private var runIdentifier: UUID?

    var body: some View {
        Form {
            Section {
                if let report = model.report {
                    LabeledContent(localized("Legado 原生橋接"), value: localized(report.bridgePresent ? "Legado 已就緒" : "Legado 尚未配置"))
                    LabeledContent(localized("Legado 執行環境"), value: localized(report.available ? "Legado 已就緒" : "Legado 尚未配置"))
                } else {
                    ProgressView(localized("Legado 檢查中"))
                }
            } footer: {
                Text(localized("Legado 原型說明"))
                    .dsSectionFooter()
            }

            if let report = model.report, !report.issues.isEmpty {
                Section(header: Text(localized("Legado 配置問題"))) {
                    ForEach(report.issues, id: \.self) { issue in
                        Text(verbatim: issue)
                            .font(DSFont.caption)
                            .foregroundStyle(DSColor.textSecondary)
                            .textSelection(.enabled)
                    }
                }
            }

            Section {
                Button(localized("Legado 執行本地驗證")) { runIdentifier = UUID() }
                    .disabled(model.isRunning || model.report?.available != true)
                    .accessibilityIdentifier("legado_runtime_run_probe")
                if model.isRunning {
                    ProgressView(localized("Legado 驗證中"))
                    Button(localized("取消"), role: .cancel) { runIdentifier = nil }
                }
            }

            if let error = model.errorMessage {
                Section(header: Text(localized("Legado 驗證失敗"))) {
                    Text(verbatim: error)
                        .foregroundStyle(DSColor.destructive)
                        .textSelection(.enabled)
                }
            }
            if model.passed, let report = model.report {
                Section(header: Text(localized("Legado 本地驗證通過"))) {
                    ForEach(report.completedSteps, id: \.self) { step in
                        Label(localized(step), systemImage: "checkmark.circle")
                            .foregroundStyle(DSColor.success)
                    }
                    if let milliseconds = report.elapsedMilliseconds {
                        LabeledContent(localized("Legado 驗證耗時"), value: String(format: "%.0f ms", milliseconds))
                    }
                } footer: {
                    Text(localized("Legado 通過範圍說明"))
                        .dsSectionFooter()
                }
            }
        }
        .navigationTitle(localized("Legado 核心驗證"))
        .toolbarTitleDisplayMode(.inline)
        .task { await model.inspect(using: dependencies.legadoPrototype) }
        .task(id: runIdentifier) {
            guard let identifier = runIdentifier else { return }
            await model.run(using: dependencies.legadoPrototype)
            if runIdentifier == identifier { runIdentifier = nil }
        }
    }
}

#Preview {
    NavigationStack { LegadoRuntimeProbeView() }
}
