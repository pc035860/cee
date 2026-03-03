import XCTest
@testable import Cee

final class FittingCalculatorTests: XCTestCase {

    // MARK: - Helpers

    private func assertSizeEqual(
        _ a: NSSize, _ b: NSSize,
        accuracy: CGFloat = 0.5,
        file: StaticString = #file, line: UInt = #line
    ) {
        XCTAssertEqual(a.width, b.width, accuracy: accuracy, "width mismatch", file: file, line: line)
        XCTAssertEqual(a.height, b.height, accuracy: accuracy, "height mismatch", file: file, line: line)
    }

    private func opts(
        shrinkH: Bool = false,
        shrinkV: Bool = false,
        stretchH: Bool = false,
        stretchV: Bool = false
    ) -> FittingOptions {
        FittingOptions(
            shrinkHorizontally: shrinkH,
            shrinkVertically: shrinkV,
            stretchHorizontally: stretchH,
            stretchVertically: stretchV
        )
    }

    private let viewport = NSSize(width: 800, height: 600)

    // MARK: - A. No-op (image fits, no stretch)

    func testNoOp_imageSmallerThanViewport_returnsOriginal() {
        let image = NSSize(width: 400, height: 300)
        let result = FittingCalculator.calculate(imageSize: image, viewportSize: viewport, options: opts())
        assertSizeEqual(result, image)
    }

    func testNoOp_imageExactlyViewportSize_returnsOriginal() {
        let result = FittingCalculator.calculate(imageSize: viewport, viewportSize: viewport, options: opts())
        assertSizeEqual(result, viewport)
    }

    // MARK: - B. Shrink H only (width exceeds, height fits)

    func testShrinkH_only_scalesProportionally() {
        let image = NSSize(width: 1600, height: 400)
        let result = FittingCalculator.calculate(
            imageSize: image, viewportSize: viewport, options: opts(shrinkH: true)
        )
        // scaleX = 800/1600 = 0.5 → width=800, height=400*0.5=200
        assertSizeEqual(result, NSSize(width: 800, height: 200))
    }

    // MARK: - C. Shrink V only (height exceeds, width fits)

    func testShrinkV_only_scalesProportionally() {
        let image = NSSize(width: 400, height: 1200)
        let result = FittingCalculator.calculate(
            imageSize: image, viewportSize: viewport, options: opts(shrinkV: true)
        )
        // scaleY = 600/1200 = 0.5 → height=600, width=400*0.5=200
        assertSizeEqual(result, NSSize(width: 200, height: 600))
    }

    // MARK: - D. Dual-axis shrink (both exceed → min scale)

    func testShrinkBoth_widthLimited() {
        // Wide image: scaleX < scaleY → width is the constraint
        let image = NSSize(width: 1600, height: 800)
        let result = FittingCalculator.calculate(
            imageSize: image, viewportSize: viewport, options: opts(shrinkH: true, shrinkV: true)
        )
        // scaleX=0.5, scaleY=0.75, min=0.5 → 800×400
        assertSizeEqual(result, NSSize(width: 800, height: 400))
    }

    func testShrinkBoth_heightLimited() {
        // Tall image: scaleY < scaleX → height is the constraint
        let image = NSSize(width: 1000, height: 1200)
        let result = FittingCalculator.calculate(
            imageSize: image, viewportSize: viewport, options: opts(shrinkH: true, shrinkV: true)
        )
        // scaleX=0.8, scaleY=0.5, min=0.5 → 500×600
        assertSizeEqual(result, NSSize(width: 500, height: 600))
    }

    func testShrinkBoth_equalScales() {
        // Image is exactly 2x viewport in both dimensions
        let image = NSSize(width: 1600, height: 1200)
        let result = FittingCalculator.calculate(
            imageSize: image, viewportSize: viewport, options: opts(shrinkH: true, shrinkV: true)
        )
        // scaleX=0.5, scaleY=0.5, min=0.5 → 800×600
        assertSizeEqual(result, viewport)
    }

