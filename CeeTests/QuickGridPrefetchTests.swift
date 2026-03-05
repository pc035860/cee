@testable import Cee
import XCTest

@MainActor
final class QuickGridPrefetchTests: XCTestCase {

    // MARK: - columnsPerRow (static)

    func testColumnsPerRow_normalWidth() {
        // 400pt available, 100pt cells, spacing=4, inset=8
        // floor((400 - 16 + 4) / (100 + 4)) = floor(388/104) = floor(3.73) = 3
        let cols = QuickGridView.columnsPerRow(availableWidth: 400, cellSize: 100)
        XCTAssertEqual(cols, 3)
    }

    func testColumnsPerRow_narrowWidth() {
        // 50pt available, 100pt cells → should clamp to 1
        let cols = QuickGridView.columnsPerRow(availableWidth: 50, cellSize: 100)
        XCTAssertEqual(cols, 1)
    }

    // MARK: - computeVisibleRange (static, Phase 3.4)

    func testComputeVisibleRange_topOfDocument() {
        // 3 cols, 100 items, cellH=90, spacing=4, inset=8, scrollY=0, viewportH=500
        // rowHeight=94, rows visible = ceil((500-8)/94) = ceil(5.23) = 6 → rows 0..5
        // firstVisible = 0, lastVisible = 5*3+2 = 17
        let range = QuickGridView.computeVisibleRange(
            scrollOriginY: 0, viewportHeight: 500,
            cellHeight: 90, lineSpacing: 4, topInset: 8,
            cols: 3, itemCount: 100)
        XCTAssertEqual(range, 0...17)
    }

    func testComputeVisibleRange_normalScroll() {
        // scrollY=200, viewportH=300 → content from 200 to 500
        // rowHeight=94, firstRow = floor((200-8)/94) = floor(2.04) = 2
        // lastRow = ceil((500-8)/94) - 1 = ceil(5.23) - 1 = 5
        // firstVisible = 2*3 = 6, lastVisible = 5*3+2 = 17
        let range = QuickGridView.computeVisibleRange(
            scrollOriginY: 200, viewportHeight: 300,
            cellHeight: 90, lineSpacing: 4, topInset: 8,
            cols: 3, itemCount: 100)
        XCTAssertEqual(range, 6...17)
    }

    func testComputeVisibleRange_bottomOfDocument() {
        // scrollY near end: 100 items, 3 cols = 34 rows
        // firstRow = floor((3000-8)/94) = 31, lastRow = min(33, ceil(3492/94)-1) = 33
        // firstVisible = 93, lastVisible = 99
        let range = QuickGridView.computeVisibleRange(
            scrollOriginY: 3000, viewportHeight: 500,
            cellHeight: 90, lineSpacing: 4, topInset: 8,
            cols: 3, itemCount: 100)
        XCTAssertEqual(range, 93...99)
    }

    func testComputeVisibleRange_negativeBounce() {
        // scrollY < 0 (rubber band), firstRow clamped to 0
        // lastRow = ceil((-100+500-8)/94)-1 = 4 → lastVisible = 14
        let range = QuickGridView.computeVisibleRange(
            scrollOriginY: -100, viewportHeight: 500,
            cellHeight: 90, lineSpacing: 4, topInset: 8,
            cols: 3, itemCount: 100)
        XCTAssertEqual(range?.lowerBound, 0)
        XCTAssertEqual(range?.upperBound, 14)
    }

    func testComputeVisibleRange_singleItem() {
        let range = QuickGridView.computeVisibleRange(
            scrollOriginY: 0, viewportHeight: 500,
            cellHeight: 90, lineSpacing: 4, topInset: 8,
            cols: 3, itemCount: 1)
        XCTAssertEqual(range, 0...0)
    }

    func testComputeVisibleRange_emptyItems() {
        let range = QuickGridView.computeVisibleRange(
            scrollOriginY: 0, viewportHeight: 500,
            cellHeight: 90, lineSpacing: 4, topInset: 8,
            cols: 3, itemCount: 0)
        XCTAssertNil(range)
    }

    func testComputeVisibleRange_partialLastRow() {
        // 10 items, 3 cols → 4 rows, last row has 1 item (index 9)
        // scrollY=0, viewportH=500 shows all 4 rows
        // lastRow = 3, lastVisible = min(3*3+2, 9) = 9
        let range = QuickGridView.computeVisibleRange(
            scrollOriginY: 0, viewportHeight: 500,
            cellHeight: 90, lineSpacing: 4, topInset: 8,
            cols: 3, itemCount: 10)
        XCTAssertEqual(range, 0...9)
    }

