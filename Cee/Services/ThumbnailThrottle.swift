/// Limits concurrent thumbnail decoding to prevent CPU saturation during grid scrolling.
/// Uses a FIFO queue with CheckedContinuation for fair ordering.
actor ThumbnailThrottle {
    private let maxConcurrent: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int = 4) {
        self.maxConcurrent = maxConcurrent
    }

    /// Primary API: execute an operation with throttled concurrency.
    /// Guarantees release via defer even if the task is cancelled.
    func withThrottle<T: Sendable>(_ operation: @Sendable () async -> T) async -> T {
        // TODO: Implement acquire/release throttling
        return await operation()
    }

    // Test support
    var activeCount: Int { active }
    var waiterCount: Int { waiters.count }
}
