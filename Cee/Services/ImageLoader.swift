import AppKit
import ImageIO

/// 使用 actor 確保快取的執行緒安全
actor ImageLoader {
    private var cache: [URL: NSImage] = [:]
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

    /// 預載周圍圖片，釋放遠離的快取
    /// ⚠️ 接收值型別參數（非 ImageFolder class）避免 Swift 6 Sendable 問題
    func updateCache(currentIndex: Int, imageURLs: [URL]) {
        guard !imageURLs.isEmpty else { return }
        let range = max(0, currentIndex - cacheRadius)...min(imageURLs.count - 1, currentIndex + cacheRadius)

        // 釋放超出範圍的快取
        let activeURLs = Set(range.map { imageURLs[$0] })
        cache = cache.filter { activeURLs.contains($0.key) }

        // 預載範圍內圖片
        for i in range {
            let url = imageURLs[i]
            if cache[url] == nil {
                Task { _ = await loadImage(at: url) }
            }
        }
    }
}
