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

    @MainActor
    @Test("page leave drains a cancelled category invocation and saves before rapid reentry opens again")
    func pagePauseDrainsCategoryLoadBeforeReentry() async throws {
        let executor = ExploreLifecycleExecutor()
        let service = LegadoMainJSSourceService(originalExecutor: executor)
        var current = source("page-drain")
        current.enabledExplore = true; current.exploreUrl = "@js: '[]'"
        let selected = current
        let model = DiscoverViewModel(source: selected, fetcher: BookSourceFetcher(mainJSService: service),
            sourceResolver: { $0 == selected.id ? selected : nil })
        await executor.holdNextEvaluation()
        var entered = executor.entered.makeAsyncIterator()
        let load = try #require(model.reload(forceRefresh: true))
        #expect(await entered.next() == true)
        let pause = try #require(model.pageDisappeared())
        _ = model.pageDisappeared()
        let reentry = try #require(model.pageAppeared())
        #expect(await executor.saveAttempts().isEmpty)
        #expect(await executor.finishedHeldEvaluations() == 0)
        await executor.releaseEvaluation()
        await load.value; await pause.value; await reentry.value
        #expect(await executor.finishedHeldEvaluations() == 1)
        let events = await executor.lifecycleEvents()
        let finished = try #require(events.firstIndex(of: "evaluation-finished"))
        let saved = try #require(events.firstIndex(of: "saved"))
        let reopened = try #require(events.lastIndex(of: "open"))
        #expect(finished < saved && saved < reopened)
        #expect(await executor.saveAttempts() == [selected.bookSourceUrl])
        #expect(model.rawItems.isEmpty)
        await model.pageDisappeared()?.value
    }

    @MainActor
    @Test("a failed page save keeps its actual pending map and duplicate disappearance does not ACK or retry it")
    func failedPagePauseRetainsPendingUntilNextPageLifetime() async throws {
        let executor = ExploreLifecycleExecutor()
        let service = LegadoMainJSSourceService(originalExecutor: executor)
        var current = source("page-failure")
        current.enabledExplore = true; current.exploreUrl = "One::https://explore-page.invalid/category"
        let selected = current
        let model = DiscoverViewModel(source: selected, fetcher: BookSourceFetcher(mainJSService: service),
            sourceResolver: { $0 == selected.id ? selected : nil })
        await model.reload()?.value
        _ = try await service.evaluateOriginalExploreContext(script: "pending", source: selected)
        await executor.failSave(for: selected.bookSourceUrl)
        await model.pageDisappeared()?.value
        #expect(await executor.isPending(selected.bookSourceUrl))
        #expect(await executor.savedSources().isEmpty)
        await model.pageDisappeared()?.value
        #expect(await executor.saveAttempts() == [selected.bookSourceUrl])
        await executor.failSave(for: nil)
        await model.pageAppeared()?.value
        await model.pageDisappeared()?.value
        #expect(!(await executor.isPending(selected.bookSourceUrl)))
        #expect(await executor.savedSources() == [selected.bookSourceUrl])
        #expect(await executor.saveAttempts() == [selected.bookSourceUrl, selected.bookSourceUrl])
    }

    @MainActor
    @Test("page pause resolves the current source and rejects an intervening rule edit")
    func pagePauseRejectsEditedSourceBeforeSaving() async throws {
        let executor = ExploreLifecycleExecutor()
        let service = LegadoMainJSSourceService(originalExecutor: executor)
        var initial = source("page-edited")
        initial.enabledExplore = true; initial.exploreUrl = "One::https://explore-page.invalid/category"
        let selected = initial
        var current = selected
        let model = DiscoverViewModel(source: selected, fetcher: BookSourceFetcher(mainJSService: service),
            sourceResolver: { $0 == current.id ? current : nil })
        await model.reload()?.value
        _ = try await service.evaluateOriginalExploreContext(script: "pending", source: selected)
        current.ruleExplore.name = "intervening-rule-edit"; current.lastUpdateTime += 1
        await model.pageDisappeared()?.value
        #expect(await executor.saveAttempts().isEmpty)
        #expect(await executor.isPending(selected.bookSourceUrl))
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
    private var holdEvaluation = false
    private var evaluationGate: CheckedContinuation<Void, Never>?
    private var heldEvaluationsFinished = 0
    private var events: [String] = []

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
    func holdNextEvaluation() { holdEvaluation = true }
    func releaseEvaluation() { evaluationGate?.resume(); evaluationGate = nil }
    func finishedHeldEvaluations() -> Int { heldEvaluationsFinished }
    func lifecycleEvents() -> [String] { events }

    func execute(sourceJSON: String, sourceURL: String, sourceRevision: String,
                 grant: OriginalRuntimePreviewGrant?, operation: LegadoOriginalPreviewOperation,
                 deadline: Date) async throws -> LegadoOriginalPreviewResult {
        #expect(grant == nil)
        var result: Any = NSNull()
        switch operation {
        case .openExploreContext:
            events.append("open")
            if maps[sourceURL] == nil { maps[sourceURL] = false }
        case .evaluateExploreContext:
            guard maps[sourceURL] != nil else { throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY", message: "Not opened") }
            maps[sourceURL] = true
            if holdEvaluation {
                holdEvaluation = false
                await withCheckedContinuation { continuation in
                    evaluationGate = continuation; enteredContinuation.yield(true)
                }
                heldEvaluationsFinished += 1; events.append("evaluation-finished")
                try Task.checkCancellation()
            }
            result = "[]"
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
            if maps[sourceURL] == true { saved.append(sourceURL); maps[sourceURL] = false; events.append("saved") }
        default:
            throw LegadoRuntimeError(code: "UNSUPPORTED_CAPABILITY", message: "Fixture only executes context lifecycle")
        }
        let currentMap: Any = maps[sourceURL] == nil ? NSNull() : [String: String]()
        let value: [String: Any] = ["infoMap": currentMap,
                                   "needSave": maps[sourceURL] ?? false, "result": result]
        return .exploreContext(try JSONDecoder().decode(LegadoOriginalExploreContextResult.self,
            from: JSONSerialization.data(withJSONObject: value)))
    }
}
