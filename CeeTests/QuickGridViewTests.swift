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
        grid.applyItemSize(50)
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
        grid.applyItemSize(150)
        XCTAssertEqual(grid.currentCellSize, 150,
                       "Cell size within range should be applied as-is")
    }

    func testApplyItemSize_noOpWhenSameSize() {
        let grid = QuickGridView()
        // Default is 120, applying 120 should be a no-op
        let initialSize = grid.currentCellSize
        grid.applyItemSize(initialSize)
        XCTAssertEqual(grid.currentCellSize, initialSize,
                       "Applying same size should not change currentCellSize")
    }

    func testApplyItemSize_consecutiveResizes() {
        let grid = QuickGridView()
        grid.applyItemSize(100)
        XCTAssertEqual(grid.currentCellSize, 100)
        grid.applyItemSize(180)
        XCTAssertEqual(grid.currentCellSize, 180)
        grid.applyItemSize(80)
        XCTAssertEqual(grid.currentCellSize, 80)
    }

    func testOnCellSizeDidChange_firesOnResize() {
        let grid = QuickGridView()
        var capturedSize: CGFloat?
        grid.onCellSizeDidChange = { size in capturedSize = size }

        grid.applyItemSize(140)
        XCTAssertEqual(capturedSize, 140, "onCellSizeDidChange should fire with clamped size")
    }

    func testOnCellSizeDidChange_doesNotFireOnSameSize() {
        let grid = QuickGridView()
        var callCount = 0
        grid.onCellSizeDidChange = { _ in callCount += 1 }

        grid.applyItemSize(grid.currentCellSize)
        XCTAssertEqual(callCount, 0, "onCellSizeDidChange should not fire when size unchanged")
    }

    // MARK: - Thumbnail Tier Boundary

    func testApplyItemSize_crossTierBoundary_clearsGridThumbnails() {
        let grid = QuickGridView()
        let loader = ImageLoader()
        let items = makeItems(count: 3)
        grid.configure(items: items, currentIndex: 0, loader: loader)

        // Start in low tier (<=120pt)
        grid.applyItemSize(100)
        XCTAssertEqual(grid.currentCellSize, 100)

        // Cross 120pt boundary into high tier (>120pt) — should clear gridThumbnails
        grid.applyItemSize(130)
        XCTAssertEqual(grid.currentCellSize, 130)
        XCTAssertEqual(grid.gridThumbnailCount, 0,
                       "Crossing tier boundary should clear grid thumbnails")

        // Items should still be intact after reloadData
        let count = grid.collectionView(dummyCV, numberOfItemsInSection: 0)
        XCTAssertEqual(count, 3, "Items should survive tier change reload")
    }

    func testApplyItemSize_withinSameTier_doesNotClearThumbnails() {
        let grid = QuickGridView()
        let loader = ImageLoader()
        let items = makeItems(count: 3)
        grid.configure(items: items, currentIndex: 0, loader: loader)

        // Both in low tier (<=120pt): 80→100
        grid.applyItemSize(80)
        let countBefore = grid.gridThumbnailCount
        grid.applyItemSize(100)
        XCTAssertEqual(grid.gridThumbnailCount, countBefore,
                       "Same tier resize should not clear thumbnails")

        // Both in high tier (>120pt): 130→180
        grid.applyItemSize(130)
        grid.applyItemSize(180)
        // No crash, size updated correctly
        XCTAssertEqual(grid.currentCellSize, 180)
    }

    func testApplyItemSize_animated_sameResult() {
        let grid = QuickGridView()
        var capturedSize: CGFloat?
        grid.onCellSizeDidChange = { size in capturedSize = size }

        grid.applyItemSize(150, animated: true)

        XCTAssertEqual(grid.currentCellSize, 150,
                       "Animated resize should produce same final state")
        XCTAssertEqual(capturedSize, 150,
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
}
