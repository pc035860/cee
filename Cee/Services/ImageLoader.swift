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
        // 1. 取得或建立 PDFDocument
        let doc: PDFDocument
        if let cached = pdfDocumentCache[url] {
            doc = cached
        } else {
            guard let newDoc = PDFDocument(url: url) else { return nil }
            pdfDocumentCache[url] = newDoc
            doc = newDoc
        }
        guard let page = doc.page(at: pageIndex) else { return nil }

        // 2. 取得頁面尺寸（考慮旋轉後的實際顯示尺寸）
        let pageBounds = page.bounds(for: .cropBox)
        let rotation = page.rotation

        // 計算旋轉後的實際顯示尺寸（points）
        let pointSize: CGSize
        if rotation == 90 || rotation == 270 {
            // 旋轉 90 或 270 度時，寬高互換
            pointSize = CGSize(width: pageBounds.height, height: pageBounds.width)
        } else {
            pointSize = pageBounds.size
        }

        // 3. 建立 NSBitmapImageRep 以支援 Retina 縮放
        let pixelSize = CGSize(
            width: pointSize.width * backingScale,
            height: pointSize.height * backingScale
        )
        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelSize.width),
            pixelsHigh: Int(pixelSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,  // 讓 CG 自動對齊
            bitsPerPixel: 0
        ) else { return nil }

        // 4. 建立 NSImage 並加入 bitmap representation
        let image = NSImage(size: pointSize)
        image.addRepresentation(bitmapRep)

        // 5. 使用 NSGraphicsContext 繪製
        guard let ctx = NSGraphicsContext(bitmapImageRep: bitmapRep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx

        let cgCtx = ctx.cgContext

        // 6. 套用 scale 變換以配合 pixel 尺寸
        cgCtx.scaleBy(x: backingScale, y: backingScale)

        // 7. 填白色背景
        cgCtx.setFillColor(CGColor.white)
        cgCtx.fill(CGRect(origin: .zero, size: pointSize))

        // 8. 處理旋轉變換
        if rotation != 0 {
            cgCtx.saveGState()

            // 平移到中心點
            cgCtx.translateBy(x: pointSize.width / 2, y: pointSize.height / 2)
            // 旋轉（rotation 是度數，需轉弧度；負號因為 CG 座標系 Y 軸向上）
            cgCtx.rotate(by: -CGFloat(rotation) * .pi / 180)
            // 平移回去（基於原始 pageBounds）
            cgCtx.translateBy(x: -pageBounds.width / 2, y: -pageBounds.height / 2)
        }

        // 9. 繪製 PDF 頁面
        page.draw(with: .cropBox, to: cgCtx)

        if rotation != 0 {
            cgCtx.restoreGState()
        }

        NSGraphicsContext.restoreGraphicsState()
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
