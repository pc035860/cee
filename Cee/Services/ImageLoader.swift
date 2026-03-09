import AppKit
import ImageIO
import PDFKit

/// 方向性 prefetch：往翻頁方向多預載
enum PrefetchDirection {
    case none
    case forward
    case backward
}

/// 使用 actor 確保快取的執行緒安全
actor ImageLoader {
    private var cache: [URL: NSImage] = [:]
    /// 縮圖快取：同時存 image 和 fullSize，避免 cache-hit 時二次開檔
    private struct ThumbnailEntry {
        let image: NSImage
        let fullSize: CGSize
    }
    /// Composite key: same URL with different maxSize produces separate cache entries.
    /// Prevents grid (240/480px) and main view (512px) thumbnails from cross-contaminating.
    private struct ThumbnailCacheKey: Hashable {
        let url: URL
        let maxSize: CGFloat
    }
    private var thumbnailCache: [ThumbnailCacheKey: ThumbnailEntry] = [:]
    private let thumbnailThrottle = ThumbnailThrottle()
    private var pdfCache: [PDFCacheKey: NSImage] = [:]
    private var pdfDocumentCache: [URL: PDFDocument] = [:]
    private let cacheRadius = Constants.cacheRadius
    private let prefetchExtra = Constants.prefetchDirectionExtraCount

    // 追蹤預載任務（支援取消）
    private var prefetchTasks: [PDFCacheKey: Task<Void, Never>] = [:]
    private var imagePrefetchTasks: [URL: Task<Void, Never>] = [:]

    /// PDF 頁面快取的 key（固定以 2x Retina 渲染，無需區分 scale）
    private struct PDFCacheKey: Hashable {
        let url: URL
        let pageIndex: Int
    }

    /// 使用 CGImageSourceCreateThumbnailAtIndex 快速載入低解析度縮圖（JPEG ~16ms）
    /// 同時回傳 full-res dimensions（從同一個 CGImageSource 讀取，避免二次開檔）
    /// PDF 不支援，回傳 nil
    /// - Parameter throttlePriority: Smaller = higher urgency. 0 = highest (default, for non-grid callers).
    ///   Grid callers pass `abs(index - visibleCenter)` as distance-based priority.
    func loadThumbnail(at url: URL, maxSize: CGFloat = 512, priority: TaskPriority = .userInitiated, throttlePriority: Int = 0) async -> (image: NSImage, fullSize: CGSize)? {
        let cacheKey = ThumbnailCacheKey(url: url, maxSize: maxSize)
        if let cached = thumbnailCache[cacheKey] {
            return (cached.image, cached.fullSize)
        }

        let result = await thumbnailThrottle.withThrottle(priority: throttlePriority) {
            () async -> (image: NSImage, fullSize: CGSize)? in
            // Skip expensive decode if caller was cancelled while waiting in queue
            guard !Task.isCancelled else { return nil }
            return await Task.detached(priority: priority) {
                Self.decodeThumbnailWithDimensions(at: url, maxSize: maxSize)
            }.value
        }

        // Don't cache if caller's Task was cancelled (e.g. Quick Grid dismissed).
        if let result, !Task.isCancelled {
            thumbnailCache[cacheKey] = ThumbnailEntry(image: result.image, fullSize: result.fullSize)
        }
        return result
    }

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
        let key = PDFCacheKey(url: url, pageIndex: pageIndex)
        if let cached = pdfCache[key] { return cached }

        let image = renderPDFPage(url: url, pageIndex: pageIndex)

        if let image { pdfCache[key] = image }
        return image
    }

    /// 固定使用 2x Retina scale 渲染（幾乎所有 Mac 都是 Retina，非 Retina 顯示 2x 無害）
    private static let renderScale: CGFloat = 2.0

    private func renderPDFPage(url: URL, pageIndex: Int) -> NSImage? {
        let backingScale = Self.renderScale
        // 早期取消檢查
        guard !Task.isCancelled else { return nil }

        // 1. 取得或建立 PDFDocument
        let doc: PDFDocument
        if let cached = pdfDocumentCache[url] {
            doc = cached
        } else {
            guard let newDoc = PDFDocument(url: url) else { return nil }
            pdfDocumentCache[url] = newDoc
            doc = newDoc
        }

        // 載入文件後檢查
        guard !Task.isCancelled else { return nil }

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

        // 像素上限保護：超過 1 億像素（≈400MB RGBA）時跳過，防止極大頁面 OOM
        let totalPixels = pixelSize.width * pixelSize.height
        guard totalPixels > 0, totalPixels <= 100_000_000 else { return nil }

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

    // MARK: - Image Loading

    /// PDF URL 判定（共用，避免散佈 pathExtension 比較）
    private static func isPDFURL(_ url: URL) -> Bool {
        url.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame
    }

    /// 僅讀 metadata 取得尺寸（不解碼，portrait fit-to-width 時避免 thumbnail→fullRes 跳動）
    private static func readImageDimensions(at url: URL) -> CGSize? {
        guard !isPDFURL(url) else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary? else { return nil }
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    /// 讀取圖片尺寸（不解碼完整圖片）用於 continuous scroll 模式
    /// - Parameter url: 圖片 URL
    /// - Returns: 圖片尺寸，已處理 EXIF orientation 5-8 的交換
    func getImageSize(for url: URL) async -> NSSize? {
        // PDF: 返回 nil（由其他邏輯處理）
        guard !Self.isPDFURL(url) else { return nil }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return nil
        }

        let w = (props[kCGImagePropertyPixelWidth as String] as? CGFloat) ?? 0
        let h = (props[kCGImagePropertyPixelHeight as String] as? CGFloat) ?? 0
        guard w > 0, h > 0 else { return nil }

        // 處理 EXIF orientation 5-8（90/270 度旋轉)
        // 這些 orientation 的 pixel dimensions 需要交換
        let orientation = (props[kCGImagePropertyOrientation as String] as? Int) ?? 1
        if orientation >= 5 && orientation <= 8 {
            return NSSize(width: h, height: w)
        }
        return NSSize(width: w, height: h)
    }

    /// 使用 CGImageSourceCreateThumbnailAtIndex 快速解碼縮圖，同時讀取 full-res 尺寸
    /// 共用同一個 CGImageSource，避免二次開檔
    private static func decodeThumbnailWithDimensions(at url: URL, maxSize: CGFloat) -> (image: NSImage, fullSize: CGSize)? {
        guard !isPDFURL(url) else { return nil }
        let decodeStart = CFAbsoluteTimeGetCurrent()

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let sourceMs = (CFAbsoluteTimeGetCurrent() - decodeStart) * 1000

        // 讀 full-res dimensions（同一個 source，零額外 I/O）
        let fullSize: CGSize
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?,
           let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
           w > 0, h > 0 {
            fullSize = CGSize(width: w, height: h)
        } else {
            fullSize = .zero  // fallback: caller 會用 thumbnail size
        }

        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSize,
        ]
        // Phase 3.1: SubsampleFactor for JPEG/HEIF DCT fast path at micro-thumbnail sizes
        let subsample: Int
        if maxSize <= Constants.quickGridSubsampleThresholdPx {
            subsample = 4
            options[kCGImageSourceSubsampleFactor] = subsample
        } else {
            subsample = 1
        }
        let thumbStart = CFAbsoluteTimeGetCurrent()
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let thumbMs = (CFAbsoluteTimeGetCurrent() - thumbStart) * 1000

        let image = NSImage(cgImage: cgImage, size: NSSize(
            width: cgImage.width,
            height: cgImage.height
        ))
        let totalMs = (CFAbsoluteTimeGetCurrent() - decodeStart) * 1000
        GridPerfLog.log(String(format: "decode: total=%.2fms | source=%.2fms | thumb(%dx%d→%.0f,ss=%d)=%.2fms | %@",
                               totalMs, sourceMs, cgImage.width, cgImage.height, maxSize, subsample, thumbMs,
                               url.lastPathComponent))

        let effectiveSize = fullSize == .zero ? image.size : fullSize
        return (image, effectiveSize)
    }

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

    /// 預載用的圖片載入（支援 cooperative cancellation）
    private func loadImageCooperative(at url: URL) async -> NSImage? {
        if let cached = cache[url] { return cached }
        guard !Task.isCancelled else { return nil }

        // 使用 Task 而非 Task.detached 以繼承 cancellation scope
        let image = await Task(priority: .userInitiated) { () -> NSImage? in
            guard !Task.isCancelled else { return nil }
            return Self.decodeImage(at: url)
        }.value

        guard !Task.isCancelled else { return nil }
        if let image { cache[url] = image }
        return image
    }

    /// 取消指定 item 的預載任務
    func cancelLoad(for item: ImageItem) {
        if let pageIndex = item.pdfPageIndex {
            let key = PDFCacheKey(url: item.url, pageIndex: pageIndex)
            prefetchTasks[key]?.cancel()
            prefetchTasks.removeValue(forKey: key)
        } else {
            imagePrefetchTasks[item.url]?.cancel()
            imagePrefetchTasks.removeValue(forKey: item.url)
        }
    }

    /// 預載周圍項目（圖片或 PDF 頁面），釋放遠離的快取
    /// 方向性 prefetch：往 direction 方向多預載 prefetchExtra 張
    /// ⚠️ 接收值型別參數（ImageItem 是 Sendable struct）避免 Swift 6 Sendable 問題
    func updateCache(currentIndex: Int, items: [ImageItem], prefetchDirection: PrefetchDirection = .none) {
        guard !items.isEmpty else { return }

        let range: ClosedRange<Int>
        switch prefetchDirection {
        case .forward:
            range = max(0, currentIndex - cacheRadius)...min(items.count - 1, currentIndex + cacheRadius + prefetchExtra)
        case .backward:
            range = max(0, currentIndex - cacheRadius - prefetchExtra)...min(items.count - 1, currentIndex + cacheRadius)
        case .none:
            range = max(0, currentIndex - cacheRadius)...min(items.count - 1, currentIndex + cacheRadius)
        }

        // 計算需要的 keys
        let activeImageURLs = Set(items[range].filter { !$0.isPDF }.map(\.url))
        let activePDFKeys = Set(items[range].compactMap { item in
            item.pdfPageIndex.map { PDFCacheKey(url: item.url, pageIndex: $0) }
        })
        let activePDFURLs = Set(items[range].filter { $0.isPDF }.map(\.url))

        // 取消不在範圍內的預載任務
        for (url, task) in imagePrefetchTasks where !activeImageURLs.contains(url) {
            task.cancel()
            imagePrefetchTasks.removeValue(forKey: url)
        }
        for (key, task) in prefetchTasks where !activePDFKeys.contains(key) {
            task.cancel()
            prefetchTasks.removeValue(forKey: key)
        }

        // 釋放超出範圍的快取
        cache = cache.filter { activeImageURLs.contains($0.key) }
        displayCache = displayCache.filter { activeImageURLs.contains($0.key) }
        thumbnailCache = thumbnailCache.filter { activeImageURLs.contains($0.key.url) }
        pdfCache = pdfCache.filter { activePDFKeys.contains($0.key) }
        pdfDocumentCache = pdfDocumentCache.filter { activePDFURLs.contains($0.key) }

        // 啟動新的預載任務（可追蹤、可取消）
        for i in range {
            let item = items[i]
            if let pageIndex = item.pdfPageIndex {
                let key = PDFCacheKey(url: item.url, pageIndex: pageIndex)
                if pdfCache[key] == nil && prefetchTasks[key] == nil {
                    prefetchTasks[key] = Task {
                        defer { prefetchTasks.removeValue(forKey: key) }
                        guard !Task.isCancelled else { return }
                        _ = await loadPDFPage(url: item.url, pageIndex: pageIndex)
                    }
                }
            } else {
                if cache[item.url] == nil && imagePrefetchTasks[item.url] == nil {
                    imagePrefetchTasks[item.url] = Task {
                        defer { imagePrefetchTasks.removeValue(forKey: item.url) }
                        guard !Task.isCancelled else { return }
                        _ = await loadImageCooperative(at: item.url)
                    }
                }
            }
        }
    }

    /// 清空縮圖快取（Quick Grid dismiss 後呼叫，避免 240px 小圖殘留污染主畫面 fallback）
    func clearThumbnailCache() {
        thumbnailCache.removeAll()
    }

    /// 取消所有預載任務並清空縮圖快取
    func cancelAllPrefetchTasks() {
        for (_, task) in prefetchTasks { task.cancel() }
        for (_, task) in imagePrefetchTasks { task.cancel() }
        prefetchTasks.removeAll()
        imagePrefetchTasks.removeAll()
        thumbnailCache.removeAll()
    }

    /// 清空主圖片快取、PDF 快取、顯示快取及取消所有預載任務（記憶體壓力時呼叫）
    func clearImageCache() {
        cache.removeAll()
        displayCache.removeAll()
        pdfCache.removeAll()
        pdfDocumentCache.removeAll()
        for (_, task) in prefetchTasks { task.cancel() }
        prefetchTasks.removeAll()
        for (_, task) in imagePrefetchTasks { task.cancel() }
        imagePrefetchTasks.removeAll()
    }

    // MARK: - Display Cache (Continuous Scroll Subsample)

    private var displayCache: [URL: NSImage] = [:]

    /// Load image subsampled for display at given pixel width (continuous scroll mode)
    /// - Parameter maxWidth: Target display width in pixels (include Retina scale factor)
    func loadImageForDisplay(at url: URL, maxWidth: CGFloat) async -> NSImage? {
        if let cached = displayCache[url] { return cached }

        let image = await Task.detached(priority: .userInitiated) {
            Self.decodeImageForDisplay(at: url, maxWidth: maxWidth)
        }.value

        if let image { displayCache[url] = image }
        return image
    }

    /// Decode with subsample for large images, full decode for small ones
    private static func decodeImageForDisplay(at url: URL, maxWidth: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return decodeImage(at: url)
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
            return decodeImage(at: url)
        }

        // EXIF orientation 5-8: swap w/h (sensor dimensions don't match display orientation)
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let sourceWidth = (orientation >= 5 && orientation <= 8) ? pixelHeight : pixelWidth

        // Calculate subsample factor: maxWidth is already in display pixels
        let ratio = sourceWidth / maxWidth
        let subsampleFactor: Int
        if ratio >= 4.0 {
            subsampleFactor = 4
        } else if ratio >= 2.0 {
            subsampleFactor = 2
        } else {
            // No subsample needed — full decode
            return decodeImage(at: url)
        }

        // Use thumbnail API with subsample for JPEG/HEIF DCT fast path
        // CGImageSource scales proportionally from maxWidth
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxWidth,
            kCGImageSourceSubsampleFactor: subsampleFactor,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return decodeImage(at: url)
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    // MARK: - Test-Only Accessors

    func _testImageCacheCount() -> Int { cache.count }
    func _testDisplayCacheCount() -> Int { displayCache.count }
}
