import Foundation
import CoreGraphics
import CoreServices
import UniformTypeIdentifiers

class ImageFolder {
    let folderURL: URL
    private(set) var images: [ImageItem] = []
    var currentIndex: Int = 0

    static let supportedTypes: Set<UTType> = [
        .jpeg, .png, .tiff, .heic, .heif, .gif, .webP, .bmp, .pdf
    ]

    init(containing fileURL: URL) {
        self.folderURL = fileURL.deletingLastPathComponent()
        self.images = scanFolder()
        self.currentIndex = images.firstIndex { $0.url == fileURL } ?? 0
    }

    private func scanFolder() -> [ImageItem] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.contentTypeKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        // Sort files first, then expand PDFs — ensures pages stay grouped after their source file
        let sortedURLs = contents
            .filter { url in
                guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
                else { return false }
                return Self.supportedTypes.contains(where: { type.conforms(to: $0) })
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        return sortedURLs.flatMap { url -> [ImageItem] in
            guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
            else { return [] }

            if type.conforms(to: .pdf) {
                let count = Self.pdfPageCount(for: url)
                guard count > 0 else { return [] }
                return (0..<count).map { ImageItem(url: url, pdfPageIndex: $0) }
            } else {
                return [ImageItem(url: url)]
            }
        }
    }

    /// 輕量取 PDF 頁數：Spotlight 元資料 → CGPDFDocument → 0
    private static func pdfPageCount(for url: URL) -> Int {
        if let mdItem = MDItemCreateWithURL(nil, url as CFURL),
           let pages = MDItemCopyAttribute(mdItem, kMDItemNumberOfPages) as? Int,
           pages > 0 {
            return pages
        }
        if let cgDoc = CGPDFDocument(url as CFURL) {
            return cgDoc.numberOfPages
        }
        return 0
    }

    var currentImage: ImageItem? { images[safe: currentIndex] }
    var hasNext: Bool { currentIndex < images.count - 1 }
    var hasPrevious: Bool { currentIndex > 0 }

    @discardableResult
    func goNext() -> Bool {
        guard hasNext else { return false }
        currentIndex += 1
        return true
    }

    @discardableResult
    func goPrevious() -> Bool {
        guard hasPrevious else { return false }
        currentIndex -= 1
        return true
    }
}
