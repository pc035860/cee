import AppKit

/// 連續捲動內容視圖（Webtoon-style vertical scrolling）
class ContinuousScrollContentView: NSView {

    // MARK: - Properties

    private var folder: ImageFolder?
    private weak var imageLoader: ImageLoader?

    /// 預載的圖片尺寸（fit-to-width 縮放後）
    private var imageSizes: [NSSize] = []

    /// 每張圖片的 Y 座標起始點
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

    // MARK: - Index Tracking

    /// 當前圖片變更回調：(index, scaledImageSize)
    var onCurrentImageChanged: ((Int, NSSize) -> Void)?

    /// 上次通知的 index（避免重複回調）
    private var lastNotifiedIndex: Int = -1

    // MARK: - Configuration

    /// 配置視圖
    func configure(with folder: ImageFolder, imageLoader: ImageLoader) {
        self.folder = folder
        self.imageLoader = imageLoader
        self.lastNotifiedIndex = -1

        Task { [weak self] in
            await self?.preloadImageSizes()
        }
    }

    /// 預載所有圖片尺寸
    private func preloadImageSizes() async {
        guard let folder = folder, let loader = imageLoader else { return }

        var sizes: [NSSize] = []
        for item in folder.images {
            if let size = await loader.getImageSize(for: item.url) {
                sizes.append(size)
            } else {
                // 無法取得尺寸時使用預設值
                sizes.append(NSSize(width: 800, height: 600))
            }
        }

        await MainActor.run { [weak self] in
            self?.imageSizes = sizes
            self?.recalculateLayout()
        }
    }

    /// 重新計算佈局
    private func recalculateLayout() {
        guard !imageSizes.isEmpty else {
            frame = NSRect(x: 0, y: 0, width: containerWidth, height: 0)
            return
        }

        // 計算 fit-to-width 後的高度
        var yOffsets: [CGFloat] = []
        var currentY: CGFloat = 0

        for size in imageSizes {
            yOffsets.append(currentY)
            let scaledHeight = (size.height / size.width) * containerWidth
            currentY += scaledHeight + imageSpacing
        }

        self.yOffsets = yOffsets

        // 設定總高度（反轉座標系統：y=0 在視覺頂部）
        let totalHeight = currentY
        frame = NSRect(x: 0, y: 0, width: containerWidth, height: totalHeight)

        needsDisplay = true
    }

    // MARK: - View Recycling

    /// 更新可見範圍內的 slots
    func updateVisibleSlots(for visibleRect: NSRect) {
        // 檢測當前 index 變更（基於 viewport 中心點）
        let viewportCenterY = visibleRect.midY
        let newIndex = calculateCurrentIndex(for: viewportCenterY)

        if newIndex != lastNotifiedIndex {
            lastNotifiedIndex = newIndex
            notifyImageChanged(index: newIndex)
        }
    }

    /// 通知圖片變更
    private func notifyImageChanged(index: Int) {
        guard imageSizes.indices.contains(index) else { return }

        let imageSize = imageSizes[index]
        // 計算 fit-to-width 縮放後的尺寸
        let scaledHeight = (imageSize.height / imageSize.width) * containerWidth
        let scaledSize = NSSize(width: containerWidth, height: scaledHeight)

        onCurrentImageChanged?(index, scaledSize)
    }

    // MARK: - Layout Helpers

    /// 計算指定索引圖片的 frame（fit-to-width）
    func frameForImage(at index: Int) -> NSRect {
        guard imageSizes.indices.contains(index),
              yOffsets.indices.contains(index) else {
            return .zero
        }

        let size = imageSizes[index]
        let scaledHeight = (size.height / size.width) * containerWidth
        let yOffset = yOffsets[index]

        // NSScrollView 反轉座標：視覺頂部 = 高 Y
        // 但 ContinuousScrollContentView 使用標準座標，所以直接用 yOffset
        return NSRect(
            x: 0,
            y: frame.height - yOffset - scaledHeight,
            width: containerWidth,
            height: scaledHeight
        )
    }

    /// 計算當前中心點對應的圖片索引
    func calculateCurrentIndex(for scrollY: CGFloat) -> Int {
        guard !imageSizes.isEmpty else { return 0 }

        // scrollY 是從視圖頂部開始的座標
        // 轉換為累積高度
        let adjustedY = frame.height - scrollY

        for i in 0..<imageSizes.count {
            let scaledHeight = (imageSizes[i].height / imageSizes[i].width) * containerWidth
            let yOffset = yOffsets[i]

            if adjustedY >= yOffset && adjustedY < yOffset + scaledHeight {
                return i
            }
        }

        // 超出範圍時返回最後一張
        return imageSizes.count - 1
    }

    // MARK: - Drawing

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // 繪製背景
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        // TODO: Phase 2+ - 繪製可見範圍內的圖片
        // 目前先繪製佔位色塊
        for i in 0..<imageSizes.count {
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
