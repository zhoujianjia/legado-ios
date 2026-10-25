import Foundation
import XCTest
import YueduCoreText
@testable import yuedu_app

// One existing XCTest class and selection. No second position store, timing
// delays, real library files or cloud notifications are involved.
extension ReadingPositionStorePersistenceTests {
    func testCheckedAdmissionCompletesAfterCancellationBehindTheExistingWriter() async throws {
        try await withPositionScenario { scenario in
            let legacy = scenario.makeStore()
            let checked = scenario.makeCheckedStore()
            try await scenario.saveSeed(using: legacy)
            let held = scenario.start { await legacy.save(scenario.held, for: "book") }
            try await scenario.wait(scenario.writer.started)
            let admitted = scenario.admissions.expect(.save, position: scenario.latest)
            let result = CheckedPositionResult()
            let save = scenario.start {
                do { result.record(try await checked.saveChecked(scenario.latest, for: "book")) }
                catch { result.record(error: error) }
            }
            try await scenario.wait(admitted)
            XCTAssertNil(result.receipt)
            held.task.cancel(); save.task.cancel()
            scenario.writer.open()
            try await scenario.wait(held.finished, save.finished)
            XCTAssertNil(result.error)
            let receipt = try XCTUnwrap(result.receipt)
            XCTAssertEqual(receipt.bookId, "book")
            XCTAssertEqual(receipt.position, scenario.latest)
            XCTAssertEqual(receipt.operation, .atomicWriteCompleted)
            XCTAssertEqual(scenario.successes.positions, [scenario.seed, scenario.held, scenario.latest])
            let loaded = try await scenario.makeCheckedStore().loadChecked(for: "book")
            XCTAssertEqual(loaded?.rawSHA256, receipt.rawSHA256)
            XCTAssertEqual(loaded?.position, scenario.latest)
            XCTAssertEqual(scenario.admissions.snapshots.map(\.kind), [.save, .save, .save, .load])
            XCTAssertTrue(scenario.admissions.strictlyIncreasingSequences)
            XCTAssertFalse(scenario.writer.wasCalledOnMain)
        }
    }

    func testAdmittedSavesAndFlushKeepOrderWhenTheFirstCallerIsCancelled() async throws {
        try await withPositionScenario { scenario in
            let store = scenario.makeStore()
            try await scenario.saveSeed(using: store)
            let first = scenario.start { await store.save(scenario.held, for: "book") }
            try await scenario.wait(scenario.writer.started)
            let latestSubmitted = scenario.admissions.expect(.save, position: scenario.latest)
            let latest = scenario.start { await store.save(scenario.latest, for: "book") }
            try await scenario.wait(latestSubmitted)
            let flushSubmitted = scenario.admissions.expect(.flush)
            let flush = scenario.start { await store.flush(for: "book") }
            try await scenario.wait(flushSubmitted)

            // loadSync is an immediate atomic snapshot, not a wait for the held
            // write. Cancellation after admission cannot abandon that write.
            let duringWrite = await Task.detached { store.loadSync(for: "book") }.value
            XCTAssertEqual(duringWrite, scenario.seed)
            XCTAssertFalse(latest.finished.didFire)
            XCTAssertFalse(flush.finished.didFire)
            first.task.cancel()
            scenario.writer.open()
            try await scenario.wait(first.finished, latest.finished, flush.finished)

            let reopened = scenario.makeStore()
            let restored = await Task.detached { reopened.loadSync(for: "book") }.value
            XCTAssertEqual(restored, scenario.latest)
            XCTAssertEqual(scenario.successes.positions, [scenario.seed, scenario.held, scenario.latest])
            XCTAssertEqual(scenario.writer.attemptedPositions, [scenario.seed, scenario.held, scenario.latest])
            XCTAssertEqual(scenario.admissions.snapshots.map(\.kind), [.save, .save, .save, .flush])
            XCTAssertTrue(scenario.admissions.strictlyIncreasingSequences)
            XCTAssertFalse(scenario.writer.wasCalledOnMain)
        }
    }

