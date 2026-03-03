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

    // MARK: - isDirectory Tests

    private var tempDir: URL!

    private func setUpTempDir() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CeeTests-URLFilter-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    private func tearDownTempDir() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
    }

    func testIsDirectory_realDir_true() {
        setUpTempDir()
        defer { tearDownTempDir() }
        XCTAssertTrue(URLFilter.isDirectory(tempDir))
    }

    func testIsDirectory_regularFile_false() {
        setUpTempDir()
        defer { tearDownTempDir() }
        let file = tempDir.appendingPathComponent("test.png")
        try! minimalPNG().write(to: file)
        XCTAssertFalse(URLFilter.isDirectory(file))
    }

    func testIsDirectory_nonexistent_false() {
        let fake = URL(fileURLWithPath: "/tmp/CeeTests-nonexistent-\(UUID().uuidString)")
        XCTAssertFalse(URLFilter.isDirectory(fake))
    }

    // MARK: - filterImageAndFolderURLs Tests

    func testFilterImageAndFolder_supportedFile() {
        let urls = [URL(fileURLWithPath: "/tmp/photo.png")]
        let result = URLFilter.filterImageAndFolderURLs(urls, isSupported: alwaysSupported)
        XCTAssertEqual(result.count, 1)
    }

    func testFilterImageAndFolder_directory() {
        setUpTempDir()
        defer { tearDownTempDir() }
        let urls = [tempDir!]
        // isSupported returns false, but isDirectory saves it
        let result = URLFilter.filterImageAndFolderURLs(urls, isSupported: neverSupported)
        XCTAssertEqual(result.count, 1)
    }

    func testFilterImageAndFolder_unsupported() {
        let urls = [URL(fileURLWithPath: "/tmp/readme.txt")]
        let result = URLFilter.filterImageAndFolderURLs(urls, isSupported: neverSupported)
        XCTAssertTrue(result.isEmpty)
    }

    func testFilterImageAndFolder_mixed() {
        setUpTempDir()
        defer { tearDownTempDir() }
        let png = URL(fileURLWithPath: "/tmp/a.png")
        let dir = tempDir!
        let txt = URL(fileURLWithPath: "/tmp/b.txt")
        let urls = [png, dir, txt]
        let result = URLFilter.filterImageAndFolderURLs(urls, isSupported: { url in
            url.pathExtension.lowercased() == "png"
        })
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.contains(png))
        XCTAssertTrue(result.contains(dir))
    }

    func testFilterImageAndFolder_empty() {
        let result = URLFilter.filterImageAndFolderURLs([], isSupported: alwaysSupported)
        XCTAssertTrue(result.isEmpty)
    }
}
