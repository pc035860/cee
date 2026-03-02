import XCTest
@testable import Cee

final class ImageFolderNavigationTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CeeTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    /// Create N dummy PNG files in tempDir and return an ImageFolder containing the first file.
    private func makeFolder(count: Int) -> ImageFolder {
        for i in 0..<count {
            let name = String(format: "img%03d.png", i)
            let url = tempDir.appendingPathComponent(name)
            // Write minimal valid PNG data (1x1 white pixel)
            let pngData = minimalPNG()
            try! pngData.write(to: url)
        }
        let firstFile = tempDir.appendingPathComponent("img000.png")
        return ImageFolder(containing: firstFile)
    }

    /// Minimal valid 1x1 white PNG (67 bytes).
    private func minimalPNG() -> Data {
        // 1x1 white RGBA PNG
        let bytes: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // signature
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR chunk
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
            0xDE,
            0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54, // IDAT chunk
            0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00, 0x00,
            0x00, 0x02, 0x00, 0x01, 0xE2, 0x21, 0xBC, 0x33,
            0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, // IEND chunk
            0xAE, 0x42, 0x60, 0x82,
        ]
        return Data(bytes)
    }

    /// Portrait size provider (all indices are portrait).
    private func allPortrait(_ index: Int) -> CGSize? {
        CGSize(width: 800, height: 1200)
    }

    // MARK: - Spread Navigation Tests

    func testGoNextSpread_advancesCorrectly() {
        let folder = makeFolder(count: 6)
        XCTAssertEqual(folder.images.count, 6)

        folder.rebuildSpreads(firstPageIsCover: false, imageSizeProvider: allPortrait)
        // Spreads: double(0,1), double(2,3), double(4,5)
        XCTAssertEqual(folder.spreads.count, 3)
        XCTAssertEqual(folder.currentSpreadIndex, 0)

        XCTAssertTrue(folder.goNextSpread())
        XCTAssertEqual(folder.currentSpreadIndex, 1)
        XCTAssertEqual(folder.currentIndex, 2)

        XCTAssertTrue(folder.goNextSpread())
        XCTAssertEqual(folder.currentSpreadIndex, 2)
        XCTAssertEqual(folder.currentIndex, 4)

        // At end, should fail
        XCTAssertFalse(folder.goNextSpread())
        XCTAssertEqual(folder.currentSpreadIndex, 2)
    }

    func testGoPreviousSpread_reversesCorrectly() {
        let folder = makeFolder(count: 6)
        folder.rebuildSpreads(firstPageIsCover: false, imageSizeProvider: allPortrait)

        // Move to last spread first
        folder.goToLastSpread()
        XCTAssertEqual(folder.currentSpreadIndex, 2)
        XCTAssertEqual(folder.currentIndex, 4)

        XCTAssertTrue(folder.goPreviousSpread())
        XCTAssertEqual(folder.currentSpreadIndex, 1)
        XCTAssertEqual(folder.currentIndex, 2)

        XCTAssertTrue(folder.goPreviousSpread())
        XCTAssertEqual(folder.currentSpreadIndex, 0)
        XCTAssertEqual(folder.currentIndex, 0)

        // At beginning, should fail
        XCTAssertFalse(folder.goPreviousSpread())
        XCTAssertEqual(folder.currentSpreadIndex, 0)
    }

    func testGoToFirstAndLastSpread() {
        let folder = makeFolder(count: 4)
        folder.rebuildSpreads(firstPageIsCover: false, imageSizeProvider: allPortrait)
        // Spreads: double(0,1), double(2,3)

        folder.goToLastSpread()
        XCTAssertEqual(folder.currentSpreadIndex, 1)
        XCTAssertEqual(folder.currentIndex, 2)

        folder.goToFirstSpread()
        XCTAssertEqual(folder.currentSpreadIndex, 0)
        XCTAssertEqual(folder.currentIndex, 0)
    }

    func testSyncSpreadIndex_afterSinglePageNavigation() {
        let folder = makeFolder(count: 4)
        folder.rebuildSpreads(firstPageIsCover: false, imageSizeProvider: allPortrait)
        // Spreads: double(0,1), double(2,3)

        // goNext uses single-page navigation, which auto-calls syncSpreadIndex
        XCTAssertTrue(folder.goNext())  // currentIndex: 0 → 1
        XCTAssertEqual(folder.currentSpreadIndex, 0)  // still in spread 0

        XCTAssertTrue(folder.goNext())  // currentIndex: 1 → 2
        XCTAssertEqual(folder.currentSpreadIndex, 1)  // now in spread 1

        XCTAssertTrue(folder.goNext())  // currentIndex: 2 → 3
        XCTAssertEqual(folder.currentSpreadIndex, 1)  // still in spread 1
    }

    func testHasNextAndPreviousSpread() {
        let folder = makeFolder(count: 4)
        folder.rebuildSpreads(firstPageIsCover: false, imageSizeProvider: allPortrait)
        // Spreads: double(0,1), double(2,3)

        XCTAssertTrue(folder.hasNextSpread)
        XCTAssertFalse(folder.hasPreviousSpread)

        folder.goNextSpread()
        XCTAssertFalse(folder.hasNextSpread)
        XCTAssertTrue(folder.hasPreviousSpread)
    }

    func testCurrentSpread_returnsCorrectSpread() {
        let folder = makeFolder(count: 4)
        folder.rebuildSpreads(firstPageIsCover: false, imageSizeProvider: allPortrait)

        let first = folder.currentSpread
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.leadingIndex, 0)
        XCTAssertEqual(first?.indices, [0, 1])

        folder.goNextSpread()
        let second = folder.currentSpread
        XCTAssertNotNil(second)
        XCTAssertEqual(second?.leadingIndex, 2)
        XCTAssertEqual(second?.indices, [2, 3])
    }
}
