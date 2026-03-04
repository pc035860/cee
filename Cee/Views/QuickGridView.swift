import AppKit

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

    override func barRect(flipped: Bool) -> NSRect {
        let full = super.barRect(flipped: flipped)
        let y = full.midY - trackHeight / 2
        return NSRect(x: full.origin.x, y: y, width: full.width, height: trackHeight)
    }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let barRect = self.barRect(flipped: flipped)
        let proportion = CGFloat((doubleValue - minValue) / (maxValue - minValue))
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
        let proportion = CGFloat((doubleValue - minValue) / (maxValue - minValue))
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
    /// Unified callback for cell size changes (pinch gesture).
    var onCellSizeChange: ((CGFloat) -> Void)?
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
            onCellSizeChange?(currentCellSize + 10)
        case 27 where modifiers == .command:  // Cmd+- (ANSI keyCode 27) — shrink by 10pt
            onCellSizeChange?(currentCellSize - 10)
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
    /// Active thumbnail loading tasks (keyed by item index)
    private var thumbnailTasks: [Int: Task<Void, Never>] = [:]

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor

        // Collection view layout
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(
            width: currentCellSize,
            height: currentCellSize
        )
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

        // Wire resize handlers (pinch + Cmd+Scroll)
        collectionView.onCellSizeChange = { [weak self] newSize in
            self?.applyItemSize(newSize)
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
        gridScrollView.hasVerticalScroller = false
        gridScrollView.hasHorizontalScroller = false
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

            sizeSlider.leadingAnchor.constraint(equalTo: sliderContainer.leadingAnchor, constant: 8),
            sizeSlider.trailingAnchor.constraint(equalTo: sliderContainer.trailingAnchor, constant: -8),
            sizeSlider.centerYAnchor.constraint(equalTo: sliderContainer.centerYAnchor),
        ])

        registerForDraggedTypes([.fileURL])
    }

    // MARK: - Cell Size

    /// Apply a new cell size, clamped to the allowed range.
    /// Only invalidates layout — does NOT clear the thumbnail cache because
    /// the 240px source thumbnails are valid for the entire 80–200pt range
    /// and NSImageView handles the rescaling automatically.
    func applyItemSize(_ newSize: CGFloat) {
        let clamped = max(Constants.quickGridMinCellSize,
                          min(Constants.quickGridMaxCellSize, newSize))
        guard clamped != currentCellSize else { return }
        currentCellSize = clamped

        // Update layout (invalidateLayout only — NOT reloadData, ~1-5ms for 1000+ items)
        flowLayout.itemSize = NSSize(width: clamped, height: clamped)
        collectionView.collectionViewLayout?.invalidateLayout()

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
        self.loader = loader

        // Ensure layout uses current cell size (supports re-open with last size in same session)
        flowLayout.itemSize = NSSize(width: currentCellSize, height: currentCellSize)
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

    /// Clear cached thumbnails and cancel pending tasks without releasing loader.
    /// Used when folder content changes and the grid will be reconfigured.
    func clearCache() {
        for (_, task) in thumbnailTasks { task.cancel() }
        thumbnailTasks.removeAll()
        gridThumbnails.removeAll()
        if let loader {
            Task { await loader.clearThumbnailCache() }
        }
    }

    /// Cancel all pending thumbnail tasks and release cached thumbnails.
    /// Note: Task.detached inside ImageLoader.loadThumbnail won't propagate cancellation,
    /// but thumbnail decodes are fast (~16ms for JPEG) so the impact is minimal.
    func cleanup() {
        for (_, task) in thumbnailTasks { task.cancel() }
        thumbnailTasks.removeAll()
        gridThumbnails.removeAll()
        // Clear ImageLoader's thumbnailCache to prevent 240px grid thumbnails
        // from polluting the main view's 512px thumbnail fallback
        if let loader {
            Task { await loader.clearThumbnailCache() }
        }
        loader = nil
    }

    // MARK: - Keyboard (ESC via responder chain; Enter handled by GridCollectionView)

    override func cancelOperation(_ sender: Any?) {
        delegate?.quickGridViewDidRequestClose(self)
    }

    // MARK: - Thumbnail Loading

    private func loadThumbnail(for index: Int, cell: QuickGridCell) {
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

        thumbnailTasks[index] = Task { [weak self] in
            let result = await loader.loadThumbnail(at: item.url, maxSize: 240)
            guard !Task.isCancelled else { return }
            guard let self else { return }

            if let image = result?.image {
                self.gridThumbnails[index] = image

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
        let cell = collectionView.makeItem(
            withIdentifier: QuickGridCell.identifier,
            for: indexPath
        )
        guard let gridCell = cell as? QuickGridCell else { return cell }
        let index = indexPath.item
        gridCell.configure(item: items[index])
        gridCell.isCurrentImage = (index == currentIndex)

        // Load thumbnail (from cache or async)
        loadThumbnail(for: index, cell: gridCell)

        return gridCell
    }

    // MARK: - NSCollectionViewDelegate

    func collectionView(
        _ collectionView: NSCollectionView,
        didSelectItemsAt indexPaths: Set<IndexPath>
    ) {
        guard let indexPath = indexPaths.first else { return }
        // Only navigate on mouse click, not keyboard arrow selection.
        // Keyboard users confirm with Enter (handled in keyDown).
        if let event = NSApp.currentEvent, event.type == .leftMouseUp {
            delegate?.quickGridView(self, didSelectItemAt: indexPath.item)
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
