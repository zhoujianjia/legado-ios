import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Settings consumes the App's existing owner. Credential inputs stay in the
/// screen's temporary state and the session-owned authentication operation.
struct SelfRenewalSettingsView: View {
    @Environment(\.appDependencies) private var dependencies
    @State private var appleID = ""
    @State private var password = ""
    @State private var verificationCode = ""
    @State private var machineName = "阅读"
    @State private var action: Action?
    @State private var selectingFile = false
    @State private var filePurpose: FilePurpose = .configure
    @State private var fileSelectionFailed = false
    @State private var confirmingInstallation = false

    private enum FilePurpose: Equatable { case initialize, configure, prepare }
    private enum Operation {
        case initialize(URL), configure(URL), prepare(URL), submit
        case setAutomatic(Bool), checkAutomatic, cancelAutomatic
        case signIn(String, String), verify(String, UUID), cancelAuthentication
        case observeAccount, signOut, refresh(String), reconcile, finalizePublication, recover
    }
    private struct Action { let id = UUID(); let operation: Operation }

    var body: some View {
        List {
            if let owner = dependencies.selfRenewalOwner {
                statusSection(owner)
                automaticSection(owner)
                configurationSection(owner)
                accountSection(owner)
                materialSection(owner)
                installationSection(owner)
            } else {
                ContentUnavailableView(localized("續簽材料目前不可用"), systemImage: "signature")
            }
            Section {
                NavigationLink {
                    SelfRenewalProbeView()
                } label: {
                    SettingsRowLabel(localized("自續簽驗證"), systemImage: "network")
                }
                .accessibilityIdentifier("self_renewal_open_diagnostics")
            }
            .interfaceSectionSurface()
        }
        .softScrollEdges()
        .navigationTitle(localized("自簽與續簽"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .fileImporter(isPresented: $selectingFile,
            allowedContentTypes: filePurpose == .prepare ? [.data] : [.json], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                fileSelectionFailed = false
                switch filePurpose {
                case .initialize: begin(.initialize(url))
                case .configure: begin(.configure(url))
                case .prepare: begin(.prepare(url))
                }
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled { fileSelectionFailed = true }
            }
        }
        .confirmationDialog(localized("安裝續簽包"), isPresented: $confirmingInstallation, titleVisibility: .visible) {
            Button(localized("安裝續簽包")) { begin(.submit) }
            Button(localized("取消"), role: .cancel) { }
        } message: {
            Text(localized("安裝會更新目前應用，過程可能中斷閱讀。"))
        }
        .task(id: action?.id) {
            guard let selected = action, let owner = dependencies.selfRenewalOwner else { return }
            switch selected.operation {
            case .initialize(let url): await owner.initializeConfiguration(from: url)
            case .configure(let url): await owner.importConfiguration(url)
            case .prepare(let url): await owner.prepareRenewal(from: url)
            case .submit: await owner.submitPreparedRenewal()
            case .setAutomatic(let enabled): await owner.setAutomaticRenewalEnabled(enabled)
            case .checkAutomatic: await owner.runAutomaticRenewalNow()
            case .cancelAutomatic: await owner.cancelAutomaticRenewal()
            case .signIn(let account, let secret): await owner.signInDeveloperAccount(appleID: account, password: secret)
            case .verify(let code, let challenge): await owner.submitDeveloperVerificationCode(code, challengeID: challenge)
            case .cancelAuthentication: await owner.cancelDeveloperAuthentication()
            case .observeAccount: await owner.observeDeveloperAccount()
            case .signOut: await owner.signOutDeveloperAccount()
            case .refresh(let name): await owner.refreshDeveloperMaterials(machineName: name)
            case .reconcile: await owner.reconcileDeveloperMaterials()
            case .finalizePublication: await owner.finalizeDeveloperMaterialPublication()
            case .recover: await owner.recoverExplicitly()
            }
            if action?.id == selected.id { action = nil }
        }
        .onChange(of: dependencies.selfRenewalOwner?.developerChallenge?.id) { _, _ in verificationCode = "" }
        .onChange(of: dependencies.selfRenewalOwner?.problem) { _, problem in
            guard let problem else { return }
            UIAccessibility.post(notification: .announcement, argument: localized(problemKey(problem)))
        }
        .onDisappear {
            // Cancels this view's actual task. Session forwards cancellation to
            // its owned login/transport work and drains it before returning.
            action = nil; password = ""; verificationCode = ""
        }
    }

    private func statusSection(_ owner: SelfRenewalAppOwner) -> some View {
        Section {
            ThemedLabeledContent(localized("續簽材料"), value: localized(statusKey(owner.status)))
                .accessibilityIdentifier("self_renewal_current_materials")
            if owner.isWorking {
                ProgressView(localized("正在處理續簽操作"))
                if action != nil {
                    Button(localized("取消"), role: .cancel) { action = nil }
                        .accessibilityIdentifier("self_renewal_cancel_operation")
                }
            }
            if let problem = owner.problem {
                Text(localized(problemKey(problem)))
                    .foregroundStyle(DSColor.destructive)
                    .accessibilityIdentifier("self_renewal_operation_problem")
            } else if fileSelectionFailed {
                Text(localized("無法開啟所選檔案"))
                    .foregroundStyle(DSColor.destructive)
            }
        }
        .interfaceSectionSurface()
    }

    private func configurationSection(_ owner: SelfRenewalAppOwner) -> some View {
        Section {
            Button { chooseFile(.initialize) } label: {
                SettingsRowLabel(localized("初始化續簽配置"), systemImage: "key", role: .action)
            }
            .disabled(owner.isWorking || owner.status?.state != .unconfigured)
            .accessibilityIdentifier("self_renewal_initialize_configuration")
            Button { chooseFile(.configure) } label: {
                SettingsRowLabel(localized("匯入續簽配置"), systemImage: "doc.badge.plus", role: .action)
            }
            .disabled(owner.isWorking)
            .accessibilityIdentifier("self_renewal_configure")
        }
        .interfaceSectionSurface()
    }

    private func automaticSection(_ owner: SelfRenewalAppOwner) -> some View {
        Section {
            Toggle(isOn: Binding(
                get: { owner.automaticRenewal?.isEnabled == true },
                set: { begin(.setAutomatic($0)) })) {
                SettingsRowLabel(localized("自動續簽"), systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(owner.isWorking || owner.automaticRenewal == nil)
            .accessibilityIdentifier("self_renewal_automatic_toggle")
            if let observation = owner.automaticRenewal {
                ThemedLabeledContent(localized("續簽狀態"), value: localized(automaticStatusKey(observation.outcome)))
                    .accessibilityIdentifier("self_renewal_automatic_status")
                if let next = observation.nextEligibleAt, observation.isEnabled {
                    LabeledContent(localized("下次檢查時間")) {
                        Text(next, format: .dateTime.year().month().day().hour().minute())
                            .foregroundStyle(DSColor.textSecondary)
                    }
                }
            }
            Button(localized("立即檢查續簽條件")) { begin(.checkAutomatic) }
                .disabled(owner.isWorking || owner.automaticRenewal?.isEnabled != true)
                .accessibilityIdentifier("self_renewal_automatic_check")
            if owner.isWorking && action == nil {
                Button(localized("取消"), role: .cancel) { begin(.cancelAutomatic) }
                    .accessibilityIdentifier("self_renewal_automatic_cancel")
            }
        } footer: {
            Text(localized("需要有效簽名材料及已配對的安裝連線；背景執行時間由系統決定。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    private func automaticStatusKey(_ outcome: SelfRenewalAppSession.AutomaticRenewalOutcome) -> String {
        switch outcome {
        case .disabled: return "自動續簽已關閉"
        case .waiting: return "等待下次續簽檢查"
        case .configurationRequired: return "尚未配置續簽材料"
        case .accountRequired: return "需要登入 Apple ID"
        case .recoveryRequired: return "已有事務需要恢復檢查"
        case .interrupted: return "上次續簽檢查已中斷"
        case .receiptObserved: return "已收到安裝回應，仍需確認更新結果"
        case .failed: return "續簽檢查未完成"
        case .clockChanged: return "裝置時間已變更，稍後重新檢查"
        }
    }

    private func accountSection(_ owner: SelfRenewalAppOwner) -> some View {
        Section {
            ThemedLabeledContent(localized("Apple ID"),
                value: localized(owner.developerSession == nil ? "尚未驗證" : "已登入"))
            if owner.developerServicesConfigured {
                if let challenge = owner.developerChallenge {
                    TextField(localized("驗證碼"), text: $verificationCode)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .accessibilityIdentifier("self_renewal_verification_code")
                    Button(localized("提交驗證碼")) {
                        let code = verificationCode; verificationCode = ""
                        begin(.verify(code, challenge.id))
                    }
                    .disabled(owner.isWorking || verificationCode.isEmpty)
                    Button(localized("取消登入"), role: .cancel) {
                        password = ""; verificationCode = ""; begin(.cancelAuthentication)
                    }
                    .disabled(owner.isWorking)
                } else if owner.developerSession == nil {
                    TextField(localized("Apple ID"), text: $appleID)
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("self_renewal_apple_id")
                    SecureField(localized("密碼"), text: $password)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("self_renewal_password")
                    Button(localized("登入 Apple ID")) {
                        let secret = password; password = ""
                        begin(.signIn(appleID, secret))
                    }
                    .disabled(owner.isWorking || appleID.isEmpty || password.isEmpty || !hasConfiguration(owner))
                }
                Button(localized("檢查帳號連線")) { begin(.observeAccount) }
                    .disabled(owner.isWorking || !hasConfiguration(owner))
                if owner.developerChallenge == nil {
                    Button(localized("登出"), role: .destructive) {
                        password = ""; verificationCode = ""; begin(.signOut)
                    }
                    .disabled(owner.isWorking || !hasConfiguration(owner))
                }
            }
        } footer: {
            if !owner.developerServicesConfigured {
                Text(localized("帳號認證服務尚未配置，暫時無法登入或申請簽名材料。"))
                    .dsSectionFooter()
            }
        }
        .interfaceSectionSurface()
    }

    private func materialSection(_ owner: SelfRenewalAppOwner) -> some View {
        Section {
            TextField(localized("裝置名稱"), text: $machineName)
                .accessibilityIdentifier("self_renewal_machine_name")
            Button { begin(.refresh(machineName)) } label: {
                SettingsRowLabel(localized("申請或更新簽名材料"), systemImage: "arrow.clockwise", role: .action)
            }
            .disabled(owner.isWorking || !owner.developerServicesConfigured || owner.developerSession == nil || machineName.isEmpty)
            .accessibilityIdentifier("self_renewal_refresh_materials")
            Button(localized("核對待確認的材料申請")) { begin(.reconcile) }
                .disabled(owner.isWorking || !owner.developerServicesConfigured || !hasConfiguration(owner))
            Button(localized("確認已發布的簽名材料")) { begin(.finalizePublication) }
                .disabled(owner.isWorking || !hasConfiguration(owner))
            if let material = owner.developerMaterial, let expires = material.profileExpiresAt {
                LabeledContent(localized("描述檔到期時間")) {
                    Text(expires, format: .dateTime.year().month().day().hour().minute())
                        .foregroundStyle(DSColor.textSecondary)
                }
            }
        }
        .interfaceSectionSurface()
    }

    private func installationSection(_ owner: SelfRenewalAppOwner) -> some View {
        Section {
            Button { chooseFile(.prepare) } label: {
                SettingsRowLabel(localized("選擇 IPA 並準備續簽包"), systemImage: "shippingbox", role: .action)
            }
            .disabled(owner.isWorking || owner.status?.access != .signing)
            .accessibilityIdentifier("self_renewal_prepare_ipa")
            Button { confirmingInstallation = true } label: {
                SettingsRowLabel(localized("安裝續簽包"), systemImage: "arrow.down.app", role: .action)
            }
            .disabled(owner.isWorking || owner.status?.access != .signing || owner.status?.phase != .candidateReady)
            .accessibilityIdentifier("self_renewal_submit_candidate")
            if owner.recoveryAvailable {
                Button { begin(.recover) } label: {
                    SettingsRowLabel(localized("恢復續簽事務檢查"), systemImage: "arrow.clockwise", role: .action)
                }
                .disabled(owner.isWorking)
            }
        } footer: {
            Text(localized("準備完成後需另行確認安裝；已提交但結果未明時，請先恢復事務檢查。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    private func begin(_ operation: Operation) { action = Action(operation: operation) }
    private func chooseFile(_ purpose: FilePurpose) { filePurpose = purpose; selectingFile = true }
    private func hasConfiguration(_ owner: SelfRenewalAppOwner) -> Bool {
        guard let status = owner.status else { return false }
        return status.state != .unconfigured
    }
    private func statusKey(_ status: SelfRenewalAppSession.Status?) -> String {
        switch status?.state {
        case .unconfigured: return "尚未配置續簽材料"
        case .ready: return "續簽材料已連接"
        case .candidateReady: return "已有待處理續簽包"
        case .recoveryRequired: return "已有事務需要恢復檢查"
        case .attentionRequired: return "已有事務需要處理"
        case .retiredUnsubmitted: return "未提交事務已安全退役"
        case .authenticatedRecoveryObserved: return "已完成認證恢復檢查"
        case .unavailable, nil: return "續簽材料目前不可用"
        }
    }
    private func problemKey(_ problem: SelfRenewalAppOwner.Problem) -> String {
        switch problem {
        case .invalidConfiguration: return "續簽配置無效或內容不完整"
        case .configurationInUse: return "已有事務使用目前配置，暫時無法更換"
        case .signingMaterials: return "缺少可用的簽名材料"
        case .authenticationNotConfigured: return "續簽認證尚未配置"
        case .authenticationUnavailable: return "續簽認證目前不可用"
        case .localStorage: return "無法讀寫續簽狀態，原有事務已保留"
        case .operationFailed: return "無法完成續簽操作，原有事務已保留"
        case .cancelled: return "續簽操作已取消"
        }
    }
}

#Preview {
    NavigationStack { SelfRenewalSettingsView() }
}
