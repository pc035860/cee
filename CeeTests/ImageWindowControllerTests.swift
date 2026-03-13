import XCTest
@testable import Cee

final class ImageWindowControllerTests: XCTestCase {

    func testExpandedHeightFrame_alignsToVisibleFrameAndPreservesWidth() {
        let frame = NSRect(x: 340, y: 180, width: 720, height: 480)
        let visibleFrame = NSRect(x: 80, y: 40, width: 1440, height: 900)

        let expanded = ImageWindowController.expandedHeightFrame(from: frame, within: visibleFrame)

        XCTAssertEqual(expanded.width, frame.width)
        XCTAssertEqual(expanded.height, visibleFrame.height)
        XCTAssertEqual(expanded.minY, visibleFrame.minY)
        XCTAssertEqual(expanded.maxY, visibleFrame.maxY)
        XCTAssertEqual(expanded.midX, frame.midX, accuracy: 0.001)
    }
}
