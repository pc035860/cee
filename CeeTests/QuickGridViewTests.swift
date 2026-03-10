@testable import Cee
import XCTest

// MARK: - Mock Delegate

@MainActor
private final class MockQuickGridDelegate: QuickGridViewDelegate {
    var selectedIndex: Int?
    var closeRequested = false
    var droppedURLs: [URL]?

    func quickGridView(_ view: QuickGridView, didSelectItemAt index: Int) {
        selectedIndex = index
    }

    func quickGridView(_ view: QuickGridView, didReceiveDrop urls: [URL]) {
        droppedURLs = urls
    }

    func quickGridViewDidRequestClose(_ view: QuickGridView) {
        closeRequested = true
    }
}

// MARK: - Tests

@MainActor
final class QuickGridViewTests: XCTestCase {

    private var tempDir: URL!
    /// Dummy collection view passed to dataSource methods (the actual private collectionView is inaccessible)
    private let dummyCV = NSCollectionView()

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CeeTests-Grid-\(UUID().uuidString)")
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

    // MARK: - Configure Tests

    func testConfigure_setsItemCount() {
        let grid = QuickGridView()
        let loader = ImageLoader()
        let items = makeItems(count: 5)

        grid.configure(items: items, currentIndex: 2, loader: loader)

        // NSCollectionViewDataSource reports correct count
        let count = grid.collectionView(dummyCV, numberOfItemsInSection: 0)
        XCTAssertEqual(count, 5)
    }

    func testConfigure_reconfigureUpdatesItems() {
        let grid = QuickGridView()
        let loader = ImageLoader()

        // Configure with 3 items
        let items3 = makeItems(count: 3)
        grid.configure(items: items3, currentIndex: 0, loader: loader)
        XCTAssertEqual(grid.collectionView(dummyCV, numberOfItemsInSection: 0), 3)

        // Reconfigure with 7 items (simulates folder change refresh)
        let items7 = makeItems(count: 7)
        grid.configure(items: items7, currentIndex: 0, loader: loader)
        XCTAssertEqual(grid.collectionView(dummyCV, numberOfItemsInSection: 0), 7)
    }

    // MARK: - clearCache vs cleanup

    func testClearCache_thenReconfigure_updatesItems() {
        let grid = QuickGridView()
        let loader = ImageLoader()

        // Configure with 3 items
        let items3 = makeItems(count: 3)
        grid.configure(items: items3, currentIndex: 0, loader: loader)
        XCTAssertEqual(grid.collectionView(dummyCV, numberOfItemsInSection: 0), 3)

        // clearCache + reconfigure with new folder's items
        grid.clearCache()
        let items5 = makeItems(count: 5)
        grid.configure(items: items5, currentIndex: 2, loader: loader)
        XCTAssertEqual(grid.collectionView(dummyCV, numberOfItemsInSection: 0), 5)
    }

    func testCleanup_doesNotCrash() {
        let grid = QuickGridView()
        let loader = ImageLoader()
        let items = makeItems(count: 3)

        grid.configure(items: items, currentIndex: 0, loader: loader)
        grid.cleanup()

        // After cleanup, data source still reports last-configured items
        // (cleanup clears cache but doesn't reset items array)
        XCTAssertEqual(grid.collectionView(dummyCV, numberOfItemsInSection: 0), 3)
    }

    // MARK: - Drag Registration

    func testRegisteredForFileURLDragType() {
        let grid = QuickGridView()
        let types = grid.registeredDraggedTypes
        XCTAssertTrue(types.contains(.fileURL), "QuickGridView should accept .fileURL drags")
    }

    // MARK: - Delegate Protocol

    func testDelegateProtocol_hasDropMethod() {
        let grid = QuickGridView()
        let delegate = MockQuickGridDelegate()
        grid.delegate = delegate

        // Verify the delegate method exists and can be called
        let testURLs = [URL(fileURLWithPath: "/tmp/test.png")]
        delegate.quickGridView(grid, didReceiveDrop: testURLs)
        XCTAssertEqual(delegate.droppedURLs, testURLs)
    }

    // MARK: - Cell Size Resize

    func testApplyItemSize_clampsToMinimum() {
        let grid = QuickGridView()
        grid.applyItemSize(10)
        XCTAssertEqual(grid.currentCellSize, Constants.quickGridMinCellSize,
                       "Cell size below minimum should clamp to \(Constants.quickGridMinCellSize)")
    }

