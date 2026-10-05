import Foundation

/// Tracks document work accepted on the main actor but not yet reflected by the engine.
/// Saving may happen on a background thread, so this boundary is deliberately synchronous.
final class DocumentWorkBarrier: @unchecked Sendable {
    final class Token: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private weak var barrier: DocumentWorkBarrier?

        fileprivate init(_ barrier: DocumentWorkBarrier) { self.barrier = barrier }

        func finish() {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            lock.unlock()
            barrier?.finish()
        }

        deinit { finish() }
    }

    private let condition = NSCondition()
    private var pending = 0

    var hasPendingWork: Bool {
        condition.withLock { pending > 0 }
    }

    func begin() -> Token {
        condition.withLock { pending += 1 }
        return Token(self)
    }

    func waitUntilIdle() {
        condition.lock()
        while pending > 0 { condition.wait() }
        condition.unlock()
    }

    private func finish() {
        condition.lock()
        pending -= 1
        if pending == 0 { condition.broadcast() }
        condition.unlock()
    }
}

private extension NSCondition {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
