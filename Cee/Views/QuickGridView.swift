import AppKit
import ImageIO

/// Scroll direction for prefetch pipeline.
enum ScrollDirection: Equatable {
    case up, down, none
}

@MainActor
protocol QuickGridViewDelegate: AnyObject {
    func quickGridView(_ view: QuickGridView, didSelectItemAt index: Int)
    func quickGridView(_ view: QuickGridView, didReceiveDrop urls: [URL])
    func quickGridViewDidRequestClose(_ view: QuickGridView)
}

/// NSScrollView subclass that intercepts Cmd+Scroll for grid cell size adjustment.
/// NSScrollView captures scrollWheel before documentView, so subclassing is required
/// (same pattern as ImageScrollView).
private final class GridScrollView: NSScrollView {
    var onCmdScroll: ((CGFloat) -> Void)?
    /// Read by scrollWheel to compute delta-based size. Updated by QuickGridView.
    var currentCellSize: CGFloat = Constants.quickGridCellSize

    // NSCollectionView re-enables scrollers during layout passes / reloadData.
    // Override to lock them off permanently.
    override var hasVerticalScroller: Bool {
        get { false }
        set { /* ignore — NSCollectionView tries to enable this */ }
    }
    override var hasHorizontalScroller: Bool {
        get { false }
        set { /* ignore */ }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        allowsMagnification = false  // defensive: prevent pinch event consumption
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }
        // Cmd+Scroll → adjust grid cell size
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.01 else { return }

        let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.5 : 3.0
        let newSize = currentCellSize + delta * sensitivity
        onCmdScroll?(newSize)
        // Do NOT call super — prevents event leaking to ImageScrollView underneath
    }
}

/// Minimal slider cell with thin track (2px) and small dot knob (8x8).
/// Provides a Figma-like ultra-minimal appearance for the grid size slider.
private final class MinimalSliderCell: NSSliderCell {
    private let trackHeight: CGFloat = 2
    private let knobSize: CGFloat = 8

    /// Normalized slider position (0.0–1.0).
    private var proportion: CGFloat {
        CGFloat((doubleValue - minValue) / (maxValue - minValue))
    }

    override func barRect(flipped: Bool) -> NSRect {
        let full = super.barRect(flipped: flipped)
        let y = full.midY - trackHeight / 2
        return NSRect(x: full.origin.x, y: y, width: full.width, height: trackHeight)
    }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let barRect = self.barRect(flipped: flipped)
        let knobX = barRect.origin.x + barRect.width * proportion

        // Left (filled) portion
        let leftRect = NSRect(x: barRect.origin.x, y: barRect.origin.y,
                              width: knobX - barRect.origin.x, height: barRect.height)
        let leftPath = NSBezierPath(roundedRect: leftRect, xRadius: 1, yRadius: 1)
        NSColor.white.withAlphaComponent(0.4).setFill()
        leftPath.fill()

        // Right (unfilled) portion
        let rightRect = NSRect(x: knobX, y: barRect.origin.y,
                               width: barRect.maxX - knobX, height: barRect.height)
        let rightPath = NSBezierPath(roundedRect: rightRect, xRadius: 1, yRadius: 1)
        NSColor.white.withAlphaComponent(0.15).setFill()
        rightPath.fill()
    }

    override func knobRect(flipped: Bool) -> NSRect {
        let barRect = self.barRect(flipped: flipped)
        let knobX = barRect.origin.x + barRect.width * proportion - knobSize / 2
        let knobY = barRect.midY - knobSize / 2
        return NSRect(x: knobX, y: knobY, width: knobSize, height: knobSize)
    }

    override func drawKnob(_ knobRect: NSRect) {
        let dotRect = NSRect(
            x: knobRect.midX - knobSize / 2,
            y: knobRect.midY - knobSize / 2,
            width: knobSize,
            height: knobSize
        )
        let path = NSBezierPath(ovalIn: dotRect)
        NSColor.white.withAlphaComponent(0.85).setFill()
        path.fill()
    }
}

/// NSCollectionView subclass that intercepts Enter/Return at the first responder level.
/// Without this, Enter events would need to propagate up the responder chain,
/// which NSCollectionView may not forward reliably.
private final class GridCollectionView: NSCollectionView {
    var onReturn: (() -> Void)?
    var onDismiss: (() -> Void)?
    /// Callback for cell size changes (pinch gesture, non-animated).
    var onCellSizeChange: ((CGFloat) -> Void)?
    /// Callback for animated cell size changes (keyboard shortcuts).
    var onAnimatedCellSizeChange: ((CGFloat) -> Void)?
    /// Current cell size — set by QuickGridView, read for incremental pinch calculation.
    var currentCellSize: CGFloat = Constants.quickGridCellSize

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.keyCode {
        case 36, 76:  // Return / Numpad Enter
            onReturn?()
        case 5 where modifiers == []:  // bare G (dismiss)
            onDismiss?()
        case 24 where modifiers == .command || modifiers == [.command, .shift]:
            // Cmd+= or Cmd+Shift+= (Cmd+) — grow by 10pt (ANSI keyCode 24)
            onAnimatedCellSizeChange?(currentCellSize + 10)
        case 27 where modifiers == .command:  // Cmd+- (ANSI keyCode 27) — shrink by 10pt
            onAnimatedCellSizeChange?(currentCellSize - 10)
        default:
            super.keyDown(with: event)
        }
    }

    override func magnify(with event: NSEvent) {
        // Incremental: newSize = currentSize * (1 + delta)
        // Matches ImageScrollView pattern (magnification + event.magnification)
        let newSize = currentCellSize * (1 + event.magnification)
        onCellSizeChange?(newSize)
        // Do NOT call super — prevents event propagating to ImageScrollView
    }
}

