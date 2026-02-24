import AppKit

class ImageContentView: NSView {
    var image: NSImage? { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }
    var interpolation: NSImageInterpolation = .default { didSet { needsDisplay = true } }
    var showPixels: Bool = false { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize {
        image?.size ?? .zero
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let ctx = NSGraphicsContext.current else { return }

        // 縮放品質控制
        // 注意：NSGraphicsContext.imageInterpolation 在 macOS Big Sur+ Retina 已失效
        // 必須使用 CGContext 層級的 interpolationQuality
        let cgCtx = ctx.cgContext
        if showPixels {
            cgCtx.interpolationQuality = .none
        } else {
            switch interpolation {
            case .none:    cgCtx.interpolationQuality = .none
            case .low:     cgCtx.interpolationQuality = .low
            case .high:    cgCtx.interpolationQuality = .high
            default:       cgCtx.interpolationQuality = .medium
            }
        }

        // NSImage.draw(in:) 自動處理 macOS 座標系（原點左下）
        image.draw(in: bounds)
    }
}
