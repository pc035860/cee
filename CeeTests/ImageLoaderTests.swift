@testable import Cee
import XCTest

final class ImageLoaderTests: XCTestCase {

    func testLoadThumbnail_returnsSmallerImageWithDimensions() async throws {
        #if !canImport(AppKit)
        throw XCTSkip("AppKit required for createPNG")
        #else
        let url = try createPNG(width: 256, height: 256)
        defer { try? FileManager.default.removeItem(at: url) }

        let loader = ImageLoader()
        let result = await loader.loadThumbnail(at: url, maxSize: 128)

        XCTAssertNotNil(result)
        let size = result!.image.size
        XCTAssertLessThanOrEqual(max(size.width, size.height), 128 + 1, "Thumbnail should be at most 128pt")
        // fullSize should reflect original dimensions
        XCTAssertEqual(result!.fullSize.width, 256, accuracy: 1)
        XCTAssertEqual(result!.fullSize.height, 256, accuracy: 1)
        #endif
    }

    func testLoadThumbnail_cachesResult() async throws {
        #if !canImport(AppKit)
        throw XCTSkip("AppKit required for createPNG")
        #else
        let url = try createPNG(width: 100, height: 100)
        defer { try? FileManager.default.removeItem(at: url) }

        let loader = ImageLoader()
        _ = await loader.loadThumbnail(at: url, maxSize: 64)
        let second = await loader.loadThumbnail(at: url, maxSize: 64)
        XCTAssertNotNil(second)
        #endif
    }

    func testLoadThumbnail_invalidURL_returnsNil() async {
        let invalidURL = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).png")
        let loader = ImageLoader()
        let result = await loader.loadThumbnail(at: invalidURL, maxSize: 128)
        XCTAssertNil(result)
    }
}
