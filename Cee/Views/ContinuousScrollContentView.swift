import AppKit

/// 連續捲動內容視圖（Webtoon-style vertical scrolling）
/// 使用標準 macOS 座標系統（y=0 在底部）以配合 ImageScrollView
class ContinuousScrollContentView: NSView {

    // MARK: - Properties

    private var folder: ImageFolder?
    private weak var imageLoader: ImageLoader?

    /// 預載的圖片尺寸
    private(set) var imageSizes: [NSSize] = []

    /// 縮放後的高度（cache 避免重複計算）
    internal var scaledHeights: [CGFloat] = []

    /// 每張圖片的 Y 座標起始點（從底部開始累積）
    private var yOffsets: [CGFloat] = []

    /// 容器寬度（用於 fit-to-width 計算）
    var containerWidth: CGFloat = 800 {
        didSet {
            guard oldValue != containerWidth else { return }
            recalculateLayout()
        }
    }

    /// 圖片間距
    private let imageSpacing: CGFloat = 0

    /// 預設圖片高度（無法取得尺寸時使用）
    private let defaultAspectRatio: CGFloat = 4.0 / 3.0

    // MARK: - Index Tracking

    /// 當前圖片變更回調：(index, scaledImageSize)
    var onCurrentImageChanged: ((Int, NSSize) -> Void)?

    /// 預載完成回調
    var onPreloadComplete: (() -> Void)?

    /// 上次通知的 index（避免重複回調）
    private var lastNotifiedIndex: Int = -1

    // MARK: - Configuration

    /// 配置視圖
    func configure(with folder: ImageFolder, imageLoader: ImageLoader) {
        self.folder = folder
        self.imageLoader = imageLoader
        self.lastNotifiedIndex = -1

        NSLog("[ContinuousScroll] configure: folder.images.count=\(folder.images.count), containerWidth=\(containerWidth)")

        Task { [weak self] in
            await self?.preloadImageSizesParallel()
        }
    }

    /// 平行預載所有圖片尺寸
    private func preloadImageSizesParallel() async {
        guard let folder = folder, let loader = imageLoader else { return }

        // Capture default aspect ratio before entering TaskGroup
        let defaultRatio = defaultAspectRatio

        // 使用 TaskGroup 平行載入
        let sizes = await withTaskGroup(of: (Int, NSSize).self) { group in
            for (index, item) in folder.images.enumerated() {
                group.addTask {
                    if let size = await loader.getImageSize(for: item.url) {
                        return (index, size)
                    } else {
                        // 無法取得尺寸時使用預設比例
                        return (index, NSSize(width: 800, height: 800 / defaultRatio))
                    }
                }
            }

            var results: [(Int, NSSize)] = []
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }

        await MainActor.run { [weak self] in
            self?.imageSizes = sizes
            NSLog("[ContinuousScroll] preloaded \(sizes.count) image sizes")
            self?.recalculateLayout()
            // 通知預載完成
            self?.onPreloadComplete?()
        }
    }

    /// 重新計算佈局（使用標準座標系統：y=0 在底部）
    private func recalculateLayout() {
        guard !imageSizes.isEmpty else {
            scaledHeights = []
            yOffsets = []
            frame = NSRect(x: 0, y: 0, width: containerWidth, height: 0)
            NSLog("[ContinuousScroll] recalculateLayout: empty imageSizes")
            return
        }

        // Cache 縮放後的高度，避免重複計算
        scaledHeights = imageSizes.map { scaledHeightForSize($0) }
        let totalHeight = scaledHeights.reduce(0, +) + CGFloat(max(0, scaledHeights.count - 1)) * imageSpacing

        // 從頂端開始往下排列 (unflipped: 大 y 在上，小 y 在下)
        var offsets: [CGFloat] = []
        var currentY = totalHeight
        for h in scaledHeights {
            let bottomY = currentY - h
            offsets.append(bottomY)
            currentY = bottomY - imageSpacing
        }

        self.yOffsets = offsets
        frame = NSRect(x: 0, y: 0, width: containerWidth, height: totalHeight)

        NSLog("[ContinuousScroll] recalculateLayout: totalHeight=\(totalHeight), containerWidth=\(containerWidth), frame=\(frame)")

        needsDisplay = true
    }

