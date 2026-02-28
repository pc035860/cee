import AppKit
import ImageIO
import PDFKit

/// 使用 actor 確保快取的執行緒安全
actor ImageLoader {
    private var cache: [URL: NSImage] = [:]
    private var pdfCache: [String: NSImage] = [:]
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

    func loadPDFPage(url: URL, pageIndex: Int) async -> NSImage? {
        let key = pdfCacheKey(url: url, pageIndex: pageIndex)
        if let cached = pdfCache[key] { return cached }

        // TODO: Phase 2 — cache PDFDocument instances per-URL to avoid
        // repeated ~19MB allocation per page render
        let image = await Task.detached(priority: .userInitiated) {
            Self.renderPDFPage(url: url, pageIndex: pageIndex)
        }.value

        if let image { pdfCache[key] = image }
        return image
    }

    private static func renderPDFPage(url: URL, pageIndex: Int) -> NSImage? {
        guard let doc = PDFDocument(url: url),
              let page = doc.page(at: pageIndex) else { return nil }
        let size = page.bounds(for: .cropBox).size
        // TODO: Phase 2 — multiply by backingScaleFactor for Retina-quality rendering
        return page.thumbnail(of: size, for: .cropBox)
    }

    private func pdfCacheKey(url: URL, pageIndex: Int) -> String {
        "\(url.path)#\(pageIndex)"
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

        // 釋放超出範圍的 PDF 快取
        let activePDFKeys = Set(items[range].compactMap { item -> String? in
            guard let pageIndex = item.pdfPageIndex else { return nil }
            return pdfCacheKey(url: item.url, pageIndex: pageIndex)
        })
        pdfCache = pdfCache.filter { activePDFKeys.contains($0.key) }

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
