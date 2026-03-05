@testable import Cee
import XCTest

// MARK: - MemoryPressureMonitor Tests

@MainActor
final class MemoryPressureMonitorTests: XCTestCase {

    func testSimulatePressure_warning() {
        let monitor = MemoryPressureMonitor()
        var receivedLevel: MemoryPressureMonitor.PressureLevel?
        monitor.onPressure = { level in receivedLevel = level }

        monitor._testSimulatePressure(.warning)

        XCTAssertEqual(receivedLevel, .warning)
    }

    func testSimulatePressure_critical() {
        let monitor = MemoryPressureMonitor()
        var receivedLevel: MemoryPressureMonitor.PressureLevel?
        monitor.onPressure = { level in receivedLevel = level }

        monitor._testSimulatePressure(.critical)

        XCTAssertEqual(receivedLevel, .critical)
    }
}

// MARK: - QuickGridView Memory Pressure Integration

@MainActor
final class QuickGridMemoryPressureTests: XCTestCase {

    /// Helper: inject mock thumbnails at given indices.
    private func injectMockThumbnails(into grid: QuickGridView, indices: [Int]) {
        let image = NSImage(size: NSSize(width: 10, height: 10))
        for index in indices {
            grid._testSetThumbnail(image, forIndex: index)
        }
    }

    /// Helper: inject mock tasks at given indices.
    private func injectMockTasks(into grid: QuickGridView, indices: [Int]) {
        for index in indices {
            let task = Task<Void, Never> {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            grid._testSetTask(task, forIndex: index)
        }
    }

    func testHandleMemoryPressure_warning_cancelsTasks() {
        let grid = QuickGridView()
        injectMockThumbnails(into: grid, indices: Array(0..<20))
        injectMockTasks(into: grid, indices: Array(0..<10))

        XCTAssertEqual(grid.thumbnailTaskCount, 10)

        // Warning: should cancel pending tasks
        grid._testHandleMemoryPressure(.warning)

        XCTAssertEqual(grid.thumbnailTaskCount, 0,
                       "Warning should cancel all pending thumbnail tasks")
    }

    func testHandleMemoryPressure_critical_clearsAllCache() {
        let grid = QuickGridView()
        injectMockThumbnails(into: grid, indices: Array(0..<50))
        injectMockTasks(into: grid, indices: Array(0..<10))

        XCTAssertEqual(grid.gridThumbnailCount, 50)
        XCTAssertEqual(grid.thumbnailTaskCount, 10)

        // Critical: should clear ALL thumbnails and tasks
        grid._testHandleMemoryPressure(.critical)

        XCTAssertEqual(grid.gridThumbnailCount, 0,
                       "Critical should clear all grid thumbnails")
        XCTAssertEqual(grid.thumbnailTaskCount, 0,
                       "Critical should cancel all pending tasks")
    }
}
