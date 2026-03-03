import Foundation
import CoreGraphics
import CoreServices
import UniformTypeIdentifiers

class ImageFolder {
    private(set) var folderURL: URL
    private(set) var images: [ImageItem] = []
    var currentIndex: Int = 0

    static let supportedTypes: Set<UTType> = [
        .jpeg, .png, .tiff, .heic, .heif, .gif, .webP, .bmp, .pdf
    ]

    /// Check if a file URL is a supported image or PDF type
    static func isSupported(url: URL) -> Bool {
        guard let uttype = UTType(filenameExtension: url.pathExtension) else { return false }
        return supportedTypes.contains { uttype.conforms(to: $0) }
    }

    init(containing fileURL: URL) {
        self.folderURL = fileURL.deletingLastPathComponent()
        self.images = scanFolder()

        // 找到對應的 ImageItem
        if let firstIndex = images.firstIndex(where: { $0.url == fileURL }) {
            let firstItem = images[firstIndex]

            if firstItem.isPDF {
                // PDF 檔案：計算總頁數並恢復上次頁碼
                let totalPages = images.filter { $0.url == fileURL }.count
                let savedPage = Self.getLastViewedPage(for: fileURL, totalPages: totalPages)
                self.currentIndex = firstIndex + savedPage
            } else {
                // 一般圖片
                self.currentIndex = firstIndex
            }
        } else {
            self.currentIndex = 0
        }
    }

    /// Initialize from a folder URL directly (for drag-drop folder support).
    /// Scans the folder and starts at the first image.
    /// If the folder contains no images, searches up to 2 levels of subdirectories
    /// for the first subfolder that does contain images.
    init(folderURL: URL) {
        self.folderURL = folderURL
        self.images = scanFolder()

        // Top-level empty: search subdirectories for the first folder with images
        if images.isEmpty {
            if let found = Self.findFirstSubfolderWithImages(in: folderURL, maxDepth: 2) {
                self.folderURL = found
                self.images = scanFolder()
            }
        }

        self.currentIndex = 0
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

    // MARK: - Subfolder Discovery

    /// BFS search for the first subdirectory that contains supported images.
    /// - Parameters:
    ///   - rootURL: The folder to start searching from (its direct children are depth 1).
    ///   - maxDepth: Maximum depth to search (e.g. 2 means grandchildren at most).
    /// - Returns: The URL of the first subfolder containing images, or nil.
    static func findFirstSubfolderWithImages(in rootURL: URL, maxDepth: Int) -> URL? {
        let fm = FileManager.default
        var queue: [(url: URL, depth: Int)] = []

        // Seed queue with immediate subdirectories (depth 1)
        if let children = sortedSubdirectories(of: rootURL, using: fm) {
            for child in children {
                queue.append((child, 1))
            }
        }

        while !queue.isEmpty {
            let (currentURL, depth) = queue.removeFirst()

            if folderContainsSupportedImages(currentURL, using: fm) {
                return currentURL
            }

            // Enqueue deeper subdirectories if within depth limit
            if depth < maxDepth, let children = sortedSubdirectories(of: currentURL, using: fm) {
                for child in children {
                    queue.append((child, depth + 1))
                }
            }
        }

        return nil
    }

    /// Returns sorted subdirectories of a folder, skipping hidden files and packages.
    private static func sortedSubdirectories(of url: URL, using fm: FileManager) -> [URL]? {
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: .skipsHiddenFiles
        ) else { return nil }

        let dirs = contents.filter { child in
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
                  values.isDirectory == true,
                  values.isPackage != true
            else { return false }
            return true
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        return dirs.isEmpty ? nil : dirs
    }

    /// Quick check whether a folder contains at least one supported image file.
    private static func folderContainsSupportedImages(_ folderURL: URL, using fm: FileManager) -> Bool {
        guard let contents = try? fm.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.contentTypeKey],
            options: .skipsHiddenFiles
        ) else { return false }

        return contents.contains { url in
            guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
            else { return false }
            return supportedTypes.contains(where: { type.conforms(to: $0) })
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

    /// 從 UserDefaults 讀取上次閱讀的 PDF 頁碼
    private static func getLastViewedPage(for pdfURL: URL, totalPages: Int) -> Int {
        let key = "pdf.lastPage.\(pdfURL.path)"
        guard let savedPage = UserDefaults.standard.object(forKey: key) as? Int else {
            return 0  // 預設第一頁
        }
        // 確保頁碼在有效範圍內（0 ~ totalPages-1）
        return max(0, min(savedPage, totalPages - 1))
    }

    var currentImage: ImageItem? { images[safe: currentIndex] }
    var hasNext: Bool { currentIndex < images.count - 1 }
    var hasPrevious: Bool { currentIndex > 0 }

    @discardableResult
    func goNext() -> Bool {
        guard hasNext else { return false }
        currentIndex += 1
        if !spreads.isEmpty { syncSpreadIndex() }
        return true
    }

    @discardableResult
    func goPrevious() -> Bool {
        guard hasPrevious else { return false }
        currentIndex -= 1
        if !spreads.isEmpty { syncSpreadIndex() }
        return true
    }

    // MARK: - Spread Navigation

    /// Cached spread list, rebuilt when dual mode or offset changes.
    private(set) var spreads: [PageSpread] = []
    private(set) var currentSpreadIndex: Int = 0

    /// Rebuild spreads with current settings.
    /// Call when: dual mode toggled, offset toggled, folder loaded, image sizes become known.
    func rebuildSpreads(firstPageIsCover: Bool, imageSizeProvider: (Int) -> CGSize?) {
        spreads = SpreadManager.buildSpreads(
            from: images,
            firstPageIsCover: firstPageIsCover,
            imageSizeProvider: imageSizeProvider
        )
        currentSpreadIndex = SpreadManager.spreadIndex(for: currentIndex, in: spreads)
    }

    var currentSpread: PageSpread? { spreads[safe: currentSpreadIndex] }
    var hasNextSpread: Bool { currentSpreadIndex < spreads.count - 1 }
    var hasPreviousSpread: Bool { currentSpreadIndex > 0 }

    @discardableResult
    func goNextSpread() -> Bool {
        guard hasNextSpread else { return false }
        currentSpreadIndex += 1
        if let spread = currentSpread {
            currentIndex = spread.leadingIndex
        }
        return true
    }

    @discardableResult
    func goPreviousSpread() -> Bool {
        guard hasPreviousSpread else { return false }
        currentSpreadIndex -= 1
        if let spread = currentSpread {
            currentIndex = spread.leadingIndex
        }
        return true
    }

    func goToFirstSpread() {
        currentSpreadIndex = 0
        if let spread = currentSpread {
            currentIndex = spread.leadingIndex
        }
    }

    func goToLastSpread() {
        currentSpreadIndex = max(0, spreads.count - 1)
        if let spread = currentSpread {
            currentIndex = spread.leadingIndex
        }
    }

    /// Sync spread index after single-page navigation (goNext/goPrevious).
    func syncSpreadIndex() {
        currentSpreadIndex = SpreadManager.spreadIndex(for: currentIndex, in: spreads)
    }
}