    // MARK: - E. Stretch H only (image narrow)

    func testStretchH_only_scalesProportionally() {
        let image = NSSize(width: 400, height: 800)
        let result = FittingCalculator.calculate(
            imageSize: image, viewportSize: viewport, options: opts(stretchH: true)
        )
        // scaleX = 800/400 = 2 → width=800, height=800*2=1600
        assertSizeEqual(result, NSSize(width: 800, height: 1600))
    }

    // MARK: - F. Stretch V only (image short)

    func testStretchV_only_scalesProportionally() {
        let image = NSSize(width: 900, height: 300)
        let result = FittingCalculator.calculate(
            imageSize: image, viewportSize: viewport, options: opts(stretchV: true)
        )
        // scaleY = 600/300 = 2 → height=600, width=900*2=1800
        assertSizeEqual(result, NSSize(width: 1800, height: 600))
    }

    // MARK: - G. Dual-axis stretch (both small → min scale)

    func testStretchBoth_widthLimited() {
        // Wide-ish small image: scaleX < scaleY
        let image = NSSize(width: 400, height: 200)
        let result = FittingCalculator.calculate(
            imageSize: image, viewportSize: viewport, options: opts(stretchH: true, stretchV: true)
        )
        // scaleX=2, scaleY=3, min=2 → 800×400
        assertSizeEqual(result, NSSize(width: 800, height: 400))
    }

    func testStretchBoth_heightLimited() {
        // Tall-ish small image: scaleY < scaleX
        let image = NSSize(width: 200, height: 400)
        let result = FittingCalculator.calculate(
            imageSize: image, viewportSize: viewport, options: opts(stretchH: true, stretchV: true)
        )
        // scaleX=4, scaleY=1.5, min=1.5 → 300×600
        assertSizeEqual(result, NSSize(width: 300, height: 600))
    }

    // MARK: - H. Mixed: shrinkH + stretchV

    func testMixed_shrinkH_stretchV() {
        // Wide but short: width exceeds, height is small
        let image = NSSize(width: 1600, height: 300)
        let result = FittingCalculator.calculate(
            imageSize: image, viewportSize: viewport, options: opts(shrinkH: true, stretchV: true)
        )
        // shrinkH: width=800; stretchV: height=600 (independent axes, no dual-axis branch)
        assertSizeEqual(result, NSSize(width: 800, height: 600))
    }

    // MARK: - I. All disabled

    func testAllDisabled_returnsOriginal() {
        let image = NSSize(width: 2000, height: 2000)
        let result = FittingCalculator.calculate(imageSize: image, viewportSize: viewport, options: opts())
        assertSizeEqual(result, image)
    }

    // MARK: - J. Edge cases

    func testZeroSizeImage_returnsZero() {
        let image = NSSize(width: 0, height: 0)
        let result = FittingCalculator.calculate(
            imageSize: image, viewportSize: viewport, options: opts(shrinkH: true, shrinkV: true)
        )
        // Zero image is smaller than viewport, no shrink needed
        assertSizeEqual(result, image)
    }

    func testTinyViewport_shrinksCorrectly() {
        let image = NSSize(width: 100, height: 100)
        let tiny = NSSize(width: 1, height: 1)
        let result = FittingCalculator.calculate(
            imageSize: image, viewportSize: tiny, options: opts(shrinkH: true, shrinkV: true)
        )
        // scaleX=0.01, scaleY=0.01, min=0.01 → 1×1
        assertSizeEqual(result, NSSize(width: 1, height: 1))
    }

    // MARK: - Default options (shrinkH + shrinkV = true)

    func testDefaultOptions_fitOnScreen() {
        let image = NSSize(width: 1600, height: 1200)
        let defaultOpts = FittingOptions()  // shrinkH=true, shrinkV=true
        let result = FittingCalculator.calculate(imageSize: image, viewportSize: viewport, options: defaultOpts)
        // scaleX=0.5, scaleY=0.5 → 800×600
        assertSizeEqual(result, viewport)
    }
}
