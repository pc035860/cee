@testable import Cee
import XCTest

// MARK: - ImageLoader Subsample Tests for Continuous Scroll

final class ContinuousScrollSubsampleTests: XCTestCase {

    // MARK: - Test 1: Large JPEG gets subsampled

    func testLargeJPEG_getsSubsampled() async throws {
        let loader = ImageLoader()
        let url = try createJPEG(width: 4000, height: 6000)
        defer { try? FileManager.default.removeItem(at: url) }

        // maxWidth = 800 display pixels (simulating 400pt * 2x Retina)
        // ratio = 4000 / 800 = 5.0 → subsample factor 4
        let image = await loader.loadImageForDisplay(at: url, maxWidth: 800)

        XCTAssertNotNil(image, "Should return a valid image")
        guard let image else { return }

        // Subsampled image should be significantly smaller than source (4000px)
        let width = Int(image.size.width)
        XCTAssertLessThanOrEqual(width, 800,
                                 "Subsampled image width should be ≤ maxWidth (\(width))")
        XCTAssertGreaterThan(width, 0, "Image should have positive width")
    }

    // MARK: - Test 2: Small image NOT subsampled

    func testSmallJPEG_notSubsampled() async throws {
        let loader = ImageLoader()
        let url = try createJPEG(width: 800, height: 600)
        defer { try? FileManager.default.removeItem(at: url) }

        // maxWidth = 800 → ratio = 800 / 800 = 1.0 → no subsample
        let image = await loader.loadImageForDisplay(at: url, maxWidth: 800)

        XCTAssertNotNil(image, "Should return a valid image")
        guard let image else { return }

        // Should be at original resolution (no subsample, full decode)
        // decodeImage creates NSImage(cgImage:size:) where size = cgImage pixel dimensions
        let width = Int(image.size.width)
        XCTAssertEqual(width, 800, "Small image should be at original width")
    }

    // MARK: - Test 3: Cache hit returns same image

    func testCacheHit_returnsSameImage() async throws {
        let loader = ImageLoader()
        let url = try createJPEG(width: 2000, height: 3000)
        defer { try? FileManager.default.removeItem(at: url) }

        let image1 = await loader.loadImageForDisplay(at: url, maxWidth: 800)
        let image2 = await loader.loadImageForDisplay(at: url, maxWidth: 800)

        XCTAssertNotNil(image1)
        XCTAssertNotNil(image2)
        // Same object from cache
        XCTAssertTrue(image1 === image2, "Second call should return cached image")
    }

    // MARK: - Test 4: displayCache isolation from main cache

    func testCacheIsolation_displayAndMainCacheSeparate() async throws {
        let loader = ImageLoader()
        let url = try createJPEG(width: 4000, height: 6000)
        defer { try? FileManager.default.removeItem(at: url) }

        // Load via main cache
        _ = await loader.loadImage(at: url)
        let mainCount = await loader._testImageCacheCount()
        XCTAssertEqual(mainCount, 1, "Main cache should have 1 entry")

        // Load via display cache
        _ = await loader.loadImageForDisplay(at: url, maxWidth: 800)
        let displayCount = await loader._testDisplayCacheCount()
        XCTAssertEqual(displayCount, 1, "Display cache should have 1 entry")

        // Both caches should have entries independently
        let mainCountAfter = await loader._testImageCacheCount()
        XCTAssertEqual(mainCountAfter, 1, "Main cache should still have 1 entry")
    }

    // MARK: - Test 5: clearImageCache clears displayCache

    func testClearImageCache_clearsDisplayCache() async throws {
        let loader = ImageLoader()
        let url = try createJPEG(width: 4000, height: 6000)
        defer { try? FileManager.default.removeItem(at: url) }

        _ = await loader.loadImageForDisplay(at: url, maxWidth: 800)
        let countBefore = await loader._testDisplayCacheCount()
        XCTAssertGreaterThan(countBefore, 0, "Display cache should have entries")

        await loader.clearImageCache()

        let countAfter = await loader._testDisplayCacheCount()
        XCTAssertEqual(countAfter, 0, "clearImageCache should clear display cache")
    }
}
