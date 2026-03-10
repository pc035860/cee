import AppKit
import ImageIO

/// Scroll direction for prefetch pipeline.
enum ScrollDirection: Equatable {
    case up, down, none
}

private enum QuickGridPinchDebug {
    static let gestureFrameBudgetMs: Double = 8
    static let gestureFrameSevereBudgetMs: Double = 12

    static let isEnabled: Bool = {
        let processInfo = ProcessInfo.processInfo
        if processInfo.environment["CEE_DEBUG_QUICKGRID_PINCH"] == "1" {
            return true
        }
        return processInfo.arguments.contains("--debug-quickgrid-pinch")
    }()

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = message()
        GridPerfLog.log("pinch: \(text)")
        fputs("[QuickGridPinch] \(text)\n", stderr)
    }

    static func measureIfSlow(_ label: String, thresholdMs: Double = 4, body: () -> Void) {
        guard isEnabled else { return body() }
        let start = CFAbsoluteTimeGetCurrent()
        body()
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        guard ms >= thresholdMs else { return }
        log(String(format: "%@ slow=%.2fms", label, ms))
    }

    static func measure<T>(_ label: String, body: () -> T) -> T {
        guard isEnabled else { return body() }
        let start = CFAbsoluteTimeGetCurrent()
        let result = body()
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        log(String(format: "%@=%.2fms", label, ms))
        return result
    }

    @discardableResult
    static func timed<T>(_ body: () -> T) -> (result: T, ms: Double) {
        let start = CFAbsoluteTimeGetCurrent()
        let result = body()
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        return (result, ms)
    }

    static func phaseText(_ phase: NSEvent.Phase) -> String {
        var parts: [String] = []
        if phase.contains(.began) { parts.append("began") }
        if phase.contains(.stationary) { parts.append("stationary") }
        if phase.contains(.changed) { parts.append("changed") }
        if phase.contains(.ended) { parts.append("ended") }
        if phase.contains(.cancelled) { parts.append("cancelled") }
        if phase.contains(.mayBegin) { parts.append("mayBegin") }
        return parts.isEmpty ? "[]" : parts.joined(separator: "|")
    }
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
final class GridScrollView: NSScrollView {
    private final class VisibleScroller: NSScroller {
        override class func scrollerWidth(for controlSize: NSControl.ControlSize,
                                          scrollerStyle: NSScroller.Style) -> CGFloat {
            12
        }

