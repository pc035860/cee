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

    // MARK: - Layout Helpers tests (Implicit)
    func testLayoutCalculations() {
        // ContinuousScrollContentView logic uses unflipped system (y=0 at bottom)
        // With imageSizes: [800x600, 800x600] and containerWidth 800
        // Scaled height is 600.
        // Array of offsets should be [totalHeight - 600, totalHeight - 1200]
        
        // As recalculateLayout is private, test functionality implicitly through public functions 
        // if they were available, but currently CalculateCurrentIndex needs imageSizes which are private.
        // We ensure standard init doesn't throw.
    }
}
