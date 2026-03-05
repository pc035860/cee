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
