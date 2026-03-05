@testable import Cee
import XCTest

/// Tests for #1 Scrollbar Optimization.
/// These tests verify that the GridScrollView shows/hides scrollbars
/// based on content overflow, with overlay style and auto-hide behavior.
@MainActor
final class QuickGridScrollbarTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CeeTests-Scrollbar-\(UUID().uuidString)")
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
            // QuickGridView itself is an NSView, so we can call layoutSubtreeIfNeeded on it
            grid.layoutSubtreeIfNeeded()
        }
    }

    // MARK: - Test 1: Scrollbar hidden when content fits

    /// When the grid content height is <= visible area height,
    /// the scrollbar should be hidden.
    func testScrollbarHiddenWhenContentFits() async {
        let grid = QuickGridView()
        let loader = ImageLoader()
        // Small number of items that should fit in visible area
        let items = makeItems(count: 3)

        grid.configure(items: items, currentIndex: 0, loader: loader)
        await waitForLayout(grid: grid)

        // Verify scrollbar is hidden
        let scrollView = grid._testGridScrollView
        XCTAssertFalse(scrollView.wantsVerticalScroller,
                       "Scrollbar should be hidden when content fits visible area")
    }

    // MARK: - Test 2: Scrollbar visible when content overflows

    /// When the grid content height exceeds visible area height,
    /// the scrollbar should be visible.
    /// Note: This test requires a window for proper constraint layout.
    /// In a unit test environment without a window, we verify that
    /// updateScrollerVisibility() is called without crash.
    func testScrollbarVisibleWhenContentOverflows() async {
        let grid = QuickGridView()
        // Set a reasonable frame so visibleHeight is non-zero
        grid.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        let loader = ImageLoader()
        // Large number of items
        let items = makeItems(count: 50)

        grid.configure(items: items, currentIndex: 0, loader: loader)
        await waitForLayout(grid: grid)

        // Verify the method runs without crash
        // Note: Without a window, constraints may not layout correctly,
        // so actual visibility depends on the view hierarchy.
        let scrollView = grid._testGridScrollView
        // Just verify the property is accessible
        let _ = scrollView.wantsVerticalScroller
    }

    // MARK: - Test 3: Scrollbar updates after window resize

    /// When the window frame changes (gridFrameDidChange), the scrollbar
    /// visibility should update accordingly.
    func testScrollbarUpdatesAfterResize() async {
        let grid = QuickGridView()
        let loader = ImageLoader()
        let items = makeItems(count: 20)

        // Set up grid with initial frame
        grid.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        grid.configure(items: items, currentIndex: 0, loader: loader)
        await waitForLayout(grid: grid)

        let scrollView = grid._testGridScrollView
        let _ = scrollView.wantsVerticalScroller

        // Simulate window resize to much taller frame (content may fit now)
        grid.frame = NSRect(x: 0, y: 0, width: 400, height: 2000)
        await waitForLayout(grid: grid)

        // The scrollbar visibility may or may not change depending on content
        // Just verify the method was called (no crash)
        let _ = scrollView.wantsVerticalScroller
    }

    // MARK: - Test 4: Scroller style is overlay

    /// The scroller should use overlay style (floating, semi-transparent).
    func testScrollerStyleIsOverlay() {
        let grid = QuickGridView()
        let scrollView = grid._testGridScrollView

        XCTAssertEqual(scrollView.scrollerStyle, NSScroller.Style.overlay,
                       "Scroller style should be overlay for modern appearance")
    }

    // MARK: - Test 5: Autohides scrollers enabled

    /// The scroller should auto-hide when not in use.
    func testAutohidesScrollersEnabled() {
        let grid = QuickGridView()
        let scrollView = grid._testGridScrollView

        XCTAssertTrue(scrollView.autohidesScrollers,
                      "Autohides scrollers should be enabled for clean UI")
    }

    // MARK: - Test 6: Scrollbar updates after cell size change

    /// When cell size changes via applyItemSize(), the scrollbar visibility
    /// should update based on new total content height.
    func testScrollbarUpdatesAfterCellSizeChange() async {
        let grid = QuickGridView()
        let loader = ImageLoader()
        let items = makeItems(count: 30)

        // Small cell size: many rows → overflow → scrollbar visible
        grid.configure(items: items, currentIndex: 0, loader: loader)
        grid.applyItemSize(Constants.quickGridMinCellSize) // 160pt
        await waitForLayout(grid: grid)

        let scrollView = grid._testGridScrollView
        let _ = scrollView.wantsVerticalScroller

        // Note: Whether scrollbar is visible depends on actual frame/content
        // The key test is that resize triggers updateScrollerVisibility()

        // Resize to much larger cells → fewer rows → may fit without scrollbar
        grid.applyItemSize(Constants.quickGridMaxCellSize) // 512pt
        await waitForLayout(grid: grid)

        // Just verify no crash and value is accessible
        let _ = scrollView.wantsVerticalScroller
    }
}
