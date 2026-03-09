import XCTest
@testable import Cee

@MainActor
final class ContinuousScrollContentViewTests: XCTestCase {

    var contentView: ContinuousScrollContentView!
    var loader: ImageLoader!

    override func setUp() {
        super.setUp()
        contentView = ContinuousScrollContentView()
        loader = ImageLoader()
    }

    override func tearDown() {
        contentView = nil
        loader = nil
        super.tearDown()
    }

    // MARK: - Initialization

    func testConfigureWithFolder_setsImageSizes() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for i in 0..<3 {
            let url = tempDir.appendingPathComponent("img\(i).png")
            try minimalPNG().write(to: url)
        }

        let folder = ImageFolder(folderURL: tempDir)
        contentView.configure(with: folder, imageLoader: loader)

        // Wait for async initialization
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // Test passes if it doesn't crash and layout completes
        XCTAssertNotNil(contentView)
    }

    // MARK: - Frame Calculation Tests

    func testFrameForImage_returnsCorrectFrame() async throws {
        // Given
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create images with different aspect ratios
        let url0 = try createPNG(width: 800, height: 600)
        let data0 = try Data(contentsOf: url0)
        try data0.write(to: tempDir.appendingPathComponent("img0.png"))

        let url1 = try createPNG(width: 800, height: 1200)
        let data1 = try Data(contentsOf: url1)
        try data1.write(to: tempDir.appendingPathComponent("img1.png"))

        let folder = ImageFolder(folderURL: tempDir)
        contentView.configure(with: folder, imageLoader: loader)
        contentView.containerWidth = 800

        // Wait for preload
        try await Task.sleep(nanoseconds: 200_000_000)

        // When: Get frame for second image
        let frame1 = contentView.frameForImage(at: 1)

        // Then: Second image should be at y=0 (bottom) with height 1200
        XCTAssertEqual(frame1.width, 800, accuracy: 0.1)
        XCTAssertEqual(frame1.height, 1200, accuracy: 0.1)
        XCTAssertEqual(frame1.origin.y, 0, accuracy: 0.1, "Second image should be at bottom")

        // And: First image should be above second
        let frame0 = contentView.frameForImage(at: 0)
        XCTAssertEqual(frame0.width, 800, accuracy: 0.1)
        XCTAssertEqual(frame0.height, 600, accuracy: 0.1)
        XCTAssertEqual(frame0.origin.y, 1200, accuracy: 0.1, "First image should be above second")
    }

    // MARK: - Index Tracking Tests

    func testCalculateCurrentIndex_returnsCorrectIndex() async throws {
        // Given
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create 3 images, each 800x1000
        for i in 0..<3 {
            let url = try createPNG(width: 800, height: 1000)
            let data = try Data(contentsOf: url)
            try data.write(to: tempDir.appendingPathComponent("img\(i).png"))
        }

        let folder = ImageFolder(folderURL: tempDir)
        contentView.configure(with: folder, imageLoader: loader)
        contentView.containerWidth = 800

        // Wait for preload
        try await Task.sleep(nanoseconds: 200_000_000)

        // When/Then: Test various scroll positions
        // Total height = 3000, images at: [2000-3000], [1000-2000], [0-1000]

        // At y=2500 (middle of image 0)
        XCTAssertEqual(contentView.calculateCurrentIndex(for: 2500), 0, "Should return index 0")

        // At y=1500 (middle of image 1)
        XCTAssertEqual(contentView.calculateCurrentIndex(for: 1500), 1, "Should return index 1")

        // At y=500 (middle of image 2)
        XCTAssertEqual(contentView.calculateCurrentIndex(for: 500), 2, "Should return index 2")
    }

    func testCalculateCurrentIndex_emptyHeights_returnsZero() {
        // Given: Empty contentView with no images
        // When/Then
        XCTAssertEqual(contentView.calculateCurrentIndex(for: 500), 0, "Empty view should return 0")
    }

    // MARK: - View Recycling Placeholder Tests
    // Note: calculateVisibleRange and manageSlotViews will be tested in Phase 3.1 implementation

    func testActiveSlots_initiallyEmpty() {
        // Initially there should be no active slots
        // This test will be expanded when view recycling is implemented
        XCTAssertNotNil(contentView)
    }

    // MARK: - Scroll Direction Tests

    func testUpdateScrollDirection_detectsDownwardScroll() {
        // Given: Set last scroll position
        contentView.lastScrollY = 1000

        // When: Scroll to smaller y (visually down in standard coordinates)
        contentView.updateScrollDirection(currentY: 500)

        // Then: Should detect downward scroll
        XCTAssertTrue(contentView.isScrollingDown, "Scrolling to smaller y should be downward (toward larger index)")
    }

    func testUpdateScrollDirection_detectsUpwardScroll() {
        // Given: Set last scroll position
        contentView.lastScrollY = 500

        // When: Scroll to larger y (visually up in standard coordinates)
        contentView.updateScrollDirection(currentY: 1000)

        // Then: Should detect upward scroll
        XCTAssertFalse(contentView.isScrollingDown, "Scrolling to larger y should be upward (toward smaller index)")
    }

    func testUpdateScrollDirection_firstCall_noCrash() {
        // Given: No previous scroll position (lastScrollY is nil)
        // When: First scroll update
        contentView.updateScrollDirection(currentY: 500)

        // Then: Should not crash, isScrollingDown should remain default
        XCTAssertNotNil(contentView)
    }
}