    func testApplyItemSize_clampsToMaximum() {
        let grid = QuickGridView()
        grid.applyItemSize(999)
        XCTAssertEqual(grid.currentCellSize, Constants.quickGridMaxCellSize,
                       "Cell size above maximum should clamp to \(Constants.quickGridMaxCellSize)")
    }

    func testApplyItemSize_withinRange() {
        let grid = QuickGridView()
        grid.applyItemSize(200)
        XCTAssertEqual(grid.currentCellSize, 200,
                       "Cell size within range should be applied as-is")
    }

    func testApplyItemSize_noOpWhenSameSize() {
        let grid = QuickGridView()
        // Default is 160, applying 160 should be a no-op
        let initialSize = grid.currentCellSize
        grid.applyItemSize(initialSize)
        XCTAssertEqual(grid.currentCellSize, initialSize,
                       "Applying same size should not change currentCellSize")
    }

    func testApplyItemSize_consecutiveResizes() {
        let grid = QuickGridView()
        grid.applyItemSize(160)
        XCTAssertEqual(grid.currentCellSize, 160)
        grid.applyItemSize(220)
        XCTAssertEqual(grid.currentCellSize, 220)
        grid.applyItemSize(180)
        XCTAssertEqual(grid.currentCellSize, 180)
    }

    func testOnCellSizeDidChange_firesOnResize() {
        let grid = QuickGridView()
        var capturedSize: CGFloat?
        grid.onCellSizeDidChange = { size in capturedSize = size }

        grid.applyItemSize(200)
        XCTAssertEqual(capturedSize, 200, "onCellSizeDidChange should fire with clamped size")
    }

    func testOnCellSizeDidChange_doesNotFireOnSameSize() {
        let grid = QuickGridView()
        var callCount = 0
        grid.onCellSizeDidChange = { _ in callCount += 1 }

        grid.applyItemSize(grid.currentCellSize)
        XCTAssertEqual(callCount, 0, "onCellSizeDidChange should not fire when size unchanged")
    }

    // MARK: - Thumbnail Tier Boundary

    func testApplyItemSize_crossTierBoundary_preservesExistingGridThumbnails() {
        let grid = QuickGridView()
        let loader = ImageLoader()
        let items = makeItems(count: 3)
        grid.configure(items: items, currentIndex: 0, loader: loader)

        // Start in tier2 (121-240pt)
        grid.applyItemSize(200)
        injectMockThumbnails(into: grid, indices: [0, 1, 2])
        XCTAssertEqual(grid.gridThumbnailCount, 3, "Pre-condition: 3 thumbnails cached")

        // Cross to tier3 (>240pt) — old thumbnails stay until new tier loads in.
        grid.applyItemSize(260)
        XCTAssertEqual(grid.gridThumbnailCount, 3,
                       "Crossing tier2→tier3 boundary should preserve old thumbnails during progressive reload")
        XCTAssertNotEqual(grid._testCachedThumbnailSize(forIndex: 0), grid.currentGridThumbnailMaxSize,
                          "Cached thumbnail tier should remain old tier until replacement images finish loading")

        // Items should still be intact after progressive reload scheduling
        let count = grid.collectionView(dummyCV, numberOfItemsInSection: 0)
        XCTAssertEqual(count, 3, "Items should survive tier change reload")
    }

    func testApplyItemSize_withinSameTier_doesNotClearThumbnails() {
        let grid = QuickGridView()
        let loader = ImageLoader()
        let items = makeItems(count: 3)
        grid.configure(items: items, currentIndex: 0, loader: loader)

        // Both in tier2 (121-240pt): 160→200
        grid.applyItemSize(160)
        let countBefore = grid.gridThumbnailCount
        grid.applyItemSize(200)
        XCTAssertEqual(grid.gridThumbnailCount, countBefore,
                       "Same tier resize should not clear thumbnails")

        // Both in tier3 (>240pt): 260→300
        grid.applyItemSize(260)
        grid.applyItemSize(300)
        // No crash, size updated correctly
        XCTAssertEqual(grid.currentCellSize, 300)
    }

    func testApplyItemSize_animated_sameResult() {
        let grid = QuickGridView()
        var capturedSize: CGFloat?
        grid.onCellSizeDidChange = { size in capturedSize = size }

        grid.applyItemSize(200, animated: true)

        XCTAssertEqual(grid.currentCellSize, 200,
                       "Animated resize should produce same final state")
        XCTAssertEqual(capturedSize, 200,
                       "onCellSizeDidChange should fire for animated resize")
    }

