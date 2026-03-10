import AppKit

/// 連續捲動內容視圖（Webtoon-style vertical scrolling）
/// 使用標準 macOS 座標系統（y=0 在底部）以配合 ImageScrollView
class ContinuousScrollContentView: NSView {

    // MARK: - Properties

    private var folder: ImageFolder?
    private weak var imageLoader: ImageLoader?

    /// Configuration generation ID（防止 stale write）
    private var configurationID: UUID = UUID()

    /// 預載的圖片尺寸
    private(set) var imageSizes: [NSSize] = []

    /// 縮放後的高度（cache 避免重複計算）
    internal var scaledHeights: [CGFloat] = []

    /// 每張圖片的 Y 座標起始點（從底部開始累積）
    private var yOffsets: [CGFloat] = []

    /// 容器寬度（用於 fit-to-width 計算）
    var containerWidth: CGFloat = 800 {
        didSet { guard oldValue != containerWidth else { return }; relayoutSlots() }
    }

    /// 圖片間距
    var imageSpacing: CGFloat = 0 {
        didSet { guard oldValue != imageSpacing else { return }; relayoutSlots() }
    }

    /// 重算 layout 並更新所有 activeSlots 的 frame（含 anchor-based 位置保持）
    private func relayoutSlots() {
        // 1. Capture anchor before relayout
        let scrollView = enclosingScrollView
        let hadLayout = !scaledHeights.isEmpty
        let viewportMidY = scrollView?.contentView.bounds.midY ?? 0
        let anchorIndex = hadLayout ? calculateCurrentIndex(for: viewportMidY) : 0
        let fraction: CGFloat
        if hadLayout {
            let imageOriginY = yOffsets[anchorIndex]
            let imageHeight = scaledHeights[anchorIndex]
            let raw = imageHeight > 0 ? (viewportMidY - imageOriginY) / imageHeight : 0
            fraction = max(0, min(1, raw))
        } else {
            fraction = 0
        }

        // 2. Relayout
        recalculateLayout()
        for slot in activeSlots {
            slot.frame = frameForImage(at: slot.imageIndex)
        }

        // 3. Restore scroll position
        guard hadLayout, let scrollView, !scaledHeights.isEmpty,
              anchorIndex < yOffsets.count else { return }
        let clipView = scrollView.contentView
        let newImageOriginY = yOffsets[anchorIndex]
        let newImageHeight = scaledHeights[anchorIndex]
        let newMidY = newImageOriginY + fraction * newImageHeight
        let clipHeight = clipView.bounds.height
        // Inset-aware clamp: .bottom = visual bottom (minY), .top = visual top (maxY)
        let insets = scrollView.contentInsets
        let minY = -insets.bottom
        let maxY = max(frame.height - clipHeight + insets.top, minY)
        let targetY = max(minY, min(newMidY - clipHeight / 2, maxY))
        // Preserve horizontal position (zoom + pan scenario)
        let currentX = clipView.bounds.origin.x
        clipView.scroll(to: NSPoint(x: currentX, y: targetY))
        scrollView.reflectScrolledClipView(clipView)
    }

    /// 預設圖片高度（無法取得尺寸時使用）
    private let defaultAspectRatio: CGFloat = 4.0 / 3.0

    // MARK: - Scaling Quality

    /// 當前的縮放 filter（供新建 slot 套用）
    private var currentMagFilter: CALayerContentsFilter = .linear
    private var currentMinFilter: CALayerContentsFilter = .linear

    /// 設定所有 active slots 的縮放 filter，並儲存供新 slot 套用
    func setScalingFilters(magnification: CALayerContentsFilter, minification: CALayerContentsFilter) {
        guard currentMagFilter != magnification || currentMinFilter != minification else { return }
        currentMagFilter = magnification
        currentMinFilter = minification
        for slot in activeSlots {
            slot.setScalingFilters(magnification: magnification, minification: minification)
        }
    }

    // MARK: - View Recycling

    private var activeSlots: [ImageSlotView] = []
    private var reusableSlots: [ImageSlotView] = []
    private var bufferCount: Int = 2  // visible 前後各 buffer 2 張
    private let defaultBufferCount: Int = 2

    /// Zoom 進行中：跳過 slot 回收，只新增 slot（防止黑色閃爍）
    private(set) var isZooming: Bool = false

    /// 開始 zoom：暫停 slot 回收
    func beginZoomSuppression() {
        isZooming = true
    }

    /// 結束 zoom：恢復 slot 回收，處理延遲的記憶體壓力，清理多餘 slots
    func endZoomSuppression(visibleBounds: NSRect) {
        isZooming = false
        // 更新 lastKnownVisibleBounds，確保 deferred pressure 使用最新可視區域
        lastKnownVisibleBounds = visibleBounds
        if let level = pendingPressureLevel {
            pendingPressureLevel = nil
            handleMemoryPressure(level)
            // handleMemoryPressure 內部已呼叫 manageSlotViews，不需重複
        } else {
            updateVisibleSlots(for: visibleBounds)
        }
    }

