import Foundation
import Observation
import SwiftUI
import UIKit

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
            let result = await probe.runDiscovery()
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
    @Environment(\.openURL) private var openURL
    @State private var model = SelfRenewalProbeModel()
    @State private var runIdentifier: UUID?

    var body: some View {
        List {
            Section {
                ThemedLabeledContent(localized("自續簽狀態"), value: localized("尚未驗證"))
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
                Text(localized("手動開始時可能請求本機網路權限；僅檢查屬於本機的入口，不執行簽名或安裝。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()

            if let discovery = model.report?.remotePairingDiscovery {
                Section {
                    ThemedLabeledContent(localized("探索結果"), value: localized(outcomeKey(discovery.outcome)))
                        .accessibilityIdentifier("self_renewal_discovery_outcome")
                    ThemedLabeledContent(localized("探索階段"), value: localized(phaseKey(discovery.phase)))
                        .accessibilityIdentifier("self_renewal_discovery_phase")
                    ThemedLabeledContent(localized("發現的服務"), value: discovery.discoveredServiceCount.formatted())
                    ThemedLabeledContent(localized("解析的位址"), value: discovery.resolvedAddressCount.formatted())
                    ThemedLabeledContent(localized("排除的位址"), value: discovery.rejectedAddressCount.formatted())
                    ThemedLabeledContent(localized("核准的本機入口"), value: discovery.approvedEndpointCount.formatted())
                    ThemedLabeledContent(localized("TCP 連線嘗試"), value: discovery.tcpConnectionAttemptsStarted.formatted())
                    if mayNeedLocalNetworkAccess(discovery) {
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        } label: {
                            SettingsRowLabel(localized("開啟系統設定"), systemImage: "gearshape", role: .action)
                        }
                        .accessibilityIdentifier("self_renewal_open_settings")
                    }
                } header: {
                    Text(localized("本機連線結果"))
                } footer: {
                    Text(localized(mayNeedLocalNetworkAccess(discovery)
                                   ? "本機網路存取可能受限，可在系統設定中檢查權限。TCP 連通仍不能確認設備服務或自續簽。"
                                   : "TCP 連通僅代表本機入口可連線，仍不能確認設備服務或自續簽；沒有結果也不能排除其他通道。"))
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

    private func mayNeedLocalNetworkAccess(_ discovery: SelfRenewalRemotePairingDiscoveryReport) -> Bool {
        // DNS-SD PolicyDenied is a permission signal, including while waiting; it is
        // not evidence that an empty result or a POSIX error has this cause.
        [discovery.networkError, discovery.lastWaitingError].contains {
            $0?.domain == "dns" && $0?.code == -65570
        }
    }

    private func outcomeKey(_ outcome: SelfRenewalDiscoveryOutcome) -> String {
        switch outcome {
        case .tcpConnected: return "TCP 已連通，服務尚未確認"
        case .noLocalCandidate: return "未找到屬於本機的入口"
        case .discoveryTimedOut: return "服務探索逾時"
        case .discoveryUnavailable: return "服務探索無法使用"
        case .resolutionFailed: return "服務位址解析失敗"
        case .transportFailed: return "連線未建立"
        case .timedOut: return "連線逾時"
        case .cancelled: return "連線檢查已取消"
        case .interfaceChanged: return "本機網路介面已變更"
        case .discoveryChanged: return "探索結果已變更"
        case .limitExceeded: return "探索結果超過檢查上限"
        case .internalError: return "無法完成檢查"
        }
    }

    private func phaseKey(_ phase: SelfRenewalDiscoveryPhase) -> String {
        switch phase {
        case .snapshotting: return "讀取本機網路介面"
        case .discovering: return "探索服務"
        case .resolving: return "解析服務位址"
        case .checkingOwnership: return "核對本機位址"
        case .connecting: return "連線中"
        case .completed: return "檢查完成"
        }
    }
}

private enum SelfRenewalProbeExport {
    private struct Envelope: Encodable {
        let schemaVersion = 2
        let report: SelfRenewalTransportProbeReport
        let appVersion: String?
        let appBuild: String?
        let sourceCommit: String?
        let operatingSystem: String
        let computerPoweredOff = "notMeasured"
        let companionAppsAbsent = "notMeasured"
        let dynamicRemotePairingDiscoveryAttempted: Bool
        let interpretation = "Opt-in dynamic remote-pairing discovery, same-device address ownership checks, and TCP connection only. DNS-SD queries may be sent; no application frames are sent on TCP. Device service identity, automatic renewal, and installation remain unverified."
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
            sourceCommit: source, operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            dynamicRemotePairingDiscoveryAttempted: report.remotePairingDiscovery?.discoveryStarted == true
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