final class QuickGridView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {

    weak var delegate: QuickGridViewDelegate?

    // MARK: - UI

    private let gridScrollView = GridScrollView()
    private let collectionView = GridCollectionView()
    private var flowLayout: NSCollectionViewFlowLayout!
    private var items: [ImageItem] = []
    private var currentIndex: Int = 0

    /// Current grid cell size — single source of truth. Clamped to min/max range.
    private(set) var currentCellSize: CGFloat = Constants.quickGridCellSize

    /// Dynamic aspect ratio (height/width) determined by sampling folder images.
    private var currentAspectRatio: CGFloat = Constants.quickGridCellAspectRatio

    /// Dynamic thumbnail maxSize based on current cell size.
    /// Four tiers to balance sharpness vs memory:
    /// ≤ tier0 → adaptive (quantized 20px steps), ≤ tier1 → 240px, ≤ tier2 → 480px, > tier2 → 720px
    private var gridThumbnailMaxSize: CGFloat {
        if currentCellSize <= Constants.quickGridTier0Boundary {
            let scale = collectionView.window?.backingScaleFactor ?? 2.0
            let raw = max(currentCellSize * scale, Constants.quickGridTier0MinPx)
            // Quantize to fixed steps so pinch resize doesn't flush cache every frame
            let step = Constants.quickGridTier0QuantizeStep
            return ceil(raw / step) * step
        }
        if currentCellSize <= Constants.quickGridTier1Boundary { return Constants.quickGridThumbnailSize1 }
        if currentCellSize <= Constants.quickGridTier2Boundary { return Constants.quickGridThumbnailSize2 }
        return Constants.quickGridThumbnailSize3
    }

    // MARK: - Slider

    private let sizeSlider = NSSlider()
    private let sliderContainer = NSView()
    private var isUpdatingSliderProgrammatically = false

    /// Called after cell size changes (for persistence).
    var onCellSizeDidChange: ((CGFloat) -> Void)?

    // MARK: - Thumbnail Loading

    private var loader: ImageLoader?
    /// Grid-local thumbnail cache (not evicted by navigation's updateCache)
    private var gridThumbnails: [Int: NSImage] = [:]
    /// Test-only: number of cached grid thumbnails.
    var gridThumbnailCount: Int { gridThumbnails.count }
    /// Active thumbnail loading tasks (keyed by item index)
    private var thumbnailTasks: [Int: Task<Void, Never>] = [:]
    /// Test-only: number of active thumbnail loading tasks.
    var thumbnailTaskCount: Int { thumbnailTasks.count }

    /// Test-only: inject a mock task at the given index.
    func _testSetTask(_ task: Task<Void, Never>, forIndex index: Int) {
        thumbnailTasks[index] = task
    }

    /// Test-only accessor for gridThumbnailMaxSize computed property.
    var currentGridThumbnailMaxSize: CGFloat { gridThumbnailMaxSize }

    /// Test-only: inject a cached thumbnail at the given index.

    func _testSetThumbnail(_ image: NSImage, forIndex index: Int) {
        gridThumbnails[index] = image
    }

    /// Test-only accessor for gridThumbnailMaxCount.
    var _testGridThumbnailMaxCount: Int { gridThumbnailMaxCount }

    /// Generation counter: incremented on folder change to prevent stale cache writes.
    private var generationID: Int = 0

    /// Test-only accessor for generationID.
    var _testGenerationID: Int { generationID }

    /// Test-only: write thumbnail only if generation matches current.
    func _testWriteThumbnailIfCurrentGeneration(_ image: NSImage, forIndex index: Int, generation: Int) {
        guard generationID == generation else { return }
        gridThumbnails[index] = image
    }

    /// Test-only: simulate memory pressure response.
    func _testHandleMemoryPressure(_ level: MemoryPressureMonitor.PressureLevel) {
        handleMemoryPressure(level)
    }

    /// Test-only: set cell size without clamping for tier0 logic tests.
    func _testSetCellSizeForTesting(_ size: CGFloat) {
        currentCellSize = size
    }

    // MARK: - Memory Pressure

    private let memoryPressureMonitor = MemoryPressureMonitor()

    func setupMemoryPressureMonitor() {
        memoryPressureMonitor.onPressure = { [weak self] level in
            guard let self else { return }
            self.handleMemoryPressure(level)
        }
        memoryPressureMonitor.start()
    }

