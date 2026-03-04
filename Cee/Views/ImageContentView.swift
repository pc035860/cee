import AppKit

class ImageContentView: NSView {

    // MARK: - Phase 6: Loading State (replaces isError from Phase 5)

    enum LoadingState { case idle, loading, loaded, error }

    /// Set imageFileName before loadingState so the accessibility label is included in the notification.
    var imageFileName: String?

    var loadingState: LoadingState = .idle {
        didSet { updateAccessibilityState() }
    }

    /// Backward-compatible bridge for Phase 5 callers
    var isError: Bool {
        get { loadingState == .error }
        set { loadingState = newValue ? .error : .idle }
    }

    private func updateAccessibilityState() {
        switch loadingState {
        case .idle:    setAccessibilityIdentifier("imageContent-idle")
        case .loading: setAccessibilityIdentifier("imageContent-loading")
        case .loaded:  setAccessibilityIdentifier("imageContent-loaded")
        case .error:   setAccessibilityIdentifier("imageContent-error")
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        if let imageFileName {
            setAccessibilityLabel(imageFileName)
        }
        // 通知 accessibility 系統狀態已改變，讓 XCUITest 能查詢到最新 identifier
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    // MARK: - Properties

    var image: NSImage? {
        didSet {
            guard image !== oldValue else { return }
            if let image {
                cachedCGImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                if cachedCGImage == nil {
                    DebugCentering.log("WARNING: NSImage -> CGImage conversion returned nil for \(image)")
                }
            } else {
                cachedCGImage = nil
            }
            needsDisplay = true  // triggers updateLayer()
            invalidateIntrinsicContentSize()
        }
    }

    /// Controls layer magnification filter (upscaling).
    /// Setting this does NOT trigger needsDisplay — GPU handles it immediately.
    var layerScalingFilter: CALayerContentsFilter = .linear {
        didSet {
            guard layerScalingFilter != oldValue else { return }
            layer?.magnificationFilter = layerScalingFilter
        }
    }

    /// Controls layer minification filter (downscaling).
    /// Setting this does NOT trigger needsDisplay — GPU handles it immediately.
    var layerMinificationFilter: CALayerContentsFilter = .linear {
        didSet {
            guard layerMinificationFilter != oldValue else { return }
            layer?.minificationFilter = layerMinificationFilter
        }
    }

    /// Cached CGImage to avoid repeated NSImage -> CGImage conversion.
    private var cachedCGImage: CGImage?

    override var intrinsicContentSize: NSSize {
        image?.size ?? .zero
    }

    // MARK: - Layer-backed rendering

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.contentsGravity = .resize
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.contents = cachedCGImage
        layer.contentsScale = window?.backingScaleFactor ?? 2.0
        // contentsGravity set once in init; filters managed by didSet.
    }

    /// Refresh contentsScale when dragging window across Retina/non-Retina displays.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }
}
