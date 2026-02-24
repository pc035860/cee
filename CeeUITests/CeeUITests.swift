import XCTest

@MainActor
final class CeeUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        app = XCUIApplication()

        let testBundle = Bundle(for: type(of: self))
        guard let fixtureFolder = testBundle.url(
            forResource: "Images",
            withExtension: nil,
            subdirectory: "Fixtures"
        ) else {
            XCTFail("Fixtures/Images not found in test bundle")
            return
        }

        let firstImage = fixtureFolder.appendingPathComponent("001-landscape.jpg")

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

    override func tearDownWithError() throws {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .deleteOnSuccess
        add(attachment)

        app.terminate()
        try super.tearDownWithError()
    }

    // MARK: - Smoke Tests

    func testSmoke_AppLaunchesAndDisplaysImage() throws {
        let window = app.windows["imageWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 10),
            "Main window should appear after launch")

        let loadedImage = app.otherElements["imageContent-loaded"]
        XCTAssertTrue(loadedImage.waitForExistence(timeout: 10),
            "Image should finish loading")

        let windowTitle = window.title
        XCTAssertTrue(windowTitle.contains("001-landscape.jpg"),
            "Window title should contain filename, got: \(windowTitle)")
        XCTAssertTrue(windowTitle.contains("/3"),
            "Window title should show total count of 3, got: \(windowTitle)")
    }

    func testSmoke_NavigateToNextImage() throws {
        let loadedImage = app.otherElements["imageContent-loaded"]
        XCTAssertTrue(loadedImage.waitForExistence(timeout: 10))

        app.typeKey(.rightArrow, modifierFlags: [])

        let newLoaded = app.otherElements["imageContent-loaded"]
        newLoaded.wait(until: { element in
            element.exists && (element.label.contains("002"))
        }, timeout: 10, message: "Second image should load after navigation")

        let window = app.windows["imageWindow"]
        let title = window.title
        XCTAssertTrue(title.contains("002-portrait.png"),
            "Title should show second image, got: \(title)")
        XCTAssertTrue(title.contains("2/3"),
            "Title should show position 2/3, got: \(title)")
    }

    func testSmoke_NavigateToPreviousImage() throws {
        let loadedImage = app.otherElements["imageContent-loaded"]
        XCTAssertTrue(loadedImage.waitForExistence(timeout: 10))

        app.typeKey(.rightArrow, modifierFlags: [])
        loadedImage.wait(until: { $0.exists && $0.label.contains("002") }, timeout: 10)

        app.typeKey(.leftArrow, modifierFlags: [])
        loadedImage.wait(until: { $0.exists && $0.label.contains("001") }, timeout: 10)

        let window = app.windows["imageWindow"]
        XCTAssertTrue(window.title.contains("001-landscape.jpg"))
        XCTAssertTrue(window.title.contains("1/3"))
    }

    func testSmoke_KeyboardZoom() throws {
        let loadedImage = app.otherElements["imageContent-loaded"]
        XCTAssertTrue(loadedImage.waitForExistence(timeout: 10))

        app.typeKey("1", modifierFlags: .command)   // Actual Size
        app.typeKey("=", modifierFlags: .command)   // Zoom In
        app.typeKey("0", modifierFlags: .command)   // Fit on Screen

        XCTAssertTrue(loadedImage.exists, "Image should still be visible after zoom operations")
    }

    func testSmoke_FullscreenToggle() throws {
        let loadedImage = app.otherElements["imageContent-loaded"]
        XCTAssertTrue(loadedImage.waitForExistence(timeout: 10))

        app.typeKey("f", modifierFlags: .command)   // Enter fullscreen
        sleep(2)

        XCTAssertTrue(loadedImage.exists, "Image should be visible in fullscreen")

        app.typeKey(.escape, modifierFlags: [])     // Exit fullscreen
        sleep(2)

        let window = app.windows["imageWindow"]
        XCTAssertTrue(window.exists, "Window should exist after exiting fullscreen")
    }

    func testSmoke_ScrollToPageTurn() throws {
        let loadedImage = app.otherElements["imageContent-loaded"]
        XCTAssertTrue(loadedImage.waitForExistence(timeout: 10))

        app.typeKey("1", modifierFlags: .command)   // Actual Size for scrollable image

        let scrollView = app.scrollViews["imageScrollView"]
        guard scrollView.exists else { return }

        let window = app.windows["imageWindow"]
        let initialTitle = window.title

        for _ in 0..<50 {
            scrollView.scrollDown(by: 100)
            if window.title != initialTitle { break }
        }

        let newTitle = window.title
        XCTAssertTrue(newTitle.contains("002"),
            "Should have paged to next image via scroll, got: \(newTitle)")
    }

    func testSmoke_ScrollView() throws {
        let loadedImage = app.otherElements["imageContent-loaded"]
        XCTAssertTrue(loadedImage.waitForExistence(timeout: 10))

        app.typeKey("1", modifierFlags: .command)   // Actual Size

        let scrollView = app.scrollViews["imageScrollView"]
        if scrollView.exists {
            scrollView.scrollDown(by: 100)
            scrollView.scrollUp(by: 100)
        }

        XCTAssertTrue(loadedImage.exists)
    }
}
