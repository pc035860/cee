import AppKit

/// 連續捲動模式中的單一圖片 slot view
/// 使用 layer-backed GPU 渲染 (wantsUpdateLayer = true)
class ImageSlotView: NSView {
    // MARK: - Properties
    var imageIndex: Int = -1
    private var cachedCGImage: CGImage?
    private var loadTask: Task<Void, Never>?

    // MARK: - Initialization
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.contentsGravity = .resize
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    // MARK: - Layer-backed Rendering
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.contents = cachedCGImage
        layer.contentsScale = window?.backingScaleFactor ?? 2.0
    }

    // MARK: - Backing Properties Change
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    // MARK: - Configuration
    func setImage(_ image: NSImage?) {
        cachedCGImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        needsDisplay = true
    }

    func setLoadTask(_ task: Task<Void, Never>) {
        loadTask?.cancel()
        loadTask = task
    }

    // MARK: - Reuse
    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        cachedCGImage = nil
        imageIndex = -1
        needsDisplay = true
    }
}
