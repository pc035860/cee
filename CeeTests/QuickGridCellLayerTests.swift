@testable import Cee
import XCTest

@MainActor
final class QuickGridCellLayerTests: XCTestCase {

    func testCell_canDrawSubviewsIntoLayer() {
        let cell = QuickGridCell()
        _ = cell.view  // Trigger loadView
        XCTAssertTrue(cell.view.canDrawSubviewsIntoLayer,
                      "canDrawSubviewsIntoLayer should be enabled for compositing optimization")
    }

    func testCell_layerContentsRedrawPolicy() {
        let cell = QuickGridCell()
        _ = cell.view  // Trigger loadView
        XCTAssertEqual(cell.view.layerContentsRedrawPolicy, .onSetNeedsDisplay,
                       "layerContentsRedrawPolicy should be .onSetNeedsDisplay")
    }
}
