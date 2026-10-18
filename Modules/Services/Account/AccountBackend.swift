import Foundation

/// Backend surface the app needs after sign-in: profile, avatar, subscription
/// and TestFlight. Two implementations exist — the existing Firebase SDK path
/// and the Gateway path — behind one protocol so no caller branches.
@MainActor
protocol AccountBackend: AnyObject {
    func fetchProfile(uid: String) async throws -> UserProfile?
    func upsertProfile(_ profile: UserProfile) async throws
    func uploadAvatar(data: Data) async throws -> URL
    /// Nil means the backend has no authoritative value (never "not Pro").
    /// Throws when the backend could not be reached.
    func refreshEntitlement(uid: String) async throws -> CachedSubscriptionEntitlement?
    func accountToken() async throws -> UUID
    func bind(signedTransaction: String) async throws -> CachedSubscriptionEntitlement
    func deleteSubscriptionAccountData() async throws
    func verifyTestFlightAccess() async throws -> Bool
    func requestTestFlightAccess(email: String) async throws -> TestFlightAccessResult
    func deleteRemoteData(uid: String) async throws
}

enum AccountBackendError: LocalizedError {
    case notAuthenticated
    case unsupportedOnGateway
    case invalidResponse
    case disabledForLocalReader

    var errorDescription: String? {
        if case .disabledForLocalReader = self {
            return localized("本地版本不提供應用程式帳號與雲端會員服務。")
        }
        return nil
    }
}

/// A disabled service rejects work instead of reporting a successful cloud
/// operation. Keeping this at the router also protects any retained callers.
@MainActor
private final class DisabledAccountBackend: AccountBackend {
    func fetchProfile(uid: String) async throws -> UserProfile? { throw AccountBackendError.disabledForLocalReader }
    func upsertProfile(_ profile: UserProfile) async throws { throw AccountBackendError.disabledForLocalReader }
    func uploadAvatar(data: Data) async throws -> URL { throw AccountBackendError.disabledForLocalReader }
    func refreshEntitlement(uid: String) async throws -> CachedSubscriptionEntitlement? { throw AccountBackendError.disabledForLocalReader }
    func accountToken() async throws -> UUID { throw AccountBackendError.disabledForLocalReader }
    func bind(signedTransaction: String) async throws -> CachedSubscriptionEntitlement { throw AccountBackendError.disabledForLocalReader }
    func deleteSubscriptionAccountData() async throws { throw AccountBackendError.disabledForLocalReader }
    func verifyTestFlightAccess() async throws -> Bool { throw AccountBackendError.disabledForLocalReader }
    func requestTestFlightAccess(email: String) async throws -> TestFlightAccessResult { throw AccountBackendError.disabledForLocalReader }
    func deleteRemoteData(uid: String) async throws { throw AccountBackendError.disabledForLocalReader }
}

@MainActor
final class AccountBackendRouter {
    static let shared = AccountBackendRouter()

    private(set) lazy var firebase = FirebaseAccountBackend()
    private(set) lazy var gateway = GatewayAccountBackend()
    private let disabled = DisabledAccountBackend()
    private let accountServicesEnabled: Bool

    init(accountServicesEnabled: Bool = ReaderExperienceConfiguration.accountServicesEnabled) {
        self.accountServicesEnabled = accountServicesEnabled
    }

    /// Effective backend for the live session. The Gateway session store is the
    /// source of truth: profile/avatar/subscription calls only happen while
    /// signed in, and a Gateway session means those calls must not touch
    /// Google-hosted endpoints.
    var current: AccountBackend {
        guard accountServicesEnabled else { return disabled }
        return GatewaySessionStore.shared.hasSession ? gateway : firebase
    }

    func backend(for route: AuthRoute) -> AccountBackend {
        guard accountServicesEnabled else { return disabled }
        return route == .gateway ? gateway : firebase
    }
}