        override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
            let inset = slotRect.insetBy(dx: 2, dy: 2)
            NSColor.white.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: inset, xRadius: 4, yRadius: 4).fill()
        }

        override func drawKnob() {
            let knobRect = rect(for: .knob).insetBy(dx: 2, dy: 2)
            guard knobRect.width > 0, knobRect.height > 0 else { return }
            NSColor.white.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: knobRect, xRadius: 4, yRadius: 4).fill()
        }
    }

    var onCmdScroll: ((CGFloat) -> Void)?
    /// Read by scrollWheel to compute delta-based size. Updated by QuickGridView.
    var currentCellSize: CGFloat = Constants.quickGridCellSize
    /// Controls vertical scroller visibility. Set by QuickGridView.updateScrollerVisibility().
    var wantsVerticalScroller: Bool = false {
        didSet {
            guard wantsVerticalScroller != oldValue else { return }
            super.hasVerticalScroller = wantsVerticalScroller
            verticalScroller?.isHidden = !wantsVerticalScroller
            verticalScroller?.alphaValue = wantsVerticalScroller ? 1 : 0
            verticalScroller?.needsDisplay = true
            tile()
            reflectScrolledClipView(contentView)
            needsLayout = true
        }
    }

    // NSCollectionView re-enables scrollers during layout passes / reloadData.
    // Override to control visibility via wantsVerticalScroller property.
    override var hasVerticalScroller: Bool {
        get { wantsVerticalScroller }
        set { /* ignore — NSCollectionView tries to enable this */ }
    }
    override var hasHorizontalScroller: Bool {
        get { false }
        set { /* ignore */ }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        allowsMagnification = false  // defensive: prevent pinch event consumption
        scrollerStyle = .overlay  // overlay: doesn't take space, avoids border-scrollbar geometry conflict
        autohidesScrollers = false
        contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 12)  // reserve 12pt so cells aren't covered by overlay scroller
        scrollerKnobStyle = .light
        drawsBackground = false
        super.hasHorizontalScroller = false
        super.hasVerticalScroller = false
        verticalScroller = VisibleScroller(frame: .zero)
        verticalScroller?.controlSize = .regular
        verticalScroller?.alphaValue = 0
        verticalScroller?.isHidden = true
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
    /// Parameters: newSize, gesture phase (began/changed/ended/cancelled)
    var onCellSizeChange: ((CGFloat, NSEvent.Phase) -> Void)?
    /// Callback for animated cell size changes (keyboard shortcuts).
    var onAnimatedCellSizeChange: ((CGFloat) -> Void)?
    /// Callback for PageDown key
    var onPageDown: (() -> Void)?
    /// Callback for PageUp key
    var onPageUp: (() -> Void)?
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
        case 121:  // PageDown
            onPageDown?()
        case 116:  // PageUp
            onPageUp?()
        case 49 where modifiers == []:  // Space (same as PageDown)
            onPageDown?()
        default:
            super.keyDown(with: event)
        }
    }

    override func magnify(with event: NSEvent) {
        // Incremental: newSize = currentSize * (1 + delta)
        // Matches ImageScrollView pattern (magnification + event.magnification)
        let newSize = currentCellSize * (1 + event.magnification)
        // Combine phase + momentumPhase for complete gesture state
        let effectivePhase = event.phase.union(event.momentumPhase)
        QuickGridPinchDebug.log(
            String(
                format: "magnify current=%.1f mag=%.4f phase=%@ momentum=%@ effective=%@ target=%.1f",
                currentCellSize,
                event.magnification,
                QuickGridPinchDebug.phaseText(event.phase),
                QuickGridPinchDebug.phaseText(event.momentumPhase),
                QuickGridPinchDebug.phaseText(effectivePhase),
                newSize
            )
        )
        onCellSizeChange?(newSize, effectivePhase)
        // Do NOT call super — prevents event propagating to ImageScrollView
    }

    // Block NSCollectionView's internal scroll-to-selection during keyboard nav.
    // scrollToItems(at:scrollPosition:) is the modern index-path-mode scroll path.
    // didSelectItemsAt fires synchronously inside super.move*(), so our smooth
    // animation starts from the correct pre-scroll position without interference.
    private var suppressAutoScroll = false

    override func scrollToItems(at indexPaths: Set<IndexPath>,
                                scrollPosition: NSCollectionView.ScrollPosition) {
        guard !suppressAutoScroll else { return }
        super.scrollToItems(at: indexPaths, scrollPosition: scrollPosition)
    }

    override func moveUp(_ sender: Any?) {
        suppressAutoScroll = true
        super.moveUp(sender)
        suppressAutoScroll = false
    }
    override func moveDown(_ sender: Any?) {
        suppressAutoScroll = true
        super.moveDown(sender)
        suppressAutoScroll = false
    }
    override func moveLeft(_ sender: Any?) {
        suppressAutoScroll = true
        super.moveLeft(sender)
        suppressAutoScroll = false
    }
    override func moveRight(_ sender: Any?) {
        suppressAutoScroll = true
        super.moveRight(sender)
        suppressAutoScroll = false
    }
}

final class QuickGridView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {

    weak var delegate: QuickGridViewDelegate?

    /// When true, scrolls cursor card to center of viewport after zoom ends.
    /// Controlled by "Scroll to Cursor After Zoom" menu item (default off).
    var scrollAfterZoomEnabled: Bool = false

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
    /// Tracks which decode tier each cached thumbnail belongs to.
    private var gridThumbnailSizes: [Int: CGFloat] = [:]
    /// Test-only: number of cached grid thumbnails.
    var gridThumbnailCount: Int { gridThumbnails.count }