    // MARK: - Cancel Non-Visible Tasks

    /// Helper: inject mock long-running tasks at given indices.
    private func injectMockTasks(into grid: QuickGridView, indices: [Int]) {
        for index in indices {
            let task = Task<Void, Never> {
                // Long-running task that waits until cancelled
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                }
            }
            grid._testSetTask(task, forIndex: index)
        }
    }

    func testCancelNonVisibleTasks_cancelsOutOfViewTasks() {
        let grid = QuickGridView()
        injectMockTasks(into: grid, indices: [0, 1, 2, 3, 4])

        XCTAssertEqual(grid.thumbnailTaskCount, 5, "Should have 5 tasks before cancel")

        grid.cancelNonVisibleTasks(visibleIndices: Set([1, 2]))

        XCTAssertEqual(grid.thumbnailTaskCount, 2,
                       "Should only keep 2 tasks for visible indices [1, 2]")
    }

    func testCancelNonVisibleTasks_preservesVisibleTasks() {
        let grid = QuickGridView()
        injectMockTasks(into: grid, indices: [0, 1, 2])

        grid.cancelNonVisibleTasks(visibleIndices: Set([0, 1, 2]))

        XCTAssertEqual(grid.thumbnailTaskCount, 3,
                       "All tasks visible — none should be cancelled")
    }

    func testCancelNonVisibleTasks_preservesCache() {
        let grid = QuickGridView()
        let loader = ImageLoader()
        let items = makeItems(count: 3)
        grid.configure(items: items, currentIndex: 0, loader: loader)

        // Manually populate gridThumbnails via loading
        // For this test, just verify the count accessor works with empty initial state
        let cacheBefore = grid.gridThumbnailCount

        injectMockTasks(into: grid, indices: [0, 1, 2])
        grid.cancelNonVisibleTasks(visibleIndices: Set([1]))

        XCTAssertEqual(grid.gridThumbnailCount, cacheBefore,
                       "cancelNonVisibleTasks should not touch gridThumbnails cache")
    }

    func testCancelNonVisibleTasks_emptyTasks_noOp() {
        let grid = QuickGridView()

        XCTAssertEqual(grid.thumbnailTaskCount, 0)
        grid.cancelNonVisibleTasks(visibleIndices: Set([0, 1]))
        XCTAssertEqual(grid.thumbnailTaskCount, 0,
                       "No crash on empty thumbnailTasks")
    }

    func testCancelNonVisibleTasks_allOutOfView() {
        let grid = QuickGridView()
        injectMockTasks(into: grid, indices: [0, 1, 2, 3])

        grid.cancelNonVisibleTasks(visibleIndices: Set())

        XCTAssertEqual(grid.thumbnailTaskCount, 0,
                       "All tasks should be cancelled when nothing is visible")
    }

    // MARK: - Window Cache Eviction

    /// Helper: inject mock thumbnails at given indices.
    private func injectMockThumbnails(into grid: QuickGridView, indices: [Int]) {
        let image = NSImage(size: NSSize(width: 10, height: 10))
        for index in indices {
            grid._testSetThumbnail(image, forIndex: index)
        }
    }

    func testEvictNonVisibleThumbnails_removesOutOfRange() {
        let grid = QuickGridView()
        // Populate cache with indices 0..99
        injectMockThumbnails(into: grid, indices: Array(0..<100))
        XCTAssertEqual(grid.gridThumbnailCount, 100)

        // Visible is [40..60], buffer is 50 → keepRange = 0..110
        // Since all are within 0..99, no eviction with default buffer=50
        // Use a scenario where eviction happens:
        // With 200 items and visible at [150..160], keep 100..210 → evict 0..99
        injectMockThumbnails(into: grid, indices: Array(100..<200))
        XCTAssertEqual(grid.gridThumbnailCount, 200)

        grid.evictNonVisibleThumbnails(visibleIndices: Set(150...160))

        // keepRange = max(0, 150-50)...160+50 = 100...210
        // Items 0..99 should be evicted
        XCTAssertLessThan(grid.gridThumbnailCount, 200,
                          "Should evict thumbnails outside visible + buffer window")
        XCTAssertEqual(grid.gridThumbnailCount, 100,
                       "Should keep only entries in range 100..199")
    }

    func testEvictNonVisibleThumbnails_preservesVisibleAndBuffer() {
        let grid = QuickGridView()
        injectMockThumbnails(into: grid, indices: Array(0..<20))

        // All within buffer range
        grid.evictNonVisibleThumbnails(visibleIndices: Set(5...15))

        // keepRange = max(0, 5-50)...15+50 = 0...65 → all 20 entries within range
        XCTAssertEqual(grid.gridThumbnailCount, 20,
                       "All entries within buffer should be preserved")
    }

    func testEvictNonVisibleThumbnails_emptyVisible_noOp() {
        let grid = QuickGridView()
        injectMockThumbnails(into: grid, indices: [0, 1, 2])

        grid.evictNonVisibleThumbnails(visibleIndices: Set())

        XCTAssertEqual(grid.gridThumbnailCount, 3,
                       "Empty visible should not evict anything (guard clause)")
    }

    func testEvictNonVisibleThumbnails_smallCache_noEviction() {
        let grid = QuickGridView()
        injectMockThumbnails(into: grid, indices: [5, 6, 7])

        grid.evictNonVisibleThumbnails(visibleIndices: Set([5, 6, 7]))

        XCTAssertEqual(grid.gridThumbnailCount, 3,
                       "Small cache within visible range should not evict")
    }

    // MARK: - Resolution Cap

    func testGridThumbnailMaxSize_highTier_returns720() {
        let grid = QuickGridView()
        // Set cell size above tier2 boundary (240pt) to trigger highest tier
        grid.applyItemSize(300)
        XCTAssertEqual(grid.currentGridThumbnailMaxSize, 720,
                       "Highest thumbnail tier should be 720px (not 1024)")
    }

    func testConstants_thumbnailSize3_is720() {
        XCTAssertEqual(Constants.quickGridThumbnailSize3, 720,
                       "quickGridThumbnailSize3 should be 720 for memory optimization")
    }

    // MARK: - Phase 4.1 Minimum Cell Size

    func testConstants_minCellSize_isAboveTier0Boundary() {
        XCTAssertGreaterThan(Constants.quickGridMinCellSize, Constants.quickGridTier0Boundary,
                            "Phase 4.1: min cell size must be > tier0 boundary to avoid throttle saturation")
    }

    func testConstants_sliderMaxWidth_is400() {
        XCTAssertEqual(Constants.quickGridSliderMaxWidth, 400,
                       "Slider max width should be 400pt (Finder-style)")
    }

    // MARK: - Tier 0 Adaptive Resolution (Phase 3.1)

    /// At min 160pt we're in tier2 (decode 480px).
    func testGridThumbnailMaxSize_minCellSize_returnsTier2() {
        let grid = QuickGridView()
        grid.applyItemSize(Constants.quickGridMinCellSize)
        XCTAssertEqual(grid.currentGridThumbnailMaxSize, 480,
                       "At minimum cell size (160pt) should return tier2 decode 480px")
    }

    func testGridThumbnailMaxSize_tier0_returnsQuantizedAdaptiveSize() {
        let grid = QuickGridView()
        grid._testSetCellSizeForTesting(40) // tier0: 40 * 2.0 = 80 → ceil(80/20)*20 = 80
        XCTAssertEqual(grid.currentGridThumbnailMaxSize, 80,
                       "Tier0 at 40pt should return quantized adaptive size 80")
    }

    func testGridThumbnailMaxSize_tier0_quantizationRoundsUp() {
        let grid = QuickGridView()
        grid._testSetCellSizeForTesting(45) // tier0: 45 * 2.0 = 90 → ceil(90/20)*20 = 100
        XCTAssertEqual(grid.currentGridThumbnailMaxSize, 100,
                       "Tier0 at 45pt should quantize 90→100 (rounds up to 20px step)")
    }

    func testGridThumbnailMaxSize_tier0Boundary_exactBoundary() {
        let grid = QuickGridView()
        grid._testSetCellSizeForTesting(60) // tier0: 60 * 2.0 = 120 → ceil(120/20)*20 = 120
        XCTAssertEqual(grid.currentGridThumbnailMaxSize, 120,
                       "Tier0 at exact boundary 60pt should return 120")
    }

    func testGridThumbnailMaxSize_aboveTier0_returnsTier1() {
        let grid = QuickGridView()
        grid._testSetCellSizeForTesting(80) // tier1 (61-120pt) = 240
        XCTAssertEqual(grid.currentGridThumbnailMaxSize, 240,
                       "Above tier0 boundary should fall to tier1 (240)")
    }

    func testApplyItemSize_withinSameTier_noCacheClear() {
        let grid = QuickGridView()
        let loader = ImageLoader()
        let items = makeItems(count: 3)
        grid.configure(items: items, currentIndex: 0, loader: loader)

        // Both in tier2 (121-240pt)
        grid.applyItemSize(160)
        injectMockThumbnails(into: grid, indices: [0, 1, 2])
        let countBefore = grid.gridThumbnailCount

        grid.applyItemSize(200)
        XCTAssertEqual(grid.currentGridThumbnailMaxSize, 480,
                       "Both 160 and 200pt are tier2 (480px)")
        XCTAssertEqual(grid.gridThumbnailCount, countBefore,
                       "Same tier resize should not clear thumbnails")
    }

    // MARK: - Memory Cap

    func testGridThumbnailMaxCount_isReasonable() {
        let grid = QuickGridView()
        let maxCount = grid._testGridThumbnailMaxCount
        XCTAssertGreaterThanOrEqual(maxCount, 50,
                                    "Max count floor should be at least 50")
        XCTAssertLessThan(maxCount, 10000,
                          "Max count should be reasonable (not millions)")
    }

    func testGridThumbnails_enforcesMemoryCap() {
        let grid = QuickGridView()
        let maxCount = grid._testGridThumbnailMaxCount

        // Inject maxCount + 20 thumbnails
        let overCount = maxCount + 20
        injectMockThumbnails(into: grid, indices: Array(0..<overCount))
        XCTAssertEqual(grid.gridThumbnailCount, overCount, "Pre-condition: all injected")

        // Trigger cap enforcement
        grid.enforceGridThumbnailCap(currentIndex: overCount / 2)

        XCTAssertLessThanOrEqual(grid.gridThumbnailCount, maxCount,
                                  "Cache should not exceed memory cap after enforcement")
    }

    // MARK: - Scroll Anchor (Continuous Scroll Resize)

    func testComputeScrollAnchor_atTopOfGrid() {
        // Viewport center is in the first row
        let (item, frac) = QuickGridView.computeScrollAnchor(
            viewportMidY: 50, cellHeight: 100, lineSpacing: 4,
            topInset: 8, columns: 5, itemCount: 100
        )
        // Row 0: rowY = 8, fraction = (50-8)/100 = 0.42
        XCTAssertEqual(item, 0)
        XCTAssertEqual(frac, 0.42, accuracy: 0.01)
    }

    func testComputeScrollAnchor_midGrid() {
        // viewportMidY = 430, cellH=100, lineSpacing=4, topInset=8, cols=5
        // rowHeight = 104, row = floor((430-8)/104) = floor(4.05) = 4
        // itemIndex = 4*5 = 20, rowY = 8 + 4*104 = 424
        // fraction = (430-424)/100 = 0.06
        let (item, frac) = QuickGridView.computeScrollAnchor(
            viewportMidY: 430, cellHeight: 100, lineSpacing: 4,
            topInset: 8, columns: 5, itemCount: 100
        )
        XCTAssertEqual(item, 20)
        XCTAssertEqual(frac, 0.06, accuracy: 0.01)
    }

    func testComputeScrollAnchor_emptyItems_returnsZero() {
        let (item, frac) = QuickGridView.computeScrollAnchor(
            viewportMidY: 200, cellHeight: 100, lineSpacing: 4,
            topInset: 8, columns: 5, itemCount: 0
        )
        XCTAssertEqual(item, 0)
        XCTAssertEqual(frac, 0)
    }

    func testComputeRestoredScrollY_sameColumns_preservesPosition() {
        // Anchor at item 20 with fraction 0.5, 5 columns → row 4
        // newRowY = 8 + 4*104 = 424, targetMidY = 424 + 0.5*100 = 474
        // targetY = 474 - 300 = 174
        let y = QuickGridView.computeRestoredScrollY(
            anchorItemIndex: 20, anchorFraction: 0.5,
            cellHeight: 100, lineSpacing: 4,
            topInset: 8, bottomInset: 8,
            columns: 5, viewportHeight: 600, itemCount: 100
        )
        XCTAssertEqual(y, 174, accuracy: 0.01)
    }

    func testComputeRestoredScrollY_columnChange_adjustsRow() {
        // Anchor item 20 was in row 4 (5 cols). Now 4 cols → row 5.
        // newRowY = 8 + 5*104 = 528, targetMidY = 528 + 0.5*100 = 578
        // targetY = 578 - 300 = 278
        let y = QuickGridView.computeRestoredScrollY(
            anchorItemIndex: 20, anchorFraction: 0.5,
            cellHeight: 100, lineSpacing: 4,
            topInset: 8, bottomInset: 8,
            columns: 4, viewportHeight: 600, itemCount: 100
        )
        XCTAssertEqual(y, 278, accuracy: 0.01)
    }

    func testComputeRestoredScrollY_clampsToTop() {
        // Anchor near top, restored Y would be negative → clamp to 0
        let y = QuickGridView.computeRestoredScrollY(
            anchorItemIndex: 0, anchorFraction: 0.0,
            cellHeight: 100, lineSpacing: 4,
            topInset: 8, bottomInset: 8,
            columns: 5, viewportHeight: 600, itemCount: 100
        )
        XCTAssertEqual(y, 0, accuracy: 0.01)
    }

    func testComputeRestoredScrollY_clampsToBottom() {
        // 20 items, 5 cols → 4 rows, docH = 8 + 4*104 - 4 + 8 = 428
        // viewport 600 > docH 428 → maxScrollY = 0
        let y = QuickGridView.computeRestoredScrollY(
            anchorItemIndex: 15, anchorFraction: 0.5,
            cellHeight: 100, lineSpacing: 4,
            topInset: 8, bottomInset: 8,
            columns: 5, viewportHeight: 600, itemCount: 20
        )
        XCTAssertEqual(y, 0, accuracy: 0.01)
    }

    func testScrollAnchor_roundTrip_sameColumns_preservesScrollY() {
        // Simulate: capture at scrollY with 5 cols, restore with 5 cols → same Y
        let cellH: CGFloat = 100, lineSpacing: CGFloat = 4
        let topInset: CGFloat = 8, bottomInset: CGFloat = 8
        let viewportH: CGFloat = 600
        let scrollOriginY: CGFloat = 500
        let viewportMidY = scrollOriginY + viewportH / 2 // 800

        let (item, frac) = QuickGridView.computeScrollAnchor(
            viewportMidY: viewportMidY, cellHeight: cellH, lineSpacing: lineSpacing,
            topInset: topInset, columns: 5, itemCount: 200
        )
        let restoredY = QuickGridView.computeRestoredScrollY(
            anchorItemIndex: item, anchorFraction: frac,
            cellHeight: cellH, lineSpacing: lineSpacing,
            topInset: topInset, bottomInset: bottomInset,
            columns: 5, viewportHeight: viewportH, itemCount: 200
        )
        // Should restore to approximately the same scrollOriginY
        XCTAssertEqual(restoredY, scrollOriginY, accuracy: 1.0,
                       "Round-trip with same columns should preserve scroll position")
    }

    func testScrollAnchor_roundTrip_columnChange_keepsAnchorVisible() {
        // Capture with 5 cols, restore with 4 cols → anchor item still in viewport
        let cellH: CGFloat = 100, lineSpacing: CGFloat = 4
        let topInset: CGFloat = 8, bottomInset: CGFloat = 8
        let viewportH: CGFloat = 600
        let scrollOriginY: CGFloat = 500
        let viewportMidY = scrollOriginY + viewportH / 2

        let (item, frac) = QuickGridView.computeScrollAnchor(
            viewportMidY: viewportMidY, cellHeight: cellH, lineSpacing: lineSpacing,
            topInset: topInset, columns: 5, itemCount: 200
        )

        let restoredY = QuickGridView.computeRestoredScrollY(
            anchorItemIndex: item, anchorFraction: frac,
            cellHeight: cellH, lineSpacing: lineSpacing,
            topInset: topInset, bottomInset: bottomInset,
            columns: 4, viewportHeight: viewportH, itemCount: 200
        )

        // Verify anchor item's row is within restored viewport
        let newRow = item / 4
        let newRowY = topInset + CGFloat(newRow) * (cellH + lineSpacing)
        XCTAssertGreaterThanOrEqual(newRowY, restoredY,
                                     "Anchor row should be at or below viewport top")
        XCTAssertLessThanOrEqual(newRowY, restoredY + viewportH,
                                  "Anchor row should be at or above viewport bottom")
    }
}
