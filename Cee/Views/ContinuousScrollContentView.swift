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

    // MARK: - View Recycling

    private var activeSlots: [ImageSlotView] = []
    private var reusableSlots: [ImageSlotView] = []
    private let bufferCount: Int = 2  // visible 前後各 buffer 2 張

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

        // 清理舊的 slots
        for slot in activeSlots {
            slot.removeFromSuperview()
        }
        activeSlots.removeAll()
        reusableSlots.removeAll()

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

    /// 更新可見範圍內的 slots（對外入口）
    func updateVisibleSlots(for visibleBounds: NSRect) {
        // 原有的 index tracking
        let newIndex = calculateCurrentIndex(for: visibleBounds.midY)
        if newIndex != lastNotifiedIndex {
            lastNotifiedIndex = newIndex
            notifyImageChanged(index: newIndex)
        }

        // View recycling
        manageSlotViews(for: visibleBounds)
    }

    /// 計算可見範圍（含 buffer）
    func calculateVisibleRange(for visibleRect: NSRect) -> ClosedRange<Int> {
        guard !imageSizes.isEmpty else { return 0...0 }

        let topY = visibleRect.minY
        let bottomY = visibleRect.maxY

        // Binary search 找出可見範圍
        var firstIndex = 0
        var lastIndex = imageSizes.count - 1

        // 找第一個可見的 index
        for (i, yOffset) in yOffsets.enumerated() {
            let height = scaledHeights[safe: i] ?? containerWidth / defaultAspectRatio
            if yOffset + height >= topY {
                firstIndex = i
                break
            }
        }

        // 找最後一個可見的 index
        for (i, yOffset) in yOffsets.enumerated() {
            if yOffset > bottomY {
                lastIndex = max(firstIndex, i - 1)
                break
            }
        }

        // 加上 buffer
        let bufferedFirst = max(0, firstIndex - bufferCount)
        let bufferedLast = min(imageSizes.count - 1, lastIndex + bufferCount)

        return bufferedFirst...bufferedLast
    }

    /// Dequeue 或建立新的 slot
    private func dequeueOrCreateSlot() -> ImageSlotView {
        if let reusable = reusableSlots.popLast() {
            return reusable
        }
        return ImageSlotView(frame: .zero)
    }

    /// 檢查指定 index 的 slot 是否已存在
    private func isSlotActive(for index: Int) -> Bool {
        activeSlots.contains { $0.imageIndex == index }
    }

    /// 管理可見範圍內的 slot views（view recycling 核心方法）
    private func manageSlotViews(for visibleRect: NSRect) {
        let visibleRange = calculateVisibleRange(for: visibleRect)

        // 1. 回收超出範圍的 slots
        for slot in activeSlots where !visibleRange.contains(slot.imageIndex) {
            slot.removeFromSuperview()
            slot.prepareForReuse()
            reusableSlots.append(slot)
        }
        activeSlots.removeAll { !visibleRange.contains($0.imageIndex) }

        // 2. 為新進入範圍的 indices 建立 slots
        for index in visibleRange where !isSlotActive(for: index) {
            let slot = dequeueOrCreateSlot()
            slot.imageIndex = index
            slot.frame = frameForImage(at: index)
            addSubview(slot)
            activeSlots.append(slot)
            loadImage(for: index, into: slot)
        }
    }

    /// 計算指定 index 圖片的 frame
    func frameForImage(at index: Int) -> NSRect {
        guard index < imageSizes.count && index < yOffsets.count else {
            return .zero
        }
        let height = scaledHeights[safe: index] ?? containerWidth / defaultAspectRatio
        let y = yOffsets[index]
        return NSRect(x: 0, y: y, width: containerWidth, height: height)
    }

    // MARK: - Async Image Loading

    private func loadImage(for index: Int, into slot: ImageSlotView) {
        guard let folder = folder,
              index < folder.images.count,
              let loader = imageLoader else { return }

        let item = folder.images[index]

        // 取消該 slot 原有的載入任務
        slot.prepareForReuse()
        slot.imageIndex = index

        // 建立新的載入任務
        let task = Task { [weak self] in
            guard !Task.isCancelled else { return }

            let image: NSImage?

            // 根據類型選擇載入方式
            if let pageIndex = item.pdfPageIndex {
                image = await loader.loadPDFPage(url: item.url, pageIndex: pageIndex)
            } else {
                image = await loader.loadImage(at: item.url)
            }

            guard let image else { return }

            await MainActor.run { [weak self] in
                // 檢查 self 和 folder 是否仍存在
                guard let self,
                      self.folder != nil else { return }
                // Stale write 防護：確認 slot 仍對應這個 index
                guard slot.imageIndex == index else { return }
                slot.setImage(image)
            }
        }

        slot.setLoadTask(task)
    }

    // MARK: - Index Tracking

    /// 通知圖片變更
    private func notifyImageChanged(index: Int) {
        guard scaledHeights.indices.contains(index) else { return }

        let scaledHeight = scaledHeights[index]
        let scaledSize = NSSize(width: containerWidth, height: scaledHeight)

        onCurrentImageChanged?(index, scaledSize)
    }

    // MARK: - Layout Helpers


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
}

// MARK: - Array Safe Subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
