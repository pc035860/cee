import Foundation
import CoreGraphics

/// Builds page spreads for dual-page viewing.
/// Pure static methods — no state, no UI dependencies.
struct SpreadManager: Sendable {

    /// Build spreads from an array of ImageItems.
    /// - Parameters:
    ///   - items: All images in the folder.
    ///   - firstPageIsCover: If true, first page is displayed solo (cover mode).
    ///   - imageSizeProvider: Returns the pixel size for an index (for wide-page detection).
    ///                        Returns nil if size is unknown yet (treated as portrait).
    static func buildSpreads(
        from items: [ImageItem],
        firstPageIsCover: Bool,
        imageSizeProvider: (Int) -> CGSize?
    ) -> [PageSpread] {
        guard !items.isEmpty else { return [] }
        var spreads: [PageSpread] = []
        var i = 0

        // Cover mode: first page always solo
        if firstPageIsCover {
            spreads.append(.single(index: 0, item: items[0]))
            i = 1
        }

        while i < items.count {
            let item = items[i]
            let isWide = Self.isWidePage(at: i, sizeProvider: imageSizeProvider)

            if isWide {
                // Wide page gets its own spread
                spreads.append(.single(index: i, item: item))
                i += 1
            } else if i + 1 < items.count {
                let nextIsWide = Self.isWidePage(at: i + 1, sizeProvider: imageSizeProvider)

                if nextIsWide {
                    // Current portrait, next wide → current becomes single
                    spreads.append(.single(index: i, item: item))
                    i += 1
                } else {
                    // Both portrait → pair them
                    spreads.append(.double(
                        leadingIndex: i, leading: item,
                        trailingIndex: i + 1, trailing: items[i + 1]
                    ))
                    i += 2
                }
            } else {
                // Last page, solo
                spreads.append(.single(index: i, item: item))
                i += 1
            }
        }
        return spreads
    }

    /// Find the spread index that contains a given page index.
    /// Returns 0 if not found.
    static func spreadIndex(for pageIndex: Int, in spreads: [PageSpread]) -> Int {
        spreads.firstIndex { $0.containsPage(pageIndex) } ?? 0
    }

    // MARK: - Private

    private static func isWidePage(
        at index: Int,
        sizeProvider: (Int) -> CGSize?
    ) -> Bool {
        guard let size = sizeProvider(index) else { return false }
        return size.width > size.height
    }
}
