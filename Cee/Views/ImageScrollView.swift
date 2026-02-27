import AppKit

// MARK: - Delegate Protocol

@MainActor
protocol ImageScrollViewDelegate: AnyObject {
    func scrollViewDidReachBottom(_ scrollView: ImageScrollView)
    func scrollViewDidReachTop(_ scrollView: ImageScrollView)
    func scrollViewMagnificationDidChange(
        _ scrollView: ImageScrollView,
        magnification: CGFloat,
        gesturePhase: NSEvent.Phase
    )
    // Phase 2: keyboard navigation callbacks
    func scrollViewRequestNextImage(_ scrollView: ImageScrollView)
    func scrollViewRequestPreviousImage(_ scrollView: ImageScrollView)
    func scrollViewRequestFirstImage(_ scrollView: ImageScrollView)
    func scrollViewRequestLastImage(_ scrollView: ImageScrollView)
    func scrollViewRequestPageDown(_ scrollView: ImageScrollView)
    func scrollViewRequestPageUp(_ scrollView: ImageScrollView)
}

// MARK: - ImageScrollView

class ImageScrollView: NSScrollView {
    weak var scrollDelegate: ImageScrollViewDelegate?
    var trackpadOverscrollThreshold: CGFloat = 130  // VC updates from settings
    var wheelOverscrollThreshold: CGFloat = 20      // VC updates from settings

    private var isAtBottom = false
    private var isAtTop = false
    private var isAtLeft = false
    private var isAtRight = false
    private let edgeThreshold: CGFloat = Constants.scrollEdgeThreshold

    // Trackpad gesture state: 只有從邊緣開始的新手勢才能觸發切圖
    private var gestureBeganAtTop = false
    private var gestureBeganAtBottom = false
    private var pageTurnedThisGesture = false
    private var overscrollAccumulator: CGFloat = 0

    // 切圖後鎖死動量：抑制 scroll 事件直到冷卻結束
    private var pageTurnLockUntil: TimeInterval = 0
    private let pageTurnLockDuration: TimeInterval = 1.0

    // 方向鍵邊緣翻頁防誤觸：到邊緣後需連續按 N 次同方向才翻頁
    private var edgePressCount: Int = 0
    private var edgePressDirection: UInt16 = 0
    private let edgePressThreshold: Int = 3
    private var edgeIndicatorFadeTimer: DispatchWorkItem?

    // Three-finger pan state
    private var threeFingerPanActive = false
    private var previousTouchPositions: [NSObject: NSPoint] = [:]

    // 邊緣翻頁進度視覺提示
    private enum Edge { case top, bottom, left, right }
    private lazy var topIndicator = makeEdgeIndicator(edge: .top)
    private lazy var bottomIndicator = makeEdgeIndicator(edge: .bottom)
    private lazy var leftIndicator = makeEdgeIndicator(edge: .left)
    private lazy var rightIndicator = makeEdgeIndicator(edge: .right)

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

