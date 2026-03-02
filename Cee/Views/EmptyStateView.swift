import AppKit
import UniformTypeIdentifiers

/// Overlay view displayed when no folder is loaded.
/// Supports drag-and-drop to open image files.
final class EmptyStateView: NSView {

    // MARK: - Delegate

    @MainActor
    protocol Delegate: AnyObject {
        func emptyStateViewDidReceiveDrop(_ view: EmptyStateView, urls: [URL])
    }

    weak var delegate: Delegate?

    // MARK: - UI Elements

    private let stackView = NSStackView()
    private let iconView = NSImageView()
    private let primaryLabel = NSTextField(labelWithString: "Drop images here to view")
    private let secondaryLabel = NSTextField(labelWithString: "Or use File \u{2039} Open (\u{2318}O)")
    private let dashedBorderLayer = CAShapeLayer()

    // MARK: - State

    private var isDragOver = false {
        didSet {
            updateDragHighlight()
        }
    }

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func setupUI() {
        wantsLayer = true

        // Background
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        // Stack view
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 12
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        // Icon
        let config = NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)
        if let image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            iconView.image = image
            iconView.contentTintColor = NSColor.secondaryLabelColor
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(iconView)

        // Primary label
        primaryLabel.font = .systemFont(ofSize: 16)
        primaryLabel.textColor = NSColor.secondaryLabelColor
        primaryLabel.alignment = .center
        primaryLabel.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(primaryLabel)

        // Secondary label
        secondaryLabel.font = .systemFont(ofSize: 13)
        secondaryLabel.textColor = NSColor.tertiaryLabelColor
        secondaryLabel.alignment = .center
        secondaryLabel.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(secondaryLabel)

        // Layout
        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 40),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -40),
        ])

        // Dashed border layer (initially hidden)
        dashedBorderLayer.fillColor = nil
        dashedBorderLayer.strokeColor = NSColor.controlAccentColor.cgColor
        dashedBorderLayer.lineWidth = 2
        dashedBorderLayer.lineDashPattern = [8, 4]
        dashedBorderLayer.isHidden = true
        layer?.addSublayer(dashedBorderLayer)
    }

    override func layout() {
        super.layout()
        updateDashedBorderPath()
    }

    private func updateDashedBorderPath() {
        let inset: CGFloat = 8
        let rect = bounds.insetBy(dx: inset, dy: inset)
        dashedBorderLayer.frame = bounds
        dashedBorderLayer.path = CGPath(
            roundedRect: rect,
            cornerWidth: 8,
            cornerHeight: 8,
            transform: nil
        )
    }

    private func updateDragHighlight() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.allowsImplicitAnimation = true
            dashedBorderLayer.isHidden = !isDragOver
        }
    }

    // MARK: - Drag and Drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = extractImageURLs(from: sender.draggingPasteboard)
        isDragOver = !urls.isEmpty
        return urls.isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = extractImageURLs(from: sender.draggingPasteboard)
        return urls.isEmpty ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDragOver = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDragOver = false
        let urls = extractImageURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.emptyStateViewDidReceiveDrop(self, urls: urls)
        }
        return true
    }

    // MARK: - URL Extraction

    private func extractImageURLs(from pasteboard: NSPasteboard) -> [URL] {
        guard let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] else {
            return []
        }
        return urls.filter { isSupported($0) }
    }

    private func isSupported(_ url: URL) -> Bool {
        guard let uttype = UTType(filenameExtension: url.pathExtension) else {
            return false
        }
        return uttype.conforms(to: .image) || uttype.conforms(to: .pdf)
    }
}
