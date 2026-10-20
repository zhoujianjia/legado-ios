import SwiftUI
import UIKit
import JavaScriptCore
import LegadoRuntime

// MARK: - BookSourceFormLoginView
// Handles book sources whose `loginUi` JSON defines form fields (text/password/select/button).
// After the user fills in credentials and taps "Confirm", the loginUrl JS is executed
// with those credentials stored via LoginManager — mirroring Legado's SourceLoginDialog.
// Fields are laid out as a wrapping 12-column grid (LoginFormGrid) so each row's `style`
// decides its width, like Legado's login dialog.

struct BookSourceFormLoginView: View {
    let source: BookSource
    let onDismiss: () -> Void

    @MainActor private static weak var currentToastAlert: UIAlertController?

    private let gs = GlobalSettings.shared
    @State private var fields: [LoginField] = []
    @State private var fieldLabels: [String: String] = [:]
    @State private var values: [String: String] = [:]
    @State private var originalDismissState = LegadoOriginalLoginUIDismissState()
    @State private var originalDynamic = false
    @State private var originalFormSource: BookSource?
    @State private var originalPresentedSourceID: UUID?
    @State private var originalPresentedSourceURL: String?
    @State private var originalExitTask: Task<Void, Never>?
    @State private var originalExitGeneration = UUID()
    @State private var originalExitInProgress = false
    @State private var originalExitAllowsDismiss = false
    @State private var originalExitSystemDismissed = false
    @State private var originalRows: [LegadoOriginalLoginUIRow] = []
    @State private var originalLayout: LegadoOriginalLoginUILayout?
    @State private var originalControls: [String: LegadoOriginalLoginUIControl] = [:]
    @State private var originalUIOwnerGeneration = UUID()
    @State private var originalUIActive = false
    @State private var originalControlGeneration = UUID()
    @State private var originalTextTasks: [String: Task<Void, Never>] = [:]
    @State private var originalTextTaskTokens: [String: UUID] = [:]
    @State private var originalActionQueue: [OriginalQueuedAction] = []
    @State private var originalActionQueueHead = 0

    @MainActor private final class OriginalListenerChain {
        let id = UUID()
        var budget = LegadoOriginalLoginUIActionBudget()
    }

    private struct OriginalQueuedAction: Sendable {
        let action: String
        let isLongClick: Bool
        let rows: [LegadoOriginalLoginUIRow]
        let layout: LegadoOriginalLoginUILayout?
        let values: [String: String]
        let controls: [String: LegadoOriginalLoginUIControl]
        let credentials: [String: String]?
        let inputBindingFailed: Bool
        let chain: OriginalListenerChain
    }
    // Dynamic loginUi is evaluated asynchronously. Start in the same loading state
    // as Legado so the first render never presents an empty form as if it were ready.
    @State private var isLoading = true
    @State private var showFanqieLogin = false
    @State private var showLog = false
    @State private var canRetryLoginUi = false
    @State private var originalActionTask: Task<Void, Never>?
    @State private var originalActionGeneration = UUID()
    @State private var formSubmissionTask: Task<Void, Never>?
    @State private var formSubmissionGeneration = UUID()
    @State private var loginUIRenderTask: Task<Void, Never>?
    @State private var loginUIRenderGeneration = UUID()
    @State private var originalFormLoaded = false
    @State private var usesOriginalLoginUI = false
    @State private var usesOriginalLoginV2 = false
    @State private var originalV2ReplacingSource = false
    @State private var originalV2State = LegadoOriginalLoginV2State()
    @State private var originalV2Errors: [String: String] = [:]
    @State private var originalV2OwnerGeneration = UUID()
    @State private var originalV2InputGeneration = UUID()
    @State private var originalV2Task: Task<Void, Never>?
    @State private var originalV2TaskGeneration = UUID()
    @State private var originalV2Rendering = false
    @State private var originalV2RenderGeneration = UUID()
    @State private var originalV2DisabledButton: String?
    @State private var originalV2ToggleActionsEnabled = true
    @State private var originalV2Countdowns: [String: Int] = [:]
    @State private var originalV2CountdownTasks: [String: Task<Void, Never>] = [:]
    /// What a menu button's run reported when the source itself said nothing.
    /// Alert only, never the inline error Section: that Section sits below the whole
    /// form, which on a long source menu is far off-screen — the button still read
    /// as dead even once it had something to say.
    @State private var menuAlert: MenuActionAlert? = nil