    // MARK: - Scroll Direction Tracking (Phase 3.2)

    /// 上次捲動的 Y 座標（用於計算捲動方向）
    internal var lastScrollY: CGFloat?

    /// 捲動方向（true = 往下捲動，    /// 小 y = 視覺下方 =        /// 大 y = 視覺上方）
    private(set) var isScrollingDown: Bool = true

    /// 最後已知的可見區域（用於記憶體壓力處理時參考）
    private var lastKnownVisibleBounds: NSRect = .zero

    /// 預取節流器（20Hz）
    private var prefetchThrottle = NavigationThrottle()

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
        self.configurationID = UUID()  // 新的 configuration generation

        // 重置捲動方向
        resetScrollDirection()

        // 清理舊的 slots（先取消載入任務再移除）
        for slot in activeSlots {
            slot.prepareForReuse()
            slot.removeFromSuperview()
        }
        activeSlots.removeAll()
        reusableSlots.removeAll()

        // 設定記憶體壓力監控（idempotent — MemoryPressureMonitor 內部有 guard）
        setupMemoryPressureMonitor()

        NSLog("[ContinuousScroll] configure: folder.images.count=\(folder.images.count), containerWidth=\(containerWidth)")

        // 在 Task 外部捕獲所有需要的值，避免資料競爭
        let capturedFolder = folder
        let capturedLoader: ImageLoader? = imageLoader
        let capturedConfigurationID = configurationID
        let capturedDefaultRatio = defaultAspectRatio

