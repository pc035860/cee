import Foundation

struct ImageItem: Equatable {
    let url: URL
    var fileName: String { url.lastPathComponent }
}

// MARK: - Safe Array Subscript

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
