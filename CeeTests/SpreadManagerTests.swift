import XCTest
@testable import Cee

final class SpreadManagerTests: XCTestCase {

    // MARK: - Helpers

    /// Create dummy ImageItems with sequential filenames.
    private func makeItems(_ count: Int) -> [ImageItem] {
        (0..<count).map {
            ImageItem(url: URL(fileURLWithPath: "/tmp/img\($0).png"))
        }
    }

    /// Size provider that returns portrait for all items.
    private func allPortrait(_ item: ImageItem) -> CGSize? {
        CGSize(width: 800, height: 1200)
    }

    /// Size provider that returns wide for all items.
    private func allWide(_ item: ImageItem) -> CGSize? {
        CGSize(width: 1600, height: 900)
    }

    /// Size provider that returns nil (unknown) for all items.
    private func allUnknown(_ item: ImageItem) -> CGSize? {
        nil
    }

    /// Build a provider that returns wide for specific indices.
    private func wideAt(_ wideIndices: Set<Int>, items: [ImageItem]) -> (ImageItem) -> CGSize? {
        { item in
            guard let idx = items.firstIndex(of: item) else { return nil }
            if wideIndices.contains(idx) {
                return CGSize(width: 1600, height: 900)
            }
            return CGSize(width: 800, height: 1200)
        }
    }

    // MARK: - buildSpreads Tests

    func testEmptyArray_returnsEmpty() {
        let result = SpreadManager.buildSpreads(from: [], firstPageIsCover: false, imageSizeProvider: allPortrait)
        XCTAssertEqual(result.count, 0)
    }

