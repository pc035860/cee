import XCTest
@testable import Cee

final class ImageFolderSubfolderSearchTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        // Resolve symlinks to avoid /var vs /private/var mismatch
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CeeTests-subfolder-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func createSubdir(_ name: String) -> URL {
        let dir = tempDir.appendingPathComponent(name, isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Compare folder URLs by standardized path (ignores trailing slash differences).
    private func assertEqualPaths(_ actual: URL, _ expected: URL, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(
            actual.standardizedFileURL.path,
            expected.standardizedFileURL.path,
            message, file: file, line: line
        )
    }

    private func writePNG(in dir: URL, name: String = "img.png") {
        try! minimalPNG().write(to: dir.appendingPathComponent(name))
    }

    private func relativePaths(_ folder: ImageFolder) -> [String] {
        folder.images.map { folder.relativePath(of: $0) }
    }

    // MARK: - Tests

    func testFolderWithTopLevelImages_doesNotJoinSubfolders() {
        // tempDir/
        //   photo.png
        //   subA/
        //     other.png   ← ignored: top level already has images
        writePNG(in: tempDir, name: "photo.png")
        writePNG(in: createSubdir("subA"), name: "other.png")

        let folder = ImageFolder(folderURL: tempDir)

        assertEqualPaths(folder.folderURL, tempDir)
        XCTAssertEqual(relativePaths(folder), ["photo.png"])
    }

    func testEmptyFolder_remainsEmpty() {
        let folder = ImageFolder(folderURL: tempDir)

        assertEqualPaths(folder.folderURL, tempDir)
        XCTAssertTrue(folder.images.isEmpty)
    }

    func testEmptyTopLevel_joinsAllSubfolders() {
        // tempDir/
        //   subA/ a.png
        //   subB/ b.png
        writePNG(in: createSubdir("subA"), name: "a.png")
        writePNG(in: createSubdir("subB"), name: "b.png")

        let folder = ImageFolder(folderURL: tempDir)

        assertEqualPaths(folder.folderURL, tempDir, "folderURL stays the given root")
        XCTAssertEqual(relativePaths(folder), ["subA/a.png", "subB/b.png"])
        XCTAssertEqual(folder.currentIndex, 0)
    }

    func testDeepNesting_noDepthLimit() {
        // tempDir/a/b/c/d/photo.png
        writePNG(in: createSubdir("a/b/c/d"), name: "photo.png")

        let folder = ImageFolder(folderURL: tempDir)

        XCTAssertEqual(relativePaths(folder), ["a/b/c/d/photo.png"])
    }

    func testOrder_depthFirst_naturalSort() {
        // tempDir/
        //   b/ 1.png
        //   a/ 2.png, 10.png
        //     sub/ 3.png
        writePNG(in: createSubdir("b"), name: "1.png")
        let a = createSubdir("a")
        writePNG(in: a, name: "10.png")
        writePNG(in: a, name: "2.png")
        writePNG(in: createSubdir("a/sub"), name: "3.png")

        let folder = ImageFolder(folderURL: tempDir)

        XCTAssertEqual(
            relativePaths(folder),
            ["a/2.png", "a/10.png", "a/sub/3.png", "b/1.png"]
        )
    }

    func testSubfolderOrder_naturalSortNotLexicographic() {
        writePNG(in: createSubdir("10"), name: "x.png")
        writePNG(in: createSubdir("2"), name: "x.png")

        let folder = ImageFolder(folderURL: tempDir)

        XCTAssertEqual(relativePaths(folder), ["2/x.png", "10/x.png"])
    }

    func testSymlinkedSubfolder_notFollowed() {
        let real = createSubdir("real")
        writePNG(in: real, name: "a.png")
        try! FileManager.default.createSymbolicLink(
            at: tempDir.appendingPathComponent("loop"),
            withDestinationURL: tempDir
        )

        let folder = ImageFolder(folderURL: tempDir)

        XCTAssertEqual(relativePaths(folder), ["real/a.png"])
    }

    func testSameFileNameInDifferentSubfolders_bothKept() {
        writePNG(in: createSubdir("subA"), name: "page.png")
        writePNG(in: createSubdir("subB"), name: "page.png")

        let folder = ImageFolder(folderURL: tempDir)

        XCTAssertEqual(relativePaths(folder), ["subA/page.png", "subB/page.png"])
    }

    func testHiddenSubfoldersSkipped() {
        // tempDir/
        //   .hidden/ photo.png   ← skipped
        //   visible/ photo.png
        writePNG(in: createSubdir(".hidden"))
        writePNG(in: createSubdir("visible"), name: "photo.png")

        let folder = ImageFolder(folderURL: tempDir)

        XCTAssertEqual(relativePaths(folder), ["visible/photo.png"])
    }

    func testRelativePath_outsideRoot_fallsBackToFileName() {
        let folder = ImageFolder(folderURL: tempDir)
        let outside = ImageItem(url: URL(fileURLWithPath: "/elsewhere/photo.png"))

        XCTAssertEqual(folder.relativePath(of: outside), "photo.png")
    }
}
