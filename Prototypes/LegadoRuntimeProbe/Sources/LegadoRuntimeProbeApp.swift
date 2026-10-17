import SwiftUI
import Observation

@main struct LegadoRuntimeProbeApp: App {
    var body: some Scene { WindowGroup { ProbeView() } }
}

@MainActor @Observable final class ProbeModel {
    var report: String?
    var failure: String?
    var isRunning = false
    let runner = ProbeRunner()

    func inspect() async {
        do { report = try await runner.inspect(); failure = nil }
        catch { failure = error.localizedDescription }
    }
    func run() async {
        guard !isRunning else { return }
        isRunning = true
        report = nil
        failure = nil
        defer { isRunning = false }
        do {
            let result = try await runner.run()
            try Task.checkCancellation()
            report = result
        } catch is CancellationError { failure = localized("probe.cancelled") }
        catch { failure = error.localizedDescription }
    }
}

struct ProbeView: View {
    @State private var model = ProbeModel()
    @State private var runID: UUID?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button(localized("probe.diagnose")) { runID = nil; Task { await model.inspect() } }
                        .disabled(model.isRunning)
                    Button(localized("probe.run")) { runID = UUID() }
                        .disabled(model.isRunning)
                    if model.isRunning {
                        ProgressView(localized("probe.running"))
                        Button(localized("probe.cancel"), role: .cancel) { runID = nil }
                    }
                } footer: {
                    Text(localized("probe.fixture_notice"))
                }
                if let failure = model.failure {
                    Section(localized("probe.failed")) {
                        Text(verbatim: failure).textSelection(.enabled)
                    }
                }
                Section(localized("probe.report")) {
                    if let report = model.report { Text(verbatim: report).textSelection(.enabled) }
                    else { Text(localized("probe.empty")) }
                }
            }
            .navigationTitle(localized("probe.title"))
            .toolbarTitleDisplayMode(.inline)
            .task { await model.inspect() }
            .task(id: runID) {
                guard let identifier = runID else { return }
                await model.run()
                if runID == identifier { runID = nil }
            }
        }
    }
}

func localized(_ key: String) -> String { NSLocalizedString(key, comment: "Standalone runtime prototype") }

#Preview { ProbeView() }
