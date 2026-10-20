import Foundation
import WebKit

/// The existing WK change observer now sends fresh snapshots to the one durable
/// Cookie owner. Requests await its first observation; they never replay a
/// cached WK jar over a newer HTTP value. No per-request WebKit IPC is added.
final class WebViewCookieMirror: @unchecked Sendable {
    static let shared = WebViewCookieMirror()
    private let lock = NSLock()
    private var isPrimed = false
    private var lastFailure: Error?
    private var primingTask: (UUID, Task<Void, Error>)?
    private let observer = CookieStoreObserver()
    private init() {}

    func prepare() async throws {
        let pending: (UUID, Task<Void, Error>)? = lock.withLock {
            if isPrimed { return nil }
            if let primingTask { return primingTask }
            let id = UUID()
            let task = Task { [weak self] in
                guard let self else { throw CancellationError() }
                await self.observer.install()
                try await self.refresh()
            }
            primingTask = (id, task)
            return (id, task)
        }
        if let (id, task) = pending {
            do {
                try await task.value
                lock.withLock { if primingTask?.0 == id { primingTask = nil } }
            } catch {
                lock.withLock { if primingTask?.0 == id { primingTask = nil } }
                throw error
            }
        }
        if let failure = lock.withLock({ lastFailure }) { throw failure }
        try Task.checkCancellation()
    }

    func start() {
        Task {
            do { try await prepare() }
            catch { AppLogger.error("Browser Cookie observation failed", error: error) }
        }
    }

    fileprivate func refresh() async throws {
        do {
            // Retry only a real revision conflict, using a new WebKit snapshot
            // each time. There is no settling timer or stale-snapshot replay.
            for attempt in 0..<4 {
                do {
                    let store = await MainActor.run { WKWebsiteDataStore.default().httpCookieStore }
                    _ = try await CookieStore.shared.captureWebKit(store, requireCurrent: false)
                    lock.withLock { isPrimed = true; lastFailure = nil }
                    return
                } catch let error as CookieOwnerError where error.code == "STATE_CONFLICT" && attempt < 3 {
                    continue
                }
            }
        } catch {
            lock.withLock { lastFailure = error }
            throw error
        }
    }
}

private final class CookieStoreObserver: NSObject, WKHTTPCookieStoreObserver, @unchecked Sendable {
    private var isInstalled = false
    @MainActor
    func install() {
        guard !isInstalled else { return }
        isInstalled = true
        WKWebsiteDataStore.default().httpCookieStore.add(self)
    }
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task {
            do { try await WebViewCookieMirror.shared.refresh() }
            catch { AppLogger.error("Browser Cookie observation failed", error: error) }
        }
    }
}
