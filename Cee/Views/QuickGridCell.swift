import AppKit

final class QuickGridCell: NSCollectionViewItem {

    static let identifier = NSUserInterfaceItemIdentifier("QuickGridCell")

    // MARK: - UI Elements

    private let thumbnailView = NSImageView()
    private let filenameLabel = NSTextField(labelWithString: "")
    private var highlightLayer: CALayer?

    /// Whether this cell represents the image currently shown in the main viewer.
    var isCurrentImage = false {
        didSet { updateHighlight() }
    }

    // MARK: - Lifecycle

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 4
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        self.view = container

        setupThumbnailView()
        setupFilenameLabel()
    }

    private func setupThumbnailView() {
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.isHidden = true  // Hidden until thumbnail is loaded (WU2)
        view.addSubview(thumbnailView)
        // Let drag events pass through to parent QuickGridView
        // (NSImageView registers drag types by default, intercepting file drops)
        thumbnailView.unregisterDraggedTypes()

        NSLayoutConstraint.activate([
            thumbnailView.topAnchor.constraint(equalTo: view.topAnchor, constant: 2),
            thumbnailView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            thumbnailView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
            thumbnailView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -2),
        ])
    }

    private func setupFilenameLabel() {
        filenameLabel.font = .systemFont(ofSize: 9)
        filenameLabel.textColor = NSColor.secondaryLabelColor
        filenameLabel.alignment = .center
        filenameLabel.lineBreakMode = .byTruncatingMiddle
        filenameLabel.maximumNumberOfLines = 2
        filenameLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(filenameLabel)

        NSLayoutConstraint.activate([
            filenameLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            filenameLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            filenameLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
        ])
    }

    // MARK: - Configuration

    func configure(item: ImageItem) {
        filenameLabel.stringValue = item.fileName
        filenameLabel.isHidden = false
        thumbnailView.image = nil
        thumbnailView.isHidden = true
    }

    /// Set thumbnail image (called by WU2 thumbnail loading).
    func setThumbnail(_ image: NSImage?) {
        thumbnailView.image = image
        thumbnailView.isHidden = (image == nil)
        filenameLabel.isHidden = (image != nil)
    }

    // MARK: - Selection

    override var isSelected: Bool {
        didSet { updateHighlight() }
    }

    private func updateHighlight() {
        guard let layer = view.layer else { return }

        if isCurrentImage || isSelected {
            if highlightLayer == nil {
                let hl = CALayer()
                hl.borderWidth = 2
                hl.cornerRadius = 4
                hl.frame = layer.bounds
                hl.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
                layer.addSublayer(hl)
                highlightLayer = hl
            }
            // Current image: accent color. Selection cursor: white.
            highlightLayer?.borderColor = isCurrentImage
                ? NSColor.controlAccentColor.cgColor
                : NSColor.white.cgColor
            highlightLayer?.isHidden = false
        } else {
            highlightLayer?.isHidden = true
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailView.image = nil
        thumbnailView.isHidden = true
        filenameLabel.stringValue = ""
        filenameLabel.isHidden = false
        isCurrentImage = false
        highlightLayer?.isHidden = true
    }
}
