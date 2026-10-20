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
    private var bootstrapped = false

    init(root: URL? = nil, clock: @escaping @Sendable () -> Date = { Date() }) {
        handoff = SelfRenewalUserDataHandoff()
        session = SelfRenewalAppSession(root: root, clock: clock)
    }
    #if DEBUG
    /// Only owned tests choose another verified application directory. This
    /// parameter is absent from configuration and production initialization.
    init(root: URL, currentApplicationRoot: URL, clock: @escaping @Sendable () -> Date = { Date() }) {
        handoff = SelfRenewalUserDataHandoff()
        session = SelfRenewalAppSession(root: root, currentApplicationRoot: currentApplicationRoot, clock: clock)
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

    func close() async throws {
        guard !isWorking else { throw SelfRenewalAppSession.Failure.busy }
        isWorking = true; defer { isWorking = false }
        try await session.close()
        status = nil; problem = nil; signingMaterialProblem = nil; recoveryAvailable = false; bootstrapped = false
    }

    private static func classify(_ error: Error) -> Problem {
        if error is CancellationError { return .cancelled }
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
