import Foundation

/// A spread represents one or two pages displayed together in dual-page mode.
enum PageSpread: Sendable, Equatable {
    case single(index: Int, item: ImageItem)
    case double(leadingIndex: Int, leading: ImageItem, trailingIndex: Int, trailing: ImageItem)

    /// The index of the leading (first) page in the original images array.
    var leadingIndex: Int {
        switch self {
        case .single(let index, _): return index
        case .double(let index, _, _, _): return index
        }
    }

    /// The leading item — used as the primary reference for this spread.
    var leadingItem: ImageItem {
        switch self {
        case .single(_, let item): return item
        case .double(_, let leading, _, _): return leading
        }
    }

    /// All items in display order (leading first).
    var items: [ImageItem] {
        switch self {
        case .single(_, let item): return [item]
        case .double(_, let leading, _, let trailing): return [leading, trailing]
        }
    }

    /// All page indices in the original images array.
    var indices: [Int] {
        switch self {
        case .single(let index, _): return [index]
        case .double(let li, _, let ti, _): return [li, ti]
        }
    }
}
