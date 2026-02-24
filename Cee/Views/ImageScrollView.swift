import AppKit

// MARK: - Delegate Protocol (used in Phase 2)

protocol ImageScrollViewDelegate: AnyObject {
    func scrollViewDidReachBottom(_ scrollView: ImageScrollView)
    func scrollViewDidReachTop(_ scrollView: ImageScrollView)
    func scrollViewMagnificationDidChange(_ scrollView: ImageScrollView, magnification: CGFloat)
}

// MARK: - ImageScrollView

class ImageScrollView: NSScrollView {
    weak var scrollDelegate: ImageScrollViewDelegate?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        allowsMagnification = true
        minMagnification = Constants.minMagnification
        maxMagnification = Constants.maxMagnification
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        backgroundColor = .black
    }

    /// 以游標位置為中心的 Pinch Zoom
    override func magnify(with event: NSEvent) {
        let point = contentView.convert(event.locationInWindow, from: nil)
        let newMag = magnification + event.magnification
        setMagnification(
            max(minMagnification, min(maxMagnification, newMag)),
            centeredAt: point
        )
        scrollDelegate?.scrollViewMagnificationDidChange(self, magnification: magnification)
    }

    /// 切換圖片後回到頂部
    func scrollToTop() {
        guard let docView = documentView else { return }
        // macOS 座標系：maxY = 頂部
        let topPoint = NSPoint(x: 0, y: docView.frame.height)
        contentView.scroll(to: topPoint)
        reflectScrolledClipView(contentView)
    }

    /// 切換圖片後跳到底部
    func scrollToBottom() {
        contentView.scroll(to: .zero)
        reflectScrolledClipView(contentView)
    }
}
