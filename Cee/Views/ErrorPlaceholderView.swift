import AppKit

/// Overlay view displayed when image loading fails (file missing, unsupported format, empty folder).
/// Placed on top of the scroll view, not inside the document view.
class ErrorPlaceholderView: NSView {
    private let label: NSTextField

    /// Update the displayed message text.
    func setMessage(_ text: String) {
        label.stringValue = text
    }

    override init(frame frameRect: NSRect) {
        label = NSTextField(labelWithString: "Cannot display image")
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.textColor = NSColor(white: 0.5, alpha: 1.0)
        label.translatesAutoresizingMaskIntoConstraints = false
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 1.0).cgColor
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}
