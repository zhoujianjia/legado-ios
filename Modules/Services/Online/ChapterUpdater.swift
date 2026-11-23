import Foundation
import Observation

/// One observable object per book. A progress change never publishes the whole shelf.
@MainActor @Observable
final class BookshelfBookRefreshState {
    enum Phase: Equatable, Sendable {
        case idle, queued, refreshing, completed, failed, cancelled
    }
    fileprivate(set) var phase: Phase = .idle
}

struct BookshelfRefreshRequest: Hashable, Sendable {
    let bookID: UUID
    let sourceID: UUID?
    let needsInfoRefresh: Bool

    fileprivate var sourceKey: UUID { sourceID ?? bookID }
}

/// Owns refresh lifetimes and the book-scoped display states, not book content.
@MainActor
final class BookshelfRefreshCoordinator {
    static let shared = BookshelfRefreshCoordinator()
    private let maximumConcurrentBooks: Int
    private var batches: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var states: [UUID: BookshelfBookRefreshState] = [:]

    init(maximumConcurrentBooks: Int = AppConfig.startupRefreshMaxConcurrentTasks) {
        self.maximumConcurrentBooks = max(1, maximumConcurrentBooks)
    }

    func state(for bookID: UUID) -> BookshelfBookRefreshState {
        if let state = states[bookID] { return state }
        let state = BookshelfBookRefreshState()
        states[bookID] = state
        return state
    }

    func isRefreshing(owner: AnyObject) -> Bool { batches[ObjectIdentifier(owner)] != nil }

    /// Auto-refresh and pull-to-refresh of the same store join the same batch.
    /// Only its initiating task owns cancellation; cancelling a joiner does not
    /// tear down a refresh still owned by another caller.
    func refresh(owner: AnyObject, operation: @escaping @Sendable () async -> Void) async {
        let key = ObjectIdentifier(owner)
        if let batch = batches[key] {
            await batch.value
            return
        }
        guard !Task.isCancelled else { return }
        let task = Task.detached(priority: .utility) { await operation() }
        batches[key] = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        batches[key] = nil
    }

    /// Requests of one source are serialized before they consume worker slots.
    /// Other sources can therefore finish while one source is slow or limited;
    /// the existing request/JVM rate limiter still owns its finer source budget.
    nonisolated func refreshBooks(
        _ requests: [BookshelfRefreshRequest],
        operation: @escaping @Sendable (BookshelfRefreshRequest) async throws -> Void
    ) async {
        let width = await maximumConcurrentBooks
        var seen = Set<UUID>()
        let unique = requests.filter { seen.insert($0.bookID).inserted }
        var sourceIndexes: [UUID: Int] = [:]
        var queues: [[BookshelfRefreshRequest]] = []
        for request in unique {
            if let index = sourceIndexes[request.sourceKey] {
                queues[index].append(request)
            } else {
                sourceIndexes[request.sourceKey] = queues.count
                queues.append([request])
            }
            await setPhase(.queued, for: request.bookID)
        }
        await SourcePerfTrace.spanAsync("refresh.books", "books=\(unique.count) concurrency=\(width) main=\(Thread.isMainThread)") {
            await withTaskGroup(of: Int.self) { group in
                var offsets = Array(repeating: 0, count: queues.count)
                var ready = Array(queues.indices)
                var cursor = 0
                func dequeue() -> (source: Int, request: BookshelfRefreshRequest)? {
                    guard !Task.isCancelled, cursor < ready.count else { return nil }
                    let source = ready[cursor]
                    cursor += 1
                    let request = queues[source][offsets[source]]
                    offsets[source] += 1
                    return (source, request)
                }
                for _ in 0..<min(width, queues.count) {
                    if let next = dequeue() {
                        group.addTask {
                            await self.refreshBook(next.request, operation: operation)
                            return next.source
                        }
                    }
                }
                while let source = await group.next() {
                    if Task.isCancelled {
                        group.cancelAll()
                    } else {
                        if offsets[source] < queues[source].count { ready.append(source) }
                        if let next = dequeue() {
                            group.addTask {
                                await self.refreshBook(next.request, operation: operation)
                                return next.source
                            }
                        }
                    }
                }
            }
        }
        if Task.isCancelled {
            for request in unique { await cancelIfQueued(request.bookID) }
        }
    }

