import XCTest
@testable import Cee

final class URLFilterTests: XCTestCase {

    // MARK: - Test Doubles

    /// Always returns true (simulates all URLs supported)
    private func alwaysSupported(_ url: URL) -> Bool { true }

    /// Always returns false (simulates no URLs supported)
    private func neverSupported(_ url: URL) -> Bool { false }

    /// Returns true only for .jpg extension
    private func onlyJPGSupported(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "jpg" || url.pathExtension.lowercased() == "jpeg"
    }

    // MARK: - filterImageURLs Tests

    func testFilterImageURLs_allSupported_returnsOriginalArray() {
        let urls = [
            URL(fileURLWithPath: "/tmp/a.jpg"),
            URL(fileURLWithPath: "/tmp/b.png"),
            URL(fileURLWithPath: "/tmp/c.pdf")
        ]
        let result = URLFilter.filterImageURLs(urls, isSupported: alwaysSupported)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result, urls)
    }

    func testFilterImageURLs_noneSupported_returnsEmptyArray() {
        let urls = [
            URL(fileURLWithPath: "/tmp/a.txt"),
            URL(fileURLWithPath: "/tmp/b.mp4")
        ]
        let result = URLFilter.filterImageURLs(urls, isSupported: neverSupported)
        XCTAssertTrue(result.isEmpty)
    }

    func testFilterImageURLs_mixed_returnsOnlySupported() {
        let urls = [
            URL(fileURLWithPath: "/tmp/a.jpg"),
            URL(fileURLWithPath: "/tmp/b.txt"),
            URL(fileURLWithPath: "/tmp/c.jpeg"),
            URL(fileURLWithPath: "/tmp/d.mp4")
        ]
        let result = URLFilter.filterImageURLs(urls, isSupported: onlyJPGSupported)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].pathExtension, "jpg")
        XCTAssertEqual(result[1].pathExtension, "jpeg")
    }

    func testFilterImageURLs_emptyArray_returnsEmptyArray() {
        let urls: [URL] = []
        let result = URLFilter.filterImageURLs(urls, isSupported: alwaysSupported)
        XCTAssertTrue(result.isEmpty)
    }

    func testFilterImageURLs_caseInsensitive() {
        let urls = [
            URL(fileURLWithPath: "/tmp/a.JPG"),
            URL(fileURLWithPath: "/tmp/b.Jpeg"),
            URL(fileURLWithPath: "/tmp/c.txt")
        ]
        let result = URLFilter.filterImageURLs(urls, isSupported: onlyJPGSupported)
        XCTAssertEqual(result.count, 2)
    }

    // MARK: - Integration with ImageFolder.isSupported

    func testFilterImageURLs_withRealIsSupported() {
        let urls = [
            URL(fileURLWithPath: "/tmp/image.jpg"),
            URL(fileURLWithPath: "/tmp/file.txt"),
            URL(fileURLWithPath: "/tmp/doc.pdf"),
            URL(fileURLWithPath: "/tmp/video.mp4")
        ]
        let result = URLFilter.filterImageURLs(urls, isSupported: ImageFolder.isSupported(url:))
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].pathExtension, "jpg")
        XCTAssertEqual(result[1].pathExtension, "pdf")
    }
}
