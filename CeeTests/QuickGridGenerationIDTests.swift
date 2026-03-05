@testable import Cee
import XCTest

@MainActor
final class QuickGridGenerationIDTests: XCTestCase {

    func testGenerationID_incrementsOnClearCache() {
        let grid = QuickGridView()
        let gen0 = grid._testGenerationID

        grid.clearCache()
        let gen1 = grid._testGenerationID

        XCTAssertEqual(gen1, gen0 + 1, "clearCache should increment generationID")
    }

    func testGenerationID_preventsStaleWrite() {
        let grid = QuickGridView()
        let staleGen = grid._testGenerationID

        // Simulate folder change
        grid.clearCache()

        // Try to write with stale generation
        let image = NSImage(size: NSSize(width: 10, height: 10))
        grid._testWriteThumbnailIfCurrentGeneration(image, forIndex: 5, generation: staleGen)

        XCTAssertEqual(grid.gridThumbnailCount, 0,
                       "Stale generation write should be rejected")
    }

    func testGenerationID_allowsCurrentWrite() {
        let grid = QuickGridView()
        let currentGen = grid._testGenerationID

        let image = NSImage(size: NSSize(width: 10, height: 10))
        grid._testWriteThumbnailIfCurrentGeneration(image, forIndex: 5, generation: currentGen)

        XCTAssertEqual(grid.gridThumbnailCount, 1,
                       "Current generation write should succeed")
    }
}
