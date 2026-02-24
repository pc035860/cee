import AppKit

class ImageContentView: NSView {
    var image: NSImage? { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }
    var interpolation: NSImageInterpolation = .default { didSet { needsDisplay = true } }
    var showPixels: Bool = false { didSet { needsDisplay = true } }

    /// Phase 5: 圖片載入失敗時顯示 placeholder
    var isError: Bool = false { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize {
        image?.size ?? .zero
    }

    override func draw(_ dirtyRect: NSRect) {
        // Phase 5: 錯誤 placeholder（檔案缺失 / 格式不支援 / 空資料夾）
        if image == nil && isError {
            drawErrorPlaceholder(in: bounds)
            return
        }

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

    // MARK: - Error Placeholder

    private func drawErrorPlaceholder(in rect: NSRect) {
        // 深灰色背景
        NSColor(white: 0.15, alpha: 1.0).setFill()
        NSBezierPath.fill(rect)

        // 居中灰色文字
        let text = "Cannot display image"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor(white: 0.6, alpha: 1.0)
        ]
        let size = text.size(withAttributes: attrs)
        let origin = NSPoint(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2
        )
        text.draw(at: origin, withAttributes: attrs)
    }
}