    func testDifferentInstancesShareAdmissionOrderAndAsyncLoadWaits() async throws {
        try await withPositionScenario { scenario in
            let firstStore = scenario.makeStore()
            let secondStore = scenario.makeStore()
            try await scenario.saveSeed(using: firstStore)
            let first = scenario.start { await firstStore.save(scenario.held, for: "book") }
            try await scenario.wait(scenario.writer.started)
            let latestSubmitted = scenario.admissions.expect(.save, position: scenario.latest)
            let latest = scenario.start { await secondStore.save(scenario.latest, for: "book") }
            try await scenario.wait(latestSubmitted)
            let value = PositionResult()
            let loadSubmitted = scenario.admissions.expect(.load)
            let load = scenario.start { value.record(await secondStore.load(for: "book")) }
            try await scenario.wait(loadSubmitted)
            let flushSubmitted = scenario.admissions.expect(.flush)
            let flush = scenario.start { await firstStore.flush(for: "book") }
            try await scenario.wait(flushSubmitted)

            XCTAssertFalse(load.finished.didFire)
            XCTAssertFalse(flush.finished.didFire)
            scenario.writer.open()
            try await scenario.wait(first.finished, latest.finished, load.finished, flush.finished)
            XCTAssertEqual(value.position, scenario.latest)
            XCTAssertEqual(scenario.successes.positions, [scenario.seed, scenario.held, scenario.latest])
            XCTAssertEqual(scenario.admissions.snapshots.map(\.kind), [.save, .save, .save, .load, .flush])
            XCTAssertTrue(scenario.admissions.strictlyIncreasingSequences)
            XCTAssertFalse(scenario.writer.wasCalledOnMain)
        }
    }

    func testHeldWriteFailureDoesNotPublishSuccessOrStopTheLaterSave() async throws {
        try await withPositionScenario(failHeldWrite: true) { scenario in
            let store = scenario.makeStore()
            try await scenario.saveSeed(using: store)
            let before = try await scenario.fileBytes()
            let failed = scenario.start { await store.save(scenario.held, for: "book") }
            try await scenario.wait(scenario.writer.started)
            let latestSubmitted = scenario.admissions.expect(.save, position: scenario.latest)
            let latest = scenario.start { await store.save(scenario.latest, for: "book") }
            try await scenario.wait(latestSubmitted)
            let duringWrite = try await scenario.fileBytes()
            XCTAssertEqual(duringWrite, before)
            scenario.writer.open()
            try await scenario.wait(failed.finished, latest.finished)
            let flush = scenario.start { await store.flush(for: "book") }
            try await scenario.wait(flush.finished)

            let restored = await Task.detached { store.loadSync(for: "book") }.value
            XCTAssertTrue(scenario.writer.didUseFault)
            XCTAssertEqual(restored, scenario.latest)
            XCTAssertEqual(scenario.successes.positions, [scenario.seed, scenario.latest])
            XCTAssertEqual(scenario.writer.failedPositions, [scenario.held])
            XCTAssertEqual(scenario.writer.attemptedPositions, [scenario.seed, scenario.held, scenario.latest])
            XCTAssertFalse(scenario.writer.wasCalledOnMain)
        }
    }

    func testDirectoryRemovedDuringAHeldWriteIsRecreatedByTheNextSave() async throws {
        try await withPositionScenario { scenario in
            let store = scenario.makeStore()
            try await scenario.saveSeed(using: store)
            let failed = scenario.start { await store.save(scenario.held, for: "book") }
            try await scenario.wait(scenario.writer.started)
            let directory = scenario.directory
            try await Task.detached { try FileManager.default.removeItem(at: directory) }.value
            let latestSubmitted = scenario.admissions.expect(.save, position: scenario.latest)
            let latest = scenario.start { await store.save(scenario.latest, for: "book") }
            try await scenario.wait(latestSubmitted)
            scenario.writer.open()
            try await scenario.wait(failed.finished, latest.finished)
            let flush = scenario.start { await store.flush(for: "book") }
            try await scenario.wait(flush.finished)

            let reopened = scenario.makeStore()
            let restored = await Task.detached { reopened.loadSync(for: "book") }.value
            XCTAssertEqual(restored, scenario.latest)
            XCTAssertEqual(scenario.writer.failedPositions, [scenario.held])
            XCTAssertEqual(scenario.successes.positions, [scenario.seed, scenario.latest])
            XCTAssertEqual(scenario.writer.attemptedPositions, [scenario.seed, scenario.held, scenario.latest])
            XCTAssertFalse(scenario.writer.wasCalledOnMain)
        }
    }

