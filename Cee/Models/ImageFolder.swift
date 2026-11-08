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
        self.images = Self.scanDirectory(folderURL)

        // 找到對應的 ImageItem (use .path — URL == can fail between constructed URLs and contentsOfDirectory)
        let filePath = fileURL.resolvingSymlinksInPath().path
        if let firstIndex = images.firstIndex(where: { $0.url.resolvingSymlinksInPath().path == filePath }) {
            let firstItem = images[firstIndex]

            if firstItem.isPDF {
                // PDF 檔案：計算總頁數並恢復上次頁碼
                let totalPages = images.filter { $0.url.resolvingSymlinksInPath().path == filePath }.count
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
    /// If the folder contains no images, joins the images of all nested subfolders into one flat list
    /// (depth-first, subfolders in natural order). `folderURL` stays the given root.
    init(folderURL: URL) {
        self.folderURL = folderURL
        var items = Self.scanDirectory(folderURL)
        if items.isEmpty {
            items = Self.scanNestedSubfolders(of: folderURL)
        }
        self.images = items
        self.currentIndex = 0
    }

    /// Path of an item relative to `folderURL`, falling back to the file name outside the root.
    func relativePath(of item: ImageItem) -> String {
        let rootPath = folderURL.resolvingSymlinksInPath().path
        let itemPath = item.url.resolvingSymlinksInPath().path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard itemPath.hasPrefix(prefix) else { return item.url.lastPathComponent }
        return String(itemPath.dropFirst(prefix.count))
    }

    private static func scanDirectory(_ url: URL) -> [ImageItem] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.contentTypeKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        // Single pass: filter supported files and capture their UTType
        let supported: [(url: URL, type: UTType)] = contents.compactMap { url in
            guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
                  Self.supportedTypes.contains(where: { type.conforms(to: $0) })
            else { return nil }
            return (url, type)
        }
        .sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }

        // Expand PDFs into per-page items
        return supported.flatMap { (url, type) -> [ImageItem] in
            if type.conforms(to: .pdf) {
                let count = Self.pdfPageCount(for: url)
                guard count > 0 else { return [] }
                return (0..<count).map { ImageItem(url: url, pdfPageIndex: $0) }
            } else {
                return [ImageItem(url: url)]
            }
        }
    }

    // MARK: - Nested Subfolder Join

    /// Depth-first join: each subfolder's own images first, then its subfolders, all in natural order.
    /// Symlinked directories and packages are not followed.
    private static func scanNestedSubfolders(of rootURL: URL) -> [ImageItem] {
        subdirectories(of: rootURL).flatMap { dir in
            scanDirectory(dir) + scanNestedSubfolders(of: dir)
        }
    }

    private static func subdirectories(of url: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return contents
            .filter { child in
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else { return false }
                return values.isDirectory == true && values.isPackage != true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
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
    func goNext(amount: Int = 1) -> Bool {
        guard amount > 0 else { return false }
        let nextIndex = min(currentIndex + amount, images.count - 1)
        guard nextIndex != currentIndex else { return false }
        currentIndex = nextIndex
        if !spreads.isEmpty { syncSpreadIndex() }
        return true
    }

    @discardableResult
    func goPrevious(amount: Int = 1) -> Bool {
        guard amount > 0 else { return false }
        let prevIndex = max(currentIndex - amount, 0)
        guard prevIndex != currentIndex else { return false }
        currentIndex = prevIndex
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
