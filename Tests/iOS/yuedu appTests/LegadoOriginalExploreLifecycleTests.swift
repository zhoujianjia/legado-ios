import Foundation
import LegadoRuntime
import Testing
@testable import yuedu_app

/// These tests replace only the native invocation boundary. Real JNI/cache effects
/// are covered separately by LegadoNativeOriginalReaderTests, never inferred here.
@Suite("Original exploration App lifecycle", .serialized)
struct LegadoOriginalExploreLifecycleTests {
    @Test("App pause visits off-screen sources after another source fails, without ACKing its write")
    func pauseVisitsEveryOpenedSourceAndRetainsIndividualFailure() async throws {
        let executor = ExploreLifecycleExecutor()
        let service = LegadoMainJSSourceService(originalExecutor: executor)
        let first = source("first"), second = source("second")
        let sources = [first.id: first, second.id: second]
        _ = try await service.openOriginalExploreContext(source: first)
        _ = try await service.openOriginalExploreContext(source: second)
        _ = try await service.evaluateOriginalExploreContext(script: "pending", source: first)
        _ = try await service.evaluateOriginalExploreContext(script: "pending", source: second)
        await executor.failSave(for: first.bookSourceUrl)
        let report = try await service.savePendingOriginalExploreContexts(sourceResolver: { sources[$0] })
        #expect(report.acknowledgedSourceIDs == [second.id])
        #expect(report.failures.map(\.sourceID) == [first.id])
        #expect(report.failures.map(\.code) == ["STATE_IO"])
        #expect(await executor.savedSources() == [second.bookSourceUrl])
        #expect(await executor.isPending(first.bookSourceUrl))

        await executor.failSave(for: nil)
        let next = try await service.savePendingOriginalExploreContexts(sourceResolver: { sources[$0] })
        #expect(next.failures.isEmpty)
        #expect(Set(next.acknowledgedSourceIDs) == Set([first.id, second.id]))
        #expect(await executor.savedSources() == [second.bookSourceUrl, first.bookSourceUrl])
        #expect(!(await executor.isPending(first.bookSourceUrl)))
    }

    @Test("a removed or edited source cannot save an old revision, and unopened contexts are never enrolled by pause")
    func pauseRejectsChangedSourceWithoutGrantingUnopenedContext() async throws {
        let executor = ExploreLifecycleExecutor()
        let service = LegadoMainJSSourceService(originalExecutor: executor)
        let first = source("changed"), second = source("removed"), unopened = source("unopened")
        _ = try await service.openOriginalExploreContext(source: first)
        _ = try await service.openOriginalExploreContext(source: second)
        _ = try await service.savePendingOriginalExploreContext(source: unopened)
        var edited = first
        edited.ruleExplore.name = "different source rule"
        edited.lastUpdateTime += 1
        let current = edited
        let report = try await service.savePendingOriginalExploreContexts(sourceResolver: { $0 == current.id ? current : nil })
        #expect(report.acknowledgedSourceIDs.isEmpty)
        #expect(Set(report.failures.map(\.sourceID)) == Set([first.id, second.id]))
        #expect(report.failures.allSatisfy { $0.code == "SOURCE_CHANGED" })
        #expect(await executor.saveAttempts() == [unopened.bookSourceUrl])
    }

    @Test("cancelling pause awaits the outstanding invocation's real completion and keeps the pending map")
    func cancelledPauseDrainsBeforeItReturns() async throws {
        let executor = ExploreLifecycleExecutor()
        let service = LegadoMainJSSourceService(originalExecutor: executor)
        let current = source("held")
        _ = try await service.openOriginalExploreContext(source: current)
        _ = try await service.evaluateOriginalExploreContext(script: "pending", source: current)
        await executor.holdNextSave()
        var entered = executor.entered.makeAsyncIterator()
        let pause = Task { try await service.savePendingOriginalExploreContexts(sourceResolver: { $0 == current.id ? current : nil }) }
        #expect(await entered.next() == true)
        pause.cancel()
        // The fixture's native invocation is still live, so returning early would
        // abandon it. Releasing its actual signal, not sleeping, permits cleanup.
        #expect(await executor.finishedHeldSaves() == 0)
        await executor.releaseSave()
        do { _ = try await pause.value; Issue.record("Cancelled pause was acknowledged") }
        catch { #expect(error is CancellationError) }
        #expect(await executor.finishedHeldSaves() == 1)
        #expect(await executor.isPending(current.bookSourceUrl))
        #expect(await executor.savedSources().isEmpty)
    }

    private func source(_ name: String) -> BookSource {
        BookSource(bookSourceUrl: "https://explore-lifecycle-" + name + ".invalid", bookSourceName: name)
    }
}

private actor ExploreLifecycleExecutor: LegadoOriginalPreviewExecuting {
    nonisolated let entered: AsyncStream<Bool>
    private let enteredContinuation: AsyncStream<Bool>.Continuation
    private var maps: [String: Bool] = [:]
    private var saved: [String] = []
    private var attempts: [String] = []
    private var failingSource: String?
    private var shouldHold = false
    private var gate: CheckedContinuation<Void, Never>?
    private var heldFinished = 0

    init() {
        let events = AsyncStream<Bool>.makeStream()
        entered = events.stream; enteredContinuation = events.continuation
    }
    func failSave(for source: String?) { failingSource = source }
    func savedSources() -> [String] { saved }
    func saveAttempts() -> [String] { attempts }
    func isPending(_ source: String) -> Bool { maps[source] == true }
    func holdNextSave() { shouldHold = true }
    func releaseSave() { gate?.resume(); gate = nil }
    func finishedHeldSaves() -> Int { heldFinished }

    func execute(sourceJSON: String, sourceURL: String, sourceRevision: String,
                 grant: OriginalRuntimePreviewGrant?, operation: LegadoOriginalPreviewOperation,
                 deadline: Date) async throws -> LegadoOriginalPreviewResult {
        #expect(grant == nil)
        switch operation {
        case .openExploreContext:
            if maps[sourceURL] == nil { maps[sourceURL] = false }
        case .evaluateExploreContext:
            guard maps[sourceURL] != nil else { throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY", message: "Not opened") }
            maps[sourceURL] = true
        case .savePendingExploreContext:
            attempts.append(sourceURL)
            if shouldHold {
                shouldHold = false
                await withCheckedContinuation { continuation in
                    gate = continuation; enteredContinuation.yield(true)
                }
                heldFinished += 1
                try Task.checkCancellation()
            }
            if failingSource == sourceURL { throw LegadoRuntimeError(code: "STATE_IO", message: "Controlled save failed") }
            if maps[sourceURL] == true { saved.append(sourceURL); maps[sourceURL] = false }
        default:
            throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY", message: "Fixture only executes context lifecycle")
        }
        let currentMap: Any = maps[sourceURL] == nil ? NSNull() : [String: String]()
        let value: [String: Any] = ["infoMap": currentMap,
                                   "needSave": maps[sourceURL] ?? false, "result": NSNull()]
        return .exploreContext(try JSONDecoder().decode(LegadoOriginalExploreContextResult.self,
            from: JSONSerialization.data(withJSONObject: value)))
    }
}
