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
    let handoff: SelfRenewalUserDataHandoff
    private let session: SelfRenewalAppSession
    private(set) var status: SelfRenewalAppSession.Status?
    private(set) var problem: Problem?
    private(set) var signingMaterialProblem: Problem?
    private(set) var isWorking = false
    private(set) var recoveryAvailable = false
    private(set) var developerSession: SelfRenewalDeveloperAccountClient.SessionObservation?
    private(set) var developerMaterial: SelfRenewalAppSession.DeveloperMaterialObservation?
    private(set) var developerChallenge: SelfRenewalDeveloperAuthentication.Challenge?
    private var developerOperationID: UUID?
    private var authenticatingOperationID: UUID?
    private var bootstrapped = false

    init(root: URL? = nil, developerServices: SelfRenewalAppSession.DeveloperServices? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }) {
        handoff = SelfRenewalUserDataHandoff()
        session = SelfRenewalAppSession(root: root, developerServices: developerServices, clock: clock)
    }
    #if DEBUG
    /// Only owned tests choose another verified application directory. This
    /// parameter is absent from configuration and production initialization.
    init(root: URL, currentApplicationRoot: URL, developerServices: SelfRenewalAppSession.DeveloperServices? = nil,
        developerAuthenticationRandom: @escaping @Sendable () throws -> Data = SelfRenewalGSASRP.randomExponent,
        clock: @escaping @Sendable () -> Date = { Date() }) {
        handoff = SelfRenewalUserDataHandoff()
        session = SelfRenewalAppSession(root: root, currentApplicationRoot: currentApplicationRoot,
            developerServices: developerServices, developerAuthenticationRandom: developerAuthenticationRandom, clock: clock)
    }
    #endif

    func start(books: BookStore, sources: BookSourceStore, positions: any ReadingPositionStore) async {
        do { try handoff.bind(books: books, sources: sources, positions: positions) }
        catch {
            problem = .operationFailed
            AppLogger.parse("Renewal App persistence binding unavailable type=\(String(reflecting: type(of: error)))")
            return
        }
        await bootstrap()
    }

    /// Called only after the App binds its actual BookStore, BookSourceStore and
    /// position owner. No network or authentication UI is opened during startup.
    func bootstrap() async {
        guard !isWorking else { return }
        isWorking = true; defer { isWorking = false }
        problem = nil
        do {
            status = try await session.bootstrap(handoff: handoff)
            bootstrapped = true
        } catch {
            status = await session.status()
            problem = Self.classify(error)
            bootstrapped = false
            AppLogger.parse("Renewal App bootstrap unavailable type=\(String(reflecting: type(of: error)))")
        }
        recoveryAvailable = await session.recoveryIsAvailable()
        signingMaterialProblem = await session.signingMaterialFailure() == nil ? nil : .signingMaterials
    }

    /// Foreground observes the same process at most once through the existing
    /// coordinator proof guards. It never turns a foreground event into cold
    /// launch evidence, Lookup, remote cleanup, signing, or submission.
    func becameActive() async {
        guard bootstrapped, !isWorking else { return }
        await bootstrap()
    }

    func importConfiguration(_ url: URL) async {
        guard !isWorking else { return }
        isWorking = true; defer { isWorking = false }
        problem = nil
        do {
            status = try await session.configure(from: url, handoff: handoff)
            bootstrapped = true
        } catch {
            status = await session.status()
            problem = Self.classify(error)
            AppLogger.parse("Renewal configuration unavailable type=\(String(reflecting: type(of: error)))")
        }
        recoveryAvailable = await session.recoveryIsAvailable()
        signingMaterialProblem = await session.signingMaterialFailure() == nil ? nil : .signingMaterials
    }

    func recoverExplicitly() async {
        guard !isWorking else { return }
        isWorking = true; defer { isWorking = false }
        problem = nil
        do { status = try await session.recoverExplicitly(handoff: handoff) }
        catch {
            status = await session.status()
            problem = Self.classify(error)
            AppLogger.parse("Renewal recovery unavailable type=\(String(reflecting: type(of: error)))")
        }
        recoveryAvailable = await session.recoveryIsAvailable()
        signingMaterialProblem = await session.signingMaterialFailure() == nil ? nil : .signingMaterials
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
            AppLogger.parse("Renewal account login unavailable type=\(String(reflecting: type(of: error)))")
        }
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
            AppLogger.parse("Renewal verification unavailable type=\(String(reflecting: type(of: error)))")
        }
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
            AppLogger.parse("Renewal login cancellation unavailable type=\(String(reflecting: type(of: error)))")
        }
    }

    private func beginDeveloperAuthentication() -> UUID {
        let id = takeDeveloperAuthentication()
        authenticatingOperationID = id
        problem = nil; developerSession = nil; developerChallenge = nil
        return id
    }
    private var canTakeDeveloperAuthentication: Bool {
        !isWorking || (developerOperationID != nil && authenticatingOperationID == developerOperationID)
    }
    private func takeDeveloperAuthentication() -> UUID {
        let id = UUID()
        developerOperationID = id; authenticatingOperationID = nil; isWorking = true
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
        problem = nil; developerSession = nil
        do { developerSession = try await session.observeDeveloperAccount() }
        catch {
            problem = Self.classify(error)
            AppLogger.parse("Renewal account observation unavailable type=\(String(reflecting: type(of: error)))")
        }
    }

    func refreshDeveloperMaterials(machineName: String) async {
        guard !isWorking else { return }
        isWorking = true; defer { isWorking = false }
        problem = nil
        do { developerMaterial = try await session.refreshDeveloperMaterials(machineName: machineName) }
        catch let failure as SelfRenewalAppSession.DeveloperMaterialFinalizationFailure {
            developerMaterial = failure.published
            problem = Self.classify(failure.underlying)
        } catch {
            problem = Self.classify(error)
            AppLogger.parse("Renewal account material refresh unavailable type=\(String(reflecting: type(of: error)))")
        }
        status = await session.status()
        recoveryAvailable = await session.recoveryIsAvailable()
    }

    func finalizeDeveloperMaterialPublication() async {
        guard !isWorking else { return }
        isWorking = true; defer { isWorking = false }
        problem = nil
        do { developerMaterial = try await session.finalizeDeveloperMaterialPublication() }
        catch let failure as SelfRenewalAppSession.DeveloperMaterialFinalizationFailure {
            developerMaterial = failure.published
            problem = Self.classify(failure.underlying)
        } catch {
            problem = Self.classify(error)
            AppLogger.parse("Renewal account publication observation unavailable type=\(String(reflecting: type(of: error)))")
        }
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
            AppLogger.parse("Renewal account sign-out unavailable type=\(String(reflecting: type(of: error)))")
        }
    }

    func close() async throws {
        guard !isWorking else { throw SelfRenewalAppSession.Failure.busy }
        isWorking = true; defer { isWorking = false }
        try await session.close()
        status = nil; problem = nil; signingMaterialProblem = nil; recoveryAvailable = false; bootstrapped = false
        developerSession = nil; developerMaterial = nil; developerChallenge = nil
    }

    private static func classify(_ error: Error) -> Problem {
        if error is CancellationError { return .cancelled }
        if error is SelfRenewalAppSession.DeveloperServicesFailure { return .authenticationNotConfigured }
        if error is SelfRenewalDeveloperAuthentication.Failure || error is SelfRenewalGSASRP.Failure { return .authenticationUnavailable }
        if let failure = error as? SelfRenewalAppSession.DeveloperMaterialFinalizationFailure { return classify(failure.underlying) }
        if let failure = error as? SelfRenewalDeveloperAccountClient.EnrollmentFailure { return classify(failure.underlying) }
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
        if error is KeychainHelper.ReadFailure { return .localStorage }
        if error is SelfRenewalAppSession.InitializationFailure { return .localStorage }
        return .operationFailed
    }
}
