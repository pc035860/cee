import AppKit

@MainActor
protocol QuickGridViewDelegate: AnyObject {
    func quickGridView(_ view: QuickGridView, didSelectItemAt index: Int)
    func quickGridViewDidRequestClose(_ view: QuickGridView)
}

final class QuickGridView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {

    weak var delegate: QuickGridViewDelegate?

    // MARK: - UI

    private let gridScrollView = NSScrollView()
    private let collectionView = NSCollectionView()
    private var items: [ImageItem] = []
    private var currentIndex: Int = 0

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
            width: Constants.quickGridCellSize,
            height: Constants.quickGridCellSize
        )
        layout.minimumInteritemSpacing = Constants.quickGridSpacing
        layout.minimumLineSpacing = Constants.quickGridSpacing
        layout.sectionInset = NSEdgeInsets(
            top: Constants.quickGridInset,
            left: Constants.quickGridInset,
            bottom: Constants.quickGridInset,
            right: Constants.quickGridInset
        )

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

        // Scroll view wrapping collection view
        gridScrollView.documentView = collectionView
        gridScrollView.hasVerticalScroller = true
        gridScrollView.hasHorizontalScroller = false
        gridScrollView.drawsBackground = false
        gridScrollView.autohidesScrollers = true
        gridScrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gridScrollView)

        NSLayoutConstraint.activate([
            gridScrollView.topAnchor.constraint(equalTo: topAnchor),
            gridScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            gridScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            gridScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Configuration

    func configure(items: [ImageItem], currentIndex: Int, loader: ImageLoader) {
        self.items = items
        self.currentIndex = currentIndex
        self.loader = loader
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

    /// Cancel all pending thumbnail tasks and release cached thumbnails.
    func cleanup() {
        for (_, task) in thumbnailTasks { task.cancel() }
        thumbnailTasks.removeAll()
        gridThumbnails.removeAll()
        loader = nil
    }

    // MARK: - ESC via responder chain

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
        delegate?.quickGridView(self, didSelectItemAt: indexPath.item)
    }
}
