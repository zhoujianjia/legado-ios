import Foundation
import Observation

/// One App-lifetime observable owner, injected into Settings and the reader's
/// existing handoff DI. Initialization is O(1); the App task admits bootstrap.
@MainActor @Observable
final class SelfRenewalAppOwner {
    enum Problem: Equatable {
        case invalidConfiguration, configurationInUse, signingMaterials
        case authenticationNotConfigured, authenticationUnavailable, localStorage
        case operationFailed, cancelled
    }
    struct InitializationFailureObservation: Sendable, Equatable, Encodable {
        let occurredAt: Date
        let errorType: String
        let failureCode: String
    }
    enum DiagnosticOperation: String, Sendable, Equatable, Encodable {
        case persistenceBinding, bootstrap, pairingImport, configurationImport, initialization
        case packagePreparation, installationSubmission, recovery, providerConfiguration, providerReset
        case signIn, verification, loginCancellation, accountObservation
        case materialRefresh, materialReconciliation, publicationFinalization, signOut, automaticRenewal
    }
    struct OperationFailureObservation: Sendable, Equatable, Encodable {
        let occurredAt: Date
        let operation: DiagnosticOperation
        let failure: SelfRenewalDiagnosticFailure
    }
    let handoff: SelfRenewalUserDataHandoff
    /// Explicit provider configuration/injection only, never Apple authority.
    private(set) var developerServicesConfigured: Bool
    private(set) var anisetteProvider: SelfRenewalAnisetteV3Configuration?
    private(set) var anisetteRegistration: SelfRenewalAnisetteV3Provider.RegistrationObservation?
    private(set) var anisetteRegistrationProblem: Problem?
    private let session: SelfRenewalAppSession
    private let clock: @Sendable () -> Date
    private(set) var status: SelfRenewalAppSession.Status?
    private(set) var problem: Problem?
    private(set) var signingMaterialProblem: Problem?
    private(set) var initializationFailure: InitializationFailureObservation?
    /// Passive status refreshes do not erase the latest explicit action failure.
    private(set) var operationFailure: OperationFailureObservation?
    private(set) var isWorking = false {
        didSet { if !isWorking { resumeForegroundWaiters() } }
    }
    enum ExecutionPhase: Equatable, Sendable { case active, inactive, background }
    @ObservationIgnored private var executionPhase = ExecutionPhase.inactive
    @ObservationIgnored private var foregroundGeneration = UUID()
    @ObservationIgnored private var requestedActivationGeneration: UUID?
    @ObservationIgnored private var foregroundWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var recoveryAvailable = false
    private(set) var developerSession: SelfRenewalDeveloperAccountClient.SessionObservation?
    private(set) var developerMaterial: SelfRenewalAppSession.DeveloperMaterialObservation?
    private(set) var developerChallenge: SelfRenewalDeveloperAuthentication.Challenge?
    private var developerOperationID: UUID?
    private var authenticatingOperationID: UUID?
    private var bootstrapped = false
    private(set) var automaticRenewal: SelfRenewalAppSession.AutomaticRenewalObservation?
    private enum AutomaticTrigger { case foreground(UUID), systemBackground }
    private struct AutomaticOperation {
        let trigger: AutomaticTrigger
        let id: UUID
        let task: Task<SelfRenewalAppSession.AutomaticRenewalObservation, Error>
    }
    private var automaticOperation: AutomaticOperation?
    private struct PairingImportOperation {
        let id: UUID
        let task: Task<SelfRenewalAppSession.Status, Error>
    }
    private var pairingImportOperation: PairingImportOperation?
    private var automaticSchedule: (@MainActor (Date?) -> Void)?

