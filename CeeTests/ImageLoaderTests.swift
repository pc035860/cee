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

    // MARK: - Composite Cache Key Isolation

    func testLoadThumbnail_differentMaxSizes_separateCacheEntries() async throws {
        #if !canImport(AppKit)
        throw XCTSkip("AppKit required for createPNG")
        #else
        let url = try createPNG(width: 800, height: 800)
        defer { try? FileManager.default.removeItem(at: url) }

        let loader = ImageLoader()
        let small = await loader.loadThumbnail(at: url, maxSize: 240)
        let large = await loader.loadThumbnail(at: url, maxSize: 480)

        XCTAssertNotNil(small)
        XCTAssertNotNil(large)
        // Different maxSize should produce different thumbnail dimensions
        let smallMax = max(small!.image.size.width, small!.image.size.height)
        let largeMax = max(large!.image.size.width, large!.image.size.height)
        XCTAssertLessThanOrEqual(smallMax, 240 + 1)
        XCTAssertLessThanOrEqual(largeMax, 480 + 1)
        XCTAssertGreaterThan(largeMax, smallMax, "480px thumbnail should be larger than 240px")
        // Both should report the same fullSize (original dimensions)
        XCTAssertEqual(small!.fullSize.width, large!.fullSize.width, accuracy: 1)
        #endif
    }

    func testLoadThumbnail_sameMaxSize_cacheHit() async throws {
        #if !canImport(AppKit)
        throw XCTSkip("AppKit required for createPNG")
        #else
        let url = try createPNG(width: 400, height: 400)
        defer { try? FileManager.default.removeItem(at: url) }

        let loader = ImageLoader()
        let first = await loader.loadThumbnail(at: url, maxSize: 240)
        // Delete file — second call must come from cache
        try FileManager.default.removeItem(at: url)
        let second = await loader.loadThumbnail(at: url, maxSize: 240)

        XCTAssertNotNil(first)
        XCTAssertNotNil(second, "Same maxSize should hit cache even after file deletion")
        #endif
    }

    // MARK: - SubsampleFactor (Phase 3.1)

    func testLoadThumbnail_smallMaxSize_appliesSubsampleFactor() async throws {
        #if !canImport(AppKit)
        throw XCTSkip("AppKit required for createJPEG")
        #else
        let url = try createJPEG(width: 2000, height: 2000)
        defer { try? FileManager.default.removeItem(at: url) }

        let loader = ImageLoader()
        let result = await loader.loadThumbnail(at: url, maxSize: 80)

        XCTAssertNotNil(result, "Small maxSize with SubsampleFactor should still produce valid image")
        let maxEdge = max(result!.image.size.width, result!.image.size.height)
        XCTAssertLessThanOrEqual(maxEdge, 80 + 1, "Thumbnail should be at most 80px")
        // fullSize should still reflect original dimensions
        XCTAssertEqual(result!.fullSize.width, 2000, accuracy: 1)
        XCTAssertEqual(result!.fullSize.height, 2000, accuracy: 1)
        #endif
    }

    func testLoadThumbnail_largeMaxSize_noSubsampleFactor() async throws {
        #if !canImport(AppKit)
        throw XCTSkip("AppKit required for createJPEG")
        #else
        let url = try createJPEG(width: 2000, height: 2000)
        defer { try? FileManager.default.removeItem(at: url) }

        let loader = ImageLoader()
        let result = await loader.loadThumbnail(at: url, maxSize: 240)

        XCTAssertNotNil(result, "Large maxSize should produce valid image")
        let maxEdge = max(result!.image.size.width, result!.image.size.height)
        XCTAssertLessThanOrEqual(maxEdge, 240 + 1, "Thumbnail should be at most 240px")
        XCTAssertEqual(result!.fullSize.width, 2000, accuracy: 1)
        #endif
    }

    // MARK: - Dual Priority Loading

    func testLoadThumbnail_utilityPriority_stillWorks() async throws {
        #if !canImport(AppKit)
        throw XCTSkip("AppKit required for createPNG")
        #else
        let url = try createPNG(width: 200, height: 200)
        defer { try? FileManager.default.removeItem(at: url) }

        let loader = ImageLoader()
        let result = await loader.loadThumbnail(at: url, maxSize: 128, priority: .utility)

        XCTAssertNotNil(result, "Utility priority should still produce a valid thumbnail")
        let size = result!.image.size
        XCTAssertLessThanOrEqual(max(size.width, size.height), 128 + 1)
        #endif
    }

    func testLoadThumbnail_bothPriorities_sameCache() async throws {
        #if !canImport(AppKit)
        throw XCTSkip("AppKit required for createPNG")
        #else
        let url = try createPNG(width: 300, height: 300)
        defer { try? FileManager.default.removeItem(at: url) }

        let loader = ImageLoader()
        // Load with userInitiated first
        _ = await loader.loadThumbnail(at: url, maxSize: 240, priority: .userInitiated)
        // Delete file — second call with utility must hit cache
        try FileManager.default.removeItem(at: url)
        let second = await loader.loadThumbnail(at: url, maxSize: 240, priority: .utility)

        XCTAssertNotNil(second, "Different priority should still hit same cache key")
        #endif
    }
}
