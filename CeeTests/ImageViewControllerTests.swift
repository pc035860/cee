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