    func testSyncReplacementUsesTheSameOrderedWorkerWithoutEchoingASave() async throws {
        try await withPositionScenario { scenario in
            let store = scenario.makeStore()
            let importingStore = scenario.makeStore()
            try await scenario.saveSeed(using: store)
            let first = scenario.start { await store.save(scenario.held, for: "book") }
            try await scenario.wait(scenario.writer.started)
            let syncPosition = CoreTextReadingPosition(spineIndex: 8, charOffset: 320, translationOffset: 17)
            let syncSubmitted = scenario.admissions.expect(.syncReplacement)
            let sync = scenario.start { await importingStore.applySyncedPositions(["book": syncPosition]) }
            try await scenario.wait(syncSubmitted)
            let latestSubmitted = scenario.admissions.expect(.save, position: scenario.latest)
            let latest = scenario.start { await store.save(scenario.latest, for: "book") }
            try await scenario.wait(latestSubmitted)
            let flushSubmitted = scenario.admissions.expect(.flush)
            let flush = scenario.start { await importingStore.flush(for: "book") }
            try await scenario.wait(flushSubmitted)
            XCTAssertFalse(sync.finished.didFire)
            XCTAssertFalse(flush.finished.didFire)
            scenario.writer.open()
            try await scenario.wait(first.finished, sync.finished, latest.finished, flush.finished)

            let restored = await Task.detached { store.loadSync(for: "book") }.value
            XCTAssertEqual(restored, scenario.latest)
            XCTAssertEqual(scenario.writer.attemptedPositions, [scenario.seed, scenario.held, syncPosition, scenario.latest])
            XCTAssertEqual(scenario.successes.positions, [scenario.seed, scenario.held, scenario.latest])
            XCTAssertEqual(scenario.admissions.snapshots.map(\.kind), [.save, .save, .syncReplacement, .save, .flush])
            XCTAssertTrue(scenario.admissions.strictlyIncreasingSequences)
            XCTAssertFalse(scenario.writer.wasCalledOnMain)
        }
    }
}

@MainActor
private func withPositionScenario(
    failHeldWrite: Bool = false,
    body: @MainActor (PositionScenario) async throws -> Void
) async throws {
    let scenario = PositionScenario(failHeldWrite: failHeldWrite)
    do {
        try await body(scenario)
        await scenario.cleanUp()
    } catch {
        await scenario.cleanUp()
        throw error
    }
}

@MainActor
private final class PositionScenario {
    let root: URL
    let directory: URL
    let seed = CoreTextReadingPosition(spineIndex: 1, charOffset: 28, translationOffset: 5)
    let held: CoreTextReadingPosition
    let latest = CoreTextReadingPosition(spineIndex: 3, charOffset: 144, translationOffset: 23)
    let writer: HeldPositionWriter
    let successes = PositionSuccessLog()
    let admissions = PositionAdmissionLog()
    private var actions: [PositionAction] = []

