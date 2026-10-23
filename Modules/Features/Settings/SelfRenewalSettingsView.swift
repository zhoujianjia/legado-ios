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
    @State private var providerEndpointDraft = ""
    @State private var providerDraftHasEdits = false
    @State private var confirmingRegistrationReset = false
    @State private var pairingPKCS12: URL?
    @State private var pairingPublicConfiguration: URL?
    @State private var pairingPassword = ""
    @State private var pairingImportSucceeded = false
    @State private var inputProblem: InputProblem?

    private enum FilePurpose: Equatable { case initialize, configure, prepare, pairingPKCS12, pairingPublicConfiguration }
    private enum InputProblem: Equatable { case serviceURL, pairingFiles, pairingPassword, busy }
    private enum Operation {
        case initialize(URL), configure(URL), prepare(URL), submit
        case setAutomatic(Bool), checkAutomatic, cancelAutomatic
        case signIn(String, String), verify(String, UUID), cancelAuthentication
        case observeAccount, signOut, refresh(String), reconcile, finalizePublication, recover
        case configureProvider(URL?), observeRegistration, resetRegistration
        case importPairing(URL, String, URL)
    }
    private struct Action { let id = UUID(); let operation: Operation }

    var body: some View {
        List {
            if let owner = dependencies.selfRenewalOwner {
                statusSection(owner)
                automaticSection(owner)
                configurationSection(owner)
                providerSection(owner)
                accountSection(owner)
                materialSection(owner)
                pairingSection(owner)
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
            allowedContentTypes: allowedFileTypes, allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                fileSelectionFailed = false
                switch filePurpose {
                case .initialize: begin(.initialize(url))
                case .configure: begin(.configure(url))
                case .prepare: begin(.prepare(url))
                case .pairingPKCS12:
                    pairingPKCS12 = url; pairingPassword = ""; pairingImportSucceeded = false; inputProblem = nil
                case .pairingPublicConfiguration:
                    pairingPublicConfiguration = url; pairingImportSucceeded = false; inputProblem = nil
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
        .confirmationDialog(localized("重設未完成的註冊？"), isPresented: $confirmingRegistrationReset, titleVisibility: .visible) {
            Button(localized("重設未完成的註冊"), role: .destructive) {
                guard let owner = dependencies.selfRenewalOwner, registrationNeedsReset(owner), !owner.isWorking else { return }
                begin(.resetRegistration)
            }
            Button(localized("取消"), role: .cancel) { }
        } message: {
            Text(localized("重設後需重新登入 Apple ID。"))
        }
        .task {
            guard let owner = dependencies.selfRenewalOwner else { return }
            await owner.observeAnisetteRegistration()
            synchronizeProviderDraft(owner)
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
            case .configureProvider(let endpoint):
                let saved = await owner.configureAnisetteProvider(endpoint: endpoint)
                if saved, !Task.isCancelled { synchronizeProviderDraft(owner, committed: true) }
                else if !saved, owner.problem == nil, !Task.isCancelled { inputProblem = .busy }
            case .observeRegistration: await owner.observeAnisetteRegistration()
            case .resetRegistration: await owner.resetUnknownAnisetteRegistration()
            case .importPairing(let pkcs12, let secret, let configuration):
                let imported = await owner.importPairingIdentity(pkcs12: pkcs12, password: secret, publicConfiguration: configuration)
                if imported, !Task.isCancelled {
                    pairingImportSucceeded = true; pairingPKCS12 = nil; pairingPublicConfiguration = nil
                } else if !imported, owner.problem == nil, !Task.isCancelled { inputProblem = .busy }
            }
            if action?.id == selected.id { action = nil }
        }
        .onChange(of: dependencies.selfRenewalOwner?.anisetteProvider?.endpoint) { _, _ in
            if let owner = dependencies.selfRenewalOwner { synchronizeProviderDraft(owner) }
        }
        .onChange(of: dependencies.selfRenewalOwner?.developerChallenge?.id) { _, _ in verificationCode = "" }
        .onChange(of: dependencies.selfRenewalOwner?.problem) { _, problem in
            guard let problem else { return }
            UIAccessibility.post(notification: .announcement, argument: localized(problemKey(problem)))
        }
        .onChange(of: inputProblem) { _, problem in
            guard let problem else { return }
            UIAccessibility.post(notification: .announcement, argument: localized(inputProblemKey(problem)))
        }
        .onChange(of: pairingImportSucceeded) { _, succeeded in
            if succeeded { UIAccessibility.post(notification: .announcement, argument: localized("已匯入配對身分")) }
        }
        .onDisappear {
            // Cancels this view's actual task. Session forwards cancellation to
            // its owned login/transport work and drains it before returning.
            action = nil; password = ""; verificationCode = ""; pairingPassword = ""
            pairingPKCS12 = nil; pairingPublicConfiguration = nil
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
            if let problem = inputProblem {
                Text(localized(inputProblemKey(problem)))
                    .foregroundStyle(DSColor.destructive)
                    .accessibilityIdentifier("self_renewal_input_problem")
            } else if fileSelectionFailed {
                Text(localized("無法開啟所選檔案"))
                    .foregroundStyle(DSColor.destructive)
            } else if let problem = owner.problem {
                Text(localized(problemKey(problem)))
                    .foregroundStyle(DSColor.destructive)
                    .accessibilityIdentifier("self_renewal_operation_problem")
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

    private func providerSection(_ owner: SelfRenewalAppOwner) -> some View {
        Section {
            LabeledContent {
                TextField(localized("HTTPS 服務網址"), text: Binding(
                    get: { providerEndpointDraft },
                    set: { providerEndpointDraft = $0; providerDraftHasEdits = true; inputProblem = nil }))
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .disabled(owner.isWorking || action != nil)
                    .accessibilityIdentifier("self_renewal_anisette_endpoint")
            } label: {
                SettingsRowLabel(localized("HTTPS 服務網址"), systemImage: "network")
            }
            Button { saveProvider() } label: {
                SettingsRowLabel(localized("儲存服務"), systemImage: "checkmark", role: .action)
            }
            .disabled(owner.isWorking || action != nil)
            .accessibilityIdentifier("self_renewal_anisette_save")
            if owner.anisetteProvider != nil {
                Button { begin(.configureProvider(nil)) } label: {
                    SettingsRowLabel(localized("停用服務"), systemImage: "pause.circle", role: .action)
                }
                .disabled(owner.isWorking || action != nil)
                .accessibilityIdentifier("self_renewal_anisette_disable")
                if hasConfiguration(owner) {
                    if owner.anisetteRegistrationProblem != nil {
                        Text(localized("無法讀取服務註冊狀態"))
                            .foregroundStyle(DSColor.destructive)
                            .accessibilityIdentifier("self_renewal_anisette_registration_problem")
                    } else {
                        ThemedLabeledContent(localized("服務註冊"), value: localized(registrationStatusKey(owner)))
                            .accessibilityIdentifier("self_renewal_anisette_registration_status")
                    }
                    Button { begin(.observeRegistration) } label: {
                        SettingsRowLabel(localized("重新檢查註冊狀態"), systemImage: "arrow.clockwise", role: .action)
                    }
                    .disabled(owner.isWorking || action != nil)
                    .accessibilityIdentifier("self_renewal_anisette_observe_registration")
                }
                if registrationNeedsReset(owner) {
                    Button { confirmingRegistrationReset = true } label: {
                        SettingsRowLabel(localized("重設未完成的註冊"), systemImage: "arrow.counterclockwise", role: .destructive)
                    }
                    .disabled(owner.isWorking || action != nil)
                    .accessibilityIdentifier("self_renewal_anisette_reset_registration")
                }
            }
        } header: {
            Text(localized("Anisette 服務"))
        } footer: {
            Text(localized("請使用您信任的服務；更換、停用或重設後需重新登入 Apple ID。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    private func pairingSection(_ owner: SelfRenewalAppOwner) -> some View {
        Section {
            Button { chooseFile(.pairingPKCS12) } label: {
                SettingsValueLabel(title: localized("選擇配對憑證（P12）"), systemImage: "doc.badge.plus",
                    value: pairingPKCS12?.lastPathComponent ?? localized("尚未選擇"))
            }
            .disabled(owner.isWorking || action != nil)
            .accessibilityIdentifier("self_renewal_pairing_select_pkcs12")
            Button { chooseFile(.pairingPublicConfiguration) } label: {
                SettingsValueLabel(title: localized("選擇公開配對配置（JSON）"), systemImage: "doc.text",
                    value: pairingPublicConfiguration?.lastPathComponent ?? localized("尚未選擇"))
            }
            .disabled(owner.isWorking || action != nil)
            .accessibilityIdentifier("self_renewal_pairing_select_public_configuration")
            LabeledContent {
                SecureField(localized("配對憑證密碼"), text: $pairingPassword)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .disabled(owner.isWorking || action != nil)
                    .accessibilityIdentifier("self_renewal_pairing_password")
            } label: {
                SettingsRowLabel(localized("配對憑證密碼"), systemImage: "lock")
            }
            Button { importPairing() } label: {
                SettingsRowLabel(localized("匯入配對身分"), systemImage: "key", role: .action)
            }
            .disabled(owner.isWorking || action != nil || owner.status?.access != .signing ||
                (owner.status?.phase != nil && owner.status?.phase != .retired))
            .accessibilityIdentifier("self_renewal_pairing_import")
            if pairingImportSucceeded {
                Text(localized("已匯入配對身分"))
                    .foregroundStyle(DSColor.textSecondary)
                    .accessibilityIdentifier("self_renewal_pairing_imported")
            }
        } header: {
            Text(localized("配對身分"))
        } footer: {
            Text(localized("需要已配對裝置的憑證及公開配置；匯入成功後仍需確認連線與安裝權限。"))
                .dsSectionFooter()
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
            } else if !owner.isWorking, owner.developerSession == nil,
                      let operation = owner.operationFailure?.operation,
                      operation == .signIn || operation == .verification,
                      let problem = owner.problem {
                Text(localized(problemKey(problem)))
                    .dsSectionFooter()
                    .foregroundStyle(DSColor.destructive)
                    .accessibilityIdentifier("self_renewal_account_problem")
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
        } footer: {
            if !owner.developerServicesConfigured {
                Text(localized("請先設定 Anisette 服務。"))
                    .dsSectionFooter()
            } else if owner.developerSession == nil {
                Text(localized("需要登入 Apple ID"))
                    .dsSectionFooter()
            } else if machineName.isEmpty {
                Text(localized("請填寫裝置名稱。"))
                    .dsSectionFooter()
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

    private var allowedFileTypes: [UTType] {
        switch filePurpose {
        case .prepare: return [.data]
        case .pairingPKCS12: return [.pkcs12]
        case .initialize, .configure, .pairingPublicConfiguration: return [.json]
        }
    }
    private func synchronizeProviderDraft(_ owner: SelfRenewalAppOwner, committed: Bool = false) {
        guard committed || !providerDraftHasEdits else { return }
        providerEndpointDraft = owner.anisetteProvider?.endpoint.absoluteString ?? ""
        providerDraftHasEdits = false
    }
    private func saveProvider() {
        let input = providerEndpointDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpoint = URL(string: input) else { inputProblem = .serviceURL; return }
        do {
            // This is the service's pure value validation. It does not create
            // a provider/transport, observe registration or perform network I/O.
            let configuration = try SelfRenewalAnisetteV3Configuration(endpoint: endpoint)
            begin(.configureProvider(configuration.endpoint))
        } catch { inputProblem = .serviceURL }
    }
    private func importPairing() {
        guard let pkcs12 = pairingPKCS12, let configuration = pairingPublicConfiguration,
              pkcs12.isFileURL, configuration.isFileURL else { inputProblem = .pairingFiles; return }
        guard !pairingPassword.isEmpty, pairingPassword.utf8.count <= 1_024,
              !pairingPassword.utf8.contains(0) else { inputProblem = .pairingPassword; return }
        let secret = pairingPassword; pairingPassword = ""; pairingImportSucceeded = false
        begin(.importPairing(pkcs12, secret, configuration))
    }
    private func registrationNeedsReset(_ owner: SelfRenewalAppOwner) -> Bool {
        owner.anisetteRegistrationProblem == nil &&
            (owner.anisetteRegistration?.phase == .provisioningOutcomeUnknown || owner.anisetteRegistration?.phase == .resetOutcomeUnknown)
    }
    private func registrationStatusKey(_ owner: SelfRenewalAppOwner) -> String {
        switch owner.anisetteRegistration?.phase {
        case .unprovisioned, nil: return "尚未註冊"
        case .provisioningOutcomeUnknown: return "註冊結果待確認"
        case .resetOutcomeUnknown: return "重設結果待確認"
        case .provisioned: return "已註冊"
        }
    }
    private func inputProblemKey(_ problem: InputProblem) -> String {
        switch problem {
        case .serviceURL: return "請輸入有效的 HTTPS 服務網址，且勿包含路徑、連接埠或登入資訊。"
        case .pairingFiles: return "請先選擇配對憑證與公開配置。"
        case .pairingPassword: return "請輸入有效的配對憑證密碼。"
        case .busy: return "目前有其他續簽操作，請稍後再試。"
        }
    }
    private func begin(_ operation: Operation) {
        guard action == nil else { return }
        switch operation {
        case .cancelAutomatic, .cancelAuthentication: break
        default: guard dependencies.selfRenewalOwner?.isWorking != true else { return }
        }
        inputProblem = nil; fileSelectionFailed = false; action = Action(operation: operation)
    }
    private func chooseFile(_ purpose: FilePurpose) {
        inputProblem = nil; fileSelectionFailed = false; filePurpose = purpose; selectingFile = true
    }
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
