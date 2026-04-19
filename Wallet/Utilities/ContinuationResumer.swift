import Foundation

/// Guards a `CheckedContinuation` so that it resumes at most once, even when
/// multiple callers (timeouts, completion handlers, error paths) race to finish.
final class ContinuationResumer<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(with value: Value) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(returning: value)
    }
}
