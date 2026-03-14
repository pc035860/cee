import XCTest
@testable import Cee

final class ImageWindowControllerTests: XCTestCase {

    func testEffectiveMinimumContentSize_prefersLayoutFittingWidthWhenLarger() {
        let effective = ImageWindowController.effectiveMinimumContentSize(
            configuredMinContentSize: NSSize(width: 300, height: 300),
            layoutMinContentSize: NSSize(width: 568, height: 22)
        )

        XCTAssertEqual(effective.width, 568)
        XCTAssertEqual(effective.height, 300)
    }

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

    func testExpandedHeightFrame_clampsLeftEdgeIntoVisibleFrame() {
        let frame = NSRect(x: 20, y: 200, width: 720, height: 500)
        let visibleFrame = NSRect(x: 80, y: 40, width: 1440, height: 900)

        let expanded = ImageWindowController.expandedHeightFrame(from: frame, within: visibleFrame)

        XCTAssertEqual(expanded.minX, visibleFrame.minX)
        XCTAssertEqual(expanded.width, frame.width)
        XCTAssertEqual(expanded.maxY, visibleFrame.maxY)
    }

    func testExpandedHeightFrame_clampsRightEdgeIntoVisibleFrame() {
        let frame = NSRect(x: 980, y: 200, width: 720, height: 500)
        let visibleFrame = NSRect(x: 80, y: 40, width: 1440, height: 900)

        let expanded = ImageWindowController.expandedHeightFrame(from: frame, within: visibleFrame)

        XCTAssertEqual(expanded.maxX, visibleFrame.maxX)
        XCTAssertEqual(expanded.width, frame.width)
        XCTAssertEqual(expanded.minY, visibleFrame.minY)
    }

    func testEffectiveMinimumContentSize_usesConfiguredMinWhenLayoutFittingIsSmaller() {
        let effective = ImageWindowController.effectiveMinimumContentSize(
            configuredMinContentSize: NSSize(width: 300, height: 300),
            layoutMinContentSize: NSSize(width: 200, height: 22)
        )

        XCTAssertEqual(effective.width, 300)
        XCTAssertEqual(effective.height, 300)
    }

    func testExpandedHeightFrame_clampsWidthToVisibleFrameWhenWindowIsTooWide() {
        let frame = NSRect(x: 20, y: 200, width: 1800, height: 500)
        let visibleFrame = NSRect(x: 80, y: 40, width: 1440, height: 900)

        let expanded = ImageWindowController.expandedHeightFrame(from: frame, within: visibleFrame)

        XCTAssertEqual(expanded.minX, visibleFrame.minX)
        XCTAssertEqual(expanded.maxX, visibleFrame.maxX)
        XCTAssertEqual(expanded.width, visibleFrame.width)
        XCTAssertEqual(expanded.height, visibleFrame.height)
    }
}
