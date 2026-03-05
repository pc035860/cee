import Foundation

/// Limits concurrent thumbnail decoding to prevent CPU saturation during grid scrolling.
/// Uses a priority queue: smaller priority value = higher urgency (closer to visible center).
/// Equal priorities preserve FIFO insertion order (Swift min(by:) stability guarantee).
actor ThumbnailThrottle {
    private let maxConcurrent: Int
    private var active = 0
    private var waiters: [(priority: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(maxConcurrent: Int = 4) {
        self.maxConcurrent = maxConcurrent
    }

    /// Primary API: execute an operation with throttled concurrency.
    /// Priority: smaller = higher priority (0 = highest, default for non-grid callers).
    /// Grid callers pass distance-from-visible-center as priority.
    /// Guarantees release via defer even if the task is cancelled.
    func withThrottle<T: Sendable>(priority: Int = 0, _ operation: @Sendable () async -> T) async -> T {
        let waitStart = CFAbsoluteTimeGetCurrent()
        await acquire(priority: priority)
        let waitMs = (CFAbsoluteTimeGetCurrent() - waitStart) * 1000
        if waitMs > 1.0 {
            GridPerfLog.log(String(format: "throttle: waited=%.2fms | pri=%d | active=%d | waiters=%d",
                                   waitMs, priority, active, waiters.count))
        }
        defer { release() }
        return await operation()
    }

    private func acquire(priority: Int) async {
        if active < maxConcurrent {
            active += 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append((priority: priority, continuation: continuation))
        }
    }

    private func release() {
        active -= 1
        guard !waiters.isEmpty else { return }
        // Pick waiter with smallest priority (closest to visible center).
        // Swift's min(by:) is stable — for equal priorities, first-inserted wins (FIFO).
        let minIdx = waiters.indices.min(by: { waiters[$0].priority < waiters[$1].priority })!
        let next = waiters.remove(at: minIdx)
        active += 1
        next.continuation.resume()
    }

    // Test support
    var activeCount: Int { active }
    var waiterCount: Int { waiters.count }
}
