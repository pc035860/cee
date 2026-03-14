import XCTest
@testable import Cee

@MainActor
final class ImageViewControllerTests: XCTestCase {

    func testZoomStatusFormatter_fit() {
        XCTAssertEqual(ZoomStatusFormatter.text(for: .fit), String(localized: "status.fit"))
    }

    func testZoomStatusFormatter_actualWithWindowAuto() {
        XCTAssertEqual(
            ZoomStatusFormatter.text(for: .actual(windowAuto: true)),
            String(localized: "status.actual") + " 100% · " + String(localized: "status.windowAuto")
        )
    }

    func testZoomStatusFormatter_manualWithWindowAuto() {
        XCTAssertEqual(
            ZoomStatusFormatter.text(for: .manual(percent: 125, windowAuto: true)),
            String(localized: "status.manual") + " 125% · " + String(localized: "status.windowAuto")
        )
    }

    func testZoomStatusFormatter_compactPercentOnly_manual() {
        XCTAssertEqual(
            ZoomStatusFormatter.text(for: .manual(percent: 89, windowAuto: true), style: .compactPercentOnly),
            "89%"
        )
    }

    func testZoomStatusFormatter_compactPercentOnly_fit() {
        XCTAssertEqual(
            ZoomStatusFormatter.text(for: .fit, style: .compactPercentOnly),
            String(localized: "status.fit")
        )
    }

    func testZoomStatusFormatter_compactPercentOnly_actual() {
        XCTAssertEqual(
            ZoomStatusFormatter.text(for: .actual(windowAuto: true), style: .compactPercentOnly),
            "100%"
        )
    }

    func testStatusBarFittingWidthStaysCompact() {
        let statusBar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 10, height: Constants.statusBarHeight))

        statusBar.update(
            index: 1,
            total: 999,
            zoomMode: .manual(percent: 100, windowAuto: true),
            imageSize: NSSize(width: 4000, height: 3000)
        )
        statusBar.layoutSubtreeIfNeeded()

        XCTAssertLessThan(statusBar.fittingSize.width, 300)
    }

    func testStatusBarDisplayMode_regularAtWideWidth() {
        let statusBar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 600, height: Constants.statusBarHeight))
        statusBar.update(
            index: 1,
            total: 100,
            zoomMode: .manual(percent: 100, windowAuto: true),
            imageSize: NSSize(width: 800, height: 600)
        )
        statusBar.layoutSubtreeIfNeeded()

        XCTAssertEqual(statusBar.currentDisplayMode, .regular)
    }

    func testStatusBarDisplayMode_minimalAtVeryNarrowWidth() {
        let statusBar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 600, height: Constants.statusBarHeight))
        statusBar.update(
            index: 1,
            total: 100,
            zoomMode: .manual(percent: 100, windowAuto: true),
            imageSize: NSSize(width: 800, height: 600)
        )
        statusBar.layoutSubtreeIfNeeded()

        statusBar.frame.size.width = 120
        statusBar.layoutSubtreeIfNeeded()

        XCTAssertEqual(statusBar.currentDisplayMode, .minimal)
    }

    func testScrollViewEffectiveMinMagnificationUsesDocumentBaseSize() {
        let scrollView = ImageScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 500))

        XCTAssertEqual(scrollView.effectiveMinMagnification(), 0.6, accuracy: 0.001)
    }

    private var controller: ImageViewController!
    private var scrollView: ImageScrollView!
    private var documentView: DualPageContentView!

    private func makeController(
        contentSize: NSSize = NSSize(width: 1000, height: 800),
        imageSize: NSSize = NSSize(width: 800, height: 400)
    ) throws {
        controller = ImageViewController()
        controller.loadViewIfNeeded()
        controller.settings.showStatusBar = false
        controller.settings.alwaysFitOnOpen = true
        controller.settings.isManualZoom = false
        controller.settings.fittingOptions = FittingOptions(
            shrinkHorizontally: false,
            shrinkVertically: false,
            stretchHorizontally: true,
            stretchVertically: false
        )

        controller.view.frame = NSRect(origin: .zero, size: contentSize)
        controller.view.layoutSubtreeIfNeeded()

        scrollView = try XCTUnwrap(
            controller.view.subviews.first(where: { $0 is ImageScrollView }) as? ImageScrollView
        )
        documentView = try XCTUnwrap(scrollView.documentView as? DualPageContentView)
        documentView.configureSingle(imageSize: imageSize)
        controller.view.layoutSubtreeIfNeeded()
    }

    func testHandleWindowDidResize_reappliesAutoFitMagnification() throws {
        try makeController()

        controller.handleWindowDidResize()
        XCTAssertEqual(scrollView.magnification, 1.25, accuracy: 0.001)

        controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        controller.view.layoutSubtreeIfNeeded()

        controller.handleWindowDidResize()
        XCTAssertEqual(scrollView.magnification, 1.5, accuracy: 0.001)
    }

    func testHandleWindowDidResize_preservesManualZoom() throws {
        try makeController()

        controller.handleWindowDidResize()
        let initialMagnification = scrollView.magnification
        controller.settings.isManualZoom = true

        controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        controller.view.layoutSubtreeIfNeeded()

        controller.handleWindowDidResize()
        XCTAssertEqual(scrollView.magnification, initialMagnification, accuracy: 0.001)
    }
}