    struct MenuActionAlert: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        var dismissesView = false
        var discardExitGeneration: UUID? = nil
    }

    var body: some View {
        NavigationStack {
            // Source-authored controls own their surfaces, so the page artwork stays
            // continuous between full-, half- and third-width actions.
            ScrollView {
                VStack(spacing: DSSpacing.md) {
                    if isLoading {
                        ProgressView()
                    }
                    if usesOriginalLoginV2 {
                        if let form = originalV2State.form {
                            LoginV2FormGrid(form: form, values: $originalV2State.values, errors: originalV2Errors,
                                disabledButton: originalV2DisabledButton,
                                toggleActionsEnabled: originalV2ToggleActionsEnabled,
                                countdowns: originalV2Countdowns,
                                onEdit: { originalV2InputGeneration = UUID() }, onAction: runOriginalV2Action)
                        }
                    } else {
                    LoginFormGrid(
                        fields: fields,
                        values: $values,
                        labels: fieldLabels,
                        onValueChange: { field, value in
                            if field.originalRowID != nil, usesOriginalLoginUI {
                                switch field.type {
                                case .text, .password: scheduleOriginalTextAction(field: field)
                                case .select, .toggle:
                                    originalDismissState.markChanged()
                                    if originalControls[field.id]?.listenerMapIsCurrent == true {
                                        values[field.name] = value
                                    }
                                    if field.type == .toggle, let caption = originalControls[field.id]?.cycleLabel {
                                        fieldLabels[field.id] = caption
                                    }
                                case .button: break
                                }
                            } else if field.type == .select {
                                persistCurrentFormValues()
                            }
                        },
                        onAction: handleButton,
                        onOriginalAction: { field, isLongClick in
                            runOriginalAction(field: field, isLongClick: isLongClick)
                        },
                        originalControls: usesOriginalLoginUI ? $originalControls : nil
                    )
                    }

                    if !usesOriginalLoginV2 && !originalV2ReplacingSource && Self.supportsFanqieLogin(source: source) {
                        Button {
                            showFanqieLogin = true
                        } label: {
                            Label(localized("番茄登入"), systemImage: "network")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(LoginPressButtonStyle())
                    }
                }
                .frame(maxWidth: DSLayout.readableFormWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, DSSpacing.lg)
                .padding(.vertical, DSSpacing.md)
            }
            .softScrollEdges()
            .scrollDismissesKeyboard(.interactively)
            .disabled(isLoading)
            .navigationTitle(loginTitle)
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .settings)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        requestFormClose()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(localized("取消"))
                }
                if !usesOriginalLoginV2 && !originalV2ReplacingSource && !fields.contains(where: { $0.type == .button }) {
                    ToolbarItem(placement: .topBarTrailing) {
                        if isLoading {
                            ProgressView()
                        } else {
                            Button {
                                doLogin()
                            } label: {
                                Image(systemName: "checkmark")
                            }
                            .accessibilityLabel(localized("完成"))
                    .disabled(usesOriginalLoginUI && !originalFormLoaded)
                        }
                    }
                } else if !usesOriginalLoginV2 && !originalV2ReplacingSource {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            if usesOriginalLoginUI {
                                doLogin()
                            } else {
                                persistCurrentFormValues()
                                onDismiss()
                            }
                        } label: {
                            Image(systemName: "checkmark")
                        }
                        .accessibilityLabel(localized("完成"))
                    .disabled(usesOriginalLoginUI && !originalFormLoaded)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showLoginHeader()
                        } label: {
                            Label(localized("查看登录头"), systemImage: "key.horizontal")
                        }
                        Button {
                            deleteLoginHeader()
                        } label: {
                            Label(localized("删除登录头"), systemImage: "trash")
                        }
                        Divider()
                        Button {
                            showLog = true
                        } label: {
                            Label(localized("日志"), systemImage: "doc.text")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel(localized("更多"))
                }
            }
        }
        .background(OriginalLoginDismissObserver(
            protectsDismissal: (usesOriginalLoginUI || originalV2ReplacingSource) && !originalExitAllowsDismiss,
            onAttempt: { requestFormClose() },
            onSystemDismiss: { requestFormClose(system: true) }))
        .onAppear {
            if !originalUIActive && !originalExitInProgress && !originalExitAllowsDismiss { loadUI() }
        }
        .onDisappear {
            // Presenting this form's own child cover is not leaving the form.
            // The native host observer still sees an actual parent dismissal.
            guard !showLog && !showFanqieLogin else { return }
            if usesOriginalLoginUI || originalV2ReplacingSource { requestFormClose(system: true) }
            else { cancelOriginalOperations() }
        }
        .onChange(of: source.id) { _, current in
            originalPresentedSourceID = current
            originalExitTask?.cancel()
            if usesOriginalLoginV2 || originalV2ReplacingSource { resetOriginalV2Source() }
        }
        .onChange(of: source.bookSourceUrl) { _, current in
            originalPresentedSourceURL = current
            originalExitTask?.cancel()
            if usesOriginalLoginV2 || originalV2ReplacingSource { resetOriginalV2Source() }
        }
        .onChange(of: source.loginUi) { _, _ in
            if usesOriginalLoginV2 || originalV2ReplacingSource { resetOriginalV2Source() }
        }
        .onChange(of: source.loginUrl) { _, _ in
            if usesOriginalLoginV2 || originalV2ReplacingSource { resetOriginalV2Source() }
        }
        .onChange(of: source.jsLib) { _, _ in
            if usesOriginalLoginV2 || originalV2ReplacingSource { resetOriginalV2Source() }
        }
        .sheet(isPresented: $showLog) {
            BookSourceDebugView()
        }
        .alert(
            menuAlert?.title ?? "",
            isPresented: Binding(
                get: { menuAlert != nil },
                set: { if !$0 { menuAlert = nil } }
            ),
            presenting: menuAlert
        ) { alert in
            if canRetryLoginUi {
                Button(localized("重試")) {
                    menuAlert = nil
                    canRetryLoginUi = false
                    loadUI()
                }
            }
            if let generation = alert.discardExitGeneration {
                Button(localized("不儲存退出"), role: .destructive) {
                    menuAlert = nil
                    requestFormClose(discardingFailedGeneration: generation)
                }
            }
            Button(localized("好"), role: .cancel) {
                let dismissesView = menuAlert?.dismissesView == true
                menuAlert = nil
                canRetryLoginUi = false
                if dismissesView { requestFormClose() }
            }
        } message: { alert in
            Text(alert.detail)
        }
        .sheet(isPresented: fanqiePresentationBinding(fullScreen: false)) {
            fanqieLoginBrowser
        }
        .fullScreenCover(isPresented: fanqiePresentationBinding(fullScreen: true)) {
            fanqieLoginBrowser
        }
    }

    private func fanqiePresentationBinding(fullScreen: Bool) -> Binding<Bool> {
        Binding(
            get: { showFanqieLogin && (UIDevice.current.userInterfaceIdiom == .pad) == fullScreen },
            set: { showFanqieLogin = $0 }
        )
    }

    private var fanqieLoginBrowser: some View {
        JsBridgeBrowserView(urlString: "https://fanqienovel.com", title: localized("番茄登入")) { _ in
            showFanqieLogin = false
        }
    }

    /// Legado's `login_source` title format: 「登入：源名稱」.
    private var loginTitle: String {
        let name = source.bookSourceName.isEmpty ? localized("來源配置登入") : source.bookSourceName
        return String(format: localized("登入：%@"), name)
    }

    // MARK: - 更多 menu (Legado menu_show_login_header / menu_del_login_header / menu_log)

    private func showLoginHeader() {
        let header = LoginManager.shared.getLoginHeader(sourceUrl: source.bookSourceUrl)
        menuAlert = MenuActionAlert(
            title: localized("登录头"),
            detail: header?.isEmpty != false
                ? localized("未設置登录头")
                : header ?? localized("未設置登录头")
        )
    }

    private func deleteLoginHeader() {
        LoginManager.shared.removeLoginHeader(sourceUrl: source.bookSourceUrl)
        menuAlert = MenuActionAlert(
            title: localized("完成"),
            detail: localized("已刪除登录头")
        )
    }

    /// Stop and drain the existing owned operations before any exit write. A
    /// canceled operation keeps its host effect facts; it cannot publish new rows.
    private func cancelOriginalOperations() {
        cancelOriginalV2Work()
        originalUIActive = false
        originalUIOwnerGeneration = UUID()
        cancelOriginalTransientWork()
        originalActionGeneration = UUID()
        originalActionTask?.cancel(); originalActionTask = nil
        formSubmissionGeneration = UUID()
        formSubmissionTask?.cancel(); formSubmissionTask = nil
        loginUIRenderGeneration = UUID()
        loginUIRenderTask?.cancel(); loginUIRenderTask = nil
    }

    private func requestFormClose(system: Bool = false, discardingFailedGeneration: UUID? = nil) {
        if usesOriginalLoginV2 || originalV2ReplacingSource {
            requestOriginalV2Close(system: system)
            return
        }
        if let failedGeneration = discardingFailedGeneration {
            // Explicit abandonment is available only after this exact failed
            // close has drained. It never acknowledges a credential write.
            guard usesOriginalLoginUI, !system, !originalExitSystemDismissed,
                  originalExitGeneration == failedGeneration, !originalExitInProgress,
                  originalExitTask == nil else { return }
        }
        guard usesOriginalLoginUI else {
            if system { cancelOriginalOperations() } else { onDismiss() }
            return
        }
        if system { originalExitSystemDismissed = true }
        guard !originalExitAllowsDismiss else { return }
        guard originalExitTask == nil else { return }
        let runningAction = originalActionTask, runningForm = formSubmissionTask, runningRender = loginUIRenderTask
        cancelOriginalOperations()
        let snapshot = originalFormSource ?? source
        // Deliberately omit current text-control buffers: original onDismiss writes
        // viewModel.loginInfo, whereas OK's getLoginData overlays those controls.
        let workingMap = values
        let revision = originalDismissState.revision
        let requiresSave = originalDismissState.shouldPersist && discardingFailedGeneration == nil
        let validForm = originalFormLoaded
        let generation = UUID()
        originalExitGeneration = generation
        originalExitInProgress = true
        isLoading = true
        let hold = BackgroundTaskHold(name: "OriginalLoginDismiss")
        originalExitTask = Task {
            defer {
                hold.release()
                if originalExitGeneration == generation {
                    originalExitTask = nil
                    originalExitInProgress = false
                    if !originalExitAllowsDismiss && !system && !originalExitSystemDismissed {
                        originalUIActive = true
                        isLoading = false
                    }
                }
            }
            var retainedEffects: [String] = []
            // No new source operation enters while these canceled actors drain.
            await runningAction?.value
            await runningForm?.value
            await runningRender?.value
            do {
                try Task.checkCancellation()
                guard originalExitGeneration == generation else { return }
                if requiresSave {
                    guard validForm, originalPresentedSourceID == snapshot.id,
                          originalPresentedSourceURL?.utf8.elementsEqual(snapshot.bookSourceUrl.utf8) == true else {
                        throw LegadoRuntimeError(code: "STALE_SOURCE", message: "Login form source changed before exit")
                    }
                    let service = await Task.detached { BookSourceFetcher.shared.mainJSService }.value
                    let receipt = try await service.originalPersistLoginInfo(source: snapshot, values: workingMap)
                    retainedEffects = receipt.completedEffects
                    try Task.checkCancellation()
                    guard !receipt.executed, receipt.loginUIEvents.isEmpty,
                          workingMap.isEmpty ? receipt.credentialsCleared && !receipt.credentialsStored
                            : receipt.credentialsStored && !receipt.credentialsCleared else {
                        throw LegadoRuntimeError(code: "STATE_IO", message: "Credential owner did not acknowledge exit")
                    }
                    guard originalExitGeneration == generation else { return }
                    guard originalDismissState.acknowledge(revision: revision) else {
                        throw LegadoRuntimeError(code: "STATE_IO", message: "Login form changed during exit")
                    }
                }
                originalExitAllowsDismiss = true
                isLoading = false
                if !system && !originalExitSystemDismissed { onDismiss() }
            } catch {
                let typed = error as? LegadoRuntimeError
                let code = error is CancellationError ? "CANCELLED" : typed?.code ?? "STATE_IO"
                let effectCount = Set(retainedEffects + (typed?.completedEffects ?? [])).count
                let secondaryCodes = typed?.secondaryFailures?.map(\.code) ?? []
                // Forced OS destruction cannot be prevented or restore unsaved UI.
                // Do not ACK, clear dirty state, log values, or replace old Keychain.
                AppLogger.error("Original login exit failed", context: ["code": code,
                    "reportedEffects": effectCount, "secondaryCodes": secondaryCodes, "system": system])
                if !system, !originalExitSystemDismissed, originalExitGeneration == generation {
                    presentOriginalLoginFailure(code: code, secondary: secondaryCodes, effects: effectCount,
                        discardExitGeneration: generation)
                }
            }
        }
    }

    // MARK: - Original login UI v2

    private func originalV2IsCurrent(_ generation: UUID, source snapshot: BookSource) -> Bool {
        originalUIActive && usesOriginalLoginV2 && originalV2OwnerGeneration == generation
            && originalPresentedSourceID == snapshot.id
            && originalPresentedSourceURL?.utf8.elementsEqual(snapshot.bookSourceUrl.utf8) == true
    }

    private func collectOriginalV2Form() -> [String: String] {
        SourcePerfTrace.span("legado.original.login.v2.collect",
            "main=\(Thread.isMainThread) controls=\(originalV2State.values.count)") {
            originalV2State.collectForm()
        }
    }

    private func cancelOriginalV2Work() {
        originalV2OwnerGeneration = UUID()
        originalV2TaskGeneration = UUID()
        originalV2RenderGeneration = UUID()
        originalV2Task?.cancel(); originalV2Task = nil
        for task in originalV2CountdownTasks.values { task.cancel() }
        originalV2CountdownTasks = [:]; originalV2Countdowns = [:]
        originalV2Rendering = false
    }

    private func resetOriginalV2Source() {
        guard !originalExitAllowsDismiss, !originalExitSystemDismissed else { return }
        // A close may already own the only remaining handles to canceled work.
        // Capture that drain before rotating its publication generation.
        let exit = originalExitTask, action = originalV2Task, render = loginUIRenderTask
        originalExitGeneration = UUID()
        originalExitTask?.cancel(); originalExitTask = nil
        originalExitInProgress = true
        originalExitAllowsDismiss = false; originalExitSystemDismissed = false
        cancelOriginalOperations()
        originalV2ReplacingSource = true
        originalV2State = .init(); originalV2Errors = [:]
        originalV2DisabledButton = nil; originalV2ToggleActionsEnabled = true
        usesOriginalLoginV2 = false; usesOriginalLoginUI = false
        originalFormLoaded = false; originalRows = []; originalLayout = nil
        originalDismissState = .init(); originalFormSource = nil; originalDynamic = false
        fields = []; fieldLabels = [:]; values = [:]; originalControls = [:]
        let generation = UUID()
        loginUIRenderGeneration = generation
        isLoading = true
        // Drain canceled work before admitting this View's replacement source.
        loginUIRenderTask = Task {
            await Self.drainOriginalV2Owner(exit: exit, action: action, render: render)
            guard !Task.isCancelled, loginUIRenderGeneration == generation else { return }
            originalExitInProgress = false
            originalV2ReplacingSource = false
            loginUIRenderTask = nil
            loadUI()
        }
    }

    /// Both source replacement and a native close retain their old owned work
    /// until it has actually drained. A canceled close still owns its child work.
    nonisolated static func drainOriginalV2Owner(exit: Task<Void, Never>?,
        action: Task<Void, Never>?, render: Task<Void, Never>?) async {
        await exit?.value
        await action?.value
        await render?.value
    }

    private func requestOriginalV2Close(system: Bool) {
        if system { originalExitSystemDismissed = true }
        guard !originalExitAllowsDismiss, originalExitTask == nil else { return }
        let action = originalV2Task, render = loginUIRenderTask
        cancelOriginalOperations()
        originalExitInProgress = true; isLoading = true
        let generation = UUID(); originalExitGeneration = generation
        let hold = BackgroundTaskHold(name: "OriginalLoginV2Close")
        originalExitTask = Task {
            defer {
                hold.release()
                if originalExitGeneration == generation {
                    originalExitTask = nil; originalExitInProgress = false
                }
            }
            await Self.drainOriginalV2Owner(exit: nil, action: action, render: render)
            guard originalExitGeneration == generation, !Task.isCancelled else { return }
            // V2 never writes legacy working values on any dismissal path.
            originalExitAllowsDismiss = true; isLoading = false
            if !system && !originalExitSystemDismissed { onDismiss() }
        }
    }

    @discardableResult private func applyOriginalV2Errors(_ errors: [String: String]) throws -> [String] {
        guard let form = originalV2State.form else { return [] }
        let checked = try form.checkedErrors(errors)
        originalV2Errors = checked.fields
        if !checked.messages.isEmpty {
            // Authored field messages are user-visible source content, never logs.
            menuAlert = .init(title: localized("操作失敗"), detail: checked.messages.joined(separator: "\n"))
        }
        return checked.messages
    }

    private func renderOriginalV2(source snapshot: BookSource, candidateState: String,
        errors: [String: String] = [:], owner: UUID) async throws {
        let token = UUID(); originalV2RenderGeneration = token
        originalV2Rendering = true
        _ = collectOriginalV2Form()
        defer {
            if originalV2RenderGeneration == token { originalV2Rendering = false }
        }
        var effects: [String] = []
        do {
            let service = await Task.detached { BookSourceFetcher.shared.mainJSService }.value
            let receipt = try await service.originalLoginV2UI(source: snapshot, stateJSON: candidateState)
            effects = receipt.completedEffects
            try Task.checkCancellation()
            guard originalV2IsCurrent(owner, source: snapshot), originalV2RenderGeneration == token else {
                throw CancellationError()
            }
            let renderID = UUID()
            // The original collects again after the response. Project off main
            // from the latest controls; if the user edits during projection,
            // rebase that pure projection without executing the source again.
            while true {
                let inputToken = originalV2InputGeneration, latest = originalV2State
                let projected = try await Task.detached {
                    try latest.rendered(receipt.render, candidateState: candidateState, renderID: renderID)
                }.value
                try Task.checkCancellation()
                guard originalV2IsCurrent(owner, source: snapshot), originalV2RenderGeneration == token else {
                    throw CancellationError()
                }
                if originalV2InputGeneration != inputToken { continue }
                // Validate authored errors before replacing any previous form.
                _ = try projected.form?.checkedErrors(errors)
                originalV2State = projected
                break
            }
            originalV2Errors = [:]
            originalV2DisabledButton = nil; originalV2ToggleActionsEnabled = true
            isLoading = false
            try applyOriginalV2Errors(errors)
        } catch {
            let typed = error as? LegadoRuntimeError
            let code = typed?.code ?? (error is CancellationError ? "CANCELLED" : "STATE_IO")
            let reported = Array(Set(effects + (typed?.completedEffects ?? []))).sorted()
            AppLogger.error("Original login v2 render failed", context: ["code": code, "reportedEffects": reported.count])
            throw LegadoRuntimeError(code: code, message: "Original login v2 render did not complete",
                completedEffects: reported, secondaryFailures: typed?.secondaryFailures)
        }
    }

    private func runOriginalV2Action(_ row: LegadoOriginalLoginV2Form.Row) {
        guard usesOriginalLoginV2, originalUIActive, originalV2Task == nil,
              loginUIRenderTask == nil, !originalV2Rendering,
              originalV2State.form?.rowIDs.contains(row.id) == true,
              let action = row.definition.action, let actionID = row.actionID,
              (originalV2Countdowns[actionID] ?? 0) <= 0 else { return }
        originalV2Errors = [:]
        let form = collectOriginalV2Form(), stateJSON = originalV2State.stateJSON, snapshot = source
        let owner = originalV2OwnerGeneration, generation = UUID()
        originalV2TaskGeneration = generation
        originalV2DisabledButton = actionID; originalV2ToggleActionsEnabled = false
        originalV2Task = Task {
            defer {
                if originalV2TaskGeneration == generation { originalV2Task = nil }
            }
            var effects: [String] = []
            var sourceErrors: [String: String]?
            do {
                let service = await Task.detached { BookSourceFetcher.shared.mainJSService }.value
                let receipt = try await service.originalLoginV2Action(source: snapshot, action: action,
                    stateJSON: stateJSON, form: form)
                effects = receipt.completedEffects
                try Task.checkCancellation()
                guard originalV2IsCurrent(owner, source: snapshot), originalV2TaskGeneration == generation else {
                    throw CancellationError()
                }
                let command = receipt.command
                if command.close {
                    // The service has already validated the whole command and
                    // acknowledged any explicit login object with its owner.
                    // Do not await this action task from its own close path.
                    originalV2Task = nil
                    cancelOriginalOperations()
                    originalExitAllowsDismiss = true; isLoading = false
                    onDismiss()
                    return
                }
                let errors = command.errors ?? [:]
                sourceErrors = errors
                if row.definition.type == "button", errors.isEmpty, let seconds = row.definition.countdown, seconds > 0 {
                    startOriginalV2Countdown(actionID: actionID, seconds: seconds, owner: owner)
                }
                if let candidate = command.stateJSON {
                    try await renderOriginalV2(source: snapshot, candidateState: candidate, errors: errors, owner: owner)
                } else {
                    originalV2DisabledButton = nil; originalV2ToggleActionsEnabled = true
                    try applyOriginalV2Errors(errors)
                }
            } catch {
                let typed = error as? LegadoRuntimeError
                let code = typed?.code ?? (error is CancellationError ? "CANCELLED" : "STATE_IO")
                let count = Set(effects + (typed?.completedEffects ?? [])).count
                AppLogger.error("Original login v2 action failed", context: ["code": code, "reportedEffects": count])
                guard originalV2IsCurrent(owner, source: snapshot), originalV2TaskGeneration == generation else { return }
                originalV2DisabledButton = nil; originalV2ToggleActionsEnabled = true
                // A failed candidate render retains the prior state, controls
                // and session. Preserve its primary error and apply source errors
                // to those retained controls; any countdown keeps running.
                var secondary = typed?.secondaryFailures?.map(\.code) ?? []
                var messages: [String] = []
                if let sourceErrors {
                    do { messages = try applyOriginalV2Errors(sourceErrors) }
                    catch { secondary.append((error as? LegadoRuntimeError)?.code ?? "STATE_IO") }
                }
                presentOriginalLoginFailure(code: code, secondary: secondary, effects: count)
                if !messages.isEmpty, let failure = menuAlert {
                    menuAlert = .init(title: failure.title, detail: failure.detail + "\n" + messages.joined(separator: "\n"))
                }
            }
        }
    }

    private func startOriginalV2Countdown(actionID: String, seconds: Int, owner: UUID) {
        originalV2CountdownTasks[actionID]?.cancel()
        originalV2Countdowns[actionID] = seconds
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        originalV2CountdownTasks[actionID] = Task {
            do {
                while true {
                    // This is the source-requested one-second countdown, not a
                    // delay used to settle UI or retry source execution.
                    try await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, originalUIActive, originalV2OwnerGeneration == owner else { return }
                    let left = LegadoOriginalLoginV2State.countdownRemaining(until: deadline, now: clock.now)
                    if left == 0 { break }
                    originalV2Countdowns[actionID] = left
                }
                guard originalV2OwnerGeneration == owner else { return }
                originalV2Countdowns.removeValue(forKey: actionID)
                originalV2CountdownTasks.removeValue(forKey: actionID)
            } catch is CancellationError { }
            catch { AppLogger.error("Original login v2 countdown failed") }
        }
    }

    // MARK: - Setup

    private func loadUI() {
        guard !originalExitInProgress && !originalExitAllowsDismiss else { return }
        originalPresentedSourceID = source.id
        originalPresentedSourceURL = source.bookSourceUrl
        cancelOriginalTransientWork()
        originalUIActive = true
        formSubmissionGeneration = UUID()
        formSubmissionTask?.cancel(); formSubmissionTask = nil
        originalActionGeneration = UUID()
        originalActionTask?.cancel(); originalActionTask = nil
        loginUIRenderTask?.cancel()
        let generation = UUID()
        loginUIRenderGeneration = generation
        isLoading = true
        canRetryLoginUi = false
        originalV2TaskGeneration = UUID()
        originalV2Task?.cancel(); originalV2Task = nil
        let snapshot = source
        let valueSnapshot = values
        let controlsSnapshot = originalControls
        let rowsSnapshot = originalRows, layoutSnapshot = originalLayout
        let useExistingValues = originalFormLoaded, dynamic = originalDynamic
        if useExistingValues { originalDismissState.requestedRender(dynamic: originalDynamic) }
        loginUIRenderTask = Task {
            defer {
                if loginUIRenderGeneration == generation {
                    loginUIRenderTask = nil
                    startOriginalActionDrain()
                }
            }
            let original = await Task.detached {
                snapshot.bookSourceType == 0 && !snapshot.isJsSource
            }.value
            guard !Task.isCancelled, loginUIRenderGeneration == generation else { return }
            guard original else {
                usesOriginalLoginUI = false
                usesOriginalLoginV2 = false
                loadLegacyUI()
                return
            }
            usesOriginalLoginUI = true
            do {
                if usesOriginalLoginV2 {
                    try await renderOriginalV2(source: snapshot, candidateState: originalV2State.stateJSON,
                        owner: originalV2OwnerGeneration)
                    return
                }
                let evaluation: [String: String]? = try await Task.detached {
                    useExistingValues && dynamic
                        ? try Self.originalFormSubmissionValues(rows: rowsSnapshot, layout: layoutSnapshot,
                            values: valueSnapshot, controls: controlsSnapshot)
                        : nil
                }.value
                let service = await Task.detached { BookSourceFetcher.shared.mainJSService }.value
                let rendered = try await service.originalLoginUI(source: snapshot,
                    values: useExistingValues ? valueSnapshot : nil, evaluationValues: evaluation)
                guard !Task.isCancelled, loginUIRenderGeneration == generation else { return }
                // Locked resolveLoginUiRender applies only successful new rows.
                // On failure the previous fields, labels and edits remain intact.
                fields = rendered.fields
                fieldLabels = rendered.labels
                values = rendered.values
                originalRows = rendered.rows
                originalLayout = rendered.layout
                originalControls = rendered.controls
                originalControlGeneration = UUID()
                originalFormLoaded = true
                originalFormSource = snapshot
                originalDynamic = rendered.dynamic
                originalDismissState.rendered(workingMapChanged: rendered.workingMapChanged)
                isLoading = false
            } catch {
                guard !Task.isCancelled, loginUIRenderGeneration == generation else { return }
                var failure = error
                // Classification belongs to the locked BaseSource/GSON code.
                // Only this explicit admission signal selects the V2 protocol;
                // a script, state or IO failure never selects another engine.
                if (error as? LegadoRuntimeError)?.code == "LOGIN_UI_V2" {
                    usesOriginalLoginV2 = true
                    do {
                        try await renderOriginalV2(source: snapshot, candidateState: originalV2State.stateJSON,
                            owner: originalV2OwnerGeneration)
                        return
                    } catch { failure = error }
                }
                guard !Task.isCancelled, loginUIRenderGeneration == generation else { return }
                isLoading = false
                canRetryLoginUi = true
                let typed = failure as? LegadoRuntimeError
                let code = typed?.code ?? "STATE_IO"
                AppLogger.error("Original login UI failed", context: ["code": code,
                    "reportedEffects": typed?.completedEffects?.count ?? 0])
                menuAlert = MenuActionAlert(title: localized("操作失敗"),
                    detail: localized("操作失敗") + " (\(code))")
            }
        }
    }

    private func loadLegacyUI() {
        isLoading = true
        canRetryLoginUi = false
        let rawUi = source.loginUi.trimmingCharacters(in: .whitespacesAndNewlines)
        // Some sources (e.g. 起点) define `loginUi` as JS (`@js:` / `<js>…</js>`) that
        // builds the form by calling a jsLib helper like `Menu()`. Evaluate it first,
        // then parse the JSON it returns. Plain JSON-array loginUi takes the fast path.
        if rawUi.hasPrefix("@js:") || rawUi.hasPrefix("<js>") {
            let src = source
            Task.detached(priority: .userInitiated) {
                let evaluation = await SourceScriptThread.run { Self.evaluateJsLoginUiResult(source: src) }
                let parsed = LoginManager.shared.parseLoginUiResult(evaluation.json)
                let stored = LoginManager.shared.getLoginInfo(sourceUrl: src.bookSourceUrl)
                await MainActor.run {
                    self.fields = parsed ?? []
                    self.fieldLabels = evaluation.labels
                    self.values = Self.initialValues(for: parsed ?? [], stored: stored)
                    self.isLoading = false
                    guard parsed == nil else { return }
                    self.canRetryLoginUi = true
                    self.menuAlert = MenuActionAlert(
                        title: localized("來源配置腳本錯誤"),
                        detail: evaluation.error ?? localized("載入失敗，點按重試")
                    )
                }
            }
            return
        }

        fields = LoginManager.shared.parseLoginUi(source.loginUi)
        fieldLabels = fields.literalViewNames
        values = Self.initialValues(
            for: fields,
            stored: LoginManager.shared.getLoginInfo(sourceUrl: source.bookSourceUrl)
        )
        isLoading = false
        refreshDynamicLabels(for: fields)
    }

    /// Resolve dynamic `viewName` expressions off the main thread. Fields show their
    /// `name` until the JS answers, mirroring Legado's async `evalUiJs(viewName)`.
    private func refreshDynamicLabels(for fields: [LoginField]) {
        guard fields.hasDynamicViewNames else { return }
        let src = source
        let credentials = currentFormValues()
        Task.detached(priority: .utility) {
            let labels = await SourceScriptThread.run {
                Self.resolveDynamicLoginLabels(fields: fields, source: src, credentials: credentials)
            }
            guard !labels.isEmpty else { return }
            await MainActor.run { self.fieldLabels.merge(labels) { _, new in new } }
        }
    }

    struct LoginUIEvaluationResult: Sendable {
        let json: String
        let error: String?
        /// Resolved `viewName` labels keyed by field name, when the menu carries any.
        var labels: [String: String] = [:]
    }

    /// Evaluate a JS-based `loginUi` (with jsLib + source runtime wired) and return
    /// the JSON form definition produced by its completion value or result assignment.
    nonisolated static func evaluateJsLoginUi(source: BookSource) -> String {
        evaluateJsLoginUiResult(source: source).json
    }

    /// Legado, Sigma, and the MD3 implementation evaluate loginUrl JS before loginUi JS
    /// in the same engine. Dynamic menus commonly call helpers declared by loginUrl, so
    /// evaluating loginUi in isolation produces a blank form after the JS error is swallowed.
    nonisolated static func evaluateJsLoginUiResult(
        source: BookSource
    ) -> LoginUIEvaluationResult {
        let engine = makeLoginEngine(source: source)

        let raw = source.loginUi.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawLogin = source.loginUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let loginJS = LoginManager.shared.extractLoginJs(rawLogin) ?? ""
        let jsBody = LoginManager.shared.extractLoginJs(raw) ?? raw
        let storedLoginInfo = LoginManager.shared.getLoginInfo(sourceUrl: source.bookSourceUrl) ?? [:]
        // Run loginUrl and loginUi in one JS context, mirroring Legado's evalUiJs.
        // `book` and `chapter` are null for a standalone login sheet, as in Legado.
        // Do not append `result` here. Legado returns the loginUi script's completion
        // value; 神魔小說 ends with `JSON.stringify(rows)` while `result` still contains
        // previously stored credentials. Returning `result` would replace the menu JSON
        // with that credentials object and make the form parser report a load failure.
        let wrapped = """
        \(loginJS)
        \(jsBody)
        """
        let out = engine.evaluate(
            wrapped,
            result: storedLoginInfo,
            bindings: sourceLoginBindings(source)
        ) ?? ""
        let error = engine.lastError

        // Dynamic viewNames are evaluated in the same engine — loginUrl and the menu JS
        // have already run here, so expressions can call their helpers with the menu's
        // own state still in scope. Legado does this per row through `evalUiJs`.
        let parsed = LoginManager.shared.parseLoginUiResult(out)
        var labels = parsed?.literalViewNames ?? [:]
        if let parsed {
            labels.merge(
                evaluateDynamicLabels(
                    parsed.filter(\.hasDynamicViewName),
                    engine: engine,
                    credentials: storedLoginInfo,
                    source: source
                )
            ) { _, new in new }
        }

        AppLogger.parse("⟐ menuEval", context: [
            "resultLen": out.count,
            "head": String(out.prefix(120)),
            "hasLoginJs": !loginJS.isEmpty,
            "jsError": error ?? "none",
        ])
        return LoginUIEvaluationResult(json: out, error: error, labels: labels)
    }

    /// The one login engine: a `JSCoreEngine` wired to the source's runtime (jsLib,
    /// java.* handlers, localStorage-equivalent store) with toasts presented as alerts.
    nonisolated static func makeLoginEngine(source: BookSource, loginOwner: LoginManager = .shared) -> JSCoreEngine {
        let engine = JSCoreEngine()
        engine.bookSource = source
        configureLegadoRuntime(engine, source: source, loginOwner: loginOwner)
        engine.toastHandler = { msg in
            Task { @MainActor in BookSourceFormLoginView.presentToastAlert(message: msg) }
        }
        return engine
    }

    nonisolated static func sourceLoginBindings(_ source: BookSource) -> [String: Any] {
        [
            "baseUrl": source.bookSourceUrl,
            "book": NSNull(),
            "chapter": NSNull(),
        ]
    }

    /// Evaluate `viewName` expressions for a static (non-`@js:`) `loginUi` by loading
    /// the source's loginUrl JS into a fresh engine, matching Legado's `evalUiJs`.
    nonisolated static func resolveDynamicLoginLabels(
        fields: [LoginField],
        source: BookSource,
        credentials: [String: String]
    ) -> [String: String] {
        let dynamicFields = fields.filter(\.hasDynamicViewName)
        guard !dynamicFields.isEmpty else { return [:] }
        let engine = makeLoginEngine(source: source)
        let rawLogin = source.loginUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if let loginJS = LoginManager.shared.extractLoginJs(rawLogin),
           !loginJS.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = engine.evaluate(
                loginJS, result: credentials, bindings: sourceLoginBindings(source)
            )
        }
        return evaluateDynamicLabels(
            dynamicFields, engine: engine, credentials: credentials, source: source
        )
    }

    /// A failed or empty `viewName` result falls back to the field name. (Legado prints
    /// literal "err"/"null" there; those are neither localizable nor actionable, and the
    /// JS error is already visible through `AppLogger` and the source log.)
    nonisolated static func evaluateDynamicLabels(
        _ fields: [LoginField],
        engine: JSCoreEngine,
        credentials: [String: String],
        source: BookSource
    ) -> [String: String] {
        var labels: [String: String] = [:]
        for field in fields {
            guard let expression = field.viewName, !expression.isEmpty else { continue }
            let value = engine.evaluate(
                expression, result: credentials, bindings: sourceLoginBindings(source)
            )
            if let value, !value.isEmpty, value != "undefined", value != "null" {
                labels[field.name] = value
            } else {
                labels[field.name] = field.name
            }
        }
        return labels
    }

    private func selectedValue(for field: LoginField) -> String {
        if let value = values[field.name], !value.isEmpty {
            return value
        }
        if let defaultValue = field.defaultValue, !defaultValue.isEmpty {
            return defaultValue
        }
        return field.options.first ?? ""
    }

    private static func initialValues(
        for fields: [LoginField],
        stored: [String: String]?
    ) -> [String: String] {
        var result = stored ?? [:]
        // `.select` only: a `.toggle`'s declared default must stay out of the stored
        // values (see `LoginToggleChars.isOn`) — seeding it flips 段评开关 off.
        for field in fields where field.type == .select {
            if let current = result[field.name], !current.isEmpty {
                continue
            }
            if let defaultValue = field.defaultValue, !defaultValue.isEmpty {
                result[field.name] = defaultValue
            } else if let first = field.options.first {
                result[field.name] = first
            }
        }
        return result
    }

    static func supportsFanqieLogin(source: BookSource) -> Bool {
        [
            source.loginUi,
            source.loginUrl,
            source.jsLib,
            source.ruleToc.chapterUrl,
            source.ruleContent.content,
        ].contains { $0.contains("fanqienovel.com") || $0.contains("getFqToken") }
    }

    /// Returns text-like fields that must be filled before running loginUrl.
    /// Selects with declared options already have a usable selection; toggles
    /// and action buttons are not credentials and therefore are optional.
    static func missingRequiredFieldNames(
        fields: [LoginField],
        values: [String: String]
    ) -> [String] {
        fields.compactMap { field in
            let requiresValue: Bool
            switch field.type {
            case .text, .password:
                requiresValue = true
            case .select:
                requiresValue = field.options.isEmpty
            case .toggle, .button:
                requiresValue = false
            }
            guard requiresValue,
                  Self.resolvedValue(for: field, values: values)
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            else { return nil }
            return field.name
        }
    }

    /// What the form is effectively holding for a field: the user's edit, else the
    /// source-declared default the grid displays. Toggles stay out of this — their
    /// default is display-only so a save never flips them (see `initialValues`).
    static func resolvedValue(for field: LoginField, values: [String: String]) -> String {
        if let current = values[field.name], !current.isEmpty {
            return current
        }
        switch field.type {
        case .text, .password, .select:
            return field.defaultValue ?? ""
        case .toggle, .button:
            return ""
        }
    }

    // MARK: - Login Action

    private func doLogin() {
        guard !isLoading, !originalExitInProgress, !usesOriginalLoginUI || originalFormLoaded else { return }
        // Locked menu_ok sets this before launching async login; it remains sticky
        // on script failure/cancellation so exit cannot overwrite authored writes.
        if usesOriginalLoginUI { originalDismissState.acceptedOK() }
        menuAlert = nil
        canRetryLoginUi = false

        submitForm()
    }

    /// Locked dialog getLoginData: preserve complete loginInfo, then overwrite
    /// only visible text/password edits. An explicit empty edit stays empty.
    nonisolated static func originalFormSubmissionValues(
        fields: [LoginField], values: [String: String],
        controls: [String: LegadoOriginalLoginUIControl]? = nil
    ) -> [String: String] {
        LegadoOriginalLoginUIForm.submissionValues(fields: fields, values: values, controls: controls)
    }

    /// Actual original getLoginData uses raw rows and assigned physical ids.
    /// The simple field-only overload remains for older synthetic/native fixtures.
    nonisolated static func originalFormSubmissionValues(
        rows: [LegadoOriginalLoginUIRow], layout: LegadoOriginalLoginUILayout?,
        values: [String: String], controls: [String: LegadoOriginalLoginUIControl]
    ) throws -> [String: String] {
        guard let layout else {
            throw LegadoRuntimeError(code: "UI_BINDING_ERROR", message: "Original physical login layout is missing")
        }
        return try LegadoOriginalLoginUIForm.submissionValues(rows: rows, layout: layout,
            values: values, controls: controls)
    }

    private func submitForm() {
        let generation = UUID()
        formSubmissionGeneration = generation
        isLoading = true
        let snapshot = source
        let valueSnapshot = values
        let controlSnapshot = originalControls
        let rowsSnapshot = originalRows, layoutSnapshot = originalLayout
        let ownerGeneration = originalUIOwnerGeneration
        let listenerChain = OriginalListenerChain()
        let hadValidOriginalForm = originalFormLoaded
        formSubmissionTask = Task {
            defer {
                if formSubmissionGeneration == generation {
                    formSubmissionTask = nil
                    startOriginalActionDrain()
                }
            }
            // Source classification and complete form synthesis run off MainActor.
            let original = await Task.detached {
                snapshot.bookSourceType == 0 && !snapshot.isJsSource
            }.value
            guard !Task.isCancelled, formSubmissionGeneration == generation else {
                if formSubmissionGeneration == generation { isLoading = false }
                return
            }
            // Original toolbar requires a successfully parsed rowUis, including
            // valid []. A failed initial render must never become removeLoginInfo.
            guard !original || hadValidOriginalForm else { isLoading = false; return }
            guard original else {
                isLoading = false
                // Existing mainJs/media validation and login remain on their route.
                let credentials = currentFormValues()
                let missingFields = Self.missingRequiredFieldNames(fields: fields, values: credentials)
                guard missingFields.isEmpty else {
                    menuAlert = MenuActionAlert(
                        title: localized("操作失敗"),
                        detail: localized("請填入登入資訊")
                    )
                    return
                }

                if !credentials.isEmpty {
                    LoginManager.shared.storeLoginInfo(sourceUrl: snapshot.bookSourceUrl, info: credentials)
                }
                runLoginJS(credentials: credentials)
                return
            }
            do {
                let submittedCredentials = try await Task.detached {
                    try Self.originalFormSubmissionValues(rows: rowsSnapshot, layout: layoutSnapshot,
                        values: valueSnapshot, controls: controlSnapshot)
                }.value
                guard !Task.isCancelled, formSubmissionGeneration == generation else { return }
                let service = await Task.detached { BookSourceFetcher.shared.mainJSService }.value
                let receipt = try await service.originalFormLogin(source: snapshot, credentials: submittedCredentials)
                let consumptionFailures = await consumeOriginalLoginEvents(receipt.loginUIEvents,
                    ownerGeneration: ownerGeneration, chain: listenerChain)
                guard !Task.isCancelled, formSubmissionGeneration == generation else { return }
                isLoading = false
                if consumptionFailures.isEmpty {
                    menuAlert = MenuActionAlert(title: localized("完成"), detail: localized("完成"), dismissesView: true)
                } else {
                    presentOriginalLoginFailure(code: "UI_CALLBACK_ERROR", secondary: consumptionFailures)
                }
            } catch {
                let failure = error as? LegadoRuntimeError
                let consumptionFailures = await consumeOriginalLoginEvents(failure?.loginUIEvents ?? [],
                    ownerGeneration: ownerGeneration, chain: listenerChain)
                guard !Task.isCancelled, formSubmissionGeneration == generation else { return }
                isLoading = false
                presentOriginalLoginFailure(code: failure?.code ?? "STATE_IO",
                    secondary: (failure?.secondaryFailures?.map(\.code) ?? []) + consumptionFailures,
                    effects: failure?.completedEffects?.count ?? 0)
            }
        }
    }

    private func handleButton(field: LoginField) {
        if usesOriginalLoginUI {
            runOriginalAction(field: field, isLongClick: false)
            return
        }
        AppLogger.parse("⟐ menuButton", context: ["name": field.name, "action": field.action ?? "nil"])
        guard let action = field.action, !action.isEmpty else { return }
        // If it's a URL, open in browser; if JS, run it
        if action.hasPrefix("http://") || action.hasPrefix("https://") {
            if let url = URL(string: action) {
                UIApplication.shared.open(url)
            }
        } else {
            // JS button action
            let currentCredentials = currentFormValues()
            if !currentCredentials.isEmpty {
                LoginManager.shared.storeLoginInfo(
                    sourceUrl: source.bookSourceUrl,
                    info: currentCredentials
                )
            }
            runButtonJS(action: action, credentials: currentCredentials)
        }
    }

    /// Source actions borrow the current controls/Map and never pre-store them.
    private func runOriginalAction(field: LoginField, isLongClick: Bool) {
        guard originalUIActive, usesOriginalLoginUI, originalFormLoaded else { return }
        enqueueOriginalAction(field: field, isLongClick: isLongClick)
    }

    @discardableResult
    private func enqueueOriginalAction(field: LoginField, isLongClick: Bool = false,
        credentials: [String: String]? = nil, inputBindingFailed: Bool = false, automatic: Bool = false,
        chain: OriginalListenerChain? = nil) -> LegadoRuntimeError? {
        guard originalUIActive, usesOriginalLoginUI, originalFormLoaded, let action = field.action else { return nil }
        let context = chain ?? OriginalListenerChain()
        // Only automatic descendants share the finite budget. Every actual user
        // interaction starts a new chain; callbacks/debounce retain its identity.
        do {
            if automatic { try context.budget.acceptAutomatic() }
        } catch let failure as LegadoRuntimeError {
            return failure
        } catch {
            return LegadoRuntimeError(code: "STATE_IO", message: "Original login listener budget failed")
        }
        originalActionQueue.append(.init(action: action, isLongClick: isLongClick,
            rows: originalRows, layout: originalLayout,
            values: values, controls: originalControls, credentials: credentials,
            inputBindingFailed: inputBindingFailed, chain: context))
        startOriginalActionDrain()
        return nil
    }

    private func startOriginalActionDrain() {
        guard originalUIActive, originalActionTask == nil, formSubmissionTask == nil, loginUIRenderTask == nil,
              originalActionQueueHead < originalActionQueue.count else { return }
        let generation = UUID(), ownerGeneration = originalUIOwnerGeneration, snapshot = source
        originalActionGeneration = generation
        isLoading = true
        originalActionTask = Task {
            defer {
                if originalActionGeneration == generation {
                    originalActionTask = nil; isLoading = false
                    originalActionQueue = []; originalActionQueueHead = 0
                }
            }
            while !Task.isCancelled, originalUIOwnerGeneration == ownerGeneration,
                  originalActionGeneration == generation, originalActionQueueHead < originalActionQueue.count {
                let request = originalActionQueue[originalActionQueueHead]
                originalActionQueueHead += 1
                // Preserve the existing external-link route; browser/WebJS remains separate.
                if request.action.hasPrefix("http://") || request.action.hasPrefix("https://") {
                    if let url = URL(string: request.action) { UIApplication.shared.open(url, options: [:], completionHandler: nil) }
                    continue
                }
                do {
                    let input = try await Task.detached { () throws -> ([String: String], Bool) in
                        if request.inputBindingFailed { return ([:], true) }
                        if let credentials = request.credentials { return (credentials, false) }
                        do {
                            return (try Self.originalFormSubmissionValues(rows: request.rows, layout: request.layout,
                                values: request.values, controls: request.controls), false)
                        } catch let failure as LegadoRuntimeError where failure.code == "UI_BINDING_ERROR" {
                            // The original getLoginJs null check precedes getLoginData.
                            // Pass an explicit unavailable-input fact; the same JVM
                            // decides skip or rejects before any authored evaluation.
                            return ([:], true)
                        }
                    }.value
                    guard !Task.isCancelled, originalUIOwnerGeneration == ownerGeneration else { return }
                    let service = await Task.detached { BookSourceFetcher.shared.mainJSService }.value
                    let receipt = try await service.originalLoginAction(source: snapshot, action: request.action,
                        credentials: input.0, isLongClick: request.isLongClick, inputBindingFailed: input.1)
                    let consumptionFailures = await consumeOriginalLoginEvents(receipt.loginUIEvents ?? [],
                        ownerGeneration: ownerGeneration, chain: request.chain)
                    guard !Task.isCancelled, originalUIOwnerGeneration == ownerGeneration else { return }
                    if !consumptionFailures.isEmpty {
                        presentOriginalLoginFailure(code: "UI_CALLBACK_ERROR", secondary: consumptionFailures)
                    }
                } catch {
                    let typed = error as? LegadoRuntimeError
                    let consumptionFailures = await consumeOriginalLoginEvents(typed?.loginUIEvents ?? [],
                        ownerGeneration: ownerGeneration, chain: request.chain)
                    guard !Task.isCancelled, originalUIOwnerGeneration == ownerGeneration else { return }
                    presentOriginalLoginFailure(code: typed?.code ?? "STATE_IO",
                        secondary: (typed?.secondaryFailures?.map(\.code) ?? []) + consumptionFailures,
                        effects: typed?.completedEffects?.count ?? 0)
                }
            }
        }
    }

    private func scheduleOriginalTextAction(field: LoginField, chain: OriginalListenerChain? = nil) {
        guard originalUIActive, field.action != nil, usesOriginalLoginUI, originalFormLoaded else { return }
        let key = originalControlGeneration.uuidString + ":" + field.id
        originalTextTasks[key]?.cancel()
        let token = UUID(), ownerGeneration = originalUIOwnerGeneration
        let listenerChain = chain ?? OriginalListenerChain()
        originalTextTaskTokens[key] = token
        originalTextTasks[key] = Task {
            defer {
                if originalTextTaskTokens[key] == token {
                    originalTextTasks[key] = nil; originalTextTaskTokens[key] = nil
                }
            }
            do {
                // Locked TextWatcher waits600ms since the last actual value change.
                try await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, originalUIOwnerGeneration == ownerGeneration,
                      originalTextTaskTokens[key] == token else { return }
                if let failure = enqueueOriginalAction(field: field, automatic: true, chain: listenerChain) {
                    presentOriginalLoginFailure(code: failure.code)
                }
            } catch is CancellationError { }
            catch { AppLogger.error("Original login debounce failed") }
        }
    }

    private func cancelOriginalTransientWork() {
        originalUIOwnerGeneration = UUID()
        for task in originalTextTasks.values { task.cancel() }
        originalTextTasks = [:]; originalTextTaskTokens = [:]
        originalActionQueue = []; originalActionQueueHead = 0
    }

    /// Events arrive only after the service has released its source gate. A
    /// listener adds work to the drain instead of awaiting its own running task.
    private func consumeOriginalLoginEvents(_ events: [LegadoOriginalLoginUIEvent],
        ownerGeneration: UUID, chain: OriginalListenerChain) async -> [String] {
        var failures: [String] = []
        for event in events {
            guard !Task.isCancelled, originalUIOwnerGeneration == ownerGeneration else { return failures }
            switch event.kind {
            case .updateData:
                originalDismissState.markChanged()
                let rows = originalRows, currentFields = fields, labels = fieldLabels,
                    map = values, controls = originalControls, layout = originalLayout
                do {
                    let update = try await Task.detached {
                        try SourcePerfTrace.span("legado.original.login.ui.update",
                            "main=\(Thread.isMainThread) rows=\(rows.count) entries=\(event.entries?.count ?? 0)") {
                            try LegadoOriginalLoginUIForm.applying(entries: event.entries, rows: rows,
                                fields: currentFields, labels: labels, values: map, controls: controls, layout: layout)
                        }
                    }.value
                    guard !Task.isCancelled, originalUIOwnerGeneration == ownerGeneration else { return failures }
                    values = update.values; originalControls = update.controls; fieldLabels = update.labels
                    for field in update.changedTextRows { scheduleOriginalTextAction(field: field, chain: chain) }
                    for action in update.actions {
                        if let failure = action.bindingFailure, failure.code != "UI_BINDING_ERROR" {
                            failures.append(failure.code); continue
                        }
                        if let failure = enqueueOriginalAction(field: action.field, credentials: action.credentials,
                            inputBindingFailed: action.bindingFailure != nil, automatic: true, chain: chain) {
                            failures.append(failure.code)
                        }
                    }
                } catch {
                    guard !Task.isCancelled, originalUIOwnerGeneration == ownerGeneration else { return failures }
                    failures.append((error as? LegadoRuntimeError)?.code ?? "STATE_IO")
                }
            case .render:
                originalDismissState.requestedRender(dynamic: originalDynamic)
                let snapshot = source, map = values, controls = originalControls
                let rows = originalRows, layout = originalLayout, labels = fieldLabels, dynamic = originalDynamic
                do {
                    let (evaluation, reuse) = try await Task.detached {
                        let evaluation = dynamic ? try Self.originalFormSubmissionValues(rows: rows, layout: layout,
                            values: map, controls: controls) : nil
                        let reuse: LegadoOriginalLoginUIReuseState?
                        if event.deltaUp == true {
                            guard let layout else {
                                throw LegadoRuntimeError(code: "UI_BINDING_ERROR", message: "Original reuse layout is missing")
                            }
                            reuse = try LegadoOriginalLoginUIForm.reuseState(layout: layout, labels: labels, controls: controls)
                        } else { reuse = nil }
                        return (evaluation, reuse)
                    }.value
                    guard !Task.isCancelled, originalUIOwnerGeneration == ownerGeneration else { return failures }
                    let service = await Task.detached { BookSourceFetcher.shared.mainJSService }.value
                    let rendered = try await service.originalLoginUI(source: snapshot, values: map,
                        evaluationValues: evaluation, reuseState: reuse)
                    guard !Task.isCancelled, originalUIOwnerGeneration == ownerGeneration else { return failures }
                    fields = rendered.fields; fieldLabels = rendered.labels; values = rendered.values
                    originalRows = rendered.rows; originalLayout = rendered.layout; originalControls = rendered.controls
                    // Reused physical ids keep the same watcher/debounce identity.
                    // Removed controls retain pending callbacks until actual dismissal.
                    if event.deltaUp != true { originalControlGeneration = UUID() }
                    originalFormLoaded = true
                    originalFormSource = snapshot; originalDynamic = rendered.dynamic
                    originalDismissState.rendered(workingMapChanged: rendered.workingMapChanged)
                } catch {
                    guard !Task.isCancelled, originalUIOwnerGeneration == ownerGeneration else { return failures }
                    let typed = error as? LegadoRuntimeError
                    failures.append(typed?.code ?? "STATE_IO")
                    failures.append(contentsOf: typed?.secondaryFailures?.map(\.code) ?? [])
                }
            }
        }
        return failures
    }

    private func presentOriginalLoginFailure(code: String, secondary: [String] = [], effects: Int = 0,
        discardExitGeneration: UUID? = nil) {
        AppLogger.error("Original login operation failed", context: ["code": code,
            "secondaryCodes": secondary, "reportedEffects": effects])
        menuAlert = MenuActionAlert(title: localized("操作失敗"),
            detail: localized("操作失敗") + " (" + ([code] + secondary).joined(separator: ", ") + ")",
            discardExitGeneration: discardExitGeneration)
    }

    private func currentFormValues() -> [String: String] {
        fields
            .filter { $0.type != .button }
            .reduce(into: [String: String]()) { dict, field in
                switch field.type {
                case .select:
                    dict[field.name] = selectedValue(for: field)
                case .text, .password:
                    // The grid displays the declared default until the user edits the
                    // field, so that displayed value is what login must send.
                    dict[field.name] = Self.resolvedValue(for: field, values: values)
                case .toggle:
                    // A toggle reports only what the user actually flipped — resolving
                    // its default here would write it back on the next save.
                    dict[field.name] = values[field.name] ?? ""
                case .button:
                    break
                }
            }
    }

    private func persistCurrentFormValues() {
        let current = currentFormValues()
        guard !current.isEmpty else { return }
        LoginManager.shared.storeLoginInfo(sourceUrl: source.bookSourceUrl, info: current)
    }

    // MARK: - JS Execution

    private func runLoginJS(credentials: [String: String]) {
        let rawLogin = source.loginUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawLogin.isEmpty else {
            menuAlert = MenuActionAlert(
                title: localized("操作失敗"), detail: localized("來源配置未設定 loginUrl"))
            return
        }

        isLoading = true
        Task.detached(priority: .userInitiated) {
            // The login script runs on `SourceScriptThread`: a page it opens with
            // `java.startBrowserAwait` can stay up for minutes.
            let lastError: String? = await SourceScriptThread.run {
                let engine = JSCoreEngine()
                engine.bookSource = source
                Self.configureLegadoRuntime(engine, source: source, loginOwner: .shared)

                // java.startBrowser / java.startBrowserAwait open through
                // `SourceBrowserPresenter`, the same as from any other script.

                // Wire java.toast / java.longToast — shows a UIAlertController auto-dismiss
                engine.toastHandler = { msg in
                    Task { @MainActor in
                        BookSourceFormLoginView.presentToastAlert(message: msg)
                    }
                }
                let bindings: [String: Any] = [
                    "result": credentials,
                    "baseUrl": source.bookSourceUrl
                ]

                // Extract JS body from loginUrl (strip @js: / <js>…</js>)
                let js = LoginManager.shared.extractLoginJs(rawLogin) ?? rawLogin
                let wrappedJS = """
                \(js)
                if (typeof login === 'function') {
                    login.apply(this);
                }
                """

                let result = engine.evaluate(wrappedJS, bindings: bindings)

                // If JS returned a header JSON, persist it
                if let resultStr = result,
                   !resultStr.isEmpty,
                   let data = resultStr.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                    LoginManager.shared.storeLoginHeaders(
                        sourceUrl: source.bookSourceUrl, headers: dict
                    )
                } else {
                    // Try reading putLoginHeader result from LoginManager (JS may have called java.put)
                    let _ = LoginManager.shared.getLoginHeader(sourceUrl: source.bookSourceUrl)
                }
                return engine.lastError
            }

            await MainActor.run {
                isLoading = false
                if let err = lastError, !err.isEmpty {
                    menuAlert = MenuActionAlert(title: localized("操作失敗"), detail: err)
                } else {
                    menuAlert = MenuActionAlert(
                        title: localized("登入成功"),
                        detail: localized("登入成功"),
                        dismissesView: true
                    )
                }
            }
        }
    }

    private func runButtonJS(action: String, credentials: [String: String]) {
        let rawLogin = source.loginUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let loginJS = LoginManager.shared.extractLoginJs(rawLogin) ?? ""
        let combined = "\(loginJS)\n\(action)"
        // Captured before leaving the main actor so a label refresh after the action can
        // run on the same engine; the source decides the display text, we only resolve it.
        let dynamicLabelFields = fields.filter(\.hasDynamicViewName)

        // The menu action runs on `SourceScriptThread`: a page it opens with
        // `java.startBrowserAwait` can stay up for minutes.
        Task.detached(priority: .userInitiated) {
            await SourceScriptThread.run {
                let engine = Self.makeLoginEngine(source: source)
                let spoke = MenuActionSpokeFlag()

                engine.browserPresentHandler = { request, completion in
                    spoke.fired = true
                    Task { @MainActor in
                        SourceBrowserPresenter.present(request, completion: completion)
                    }
                }
                engine.toastHandler = { msg in
                    spoke.fired = true
                    Task { @MainActor in
                        BookSourceFormLoginView.presentToastAlert(message: msg)
                    }
                }
                // `changeMenu(tag)` does `source.put("menuTag", tag); java.reLoginView()`. Re-evaluate
                // the menu JS (which now reads the new menuTag) and refresh the displayed buttons so
                // multi-page source menus (起点's 评论设置 → 段评开关) can actually navigate.
                engine.reLoginViewHandler = {
                    AppLogger.parse("⟐ reLoginView FIRED", context: [:])
                    let evaluation = Self.evaluateJsLoginUiResult(source: source)
                    // Keep the current menu if a source's refresh script fails; replacing it
                    // with an empty array would hide the only actionable controls.
                    guard let parsed = LoginManager.shared.parseLoginUiResult(evaluation.json) else {
                        AppLogger.parse("⟐ reLoginView failed", context: [
                            "error": evaluation.error ?? "invalid loginUi JSON"
                        ])
                        return
                    }
                    AppLogger.parse("⟐ reLoginView", context: [
                        "newFields": parsed.count,
                        "names": parsed.prefix(8).map { $0.name }.joined(separator: "|")
                    ])
                    Task { @MainActor in
                        self.fields = parsed
                        self.fieldLabels = evaluation.labels
                        self.values = Self.initialValues(
                            for: parsed,
                            stored: LoginManager.shared.getLoginInfo(sourceUrl: source.bookSourceUrl) ?? self.values
                        )
                    }
                }

                let bindings: [String: Any] = [
                    "result": credentials,
                    "baseUrl": source.bookSourceUrl
                ]
                SourceAPIErrorLog.shared.clear(for: source.bookSourceUrl)
                if source.bookSourceName.contains("书山聚合") {
                    let before = engine.evaluate("java.get('yunpara')") ?? "<nil>"
                    NSLog(
                        "❖SHUSHAN TRACE❖ stage=menu.before action=%@ yunpara=%@ jsError=%@",
                        action,
                        before.isEmpty ? "<empty>" : before,
                        engine.lastError ?? "none"
                    )
                }
                _ = engine.evaluate(combined, bindings: bindings)
                if source.bookSourceName.contains("书山聚合") {
                    let actionError = engine.lastError
                    let after = engine.evaluate("java.get('yunpara')") ?? "<nil>"
                    NSLog(
                        "❖SHUSHAN TRACE❖ stage=menu.after action=%@ yunpara=%@ actionError=%@",
                        action,
                        after.isEmpty ? "<empty>" : after,
                        actionError ?? "none"
                    )
                }

                // Legado refreshes the menu's labels after an action (`upUiData`); a source's
                // dynamic viewNames (e.g. 起点's 段评 state) can change because of it. Resolve
                // them in the engine that just ran the action, so its state is still in scope.
                if !dynamicLabelFields.isEmpty {
                    let labels = Self.evaluateDynamicLabels(
                        dynamicLabelFields,
                        engine: engine,
                        credentials: credentials,
                        source: source
                    )
                    if !labels.isEmpty {
                        Task { @MainActor in
                            self.fieldLabels.merge(labels) { _, new in new }
                        }
                    }
                }

                // A menu action that finishes without saying anything is the failure mode
                // this reports: 同人小说网's `registerByInvite()` returns early when its API
                // answers `{"error":…}` (wrong/used 邀请码, rejected device id), so
                // 「邀请码注册Token」 looked like a dead button. Only speak when the source
                // itself stayed silent — its own toast is the better message when it has one.
                guard !spoke.fired else { return }
                let report: MenuActionAlert?
                if let jsError = engine.lastError {
                    report = MenuActionAlert(title: localized("來源配置腳本錯誤"), detail: jsError)
                } else if let failure = SourceAPIErrorLog.shared.last(for: source.bookSourceUrl) {
                    report = MenuActionAlert(
                        title: localized("來源配置伺服器回應失敗"), detail: failure.displayText)
                } else {
                    report = nil
                }
                guard let report else { return }
                AppLogger.parse("⟐ menuButton silent", context: [
                    "title": report.title, "detail": report.detail
                ])
                Task { @MainActor in self.menuAlert = report }
            }
        }
    }

    /// Whether a menu action produced any user-visible response of its own.
    /// A reference box: the JS runs on the engine's own thread and sets this
    /// through escaping handlers, then `runButtonJS` reads it once JS has finished.
    private final class MenuActionSpokeFlag: @unchecked Sendable {
        var fired = false
    }

    nonisolated private static func configureLegadoRuntime(_ engine: JSCoreEngine, source: BookSource, loginOwner: LoginManager) {
        let sourceUrl = source.bookSourceUrl
        let runtimeStore = BookSourceRuntimeStateStore.shared
        let ruleData = BookSourceRuleData(source: source)

        // Settings actions and chapter parsing use separate JS engines. Persist
        // Legado `java.put/get` state (书山's `yunpara`) at source scope.
        engine.getData = { key in
            runtimeStore.sourceValue(for: sourceUrl, key: key)
        }
        engine.putData = { key, value in
            runtimeStore.setSourceValue(value, for: sourceUrl, key: key)
        }
        engine.sourceBridge.getVariableHandler = {
            runtimeStore.sourceVariableJSON(for: sourceUrl) ?? ""
        }
        engine.sourceBridge.setVariableHandler = { jsonString in
            runtimeStore.setSourceVariableJSON(jsonString, for: sourceUrl)
        }
        engine.sourceBridge.getKeyValueHandler = { key in
            runtimeStore.sourceValue(for: sourceUrl, key: key)
        }
        engine.sourceBridge.putKeyValueHandler = { key, value in
            runtimeStore.setSourceValue(value, for: sourceUrl, key: key)
        }
        engine.sourceBridge.getLoginInfoHandler = {
            loginOwner.getLoginInfo(sourceUrl: sourceUrl).flatMap { info in
                guard let data = try? JSONSerialization.data(withJSONObject: info) else { return nil }
                return String(data: data, encoding: .utf8)
            }
        }
        engine.sourceBridge.getLoginInfoMapHandler = {
            loginOwner.getLoginInfo(sourceUrl: sourceUrl) ?? [:]
        }
        engine.sourceBridge.putLoginInfoHandler = { info in
            guard let data = info.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
            loginOwner.storeLoginInfo(sourceUrl: sourceUrl, info: dict)
        }
        engine.sourceBridge.removeLoginInfoHandler = {
            loginOwner.clearLogin(sourceUrl: sourceUrl)
        }
        // Legado semantics: the payload is stored verbatim and only becomes request
        // headers if it is a JSON object. 书山聚合's `login()` stores a bare api_key
        // and reads it straight back via `source.getLoginHeader()` to build `?key=`
        // URLs — synthesising a header name for it clobbers the constant token the
        // source's own `header` rule sends.
        engine.sourceBridge.putLoginHeaderHandler = { header in
            loginOwner.storeLoginHeader(sourceUrl: sourceUrl, raw: header)
        }
        engine.sourceBridge.getLoginHeaderHandler = {
            loginOwner.getLoginHeader(sourceUrl: sourceUrl)
        }
        engine.sourceBridge.removeLoginHeaderHandler = {
            loginOwner.removeLoginHeader(sourceUrl: sourceUrl)
        }
        engine.sourceBridge.getHeaderMapHandler = {
            // This sheet's own engine resolves the (possibly `@js:`) header rule —
            // don't reach for a second engine via `source.parsedHeaders`.
            var headers = engine.resolvedSourceHeaders()
            if let loginHeaders = loginOwner.getLoginHeaderMap(sourceUrl: sourceUrl) {
                headers.merge(loginHeaders) { _, new in new }
            }
            return headers
        }
        engine.sourceBridge.evalJSHandler = { js in
            engine.evaluate(js) ?? ""
        }
        engine.analyzeUrlHandler = { urlStr in
            let analyzeUrl = AnalyzeUrl(
                ruleUrl: urlStr,
                sourceHeader: source.header,
                baseUrl: source.bookSourceUrl,
                source: ruleData,
                jsEvaluator: { js, bindings in engine.evaluate(js, bindings: bindings) }
            )
            if analyzeUrl.isDataUri {
                guard let decoded = analyzeUrl.decodeDataUri() else { return "" }
                if analyzeUrl.type?.isEmpty == false {
                    return decoded.data.map { String(format: "%02x", $0) }.joined()
                }
                return String(data: decoded.data, encoding: .utf8) ?? ""
            }
            guard var request = analyzeUrl.toURLRequest() else { return "" }
            for (key, value) in engine.resolvedSourceHeaders()
            where request.value(forHTTPHeaderField: key) == nil {
                request.setValue(value, forHTTPHeaderField: key)
            }
            loginOwner.applyLoginHeaders(to: &request, sourceUrl: sourceUrl)
            var body = ""
            var statusCode: Int?
            var timedOut = false
            do {
                let (data, response) = try CookieStore.shared.dataForScript(request: request, session: URLSession.shared, timeout: 30)
                statusCode = (response as? HTTPURLResponse)?.statusCode
                body = String(data: data, encoding: .utf8) ?? ""
            } catch {
                timedOut = (error as? URLError)?.code == .timedOut
                if let ownerError = error as? CookieOwnerError { CookieStore.raiseScriptError(ownerError) }
                else { AppLogger.error("Login menu HTTP did not complete", error: error) }
            }
            // Menu actions are the one place a source's API failure has no other way
            // to reach the user: the rule JS returns early on a bad reply, so the
            // button just looks dead. `runButtonJS` reports whatever lands here.
            SourceAPIErrorLog.shared.record(
                sourceUrl: sourceUrl, requestUrl: request.url?.absoluteString,
                statusCode: statusCode, body: body, timedOut: timedOut
            )
            return body
        }
        engine.upLoginDataHandler = { mapValue in
            // `java.upLoginData(map)` from a settings menu (起点/光遇 段评颜色·气泡模版). Merge the
            // map's key/values into the source's stored login data so `source.getLoginInfoMap()`
            // (and the jsLib's `getConfigValue`/`Map()`) read them back.
            let raw = mapValue.toDictionary() ?? [:]
            var updates: [String: String] = [:]
            for (key, value) in raw {
                guard let name = key as? String else { continue }
                updates[name] = (value as? String) ?? String(describing: value)
            }
            guard !updates.isEmpty else { return }
            var info = loginOwner.getLoginInfo(sourceUrl: sourceUrl) ?? [:]
            info.merge(updates) { _, new in new }
            loginOwner.storeLoginInfo(sourceUrl: sourceUrl, info: info)
        }
        if !source.jsLib.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = engine.evaluate(source.jsLib, bindings: ["baseUrl": source.bookSourceUrl])
        }
    }

    // MARK: - UIKit Helpers

    /// Returns the topmost presented UIViewController for presenting modal sheets from background tasks.
    @MainActor
    static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        else { return nil }
        var top = root
        while let p = top.presentedViewController { top = p }
        return top
    }

    @MainActor
    static func presentToastAlert(message: String) {
        let showNewAlert = {
            guard let presenter = topViewControllerForToast() else { return }
            showToastAlert(message: message, from: presenter)
        }

        if let currentToastAlert, currentToastAlert.presentingViewController != nil {
            currentToastAlert.dismiss(animated: false) {
                Task { @MainActor in
                    self.currentToastAlert = nil
                    showNewAlert()
                }
            }
        } else {
            currentToastAlert = nil
            showNewAlert()
        }
    }

    /// Takes down the toast alert, if one is up, before `completion` runs — so a sheet a
    /// script asks for right after toasting has a presenter that is not already busy.
    @MainActor
    static func dismissToastAlert(then completion: @escaping @MainActor () -> Void) {
        guard let currentToastAlert, currentToastAlert.presentingViewController != nil else {
            completion()
            return
        }
        currentToastAlert.dismiss(animated: true) {
            Task { @MainActor in
                self.currentToastAlert = nil
                completion()
            }
        }
    }

    @MainActor
    private static func showToastAlert(message: String, from presenter: UIViewController) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        currentToastAlert = alert
        presenter.present(alert, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if alert.presentingViewController != nil {
                alert.dismiss(animated: true)
            }
            if currentToastAlert === alert {
                currentToastAlert = nil
            }
        }
    }

    @MainActor
    private static func topViewControllerForToast() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        else { return nil }
        var top = root
        while let presented = top.presentedViewController {
            if presented is UIAlertController {
                break
            }
            top = presented
        }
        return top
    }
}

