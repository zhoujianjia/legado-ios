import Foundation
import Observation
import SwiftUI

@MainActor @Observable
private final class SelfRenewalProbeModel {
    var report: SelfRenewalTransportProbeReport?
    var reportURL: URL?
    var isRunning = false
    var wasCancelled = false
    var exportError: String?

    func run(using probe: SelfRenewalTransportProbe) async {
        guard !isRunning else { return }
        isRunning = true
        wasCancelled = false
        exportError = nil
        report = nil
        reportURL = nil
        defer { isRunning = false }
        do {
            let result = await probe.run()
            try Task.checkCancellation()
            report = result
            reportURL = try await SelfRenewalProbeExport.write(result)
            try Task.checkCancellation()
        } catch is CancellationError {
            wasCancelled = true
            reportURL = nil
        } catch {
            exportError = localized("驗證報告無法儲存")
            AppLogger.parse("Self-renewal probe export failed: \(error.localizedDescription)")
        }
    }
}

/// An opt-in diagnostic, not a signing service. Opening Settings starts no connection.
struct SelfRenewalProbeView: View {
    @Environment(\.appDependencies) private var dependencies
    @State private var model = SelfRenewalProbeModel()
    @State private var runIdentifier: UUID?

    var body: some View {
        List {
            Section {
                ThemedLabeledContent(title: localized("自續簽狀態"), value: localized("尚未驗證"))
                    .accessibilityIdentifier("self_renewal_unverified")
                Button {
                    runIdentifier = UUID()
                } label: {
                    SettingsRowLabel(localized("開始連線驗證"), systemImage: "network", role: .action)
                }
                .disabled(model.isRunning)
                .accessibilityIdentifier("self_renewal_run_probe")

                if model.isRunning {
                    ProgressView(localized("正在檢查本機服務"))
                        .accessibilityIdentifier("self_renewal_probe_running")
                    Button(localized("取消"), role: .cancel) { runIdentifier = nil }
                        .accessibilityIdentifier("self_renewal_cancel_probe")
                } else if model.wasCancelled {
                    Text(localized("連線檢查已取消"))
                        .foregroundStyle(DSColor.textSecondary)
                }
            } footer: {
                Text(localized("僅檢查本機設備服務，尚不執行簽名或安裝。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()

            if let report = model.report {
                Section {
                    ForEach(report.attempts, id: \.address.rawValue) { attempt in
                        ThemedLabeledContent(
                            title: endpoint(attempt), value: localized(outcomeKey(attempt.outcome))
                        )
                        .accessibilityIdentifier(attempt.address == .ipv4
                                                 ? "self_renewal_attempt_ipv4" : "self_renewal_attempt_ipv6")
                    }
                } header: {
                    Text(localized("本機連線結果"))
                } footer: {
                    Text(localized("此探測僅覆蓋本機固定入口，無法判斷其他安裝通道是否可用。"))
                        .dsSectionFooter()
                }
                .interfaceSectionSurface()
            }

            if let reportURL = model.reportURL {
                Section {
                    ShareLink(item: reportURL) {
                        SettingsRowLabel(localized("匯出驗證報告"), systemImage: "square.and.arrow.up", role: .action)
                    }
                    .accessibilityIdentifier("self_renewal_export_report")
                }
                .interfaceSectionSurface()
            }

            if let error = model.exportError {
                Section {
                    Text(error)
                        .foregroundStyle(DSColor.destructive)
                }
                .interfaceSectionSurface()
            }
        }
        .softScrollEdges()
        .navigationTitle(localized("自續簽驗證"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .task(id: runIdentifier) {
            guard let identifier = runIdentifier else { return }
            await model.run(using: dependencies.selfRenewalTransportProbe)
            if runIdentifier == identifier { runIdentifier = nil }
        }
    }

    private func endpoint(_ attempt: SelfRenewalTransportAttempt) -> String {
        let host = attempt.address == .ipv6 ? "[::1]" : "127.0.0.1"
        return "\(host):\(attempt.port)"
    }

    private func outcomeKey(_ outcome: SelfRenewalTransportOutcome) -> String {
        switch outcome {
        case .lockdownConfirmed: return "已確認設備服務"
        case .protocolError: return "設備服務返回錯誤"
        case .unexpectedService: return "回應無法確認服務"
        case .invalidResponse: return "回應格式無效"
        case .transportFailed: return "連線未建立"
        case .peerClosed: return "服務關閉連線"
        case .timedOut: return "連線逾時"
        case .cancelled: return "連線檢查已取消"
        case .internalError: return "無法完成檢查"
        }
    }
}

private enum SelfRenewalProbeExport {
    private struct Envelope: Encodable {
        let report: SelfRenewalTransportProbeReport
        let appVersion: String?
        let appBuild: String?
        let sourceCommit: String?
        let operatingSystem: String
        let computerPoweredOff = "notMeasured"
        let companionAppsAbsent = "notMeasured"
        let dynamicRemotePairingDiscoveryAttempted = false
        let interpretation = "Fixed loopback lockdown QueryType only. No automatic renewal or installation has been proven."
    }

    /// Encoding and file I/O stay off the main actor in the app's Swift 5 mode.
    nonisolated static func write(_ report: SelfRenewalTransportProbeReport) async throws -> URL {
        let started = SourcePerfTrace.now
        defer {
            SourcePerfTrace.record("diagnostic.selfRenewalExport", "main=\(Thread.isMainThread) attempts=\(report.attempts.count)", since: started)
        }
        try Task.checkCancellation()
        let rawCommit = Bundle.main.object(forInfoDictionaryKey: "YueduExperienceSourceCommit") as? String
        let source = rawCommit.flatMap { value in
            value.count == 40 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } ? value : nil
        }
        let envelope = Envelope(
            report: report,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            sourceCommit: source, operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(envelope)
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SelfRenewalProbe-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("SelfRenewalProbe-report.json")
        do {
            try data.write(to: file, options: .atomic)
            try Task.checkCancellation()
            return file
        } catch {
            do { try FileManager.default.removeItem(at: directory) }
            catch { AppLogger.parse("Self-renewal probe temporary export cleanup failed: \(error.localizedDescription)") }
            throw error
        }
    }
}

#Preview {
    NavigationStack { SelfRenewalProbeView() }
}