    private func handleMemoryPressure(_ level: MemoryPressureMonitor.PressureLevel) {
        switch level {
        case .warning:
            // Clear non-visible thumbnails and cancel all pending tasks
            let visibleIndices = Set(collectionView.indexPathsForVisibleItems().map(\.item))
            evictNonVisibleThumbnails(visibleIndices: visibleIndices)
            cancelPendingThumbnailTasks()
        case .critical:
            // Nuclear: clear ALL thumbnails and tasks
            gridThumbnails.removeAll()
            cancelPendingThumbnailTasks()
            // Also clear ImageLoader cache (actor-isolated, fire-and-forget)
            Task { [weak self] in
                await self?.loader?.clearThumbnailCache()
            }
        }
    }

    // MARK: - Prefetch Pipeline

    private var lastClipOriginY: CGFloat = 0
    private var scrollDirection: ScrollDirection = .none
    /// Cached visible center index, updated by scroll handler at ~20Hz.
    /// Used by cellForItem to avoid per-cell indexPathsForVisibleItems calls.
    private var cachedVisibleCenter: Int = 0

    /// Calculate columns per row for given layout parameters.
    static func columnsPerRow(availableWidth: CGFloat, cellSize: CGFloat) -> Int {
        let minSpacing = Constants.quickGridSpacing
        let baseInset = Constants.quickGridInset
        return max(1, Int(floor((availableWidth - baseInset * 2 + minSpacing) / (cellSize + minSpacing))))
    }

    /// Instance wrapper using current layout state.
    func columnsPerRow() -> Int {
        Self.columnsPerRow(availableWidth: gridScrollView.bounds.width, cellSize: currentCellSize)
    }

    /// Arithmetic O(1) visible index range from scroll geometry (static for unit testing).
    /// Avoids indexPathsForVisibleItems() overhead in scroll handler hot path.
    static func computeVisibleRange(
        scrollOriginY: CGFloat, viewportHeight: CGFloat,
        cellHeight: CGFloat, lineSpacing: CGFloat, topInset: CGFloat,
        cols: Int, itemCount: Int
    ) -> ClosedRange<Int>? {
        guard itemCount > 0, cols > 0 else { return nil }
        let rowHeight = cellHeight + lineSpacing
        guard rowHeight > 0 else { return nil }
        let totalRows = (itemCount + cols - 1) / cols

        let firstRow = max(0, Int(floor((scrollOriginY - topInset) / rowHeight)))
        let lastRowRaw = Int(ceil((scrollOriginY + viewportHeight - topInset) / rowHeight)) - 1
        let lastRow = min(totalRows - 1, max(0, lastRowRaw))
        let firstVisible = firstRow * cols
        let lastVisible = min(lastRow * cols + cols - 1, itemCount - 1)
        guard firstVisible <= lastVisible else { return nil }
        return firstVisible...lastVisible
    }

    /// Instance wrapper using current layout state.
    private func computeVisibleRange() -> ClosedRange<Int>? {
        let bounds = gridScrollView.contentView.bounds
        let cellHeight = currentCellSize * currentAspectRatio
        return Self.computeVisibleRange(
            scrollOriginY: bounds.origin.y, viewportHeight: bounds.height,
            cellHeight: cellHeight, lineSpacing: Constants.quickGridSpacing,
            topInset: Constants.quickGridInset,
            cols: columnsPerRow(), itemCount: items.count)
    }

    /// Calculate prefetch range based on scroll direction.
    static func prefetchRange(minVisible: Int, maxVisible: Int, direction: ScrollDirection, itemCount: Int, cols: Int) -> ClosedRange<Int>? {
        guard direction != .none else { return nil }
        let prefetchCount = cols * 2  // 2 rows ahead
        switch direction {
        case .down:
            let start = maxVisible + 1
            let end = min(itemCount - 1, maxVisible + prefetchCount)
            guard start <= end else { return nil }
            return start...end
        case .up:
            let end = minVisible - 1
            let start = max(0, minVisible - prefetchCount)
            guard start <= end else { return nil }
            return start...end
        case .none:
            return nil
        }
    }

    static func prefetchRange(visibleIndices: Set<Int>, direction: ScrollDirection, itemCount: Int, cols: Int) -> ClosedRange<Int>? {
        guard let minVis = visibleIndices.min(), let maxVis = visibleIndices.max() else { return nil }
        return prefetchRange(minVisible: minVis, maxVisible: maxVis, direction: direction, itemCount: itemCount, cols: cols)
    }

    /// Instance wrapper using current state.
    func prefetchRange(visibleIndices: Set<Int>, direction: ScrollDirection) -> ClosedRange<Int>? {
        Self.prefetchRange(visibleIndices: visibleIndices, direction: direction, itemCount: items.count, cols: columnsPerRow())
    }

