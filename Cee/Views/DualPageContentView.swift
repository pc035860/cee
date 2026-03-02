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
    /// Pages are height-normalized: both rendered at the same visual height (the taller one's height).
    /// The shorter page is scaled up proportionally so spreads look uniform.
    /// When `isRTL` is true, trailing page is placed on the left (manga reading order).
    func configureDouble(leadingSize: NSSize, trailingSize: NSSize, isRTL: Bool = false) {
        if leadingPage.superview == nil { addSubview(leadingPage) }
        if trailingPage == nil {
            let tv = ImageContentView()
            addSubview(tv)
            trailingPage = tv
        }

        let maxH = max(leadingSize.height, trailingSize.height)

        // Normalize heights: scale each page so its rendered height equals maxH
        let leadingScale = (leadingSize.height > 0) ? maxH / leadingSize.height : 1.0
        let trailingScale = (trailingSize.height > 0) ? maxH / trailingSize.height : 1.0
        let renderedLeadingW = leadingSize.width * leadingScale
        let renderedTrailingW = trailingSize.width * trailingScale
        let totalW = renderedLeadingW + renderedTrailingW

        if isRTL {
            // RTL: trailing page on the left, leading page on the right
            trailingPage!.frame = NSRect(
                x: 0, y: 0,
                width: renderedTrailingW, height: maxH
            )
            leadingPage.frame = NSRect(
                x: renderedTrailingW, y: 0,
                width: renderedLeadingW, height: maxH
            )
        } else {
            // LTR: leading page on the left, trailing page on the right
            leadingPage.frame = NSRect(
                x: 0, y: 0,
                width: renderedLeadingW, height: maxH
            )
            trailingPage!.frame = NSRect(
                x: renderedLeadingW, y: 0,
                width: renderedTrailingW, height: maxH
            )
        }
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
