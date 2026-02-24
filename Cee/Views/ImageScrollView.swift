import AppKit

// MARK: - Delegate Protocol

@MainActor
protocol ImageScrollViewDelegate: AnyObject {
    func scrollViewDidReachBottom(_ scrollView: ImageScrollView)
    func scrollViewDidReachTop(_ scrollView: ImageScrollView)
    func scrollViewMagnificationDidChange(_ scrollView: ImageScrollView, magnification: CGFloat)
    // Phase 2: keyboard navigation callbacks
    func scrollViewRequestNextImage(_ scrollView: ImageScrollView)
    func scrollViewRequestPreviousImage(_ scrollView: ImageScrollView)
    func scrollViewRequestFirstImage(_ scrollView: ImageScrollView)
    func scrollViewRequestLastImage(_ scrollView: ImageScrollView)
    func scrollViewRequestPageDown(_ scrollView: ImageScrollView)
}

// MARK: - ImageScrollView

class ImageScrollView: NSScrollView {
    weak var scrollDelegate: ImageScrollViewDelegate?

    private var isAtBottom = false
    private var isAtTop = false
    private let edgeThreshold: CGFloat = Constants.scrollEdgeThreshold

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

        // Phase 6: UI test accessibility anchor
        // Note: NSScrollView already has .scrollArea role — only set identifier
        setAccessibilityIdentifier("imageScrollView")

        // 監聽 clip view 邊界變化，追蹤是否到達頂底
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(boundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: contentView
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Edge Detection

    @objc private func boundsDidChange(_ notification: Notification) {
        guard let docView = documentView else { return }
        let clipBounds = contentView.bounds
        let docFrame = docView.frame
        // macOS 座標系：原點左下角
        isAtBottom = clipBounds.maxY >= docFrame.height - edgeThreshold
        isAtTop = clipBounds.minY <= edgeThreshold
    }

    // MARK: - Scroll Wheel (Edge → Page Turn)

    override func scrollWheel(with event: NSEvent) {
        let wasAtBottom = isAtBottom
        let wasAtTop = isAtTop

        super.scrollWheel(with: event)

        // Natural Scrolling 修正：
        // isDirectionInvertedFromDevice == true → deltaY 已被系統反轉（「自然」捲動）
        // natural: deltaY < 0 = 使用者向下滑動 (content 向上) = 捲動到底方向
        // traditional: deltaY > 0 = 捲動到底方向
        let isNatural = event.isDirectionInvertedFromDevice
        let delta = event.scrollingDeltaY
        let intentDown = isNatural ? (delta < 0) : (delta > 0)
        let intentUp   = isNatural ? (delta > 0) : (delta < 0)

        if wasAtBottom && intentDown {
            scrollDelegate?.scrollViewDidReachBottom(self)
        }
        if wasAtTop && intentUp {
            scrollDelegate?.scrollViewDidReachTop(self)
        }
    }

    // MARK: - Keyboard (first responder)

    override var acceptsFirstResponder: Bool { true }

    /// 鍵盤事件在此攔截，避免 NSScrollView 內部消化方向鍵/Space/PageUp/PageDown
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 124: scrollDelegate?.scrollViewRequestNextImage(self)      // → RightArrow
        case 123: scrollDelegate?.scrollViewRequestPreviousImage(self)  // ← LeftArrow
        case 49:  scrollDelegate?.scrollViewRequestPageDown(self)       // Space
        case 115: scrollDelegate?.scrollViewRequestFirstImage(self)     // Home
        case 119: scrollDelegate?.scrollViewRequestLastImage(self)      // End
        case 121: scrollDelegate?.scrollViewRequestNextImage(self)      // PageDown
        case 116: scrollDelegate?.scrollViewRequestPreviousImage(self)  // PageUp
        case 53:  // Esc — 退出全螢幕（僅在全螢幕模式下有效）
            if window?.styleMask.contains(.fullScreen) == true {
                window?.toggleFullScreen(nil)
            } else {
                super.keyDown(with: event)
            }
        default:  super.keyDown(with: event)
        }
    }

    // MARK: - Pinch Zoom

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

    // MARK: - Scroll Helpers

    /// 切換圖片後回到頂部（macOS 座標系：maxY = 頂部）
    func scrollToTop() {
        guard let docView = documentView else { return }
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