        // Enable raw touch tracking for three-finger pan
        allowedTouchTypes = [.indirect]  // trackpad only
        wantsRestingTouches = false

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
        isAtLeft = clipBounds.minX <= edgeThreshold
        isAtRight = clipBounds.maxX >= docFrame.width - edgeThreshold
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
                if overscrollAccumulator >= trackpadOverscrollThreshold {
                    pageTurnedThisGesture = true
                    pageTurnLockUntil = CACurrentMediaTime() + pageTurnLockDuration
                    scrollDelegate?.scrollViewDidReachBottom(self)
                }
            } else if gestureBeganAtTop && wasAtTop && intentUp {
                overscrollAccumulator += abs(delta)
                if overscrollAccumulator >= trackpadOverscrollThreshold {
                    pageTurnedThisGesture = true
                    pageTurnLockUntil = CACurrentMediaTime() + pageTurnLockDuration
                    scrollDelegate?.scrollViewDidReachTop(self)
                }
            } else {
                overscrollAccumulator = 0
            }
        } else {
            // 滑鼠滾輪：累積門檻，達標才觸發（lock 1 秒防連續觸發）
            if wasAtBottom && intentDown {
                overscrollAccumulator += abs(delta)
                if overscrollAccumulator >= wheelOverscrollThreshold {
                    overscrollAccumulator = 0
                    pageTurnLockUntil = CACurrentMediaTime() + pageTurnLockDuration
                    scrollDelegate?.scrollViewDidReachBottom(self)
                }
            } else if wasAtTop && intentUp {
                overscrollAccumulator += abs(delta)
                if overscrollAccumulator >= wheelOverscrollThreshold {
                    overscrollAccumulator = 0
                    pageTurnLockUntil = CACurrentMediaTime() + pageTurnLockDuration
                    scrollDelegate?.scrollViewDidReachTop(self)
                }
            } else {
                overscrollAccumulator = 0
            }
        }
    }

    // NSScrollView 預設 becomeFirstResponder 回傳 false（它不打算自己接收鍵盤事件）
    // 我們需要攔截方向鍵/Space/PageUp/PageDown，所以必須覆寫為 true
    override func becomeFirstResponder() -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // 點擊後確保 scroll view 是 first responder（接收鍵盤事件）
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
    }

    // MARK: - Viewport Overflow Detection

    /// 判斷圖片（含 magnification）是否超出 viewport 各軸
    private var viewportOverflow: (horizontal: Bool, vertical: Bool) {
        guard let docView = documentView else { return (false, false) }
        let clipSize = contentView.bounds.size
        let docSize = docView.frame.size
        let eps: CGFloat = 1.0
        return (
            horizontal: docSize.width > clipSize.width + eps,
            vertical: docSize.height > clipSize.height + eps
        )
    }

    // MARK: - Programmatic Pan

    private func panLeft() {
        let clip = contentView
        let newX = max(clip.bounds.minX - Constants.arrowPanStep, 0)
        clip.scroll(to: NSPoint(x: newX, y: clip.bounds.minY))
        reflectScrolledClipView(clip)
    }

    private func panRight() {
        let clip = contentView
        guard let docView = documentView else { return }
        let maxX = max(docView.frame.width - clip.bounds.width, 0)
        let newX = min(clip.bounds.minX + Constants.arrowPanStep, maxX)
        clip.scroll(to: NSPoint(x: newX, y: clip.bounds.minY))
        reflectScrolledClipView(clip)
    }

    /// macOS unflipped: visual up = increase Y
    private func panUp() {
        let clip = contentView
        guard let docView = documentView else { return }
        let maxY = max(docView.frame.height - clip.bounds.height, 0)
        let newY = min(clip.bounds.minY + Constants.arrowPanStep, maxY)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: newY))
        reflectScrolledClipView(clip)
    }

    /// macOS unflipped: visual down = decrease Y
    private func panDown() {
        let clip = contentView
        let newY = max(clip.bounds.minY - Constants.arrowPanStep, 0)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: newY))
        reflectScrolledClipView(clip)
    }

    // MARK: - Edge Indicator (翻頁進度視覺提示)

    private static let indicatorThickness: CGFloat = 20

    private func makeEdgeIndicator(edge: Edge) -> CAGradientLayer {
        let layer = CAGradientLayer()
        layer.opacity = 0
        layer.isHidden = true
        layer.zPosition = 1000  // 浮在 NSScrollView 內部 clip view 之上
        // #F97068 coral accent
        let accent = NSColor(red: 249/255.0, green: 112/255.0, blue: 104/255.0, alpha: 0.9).cgColor
        let clear = NSColor.clear.cgColor
        // AppKit layer-backed: y=0 是視覺頂部（flipped）
        // 每條 indicator 的漸層方向：邊緣實色 → 內部透明
        switch edge {
        case .top:
            layer.colors = [accent, clear]
            layer.startPoint = CGPoint(x: 0.5, y: 0)  // 頂部邊緣
            layer.endPoint = CGPoint(x: 0.5, y: 1)    // 向內淡出
        case .bottom:
            layer.colors = [clear, accent]
            layer.startPoint = CGPoint(x: 0.5, y: 0)  // 內部
            layer.endPoint = CGPoint(x: 0.5, y: 1)    // 底部邊緣
        case .left:
            layer.colors = [accent, clear]
            layer.startPoint = CGPoint(x: 0, y: 0.5)  // 左邊緣
            layer.endPoint = CGPoint(x: 1, y: 0.5)    // 向內淡出
        case .right:
            layer.colors = [clear, accent]
            layer.startPoint = CGPoint(x: 0, y: 0.5)  // 內部
            layer.endPoint = CGPoint(x: 1, y: 0.5)    // 右邊緣
        }
        return layer
    }

    private func ensureIndicatorsAttached() {
        // wantsLayer 保證 self.layer 存在
        wantsLayer = true
        guard let root = layer else { return }
        for indicator in [topIndicator, bottomIndicator, leftIndicator, rightIndicator] {
            if indicator.superlayer == nil {
                root.addSublayer(indicator)
            }
        }
    }

    private func edgeForKeyCode(_ keyCode: UInt16) -> Edge {
        switch keyCode {
        case 125, 49, 121: return .bottom  // ↓, Space, PageDown
        case 126, 116:     return .top     // ↑, PageUp
        case 124:          return .right   // →
        case 123:          return .left    // ←
        default:           return .bottom
        }
    }

    private func indicatorLayer(for edge: Edge) -> CAGradientLayer {
        switch edge {
        case .top:    return topIndicator
        case .bottom: return bottomIndicator
        case .left:   return leftIndicator
        case .right:  return rightIndicator
        }
    }

    private func showEdgeIndicator(edge: Edge, progress: CGFloat) {
        ensureIndicatorsAttached()
        layoutEdgeIndicators()
        let layer = indicatorLayer(for: edge)
        layer.isHidden = false
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.1)
        layer.opacity = Float(min(progress, 1.0))
        CATransaction.commit()
        scheduleIndicatorFadeOut()
    }

    /// 排程自動淡出：每次 edge press 重置計時器，閒置 1.5 秒後淡出
    private func scheduleIndicatorFadeOut() {
        edgeIndicatorFadeTimer?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.resetEdgeState()
        }
        edgeIndicatorFadeTimer = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: task)
    }

    /// 重置所有邊緣狀態：隱藏 indicator + 清除計數
    private func resetEdgeState() {
        edgeIndicatorFadeTimer?.cancel()
        edgeIndicatorFadeTimer = nil
        edgePressCount = 0
        edgePressDirection = 0
        for indicator in [topIndicator, bottomIndicator, leftIndicator, rightIndicator] {
            guard !indicator.isHidden else { continue }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.3)
            indicator.opacity = 0
            CATransaction.commit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                indicator.isHidden = true
            }
        }
    }

    private func hideEdgeIndicators() {
        resetEdgeState()
    }

    private func layoutEdgeIndicators() {
        let t = Self.indicatorThickness
        let b = bounds
        // AppKit layer-backed: y=0 是視覺頂部（flipped）
        topIndicator.frame = CGRect(x: 0, y: 0, width: b.width, height: t)
        bottomIndicator.frame = CGRect(x: 0, y: b.height - t, width: b.width, height: t)
        leftIndicator.frame = CGRect(x: 0, y: 0, width: t, height: b.height)
        rightIndicator.frame = CGRect(x: b.width - t, y: 0, width: t, height: b.height)
    }

    override func layout() {
        super.layout()
        layoutEdgeIndicators()
    }

    // MARK: - Arrow Key Edge Press

    /// 邊緣按鍵計數器：到邊緣後需連續按 N 次同方向才觸發翻頁
    /// threshold 可覆蓋預設值（PageUp/PageDown 只需 1 次確認）
    private func handleEdgePress(keyCode: UInt16, threshold: Int? = nil, navigateAction: () -> Void) {
        if keyCode == edgePressDirection {
            edgePressCount += 1
        } else {
            // 方向改變：先隱藏舊 indicator 再重置
            resetEdgeState()
            edgePressDirection = keyCode
            edgePressCount = 1
        }
        let effectiveThreshold = threshold ?? edgePressThreshold
        let progress = CGFloat(edgePressCount) / CGFloat(effectiveThreshold)
        let edge = edgeForKeyCode(keyCode)
        showEdgeIndicator(edge: edge, progress: progress)
        if edgePressCount >= effectiveThreshold {
            edgePressCount = 0
            edgePressDirection = 0
            hideEdgeIndicators()
            navigateAction()
        }
    }

    // MARK: - Keyboard (first responder)

    override var acceptsFirstResponder: Bool { true }

    /// 鍵盤事件在此攔截，避免 NSScrollView 內部消化方向鍵/Space/PageUp/PageDown
    /// 方向鍵根據 viewport overflow 動態切換 pan 或 navigate
    /// 到邊緣時需連續按 N 次才翻頁，防止瀏覽長圖時誤觸
    override func keyDown(with event: NSEvent) {
        let overflow = viewportOverflow

        switch event.keyCode {
        case 124: // → RightArrow
            if overflow.horizontal {
                if !isAtRight {
                    panRight()
                    edgePressCount = 0
                    hideEdgeIndicators()
                } else {
                    handleEdgePress(keyCode: 124) { [weak self] in
                        guard let self else { return }
                        scrollDelegate?.scrollViewRequestNextImage(self)
                    }
                }
            } else {
                resetEdgeState()
                scrollDelegate?.scrollViewRequestNextImage(self)
            }

        case 123: // ← LeftArrow
            if overflow.horizontal {
                if !isAtLeft {
                    panLeft()
                    edgePressCount = 0
                    hideEdgeIndicators()
                } else {
                    handleEdgePress(keyCode: 123) { [weak self] in
                        guard let self else { return }
                        scrollDelegate?.scrollViewRequestPreviousImage(self)
                    }
                }
            } else {
                resetEdgeState()
                scrollDelegate?.scrollViewRequestPreviousImage(self)
            }

        case 125: // ↓ DownArrow
            if overflow.vertical {
                if !isAtBottom {
                    panDown()
                    edgePressCount = 0
                    hideEdgeIndicators()
                } else {
                    handleEdgePress(keyCode: 125) { [weak self] in
                        guard let self else { return }
                        scrollDelegate?.scrollViewRequestNextImage(self)
                    }
                }
            } else {
                resetEdgeState()
                scrollDelegate?.scrollViewRequestNextImage(self)
            }

        case 126: // ↑ UpArrow
            if overflow.vertical {
                if !isAtTop {
                    panUp()
                    edgePressCount = 0
                    hideEdgeIndicators()
                } else {
                    handleEdgePress(keyCode: 126) { [weak self] in
                        guard let self else { return }
                        scrollDelegate?.scrollViewRequestPreviousImage(self)
                    }
                }
            } else {
                resetEdgeState()
                scrollDelegate?.scrollViewRequestPreviousImage(self)
            }

        case 49, 121: // Space / PageDown
            if overflow.vertical && isAtBottom {
                handleEdgePress(keyCode: event.keyCode, threshold: 1) { [weak self] in
                    guard let self else { return }
                    scrollDelegate?.scrollViewRequestPageDown(self)
                }
            } else {
                edgePressCount = 0
                hideEdgeIndicators()
                scrollDelegate?.scrollViewRequestPageDown(self)
            }

        case 116: // PageUp
            if overflow.vertical && isAtTop {
                handleEdgePress(keyCode: 116, threshold: 1) { [weak self] in
                    guard let self else { return }
                    scrollDelegate?.scrollViewRequestPageUp(self)
                }
            } else {
                edgePressCount = 0
                hideEdgeIndicators()
                scrollDelegate?.scrollViewRequestPageUp(self)
            }

        case 115: scrollDelegate?.scrollViewRequestFirstImage(self)     // Home
        case 119: scrollDelegate?.scrollViewRequestLastImage(self)      // End
        case 53:  // Esc — 退出全螢幕（僅在全螢幕模式下有效）
            if window?.styleMask.contains(.fullScreen) == true {
                window?.toggleFullScreen(nil)
            } else {
                super.keyDown(with: event)
            }
        default:  super.keyDown(with: event)
        }
    }

    // MARK: - Three-Finger Pan (raw touch tracking)

    override func touchesBegan(with event: NSEvent) {
        let touches = event.touches(matching: .touching, in: self)
        if touches.count == 3 {
            threeFingerPanActive = true
            previousTouchPositions.removeAll()
            for touch in touches {
                let key = touch.identity as! NSObject
                previousTouchPositions[key] = touch.normalizedPosition
            }
        } else {
            super.touchesBegan(with: event)
        }
    }

    override func touchesMoved(with event: NSEvent) {
        let touches = event.touches(matching: .touching, in: self)

        guard touches.count == 3, threeFingerPanActive else {
            if !threeFingerPanActive {
                super.touchesMoved(with: event)
            }
            return
        }

        var totalDeltaX: CGFloat = 0
        var totalDeltaY: CGFloat = 0
        var matchedCount = 0

        for touch in touches {
            let key = touch.identity as! NSObject
            let currentPos = touch.normalizedPosition
            if let prevPos = previousTouchPositions[key] {
                let deviceSize = touch.deviceSize
                totalDeltaX += (currentPos.x - prevPos.x) * deviceSize.width
                totalDeltaY += (currentPos.y - prevPos.y) * deviceSize.height
                matchedCount += 1
            }
            previousTouchPositions[key] = currentPos
        }

        guard matchedCount > 0 else { return }
        let avgDeltaX = totalDeltaX / CGFloat(matchedCount)
        let avgDeltaY = totalDeltaY / CGFloat(matchedCount)
        performThreeFingerPan(deltaX: avgDeltaX, deltaY: avgDeltaY)
    }

    override func touchesEnded(with event: NSEvent) {
        let remaining = event.touches(matching: .touching, in: self)
        if remaining.count < 3 {
            resetThreeFingerPanState()
        }
        super.touchesEnded(with: event)
    }

    override func touchesCancelled(with event: NSEvent) {
        resetThreeFingerPanState()
        super.touchesCancelled(with: event)
    }

    private func performThreeFingerPan(deltaX: CGFloat, deltaY: CGFloat) {
        let clip = contentView
        guard let docView = documentView else { return }

        let docSize = docView.frame.size
        let clipSize = clip.bounds.size

        // 手指右移(+deltaX) → 內容左移 → origin.x 減少
        // 手指上移(+deltaY) → 內容下移 → origin.y 減少 (unflipped: y=0 at bottom)
        var newX = clip.bounds.origin.x - deltaX
        var newY = clip.bounds.origin.y - deltaY

        newX = max(0, min(newX, docSize.width - clipSize.width))
        newY = max(0, min(newY, docSize.height - clipSize.height))

        clip.scroll(to: NSPoint(x: newX, y: newY))
        reflectScrolledClipView(clip)
    }

    private func resetThreeFingerPanState() {
        threeFingerPanActive = false
        previousTouchPositions.removeAll()
    }

    // MARK: - Pinch Zoom

    /// 以 viewport 中心為中心的 Pinch Zoom
    override func magnify(with event: NSEvent) {
        let point = NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        let newMag = magnification + event.magnification
        setMagnification(
            max(minMagnification, min(maxMagnification, newMag)),
            centeredAt: point
        )
        scrollDelegate?.scrollViewMagnificationDidChange(
            self,
            magnification: magnification,
            gesturePhase: event.phase
        )
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
