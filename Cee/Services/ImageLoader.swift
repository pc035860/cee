import AppKit
import ImageIO
import PDFKit

/// 使用 actor 確保快取的執行緒安全
actor ImageLoader {
    private var cache: [URL: NSImage] = [:]
    private var pdfCache: [String: NSImage] = [:]
    private var pdfDocumentCache: [URL: PDFDocument] = [:]
    private let cacheRadius = Constants.cacheRadius

    func loadImage(at url: URL) async -> NSImage? {
        if let cached = cache[url] { return cached }

        // 在背景 Task 解碼，避免阻塞 MainActor
        let image = await Task.detached(priority: .userInitiated) {
            Self.decodeImage(at: url)
        }.value

        if let image { cache[url] = image }
        return image
    }

    // MARK: - PDF Loading

    func loadPDFPage(url: URL, pageIndex: Int, backingScale: CGFloat = 2.0) async -> NSImage? {
        let key = pdfCacheKey(url: url, pageIndex: pageIndex, scale: backingScale)
        if let cached = pdfCache[key] { return cached }

        let image = renderPDFPage(url: url, pageIndex: pageIndex, backingScale: backingScale)

        if let image { pdfCache[key] = image }
        return image
    }

    private func renderPDFPage(url: URL, pageIndex: Int, backingScale: CGFloat) -> NSImage? {
        let doc: PDFDocument
        if let cached = pdfDocumentCache[url] {
            doc = cached
        } else {
            guard let newDoc = PDFDocument(url: url) else { return nil }
            pdfDocumentCache[url] = newDoc
            doc = newDoc
        }
        guard let page = doc.page(at: pageIndex) else { return nil }
        let pointSize = page.bounds(for: .cropBox).size
        let scale = backingScale
        let pixelSize = CGSize(width: pointSize.width * scale, height: pointSize.height * scale)
        let image = page.thumbnail(of: pixelSize, for: .cropBox)
        image.size = pointSize  // 以 points 顯示，保留高解析度 representation
        return image
    }

    private func pdfCacheKey(url: URL, pageIndex: Int, scale: CGFloat = 2.0) -> String {
        "\(url.path)#\(pageIndex)@\(Int(scale))x"
    }

    // MARK: - Image Loading

    /// 使用 ImageIO 高效解碼（比 NSImage(contentsOf:) 更高效）
    private static func decodeImage(at url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldAllowFloat: true
        ]
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(
            width: cgImage.width,
            height: cgImage.height
        ))
    }

    /// 預載周圍項目（圖片或 PDF 頁面），釋放遠離的快取
    /// ⚠️ 接收值型別參數（ImageItem 是 Sendable struct）避免 Swift 6 Sendable 問題
    func updateCache(currentIndex: Int, items: [ImageItem]) {
        guard !items.isEmpty else { return }
        let range = max(0, currentIndex - cacheRadius)...min(items.count - 1, currentIndex + cacheRadius)

        // 釋放超出範圍的圖片快取
        let activeImageURLs = Set(items[range].filter { !$0.isPDF }.map(\.url))
        cache = cache.filter { activeImageURLs.contains($0.key) }

        // 釋放超出範圍的 PDF 快取（prefix match 忽略 scale 後綴）
        let activePDFPrefixes = Set(items[range].compactMap { item -> String? in
            guard let pageIndex = item.pdfPageIndex else { return nil }
            return "\(item.url.path)#\(pageIndex)@"
        })
        pdfCache = pdfCache.filter { entry in
            activePDFPrefixes.contains { entry.key.hasPrefix($0) }
        }

        // 釋放視窗外的 PDFDocument 實例
        let activePDFURLs = Set(items[range].filter { $0.isPDF }.map(\.url))
        pdfDocumentCache = pdfDocumentCache.filter { activePDFURLs.contains($0.key) }

        // 預載範圍內項目
        for i in range {
            let item = items[i]
            if let pageIndex = item.pdfPageIndex {
                let key = pdfCacheKey(url: item.url, pageIndex: pageIndex)
                if pdfCache[key] == nil {
                    Task { _ = await loadPDFPage(url: item.url, pageIndex: pageIndex) }
                }
            } else {
                if cache[item.url] == nil {
                    Task { _ = await loadImage(at: item.url) }
                }
            }
        }
    }
}