    func testSinglePage_returnsSingleSpread() {
        let items = makeItems(1)
        let result = SpreadManager.buildSpreads(from: items, firstPageIsCover: false, imageSizeProvider: allPortrait)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0], .single(index: 0, item: items[0]))
    }

    func testFourPortrait_twoDoubles() {
        let items = makeItems(4)
        let result = SpreadManager.buildSpreads(from: items, firstPageIsCover: false, imageSizeProvider: allPortrait)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], .double(leadingIndex: 0, leading: items[0], trailingIndex: 1, trailing: items[1]))
        XCTAssertEqual(result[1], .double(leadingIndex: 2, leading: items[2], trailingIndex: 3, trailing: items[3]))
    }

    func testThreePortrait_oneDoubleOneSingle() {
        let items = makeItems(3)
        let result = SpreadManager.buildSpreads(from: items, firstPageIsCover: false, imageSizeProvider: allPortrait)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], .double(leadingIndex: 0, leading: items[0], trailingIndex: 1, trailing: items[1]))
        XCTAssertEqual(result[1], .single(index: 2, item: items[2]))
    }

    func testWidePage_getsSingleSpread() {
        // portrait, wide, portrait → single, single, single
        let items = makeItems(3)
        let provider = wideAt([1], items: items)
        let result = SpreadManager.buildSpreads(from: items, firstPageIsCover: false, imageSizeProvider: provider)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0], .single(index: 0, item: items[0]))  // portrait before wide → solo
        XCTAssertEqual(result[1], .single(index: 1, item: items[1]))  // wide → solo
        XCTAssertEqual(result[2], .single(index: 2, item: items[2]))  // remaining portrait → solo
    }

    func testAllWide_allSingles() {
        let items = makeItems(3)
        let result = SpreadManager.buildSpreads(from: items, firstPageIsCover: false, imageSizeProvider: allWide)
        XCTAssertEqual(result.count, 3)
        for (i, spread) in result.enumerated() {
            XCTAssertEqual(spread, .single(index: i, item: items[i]))
        }
    }

    func testCoverMode_firstPageSolo() {
        let items = makeItems(4)
        let result = SpreadManager.buildSpreads(from: items, firstPageIsCover: true, imageSizeProvider: allPortrait)
        // Cover(0) + double(1,2) + single(3)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0], .single(index: 0, item: items[0]))
        XCTAssertEqual(result[1], .double(leadingIndex: 1, leading: items[1], trailingIndex: 2, trailing: items[2]))
        XCTAssertEqual(result[2], .single(index: 3, item: items[3]))
    }

    func testCoverMode_fivePortrait() {
        let items = makeItems(5)
        let result = SpreadManager.buildSpreads(from: items, firstPageIsCover: true, imageSizeProvider: allPortrait)
        // Cover(0) + double(1,2) + double(3,4)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0], .single(index: 0, item: items[0]))
        XCTAssertEqual(result[1], .double(leadingIndex: 1, leading: items[1], trailingIndex: 2, trailing: items[2]))
        XCTAssertEqual(result[2], .double(leadingIndex: 3, leading: items[3], trailingIndex: 4, trailing: items[4]))
    }

    func testUnknownSize_treatedAsPortrait() {
        let items = makeItems(2)
        let result = SpreadManager.buildSpreads(from: items, firstPageIsCover: false, imageSizeProvider: allUnknown)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0], .double(leadingIndex: 0, leading: items[0], trailingIndex: 1, trailing: items[1]))
    }

    func testMixedWidePortrait_interleaved() {
        // p, w, p, p, w, p → single(0), single(1), double(2,3), single(4), single(5)
        let items = makeItems(6)
        let provider = wideAt([1, 4], items: items)
        let result = SpreadManager.buildSpreads(from: items, firstPageIsCover: false, imageSizeProvider: provider)
        XCTAssertEqual(result.count, 5)
        XCTAssertEqual(result[0], .single(index: 0, item: items[0]))   // portrait before wide
        XCTAssertEqual(result[1], .single(index: 1, item: items[1]))   // wide
        XCTAssertEqual(result[2], .double(leadingIndex: 2, leading: items[2], trailingIndex: 3, trailing: items[3]))
        XCTAssertEqual(result[3], .single(index: 4, item: items[4]))   // wide
        XCTAssertEqual(result[4], .single(index: 5, item: items[5]))   // remaining solo
    }

    // MARK: - spreadIndex Tests

    func testSpreadIndex_basicMapping() {
        let items = makeItems(4)
        let spreads = SpreadManager.buildSpreads(from: items, firstPageIsCover: false, imageSizeProvider: allPortrait)
        // double(0,1), double(2,3)
        XCTAssertEqual(SpreadManager.spreadIndex(for: 0, in: spreads), 0)
        XCTAssertEqual(SpreadManager.spreadIndex(for: 1, in: spreads), 0)
        XCTAssertEqual(SpreadManager.spreadIndex(for: 2, in: spreads), 1)
        XCTAssertEqual(SpreadManager.spreadIndex(for: 3, in: spreads), 1)
    }

    func testSpreadIndex_notFound_returnsZero() {
        let items = makeItems(2)
        let spreads = SpreadManager.buildSpreads(from: items, firstPageIsCover: false, imageSizeProvider: allPortrait)
        XCTAssertEqual(SpreadManager.spreadIndex(for: 99, in: spreads), 0)
    }

    func testSpreadIndex_withCoverMode() {
        let items = makeItems(5)
        let spreads = SpreadManager.buildSpreads(from: items, firstPageIsCover: true, imageSizeProvider: allPortrait)
        // single(0), double(1,2), double(3,4)
        XCTAssertEqual(SpreadManager.spreadIndex(for: 0, in: spreads), 0)
        XCTAssertEqual(SpreadManager.spreadIndex(for: 1, in: spreads), 1)
        XCTAssertEqual(SpreadManager.spreadIndex(for: 2, in: spreads), 1)
        XCTAssertEqual(SpreadManager.spreadIndex(for: 3, in: spreads), 2)
        XCTAssertEqual(SpreadManager.spreadIndex(for: 4, in: spreads), 2)
    }
}
