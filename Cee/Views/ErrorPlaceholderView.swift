import AppKit

/// Overlay view displayed when image loading fails (file missing, unsupported format, empty folder).
/// Placed on top of the scroll view, not inside the document view.
class ErrorPlaceholderView: NSView {
    private let label: NSTextField

    override init(frame frameRect: NSRect) {
        label = NSTextField(labelWithString: "Cannot display image")
        label.font = .systemFont(ofSize: 14, weight: .regular)
        label.textColor = NSColor(white: 0.6, alpha: 1.0)
        label.translatesAutoresizingMaskIntoConstraints = false
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.15, alpha: 1.0).cgColor
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}
