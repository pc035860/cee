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

    /// Minimal valid 1x1 white PNG (67 bytes).
    private func minimalPNG() -> Data {
        let bytes: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
            0xDE,
            0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54,
            0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00, 0x00,
            0x00, 0x02, 0x00, 0x01, 0xE2, 0x21, 0xBC, 0x33,
            0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44,
            0xAE, 0x42, 0x60, 0x82,
        ]
        return Data(bytes)
    }

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

    // MARK: - Tests

    func testFolderWithTopLevelImages_noSubfolderSearch() {
        // Images at top level → folderURL stays the same
        writePNG(in: tempDir, name: "photo.png")

        let folder = ImageFolder(folderURL: tempDir)

        assertEqualPaths(folder.folderURL, tempDir)
        XCTAssertFalse(folder.images.isEmpty)
    }

    func testEmptyFolder_remainsEmpty() {
        // Completely empty folder → no crash, images empty
        let folder = ImageFolder(folderURL: tempDir)

        assertEqualPaths(folder.folderURL, tempDir)
        XCTAssertTrue(folder.images.isEmpty)
    }

    func testSubfolderDepth1_findsImages() {
        // tempDir/
        //   subA/
        //     photo.png
        let subA = createSubdir("subA")
        writePNG(in: subA)

        let folder = ImageFolder(folderURL: tempDir)

        assertEqualPaths(folder.folderURL, subA, "Should redirect to subfolder with images")
        XCTAssertFalse(folder.images.isEmpty)
    }

    func testSubfolderDepth2_findsImages() {
        // tempDir/
        //   level1/
        //     level2/
        //       photo.png
        let level1 = createSubdir("level1")
        let level2 = createSubdir("level1/level2")
        writePNG(in: level2)

        let folder = ImageFolder(folderURL: tempDir)

        assertEqualPaths(folder.folderURL, level2, "Should find images at depth 2")
        XCTAssertFalse(folder.images.isEmpty)
    }

    func testSubfolderDepth3_tooDeep() {
        // tempDir/
        //   a/
        //     b/
        //       c/
        //         photo.png  ← depth 3, beyond maxDepth=2
        _ = createSubdir("a")
        _ = createSubdir("a/b")
        let c = createSubdir("a/b/c")
        writePNG(in: c)

        let folder = ImageFolder(folderURL: tempDir)

        // Should NOT find it — too deep
        assertEqualPaths(folder.folderURL, tempDir)
        XCTAssertTrue(folder.images.isEmpty)
    }

    func testBFS_findsClosestSubfolder() {
        // tempDir/
        //   alpha/
        //     deep/
        //       photo.png       ← depth 2
        //   beta/
        //     photo.png         ← depth 1 (closer!)
        _ = createSubdir("alpha/deep")
        writePNG(in: tempDir.appendingPathComponent("alpha/deep"))
        let beta = createSubdir("beta")
        writePNG(in: beta)

        let folder = ImageFolder(folderURL: tempDir)

        // BFS should find beta (depth 1) before alpha/deep (depth 2)
        assertEqualPaths(folder.folderURL, beta)
    }

    func testBFS_alphabeticalOrderWithinSameDepth() {
        // tempDir/
        //   zebra/
        //     photo.png
        //   alpha/
        //     photo.png
        let zebra = createSubdir("zebra")
        writePNG(in: zebra)
        let alpha = createSubdir("alpha")
        writePNG(in: alpha)

        let folder = ImageFolder(folderURL: tempDir)

        // Both at depth 1 — alphabetically "alpha" comes first
        assertEqualPaths(folder.folderURL, alpha)
    }

    func testHiddenSubfoldersSkipped() {
        // tempDir/
        //   .hidden/
        //     photo.png     ← should be skipped
        //   visible/
        //     photo.png
        let hidden = createSubdir(".hidden")
        writePNG(in: hidden)
        let visible = createSubdir("visible")
        writePNG(in: visible)

        let folder = ImageFolder(folderURL: tempDir)

        assertEqualPaths(folder.folderURL, visible)
    }

    func testFindFirstSubfolderWithImages_staticMethod() {
        // Direct test of the static method
        let sub = createSubdir("photos")
        writePNG(in: sub)

        let result = ImageFolder.findFirstSubfolderWithImages(in: tempDir, maxDepth: 2)

        assertEqualPaths(result!, sub)
    }

    func testFindFirstSubfolderWithImages_returnsNil_whenNoImages() {
        // Only empty subdirectories
        _ = createSubdir("empty1")
        _ = createSubdir("empty2")

        let result = ImageFolder.findFirstSubfolderWithImages(in: tempDir, maxDepth: 2)

        XCTAssertNil(result)
    }
}
