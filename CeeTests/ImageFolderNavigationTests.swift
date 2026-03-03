import XCTest
@testable import Cee

final class ImageFolderNavigationTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        // Resolve symlinks to avoid /var vs /private/var mismatch
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CeeTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    /// Create N dummy PNG files in tempDir and return an ImageFolder containing the specified file.
    private func makeFolder(count: Int, openIndex: Int = 0) -> ImageFolder {
        for i in 0..<count {
            let name = String(format: "img%03d.png", i)
            let url = tempDir.appendingPathComponent(name)
            let pngData = minimalPNG()
            try! pngData.write(to: url)
        }
        let targetFile = tempDir.appendingPathComponent(String(format: "img%03d.png", openIndex))
        return ImageFolder(containing: targetFile)
    }

    /// Portrait size provider (all indices are portrait).
    private func allPortrait(_ index: Int) -> CGSize? {
        CGSize(width: 800, height: 1200)
    }

    // MARK: - init(containing:) Tests

    func testInitContaining_currentIndex_startsAtFirstFile() {
        let folder = makeFolder(count: 3)
        // makeFolder opens img000.png (first file) → index 0
        XCTAssertEqual(folder.currentIndex, 0)
        XCTAssertEqual(folder.currentImage?.url.lastPathComponent, "img000.png")
    }

    func testInitContaining_folderURL_correct() {
        let folder = makeFolder(count: 2)
        // Compare paths to avoid trailing-slash differences
        XCTAssertEqual(folder.folderURL.path, tempDir.path)
    }

    func testInitContaining_imagesCount_correct() {
        let folder = makeFolder(count: 3)
        XCTAssertEqual(folder.images.count, 3)
    }

    func testInitContaining_sortedAlphabetically() {
        // Create files in non-alphabetical order
        let names = ["img002.png", "img000.png", "img001.png"]
        for name in names {
            let url = tempDir.appendingPathComponent(name)
            try! minimalPNG().write(to: url)
        }
        let folder = ImageFolder(containing: tempDir.appendingPathComponent("img000.png"))
        XCTAssertEqual(folder.images.count, 3)
        XCTAssertEqual(folder.images[0].url.lastPathComponent, "img000.png")
        XCTAssertEqual(folder.images[1].url.lastPathComponent, "img001.png")
        XCTAssertEqual(folder.images[2].url.lastPathComponent, "img002.png")
    }

    // MARK: - Basic Navigation Tests

    func testGoNext_advances() {
        let folder = makeFolder(count: 3)
        XCTAssertTrue(folder.goNext())
        XCTAssertEqual(folder.currentIndex, 1)
    }

    func testGoNext_atEnd_fails() {
        let folder = makeFolder(count: 3)
        // Navigate to end
        XCTAssertTrue(folder.goNext())   // 0→1
        XCTAssertTrue(folder.goNext())   // 1→2
        XCTAssertFalse(folder.goNext())  // at end
        XCTAssertEqual(folder.currentIndex, 2)
    }

    func testGoPrevious_decrements() {
        let folder = makeFolder(count: 3)
        folder.goNext()  // 0→1
        folder.goNext()  // 1→2
        XCTAssertTrue(folder.goPrevious())
        XCTAssertEqual(folder.currentIndex, 1)
    }

    func testGoPrevious_atStart_fails() {
        let folder = makeFolder(count: 3)
        XCTAssertFalse(folder.goPrevious())
        XCTAssertEqual(folder.currentIndex, 0)
    }

    func testCurrentImage_correct() {
        let folder = makeFolder(count: 3)
        folder.goNext()
        let current = folder.currentImage
        XCTAssertNotNil(current)
        XCTAssertEqual(current?.url.lastPathComponent, "img001.png")
    }

    func testHasNext_hasPrevious() {
        let folder = makeFolder(count: 3)

        // At start: hasNext=true, hasPrevious=false
        XCTAssertTrue(folder.hasNext)
        XCTAssertFalse(folder.hasPrevious)

        // Middle: both true
        folder.goNext()  // 0→1
        XCTAssertTrue(folder.hasNext)
        XCTAssertTrue(folder.hasPrevious)

        // At end: hasNext=false, hasPrevious=true
        folder.goNext()  // 1→2
        XCTAssertFalse(folder.hasNext)
        XCTAssertTrue(folder.hasPrevious)
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
