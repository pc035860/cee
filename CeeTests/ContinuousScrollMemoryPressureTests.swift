@testable import Cee
import XCTest

// MARK: - ContinuousScrollContentView Memory Pressure Tests

@MainActor
final class ContinuousScrollMemoryPressureTests: XCTestCase {

    private var sut: ContinuousScrollContentView!

    override func setUp() {
        super.setUp()
        sut = ContinuousScrollContentView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    }

    override func tearDown() {
        sut?.cleanup()
        sut = nil
        super.tearDown()
    }

    // MARK: - Test 1: Warning pressure shrinks buffer

    func testWarningPressure_shrinksBufferToZero() {
        // Setup: configure with image sizes to establish layout
        configureSUTWithMockSizes(count: 20)

        // Pre-condition: buffer should be at default (2)
        XCTAssertEqual(sut._testBufferCount(), 2, "Default buffer count should be 2")

        // Act: simulate warning pressure
        sut._testHandleMemoryPressure(.warning)

        // Assert: buffer shrunk to 0
        XCTAssertEqual(sut._testBufferCount(), 0,
                       "Warning pressure should shrink buffer to 0")
    }

    // MARK: - Test 2: Critical pressure clears non-visible slots

    func testCriticalPressure_clearsNonVisibleSlots() {
        // Setup: configure with images and simulate some slots being active
        configureSUTWithMockSizes(count: 20)

        // Trigger slot creation by updating visible area (middle of content)
        let visibleBounds = NSRect(x: 0, y: 400, width: 800, height: 600)
        sut.updateVisibleSlots(for: visibleBounds)

        let activeCountBefore = sut._testActiveSlotCount()
        XCTAssertGreaterThan(activeCountBefore, 0, "Should have active slots after update")

        // Act: simulate critical pressure
        sut._testHandleMemoryPressure(.critical)

        // Assert: only visible slots remain (buffer = 0 under critical)
        // The exact count depends on how many are truly visible,
        // but it should be less than before (non-visible with buffer removed)
        let activeCountAfter = sut._testActiveSlotCount()
        XCTAssertLessThanOrEqual(activeCountAfter, activeCountBefore,
                                 "Critical pressure should reduce active slot count")
        XCTAssertEqual(sut._testReusableSlotCount(), 0,
                       "Critical pressure should clear reusable pool")
    }

    // MARK: - Test 3: Monitor lifecycle — starts on configure, stops on cleanup

    func testMonitorLifecycle_startsOnConfigure_stopsOnCleanup() {
        // Before configure: monitor should not be running
        XCTAssertFalse(sut._testIsMonitorRunning(),
                       "Monitor should not run before configure")

        // Act: configure
        configureSUTWithMockSizes(count: 5)

        // Assert: monitor is running
        XCTAssertTrue(sut._testIsMonitorRunning(),
                      "Monitor should run after configure")

        // Act: cleanup
        sut.cleanup()

        // Assert: monitor stopped
        XCTAssertFalse(sut._testIsMonitorRunning(),
                       "Monitor should stop after cleanup")
    }

    // MARK: - Test 4: Idempotent configure doesn't leak monitors

    func testIdempotentConfigure_doesNotLeakMonitors() {
        // Configure twice — should not create duplicate DispatchSources
        configureSUTWithMockSizes(count: 5)
        configureSUTWithMockSizes(count: 10)

        // Monitor should still be running (not crashed/leaked)
        XCTAssertTrue(sut._testIsMonitorRunning(),
                      "Monitor should remain running after re-configure")
    }

    // MARK: - Test 5: Buffer restoration on next scroll

    func testBufferRestoration_afterWarning_onNextScroll() {
        configureSUTWithMockSizes(count: 20)

        // Warning shrinks buffer
        sut._testHandleMemoryPressure(.warning)
        XCTAssertEqual(sut._testBufferCount(), 0)

        // Next scroll should restore buffer
        let visibleBounds = NSRect(x: 0, y: 400, width: 800, height: 600)
        sut.updateVisibleSlots(for: visibleBounds)

        XCTAssertEqual(sut._testBufferCount(), 2,
                       "Buffer should restore to default after next scroll")
    }

    // MARK: - Test 6: Memory pressure during zoom is deferred

    func testPressureDuringZoom_isDeferredUntilEndZoom() {
        configureSUTWithMockSizes(count: 20)

        // Start zoom
        sut.beginZoomSuppression()

        // Simulate critical pressure during zoom
        sut._testHandleMemoryPressure(.critical)

        // Buffer should NOT have changed (deferred)
        XCTAssertEqual(sut._testBufferCount(), 2,
                       "Pressure should be deferred during zoom")

        // End zoom — deferred pressure should be processed
        let visibleBounds = NSRect(x: 0, y: 400, width: 800, height: 600)
        sut.endZoomSuppression(visibleBounds: visibleBounds)

        // Now pressure should have been applied
        XCTAssertEqual(sut._testBufferCount(), 0,
                       "Deferred critical pressure should shrink buffer after zoom ends")
    }

    // MARK: - Test 7: Pending pressure takes max level

    func testPendingPressure_takesMaxLevel() {
        configureSUTWithMockSizes(count: 20)

        sut.beginZoomSuppression()

        // Send warning, then critical
        sut._testHandleMemoryPressure(.warning)
        sut._testHandleMemoryPressure(.critical)

        // End zoom
        let visibleBounds = NSRect(x: 0, y: 400, width: 800, height: 600)
        sut.endZoomSuppression(visibleBounds: visibleBounds)

        // Critical should have been processed (not warning)
        XCTAssertEqual(sut._testBufferCount(), 0,
                       "Should process critical (max) level")
        XCTAssertEqual(sut._testReusableSlotCount(), 0,
                       "Critical clears reusable pool")
    }

    // MARK: - Helpers

    /// Configure SUT with mock image sizes (no real ImageLoader needed for layout tests)
    private func configureSUTWithMockSizes(count: Int) {
        let sizes = (0..<count).map { _ in NSSize(width: 800, height: 1200) }
        sut._testConfigureWithSizes(sizes)
    }
}

// MARK: - ImageLoader clearImageCache Tests

final class ImageLoaderClearCacheTests: XCTestCase {

    func testClearImageCache_emptiesAllCaches() async {
        let loader = ImageLoader()

        // Pre-populate cache by loading an image
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).png")
        try! minimalPNG().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        _ = await loader.loadImage(at: url)

        // Verify cache is populated
        let countBefore = await loader._testImageCacheCount()
        XCTAssertGreaterThan(countBefore, 0, "Cache should have entries after loading")

        // Act
        await loader.clearImageCache()

        // Assert
        let countAfter = await loader._testImageCacheCount()
        XCTAssertEqual(countAfter, 0, "clearImageCache should empty the cache")
    }
}
