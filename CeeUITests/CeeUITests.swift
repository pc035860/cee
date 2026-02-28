import XCTest

@MainActor
final class CeeUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()

        let testBundle = Bundle(for: type(of: self))
        // Resources are copied flat into bundle root (XcodeGen flattens the Fixtures dir)
        guard let resourceURL = testBundle.resourceURL else {
            XCTFail("Cannot find test bundle resourceURL")
            return
        }
        let firstImage = resourceURL.appendingPathComponent("001-landscape.jpg")
        guard FileManager.default.fileExists(atPath: firstImage.path) else {
            XCTFail("Fixture 001-landscape.jpg not found in test bundle at \(firstImage.path)")
            return
        }

        app.launchArguments = [
            "--ui-testing",
            "--reset-state",
            "--disable-animations"
        ]
        app.launchEnvironment = [
            "UITEST_FIXTURE_PATH": firstImage.path
        ]

        app.launch()
    }

    override func tearDown() async throws {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .deleteOnSuccess
        add(attachment)

        app.terminate()
        try await super.tearDown()
    }

    // MARK: - Helper

    /// 等待帶有特定 identifier 的元素出現（搜尋整個 hierarchy）
    private func waitForImageState(_ identifier: String, timeout: TimeInterval = 15) -> XCUIElement {
        // 嘗試多種元素類型，因為自訂 NSView 可能在不同類型下
        let predicate = NSPredicate(format: "identifier == %@", identifier)
        let element = app.descendants(matching: .any).matching(predicate).firstMatch
        _ = element.waitForExistence(timeout: timeout)
        return element
    }

    private func waitForStableLayout(_ seconds: TimeInterval = 0.35) {
        usleep(useconds_t(seconds * 1_000_000))
    }

    private func assertImageOverlapsViewport(
        in window: XCUIElement,
        minimumVisibleOverlap: CGFloat = 24,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let image = waitForImageState("imageContent-loaded")
        XCTAssertTrue(image.exists, "imageContent-loaded should exist", file: file, line: line)

        let imageFrame = image.frame
        let windowFrame = window.frame
        XCTAssertGreaterThan(imageFrame.width, 10, "Image width should be visible", file: file, line: line)
        XCTAssertGreaterThan(imageFrame.height, 10, "Image height should be visible", file: file, line: line)
        let overlap = imageFrame.intersection(windowFrame)
        XCTAssertGreaterThan(overlap.width, minimumVisibleOverlap,
                             "Image should remain visible horizontally after zoom/fullscreen operations",
                             file: file, line: line)
        XCTAssertGreaterThan(overlap.height, minimumVisibleOverlap,
                             "Image should remain visible vertically after zoom/fullscreen operations",
                             file: file, line: line)
    }

    private func assertWindowCenterStable(
        from before: CGRect,
        to after: CGRect,
        tolerance: CGFloat = 3.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertLessThanOrEqual(
            abs(after.midX - before.midX),
            tolerance,
            "Window midX should stay stable during zoom resize",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            abs(after.midY - before.midY),
            tolerance,
            "Window midY should stay stable during zoom resize",
            file: file,
            line: line
        )
    }

    // MARK: - Smoke Tests

    func testSmoke_AppLaunchesAndDisplaysImage() throws {
        let window = app.windows["imageWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 10),
            "Main window should appear after launch")

        let loadedImage = waitForImageState("imageContent-loaded")
        XCTAssertTrue(loadedImage.exists,
            "Image should finish loading (imageContent-loaded not found)")

        let windowTitle = window.title
        XCTAssertTrue(windowTitle.contains("001-landscape.jpg"),
            "Window title should contain filename, got: \(windowTitle)")
        XCTAssertTrue(windowTitle.contains("/3"),
            "Window title should show total count of 3, got: \(windowTitle)")
    }

    func testWindowHasUsableSizeAfterLaunch() throws {
        let window = app.windows["imageWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 10),
            "Main window should appear after launch")

        XCTAssertTrue(waitForImageState("imageContent-loaded").exists,
            "Image should finish loading before window size assertion")

        let size = window.frame.size
        XCTAssertGreaterThan(size.width, 300,
            "Window width should be > 300pt to avoid unusable 1pt state, got: \(size.width)")
        XCTAssertGreaterThan(size.height, 200,
            "Window height should be > 200pt to avoid titlebar-only state, got: \(size.height)")
    }

    func testSmoke_NavigateToNextImage() throws {
        XCTAssertTrue(waitForImageState("imageContent-loaded").exists)

        // Cmd+] → 下一張（Go 選單快捷鍵，比 bare key 路由更可靠）
        app.typeKey("]", modifierFlags: .command)

        let pred = NSPredicate { _, _ in
            self.waitForImageState("imageContent-loaded", timeout: 2).label.contains("002")
        }
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: pred, object: nil)], timeout: 15)
        XCTAssertEqual(result, .completed, "Navigation to next image timed out")

        let window = app.windows["imageWindow"]
        let title = window.title
        XCTAssertTrue(title.contains("002-portrait.png"),
            "Title should show second image, got: \(title)")
        XCTAssertTrue(title.contains("2/3"),
            "Title should show position 2/3, got: \(title)")
    }

    func testSmoke_NavigateToPreviousImage() throws {
        XCTAssertTrue(waitForImageState("imageContent-loaded").exists)

        // Cmd+] → 前往 002；Cmd+[ → 返回 001
        app.typeKey("]", modifierFlags: .command)
        let pred1 = NSPredicate { _, _ in
            self.waitForImageState("imageContent-loaded", timeout: 2).label.contains("002")
        }
        let result1 = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: pred1, object: nil)], timeout: 15)
        XCTAssertEqual(result1, .completed, "Navigation to image 002 timed out")

        // 驗證已到達 002（若沒有，下面的 pred2 會等待 "001" 但 assertion 會 fail）
        app.typeKey("[", modifierFlags: .command)
        let pred2 = NSPredicate { _, _ in
            self.waitForImageState("imageContent-loaded", timeout: 2).label.contains("001")
        }
        let result2 = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: pred2, object: nil)], timeout: 15)
        XCTAssertEqual(result2, .completed, "Navigation back to image 001 timed out")

        let window = app.windows["imageWindow"]
        XCTAssertTrue(window.title.contains("001-landscape.jpg"),
            "Should be back at first image, got: \(window.title)")
        XCTAssertTrue(window.title.contains("1/3"),
            "Should show position 1/3, got: \(window.title)")
    }

    func testSmoke_KeyboardZoom() throws {
        XCTAssertTrue(waitForImageState("imageContent-loaded").exists)

        app.typeKey("1", modifierFlags: .command)   // Actual Size
        app.typeKey("=", modifierFlags: .command)   // Zoom In
        app.typeKey("0", modifierFlags: .command)   // Fit on Screen

        XCTAssertTrue(waitForImageState("imageContent-loaded").exists,
            "Image should still be visible after zoom operations")
    }

    func testSmoke_FullscreenToggle() throws {
        XCTAssertTrue(waitForImageState("imageContent-loaded").exists)

        app.typeKey("f", modifierFlags: .command)   // Enter fullscreen
        sleep(2)

        XCTAssertTrue(waitForImageState("imageContent-loaded").exists,
            "Image should be visible in fullscreen")

        app.typeKey(.escape, modifierFlags: [])     // Exit fullscreen
        sleep(2)

        let window = app.windows["imageWindow"]
        XCTAssertTrue(window.exists, "Window should exist after exiting fullscreen")
    }

    func testZoomShortcuts_KeepImageVisible() throws {
        let window = app.windows["imageWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 10),
                      "Main window should appear after launch")
        XCTAssertTrue(waitForImageState("imageContent-loaded").exists)
        assertImageOverlapsViewport(in: window)

        app.typeKey("1", modifierFlags: .command)   // Actual Size
        waitForStableLayout()
        assertImageOverlapsViewport(in: window)

        app.typeKey("=", modifierFlags: .command)   // Zoom In
        waitForStableLayout()
        assertImageOverlapsViewport(in: window)

        app.typeKey("-", modifierFlags: .command)   // Zoom Out
        waitForStableLayout()
        assertImageOverlapsViewport(in: window)

        app.typeKey("0", modifierFlags: .command)   // Fit on Screen
        waitForStableLayout()
        assertImageOverlapsViewport(in: window)
    }

    func testFullscreenZoom_StaysVisibleBeforeAndAfterExit() throws {
        let window = app.windows["imageWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 10),
                      "Main window should appear after launch")
        XCTAssertTrue(waitForImageState("imageContent-loaded").exists)

        app.typeKey("f", modifierFlags: .command)   // Enter fullscreen
        sleep(2)
        XCTAssertTrue(waitForImageState("imageContent-loaded").exists)
        assertImageOverlapsViewport(in: window)

        app.typeKey("=", modifierFlags: .command)   // Zoom In
        waitForStableLayout()
        assertImageOverlapsViewport(in: window)

        app.typeKey("-", modifierFlags: .command)   // Zoom Out
        waitForStableLayout()
        assertImageOverlapsViewport(in: window)

        app.typeKey(.escape, modifierFlags: [])     // Exit fullscreen
        sleep(2)
        XCTAssertTrue(waitForImageState("imageContent-loaded").exists)
        assertImageOverlapsViewport(in: window)
    }

    func testZoomShortcuts_WindowCenterStaysStable() throws {
        let window = app.windows["imageWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 10),
                      "Main window should appear after launch")
        XCTAssertTrue(waitForImageState("imageContent-loaded").exists)
        waitForStableLayout()

        app.typeKey("0", modifierFlags: .command)   // Fit on Screen
        waitForStableLayout()
        let before = window.frame

        app.typeKey("=", modifierFlags: .command)   // Zoom In
        waitForStableLayout()
        let afterZoomIn = window.frame
        XCTAssertGreaterThan(afterZoomIn.width, before.width,
                             "Zoom In should increase window width in fit mode")
        assertWindowCenterStable(from: before, to: afterZoomIn)

        app.typeKey("-", modifierFlags: .command)   // Zoom Out
        waitForStableLayout()
        let afterZoomOut = window.frame
        XCTAssertLessThan(afterZoomOut.width, afterZoomIn.width,
                          "Zoom Out should decrease window width after zoom in")
        assertWindowCenterStable(from: afterZoomIn, to: afterZoomOut)
    }

    // Note: scroll-wheel-triggered page turn cannot be reliably tested via XCUITest on macOS
    // because NSScrollView accessibility frame is {1,0} (hit point error). This test verifies
    // the page-turn outcome using the equivalent keyboard shortcut (Cmd+]).
    func testSmoke_PageTurnViaKeyboard() throws {
        XCTAssertTrue(waitForImageState("imageContent-loaded").exists)

        // Cmd+] 換頁到下一張（等同於捲動到底後觸發的換頁行為）
        app.typeKey("]", modifierFlags: .command)

        let pred = NSPredicate { _, _ in
            self.waitForImageState("imageContent-loaded", timeout: 2).label.contains("002")
        }
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: pred, object: nil)], timeout: 15)
        XCTAssertEqual(result, .completed, "Page turn to next image timed out")

        let newTitle = app.windows["imageWindow"].title
        XCTAssertTrue(newTitle.contains("002"),
            "Should have paged to next image, got: \(newTitle)")
    }

    func testImageRendersWithNonZeroSize() throws {
        // 等待圖片載入完成
        let imageEl = waitForImageState("imageContent-loaded")
        let result = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "identifier == %@", "imageContent-loaded"),
                object: imageEl
            )],
            timeout: 15
        )
        XCTAssertEqual(result, .completed, "Image did not reach loaded state in time")

        // 核心驗證：frame 必須有實際尺寸
        // frame.size == .zero 代表 contentView.frame 未被設定（bug 存在）
        let size = imageEl.frame.size
        XCTAssertGreaterThan(size.width,  10,
            "Image rendered width should be > 10pt (got \(size.width)); contentView.frame may be .zero")
        XCTAssertGreaterThan(size.height, 10,
            "Image rendered height should be > 10pt (got \(size.height)); contentView.frame may be .zero")

        // 長寬比語意驗證：fixture 001-landscape.jpg 是 800×600（橫向），fit 後寬應大於高
        XCTAssertGreaterThan(size.width, size.height,
            "Landscape fixture (800×600) should render wider than tall, got \(size)")
    }

    // MARK: - Zoom + Navigation Integration Tests
    // These tests exercise keyboard zoom (Cmd+=/-/0/1) combined with menu navigation (Cmd+]/[).
    // Keyboard zoom goes through ImageViewController.zoomIn/zoomOut/actualSize/fitOnScreen,
    // which call scrollView.setMagnification + resizeWindowToFitZoomedImage.
    // Note: Cmd+scroll zoom and mouse drag pan use different code paths (handleCmdScrollZoom,
    // mouseDragged→performPan) that cannot be tested via XCUITest — see test doc comments.

    /// Validates: Zoomed-in state does not block menu-based navigation (Cmd+]/[).
    /// Exercises: ImageViewController.zoomIn → setMagnification → resizeWindowToFitZoomedImage,
    /// then goToNextImage/goToPreviousImage while magnification > 1.
    /// Does NOT cover: viewportOverflow (keyDown path), performPan, handleCmdScrollZoom.
    func testZoomIn_NavigationStillWorks() throws {
        let window = app.windows["imageWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 10),
                      "Main window should appear after launch")
        XCTAssertTrue(waitForImageState("imageContent-loaded").exists)

        // Record baseline window size
        app.typeKey("0", modifierFlags: .command)   // Fit on Screen (baseline)
        waitForStableLayout()
        let baselineFrame = window.frame

        // Zoom in to create magnification > 1
        app.typeKey("1", modifierFlags: .command)   // Actual Size
        waitForStableLayout()
        app.typeKey("=", modifierFlags: .command)   // Zoom In beyond actual size
        waitForStableLayout()
        app.typeKey("=", modifierFlags: .command)   // Zoom In more
        waitForStableLayout()

        // Verify zoom actually took effect — window should be larger than fit baseline
        let zoomedFrame = window.frame
        XCTAssertGreaterThan(zoomedFrame.width, baselineFrame.width,
                             "Window should be wider after zoom in (zoomed: \(zoomedFrame.width), baseline: \(baselineFrame.width))")

        // Image should still be visible after zoom
        assertImageOverlapsViewport(in: window)

        // Navigate to next image while zoomed — zoom state must not block navigation
        app.typeKey("]", modifierFlags: .command)
        let predNext = NSPredicate { _, _ in
            self.waitForImageState("imageContent-loaded", timeout: 2).label.contains("002")
        }
        let resultNext = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: predNext, object: nil)],
            timeout: 15
        )
        XCTAssertEqual(resultNext, .completed, "Navigation to next image should work while zoomed")

        // Navigate back
        app.typeKey("[", modifierFlags: .command)
        let predPrev = NSPredicate { _, _ in
            self.waitForImageState("imageContent-loaded", timeout: 2).label.contains("001")
        }
        let resultPrev = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: predPrev, object: nil)],
            timeout: 15
        )
        XCTAssertEqual(resultPrev, .completed, "Navigation back should work while zoomed")

        // Fit to restore normal state
        app.typeKey("0", modifierFlags: .command)
        waitForStableLayout()
        assertImageOverlapsViewport(in: window)
    }

    /// Validates: Repeated zoom→navigate cycles don't corrupt state (zoom level, image index, title).
    /// Exercises: zoomIn + goToNextImage + zoomOut + goToPreviousImage as a round-trip.
    /// Does NOT cover: scrollViewMagnificationDidChange (only triggered by scroll view events,
    /// not by menu-driven zoomIn/zoomOut).
    func testMultipleZoomCycles_NavigationStable() throws {
        let window = app.windows["imageWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 10),
                      "Main window should appear after launch")
        XCTAssertTrue(waitForImageState("imageContent-loaded").exists)
        waitForStableLayout()
        let initialFrame = window.frame

        // Cycle 1: Zoom in → verify zoom → navigate next
        app.typeKey("=", modifierFlags: .command)   // Zoom In
        waitForStableLayout()
        let afterZoomIn = window.frame
        XCTAssertGreaterThan(afterZoomIn.width, initialFrame.width,
                             "Zoom In should increase window width")

        app.typeKey("]", modifierFlags: .command)   // Next image
        let pred1 = NSPredicate { _, _ in
            self.waitForImageState("imageContent-loaded", timeout: 2).label.contains("002")
        }
        let result1 = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: pred1, object: nil)],
            timeout: 15
        )
        XCTAssertEqual(result1, .completed, "Cycle 1: navigate to 002 after zoom in")

        // Cycle 2: Zoom out → navigate prev
        app.typeKey("-", modifierFlags: .command)   // Zoom Out
        waitForStableLayout()
        app.typeKey("[", modifierFlags: .command)   // Previous image
        let pred2 = NSPredicate { _, _ in
            self.waitForImageState("imageContent-loaded", timeout: 2).label.contains("001")
        }
        let result2 = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: pred2, object: nil)],
            timeout: 15
        )
        XCTAssertEqual(result2, .completed, "Cycle 2: navigate back to 001 after zoom out")

        // Verify we're back at the original image with stable state
        let title = window.title
        XCTAssertTrue(title.contains("001-landscape.jpg"),
                      "Should be back at first image after zoom cycles, got: \(title)")
        XCTAssertTrue(title.contains("1/3"),
                      "Should show position 1/3, got: \(title)")
        assertImageOverlapsViewport(in: window)
    }

    /// Validates: Aggressive zoom (Actual Size + 3× Zoom In) keeps image visible in viewport.
    /// Exercises: actualSize → 3× zoomIn → fitOnScreen round-trip via menu shortcuts.
    /// Verifies zoom magnitude by asserting window frame growth at each step.
    /// Does NOT cover: scroll-event-triggered magnification path (handleCmdScrollZoom / pinch).
    func testAggressiveZoom_ImageRemainsVisible() throws {
        let window = app.windows["imageWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 10),
                      "Main window should appear after launch")
        XCTAssertTrue(waitForImageState("imageContent-loaded").exists)

        // Actual Size first
        app.typeKey("1", modifierFlags: .command)
        waitForStableLayout()
        let actualSizeFrame = window.frame
        assertImageOverlapsViewport(in: window)

        // Zoom in aggressively (3 steps), verify frame grows
        app.typeKey("=", modifierFlags: .command)
        waitForStableLayout()
        let afterZoom1 = window.frame
        XCTAssertGreaterThanOrEqual(afterZoom1.width, actualSizeFrame.width,
                                    "First zoom should not shrink window")

        app.typeKey("=", modifierFlags: .command)
        waitForStableLayout()
        let afterZoom2 = window.frame
        XCTAssertGreaterThanOrEqual(afterZoom2.width, afterZoom1.width,
                                    "Second zoom should not shrink window vs first zoom")

        app.typeKey("=", modifierFlags: .command)
        waitForStableLayout()
        let afterZoom3 = window.frame
        XCTAssertGreaterThanOrEqual(afterZoom3.width, afterZoom2.width,
                                    "Third zoom should not shrink window vs second zoom")

        // Image must still overlap viewport even at high magnification
        assertImageOverlapsViewport(in: window)

        // Fit on Screen to restore
        app.typeKey("0", modifierFlags: .command)
        waitForStableLayout()

        // Verify image is fully restored and visible
        let image = waitForImageState("imageContent-loaded")
        XCTAssertTrue(image.exists, "Image should exist after fit restore")
        assertImageOverlapsViewport(in: window)
    }

    // Note: scroll view zoom + navigation is exercised via keyboard shortcuts.
    // Direct scroll wheel simulation is not feasible in XCUITest macOS due to accessibility
    // frame issue (hit point {1,0}) on NSScrollView.
    func testSmoke_KeyboardNavigationCycle() throws {
        XCTAssertTrue(waitForImageState("imageContent-loaded").exists)

        app.typeKey("1", modifierFlags: .command)   // Actual Size

        app.typeKey("]", modifierFlags: .command)   // 前往下一張
        let predNext = NSPredicate { _, _ in
            self.waitForImageState("imageContent-loaded", timeout: 2).label.contains("002")
        }
        let resultNext = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predNext, object: nil)], timeout: 15)
        XCTAssertEqual(resultNext, .completed, "Navigation to next image timed out")

        app.typeKey("[", modifierFlags: .command)   // 返回上一張
        let predPrev = NSPredicate { _, _ in
            self.waitForImageState("imageContent-loaded", timeout: 2).label.contains("001")
        }
        let resultPrev = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predPrev, object: nil)], timeout: 15)
        XCTAssertEqual(resultPrev, .completed, "Navigation back to first image timed out")

        XCTAssertTrue(waitForImageState("imageContent-loaded").exists,
            "Image should still be visible after navigation cycle")
    }
}