    init(failHeldWrite: Bool) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadingPositionWriteOrderingTests-\(UUID().uuidString)", isDirectory: true)
        self.root = root
        directory = root.appendingPathComponent("positions", isDirectory: true)
        let held = CoreTextReadingPosition(spineIndex: 2, charOffset: 56, translationOffset: 11)
        self.held = held
        writer = HeldPositionWriter(heldPosition: held, failHeldWrite: failHeldWrite)
    }

    func makeStore() -> JSONFileReadingPositionStore {
        let writer = writer, successes = successes, admissions = admissions
        return JSONFileReadingPositionStore(baseURL: directory,
            writeData: { try writer.write($0, to: $1) },
            onSave: { successes.record($0, bookId: $1) },
            onSubmit: { admissions.record($0) })
    }

    func makeCheckedStore(onSave: (@Sendable (CoreTextReadingPosition, String) -> Void)? = nil) -> JSONFileReadingPositionStore {
        let successes = successes, admissions = admissions
        return JSONFileReadingPositionStore(baseURL: directory,
            onSave: onSave ?? { successes.record($0, bookId: $1) }, onSubmit: { admissions.record($0) })
    }

    func start(_ operation: @escaping @MainActor () async -> Void) -> PositionAction {
        let finished = PositionSignal("position action finished")
        let action = PositionAction(task: Task { await operation(); finished.fire() }, finished: finished)
        actions.append(action)
        return action
    }

    func wait(_ signals: PositionSignal...) async throws {
        // Explicit failure deadline, not a settle delay. Every successful wait
        // ends on the real admission, writer entry or operation completion.
        let result = await XCTWaiter.fulfillment(of: signals.map(\.expectation), timeout: 5)
        XCTAssertEqual(result, .completed)
        guard result == .completed else { throw PositionScenarioFailure.signalDeadline }
    }

    func saveSeed(using store: JSONFileReadingPositionStore) async throws {
        let seed = seed
        let save = start { await store.save(seed, for: "book") }
        try await wait(save.finished)
    }

    func fileBytes() async throws -> Data {
        let file = directory.appendingPathComponent("book.json", isDirectory: false)
        return try await Task.detached { try Data(contentsOf: file) }.value
    }

    func cleanUp() async {
        writer.open()
        actions.forEach { $0.task.cancel() }
        // No uncancellable/unbounded cleanup task: if a real ordering regression
        // strands a job, report it and retain this owned directory for diagnosis.
        let result = await XCTWaiter.fulfillment(of: actions.map(\.finished.expectation), timeout: 5)
        guard result == .completed else {
            XCTFail("Position jobs did not drain after releasing the owned writer; fixture retained")
            return
        }
        let root = root
        do {
            try await Task.detached {
                if FileManager.default.fileExists(atPath: root.path) {
                    try FileManager.default.removeItem(at: root)
                }
            }.value
        } catch { XCTFail("Owned progress fixture cleanup failed: \(error)") }
    }
}

private enum PositionScenarioFailure: Error { case signalDeadline, unexpectedMainThread }
private struct PositionAction {
    let task: Task<Void, Never>
    let finished: PositionSignal
}

private final class PositionSignal: @unchecked Sendable {
    private let label: String
    private let lock = NSLock()
    private var fired = false
    private var waiting: [XCTestExpectation] = []
    init(_ label: String) { self.label = label }
    // XCTest expectations cannot be waited on more than once. Each caller gets
    // its own expectation for the same recorded event, including cleanup.
    var expectation: XCTestExpectation {
        let expectation = XCTestExpectation(description: label)
        let alreadyFired = lock.withLock {
            if fired { return true }
            waiting.append(expectation)
            return false
        }
        if alreadyFired { expectation.fulfill() }
        return expectation
    }
    var didFire: Bool { lock.withLock { fired } }
    func fire() {
        let ready: [XCTestExpectation] = lock.withLock {
            guard !fired else { return [] }
            fired = true
            let ready = waiting
            waiting.removeAll()
            return ready
        }
        ready.forEach { $0.fulfill() }
    }
}

