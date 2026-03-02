import AppKit

/// Container view for dual-page spread display.
/// Always used as `scrollView.documentView`.
/// Single page mode: one child, frame = image size (identical to old behavior).
/// Dual page mode: two children side by side, frame = composite size.
class DualPageContentView: NSView {
    let leadingPage = ImageContentView()
    private(set) var trailingPage: ImageContentView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - Configuration

    /// Configure for a single page (or single-page spread).
    func configureSingle(imageSize: NSSize) {
        trailingPage?.removeFromSuperview()
        trailingPage = nil
        if leadingPage.superview == nil { addSubview(leadingPage) }
        leadingPage.frame = NSRect(origin: .zero, size: imageSize)
        self.frame = NSRect(origin: .zero, size: imageSize)
    }

    /// Configure for double spread with two pages side by side.
    /// Shorter page is vertically centered against the taller one.
    func configureDouble(leadingSize: NSSize, trailingSize: NSSize) {
        if leadingPage.superview == nil { addSubview(leadingPage) }
        if trailingPage == nil {
            let tv = ImageContentView()
            addSubview(tv)
            trailingPage = tv
        }

        let maxH = max(leadingSize.height, trailingSize.height)
        let totalW = leadingSize.width + trailingSize.width

        // Vertical centering for unequal heights
        let leadingY = (maxH - leadingSize.height) / 2.0
        let trailingY = (maxH - trailingSize.height) / 2.0

        leadingPage.frame = NSRect(
            x: 0, y: leadingY,
            width: leadingSize.width, height: leadingSize.height
        )
        trailingPage!.frame = NSRect(
            x: leadingSize.width, y: trailingY,
            width: trailingSize.width, height: trailingSize.height
        )
        self.frame = NSRect(origin: .zero, size: NSSize(width: totalW, height: maxH))
    }

    /// The composite content size (for fitting calculations).
    var compositeSize: NSSize { frame.size }

    // MARK: - Scaling Filters

    /// Sync scaling filters to both pages (GPU-side, no needsDisplay).
    func setScalingFilters(magnification: CALayerContentsFilter, minification: CALayerContentsFilter) {
        leadingPage.layerScalingFilter = magnification
        leadingPage.layerMinificationFilter = minification
        trailingPage?.layerScalingFilter = magnification
        trailingPage?.layerMinificationFilter = minification
    }
}
