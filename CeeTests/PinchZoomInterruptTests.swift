@testable import Cee
import XCTest

/// Tests for #3 Pinch Zoom Interrupt.
/// These tests verify that tier change reloads are deferred during pinch gestures
/// to prevent main thread blocking and gesture interruption.
@MainActor
final class PinchZoomInterruptTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CeeTests-Pinch-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeItems(count: Int) -> [ImageItem] {
        (0..<count).map { i in
            let name = String(format: "img%03d.png", i)
            let url = tempDir.appendingPathComponent(name)
            try! minimalPNG().write(to: url)
            return ImageItem(url: url)
        }
    }

    /// Helper to trigger layout and wait for completion
    private func waitForLayout(grid: QuickGridView) async {
        await MainActor.run {
            grid.layoutSubtreeIfNeeded()
        }
    }

    // MARK: - Test 1: Tier change reload deferred during pinch

    /// When a tier boundary is crossed during pinch gesture,
    /// reload should be deferred until gesture ends.
    func testTierChangeDeferredDuringPinch() async {
        let grid = QuickGridView()
        let loader = ImageLoader()
        let items = makeItems(count: 20)

        grid.configure(items: items, currentIndex: 0, loader: loader)
        grid.applyItemSize(160, phase: [])  // Start at tier2 (160pt)
        await waitForLayout(grid: grid)

        // Simulate pinch gesture: began → changed (cross tier) → ended
        grid.applyItemSize(160, phase: .began)  // Gesture began
        grid.applyItemSize(300, phase: .changed)  // Cross to tier3 (>240pt)

        // Verify tier change is pending but not reloaded yet
        XCTAssertTrue(grid._testPendingTierChange,
                      "Tier change should be pending during gesture")
        XCTAssertFalse(grid._testTierChangeWorkItemScheduled,
                       "Reload work item should NOT be scheduled during gesture")

        // Gesture ended
        grid.applyItemSize(300, phase: .ended)

        // Now work item should be scheduled
        XCTAssertTrue(grid._testTierChangeWorkItemScheduled,
                      "Reload work item should be scheduled after gesture ended")
    }

    // MARK: - Test 1b: Pinch keeps cached thumbnails intact

    /// Crossing tiers during an active pinch should not clear cached thumbnails.
    func testPinchDoesNotClearCacheMidGesture() async {
        let grid = QuickGridView()
        let loader = ImageLoader()
        let items = makeItems(count: 20)

        grid.configure(items: items, currentIndex: 0, loader: loader)
        grid.applyItemSize(160, phase: [])
        await waitForLayout(grid: grid)

        let image = NSImage(size: NSSize(width: 10, height: 10))
        grid._testSetThumbnail(image, forIndex: 0)
        grid._testSetThumbnail(image, forIndex: 1)

        grid.applyItemSize(160, phase: .began)
        grid.applyItemSize(300, phase: .changed)

        XCTAssertEqual(grid.gridThumbnailCount, 2,
                       "Pinch should keep existing thumbnails until replacement tier finishes")
    }

    // MARK: - Test 2: Deferred reload cancelled on new gesture

    /// When a new gesture starts before deferred reload executes,
    /// the pending work item should be cancelled.
    func testDeferredReloadCancelledOnNewGesture() async {
        let grid = QuickGridView()
        let loader = ImageLoader()
        let items = makeItems(count: 20)

        grid.configure(items: items, currentIndex: 0, loader: loader)
        grid.applyItemSize(160, phase: [])
        await waitForLayout(grid: grid)

        // First gesture: cross tier and end
        grid.applyItemSize(160, phase: .began)
        grid.applyItemSize(300, phase: .changed)
        grid.applyItemSize(300, phase: .ended)

        XCTAssertTrue(grid._testTierChangeWorkItemScheduled,
                      "Work item should be scheduled after first gesture")

        // Second gesture: began should cancel pending work
        grid.applyItemSize(300, phase: .began)

        XCTAssertFalse(grid._testPendingTierChange,
                       "Pending tier change should be cleared on new gesture began")
        XCTAssertFalse(grid._testTierChangeWorkItemScheduled,
                       "Work item should be cancelled on new gesture began")
    }

    // MARK: - Test 3: Multiple tier changes coalesced

    /// Multiple tier crossings during a single gesture should result
    /// in only one reload after gesture ends.
    func testMultipleTierChangesCoalesced() async {
        let grid = QuickGridView()
        let loader = ImageLoader()
        let items = makeItems(count: 20)

        grid.configure(items: items, currentIndex: 0, loader: loader)
        grid.applyItemSize(160, phase: [])  // tier2
        await waitForLayout(grid: grid)

        // Gesture with multiple tier crossings
        grid.applyItemSize(160, phase: .began)
        grid.applyItemSize(300, phase: .changed)  // tier2 → tier3
        grid.applyItemSize(200, phase: .changed)  // tier3 → tier2
        grid.applyItemSize(100, phase: .changed)  // tier2 → tier1
        grid.applyItemSize(100, phase: .ended)

        // Should have pending = true and one work item scheduled
        XCTAssertTrue(grid._testPendingTierChange,
                      "Tier change should be pending after gesture ended")
        XCTAssertTrue(grid._testTierChangeWorkItemScheduled,
                      "Exactly one work item should be scheduled")
    }

    // MARK: - Test 4: Momentum phase ignored

    /// Momentum phase events after gesture ended should not
    /// reschedule the deferred reload.
    func testMomentumPhaseIgnored() async {
        let grid = QuickGridView()
        let loader = ImageLoader()
        let items = makeItems(count: 20)

        grid.configure(items: items, currentIndex: 0, loader: loader)
        grid.applyItemSize(160, phase: [])
        await waitForLayout(grid: grid)

        // Gesture ended
        grid.applyItemSize(160, phase: .began)
        grid.applyItemSize(300, phase: .changed)
        grid.applyItemSize(300, phase: .ended)

        // Capture the work item state
        let workItemBeforeMomentum = grid._testTierChangeWorkItemScheduled

        // Momentum events (should not affect scheduled work)
        grid.applyItemSize(300, phase: .changed)  // momentum

        XCTAssertEqual(grid._testTierChangeWorkItemScheduled, workItemBeforeMomentum,
                       "Momentum phase should not change work item state")
    }

    // MARK: - Test 5: Slider triggers immediate reload

    /// Slider changes (non-gesture) should trigger reload without clearing cache first.
    func testSliderTriggersImmediateReload() async {
        let grid = QuickGridView()
        let loader = ImageLoader()
        let items = makeItems(count: 20)

        grid.configure(items: items, currentIndex: 0, loader: loader)
        grid.applyItemSize(160, phase: [])
        await waitForLayout(grid: grid)

        // Inject thumbnails to track reload
        let image = NSImage(size: NSSize(width: 10, height: 10))
        grid._testSetThumbnail(image, forIndex: 0)
        grid._testSetThumbnail(image, forIndex: 1)
        XCTAssertEqual(grid.gridThumbnailCount, 2, "Pre-condition: 2 thumbnails cached")

        // Slider change (phase = []) should reload progressively
        grid.applyItemSize(300, phase: [])

        XCTAssertFalse(grid._testPendingTierChange,
                       "Slider change should not set pending tier change")
        XCTAssertFalse(grid._testTierChangeWorkItemScheduled,
                       "Slider change should not schedule deferred work")
        XCTAssertEqual(grid.gridThumbnailCount, 2,
                       "Progressive reload should keep existing thumbnails while new tier loads")
    }

    // MARK: - Test 6: Cancelled gesture still reloads

    /// When gesture is cancelled (user switches window, etc.),
    /// deferred reload should still be scheduled.
    func testCancelledGestureStillReloads() async {
        let grid = QuickGridView()
        let loader = ImageLoader()
        let items = makeItems(count: 20)

        grid.configure(items: items, currentIndex: 0, loader: loader)
        grid.applyItemSize(160, phase: [])
        await waitForLayout(grid: grid)

        // Gesture cancelled
        grid.applyItemSize(160, phase: .began)
        grid.applyItemSize(300, phase: .changed)
        grid.applyItemSize(300, phase: .cancelled)

        // Cancelled gesture should still schedule reload
        XCTAssertTrue(grid._testPendingTierChange,
                      "Tier change should be pending after cancelled gesture")
        XCTAssertTrue(grid._testTierChangeWorkItemScheduled,
                      "Reload work item should be scheduled after cancelled gesture")
    }
}