private final class PositionAdmissionLog: @unchecked Sendable {
    typealias Submission = JSONFileReadingPositionStore.Submission
    private let lock = NSLock()
    private var values: [Submission] = []
    private var waiting: [(Submission.Kind, CoreTextReadingPosition?, PositionSignal)] = []
    var snapshots: [Submission] { lock.withLock { values } }
    var strictlyIncreasingSequences: Bool {
        let values = snapshots.map(\.sequence)
        return zip(values, values.dropFirst()).allSatisfy { pair in pair.0 < pair.1 }
    }
    func expect(_ kind: Submission.Kind, position: CoreTextReadingPosition? = nil) -> PositionSignal {
        let signal = PositionSignal("position job admitted")
        let existing = lock.withLock {
            if values.contains(where: { $0.kind == kind && $0.position == position }) { return true }
            waiting.append((kind, position, signal))
            return false
        }
        if existing { signal.fire() }
        return signal
    }
    func record(_ submission: Submission) {
        let ready: [PositionSignal] = lock.withLock {
            values.append(submission)
            let ready = waiting.filter { $0.0 == submission.kind && $0.1 == submission.position }.map { $0.2 }
            waiting.removeAll { $0.0 == submission.kind && $0.1 == submission.position }
            return ready
        }
        ready.forEach { $0.fire() }
    }
}

private final class PositionSuccessLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CoreTextReadingPosition] = []
    var positions: [CoreTextReadingPosition] { lock.withLock { values } }
    func record(_ position: CoreTextReadingPosition, bookId: String) {
        XCTAssertEqual(bookId, "book")
        lock.withLock { values.append(position) }
    }
}

private final class PositionResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CoreTextReadingPosition?
    var position: CoreTextReadingPosition? { lock.withLock { value } }
    func record(_ position: CoreTextReadingPosition?) { lock.withLock { value = position } }
}

private final class CheckedPositionResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ReadingPositionPersistenceReceipt?
    private var failure: Error?
    var receipt: ReadingPositionPersistenceReceipt? { lock.withLock { value } }
    var error: Error? { lock.withLock { failure } }
    func record(_ value: ReadingPositionPersistenceReceipt?) { lock.withLock { self.value = value } }
    func record(error: Error) { lock.withLock { failure = error } }
}

/// Blocks only the detached file operation; admission, the test MainActor and
/// every signal waiter remain live. The test opens this gate even on failure.
private final class HeldPositionWriter: @unchecked Sendable {
    let started = PositionSignal("held writer entered")
    private let heldPosition: CoreTextReadingPosition
    private let failHeldWrite: Bool
    private let condition = NSCondition()
    private var opened = false
    private let lock = NSLock()
    private var attempts: [CoreTextReadingPosition] = []
    private var failures: [CoreTextReadingPosition] = []
    private var usedFault = false
    private var calledOnMain = false
    var attemptedPositions: [CoreTextReadingPosition] { lock.withLock { attempts } }
    var failedPositions: [CoreTextReadingPosition] { lock.withLock { failures } }
    var didUseFault: Bool { lock.withLock { usedFault } }
    var wasCalledOnMain: Bool { lock.withLock { calledOnMain } }

    init(heldPosition: CoreTextReadingPosition, failHeldWrite: Bool) {
        self.heldPosition = heldPosition
        self.failHeldWrite = failHeldWrite
    }
    func write(_ data: Data, to url: URL) throws {
        let position = try JSONDecoder().decode(CoreTextReadingPosition.self, from: data)
        lock.withLock { attempts.append(position); calledOnMain = calledOnMain || Thread.isMainThread }
        guard !Thread.isMainThread else {
            XCTFail("Position writer ran on main; refusing to block the test's signal waiter")
            throw PositionScenarioFailure.unexpectedMainThread
        }
        if position == heldPosition {
            started.fire()
            condition.lock()
            while !opened { condition.wait() }
            condition.unlock()
        }
        do {
            if position == heldPosition && failHeldWrite {
                lock.withLock { usedFault = true }
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try data.write(to: url, options: .atomic)
        } catch {
            lock.withLock { failures.append(position) }
            throw error
        }
    }
    func open() { condition.lock(); opened = true; condition.broadcast(); condition.unlock() }
}
