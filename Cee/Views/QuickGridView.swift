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

    func configure(items: [ImageItem], currentIndex: Int) {
        self.items = items
        self.currentIndex = currentIndex
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

    // MARK: - ESC via responder chain

    override func cancelOperation(_ sender: Any?) {
        delegate?.quickGridViewDidRequestClose(self)
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
        gridCell.configure(item: items[indexPath.item])
        gridCell.isCurrentImage = (indexPath.item == currentIndex)
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
