import Foundation

struct ImageItem: Equatable, Sendable {
    let url: URL
    let pdfPageIndex: Int?  // nil for regular images, 0-based for PDF pages

    init(url: URL, pdfPageIndex: Int? = nil) {
        self.url = url
        self.pdfPageIndex = pdfPageIndex
    }

    var isPDF: Bool { pdfPageIndex != nil }

    var fileName: String {
        guard let page = pdfPageIndex else { return url.lastPathComponent }
        return "\(url.lastPathComponent) — Page \(page + 1)"
    }
}

// MARK: - Safe Array Subscript

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