// MARK: - Preview

#Preview("登入表單") {
    var source = BookSource()
    source.bookSourceName = "範例來源配置"
    source.bookSourceUrl = "https://example.com"
    source.loginUrl = "function login() { return true; }"
    // 輸入框整行、按鈕預設半行；cols 1/2/4 展示混合欄寬（登入＋註冊半行、
    // 遊客體驗整行、條款/隱私/客服/版本四欄）。
    source.loginUi = """
    [
        {"name": "帳號", "type": "text", "chars": ["手機號或 Email"]},
        {"name": "密碼", "type": "password"},
        {"name": "登入", "type": "button", "action": "login()"},
        {"name": "註冊帳號", "type": "button", "action": "register()"},
        {"name": "遊客體驗", "type": "button", "action": "guest()", "style": {"cols": 1}},
        {"name": "條款", "type": "button", "action": "terms()", "style": {"cols": 4}},
        {"name": "隱私", "type": "button", "action": "privacy()", "style": {"cols": 4}},
        {"name": "客服", "type": "button", "action": "support()", "style": {"cols": 4}},
        {"name": "版本", "type": "button", "action": "about()", "style": {"cols": 4}}
    ]
    """
    return BookSourceFormLoginView(source: source, onDismiss: {})
}

#Preview("來源配置選單") {
    var source = BookSource()
    source.bookSourceName = "範例來源配置・設定選單"
    source.bookSourceUrl = "https://example.com"
    source.loginUrl = "function noop() {}"
    // 書源動態選單常見的組合：開關、下拉與動作按鈕；viewName 是引號字面值時
    // 直接顯示、不求值。layout_wrapBefore 讓「登出」強制換行。
    source.loginUi = """
    [
        {"name": "段評開關", "viewName": "'段評開關'", "type": "toggle",
         "action": "noop()", "chars": ["🔳", "✅"], "default": "🔳"},
        {"name": "字體", "viewName": "'字體'", "type": "select",
         "chars": ["預設", "圓角", "襯線"], "default": "預設"},
        {"name": "重新整理", "viewName": "'重新整理'", "type": "button", "action": "noop()"},
        {"name": "登出", "viewName": "'登出'", "type": "button", "action": "noop()",
         "style": {"layout_wrapBefore": true}}
    ]
    """
    return BookSourceFormLoginView(source: source, onDismiss: {})
}