        Task { [weak self] in
            guard let loader = capturedLoader else { return }

            // 使用 TaskGroup 平行載入
            let sizes = await withTaskGroup(of: (Int, NSSize).self) { group in
                for (index, item) in capturedFolder.images.enumerated() {
                    group.addTask {
                        if let size = await loader.getImageSize(for: item.url) {
                            return (index, size)
                        } else {
                            // 無法取得尺寸時使用預設比例
                            return (index, NSSize(width: Constants.defaultWindowWidth, height: Constants.defaultWindowWidth / capturedDefaultRatio))
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
                // Stale write 防護：確認 configurationID 仍然匹配
                guard self?.configurationID == capturedConfigurationID else { return }
                self?.imageSizes = sizes
                NSLog("[ContinuousScroll] preloaded \(sizes.count) image sizes")
                self?.recalculateLayout()
                // 通知預載完成
                self?.onPreloadComplete?()
            }
        }
    }

    /// 重置捲動方向（用於 folder 切換時）
    private func resetScrollDirection() {
        lastScrollY = nil
        isScrollingDown = true
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
        // Cache visible bounds（記憶體壓力處理時使用）
        lastKnownVisibleBounds = visibleBounds

        // 恢復 buffer count（warning 壓力後，下次 scroll 恢復）
        if needsBufferRestoration {
            bufferCount = defaultBufferCount
            needsBufferRestoration = false
        }

        // 更新捲動方向
        updateScrollDirection(currentY: visibleBounds.midY)

        // 原有的 index tracking
        let newIndex = calculateCurrentIndex(for: visibleBounds.midY)
        if newIndex != lastNotifiedIndex {
            lastNotifiedIndex = newIndex
            notifyImageChanged(index: newIndex)
        }

        // View recycling
        let visibleRange = manageSlotViews(for: visibleBounds)

        // 觸發預取
        triggerPrefetch(visibleRange: visibleRange)
    }

    /// 更新捲動方向
    /// - Parameter currentY: 當前捲動位置（標準座標系統，y=0 在底部）
    func updateScrollDirection(currentY: CGFloat) {
        if let lastY = lastScrollY {
            // 標準座標系統（y=0 在底部）：小 y = 視覺下方 = index 增加
            isScrollingDown = currentY < lastY
        }
        lastScrollY = currentY
    }

    /// 計算可見範圍（含 buffer）— O(log n) binary search
    /// yOffsets 是遞減排列：index 0 = 最上方（最大 y），index N-1 = 最底部（最小 y）
    func calculateVisibleRange(for visibleRect: NSRect) -> ClosedRange<Int> {
        guard !imageSizes.isEmpty else { return 0...0 }

        let count = imageSizes.count

        // 用 calculateCurrentIndex (binary search) 找到包含 visibleRect 邊界的圖片
        let firstVisible = calculateCurrentIndex(for: visibleRect.maxY)   // 頂端 → 最上方的可見圖片
        let lastVisible = calculateCurrentIndex(for: visibleRect.minY)    // 底端 → 最底部的可見圖片

        // 加上 buffer
        let bufferedFirst = max(0, firstVisible - bufferCount)
        let bufferedLast = min(count - 1, lastVisible + bufferCount)

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
    /// - Returns: 可見範圍（含 buffer）
    @discardableResult
    private func manageSlotViews(for visibleRect: NSRect) -> ClosedRange<Int> {
        let visibleRange = calculateVisibleRange(for: visibleRect)

        // 1. 回收超出範圍的 slots（zoom 中跳過回收，防止黑色閃爍）
        if !isZooming {
            for slot in activeSlots where !visibleRange.contains(slot.imageIndex) {
                slot.removeFromSuperview()
                slot.prepareForReuse()
                reusableSlots.append(slot)
            }
            activeSlots.removeAll { !visibleRange.contains($0.imageIndex) }
        }

        // 2. 為新進入範圍的 indices 建立 slots
        for index in visibleRange where !isSlotActive(for: index) {
            let slot = dequeueOrCreateSlot()
            slot.imageIndex = index
            slot.frame = frameForImage(at: index)
            slot.setScalingFilters(magnification: currentMagFilter, minification: currentMinFilter)
            addSubview(slot)
            activeSlots.append(slot)
            loadImage(for: index, into: slot)
        }

        return visibleRange
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
                // Phase 3.5: 使用 subsample 載入，節省大圖記憶體
                // displayPixelWidth = containerWidth * Retina scale factor（單次 actor hop）
                let displayPixelWidth = await MainActor.run {
                    (self?.containerWidth ?? 800) * (self?.window?.backingScaleFactor ?? 2.0)
                }
                image = await loader.loadImageForDisplay(at: item.url, maxWidth: displayPixelWidth)
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

    // MARK: - Prefetch (Phase 3.2)

    /// 觸發預取（根據捲動方向）
    private func triggerPrefetch(visibleRange: ClosedRange<Int>) {
        // 節流檢查（20Hz）
        guard prefetchThrottle.shouldProceed() else { return }

        guard let folder = folder,
              let loader = imageLoader else { return }

        // 計算預取範圍
        let prefetchCount = 5
        let prefetchStart: Int
        let prefetchEnd: Int

        if isScrollingDown {
            prefetchStart = visibleRange.upperBound + 1
            prefetchEnd = min(folder.images.count - 1, visibleRange.upperBound + prefetchCount)
        } else {
            prefetchStart = max(0, visibleRange.lowerBound - prefetchCount)
            prefetchEnd = visibleRange.lowerBound - 1
        }

        guard prefetchStart <= prefetchEnd else { return }

        // 觸發 ImageLoader 預取
        let direction: PrefetchDirection = isScrollingDown ? .forward : .backward
        Task {
            await loader.updateCache(
                currentIndex: visibleRange.lowerBound,
                items: folder.images,
                prefetchDirection: direction
            )
        }
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

    // MARK: - Memory Pressure Monitoring

    private let memoryPressureMonitor = MemoryPressureMonitor()

    /// 延遲處理的壓力等級（zoom 中暫緩）
    private var pendingPressureLevel: MemoryPressureMonitor.PressureLevel?

    /// Buffer 需要恢復的標記（warning 後在下次 scroll 恢復）
    private var needsBufferRestoration: Bool = false

    /// 設定記憶體壓力監控
    private func setupMemoryPressureMonitor() {
        memoryPressureMonitor.onPressure = { [weak self] level in
            self?.handleMemoryPressure(level)
        }
        memoryPressureMonitor.start()
    }

    /// 處理記憶體壓力
    private func handleMemoryPressure(_ level: MemoryPressureMonitor.PressureLevel) {
        // Zoom 中延遲處理（escalate only：warning 不覆蓋 critical）
        if isZooming {
            if pendingPressureLevel == nil || level == .critical {
                pendingPressureLevel = level
            }
            return
        }

        let capturedConfigID = configurationID

        // 共用：縮減 buffer，觸發 slot 回收
        bufferCount = 0
        needsBufferRestoration = true
        if !lastKnownVisibleBounds.isEmpty {
            manageSlotViews(for: lastKnownVisibleBounds)
        }

        // Critical 額外：清空 reusable pool + ImageLoader 快取
        if level == .critical {
            reusableSlots.removeAll()
            guard configurationID == capturedConfigID else { return }
            Task { [weak self] in
                await self?.imageLoader?.clearImageCache()
            }
        }
    }

    /// Cleanup: stop monitor, cancel tasks, clear slots
    func cleanup() {
        memoryPressureMonitor.stop()
        pendingPressureLevel = nil
        needsBufferRestoration = false
        bufferCount = defaultBufferCount
        for slot in activeSlots {
            slot.prepareForReuse()
            slot.removeFromSuperview()
        }
        activeSlots.removeAll()
        reusableSlots.removeAll()
    }

    // MARK: - Test-Only Accessors

    func _testActiveSlotCount() -> Int { activeSlots.count }
    func _testReusableSlotCount() -> Int { reusableSlots.count }
    func _testBufferCount() -> Int { bufferCount }
    func _testIsMonitorRunning() -> Bool { memoryPressureMonitor._testIsRunning() }

    func _testHandleMemoryPressure(_ level: MemoryPressureMonitor.PressureLevel) {
        handleMemoryPressure(level)
    }

    /// Test-only: configure with mock sizes (no ImageLoader needed)
    func _testConfigureWithSizes(_ sizes: [NSSize]) {
        self.configurationID = UUID()
        self.imageSizes = sizes
        recalculateLayout()
        setupMemoryPressureMonitor()
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
