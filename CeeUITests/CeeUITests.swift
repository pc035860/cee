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