/// Observe the existing native sheet. A visible swipe uses the same checked Close
/// operation; forced dismissal still hands its frozen Map to the owned task.
/// No credentials or pending form state live in this presentation adapter.
private struct OriginalLoginDismissObserver: UIViewControllerRepresentable {
    let protectsDismissal: Bool
    let onAttempt: () -> Void
    let onSystemDismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> ObserverController {
        let controller = ObserverController()
        controller.coordinator = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: ObserverController, context: Context) {
        context.coordinator.protectsDismissal = protectsDismissal
        context.coordinator.onAttempt = onAttempt
        context.coordinator.onSystemDismiss = onSystemDismiss
        context.coordinator.attach(from: controller)
    }
    static func dismantleUIViewController(_ controller: ObserverController, coordinator: Coordinator) {
        coordinator.restoreDelegate()
    }

    @MainActor final class ObserverController: UIViewController {
        weak var coordinator: Coordinator?
        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            coordinator?.attach(from: self)
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            coordinator?.attach(from: self)
        }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            coordinator?.observeSystemDismissal()
        }
    }

    @MainActor final class Coordinator: NSObject, UIAdaptivePresentationControllerDelegate {
        var protectsDismissal = false
        var onAttempt: () -> Void = {}
        var onSystemDismiss: () -> Void = {}
        private weak var presentation: UIPresentationController?
        private weak var previousDelegate: (any UIAdaptivePresentationControllerDelegate)?

        func attach(from controller: UIViewController) {
            var candidate: UIViewController? = controller
            while let current = candidate {
                if current.presentingViewController != nil, let host = current.presentationController {
                    if presentation !== host { restoreDelegate(); presentation = host }
                    if host.delegate !== self { previousDelegate = host.delegate; host.delegate = self }
                    return
                }
                candidate = current.parent
            }
        }
        func restoreDelegate() {
            if let presentation, presentation.delegate === self { presentation.delegate = previousDelegate }
            presentation = nil
            previousDelegate = nil
        }
        func observeSystemDismissal() {
            if presentation?.presentedViewController.isBeingDismissed == true { onSystemDismiss() }
        }
        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
            if protectsDismissal { return false }
            return previousDelegate?.presentationControllerShouldDismiss?(presentationController) ?? true
        }
        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            if protectsDismissal { onAttempt() }
            else { previousDelegate?.presentationControllerDidAttemptToDismiss?(presentationController) }
        }
        func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
            onSystemDismiss()
            previousDelegate?.presentationControllerWillDismiss?(presentationController)
        }
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            onSystemDismiss()
            previousDelegate?.presentationControllerDidDismiss?(presentationController)
        }
    }
}
