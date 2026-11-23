import Foundation
import Testing
@testable import yuedu_app

@Suite(.serialized)
struct BookshelfRefreshCoordinatorTests {
    @Test("refresh never exceeds its worker limit and duplicate book IDs execute once", .timeLimit(.minutes(1)))
    @MainActor func boundedWorkersAndUniqueBooks() async throws {
        let coordinator = BookshelfRefreshCoordinator(maximumConcurrentBooks: 3)
        let probe = RefreshProbe()
        let jobs = (0..<7).map { _ in request() }
        let task = Task { await coordinator.refreshBooks(jobs + [jobs[0]]) { try await probe.run($0) } }
        defer { task.cancel() }
        try await waitForStarts(3, probe: probe)
        #expect(coordinator.state(for: jobs[0].bookID).phase == .refreshing)
        #expect(coordinator.state(for: jobs[6].bookID).phase == .queued)
        await probe.releaseAll()
        try await finish(task)
        let result = await probe.snapshot()
        #expect(result.peak == 3)
        #expect(result.starts.count == jobs.count)
        #expect(Set(result.starts).count == jobs.count)
        for job in jobs { #expect(coordinator.state(for: job.bookID).phase == .completed) }
    }

    @Test("one slow source cannot occupy every worker and failures do not stop other books", .timeLimit(.minutes(1)))
    @MainActor func sourceFairnessAndIndependentFailure() async throws {
        let coordinator = BookshelfRefreshCoordinator(maximumConcurrentBooks: 2)
        let sourceA = UUID()
        let a = (0..<3).map { _ in request(source: sourceA) }
        let b = request(), c = request()
        let jobs = a + [b, c]
        let probe = RefreshProbe()
        let task = Task { await coordinator.refreshBooks(jobs) { try await probe.run($0) } }
        defer { task.cancel() }
        try await waitForStarts(2, probe: probe)
        let first = await probe.snapshot()
        #expect(Set(first.starts) == [a[0].bookID, b.bookID])
        await probe.release(b.bookID, failing: true)
        try await waitForStarts(3, probe: probe)
        #expect(coordinator.state(for: b.bookID).phase == .failed)
        #expect(coordinator.state(for: c.bookID).phase == .refreshing)
        await probe.release(a[0].bookID, failing: true)
        await probe.releaseAll()
        try await finish(task)
        let result = await probe.snapshot()
        #expect(result.peakBySource.values.allSatisfy { $0 == 1 })
        #expect(result.starts.count == jobs.count)
        #expect(coordinator.state(for: a[0].bookID).phase == .failed)
        for job in [a[1], a[2], c] { #expect(coordinator.state(for: job.bookID).phase == .completed) }
    }

    @Test("overlapping refresh triggers share a batch and a cancelled joiner does not cancel its owner", .timeLimit(.minutes(1)))
    @MainActor func coalescesRefreshTriggers() async throws {
        let coordinator = BookshelfRefreshCoordinator(maximumConcurrentBooks: 2)
        let owner = NSObject(), probe = RefreshProbe(), entered = RefreshSignal()
        let jobs = [request(), request()]
        let first = Task {
            await coordinator.refresh(owner: owner) {
                await coordinator.refreshBooks(jobs) { try await probe.run($0) }
            }
        }
        defer { first.cancel() }
        try await waitForStarts(2, probe: probe)
        let second = Task { @MainActor in
            entered.fire()
            await coordinator.refresh(owner: owner) {
                await coordinator.refreshBooks(jobs) { try await probe.run($0) }
            }
        }
        defer { second.cancel() }
        try await entered.wait()
        second.cancel()
        await probe.releaseAll()
        try await finish(first)
        try await finish(second)
        #expect(await probe.snapshot().starts.count == 2)
        #expect(!coordinator.isRefreshing(owner: owner))
        for job in jobs { #expect(coordinator.state(for: job.bookID).phase == .completed) }
        // A subsequent explicit refresh is a new batch, not permanently deduplicated.
        await coordinator.refresh(owner: owner) {
            await coordinator.refreshBooks(jobs) { try await probe.run($0) }
        }
        #expect(await probe.snapshot().starts.count == 4)
    }

    @Test("cancelling the owner leaves every book terminal and does not start queued books", .timeLimit(.minutes(1)))
    @MainActor func cancellationStopsQueuedWork() async throws {
        let coordinator = BookshelfRefreshCoordinator(maximumConcurrentBooks: 2)
        let owner = NSObject(), probe = RefreshProbe()
        let jobs = (0..<6).map { _ in request() }
        let task = Task {
            await coordinator.refresh(owner: owner) {
                await coordinator.refreshBooks(jobs) { try await probe.run($0) }
            }
        }
        defer { task.cancel() }
        try await waitForStarts(2, probe: probe)
        task.cancel()
        await probe.releaseAll()
        try await finish(task)
        #expect(await probe.snapshot().starts.count == 2)
        #expect(!coordinator.isRefreshing(owner: owner))
        for job in jobs { #expect(coordinator.state(for: job.bookID).phase == .cancelled) }
    }

    private func request(source: UUID = UUID()) -> BookshelfRefreshRequest {
        .init(bookID: UUID(), sourceID: source, needsInfoRefresh: false)
    }

    /// A broken scheduler must fail the event wait, not hang its continuation.
    private func waitForStarts(_ count: Int, probe: RefreshProbe) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await probe.waitForStarts(count) }
            group.addTask {
                // Deadline only; successful tests are driven by continuation events.
                try await Task.sleep(for: .seconds(5))
                throw ProbeDeadline.exceeded
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private func finish(_ task: Task<Void, Never>) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw ProbeDeadline.exceeded
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
    private enum ProbeDeadline: Error { case exceeded }
}

/// HTTP-independent controllable completion. Cancellation releases every gate.
private actor RefreshProbe {
    struct Snapshot: Sendable {
        let starts: [UUID]
        let peak: Int
        let peakBySource: [UUID: Int]
    }
    private var starts: [UUID] = []
    private var active = 0
    private var peak = 0
    private var activeBySource: [UUID: Int] = [:]
    private var peakBySource: [UUID: Int] = [:]
    private var completions: [UUID: (book: UUID, continuation: CheckedContinuation<Bool, Error>)] = [:]
    private var startWaiters: [UUID: (count: Int, continuation: CheckedContinuation<Void, Error>)] = [:]
    private var isOpen = false

    func run(_ request: BookshelfRefreshRequest) async throws {
        let source = request.sourceID ?? request.bookID
        starts.append(request.bookID)
        active += 1
        activeBySource[source, default: 0] += 1
        peak = max(peak, active)
        peakBySource[source] = max(peakBySource[source] ?? 0, activeBySource[source]!)
        let ready = startWaiters.filter { starts.count >= $0.value.count }
        for (id, waiter) in ready {
            startWaiters.removeValue(forKey: id)
            waiter.continuation.resume()
        }
        defer {
            active -= 1
            activeBySource[source, default: 1] -= 1
        }
        let failing: Bool
        if isOpen {
            failing = false
        } else {
            let invocation = UUID()
            failing = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { completions[invocation] = (request.bookID, continuation) }
                }
            } onCancel: {
                Task { await self.cancelRun(invocation) }
            }
        }
        if failing { throw ProbeFailure.expected }
    }

    func waitForStarts(_ count: Int) async throws {
        if starts.count >= count { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { startWaiters[id] = (count, continuation) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func release(_ id: UUID, failing: Bool = false) {
        let matches = completions.filter { $0.value.book == id }
        for (invocation, item) in matches {
            completions.removeValue(forKey: invocation)
            item.continuation.resume(returning: failing)
        }
    }

    func releaseAll() {
        isOpen = true
        let pending = Array(completions.values)
        completions.removeAll()
        for item in pending { item.continuation.resume(returning: false) }
    }

    private func cancelRun(_ id: UUID) { completions.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError()) }
    private func cancelWaiter(_ id: UUID) { startWaiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError()) }

    func snapshot() -> Snapshot { .init(starts: starts, peak: peak, peakBySource: peakBySource) }
    private enum ProbeFailure: Error { case expected }
}

@MainActor private final class RefreshSignal {
    private var fired = false
    private var waiter: CheckedContinuation<Void, Error>?
    func fire() { fired = true; waiter?.resume(); waiter = nil }
    func wait() async throws {
        if fired { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiter = continuation }
            }
        } onCancel: {
            Task { @MainActor in
                self.waiter?.resume(throwing: CancellationError())
                self.waiter = nil
            }
        }
    }
}
