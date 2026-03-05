@testable import Cee
import XCTest

final class ThumbnailThrottleTests: XCTestCase {

    // MARK: - Test 1: Acquire up to max

    func testThrottle_acquireUpToMax() async {
        let throttle = ThumbnailThrottle(maxConcurrent: 2)
        let started = ManagedAtomic(0)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    await throttle.withThrottle {
                        started.increment()
                        // Brief delay to keep slot occupied
                        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                    }
                }
            }
        }

        // Both should have completed
        XCTAssertEqual(started.value, 2, "Both operations should have started and completed")
        let active = await throttle.activeCount
        XCTAssertEqual(active, 0, "No active operations after completion")
    }

    // MARK: - Test 2: Acquire beyond max suspends

    func testThrottle_acquireBeyondMaxSuspends() async {
        let throttle = ThumbnailThrottle(maxConcurrent: 2)
        let startedCount = ManagedAtomic(0)
        let gate = ManagedGate()

        // Start 3 operations with maxConcurrent=2
        // The 3rd should wait until one of the first two finishes
        async let op1: Void = throttle.withThrottle {
            startedCount.increment()
            await gate.wait() // Hold slot until released
        }
        async let op2: Void = throttle.withThrottle {
            startedCount.increment()
            await gate.wait()
        }

        // Give time for first two to acquire
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

        let waiters = await throttle.waiterCount
        // At this point, 2 should be active, 3rd hasn't started yet
        let activeBeforeRelease = await throttle.activeCount
        XCTAssertEqual(activeBeforeRelease, 2, "Two operations should be active")

        // Start 3rd operation
        async let op3: Void = throttle.withThrottle {
            startedCount.increment()
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        let waitersAfter = await throttle.waiterCount
        XCTAssertEqual(waitersAfter, 1, "Third operation should be waiting")

        // Release gate to let everything finish
        gate.open()
        await op1
        await op2
        await op3

        XCTAssertEqual(startedCount.value, 3, "All three operations should have completed")
    }

    // MARK: - Test 3: FIFO ordering

    func testThrottle_releaseFIFO() async {
        let throttle = ThumbnailThrottle(maxConcurrent: 1)
        let order = ManagedOrder()
        let gate = ManagedGate()

        // First operation holds the slot
        async let op1: Void = throttle.withThrottle {
            order.append(1)
            await gate.wait()
        }

        try? await Task.sleep(nanoseconds: 30_000_000)

        // Queue operations 2 and 3 (should wait in FIFO order)
        async let op2: Void = throttle.withThrottle {
            order.append(2)
        }
        async let op3: Void = throttle.withThrottle {
            order.append(3)
        }

        try? await Task.sleep(nanoseconds: 30_000_000)

        // Release gate
        gate.open()
        await op1
        await op2
        await op3

        XCTAssertEqual(order.values, [1, 2, 3], "Operations should complete in FIFO order")
    }

    // MARK: - Test 4: Release without waiters

    func testThrottle_releaseWithoutWaiters() async {
        let throttle = ThumbnailThrottle(maxConcurrent: 2)

        // Run a single operation (below max)
        await throttle.withThrottle {
            // Do nothing
        }

        let active = await throttle.activeCount
        XCTAssertEqual(active, 0, "Active count should return to 0")
    }

    // MARK: - Test 5: Acquire/release parity (stress)

    func testThrottle_acquireReleaseParity() async {
        let throttle = ThumbnailThrottle(maxConcurrent: 3)
        let completedCount = ManagedAtomic(0)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await throttle.withThrottle {
                        // Simulate brief work
                        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                        completedCount.increment()
                    }
                }
            }
        }

        XCTAssertEqual(completedCount.value, 10, "All 10 operations should complete")
        let active = await throttle.activeCount
        XCTAssertEqual(active, 0, "Active count should return to 0 after all complete")
        let waiters = await throttle.waiterCount
        XCTAssertEqual(waiters, 0, "No waiters should remain")
    }

    // MARK: - Test 6: Cancelled task releases slot

    func testThrottle_cancelledTaskReleasesSlot() async {
        let throttle = ThumbnailThrottle(maxConcurrent: 1)
        let gate = ManagedGate()

        // op1 holds the only slot
        async let op1: Void = throttle.withThrottle {
            await gate.wait()
        }

        try? await Task.sleep(nanoseconds: 30_000_000)

        // op2 will wait in queue — then we cancel it
        let op2Task = Task {
            await throttle.withThrottle {
                // This should eventually run after op1 releases
            }
        }

        try? await Task.sleep(nanoseconds: 30_000_000)
        op2Task.cancel()

        // Release op1
        gate.open()
        await op1
        // Wait for op2 to process (even though cancelled)
        await op2Task.value

        let active = await throttle.activeCount
        XCTAssertEqual(active, 0, "Active count should return to 0 even after cancellation")
    }
}

// MARK: - Test Helpers

/// Thread-safe ordered collection for verifying FIFO execution.
private final class ManagedOrder: @unchecked Sendable {
    private var _values: [Int] = []
    private let lock = NSLock()

    var values: [Int] {
        lock.withLock { _values }
    }

    func append(_ value: Int) {
        lock.withLock { _values.append(value) }
    }
}

/// Simple atomic counter for concurrent test verification.
private final class ManagedAtomic: @unchecked Sendable {
    private var _value: Int
    private let lock = NSLock()

    init(_ initial: Int) {
        _value = initial
    }

    var value: Int {
        lock.withLock { _value }
    }

    func increment() {
        lock.withLock { _value += 1 }
    }
}

/// Simple gate for coordinating async tests.
private final class ManagedGate: @unchecked Sendable {
    private var isOpen = false
    private let lock = NSLock()

    func open() {
        lock.withLock { isOpen = true }
    }

    func wait() async {
        while true {
            let opened = lock.withLock { isOpen }
            if opened { return }
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms poll
        }
    }
}
