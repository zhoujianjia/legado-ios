import BackgroundTasks
import Foundation

/// Lifecycle adapter owned by the existing UIApplicationDelegate. It never
/// creates another session, BookStore, source store, or reading-position store.
@MainActor
final class SelfRenewalBackgroundTaskBridge {
    static let identifier = "com.yuedu.selfRenewal.processing"
    private var registered = false
    private var ownerID: ObjectIdentifier?
    private weak var owner: SelfRenewalAppOwner?
    private var start: (@MainActor () async -> Void)?
    private var pending: Runtime?
    private var scheduledDate: Date?

    /// A runtime is completed by one terminal owner after actual work drains.
    /// Expiration never reports completion while transport is still running.
    private final class Runtime {
        let systemTask: BGTask
        var worker: Task<Void, Never>?
        var expired = false
        var completed = false
        init(_ task: BGTask) { systemTask = task }
        func complete(_ success: Bool) {
            guard !completed else { return }
            completed = true; systemTask.expirationHandler = nil; worker = nil
            systemTask.setTaskCompleted(success: success && !expired)
        }
    }

    /// Registered before didFinishLaunching returns; initialization does no I/O.
    func register() {
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self else { task.setTaskCompleted(success: false); return }
                self.handle(task)
            }
        }
        if !registered { AppLogger.parse("Renewal background processing registration unavailable") }
    }

    /// App.body provides its already-existing StateObject identity, without
    /// moving BookStore's synchronous legacy initializer into App.init. If a
    /// background-only launch never creates a scene, no substitute store is
    /// opened: expiration fails that runtime and foreground remains available.
    func bind(owner: SelfRenewalAppOwner, books: BookStore,
        sources: BookSourceStore, positions: any ReadingPositionStore) {
        guard ownerID != ObjectIdentifier(owner) else { return }
        ownerID = ObjectIdentifier(owner); self.owner = owner
        start = { [weak owner] in
            await owner?.start(books: books, sources: sources, positions: positions, automatically: false)
        }
        owner.installAutomaticScheduling { [weak self] date in self?.schedule(date) }
        runPendingIfBound()
    }

    private func schedule(_ date: Date?) {
        guard registered else { return }
        guard let date else {
            scheduledDate = nil
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
            return
        }
        guard scheduledDate != date else { return }
        let request = BGProcessingTaskRequest(identifier: Self.identifier)
        request.earliestBeginDate = date
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        do { try BGTaskScheduler.shared.submit(request); scheduledDate = date }
        catch {
            scheduledDate = nil
            AppLogger.parse("Renewal background processing schedule unavailable type=\(String(reflecting: type(of: error)))")
        }
    }

    private func handle(_ task: BGTask) {
        guard task is BGProcessingTask, pending == nil else { task.setTaskCompleted(success: false); return }
        scheduledDate = nil
        let runtime = Runtime(task); pending = runtime
        task.expirationHandler = { [weak self, weak runtime] in
            Task { @MainActor in
                guard let self, let runtime, !runtime.completed else { return }
                runtime.expired = true
                if let worker = runtime.worker { worker.cancel() }
                else { runtime.complete(false); if self.pending === runtime { self.pending = nil } }
            }
        }
        runPendingIfBound()
    }
    private func runPendingIfBound() {
        guard let runtime = pending, runtime.worker == nil, !runtime.expired,
              let owner, let start else { return }
        runtime.worker = Task { [weak self] in
            await start()
            let success: Bool
            if Task.isCancelled { success = false }
            else { success = await owner.runAutomaticRenewalWithBackgroundGrant() }
            // The background-granted entry forwards cancellation and awaits the same
            // Session/Coordinator/stream workers before this single completion.
            runtime.complete(success && !Task.isCancelled)
            if self?.pending === runtime { self?.pending = nil }
        }
    }
}