    init(root: URL? = nil, developerServices: SelfRenewalAppSession.DeveloperServices? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }) {
        handoff = SelfRenewalUserDataHandoff(clock: clock)
        self.clock = clock
        developerServicesConfigured = developerServices != nil
        session = SelfRenewalAppSession(root: root, developerServices: developerServices, clock: clock)
    }
    #if DEBUG
    @ObservationIgnored private var bootstrapObservation: (@Sendable () async -> Void)?
    @ObservationIgnored private var automaticWorkerObservation: (@Sendable () async -> Void)?
    @ObservationIgnored private var foregroundWaitObservation: (@MainActor () -> Void)?
    /// Only owned tests choose another verified application directory. This
    /// parameter is absent from configuration and production initialization.
    init(root: URL, currentApplicationRoot: URL, developerServices: SelfRenewalAppSession.DeveloperServices? = nil,
        publicationFault: SelfRenewalAppSession.PublicationFault? = nil,
        initialNamespaceStorage: any SelfRenewalSigningManifestStorage = SelfRenewalSigningKeychainManifestStorage(),
        bootstrapObservation: (@Sendable () async -> Void)? = nil,
        automaticWorkerObservation: (@Sendable () async -> Void)? = nil,
        foregroundWaitObservation: (@MainActor () -> Void)? = nil,
        developerAuthenticationRandom: @escaping @Sendable () throws -> Data = SelfRenewalGSASRP.randomExponent,
        clock: @escaping @Sendable () -> Date = { Date() }) {
        handoff = SelfRenewalUserDataHandoff(clock: clock)
        self.clock = clock
        developerServicesConfigured = developerServices != nil
        self.bootstrapObservation = bootstrapObservation
        self.automaticWorkerObservation = automaticWorkerObservation
        self.foregroundWaitObservation = foregroundWaitObservation
        session = SelfRenewalAppSession(root: root, currentApplicationRoot: currentApplicationRoot,
            developerServices: developerServices, publicationFault: publicationFault,
            initialNamespaceStorage: initialNamespaceStorage,
            developerAuthenticationRandom: developerAuthenticationRandom, clock: clock)
    }
    #endif

    /// Synchronous scene facts are recorded before App lifecycle Tasks are queued.
    /// Repeated reads of the same phase keep the same epoch; late Tasks cannot
    /// announce active on behalf of an obsolete scene event.
    @discardableResult func noteScenePhase(_ phase: ExecutionPhase) -> UUID {
        if executionPhase != phase {
            executionPhase = phase
            foregroundGeneration = UUID()
            resumeForegroundWaiters()
        }
        return foregroundGeneration
    }
    private func acceptsForeground(_ generation: UUID) -> Bool {
        !Task.isCancelled && executionPhase == .active && foregroundGeneration == generation
    }
    private func reserveActivation(_ generation: UUID?) -> UUID? {
        let generation = generation ?? foregroundGeneration
        guard acceptsForeground(generation), requestedActivationGeneration != generation else { return nil }
        requestedActivationGeneration = generation
        return generation
    }
    private func resumeForegroundWaiters() {
        let waiters = foregroundWaiters
        foregroundWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    private func foregroundAvailable(_ generation: UUID) async -> Bool {
        while isWorking {
            guard acceptsForeground(generation) else { return false }
            await withCheckedContinuation {
                foregroundWaiters.append($0)
                #if DEBUG
                foregroundWaitObservation?()
                #endif
            }
        }
        return acceptsForeground(generation)
    }

    func start(books: BookStore, sources: BookSourceStore, positions: any ReadingPositionStore,
        automatically: Bool = true, foregroundGeneration: UUID? = nil) async {
        do { try handoff.bind(books: books, sources: sources, positions: positions) }
        catch {
            problem = .operationFailed
            recordFailure(error, operation: .persistenceBinding, context: "Renewal App persistence binding unavailable")
            return
        }
        let generation = automatically ? reserveActivation(foregroundGeneration) : nil
        await bootstrap()
        if let generation, await foregroundAvailable(generation) {
            await runAutomaticRenewal(.foreground(generation))
        }
    }

    /// Called only after the App binds its actual BookStore, BookSourceStore and
    /// position owner. No network or authentication UI is opened during startup.
    func bootstrap() async {
        guard !isWorking else { return }
        isWorking = true; defer { isWorking = false }
        problem = nil
        do {
            status = try await session.bootstrap(handoff: handoff)
            developerMaterial = await session.developerMaterialObservation()
            // Owner facts only; this does not prove that Settings rendered them.
            AppLogger.parse("Renewal material observation point=bootstrap signingAccess=\(status?.access == .signing) materialPresent=\(developerMaterial != nil) expiryPresent=\(developerMaterial?.profileExpiresAt != nil)")
            #if DEBUG
            await bootstrapObservation?()
            #endif
            bootstrapped = true
        } catch {
            status = await session.status()
            developerMaterial = nil
            problem = Self.classify(error)
            bootstrapped = false
            recordFailure(error, operation: .bootstrap, context: "Renewal App bootstrap unavailable", preserveAction: true)
        }
        recoveryAvailable = await session.recoveryIsAvailable()
        signingMaterialProblem = await session.signingMaterialFailure() == nil ? nil : .signingMaterials
        automaticRenewal = await session.automaticRenewalObservation()
        developerServicesConfigured = await session.developerServicesAreConfigured()
        anisetteProvider = await session.configuredAnisetteProvider()
        await refreshAnisetteRegistration()
        scheduleAutomaticRenewal()
    }

    /// Foreground preserves normal material observations and then attempts the
    /// same opt-in, durably throttled renewal use case. A foreground is never
    /// cold-launch or installation evidence.
    func becameActive(generation: UUID? = nil) async {
        guard let generation = reserveActivation(generation),
              await foregroundAvailable(generation) else { return }
        await bootstrap()
        guard acceptsForeground(generation) else { return }
        await runAutomaticRenewal(.foreground(generation))
    }

    func installAutomaticScheduling(_ schedule: @escaping @MainActor (Date?) -> Void) {
        automaticSchedule = schedule
        scheduleAutomaticRenewal()
    }
    func enteredBackground(generation: UUID? = nil) async {
        let generation = generation ?? foregroundGeneration
        guard executionPhase == .background, foregroundGeneration == generation else { return }
        // A real BGProcessingTask owns a distinct runtime grant. Scene cleanup
        // only cancels foreground work, then awaits the existing full drain.
        if let operation = automaticOperation, case .foreground = operation.trigger {
            operation.task.cancel()
            let result = await operation.task.result
            await finishAutomaticOperation(operation.id, result: result)
        }
        guard executionPhase == .background, foregroundGeneration == generation else { return }
        await cancelPairingIdentityImport()
        scheduleAutomaticRenewal()
    }
    func setAutomaticRenewalEnabled(_ enabled: Bool) async {
        let generation = foregroundGeneration
        if !enabled { await cancelAutomaticRenewal() }
        guard !isWorking else { return }
        isWorking = true
        do { automaticRenewal = try await session.setAutomaticRenewalEnabled(enabled); problem = nil }
        catch { problem = Self.classify(error) }
        isWorking = false
        scheduleAutomaticRenewal()
        if enabled, acceptsForeground(generation) {
            await runAutomaticRenewal(.foreground(generation))
        }
    }
    /// Both foreground and a system-granted BGProcessingTask await this exact
    /// owned worker. A caller cancellation is forwarded, then fully drained.
    @discardableResult func runAutomaticRenewalNow() async -> Bool {
        await runAutomaticRenewal(.foreground(foregroundGeneration))
    }
    /// Only the existing BGTask bridge calls this while its system task is live.
    /// Expiration cancellation still reaches and drains the exact same worker.
    @discardableResult func runAutomaticRenewalWithBackgroundGrant() async -> Bool {
        await runAutomaticRenewal(.systemBackground)
    }
    @discardableResult private func runAutomaticRenewal(_ trigger: AutomaticTrigger) async -> Bool {
        guard !isWorking, !Task.isCancelled else { return false }
        if case .foreground(let generation) = trigger {
            guard acceptsForeground(generation) else { return false }
        }
        isWorking = true
        // Preserve bootstrap failures while the shared worker observes disabled.
        // Session still owns local checks, cancellation and the disabled result.
        if automaticRenewal?.isEnabled != false { problem = nil }
        let id = UUID(), session = self.session, handoff = self.handoff
        #if DEBUG
        let observation = automaticWorkerObservation
        #endif
        let worker = Task {
            #if DEBUG
            await observation?()
            #endif
            return try await session.runAutomaticRenewal(handoff: handoff)
        }
        automaticOperation = AutomaticOperation(trigger: trigger, id: id, task: worker)
        let result = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
        await finishAutomaticOperation(id, result: result)
        switch result {
        case .success(let observed):
            return [.disabled, .waiting, .receiptObserved].contains(observed.outcome)
        case .failure: return false
        }
    }
    func cancelAutomaticRenewal() async {
        guard let operation = automaticOperation else { return }
        operation.task.cancel()
        let result = await operation.task.result
        await finishAutomaticOperation(operation.id, result: result)
    }
    private func finishAutomaticOperation(_ id: UUID,
        result: Result<SelfRenewalAppSession.AutomaticRenewalObservation, Error>) async {
        guard automaticOperation?.id == id else { return }
        let observed = await session.automaticRenewalObservation()
        let status = await session.status()
        let recovery = await session.recoveryIsAvailable()
        let material = await session.signingMaterialFailure()
        guard automaticOperation?.id == id else { return }
        automaticRenewal = observed; self.status = status
        recoveryAvailable = recovery; signingMaterialProblem = material == nil ? nil : .signingMaterials
        if case .failure(let error) = result {
            problem = Self.classify(error)
            recordFailure(error, operation: .automaticRenewal, context: "Renewal automatic operation unavailable", preserveAction: true)
        }
        automaticOperation = nil; isWorking = false
        scheduleAutomaticRenewal()
    }
    private func scheduleAutomaticRenewal() {
        automaticSchedule?(automaticRenewal?.isEnabled == true ? automaticRenewal?.nextEligibleAt : nil)
    }

    /// One service call owns both file scopes and the temporary password.
    /// Callers clear their password input after this awaited operation returns.
    @discardableResult
    func importPairingIdentity(pkcs12: URL, password: String, publicConfiguration: URL) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        problem = nil; operationFailure = nil
        let id = UUID(), session = self.session, handoff = self.handoff
        let worker = Task {
            try await session.importPairingIdentity(pkcs12: pkcs12, password: password,
                publicConfiguration: publicConfiguration, handoff: handoff)
        }
        pairingImportOperation = PairingImportOperation(id: id, task: worker)
        let result = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
        await finishPairingIdentityImport(id, result: result)
        // Busy admission and unrelated owner observations are not evidence
        // that this import committed. Return this exact awaited worker result.
        if case .success = result { return true }
        return false
    }

    func cancelPairingIdentityImport() async {
        guard let operation = pairingImportOperation else { return }
        operation.task.cancel()
        let result = await operation.task.result
        await finishPairingIdentityImport(operation.id, result: result)
    }

    private func finishPairingIdentityImport(_ id: UUID,
        result: Result<SelfRenewalAppSession.Status, Error>) async {
        guard pairingImportOperation?.id == id else { return }
        let finalStatus: SelfRenewalAppSession.Status?
        switch result {
        case .success(let observed): finalStatus = observed
        case .failure: finalStatus = await session.status()
        }
        let recovery = await session.recoveryIsAvailable()
        let material = await session.signingMaterialFailure()
        guard pairingImportOperation?.id == id else { return }
        status = finalStatus
        switch result {
        case .success:
            bootstrapped = true
        case .failure(let error):
            problem = Self.classify(error)
            recordFailure(error, operation: .pairingImport, context: "Renewal pairing identity import unavailable")
        }
        // A failed durable ACK can already have invalidated Session's epoch.
        // Re-observation obtains any account facts still usable after import.
        developerSession = nil; developerMaterial = nil; developerChallenge = nil
        recoveryAvailable = recovery; signingMaterialProblem = material == nil ? nil : .signingMaterials
        pairingImportOperation = nil; isWorking = false
    }

    func importConfiguration(_ url: URL) async {
        guard !isWorking else { return }
        isWorking = true; defer { isWorking = false }
        problem = nil; operationFailure = nil
        do {
            status = try await session.configure(from: url, handoff: handoff)
            developerMaterial = await session.developerMaterialObservation()
            bootstrapped = true
        } catch {
            status = await session.status()
            problem = Self.classify(error)
            recordFailure(error, operation: .configurationImport, context: "Renewal configuration unavailable")
        }
        recoveryAvailable = await session.recoveryIsAvailable()
        signingMaterialProblem = await session.signingMaterialFailure() == nil ? nil : .signingMaterials
    }

    func initializeConfiguration(from url: URL) async {
        guard !isWorking else { return }
        isWorking = true; defer { isWorking = false }
        problem = nil; initializationFailure = nil; operationFailure = nil
        do {
            status = try await session.initializeSigningNamespace(from: url)
            developerMaterial = await session.developerMaterialObservation()
            bootstrapped = true
        } catch {
            status = await session.status()
            problem = Self.classify(error)
            let failure = SelfRenewalDiagnosticFailure.capture(error)
            initializationFailure = InitializationFailureObservation(occurredAt: clock(), errorType: failure.errorType,
                failureCode: failure.failureCode)
            recordFailure(error, operation: .initialization, context: "Renewal namespace initialization unavailable")
        }
        recoveryAvailable = await session.recoveryIsAvailable()
        signingMaterialProblem = await session.signingMaterialFailure() == nil ? nil : .signingMaterials
    }

    /// Preparing an imported IPA never uploads or submits it. The session owns
    /// the security scope, original input verification and durable candidate.
    func prepareRenewal(from ipa: URL) async {
        guard !isWorking else { return }
        isWorking = true; defer { isWorking = false }
        problem = nil; operationFailure = nil
        do { status = try await session.prepareRenewal(from: ipa) }
        catch {
            status = await session.status()
            problem = Self.classify(error)
            recordFailure(error, operation: .packagePreparation, context: "Renewal preparation unavailable")
        }
        recoveryAvailable = await session.recoveryIsAvailable()
        signingMaterialProblem = await session.signingMaterialFailure() == nil ? nil : .signingMaterials
    }

    /// A separate local-only action uses the same session and preparation
    /// failure observation as an explicitly imported IPA.
    func prepareCurrentApplicationRenewal() async {
        guard !isWorking else { return }
        isWorking = true; defer { isWorking = false }
        problem = nil; operationFailure = nil
        do { status = try await session.prepareCurrentApplicationRenewal() }
        catch {
            status = await session.status()
            problem = Self.classify(error)
            recordFailure(error, operation: .packagePreparation, context: "Renewal current application preparation unavailable")
        }
        recoveryAvailable = await session.recoveryIsAvailable()
        signingMaterialProblem = await session.signingMaterialFailure() == nil ? nil : .signingMaterials
    }

    /// A separate user action reaches the actual Coordinator hook with this
    /// owner's same BookStore, source and reading-position handoff instance.
    func submitPreparedRenewal() async {
        guard !isWorking else { return }
        isWorking = true; defer { isWorking = false }
        problem = nil; operationFailure = nil
        do { status = try await session.submitPreparedRenewal(handoff: handoff) }
        catch {
            status = await session.status()
            problem = Self.classify(error)
            recordFailure(error, operation: .installationSubmission, context: "Renewal submission unavailable")
        }
        recoveryAvailable = await session.recoveryIsAvailable()
        signingMaterialProblem = await session.signingMaterialFailure() == nil ? nil : .signingMaterials
    }

    func recoverExplicitly() async {
        guard !isWorking else { return }
        isWorking = true; defer { isWorking = false }
        problem = nil; operationFailure = nil
        do { status = try await session.recoverExplicitly(handoff: handoff) }
        catch {
            status = await session.status()
            problem = Self.classify(error)
            recordFailure(error, operation: .recovery, context: "Renewal recovery unavailable")
        }
        recoveryAvailable = await session.recoveryIsAvailable()
        signingMaterialProblem = await session.signingMaterialFailure() == nil ? nil : .signingMaterials
    }

    /// The Settings UI supplies an explicitly trusted HTTPS endpoint or nil.
    /// Persisting the selection does not connect to that provider or to Apple.
    @discardableResult
    func configureAnisetteProvider(endpoint: URL?) async -> Bool {
        guard canTakeDeveloperAuthentication else { return false }
        let id = takeDeveloperAuthentication()
        defer { finishDeveloperOperation(id) }
        problem = nil
        var committed = false
        do {
            let value = try endpoint.map { try SelfRenewalAnisetteV3Configuration(endpoint: $0) }
            try await session.configureAnisetteProvider(value)
            guard developerOperationID == id else { return false }
            developerSession = nil; developerMaterial = nil; developerChallenge = nil
            committed = true
        } catch {
            guard developerOperationID == id else { return false }
            problem = Self.classify(error)
            recordFailure(error, operation: .providerConfiguration, context: "Renewal anisette configuration unavailable")
        }
        anisetteProvider = await session.configuredAnisetteProvider()
        developerServicesConfigured = await session.developerServicesAreConfigured()
        await refreshAnisetteRegistration()
        return committed && developerOperationID == id
    }

    /// Local, read-only phase for Settings. It never allocates an identity or
    /// constructs a transport; an unreadable record clears the old observation.
    func observeAnisetteRegistration() async {
        guard !isWorking else { return }
        isWorking = true; defer { isWorking = false }
        await refreshAnisetteRegistration()
    }

    /// Call only after the UI's explicit confirmation. An admitted reset signs
    /// out the developer account and requires a fresh user login, even if a
    /// later reset write fails. It never starts provisioning or deletes a
    /// completed registration blob, signing material or pending transaction.
    func resetUnknownAnisetteRegistration() async {
        guard canTakeDeveloperAuthentication else { return }
        let id = takeDeveloperAuthentication()
        defer { finishDeveloperOperation(id) }
        problem = nil
        do {
            anisetteRegistration = try await session.resetUnknownAnisetteRegistration()
            guard developerOperationID == id else { return }
        } catch {
            guard developerOperationID == id else { return }
            problem = Self.classify(error)
            recordFailure(error, operation: .providerReset, context: "Renewal anisette reset unavailable")
        }
        // Credential removal may have committed before a later reset failure.
        developerSession = nil; developerMaterial = nil; developerChallenge = nil
        await refreshAnisetteRegistration()
    }

    private func refreshAnisetteRegistration() async {
        do {
            anisetteRegistration = try await session.observeAnisetteRegistration()
            anisetteRegistrationProblem = nil
        } catch {
            anisetteRegistration = nil
            anisetteRegistrationProblem = Self.classify(error)
            AppLogger.parse("Renewal anisette phase unavailable type=\(String(reflecting: type(of: error)))")
        }
    }

    /// UI receives only a verified session observation or a bounded challenge.
    /// Password/code inputs stay in the actual session-owned login task.
    func signInDeveloperAccount(appleID: String, password: String) async {
        guard !isWorking else { return }
        let id = beginDeveloperAuthentication()
        defer { finishDeveloperOperation(id) }
        do {
            let outcome = try await session.signInDeveloperAccount(appleID: appleID, password: password)
            guard developerOperationID == id else { return }
            applyDeveloperAuthentication(outcome)
        } catch {
            guard developerOperationID == id else { return }
            problem = Self.classify(error)
            recordFailure(error, operation: .signIn, context: "Renewal account login unavailable")
        }
        await refreshAnisetteRegistration()
    }

    func submitDeveloperVerificationCode(_ code: String, challengeID: UUID) async {
        guard !isWorking else { return }
        let id = beginDeveloperAuthentication()
        defer { finishDeveloperOperation(id) }
        do {
            let outcome = try await session.submitDeveloperVerificationCode(code, challengeID: challengeID)
            guard developerOperationID == id else { return }
            applyDeveloperAuthentication(outcome)
        } catch {
            guard developerOperationID == id else { return }
            problem = Self.classify(error)
            recordFailure(error, operation: .verification, context: "Renewal verification unavailable")
        }
        await refreshAnisetteRegistration()
    }

    func cancelDeveloperAuthentication() async {
        guard canTakeDeveloperAuthentication else { return }
        let id = takeDeveloperAuthentication()
        defer { finishDeveloperOperation(id) }
        problem = nil; developerChallenge = nil
        do {
            let cancelled = try await session.cancelDeveloperAuthentication()
            guard developerOperationID == id else { return }
            if let confirmed = cancelled.confirmedSession { developerSession = confirmed }
        } catch {
            guard developerOperationID == id else { return }
            problem = Self.classify(error)
            recordFailure(error, operation: .loginCancellation, context: "Renewal login cancellation unavailable")
        }
        await refreshAnisetteRegistration()
    }

    private func beginDeveloperAuthentication() -> UUID {
        let id = takeDeveloperAuthentication()
        authenticatingOperationID = id
        problem = nil; developerSession = nil; developerChallenge = nil; operationFailure = nil
        return id
    }
    private var canTakeDeveloperAuthentication: Bool {
        !isWorking || (developerOperationID != nil && authenticatingOperationID == developerOperationID)
    }
    private func takeDeveloperAuthentication() -> UUID {
        let id = UUID()
        developerOperationID = id; authenticatingOperationID = nil; isWorking = true
        operationFailure = nil
        return id
    }
    private func finishDeveloperOperation(_ id: UUID) {
        guard developerOperationID == id else { return }
        developerOperationID = nil; authenticatingOperationID = nil; isWorking = false
    }
    private func applyDeveloperAuthentication(_ outcome: SelfRenewalDeveloperAuthentication.Outcome) {
        switch outcome {
        case .connected(let observed): developerSession = observed; developerChallenge = nil
        case .verificationRequired(let challenge): developerSession = nil; developerChallenge = challenge
        }
    }

    func observeDeveloperAccount() async {
        guard !isWorking else { return }
        isWorking = true; defer { isWorking = false }
        problem = nil; developerSession = nil; operationFailure = nil
        do { developerSession = try await session.observeDeveloperAccount() }
        catch {
            problem = Self.classify(error)
            recordFailure(error, operation: .accountObservation, context: "Renewal account observation unavailable")
        }
    }

    func refreshDeveloperMaterials(machineName: String) async {
        guard !isWorking else { return }
        isWorking = true; defer { isWorking = false }
        problem = nil; operationFailure = nil
        do { developerMaterial = try await session.refreshDeveloperMaterials(machineName: machineName) }
        catch let failure as SelfRenewalAppSession.DeveloperMaterialFinalizationFailure {
            developerMaterial = failure.published
            problem = Self.classify(failure.underlying)
            recordFailure(failure, operation: .materialRefresh, context: "Renewal account material refresh finalization unavailable")
        } catch {
            problem = Self.classify(error)
            recordFailure(error, operation: .materialRefresh, context: "Renewal account material refresh unavailable")
        }
        await synchronizeDeveloperMaterialState()
    }

    /// A separate explicit action preserves pending intent instead of calling
    /// refresh again. Only the same session/coordinator may recover materials.
    func reconcileDeveloperMaterials() async {
        guard !isWorking else { return }
        isWorking = true; defer { isWorking = false }
        problem = nil; operationFailure = nil
        do { developerMaterial = try await session.reconcileDeveloperMaterials() }
        catch let failure as SelfRenewalAppSession.DeveloperMaterialFinalizationFailure {
            developerMaterial = failure.published
            problem = Self.classify(failure.underlying)
            recordFailure(failure, operation: .materialReconciliation, context: "Renewal account material reconciliation finalization unavailable")
        } catch {
            problem = Self.classify(error)
            recordFailure(error, operation: .materialReconciliation, context: "Renewal account material reconciliation unavailable")
        }
        await synchronizeDeveloperMaterialState()
    }

    func finalizeDeveloperMaterialPublication() async {
        guard !isWorking else { return }
        isWorking = true; defer { isWorking = false }
        problem = nil; operationFailure = nil
        do { developerMaterial = try await session.finalizeDeveloperMaterialPublication() }
        catch let failure as SelfRenewalAppSession.DeveloperMaterialFinalizationFailure {
            developerMaterial = failure.published
            problem = Self.classify(failure.underlying)
            recordFailure(failure, operation: .publicationFinalization, context: "Renewal account publication finalization unavailable")
        } catch {
            problem = Self.classify(error)
            recordFailure(error, operation: .publicationFinalization, context: "Renewal account publication observation unavailable")
        }
        await synchronizeDeveloperMaterialState()
    }

    private func synchronizeDeveloperMaterialState() async {
        status = await session.status()
        recoveryAvailable = await session.recoveryIsAvailable()
        signingMaterialProblem = await session.signingMaterialFailure() == nil ? nil : .signingMaterials
    }

    /// Fixed codes and numeric protocol statuses only. Associated paths,
    /// identities, credentials and server messages never enter this surface.
    private func recordFailure(_ error: Error, operation: DiagnosticOperation, context: String,
        preserveAction: Bool = false) {
        let failure = SelfRenewalDiagnosticFailure.capture(error)
        if !preserveAction || operationFailure == nil {
            operationFailure = OperationFailureObservation(occurredAt: clock(), operation: operation, failure: failure)
        }
        var fields = ["type=\(failure.errorType)", "code=\(failure.failureCode)", "phase=\(operation.rawValue)"]
        if let cause = failure.causeType { fields.append("causeType=\(cause)") }
        if let status = failure.httpStatus { fields.append("httpStatus=\(status)") }
        if let status = failure.osStatus { fields.append("osStatus=\(status)") }
        AppLogger.parse(context + " " + fields.joined(separator: " "), level: .error)
    }

    func signOutDeveloperAccount() async {
        guard canTakeDeveloperAuthentication else { return }
        let id = takeDeveloperAuthentication()
        defer { finishDeveloperOperation(id) }
        problem = nil; developerSession = nil; developerChallenge = nil
        do { try await session.signOutDeveloperAccount() }
        catch {
            guard developerOperationID == id else { return }
            problem = Self.classify(error)
            recordFailure(error, operation: .signOut, context: "Renewal account sign-out unavailable")
        }
    }

    func close() async throws {
        noteScenePhase(.inactive)
        await cancelAutomaticRenewal()
        await cancelPairingIdentityImport()
        guard !isWorking else { throw SelfRenewalAppSession.Failure.busy }
        isWorking = true; defer { isWorking = false }
        try await session.close()
        status = nil; problem = nil; signingMaterialProblem = nil; recoveryAvailable = false; bootstrapped = false
        initializationFailure = nil; operationFailure = nil
        developerSession = nil; developerMaterial = nil; developerChallenge = nil
        anisetteProvider = nil
        anisetteRegistration = nil; anisetteRegistrationProblem = nil
        developerServicesConfigured = await session.developerServicesAreConfigured()
        automaticRenewal = nil; automaticSchedule?(nil)
    }

    private static func classify(_ error: Error) -> Problem {
        if error is CancellationError { return .cancelled }
        if error is SelfRenewalApplicationMaterialVerifier.Failure { return .signingMaterials }
        if let failure = error as? SelfRenewalAnisetteV3Provider.Failure {
            switch failure {
            case .invalidConfiguration: return .invalidConfiguration
            case .storage, .storageUnavailable, .staleRegistration, .resetCommitUnknown: return .localStorage
            case .resetNotRequired: return .operationFailed
            default: return .authenticationUnavailable
            }
        }
        if let failure = error as? SelfRenewalAppSession.RenewalExecutionFailure {
            if failure.statusPersistenceError != nil { return .localStorage }
            switch failure.problem {
            case .signingMaterials: return .signingMaterials
            case .storage: return .localStorage
            case .cancelled: return .cancelled
            case .authentication: return .authenticationNotConfigured
            case .configuration: return .invalidConfiguration
            case .observation: return classify(failure.underlying)
            }
        }
        if let failure = error as? SelfRenewalControlledRenewalCoordinator.PreparationFailure { return classify(failure.underlying) }
        if let failure = error as? SelfRenewalControlledRenewalCoordinator.Interrupted { return classify(failure.underlying) }
        if let failure = error as? SelfRenewalAuthenticatedInstallationClient.OperationFailure { return classify(failure.underlying) }
        if let failure = error as? SelfRenewalAuthenticatedInstallationClient.RegistrationCleanupFailure { return classify(failure.underlying) }
        if let failure = error as? SelfRenewalAuthenticatedInstallationClient.RegistrationFinalizationFailure<SelfRenewalSigningMaterialVault.Lease> {
            return classify(failure.stopSessionError)
        }
        if let failure = error as? SelfRenewalControlledRenewalCoordinator.Failure,
           failure == .signingMaterialsUnavailable { return .signingMaterials }
        if error is SelfRenewalAppSession.DeveloperServicesFailure { return .authenticationNotConfigured }
        if let failure = error as? SelfRenewalPairingIdentityImport.Failure {
            switch failure {
            case .invalidPublicConfiguration, .invalidPassword: return .invalidConfiguration
            case .keychain, .invalidPersistentReference: return .localStorage
            case .invalidPKCS12, .hostCertificateMismatch, .invalidCertificateChain, .keyPossession:
                return .authenticationUnavailable
            }
        }
        if error is SelfRenewalDeveloperAuthentication.Failure || error is SelfRenewalGSASRP.Failure { return .authenticationUnavailable }
        if let failure = error as? SelfRenewalAppSession.InitialNamespaceBindingFailure { return classify(failure.underlying) }
        if let failure = error as? SelfRenewalAppSession.DeveloperMaterialFinalizationFailure { return classify(failure.underlying) }
        if let failure = error as? SelfRenewalDeveloperAccountClient.EnrollmentFailure { return classify(failure.underlying) }
        if let failure = error as? SelfRenewalDeveloperAccountClient.PublicationFinalizationFailure { return classify(failure.underlying) }
        if let failure = error as? SelfRenewalDeveloperAccountClient.SessionInvalidationFailure { return classify(failure.storageError) }
        if let failure = error as? SelfRenewalDeveloperAccountClient.Failure {
            switch failure {
            case .storage: return .localStorage
            case .invalidInput, .limit: return .invalidConfiguration
            case .busy, .staleOperation, .reconciliationRequired: return .operationFailed
            default: return .authenticationUnavailable
            }
        }
        if let failure = error as? SelfRenewalAuthenticatedDeviceTransport.Failure, failure == .cancelled { return .cancelled }
        if let failure = error as? SelfRenewalAppSession.RecoveryFailed {
            if let error = failure.recoveryError { return classify(error) }
            if let error = failure.observationError { return classify(error) }
            return .operationFailed
        }
        if let failure = error as? SelfRenewalInstallationRecovery.RecoveryFailure { return classify(failure.underlying) }
        if let unavailable = error as? SelfRenewalAppSession.Unavailable {
            if unavailable.statusPersistenceError != nil { return .localStorage }
            switch unavailable.problem {
            case .signingMaterials: return .signingMaterials
            case .storage: return .localStorage
            case .configuration: return .invalidConfiguration
            case .authentication: return .authenticationUnavailable
            case .observation: return .operationFailed
            case .cancelled: return .cancelled
            }
        }
        if let failure = error as? SelfRenewalAppSession.Failure {
            switch failure {
            case .invalidConfiguration, .changedFile, .limit: return .invalidConfiguration
            case .configurationInUse: return .configurationInUse
            case .notConfigured: return .signingMaterials
            case .authenticationNotConfigured: return .authenticationNotConfigured
            case .identityUnavailable: return .authenticationUnavailable
            case .storage, .commitDurabilityUnknown: return .localStorage
            case .busy, .ownedApplicationIsNotCurrentProcess: return .operationFailed
            }
        }
        if error is SelfRenewalSigningMaterialVault.Failure { return .signingMaterials }
        if error is SelfRenewalTransactionJournal.Failure { return .localStorage }
        if error is KeychainHelper.ReadFailure || error is KeychainHelper.WriteFailure { return .localStorage }
        if error is SelfRenewalAppSession.InitializationFailure { return .localStorage }
        return .operationFailed
    }
}