    // MARK: - prefetchRange (static)

    func testPrefetchRange_down() {
        let visible: Set<Int> = Set(10...15)
        let range = QuickGridView.prefetchRange(
            visibleIndices: visible, direction: .down, itemCount: 100, cols: 3)
        // 2 rows × 3 cols = 6 items ahead: 16...21
        XCTAssertEqual(range, 16...21)
    }

    func testPrefetchRange_up() {
        let visible: Set<Int> = Set(10...15)
        let range = QuickGridView.prefetchRange(
            visibleIndices: visible, direction: .up, itemCount: 100, cols: 3)
        // 2 rows × 3 cols = 6 items behind: 4...9
        XCTAssertEqual(range, 4...9)
    }

    func testPrefetchRange_upClampedToZero() {
        let visible: Set<Int> = Set(0...5)
        let range = QuickGridView.prefetchRange(
            visibleIndices: visible, direction: .up, itemCount: 100, cols: 3)
        // minVis=0, end=-1, start=0 → start > end → nil
        XCTAssertNil(range)
    }

    func testPrefetchRange_downClampedToEnd() {
        let visible: Set<Int> = Set(94...99)
        let range = QuickGridView.prefetchRange(
            visibleIndices: visible, direction: .down, itemCount: 100, cols: 3)
        // maxVis=99, start=100 > min(99, 105)=99 → nil
        XCTAssertNil(range)
    }

    func testPrefetchRange_noneDirection() {
        let visible: Set<Int> = Set(10...15)
        let range = QuickGridView.prefetchRange(
            visibleIndices: visible, direction: .none, itemCount: 100, cols: 3)
        XCTAssertNil(range)
    }

    func testPrefetchRange_noOverlapWithVisible() {
        let visible: Set<Int> = Set(10...15)
        let range = QuickGridView.prefetchRange(
            visibleIndices: visible, direction: .down, itemCount: 100, cols: 3)
        // Prefetch range should NOT overlap with visible indices
        if let range = range {
            let overlap = visible.intersection(range)
            XCTAssertTrue(overlap.isEmpty, "Prefetch range should not overlap visible indices")
        } else {
            XCTFail("Expected non-nil prefetch range")
        }
    }

    // MARK: - prefetchRange min/max overload (Phase 3.4)

    func testPrefetchRange_minMax_down() {
        let range = QuickGridView.prefetchRange(
            minVisible: 10, maxVisible: 15, direction: .down, itemCount: 100, cols: 3)
        XCTAssertEqual(range, 16...21)
    }

    func testPrefetchRange_minMax_up() {
        let range = QuickGridView.prefetchRange(
            minVisible: 10, maxVisible: 15, direction: .up, itemCount: 100, cols: 3)
        XCTAssertEqual(range, 4...9)
    }

    func testPrefetchRange_minMax_none() {
        let range = QuickGridView.prefetchRange(
            minVisible: 10, maxVisible: 15, direction: .none, itemCount: 100, cols: 3)
        XCTAssertNil(range)
    }

    func testPrefetchRange_setDelegation() {
        let visible: Set<Int> = Set(10...15)
        let setRange = QuickGridView.prefetchRange(
            visibleIndices: visible, direction: .down, itemCount: 100, cols: 3)
        let minMaxRange = QuickGridView.prefetchRange(
            minVisible: 10, maxVisible: 15, direction: .down, itemCount: 100, cols: 3)
        XCTAssertEqual(setRange, minMaxRange)
    }

    // MARK: - scrollTargetYForItem (static, keyboard nav scroll)

    func testScrollTargetYForItem_itemBelowViewport_scrollsUp() {
        // visibleRect: y=0, height=300 → shows 0..300. Item at y=400..500 is below.
        // Target: item.maxY - viewportHeight = 500 - 300 = 200
        let itemFrame = CGRect(x: 0, y: 400, width: 100, height: 100)
        let visibleRect = CGRect(x: 0, y: 0, width: 400, height: 300)
        let target = QuickGridView.scrollTargetYForItem(
            itemFrame: itemFrame, visibleRect: visibleRect, documentHeight: 1000)
        XCTAssertEqual(target, 200)
    }