    /// Detect scroll direction from clip origin Y delta.
    static func detectDirection(currentY: CGFloat, lastY: CGFloat, deadZone: CGFloat = 1) -> ScrollDirection {
        if currentY > lastY + deadZone { return .down }
        if currentY < lastY - deadZone { return .up }
        return .none  // within dead zone
    }

    /// Cancel tasks outside the given keep set (visible ∪ prefetch).
    private func cancelTasksOutsideKeepSet(_ keepIndices: Set<Int>) {
        for (index, task) in thumbnailTasks where !keepIndices.contains(index) {
            task.cancel()
            thumbnailTasks.removeValue(forKey: index)
        }
    }

    /// Cancel tasks outside the given keep range (visible ∪ prefetch, contiguous).
    private func cancelTasksOutsideKeepRange(_ keepRange: ClosedRange<Int>) {
        for (index, task) in thumbnailTasks where !keepRange.contains(index) {
            task.cancel()
            thumbnailTasks.removeValue(forKey: index)
        }
    }

    /// Start prefetch tasks for items in the prefetch range.
    private func prefetchThumbnails(visibleIndices: Set<Int>, direction: ScrollDirection) {
        guard let minVis = visibleIndices.min(), let maxVis = visibleIndices.max() else { return }
        prefetchThumbnails(minVisible: minVis, maxVisible: maxVis, direction: direction)
    }

    private func prefetchThumbnails(minVisible: Int, maxVisible: Int, direction: ScrollDirection) {
        guard let range = Self.prefetchRange(minVisible: minVisible, maxVisible: maxVisible, direction: direction, itemCount: items.count, cols: columnsPerRow()) else { return }
        let visibleCenter = (minVisible + maxVisible) / 2

        for index in range {
            guard gridThumbnails[index] == nil,
                  thumbnailTasks[index] == nil,
                  index < items.count else { continue }

            let item = items[index]
            guard !item.isPDF else { continue }
            guard let loader else { continue }

            let maxSize = gridThumbnailMaxSize
            let center = visibleCenter
            let distance = abs(index - center)
            let gen = generationID
            thumbnailTasks[index] = Task { [weak self] in
                let result = await loader.loadThumbnail(at: item.url, maxSize: maxSize,
                                                         priority: .utility,
                                                         throttlePriority: distance)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard self.generationID == gen else { return }  // Stale folder — discard

                if let image = result?.image {
                    self.gridThumbnails[index] = image
                    self.enforceGridThumbnailCap(currentIndex: center)

                    if let cell = self.collectionView.item(at: IndexPath(item: index, section: 0)) as? QuickGridCell {
                        cell.setThumbnail(image)
                    }
                }
                self.thumbnailTasks.removeValue(forKey: index)
            }
        }
    }

    /// Enforce memory cap: evict entries farthest from given center index.
    func enforceGridThumbnailCap(currentIndex: Int) {
        guard gridThumbnails.count > gridThumbnailMaxCount else { return }
        let sorted = gridThumbnails.keys.sorted { abs($0 - currentIndex) > abs($1 - currentIndex) }
        let excess = gridThumbnails.count - gridThumbnailMaxCount
        for key in sorted.prefix(excess) {
            gridThumbnails.removeValue(forKey: key)
        }
    }

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor

        // Collection view layout
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = currentItemSize
        layout.minimumInteritemSpacing = Constants.quickGridSpacing
        layout.minimumLineSpacing = Constants.quickGridSpacing
        layout.sectionInset = NSEdgeInsets(
            top: Constants.quickGridInset,
            left: Constants.quickGridInset,
            bottom: Constants.quickGridInset,
            right: Constants.quickGridInset
        )

        self.flowLayout = layout
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(
            QuickGridCell.self,
            forItemWithIdentifier: QuickGridCell.identifier
        )

        // Wire key handlers (intercepted at first-responder level by GridCollectionView)
        collectionView.onReturn = { [weak self] in
            guard let self,
                  let index = self.collectionView.selectionIndexPaths.first?.item else { return }
            self.delegate?.quickGridView(self, didSelectItemAt: index)
        }
        collectionView.onDismiss = { [weak self] in
            guard let self else { return }
            self.delegate?.quickGridViewDidRequestClose(self)
        }

        // Wire resize handlers (pinch + Cmd+Scroll — non-animated)
        collectionView.onCellSizeChange = { [weak self] newSize in
            self?.applyItemSize(newSize)
        }
        collectionView.onAnimatedCellSizeChange = { [weak self] newSize in
            self?.applyItemSize(newSize, animated: true)
        }
        gridScrollView.onCmdScroll = { [weak self] newSize in
            self?.applyItemSize(newSize)
        }

