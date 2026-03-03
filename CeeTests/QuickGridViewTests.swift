@testable import Cee
import XCTest

// MARK: - Mock Delegate

@MainActor
private final class MockQuickGridDelegate: QuickGridViewDelegate {
    var selectedIndex: Int?
    var closeRequested = false
    var droppedURLs: [URL]?

    func quickGridView(_ view: QuickGridView, didSelectItemAt index: Int) {
        selectedIndex = index
    }

    func quickGridView(_ view: QuickGridView, didReceiveDrop urls: [URL]) {
        droppedURLs = urls
    }

    func quickGridViewDidRequestClose(_ view: QuickGridView) {
        closeRequested = true
    }
}

// MARK: - Tests

@MainActor
final class QuickGridViewTests: XCTestCase {

    private var tempDir: URL!
    /// Dummy collection view passed to dataSource methods (the actual private collectionView is inaccessible)
    private let dummyCV = NSCollectionView()

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CeeTests-Grid-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeItems(count: Int) -> [ImageItem] {
        (0..<count).map { i in
            let name = String(format: "img%03d.png", i)
            let url = tempDir.appendingPathComponent(name)
            try! minimalPNG().write(to: url)
            return ImageItem(url: url)
        }
    }

    // MARK: - Configure Tests

    func testConfigure_setsItemCount() {
        let grid = QuickGridView()
        let loader = ImageLoader()
        let items = makeItems(count: 5)

        grid.configure(items: items, currentIndex: 2, loader: loader)

        // NSCollectionViewDataSource reports correct count
        let count = grid.collectionView(dummyCV, numberOfItemsInSection: 0)
        XCTAssertEqual(count, 5)
    }

    func testConfigure_reconfigureUpdatesItems() {
        let grid = QuickGridView()
        let loader = ImageLoader()

        // Configure with 3 items
        let items3 = makeItems(count: 3)
        grid.configure(items: items3, currentIndex: 0, loader: loader)
        XCTAssertEqual(grid.collectionView(dummyCV, numberOfItemsInSection: 0), 3)

        // Reconfigure with 7 items (simulates folder change refresh)
        let items7 = makeItems(count: 7)
        grid.configure(items: items7, currentIndex: 0, loader: loader)
        XCTAssertEqual(grid.collectionView(dummyCV, numberOfItemsInSection: 0), 7)
    }

    // MARK: - clearCache vs cleanup

    func testClearCache_thenReconfigure_updatesItems() {
        let grid = QuickGridView()
        let loader = ImageLoader()

        // Configure with 3 items
        let items3 = makeItems(count: 3)
        grid.configure(items: items3, currentIndex: 0, loader: loader)
        XCTAssertEqual(grid.collectionView(dummyCV, numberOfItemsInSection: 0), 3)

        // clearCache + reconfigure with new folder's items
        grid.clearCache()
        let items5 = makeItems(count: 5)
        grid.configure(items: items5, currentIndex: 2, loader: loader)
        XCTAssertEqual(grid.collectionView(dummyCV, numberOfItemsInSection: 0), 5)
    }

    func testCleanup_doesNotCrash() {
        let grid = QuickGridView()
        let loader = ImageLoader()
        let items = makeItems(count: 3)

        grid.configure(items: items, currentIndex: 0, loader: loader)
        grid.cleanup()

        // After cleanup, data source still reports last-configured items
        // (cleanup clears cache but doesn't reset items array)
        XCTAssertEqual(grid.collectionView(dummyCV, numberOfItemsInSection: 0), 3)
    }

    // MARK: - Drag Registration

    func testRegisteredForFileURLDragType() {
        let grid = QuickGridView()
        let types = grid.registeredDraggedTypes
        XCTAssertTrue(types.contains(.fileURL), "QuickGridView should accept .fileURL drags")
    }

    // MARK: - Delegate Protocol

    func testDelegateProtocol_hasDropMethod() {
        let grid = QuickGridView()
        let delegate = MockQuickGridDelegate()
        grid.delegate = delegate

        // Verify the delegate method exists and can be called
        let testURLs = [URL(fileURLWithPath: "/tmp/test.png")]
        delegate.quickGridView(grid, didReceiveDrop: testURLs)
        XCTAssertEqual(delegate.droppedURLs, testURLs)
    }
}
