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
    var overscrollThreshold: CGFloat = 130  // default medium; VC updates from settings

    private var isAtBottom = false
    private var isAtTop = false
    private let edgeThreshold: CGFloat = Constants.scrollEdgeThreshold

    // Trackpad gesture state: 只有從邊緣開始的新手勢才能觸發切圖
    private var gestureBeganAtTop = false
    private var gestureBeganAtBottom = false
    private var pageTurnedThisGesture = false
    private var overscrollAccumulator: CGFloat = 0

    // 切圖後鎖死動量：抑制 scroll 事件直到冷卻結束
    private var pageTurnLockUntil: TimeInterval = 0
    private let pageTurnLockDuration: TimeInterval = 1.0

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
        scrollerStyle = .overlay
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        drawsBackground = true
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
        // macOS 非翻轉座標系：原點左下角，Y 軸向上
        // 視覺頂部 = 高 Y 值（maxY 靠近 docFrame.height）
        // 視覺底部 = 低 Y 值（minY 靠近 0）
        isAtTop = clipBounds.maxY >= docFrame.height - edgeThreshold
        isAtBottom = clipBounds.minY <= edgeThreshold
    }

    // MARK: - Scroll Wheel (Edge → Page Turn)

    override func scrollWheel(with event: NSEvent) {
        // 判斷是 trackpad（有 phase 生命週期）還是滑鼠滾輪（無 phase）
        let isTrackpad = event.phase != [] || event.momentumPhase != []

        // 切圖後鎖死：新手勢可以解鎖，否則吃掉事件不讓新圖被滑動
        if event.phase == .began {
            pageTurnLockUntil = 0  // 新手勢立即解鎖
        }
        if CACurrentMediaTime() < pageTurnLockUntil {
            return  // 鎖死期間，不呼叫 super，完全抑制動量
        }

        // Trackpad 手勢開始：記錄當下是否在邊緣
        if event.phase == .began {
            gestureBeganAtTop = isAtTop
            gestureBeganAtBottom = isAtBottom
            pageTurnedThisGesture = false
            overscrollAccumulator = 0
        }

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

        if isTrackpad {
            // Trackpad：必須從邊緣開始的手勢，累積門檻，每手勢最多切一張
            if pageTurnedThisGesture { return }

            if gestureBeganAtBottom && wasAtBottom && intentDown {
                overscrollAccumulator += abs(delta)
                if overscrollAccumulator >= overscrollThreshold {
                    pageTurnedThisGesture = true
                    pageTurnLockUntil = CACurrentMediaTime() + pageTurnLockDuration
                    scrollDelegate?.scrollViewDidReachBottom(self)
                }
            } else if gestureBeganAtTop && wasAtTop && intentUp {
                overscrollAccumulator += abs(delta)
                if overscrollAccumulator >= overscrollThreshold {
                    pageTurnedThisGesture = true
                    pageTurnLockUntil = CACurrentMediaTime() + pageTurnLockDuration
                    scrollDelegate?.scrollViewDidReachTop(self)
                }
            } else {
                overscrollAccumulator = 0
            }
        } else {
            // 滑鼠滾輪：每個 tick 獨立，在邊緣時觸發
            if wasAtBottom && intentDown {
                pageTurnLockUntil = CACurrentMediaTime() + pageTurnLockDuration
                scrollDelegate?.scrollViewDidReachBottom(self)
            } else if wasAtTop && intentUp {
                pageTurnLockUntil = CACurrentMediaTime() + pageTurnLockDuration
                scrollDelegate?.scrollViewDidReachTop(self)
            }
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
        let maxY = max(docView.frame.height - contentView.bounds.height, 0)
        let topPoint = NSPoint(x: 0, y: maxY)
        contentView.scroll(to: topPoint)
        reflectScrolledClipView(contentView)
    }

    /// 切換圖片後跳到底部
    func scrollToBottom() {
        contentView.scroll(to: .zero)
        reflectScrolledClipView(contentView)
    }
}
