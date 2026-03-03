import AppKit

/// Shared drag-drop highlight style used by EmptyStateView and ImageScrollView.
enum DragHighlightStyle {

    /// Apply the standard drag highlight appearance to a shape layer.
    static func apply(to layer: CAShapeLayer) {
        layer.fillColor = NSColor.black.withAlphaComponent(0.3).cgColor
        layer.strokeColor = NSColor.controlAccentColor.cgColor
        layer.lineWidth = 2
        layer.lineDashPattern = [8, 4]
        layer.isHidden = true
    }
}