        // Size slider (bottom bar)
        sliderContainer.wantsLayer = true
        sliderContainer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.4).cgColor
        sliderContainer.translatesAutoresizingMaskIntoConstraints = false

        // Custom minimal cell — must be set BEFORE property configuration
        sizeSlider.cell = MinimalSliderCell()
        sizeSlider.minValue = Double(Constants.quickGridMinCellSize)
        sizeSlider.maxValue = Double(Constants.quickGridMaxCellSize)
        sizeSlider.doubleValue = Double(currentCellSize)
        sizeSlider.isContinuous = true
        sizeSlider.target = self
        sizeSlider.action = #selector(sliderValueChanged(_:))
        sizeSlider.translatesAutoresizingMaskIntoConstraints = false
        sliderContainer.addSubview(sizeSlider)

        // Scroll view wrapping collection view
        gridScrollView.documentView = collectionView
        // hasVerticalScroller/hasHorizontalScroller locked via override in GridScrollView
        gridScrollView.drawsBackground = false
        gridScrollView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(gridScrollView)
        addSubview(sliderContainer)

        NSLayoutConstraint.activate([
            gridScrollView.topAnchor.constraint(equalTo: topAnchor),
            gridScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            gridScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            gridScrollView.bottomAnchor.constraint(equalTo: sliderContainer.topAnchor),

            sliderContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            sliderContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            sliderContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            sliderContainer.heightAnchor.constraint(equalToConstant: 24),

            sizeSlider.centerXAnchor.constraint(equalTo: sliderContainer.centerXAnchor),
            sizeSlider.centerYAnchor.constraint(equalTo: sliderContainer.centerYAnchor),
            sizeSlider.widthAnchor.constraint(lessThanOrEqualToConstant: Constants.quickGridSliderMaxWidth),
            sizeSlider.leadingAnchor.constraint(greaterThanOrEqualTo: sliderContainer.leadingAnchor, constant: 8),
            sizeSlider.trailingAnchor.constraint(lessThanOrEqualTo: sliderContainer.trailingAnchor, constant: -8),
        ])

        // Prefer 400pt width when container is wide enough
        let widthConstraint = sizeSlider.widthAnchor.constraint(equalToConstant: Constants.quickGridSliderMaxWidth)
        widthConstraint.priority = .defaultLow
        widthConstraint.isActive = true

        // Respond to window resize: re-center items
        gridScrollView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(gridFrameDidChange),
            name: NSView.frameDidChangeNotification, object: gridScrollView)

        // Monitor scroll to cancel non-visible thumbnail tasks
        gridScrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification, object: gridScrollView.contentView)

        registerForDraggedTypes([.fileURL])

        // Memory pressure safety net
        setupMemoryPressureMonitor()
    }

    /// Item size derived directly from `currentCellSize` (Finder-style: smooth resize, columns change naturally).
    private var currentItemSize: NSSize {
        NSSize(width: currentCellSize, height: currentCellSize * currentAspectRatio)
    }

    /// Update section insets + inter-item spacing for space-around distribution.
    /// Each item gets equal gap on both sides; edge gap = G, between items = 2G.
    private func updateSpaceAroundLayout() {
        let available = gridScrollView.bounds.width
        guard available > 0 else { return }
        lastLayoutWidth = available

        let cellWidth = currentCellSize
        let baseInset = Constants.quickGridInset

        // Use shared columnsPerRow() as single source of truth, cast to CGFloat for gap math
        let cols = CGFloat(columnsPerRow())
        // space-around: available = cols * cellWidth + 2G * cols  →  G = remaining / (2 * cols)
        let remaining = max(0, available - cols * cellWidth)
        let gap = floor(remaining / (cols * 2))

        flowLayout.sectionInset = NSEdgeInsets(
            top: baseInset, left: gap,
            bottom: baseInset, right: gap)
        flowLayout.minimumInteritemSpacing = gap * 2
    }

    /// Last width used for space-around calculation; skip redundant recalcs (e.g. height-only resize).
    private var lastLayoutWidth: CGFloat = 0

    /// Throttle cancel-sweep to ~20Hz (avoid per-frame indexPathsForVisibleItems on 120Hz displays).
    private var cancelSweepThrottle = NavigationThrottle(interval: 0.05)

    @objc private func clipViewBoundsDidChange(_ note: Notification) {
        guard cancelSweepThrottle.shouldProceed() else { return }
        let scrollStart = CFAbsoluteTimeGetCurrent()

        // 1. Detect scroll direction
        let currentY = gridScrollView.contentView.bounds.origin.y
        let detected = Self.detectDirection(currentY: currentY, lastY: lastClipOriginY)
        if detected != .none { scrollDirection = detected }
        lastClipOriginY = currentY

        // 2. Visible range (arithmetic O(1), avoids indexPathsForVisibleItems overhead)
        let t2 = CFAbsoluteTimeGetCurrent()
        guard let visibleRange = computeVisibleRange() else {
            let totalMs = (CFAbsoluteTimeGetCurrent() - scrollStart) * 1000
            GridPerfLog.log(String(format: "scrollHandler: total=%.2fms | visible=nil | cache=%d", totalMs, gridThumbnails.count))
            return
        }
        let minVis = visibleRange.lowerBound
        let maxVis = visibleRange.upperBound
        cachedVisibleCenter = (minVis + maxVis) / 2
        let visibleMs = (CFAbsoluteTimeGetCurrent() - t2) * 1000

        // 3. Build keep range = visible ∪ prefetch (contiguous)
        var keepMin = minVis, keepMax = maxVis
        if let prefetch = Self.prefetchRange(minVisible: minVis, maxVisible: maxVis, direction: scrollDirection, itemCount: items.count, cols: columnsPerRow()) {
            keepMin = min(keepMin, prefetch.lowerBound)
            keepMax = max(keepMax, prefetch.upperBound)
        }
        let keepRange = keepMin...keepMax

        // 4. Cancel tasks outside keep range
        let t4 = CFAbsoluteTimeGetCurrent()
        cancelTasksOutsideKeepRange(keepRange)
        let cancelMs = (CFAbsoluteTimeGetCurrent() - t4) * 1000

        // 5. Evict thumbnails (±50 buffer covers prefetch range of ~6-10 items)
        let t5 = CFAbsoluteTimeGetCurrent()
        evictNonVisibleThumbnails(minVisible: minVis, maxVisible: maxVis)
        let evictMs = (CFAbsoluteTimeGetCurrent() - t5) * 1000

        // 6. Start prefetch
        let t6 = CFAbsoluteTimeGetCurrent()
        prefetchThumbnails(minVisible: minVis, maxVisible: maxVis, direction: scrollDirection)
        let prefetchMs = (CFAbsoluteTimeGetCurrent() - t6) * 1000

        let totalMs = (CFAbsoluteTimeGetCurrent() - scrollStart) * 1000
        GridPerfLog.log(String(format: "scrollHandler: total=%.2fms | visible(%d)=%.2fms | cancel(%d tasks)=%.2fms | evict=%.2fms | prefetch=%.2fms | cache=%d",
                               totalMs, visibleRange.count, visibleMs, thumbnailTasks.count, cancelMs, evictMs, prefetchMs, gridThumbnails.count))
    }

    @objc private func gridFrameDidChange(_ note: Notification) {
        let width = gridScrollView.bounds.width
        guard width != lastLayoutWidth else { return }
        updateSpaceAroundLayout()
        collectionView.collectionViewLayout?.invalidateLayout()
    }

    /// Sample image headers to compute median aspect ratio (height/width).
    /// Reads only file headers via CGImageSource — no pixel decode, ~0.1ms per file.
    /// Note: runs synchronously on main thread (~5ms for 50 images on SSD;
    /// may be slower on HDD/NAS — acceptable MVP trade-off).
    private func sampleMedianAspectRatio(from items: [ImageItem]) -> CGFloat {
        let sampleItems = items
            .lazy
            .filter { !$0.isPDF }
            .prefix(Constants.quickGridAspectRatioSampleCount)
        guard !sampleItems.isEmpty else { return Constants.quickGridCellAspectRatio }

        var ratios: [CGFloat] = []
        ratios.reserveCapacity(sampleItems.count)

        for item in sampleItems {
            guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                  let pw = props[kCGImagePropertyPixelWidth as String] as? CGFloat,
                  let ph = props[kCGImagePropertyPixelHeight as String] as? CGFloat,
                  pw > 0, ph > 0 else { continue }

            // EXIF orientation 5-8 means the image is rotated 90°/270° — swap dimensions.
            let orientation = (props[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
            let (w, h) = (orientation >= 5 && orientation <= 8) ? (ph, pw) : (pw, ph)
            ratios.append(h / w)
        }

        guard !ratios.isEmpty else { return Constants.quickGridCellAspectRatio }
        ratios.sort()
        return ratios[ratios.count / 2]
    }

    // MARK: - Cell Size

    /// Apply a new cell size, clamped to the allowed range.
    /// Normally only invalidates layout (no cache clear). When crossing a thumbnail
    /// tier boundary (tier0→adaptive/tier1→240/tier2→480/tier3→720px), cancels in-flight tasks and reloads.
    func applyItemSize(_ newSize: CGFloat, animated: Bool = false) {
        let clamped = max(Constants.quickGridMinCellSize,
                          min(Constants.quickGridMaxCellSize, newSize))
        guard clamped != currentCellSize else { return }

        // Detect thumbnail tier change
        let oldMaxSize = gridThumbnailMaxSize
        currentCellSize = clamped
        let newMaxSize = gridThumbnailMaxSize

        // Update layout (invalidateLayout only — NOT reloadData, ~1-5ms for 1000+ items)
        let updateLayout = {
            self.flowLayout.itemSize = self.currentItemSize
            self.updateSpaceAroundLayout()
            self.collectionView.collectionViewLayout?.invalidateLayout()
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.allowsImplicitAnimation = true
                updateLayout()
            }
        } else {
            updateLayout()
        }

        // Tier changed: cancel in-flight tasks (prevent stale resolution writeback)
        // and progressively reload visible thumbnails at new tier resolution.
        // No reloadData() — old thumbnails stay visible until new ones are ready.
        if oldMaxSize != newMaxSize {
            cancelPendingThumbnailTasks()
            reloadVisibleThumbnails()
        }

        // Sync current size to subviews for delta calculation
        collectionView.currentCellSize = clamped
        gridScrollView.currentCellSize = clamped

        // Sync slider without triggering its action handler
        isUpdatingSliderProgrammatically = true
        sizeSlider.doubleValue = Double(clamped)
        isUpdatingSliderProgrammatically = false

        // Notify for persistence
        onCellSizeDidChange?(clamped)
    }

    @objc private func sliderValueChanged(_ sender: NSSlider) {
        guard !isUpdatingSliderProgrammatically else { return }
        applyItemSize(CGFloat(sender.doubleValue))
    }

    // MARK: - Configuration

    func configure(items: [ImageItem], currentIndex: Int, loader: ImageLoader) {
        self.items = items
        self.currentIndex = currentIndex
        self.cachedVisibleCenter = currentIndex
        self.loader = loader

        // Sample folder images to determine optimal cell aspect ratio (~5ms for 50 images)
        currentAspectRatio = sampleMedianAspectRatio(from: items)

        // Ensure layout uses current cell size (supports re-open with last size in same session)
        flowLayout.itemSize = currentItemSize
        updateSpaceAroundLayout()
        collectionView.currentCellSize = currentCellSize
        gridScrollView.currentCellSize = currentCellSize

        collectionView.reloadData()

        // Scroll to current image and select it
        guard !items.isEmpty, currentIndex >= 0, currentIndex < items.count else { return }
        let indexPath = IndexPath(item: currentIndex, section: 0)

        // Defer scroll to after layout pass
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.collectionView.scrollToItems(
                at: [indexPath],
                scrollPosition: .centeredVertically
            )
            self.collectionView.selectionIndexPaths = [indexPath]
        }
    }

    func makeCollectionViewFirstResponder() {
        window?.makeFirstResponder(collectionView)
    }

    /// Cancel all in-flight thumbnail tasks and clear the grid-local cache.
    private func cancelAndClearThumbnails() {
        for (_, task) in thumbnailTasks { task.cancel() }
        thumbnailTasks.removeAll()
        gridThumbnails.removeAll()
    }

    /// Number of items beyond visible range to keep in cache (buffer zone).
    private let thumbnailCacheBuffer = 50

    /// Maximum number of grid thumbnails to cache, based on system RAM.
    /// Formula: 5% of physical memory / estimated per-image size (720×720×4 ≈ 2MB).
    /// Example: 8GB Mac → 400MB budget → ~200 thumbnails.
    private let gridThumbnailMaxCount: Int = {
        let budget = Double(ProcessInfo.processInfo.physicalMemory) * 0.05
        let side = Double(Constants.quickGridThumbnailSize3)
        let estimatedImageBytes = side * side * 4
        return max(50, Int(budget / estimatedImageBytes))
    }()

    /// Evict cached thumbnails outside visible + buffer window.
    /// Keeps entries within [minVisible - buffer, maxVisible + buffer].
    func evictNonVisibleThumbnails(visibleIndices: Set<Int>) {
        guard let minVis = visibleIndices.min(), let maxVis = visibleIndices.max() else { return }
        evictNonVisibleThumbnails(minVisible: minVis, maxVisible: maxVis)
    }

    private func evictNonVisibleThumbnails(minVisible: Int, maxVisible: Int) {
        let keepMin = max(0, minVisible - thumbnailCacheBuffer)
        let keepMax = maxVisible + thumbnailCacheBuffer
        let keepRange = keepMin...keepMax
        for key in gridThumbnails.keys where !keepRange.contains(key) {
            gridThumbnails.removeValue(forKey: key)
        }
    }

    /// Cancel in-flight thumbnail tasks for items not in the visible set.
    /// Thin wrapper preserving existing test API; internally delegates to cancelTasksOutsideKeepSet.
    func cancelNonVisibleTasks(visibleIndices: Set<Int>) {
        cancelTasksOutsideKeepSet(visibleIndices)
    }

    /// Cancel in-flight thumbnail tasks only (keep cached images for smooth tier transitions).
    private func cancelPendingThumbnailTasks() {
        for (_, task) in thumbnailTasks { task.cancel() }
        thumbnailTasks.removeAll()
    }

    /// Reload thumbnails for visible cells at the current tier resolution.
    /// Clears entire gridThumbnails cache so off-screen cells also reload at new tier
    /// when they scroll into view. Old images stay in cells (no reloadData = no flash).
    private func reloadVisibleThumbnails() {
        gridThumbnails.removeAll()
        let visibleItems = collectionView.indexPathsForVisibleItems()
        let indices = visibleItems.map(\.item)
        let center = indices.isEmpty ? 0 : (indices.min()! + indices.max()!) / 2
        cachedVisibleCenter = center
        for indexPath in visibleItems {
            if let cell = collectionView.item(at: indexPath) as? QuickGridCell {
                loadThumbnail(for: indexPath.item, cell: cell, visibleCenter: center)
            }
        }
    }

    /// Clear cached thumbnails and cancel pending tasks without releasing loader.
    /// Used when folder content changes and the grid will be reconfigured.
    private func resetScrollState() {
        scrollDirection = .none
        lastClipOriginY = 0
        cancelSweepThrottle = NavigationThrottle(interval: 0.05)  // Reset so first scroll event isn't eaten
    }

    func clearCache() {
        generationID += 1
        cancelAndClearThumbnails()
        resetScrollState()
        // No need to clear ImageLoader.thumbnailCache — composite key (URL + maxSize)
        // prevents cross-contamination between grid and main view thumbnails.
    }

    /// Cancel all pending thumbnail tasks and release cached thumbnails.
    /// Note: Task.detached inside ImageLoader.loadThumbnail won't propagate cancellation,
    /// but thumbnail decodes are fast (~16ms for JPEG) so the impact is minimal.
    func cleanup() {
        cancelAndClearThumbnails()
        resetScrollState()
        memoryPressureMonitor.stop()
        // Composite key in ImageLoader prevents cross-contamination —
        // no need to clear thumbnailCache on grid dismiss.
        loader = nil
    }

    // MARK: - Keyboard (ESC via responder chain; Enter handled by GridCollectionView)

    override func cancelOperation(_ sender: Any?) {
        delegate?.quickGridViewDidRequestClose(self)
    }

    // MARK: - Thumbnail Loading

    private func loadThumbnail(for index: Int, cell: QuickGridCell,
                               priority: TaskPriority = .userInitiated,
                               visibleCenter: Int = 0) {
        // Already cached locally
        if let cached = gridThumbnails[index] {
            cell.setThumbnail(cached)
            return
        }

        let item = items[index]
        // PDF items: no thumbnail support (MVP)
        guard !item.isPDF else { return }

        // Cancel existing task for this index if any
        thumbnailTasks[index]?.cancel()

        guard let loader else { return }

        let maxSize = gridThumbnailMaxSize
        let taskPriority = priority
        let distance = abs(index - visibleCenter)
        let gen = generationID
        thumbnailTasks[index] = Task { [weak self] in
            let result = await loader.loadThumbnail(at: item.url, maxSize: maxSize,
                                                     priority: taskPriority,
                                                     throttlePriority: distance)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard self.generationID == gen else { return }  // Stale folder — discard

            if let image = result?.image {
                self.gridThumbnails[index] = image
                self.enforceGridThumbnailCap(currentIndex: self.cachedVisibleCenter)

                // Verify cell is still displaying the same item before updating
                if let visibleCell = self.collectionView.item(at: IndexPath(item: index, section: 0)) as? QuickGridCell {
                    visibleCell.setThumbnail(image)
                }
            }

            self.thumbnailTasks.removeValue(forKey: index)
        }
    }

    // MARK: - NSCollectionViewDataSource

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let cellStart = CFAbsoluteTimeGetCurrent()
        let cell = collectionView.makeItem(
            withIdentifier: QuickGridCell.identifier,
            for: indexPath
        )
        guard let gridCell = cell as? QuickGridCell else { return cell }
        let index = indexPath.item
        gridCell.configure(item: items[index])
        gridCell.isCurrentImage = (index == currentIndex)

        // Load thumbnail (from cache or async)
        // Use cachedVisibleCenter (updated at 20Hz by scroll handler)
        let loadStart = CFAbsoluteTimeGetCurrent()
        loadThumbnail(for: index, cell: gridCell, visibleCenter: cachedVisibleCenter)
        let loadMs = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000

        let totalMs = (CFAbsoluteTimeGetCurrent() - cellStart) * 1000
        if totalMs > 1.0 {  // Only log slow cells (>1ms)
            GridPerfLog.log(String(format: "cellForItem[%d]: total=%.2fms | loadThumb=%.2fms | cached=%@",
                                   index, totalMs, loadMs, gridThumbnails[index] != nil ? "YES" : "NO"))
        }

        return gridCell
    }

    // MARK: - NSCollectionViewDelegate

    func collectionView(
        _ collectionView: NSCollectionView,
        didSelectItemsAt indexPaths: Set<IndexPath>
    ) {
        guard let indexPath = indexPaths.first else { return }
        if let event = NSApp.currentEvent, event.type == .leftMouseUp {
            // Mouse click: navigate directly (view will change, no scroll needed)
            delegate?.quickGridView(self, didSelectItemAt: indexPath.item)
        } else {
            // Keyboard navigation: scroll selected item into view
            if let attrs = collectionView.layoutAttributesForItem(at: indexPath) {
                collectionView.scrollToVisible(attrs.frame)
            }
        }
    }

    // MARK: - Drag & Drop

    private var cachedValidURLs: [URL] = []

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        cachedValidURLs = URLFilter.extractImageURLs(from: sender.draggingPasteboard)
        return cachedValidURLs.isEmpty ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        cachedValidURLs = []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = cachedValidURLs
        cachedValidURLs = []
        guard !urls.isEmpty else { return false }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.quickGridView(self, didReceiveDrop: urls)
        }
        return true
    }
}