    private nonisolated func refreshBook(_ request: BookshelfRefreshRequest,
        operation: @escaping @Sendable (BookshelfRefreshRequest) async throws -> Void) async {
        guard !Task.isCancelled else {
            await setPhase(.cancelled, for: request.bookID)
            return
        }
        await setPhase(.refreshing, for: request.bookID)
        do {
            try Task.checkCancellation()
            try await operation(request)
            try Task.checkCancellation()
            await setPhase(.completed, for: request.bookID)
        } catch {
            await setPhase(Task.isCancelled || error is CancellationError ? .cancelled : .failed,
                           for: request.bookID)
        }
    }

    private func setPhase(_ phase: BookshelfBookRefreshState.Phase, for bookID: UUID) {
        let state = state(for: bookID)
        if state.phase != phase { state.phase = phase }
    }

    private func cancelIfQueued(_ bookID: UUID) {
        if state(for: bookID).phase == .queued { setPhase(.cancelled, for: bookID) }
    }
}

enum ChapterUpdater {
    @MainActor static func state(for bookID: UUID) -> BookshelfBookRefreshState {
        BookshelfRefreshCoordinator.shared.state(for: bookID)
    }

    /// Preserves the automatic throttle; an explicit pull always requests a batch.
    /// The coordinator is injectable so concurrency/lifecycle tests need no network.
    @MainActor static func refreshAll(bookStore: BookStore, auto: Bool = false,
                                      coordinator: BookshelfRefreshCoordinator? = nil,
                                      bookSourceFetcher: (any BookSourceFetching)? = nil,
                                      offlineChapterStore: (any OfflineChapterStoring)? = nil) async {
        let coordinator = coordinator ?? .shared
        if auto, !coordinator.isRefreshing(owner: bookStore) {
            guard AutoRefreshThrottle(defaults: .standard, minimumInterval: AppConfig.autoRefreshMinInterval).consume() else { return }
        }
        let fetcher = bookSourceFetcher ?? AppDependencies.live.bookSourceFetcher
        let chapterStore = offlineChapterStore ?? AppDependencies.live.offlineChapterStore
        await coordinator.refresh(owner: bookStore) {
            await BookSourceStore.shared.waitUntilLoaded()
            let snapshot = await MainActor.run { bookStore.books }
            let onlineBooks = await Task.detached(priority: .utility) { snapshot.filter(\.isOnline) }.value
            guard !onlineBooks.isEmpty, !Task.isCancelled else { return }
            let requests = onlineBooks.map {
                BookshelfRefreshRequest(bookID: $0.id, sourceID: $0.bookSourceId,
                    needsInfoRefresh: ($0.tocURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                        || ($0.totalChapterNum ?? 0) == 0)
            }
            let started = SourcePerfTrace.now
            CrashContext.breadcrumb("refresh.all start books=\(onlineBooks.count) auto=\(auto)")
            await MainActor.run { SourceCallBackService.notifyShelfRefresh(.startShelfRefresh, books: onlineBooks) }
            await coordinator.refreshBooks(requests) { request in
                do {
                    _ = try await bookStore.refreshOnlineBookMetadata(
                        bookId: request.bookID, forceInfoRefresh: request.needsInfoRefresh,
                        bookSourceFetcher: fetcher, offlineChapterStore: chapterStore)
                } catch {
                    if !Task.isCancelled, !(error is CancellationError) {
                        AppLogger.network("Failed to update book TOC", error: error,
                                          context: ["bookId": request.bookID.uuidString])
                    }
                    throw error
                }
            }
            await MainActor.run { SourceCallBackService.notifyShelfRefresh(.endShelfRefresh, books: onlineBooks) }
            CrashContext.breadcrumb("refresh.all end books=\(onlineBooks.count) ms=\(Int((SourcePerfTrace.now - started) * 1000))")
        }
    }
}