    /// 計算 fit-to-width 縮放後的高度（防止除以零）
    private func scaledHeightForSize(_ size: NSSize) -> CGFloat {
        guard size.width > 0 else {
            return containerWidth / defaultAspectRatio
        }
        return (size.height / size.width) * containerWidth
    }

    // MARK: - View Recycling

    /// 更新可見範圍內的 slots
    func updateVisibleSlots(for visibleRect: NSRect) {
        // 檢測當前 index 變更（基於 viewport 中心點）
        let viewportCenterY = visibleRect.midY
        let newIndex = calculateCurrentIndex(for: viewportCenterY)

        NSLog("[ContinuousScroll] updateVisibleSlots: visibleRect=\(visibleRect), centerY=\(viewportCenterY), newIndex=\(newIndex), lastNotified=\(lastNotifiedIndex)")

        if newIndex != lastNotifiedIndex {
            lastNotifiedIndex = newIndex
            notifyImageChanged(index: newIndex)
        }
    }

    /// 通知圖片變更
    private func notifyImageChanged(index: Int) {
        guard scaledHeights.indices.contains(index) else { return }

        let scaledHeight = scaledHeights[index]
        let scaledSize = NSSize(width: containerWidth, height: scaledHeight)

        onCurrentImageChanged?(index, scaledSize)
    }

    // MARK: - Layout Helpers

    /// 計算指定索引圖片的 frame（fit-to-width）
    /// 使用標準座標系統：y=0 在底部
    func frameForImage(at index: Int) -> NSRect {
        guard scaledHeights.indices.contains(index),
              yOffsets.indices.contains(index) else {
            return .zero
        }

        let scaledHeight = scaledHeights[index]
        let yOffset = yOffsets[index]

        // 標準座標系統：直接使用累積的 yOffset
        return NSRect(
            x: 0,
            y: yOffset,
            width: containerWidth,
            height: scaledHeight
        )
    }

    /// 計算當前中心點對應的圖片索引
    /// scrollY 是標準座標系統中的 Y 座標（y=0 在底部）
    /// 使用 binary search 達到 O(log n) 效率
    func calculateCurrentIndex(for scrollY: CGFloat) -> Int {
        guard !scaledHeights.isEmpty, !yOffsets.isEmpty else { return 0 }

        var low = 0
        var high = scaledHeights.count - 1

        while low <= high {
            let mid = (low + high) / 2
            let yOffset = yOffsets[mid]
            let height = scaledHeights[mid]

            if scrollY < yOffset {
                low = mid + 1
            } else if scrollY >= yOffset + height {
                high = mid - 1
            } else {
                return mid
            }
        }

        // 超出範圍時返回邊界值
        return max(0, min(scaledHeights.count - 1, high))
    }

    // MARK: - Drawing

    // 不覆寫 isFlipped，使用標準座標系統（y=0 在底部）

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // 繪製背景
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        // TODO: Phase 2+ - 繪製可見範圍內的圖片
        // 目前先繪製佔位色塊
        for i in 0..<scaledHeights.count {
            let imageFrame = frameForImage(at: i)
            guard dirtyRect.intersects(imageFrame) else { continue }

            NSColor.secondarySystemFill.setFill()
            imageFrame.fill()

            // 繪製索引標籤
            let indexText = "\(i + 1)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 24, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let textSize = indexText.size(withAttributes: attrs)
            let textRect = NSRect(
                x: imageFrame.midX - textSize.width / 2,
                y: imageFrame.midY - textSize.height / 2,
                width: textSize.width,
                height: textSize.height
            )
            indexText.draw(in: textRect, withAttributes: attrs)
        }
    }
}