    /// Test-only accessor for gridScrollView (for scrollbar tests).
    var _testGridScrollView: GridScrollView { gridScrollView }

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
        gridThumbnailSizes[index] = gridThumbnailMaxSize
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
        gridThumbnailSizes[index] = gridThumbnailMaxSize
    }

    /// Test-only: simulate memory pressure response.
    func _testHandleMemoryPressure(_ level: MemoryPressureMonitor.PressureLevel) {
        handleMemoryPressure(level)
    }

    /// Test-only: set cell size without clamping for tier0 logic tests.
    func _testSetCellSizeForTesting(_ size: CGFloat) {
        currentCellSize = size
    }

    // MARK: - Deferred Tier Change (Pinch Optimization)

    /// Deferred tier change reload work item (prevents pinch interruption)
    private var tierChangeWorkItem: DispatchWorkItem?
    /// Debounced scroll-cursor-into-view work item (300ms, coalesces multiple zoom-end triggers)
    private var scrollCursorWorkItem: DispatchWorkItem?
    /// Pending tier change to reload after pinch ends
    private var pendingTierChange: Bool = false
    /// Test-only: count of gesture-phase flushes skipped to avoid pinch interruption.
    private(set) var deferredGestureSyncLayoutCount: Int = 0

    /// Test-only: check if tier change is pending
    var _testPendingTierChange: Bool { pendingTierChange }
    /// Test-only: check if work item is scheduled
    var _testTierChangeWorkItemScheduled: Bool { tierChangeWorkItem != nil }
    /// Test-only: cached decode tier for a given index.
    func _testCachedThumbnailSize(forIndex index: Int) -> CGFloat? {
        gridThumbnailSizes[index]
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
            cancelAndClearThumbnails()
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
        Self.columnsPerRow(availableWidth: availableLayoutWidth, cellSize: currentCellSize)
    }

    private var availableLayoutWidth: CGFloat {
        gridScrollView.contentView.bounds.width
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

    /// Returns target origin.y to scroll item into view, or nil if already visible.
    /// Used by keyboard navigation. Static for unit testing.
    /// - Parameter edgeMargin: minimum pixels outside viewport before triggering scroll.
    ///   Prevents micro-jitter when item is within a few pixels of the viewport edge
    ///   (floating-point settle, or border alignment with scrollbar geometry).
    /// - Parameter centered: if true, scroll so the item is vertically centered in the viewport
    ///   (used by zoom-end path). If false, scroll just enough to bring item to the edge.
    static func scrollTargetYForItem(
        itemFrame: CGRect,
        visibleRect: CGRect,
        documentHeight: CGFloat,
        edgeMargin: CGFloat = 0,
        centered: Bool = false
    ) -> CGFloat? {
        let isBelow = itemFrame.maxY > visibleRect.maxY + edgeMargin
        let isAbove = itemFrame.minY < visibleRect.minY - edgeMargin
        guard isBelow || isAbove else {
            return nil  // already visible (within edgeMargin tolerance)
        }
        let maxScrollY = max(0, documentHeight - visibleRect.height)
        let targetY: CGFloat
        if centered {
            targetY = itemFrame.midY - visibleRect.height / 2
        } else if isBelow {
            targetY = itemFrame.maxY - visibleRect.height
        } else {
            targetY = itemFrame.minY
        }
        return max(0, min(targetY, maxScrollY))
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
                    self.gridThumbnailSizes[index] = maxSize
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
            gridThumbnailSizes.removeValue(forKey: key)
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
        // Note: Cannot access tierChangeWorkItem from nonisolated deinit.
        // Cleanup is handled in cleanup() which should be called before deinit.
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
        collectionView.onCellSizeChange = { [weak self] newSize, phase in
            self?.applyItemSize(newSize, phase: phase)
        }
        collectionView.onAnimatedCellSizeChange = { [weak self] newSize in
            self?.applyItemSize(newSize, animated: true, phase: [])  // immediate reload
        }
        gridScrollView.onCmdScroll = { [weak self] newSize in
            self?.applyItemSize(newSize, phase: [])  // immediate reload
        }

        // Wire PageUp/PageDown handlers
        collectionView.onPageDown = { [weak self] in
            self?.scrollGridPage(by: self?.gridScrollView.contentView.bounds.height ?? 0)
        }
        collectionView.onPageUp = { [weak self] in
            self?.scrollGridPage(by: -(self?.gridScrollView.contentView.bounds.height ?? 0))
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
        let available = availableLayoutWidth
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
        let width = availableLayoutWidth
        guard width != lastLayoutWidth else { return }

        // Capture anchor: real-time computation from current viewport (not cached, avoids stale state)
        let clipBounds = gridScrollView.contentView.bounds
        let viewportCenterY = clipBounds.midY
        let anchorIP = IndexPath(item: cachedVisibleCenter, section: 0)
        // Capture fractional offset: how far viewport center is from anchor item's top
        let oldFraction: CGFloat
        if let oldAttrs = collectionView.layoutAttributesForItem(at: anchorIP) {
            let rawFraction = (viewportCenterY - oldAttrs.frame.minY) / oldAttrs.frame.height
            oldFraction = max(0, min(1, rawFraction))
        } else {
            oldFraction = 0.5
        }

        updateSpaceAroundLayout()
        collectionView.collectionViewLayout?.invalidateLayout()
        updateScrollerVisibility()

        // Restore: place anchor item at the same fractional position in viewport
        collectionView.layoutSubtreeIfNeeded()
        if let attrs = collectionView.layoutAttributesForItem(at: anchorIP) {
            let newAnchorY = attrs.frame.minY + oldFraction * attrs.frame.height
            let clipHeight = gridScrollView.contentView.bounds.height
            let targetOriginY = newAnchorY - clipHeight / 2
            let docHeight = collectionView.frame.height
            let maxOriginY = max(0, docHeight - clipHeight)
            let clampedY = min(max(0, targetOriginY), maxOriginY)
            gridScrollView.contentView.scroll(to: NSPoint(x: 0, y: clampedY))
            gridScrollView.reflectScrolledClipView(gridScrollView.contentView)
        }
    }

    /// Update vertical scrollbar visibility based on content overflow.
    /// Called after frame changes, configuration, and cell size changes.
    private func updateScrollerVisibility() {
        let documentHeight = collectionView.frame.height
        let visibleHeight = gridScrollView.contentView.bounds.height
        let previousWidth = availableLayoutWidth
        gridScrollView.wantsVerticalScroller = documentHeight > visibleHeight
        if availableLayoutWidth != previousWidth {
            updateSpaceAroundLayout()
            collectionView.collectionViewLayout?.invalidateLayout()
        }
    }

    // MARK: - PageUp/PageDown Scroll

    /// Scroll grid by one page. Positive delta = visual down, negative = visual up.
    private func scrollGridPage(by delta: CGFloat) {
        let clipView = gridScrollView.contentView
        var origin = clipView.bounds.origin
        let documentHeight = collectionView.frame.height
        let visibleHeight = clipView.bounds.height
        let maxScrollY = max(0, documentHeight - visibleHeight)

        // NSCollectionView uses flipped coordinates: y=0 is visual top
        origin.y += delta
        origin.y = max(0, min(maxScrollY, origin.y))
        clipView.setBoundsOrigin(origin)
        gridScrollView.reflectScrolledClipView(clipView)
        makeCollectionViewFirstResponder()
    }

    func pageDown() {
        scrollGridPage(by: gridScrollView.contentView.bounds.height)
    }

    func pageUp() {
        scrollGridPage(by: -gridScrollView.contentView.bounds.height)
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
    /// Normally only invalidates layout. Tier changes are committed progressively
    /// after the active interaction path settles.
    /// - Parameters:
    ///   - newSize: Target cell size (will be clamped to min/max range)
    ///   - animated: Whether to animate the layout change
    ///   - phase: Gesture phase (for pinch optimization). Empty means non-gesture trigger.
    func applyItemSize(_ newSize: CGFloat, animated: Bool = false, phase: NSEvent.Phase = []) {
        let applyStart = CFAbsoluteTimeGetCurrent()
        if phase.contains(.began) {
            tierChangeWorkItem?.cancel()
            tierChangeWorkItem = nil
            pendingTierChange = false
        }

        let isActiveGesturePhase = !phase.isEmpty && !phase.contains(.ended) && !phase.contains(.cancelled)

        let clamped = max(Constants.quickGridMinCellSize,
                          min(Constants.quickGridMaxCellSize, newSize))

        QuickGridPinchDebug.log(
            String(
                format: "apply size old=%.1f input=%.1f clamped=%.1f animated=%@ phase=%@ pending=%@ tier=%.0f",
                currentCellSize,
                newSize,
                clamped,
                animated ? "yes" : "no",
                QuickGridPinchDebug.phaseText(phase),
                pendingTierChange ? "yes" : "no",
                gridThumbnailMaxSize
            )
        )

        if clamped == currentCellSize {
            if phase.contains(.ended) || phase.contains(.cancelled) {
                if pendingTierChange {
                    QuickGridPinchDebug.log("apply unchanged-size gesture end -> schedule deferred tier reload")
                    scheduleDeferredTierChangeReload()
                }
                // Even if size didn't change, zoom end must scroll cursor card back into viewport.
                // Covers: pinch-to-boundary release, and momentum .ended with near-zero magnification.
                scheduleScrollCursorIntoView()
            }
            return
        }

        // Detect thumbnail tier change
        let oldMaxSize = gridThumbnailMaxSize
        currentCellSize = clamped
        let newMaxSize = gridThumbnailMaxSize

        if oldMaxSize != newMaxSize {
            QuickGridPinchDebug.log(
                String(
                    format: "tier crossing %.0f -> %.0f phase=%@",
                    oldMaxSize,
                    newMaxSize,
                    QuickGridPinchDebug.phaseText(phase)
                )
            )
        }

        // Update layout (invalidateLayout only — NOT reloadData, ~1-5ms for 1000+ items)
        let updateLayout = {
            let itemSizeMs = QuickGridPinchDebug.timed {
                self.flowLayout.itemSize = self.currentItemSize
            }.ms
            let spaceAroundMs = QuickGridPinchDebug.timed {
                self.updateSpaceAroundLayout()
            }.ms
            let invalidateMs = QuickGridPinchDebug.timed {
                self.collectionView.collectionViewLayout?.invalidateLayout()
            }.ms
            QuickGridPinchDebug.log(
                String(
                    format: "pinch layout itemSize=%.2fms spaceAround=%.2fms invalidate=%.2fms",
                    itemSizeMs,
                    spaceAroundMs,
                    invalidateMs
                )
            )
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

        // Tier changed
        if oldMaxSize != newMaxSize {
            tierChangeWorkItem?.cancel()
            tierChangeWorkItem = nil

            if phase.isEmpty {
                QuickGridPinchDebug.log("tier change without gesture -> immediate visible reload")
                cancelPendingThumbnailTasks()
                reloadVisibleThumbnails(forceReloadVisible: true)
            } else {
                pendingTierChange = true
                QuickGridPinchDebug.log("tier change during gesture -> defer reload")
                if phase.contains(.ended) || phase.contains(.cancelled) {
                    scheduleDeferredTierChangeReload()
                }
            }
        }

        // Sync current size to subviews for delta calculation
        collectionView.currentCellSize = clamped
        gridScrollView.currentCellSize = clamped

        // Sync slider without triggering its action handler
        isUpdatingSliderProgrammatically = true
        sizeSlider.doubleValue = Double(clamped)
        isUpdatingSliderProgrammatically = false

        let persistMs = QuickGridPinchDebug.timed {
            onCellSizeDidChange?(clamped)
        }.ms
        QuickGridPinchDebug.log(String(format: "pinch onCellSizeDidChange=%.2fms", persistMs))

        if isActiveGesturePhase {
            deferredGestureSyncLayoutCount += 1
            QuickGridPinchDebug.log(
                String(
                    format: "gesture phase=%@ skip sync flush count=%d",
                    QuickGridPinchDebug.phaseText(phase),
                    deferredGestureSyncLayoutCount
                )
            )
        } else {
            QuickGridPinchDebug.measure("pinch layoutSubtreeIfNeeded") {
                collectionView.layoutSubtreeIfNeeded()
            }
            QuickGridPinchDebug.measure("pinch updateScrollerVisibility") {
                updateScrollerVisibility()
            }
            // After layout settles, scroll cursor card back into view if it drifted out during zoom
            scheduleScrollCursorIntoView()
        }

        let totalMs = (CFAbsoluteTimeGetCurrent() - applyStart) * 1000
        let budgetLabel: String
        if isActiveGesturePhase && totalMs >= QuickGridPinchDebug.gestureFrameSevereBudgetMs {
            budgetLabel = "gesture-frame-severe"
        } else if isActiveGesturePhase && totalMs >= QuickGridPinchDebug.gestureFrameBudgetMs {
            budgetLabel = "gesture-frame-over"
        } else {
            budgetLabel = "applyItemSize"
        }
        QuickGridPinchDebug.log(
            String(
                format: "%@ total=%.2fms phase=%@ activeGesture=%@ cachedCenter=%d tasks=%d pending=%@",
                budgetLabel,
                totalMs,
                QuickGridPinchDebug.phaseText(phase),
                isActiveGesturePhase ? "yes" : "no",
                cachedVisibleCenter,
                thumbnailTasks.count,
                pendingTierChange ? "yes" : "no"
            )
        )
    }

    /// Debounced scroll of cursor card into viewport (300ms), centering the item.
    /// Coalesces rapid zoom-end triggers (multiple applyItemSize paths, momentum tail events).
    private func scheduleScrollCursorIntoView() {
        guard scrollAfterZoomEnabled else { return }
        scrollCursorWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  let indexPath = self.collectionView.selectionIndexPaths.first else { return }
            self.collectionView.layoutSubtreeIfNeeded()
            self.scrollItemIntoView(at: indexPath, animated: false, centered: true)
        }
        scrollCursorWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Schedule tier reload after the gesture lifecycle fully settles.
    private func scheduleDeferredTierChangeReload() {
        tierChangeWorkItem?.cancel()
        QuickGridPinchDebug.log("schedule deferred tier reload")
        tierChangeWorkItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            defer { self.tierChangeWorkItem = nil }
            guard self.pendingTierChange else { return }
            let visibleCount = self.collectionView.indexPathsForVisibleItems().count
            QuickGridPinchDebug.log(
                String(
                    format: "run deferred tier reload visible=%d tasks=%d pending=%@ tier=%.0f",
                    visibleCount,
                    self.thumbnailTasks.count,
                    self.pendingTierChange ? "yes" : "no",
                    self.gridThumbnailMaxSize
                )
            )
            QuickGridPinchDebug.measure("pinch deferred cancelPendingThumbnailTasks") {
                self.cancelPendingThumbnailTasks()
            }
            QuickGridPinchDebug.measure("pinch deferred reloadVisibleThumbnails") {
                self.reloadVisibleThumbnails(forceReloadVisible: true)
            }
            self.pendingTierChange = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.quickGridTierChangeDelay, execute: tierChangeWorkItem!)
    }

    @objc private func sliderValueChanged(_ sender: NSSlider) {
        guard !isUpdatingSliderProgrammatically else { return }
        applyItemSize(CGFloat(sender.doubleValue), phase: [])  // immediate reload
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
            self.collectionView.layoutSubtreeIfNeeded()
            self.updateScrollerVisibility()
            self.scrollItemIntoView(at: indexPath, animated: false, centered: true)
            self.collectionView.selectionIndexPaths = [indexPath]
        }
    }

    func makeCollectionViewFirstResponder() {
        window?.makeFirstResponder(collectionView)
    }

    /// Cancel all in-flight thumbnail tasks and clear the grid-local cache.
    private func cancelAndClearThumbnails() {
        cancelPendingThumbnailTasks()
        gridThumbnails.removeAll()
        gridThumbnailSizes.removeAll()
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
            gridThumbnailSizes.removeValue(forKey: key)
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
    /// Existing images remain onscreen until the replacement tier finishes loading.
    private func reloadVisibleThumbnails(forceReloadVisible: Bool = false) {
        let visibleItems = collectionView.indexPathsForVisibleItems()
        let indices = visibleItems.map(\.item)
        let center = indices.isEmpty ? 0 : (indices.min()! + indices.max()!) / 2
        cachedVisibleCenter = center
        QuickGridPinchDebug.log(
            String(
                format: "reloadVisible force=%@ visible=%d center=%d tier=%.0f",
                forceReloadVisible ? "yes" : "no",
                visibleItems.count,
                center,
                gridThumbnailMaxSize
            )
        )
        for indexPath in visibleItems {
            if let cell = collectionView.item(at: indexPath) as? QuickGridCell {
                loadThumbnail(
                    for: indexPath.item,
                    cell: cell,
                    visibleCenter: center,
                    forceReload: forceReloadVisible
                )
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
        tierChangeWorkItem?.cancel()
        tierChangeWorkItem = nil
        scrollCursorWorkItem?.cancel()
        scrollCursorWorkItem = nil
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
                               visibleCenter: Int = 0,
                               forceReload: Bool = false) {
        let targetMaxSize = gridThumbnailMaxSize

        if let cached = gridThumbnails[index],
           gridThumbnailSizes[index] == targetMaxSize,
           !forceReload {
            cell.setThumbnail(cached)
            return
        }

        if let stale = gridThumbnails[index] {
            cell.setThumbnail(stale)
        }

        let item = items[index]
        // PDF items: no thumbnail support (MVP)
        guard !item.isPDF else { return }

        // Cancel existing task for this index if any
        thumbnailTasks[index]?.cancel()

        guard let loader else { return }

        let distance = abs(index - visibleCenter)
        let gen = generationID
        thumbnailTasks[index] = Task { [weak self] in
            let result = await loader.loadThumbnail(at: item.url, maxSize: targetMaxSize,
                                                     priority: priority,
                                                     throttlePriority: distance)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard self.generationID == gen else { return }  // Stale folder — discard

            if let image = result?.image {
                self.gridThumbnails[index] = image
                self.gridThumbnailSizes[index] = targetMaxSize
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

    /// Scroll selected item into view with smooth animation (keyboard navigation).
    /// Manual scroll computation + NSAnimationContext avoids conflict with NSCollectionView's internal scroll.
    /// - Parameter centered: if true, center the item vertically (used by zoom-end path).
    private func scrollItemIntoView(at indexPath: IndexPath, animated: Bool = true, centered: Bool = false) {
        guard let attrs = collectionView.layoutAttributesForItem(at: indexPath) else { return }
        let clipView = gridScrollView.contentView
        let visibleRect = clipView.bounds
        let itemFrame = attrs.frame

        guard let targetY = Self.scrollTargetYForItem(
            itemFrame: itemFrame,
            visibleRect: visibleRect,
            documentHeight: collectionView.frame.height,
            edgeMargin: Constants.quickGridSpacing,  // 4pt — prevents micro-jitter at viewport edges
            centered: centered
        ) else { return }

        var targetOrigin = visibleRect.origin
        targetOrigin.y = targetY

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                context.timingFunction = CAMediaTimingFunction(name: .linear)
                clipView.animator().setBoundsOrigin(targetOrigin)
            }
        } else {
            clipView.setBoundsOrigin(targetOrigin)
        }
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
            // Keyboard navigation: smooth scroll selected item into view
            scrollItemIntoView(at: indexPath)
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