    func testScrollTargetYForItem_itemAboveViewport_scrollsDown() {
        // visibleRect: y=200, height=300 → shows 200..500. Item at y=50..150 is above.
        // Target: item.minY = 50
        let itemFrame = CGRect(x: 0, y: 50, width: 100, height: 100)
        let visibleRect = CGRect(x: 0, y: 200, width: 400, height: 300)
        let target = QuickGridView.scrollTargetYForItem(
            itemFrame: itemFrame, visibleRect: visibleRect, documentHeight: 1000)
        XCTAssertEqual(target, 50)
    }

    func testScrollTargetYForItem_itemAlreadyVisible_returnsNil() {
        let itemFrame = CGRect(x: 0, y: 150, width: 100, height: 100)
        let visibleRect = CGRect(x: 0, y: 100, width: 400, height: 300)
        let target = QuickGridView.scrollTargetYForItem(
            itemFrame: itemFrame, visibleRect: visibleRect, documentHeight: 1000)
        XCTAssertNil(target)
    }

    func testScrollTargetYForItem_clampsToMaxScroll() {
        // Item at y=900..1000, documentHeight=500, viewport=300 → maxScrollY=200
        // Target would be 700 (1000-300) but clamped to 200
        let itemFrame = CGRect(x: 0, y: 900, width: 100, height: 100)
        let visibleRect = CGRect(x: 0, y: 0, width: 400, height: 300)
        let target = QuickGridView.scrollTargetYForItem(
            itemFrame: itemFrame, visibleRect: visibleRect, documentHeight: 500)
        XCTAssertEqual(target, 200)
    }

    func testScrollTargetYForItem_clampsToZero() {
        // Item above viewport: target would be negative, clamp to 0
        let itemFrame = CGRect(x: 0, y: -50, width: 100, height: 100)
        let visibleRect = CGRect(x: 0, y: 0, width: 400, height: 300)
        let target = QuickGridView.scrollTargetYForItem(
            itemFrame: itemFrame, visibleRect: visibleRect, documentHeight: 1000)
        XCTAssertEqual(target, 0)
    }

    func testScrollTargetYForItem_itemPartiallyVisible_below_scrollsToShowBottom() {
        // Item at y=250..350, visible 0..300. Item bottom (350) > visible max (300) → scroll
        let itemFrame = CGRect(x: 0, y: 250, width: 100, height: 100)
        let visibleRect = CGRect(x: 0, y: 0, width: 400, height: 300)
        let target = QuickGridView.scrollTargetYForItem(
            itemFrame: itemFrame, visibleRect: visibleRect, documentHeight: 1000)
        XCTAssertEqual(target, 50)  // 350 - 300
    }

    // MARK: - detectDirection (static)

    func testDetectDirection_sequence() {
        // Going down: current > last + deadZone
        XCTAssertEqual(
            QuickGridView.detectDirection(currentY: 50, lastY: 0),
            .down)
        XCTAssertEqual(
            QuickGridView.detectDirection(currentY: 100, lastY: 50),
            .down)

        // Going up: current < last - deadZone
        XCTAssertEqual(
            QuickGridView.detectDirection(currentY: 95, lastY: 100),
            .up)
        XCTAssertEqual(
            QuickGridView.detectDirection(currentY: 40, lastY: 95),
            .up)

        // Within dead-zone: |current - last| <= 1
        XCTAssertEqual(
            QuickGridView.detectDirection(currentY: 100.5, lastY: 100),
            .none, "Within 1pt dead-zone should return .none")
        XCTAssertEqual(
            QuickGridView.detectDirection(currentY: 99.5, lastY: 100),
            .none, "Within 1pt dead-zone should return .none")
    }

    // MARK: - cancelNonVisibleTasks with keep set (via thin wrapper)

    func testCancelPreservesPrefetchTasks() {
        let grid = QuickGridView()
        // Inject tasks at indices 0..7
        for i in 0..<8 {
            let task = Task<Void, Never> {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            grid._testSetTask(task, forIndex: i)
        }
        XCTAssertEqual(grid.thumbnailTaskCount, 8)

        // keepSet = visible {2,3,4} ∪ prefetch {5,6,7} = {2,3,4,5,6,7}
        // Using cancelNonVisibleTasks as thin wrapper:
        // tasks 0,1 should be cancelled, 2-7 preserved
        grid.cancelNonVisibleTasks(visibleIndices: Set(2...7))

        XCTAssertEqual(grid.thumbnailTaskCount, 6,
                       "Tasks within keep set (visible + prefetch) should survive")
    }
}
