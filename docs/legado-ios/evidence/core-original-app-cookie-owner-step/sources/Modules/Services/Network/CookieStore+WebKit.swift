import Foundation
import WebKit

extension CookieStore {
    /// Begin on the Cookie actor, perform WebKit IPC on main, and commit back on
    /// the same actor. No main thread waits for persistence or copies the jar.
    func captureWebKit(_ store: WKHTTPCookieStore, confirming scope: URL? = nil,
                       requireCurrent: Bool = true,
                       validate: @escaping @Sendable () throws -> Void = {}) async throws -> [HTTPCookie] {
        let observation = try await beginWebKitObservation()
        try Task.checkCancellation()
        let cookies = await Self.readWebKit(store)
        try Task.checkCancellation()
        try await ingestWebKitSnapshot(cookies, observation: observation, confirming: scope,
            requireCurrent: requireCurrent, validate: validate)
        return cookies
    }

    @MainActor
    private static func readWebKit(_ store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
    }
}
