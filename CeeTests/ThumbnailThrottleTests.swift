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
        let op1 = Task {
            await throttle.withThrottle {
                order.append(1)
                await gate.wait()
            }
        }

        try? await Task.sleep(nanoseconds: 30_000_000)

        // Queue operations 2 and 3 (should wait in FIFO order)
        let op2 = Task {
            await throttle.withThrottle {
                order.append(2)
            }
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        let waitersAfterSecond = await throttle.waiterCount
        XCTAssertEqual(waitersAfterSecond, 1, "Second operation should enqueue before third starts")

        let op3 = Task {
            await throttle.withThrottle {
                order.append(3)
            }
        }

        try? await Task.sleep(nanoseconds: 30_000_000)
        let waitersAfterThird = await throttle.waiterCount
        XCTAssertEqual(waitersAfterThird, 2, "Second and third operations should both be waiting")

        // Release gate
        gate.open()
        await op1.value
        await op2.value
        await op3.value

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

    // MARK: - Test 7: Priority dequeue — smallest first (Phase 3.2)

    func testThumbnailThrottle_priorityDequeue_smallestFirst() async {
        let throttle = ThumbnailThrottle(maxConcurrent: 1)
        let order = ManagedOrder()
        let gate = ManagedGate()

        // Hold the only slot
        async let op1: Void = throttle.withThrottle(priority: 0) {
            order.append(0)
            await gate.wait()
        }

        try? await Task.sleep(nanoseconds: 30_000_000) // let op1 acquire

        // Queue 3 waiters with different priorities (not FIFO order)
        async let opA: Void = throttle.withThrottle(priority: 30) {
            order.append(30)
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        async let opB: Void = throttle.withThrottle(priority: 10) {
            order.append(10)
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        async let opC: Void = throttle.withThrottle(priority: 20) {
            order.append(20)
        }

        try? await Task.sleep(nanoseconds: 30_000_000) // let all enqueue

        gate.open()
        await op1
        await opA
        await opB
        await opC

        // Should be: [0 (first acquired), 10, 20, 30] — priority order, not FIFO
        XCTAssertEqual(order.values, [0, 10, 20, 30],
                       "Waiters should dequeue by smallest priority (closest to center)")
    }

    // MARK: - Test 8: Same priority preserves FIFO (Phase 3.2)

    func testThumbnailThrottle_samePriority_preservesFIFO() async {
        let throttle = ThumbnailThrottle(maxConcurrent: 1)
        let order = ManagedOrder()
        let gate = ManagedGate()

        // Hold the only slot
        async let op1: Void = throttle.withThrottle(priority: 0) {
            order.append(0)
            await gate.wait()
        }

        try? await Task.sleep(nanoseconds: 30_000_000)

        // Queue 3 waiters with SAME priority
        async let opA: Void = throttle.withThrottle(priority: 5) {
            order.append(1)
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        async let opB: Void = throttle.withThrottle(priority: 5) {
            order.append(2)
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        async let opC: Void = throttle.withThrottle(priority: 5) {
            order.append(3)
        }

        try? await Task.sleep(nanoseconds: 30_000_000)

        gate.open()
        await op1
        await opA
        await opB
        await opC

        XCTAssertEqual(order.values, [0, 1, 2, 3],
                       "Same-priority waiters should dequeue in FIFO order")
    }

    // MARK: - Test 9: Default priority is 0 (highest) (Phase 3.2)

    func testThumbnailThrottle_defaultPriority_isZero() async {
        let throttle = ThumbnailThrottle(maxConcurrent: 1)
        let order = ManagedOrder()
        let gate = ManagedGate()

        // Hold slot
        async let op1: Void = throttle.withThrottle {
            order.append(0)
            await gate.wait()
        }

        try? await Task.sleep(nanoseconds: 30_000_000)

        // Enqueue with explicit high priority number (low priority)
        async let opA: Void = throttle.withThrottle(priority: 100) {
            order.append(100)
        }
        try? await Task.sleep(nanoseconds: 10_000_000)

        // Enqueue with default (should be 0 = highest)
        async let opB: Void = throttle.withThrottle {
            order.append(1)
        }

        try? await Task.sleep(nanoseconds: 30_000_000)

        gate.open()
        await op1
        await opA
        await opB

        // Default priority (0) should dequeue before explicit 100
        XCTAssertEqual(order.values, [0, 1, 100],
                       "Default priority (0) should dequeue before higher values")
    }

}

// MARK: - Integration Tests (Phase 3.2)

final class ThumbnailThrottlePriorityIntegrationTests: XCTestCase {

    func testLoadThumbnail_throttlePriority_passesThrough() async throws {
        #if !canImport(AppKit)
        throw XCTSkip("AppKit required for createJPEG")
        #else
        let url = try createJPEG(width: 200, height: 200)
        defer { try? FileManager.default.removeItem(at: url) }

        let loader = ImageLoader()
        let result = await loader.loadThumbnail(at: url, maxSize: 128, throttlePriority: 42)

        XCTAssertNotNil(result, "loadThumbnail with throttlePriority should produce valid result")
        let maxEdge = max(result!.image.size.width, result!.image.size.height)
        XCTAssertLessThanOrEqual(maxEdge, 128 + 1)
        #endif
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
