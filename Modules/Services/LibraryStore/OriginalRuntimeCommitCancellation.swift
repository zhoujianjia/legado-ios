import Foundation
import LegadoRuntime

/// Cancellation proof for a job enqueued on the existing library persistence queue. A
/// successful synchronous owner commit is reported even if the caller cancels after it.
final class OriginalRuntimeCommitCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check(deadline: Date) throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
        guard deadline.timeIntervalSinceNow > 0 else {
            throw LegadoRuntimeError(code: "STATE_TIMEOUT", message: "The App state owner deadline expired before its write")
        }
    }
}
