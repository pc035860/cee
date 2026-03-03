import XCTest
@testable import Cee

final class ViewerSettingsTests: XCTestCase {

    // MARK: - Default Values

    func testDefaultArrowLeftRightNavigation_isTrue() {
        let settings = ViewerSettings()
        XCTAssertTrue(settings.arrowLeftRightNavigation)
    }

    func testDefaultArrowUpDownNavigation_isFalse() {
        let settings = ViewerSettings()
        XCTAssertFalse(settings.arrowUpDownNavigation)
    }

    // MARK: - Codable Round-Trip

    func testCodableRoundTrip_arrowNavigation_preservesValues() throws {
        var settings = ViewerSettings()
        settings.arrowLeftRightNavigation = false
        settings.arrowUpDownNavigation = true

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ViewerSettings.self, from: data)

        XCTAssertFalse(decoded.arrowLeftRightNavigation)
        XCTAssertTrue(decoded.arrowUpDownNavigation)
    }

    func testCodableBackwardCompat_missingKeys_usesDefaults() throws {
        // Simulate old settings JSON without the new arrow navigation keys
        let json = """
        {
            "magnification": 1.0,
            "isManualZoom": false,
            "alwaysFitOnOpen": true,
            "scalingQuality": "medium",
            "showPixelsWhenZoomingIn": true,
            "trackpadSensitivity": "medium",
            "wheelSensitivity": "medium",
            "resizeWindowAutomatically": false,
            "floatOnTop": false,
            "showStatusBar": true,
            "dualPageEnabled": false,
            "firstPageIsCover": false,
            "readingDirection": "rightToLeft",
            "fittingOptions": {
                "shrinkHorizontally": true,
                "shrinkVertically": true,
                "stretchHorizontally": false,
                "stretchVertically": false
            }
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ViewerSettings.self, from: data)

        // New keys should fall back to defaults
        XCTAssertTrue(decoded.arrowLeftRightNavigation)
        XCTAssertFalse(decoded.arrowUpDownNavigation)
        XCTAssertEqual(decoded.quickGridCellSize, 120, "Missing quickGridCellSize should default to 120")
    }

    // MARK: - Quick Grid Cell Size

    func testDefaultQuickGridCellSize_is120() {
        let settings = ViewerSettings()
        XCTAssertEqual(settings.quickGridCellSize, 120)
    }

    func testCodableRoundTrip_quickGridCellSize() throws {
        var settings = ViewerSettings()
        settings.quickGridCellSize = 150

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ViewerSettings.self, from: data)

        XCTAssertEqual(decoded.quickGridCellSize, 150)
    }
}
