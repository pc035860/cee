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

    func testContinuousScrollContentHeightForLaunch_matchesVisibleFrameMinusChrome() {
        let visibleFrameHeight: CGFloat = 900
        let verticalChrome: CGFloat = 28

        let contentH = ImageWindowController.continuousScrollContentHeightForLaunch(
            visibleFrameHeight: visibleFrameHeight,
            verticalChrome: verticalChrome
        )

        XCTAssertEqual(contentH, visibleFrameHeight - verticalChrome)
    }

    func testContinuousScrollContentHeightForLaunch_clampsToMinimumWhenVisibleAreaTooShort() {
        let visibleFrameHeight: CGFloat = 320
        let verticalChrome: CGFloat = 28

        let contentH = ImageWindowController.continuousScrollContentHeightForLaunch(
            visibleFrameHeight: visibleFrameHeight,
            verticalChrome: verticalChrome
        )

        XCTAssertEqual(contentH, Constants.minWindowContentHeight)
    }

    func testPresizedContentSize_smallImage_returnsImageSizePlusStatusBar() {
        let result = ImageWindowController.presizedContentSize(
            imageSize: NSSize(width: 500, height: 400),
            maxContent: NSSize(width: 1600, height: 1000),
            statusBarHeight: 24,
            minContent: NSSize(width: 300, height: 300),
            options: FittingOptions()
        )

        XCTAssertEqual(result.width, 500, accuracy: 0.5)
        XCTAssertEqual(result.height, 424, accuracy: 0.5)
    }

    func testPresizedContentSize_largeImage_fitsInViewportWithStatusBar() {
        let result = ImageWindowController.presizedContentSize(
            imageSize: NSSize(width: 3000, height: 2000),
            maxContent: NSSize(width: 1600, height: 1000),
            statusBarHeight: 24,
            minContent: NSSize(width: 300, height: 300),
            options: FittingOptions()
        )

        XCTAssertEqual(result.width, 1464, accuracy: 0.5)
        XCTAssertEqual(result.height, 1000, accuracy: 0.5)
    }

    func testPresizedContentSize_tinyImage_clampsToMinContent() {
        let result = ImageWindowController.presizedContentSize(
            imageSize: NSSize(width: 100, height: 80),
            maxContent: NSSize(width: 1600, height: 1000),
            statusBarHeight: 24,
            minContent: NSSize(width: 300, height: 300),
            options: FittingOptions()
        )

        XCTAssertGreaterThanOrEqual(result.width, 300)
        XCTAssertGreaterThanOrEqual(result.height, 300)
    }
}
