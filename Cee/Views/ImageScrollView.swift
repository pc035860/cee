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
    /// amount: 1 = 單張, Option+方向鍵時 = Constants.optionKeyJumpAmount
    func scrollViewRequestNextImage(_ scrollView: ImageScrollView, amount: Int)
    func scrollViewRequestPreviousImage(_ scrollView: ImageScrollView, amount: Int)
    func scrollViewRequestFirstImage(_ scrollView: ImageScrollView)
    func scrollViewRequestLastImage(_ scrollView: ImageScrollView)
    func scrollViewRequestPageDown(_ scrollView: ImageScrollView)
    func scrollViewRequestPageUp(_ scrollView: ImageScrollView)
    /// 請求 context menu（右鍵選單）
    func contextMenu(for scrollView: ImageScrollView, event: NSEvent) -> NSMenu?
    /// Called when files are dropped onto the scroll view (Phase 2: browse-mode drag-drop)
    func scrollViewDidReceiveDrop(_ scrollView: ImageScrollView, urls: [URL])
    /// Toggle Quick Grid overlay (bare G key)
    func scrollViewRequestToggleQuickGrid(_ scrollView: ImageScrollView)
    /// Phase 3: Option+scroll 即將觸發導航（設定 isOptionScrolling flag）
    func scrollViewOptionScrollWillNavigate(_ scrollView: ImageScrollView)
    /// Phase 3: Option+scroll 導航完成後更新 HUD
    func scrollViewOptionScrollDidNavigate(_ scrollView: ImageScrollView)
}

// MARK: - Default Implementation
extension ImageScrollViewDelegate {
    func contextMenu(for scrollView: ImageScrollView, event: NSEvent) -> NSMenu? { nil }
    func scrollViewDidReceiveDrop(_ scrollView: ImageScrollView, urls: [URL]) {}
    func scrollViewRequestToggleQuickGrid(_ scrollView: ImageScrollView) {}
    func scrollViewOptionScrollWillNavigate(_ scrollView: ImageScrollView) {}
    func scrollViewOptionScrollDidNavigate(_ scrollView: ImageScrollView) {}
}

// MARK: - ImageScrollView

class ImageScrollView: NSScrollView {
    weak var scrollDelegate: ImageScrollViewDelegate?
    var trackpadOverscrollThreshold: CGFloat = 130  // VC updates from settings
    var wheelOverscrollThreshold: CGFloat = 20      // VC updates from settings
    /// When true, left/right arrow navigation is reversed (RTL manga reading order).
    var isRTLNavigation = false
    /// When true, left/right arrows navigate images (pan + edge-press or direct navigate).
    var arrowLeftRightNavigation = true
    /// When true, up/down arrows navigate images at edges (pan + edge-press or direct navigate).
    var arrowUpDownNavigation = false

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

    // Mouse drag pan state
    private var isMouseDragging = false
    private var lastDragPoint: NSPoint = .zero

    // Phase 3: Option+scroll fast navigation
    private var optionScrollAccumulator = OptionScrollAccumulator()

    // MARK: - Drag and Drop (Phase 2: Browse Mode)
    // URL extraction must happen synchronously because NSDraggingInfo is not Sendable
    // and cannot cross actor boundaries.
    // cachedValidURLs is only accessed on @MainActor (ImageScrollView is @MainActor isolated).
    private var cachedValidURLs: [URL] = []
    private var isDragOver = false {  // Hook for visual feedback work unit
        didSet {
            updateDragHighlight()
        }
    }

    // Drag highlight layer (Phase 2: Visual Feedback)
    private lazy var dragHighlightLayer = CAShapeLayer()

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
        automaticallyAdjustsContentInsets = false
        hasVerticalScroller = false
        hasHorizontalScroller = false
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

        // 視窗失焦時重置拖曳狀態，避免 cursor stack 殘留
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: nil
        )

        // Phase 2: Register for drag-drop (browse mode)
        registerForDraggedTypes([.fileURL])

        // Phase 2: Setup drag highlight layer
        setupDragHighlightLayer()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Bottom inset for drag highlight border (matches status bar height when visible)
    var dragBottomInset: CGFloat = 0

    private func setupDragHighlightLayer() {
        DragHighlightStyle.apply(to: dragHighlightLayer)
        dragHighlightLayer.zPosition = 1000  // Same as edge indicators
    }

    // MARK: - Window Notifications

    @objc private func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        if isMouseDragging {
            isMouseDragging = false
            NSCursor.pop()
        }
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
        // Cmd + scroll wheel = zoom (攔截在所有其他邏輯之前)
        if event.modifierFlags.contains(.command) {
            handleCmdScrollZoom(with: event)
            return
        }

        // Phase 3: Option+scroll 快速切圖（在 pageTurnLock 之前攔截，避免被鎖死阻擋）
        if event.modifierFlags.contains(.option) {
            handleOptionScrollNav(with: event)
            return
        }

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

    // MARK: - Mouse Drag Pan

    override func mouseDown(with event: NSEvent) {
        // 點擊後確保 scroll view 是 first responder（接收鍵盤事件）
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        // 只在無修飾鍵時啟動拖曳 pan（Cmd+click 等不觸發）
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isEmpty else {
            super.mouseDown(with: event)
            return
        }
        // 防護：清理上一次未結束的拖曳
        if isMouseDragging {
            isMouseDragging = false
            NSCursor.pop()
        }
        isMouseDragging = true
        lastDragPoint = event.locationInWindow
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isMouseDragging else { super.mouseDragged(with: event); return }
        let currentPoint = event.locationInWindow
        let deltaX = currentPoint.x - lastDragPoint.x
        let deltaY = currentPoint.y - lastDragPoint.y
        lastDragPoint = currentPoint
        performPan(deltaX: deltaX, deltaY: deltaY)
    }

    override func mouseUp(with event: NSEvent) {
        if isMouseDragging {
            isMouseDragging = false
            NSCursor.pop()
        }
        super.mouseUp(with: event)
    }

    // MARK: - Context Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        // 確保 first responder
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        // 向 scrollDelegate 請求選單（傳遞 event 供 hit-test 判斷雙頁模式下的點擊目標）
        return scrollDelegate?.contextMenu(for: self, event: event)
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

    private var scrollDebounceWorkItem: DispatchWorkItem?

    /// Y 軸的 scroll 範圍（考慮 contentInsets）
    /// NSScrollView contentInsets 以視覺邊緣為語意：.bottom = visual bottom (minY), .top = visual top (maxY)
    private func yScrollBounds(docHeight: CGFloat, clipHeight: CGFloat, insets: NSEdgeInsets) -> (min: CGFloat, max: CGFloat) {
        let minY = -insets.bottom
        let maxY = max(docHeight - clipHeight + insets.top, minY)
        return (min: minY, max: maxY)
    }

    private func panLeft() {
        let clip = contentView
        let insets = contentInsets
        let minX = -insets.left
        let newX = max(clip.bounds.minX - Constants.arrowPanStep, minX)
        animateScroll(to: NSPoint(x: newX, y: clip.bounds.minY))
    }

    private func panRight() {
        let clip = contentView
        guard let docView = documentView else { return }
        let insets = contentInsets
        let maxX = max(docView.frame.width - clip.bounds.width + insets.right, -insets.left)
        let newX = min(clip.bounds.minX + Constants.arrowPanStep, maxX)
        animateScroll(to: NSPoint(x: newX, y: clip.bounds.minY))
    }

    /// macOS unflipped: visual up = increase Y
    private func panUp() {
        let clip = contentView
        guard let docView = documentView else { return }
        let yBounds = yScrollBounds(docHeight: docView.frame.height, clipHeight: clip.bounds.height, insets: contentInsets)
        let newY = min(clip.bounds.minY + Constants.arrowPanStep, yBounds.max)
        animateScroll(to: NSPoint(x: clip.bounds.minX, y: newY))
    }

    /// macOS unflipped: visual down = decrease Y
    private func panDown() {
        let clip = contentView
        let yBounds = yScrollBounds(docHeight: documentView?.frame.height ?? 0, clipHeight: clip.bounds.height, insets: contentInsets)
        let newY = max(clip.bounds.minY - Constants.arrowPanStep, yBounds.min)
        animateScroll(to: NSPoint(x: clip.bounds.minX, y: newY))
    }

    /// Animated scroll helper with debounced completion
    /// Uses debounce to prevent stuttering when key repeat triggers rapid successive animations
    private func animateScroll(to newOrigin: NSPoint) {
        let clip = contentView

        // Cancel previous debounce timer
        scrollDebounceWorkItem?.cancel()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Constants.arrowPanAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .linear)
            context.allowsImplicitAnimation = true
            clip.scroll(to: newOrigin)
        }

        // Debounce: only sync scrollbars after animations settle
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reflectScrolledClipView(clip)
        }
        scrollDebounceWorkItem = workItem
        let debounceDelay = Constants.arrowPanAnimationDuration + 0.05  // padding after animation settles
        DispatchQueue.main.asyncAfter(
            deadline: .now() + debounceDelay,
            execute: workItem
        )
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
    func resetEdgeState() {
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
        bottomIndicator.frame = CGRect(x: 0, y: b.height - t - dragBottomInset, width: b.width, height: t)
        leftIndicator.frame = CGRect(x: 0, y: 0, width: t, height: b.height)
        rightIndicator.frame = CGRect(x: b.width - t, y: 0, width: t, height: b.height)
    }

    override func layout() {
        super.layout()
        layoutEdgeIndicators()
        // Only update drag highlight path if visible (efficiency optimization)
        if !dragHighlightLayer.isHidden {
            updateDragHighlightPath()
        }
    }

    // MARK: - Drag Highlight (Phase 2: Visual Feedback)

    private func updateDragHighlight() {
        ensureDragHighlightAttached()
        updateDragHighlightPath()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.allowsImplicitAnimation = true
            dragHighlightLayer.isHidden = !isDragOver
        }
        // Note: didSet will also trigger when isDragOver is set in
        // draggingExited or concludeDragOperation, ensuring proper cleanup
    }

    private func ensureDragHighlightAttached() {
        wantsLayer = true
        guard let root = layer, dragHighlightLayer.superlayer == nil else { return }
        root.addSublayer(dragHighlightLayer)  // Lazy attachment on first drag
    }

    private func updateDragHighlightPath() {
        let inset: CGFloat = 8
        // Asymmetric inset: extra bottom space to avoid status bar overlay
        let topInset = inset
        let bottomInset = inset + dragBottomInset
        let rect = CGRect(
            x: bounds.minX + inset,
            y: bounds.minY + topInset,
            width: bounds.width - inset * 2,
            height: bounds.height - topInset - bottomInset
        )
        dragHighlightLayer.frame = bounds
        dragHighlightLayer.path = CGPath(
            roundedRect: rect,
            cornerWidth: 8,
            cornerHeight: 8,
            transform: nil
        )
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
        let navAmount = event.modifierFlags.contains(.option) ? Constants.optionKeyJumpAmount : 1

        switch event.keyCode {
        case 124: // → RightArrow
            let rightAction: () -> Void = { [weak self] in
                guard let self else { return }
                if self.isRTLNavigation {
                    self.scrollDelegate?.scrollViewRequestPreviousImage(self, amount: navAmount)
                } else {
                    self.scrollDelegate?.scrollViewRequestNextImage(self, amount: navAmount)
                }
            }
            if overflow.horizontal {
                if !isAtRight {
                    panRight()
                    edgePressCount = 0
                    hideEdgeIndicators()
                } else if arrowLeftRightNavigation {
                    handleEdgePress(keyCode: 124, navigateAction: rightAction)
                }
            } else if arrowLeftRightNavigation {
                resetEdgeState()
                rightAction()
            }

        case 123: // ← LeftArrow
            let leftAction: () -> Void = { [weak self] in
                guard let self else { return }
                if self.isRTLNavigation {
                    self.scrollDelegate?.scrollViewRequestNextImage(self, amount: navAmount)
                } else {
                    self.scrollDelegate?.scrollViewRequestPreviousImage(self, amount: navAmount)
                }
            }
            if overflow.horizontal {
                if !isAtLeft {
                    panLeft()
                    edgePressCount = 0
                    hideEdgeIndicators()
                } else if arrowLeftRightNavigation {
                    handleEdgePress(keyCode: 123, navigateAction: leftAction)
                }
            } else if arrowLeftRightNavigation {
                resetEdgeState()
                leftAction()
            }

        case 125: // ↓ DownArrow
            if overflow.vertical && !isAtBottom {
                panDown()
                edgePressCount = 0
                hideEdgeIndicators()
            } else if arrowUpDownNavigation {
                if overflow.vertical {
                    // At bottom edge: edge-press to navigate
                    handleEdgePress(keyCode: 125) { [weak self] in
                        guard let self else { return }
                        self.scrollDelegate?.scrollViewRequestNextImage(self, amount: navAmount)
                    }
                } else {
                    // No vertical overflow: navigate directly
                    resetEdgeState()
                    scrollDelegate?.scrollViewRequestNextImage(self, amount: navAmount)
                }
            }

        case 126: // ↑ UpArrow
            if overflow.vertical && !isAtTop {
                panUp()
                edgePressCount = 0
                hideEdgeIndicators()
            } else if arrowUpDownNavigation {
                if overflow.vertical {
                    // At top edge: edge-press to navigate
                    handleEdgePress(keyCode: 126) { [weak self] in
                        guard let self else { return }
                        self.scrollDelegate?.scrollViewRequestPreviousImage(self, amount: navAmount)
                    }
                } else {
                    // No vertical overflow: navigate directly
                    resetEdgeState()
                    scrollDelegate?.scrollViewRequestPreviousImage(self, amount: navAmount)
                }
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
        case 5 where event.modifierFlags.intersection(.deviceIndependentFlagsMask) == []:  // bare G (no modifiers)
            scrollDelegate?.scrollViewRequestToggleQuickGrid(self)
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
                guard let key = touch.identity as? NSObject else { continue }
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

        // Map normalized trackpad movement to viewport size for drag-like feel:
        // full trackpad swipe = full viewport scroll
        let viewportSize = contentView.bounds.size

        for touch in touches {
            guard let key = touch.identity as? NSObject else { continue }
            let currentPos = touch.normalizedPosition
            if let prevPos = previousTouchPositions[key] {
                totalDeltaX += (currentPos.x - prevPos.x) * viewportSize.width
                totalDeltaY += (currentPos.y - prevPos.y) * viewportSize.height
                matchedCount += 1
            }
            previousTouchPositions[key] = currentPos
        }

        guard matchedCount > 0 else { return }
        let avgDeltaX = totalDeltaX / CGFloat(matchedCount)
        let avgDeltaY = totalDeltaY / CGFloat(matchedCount)
        performPan(deltaX: avgDeltaX, deltaY: avgDeltaY)
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

    /// Shared pan helper for mouse drag and three-finger trackpad pan.
    /// Moves the clip view origin by the given delta (in view coordinates).
    private func performPan(deltaX: CGFloat, deltaY: CGFloat) {
        let clip = contentView
        guard let docView = documentView else { return }

        let docSize = docView.frame.size
        let clipSize = clip.bounds.size

        // 手指右移(+deltaX) → 內容左移 → origin.x 減少
        // 手指上移(+deltaY) → 內容下移 → origin.y 減少 (unflipped: y=0 at bottom)
        var newX = clip.bounds.origin.x - deltaX
        var newY = clip.bounds.origin.y - deltaY

        let insets = contentInsets
        newX = max(-insets.left, min(newX, docSize.width - clipSize.width + insets.right))
        let yBounds = yScrollBounds(docHeight: docSize.height, clipHeight: clipSize.height, insets: insets)
        newY = max(yBounds.min, min(newY, yBounds.max))

        clip.scroll(to: NSPoint(x: newX, y: newY))
        reflectScrolledClipView(clip)
    }

    private func resetThreeFingerPanState() {
        threeFingerPanActive = false
        previousTouchPositions.removeAll()
    }

    // MARK: - Cmd + Scroll Wheel Zoom

    private func handleCmdScrollZoom(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.01 else { return }

        // Zoom 方向：deltaY > 0 = 放大，deltaY < 0 = 縮小
        // 不跟隨 Natural Scrolling 反轉（主流慣例：scroll up = zoom in）
        let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.003 : 0.08
        let newMag = magnification + delta * sensitivity
        let effectiveMin = effectiveMinMagnification()
        let clamped = max(effectiveMin, min(maxMagnification, newMag))

        // 以可預測的視窗中心為 anchor（避免 contentInsets 暫時被重置時漂移到左側）
        let center = zoomAnchorPoint()
        setMagnificationPreservingInsets(clamped, centeredAt: center)

        // 通知 delegate（與 pinch zoom 一致）
        scrollDelegate?.scrollViewMagnificationDidChange(
            self, magnification: magnification, gesturePhase: event.phase
        )
    }

    // MARK: - Option + Scroll Fast Navigation (Phase 3)

    private func handleOptionScrollNav(with event: NSEvent) {
        let isTrackpad = event.phase != [] || event.momentumPhase != []
        let isMomentum = event.momentumPhase != []

        // 新手勢開始時重置累積器
        if event.phase == .began {
            optionScrollAccumulator.resetForNewGesture()
            resetEdgeState()  // 清除鍵盤導航的邊緣指示器
        }

        // Natural Scrolling 方向校正（與 page-turn 邏輯一致）
        // intentDown (next) 用正值，intentUp (previous) 用負值
        let isNatural = event.isDirectionInvertedFromDevice
        let rawDelta = event.scrollingDeltaY
        // natural: deltaY < 0 = 使用者向下滑動 = next
        // traditional: deltaY > 0 = next
        let correctedDelta: CGFloat
        if isNatural {
            correctedDelta = -rawDelta  // 反轉：natural 的 negative → positive (next)
        } else {
            correctedDelta = rawDelta   // traditional: positive = next
        }

        let steps = optionScrollAccumulator.accumulate(
            delta: correctedDelta,
            isTrackpad: isTrackpad,
            isMomentum: isMomentum
        )

        guard steps != 0 else { return }

        // 1. 設定 isOptionScrolling flag（force thumbnail fallback）
        scrollDelegate?.scrollViewOptionScrollWillNavigate(self)
        // 2. 觸發導航（用 amount=1 逐張切換，確保 dual-page 相容）
        let navCount = abs(steps)
        for _ in 0..<navCount {
            if steps > 0 {
                scrollDelegate?.scrollViewRequestNextImage(self, amount: 1)
            } else {
                scrollDelegate?.scrollViewRequestPreviousImage(self, amount: 1)
            }
        }
        // 3. 導航完成，更新 HUD（此時 folder.currentIndex 已是最新值）
        scrollDelegate?.scrollViewOptionScrollDidNavigate(self)
    }

    // MARK: - Pinch Zoom

    /// 以 viewport 中心為中心的 Pinch Zoom
    override func magnify(with event: NSEvent) {
        let point = zoomAnchorPoint()
        let newMag = magnification + event.magnification
        let effectiveMin = effectiveMinMagnification()
        setMagnificationPreservingInsets(
            max(effectiveMin, min(maxMagnification, newMag)),
            centeredAt: point
        )
        scrollDelegate?.scrollViewMagnificationDidChange(
            self,
            magnification: magnification,
            gesturePhase: event.phase
        )
    }

    private func setMagnificationPreservingInsets(_ magnification: CGFloat, centeredAt point: NSPoint) {
        let zeroInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        let previousInsets = contentInsets
        setMagnification(magnification, centeredAt: point)
        // AppKit 在 magnify 期間可能把 contentInsets 重置為 0，導致畫面左右閃動。
        // 優先恢復上一幀 insets；若上一幀本來就是 0，改用幾何推導值作為保底。
        if !edgeInsetsNearlyEqual(contentInsets, previousInsets) {
            contentInsets = previousInsets
        }
        if edgeInsetsNearlyEqual(contentInsets, zeroInsets),
           let fallbackInsets = computedCenteringInsets(),
           !edgeInsetsNearlyEqual(fallbackInsets, zeroInsets) {
            contentInsets = fallbackInsets
        }
    }

    private func edgeInsetsNearlyEqual(
        _ lhs: NSEdgeInsets,
        _ rhs: NSEdgeInsets,
        epsilon: CGFloat = 0.01
    ) -> Bool {
        lhs.isNearlyEqual(to: rhs, epsilon: epsilon)
    }

    private func zoomAnchorPoint() -> NSPoint {
        let bounds = contentView.bounds
        return NSPoint(x: bounds.midX, y: bounds.midY)
    }

    /// 根據圖片原始尺寸與視窗最小尺寸動態計算最小 magnification。
    /// 當 displayedSize < minWindowContent 時 resizeToFitImage 不再縮小視窗，
    /// 但 magnification 會繼續降導致不同步漂移。此方法確保 magnification 不會低於該臨界值。
    func effectiveMinMagnification() -> CGFloat {
        guard let docView = documentView else { return minMagnification }
        // documentView.frame 是已縮放尺寸，除以 magnification 取得原始圖片尺寸
        let currentMag = magnification
        guard currentMag > 0 else { return minMagnification }
        let originalWidth = docView.frame.width / currentMag
        let originalHeight = docView.frame.height / currentMag
        guard originalWidth > 0, originalHeight > 0 else { return minMagnification }
        let minMagW = Constants.minWindowContentWidth / originalWidth
        let minMagH = Constants.minWindowContentHeight / originalHeight
        return max(minMagnification, max(minMagW, minMagH))
    }

    /// 緊急 fallback：當 AppKit 在 magnify 期間將 contentInsets 清零時，
    /// 用幾何推導重算置中 insets。這不是主要計算來源（主要在 ImageViewController.applyCenteringInsetsIfNeeded）。
    private func computedCenteringInsets() -> NSEdgeInsets? {
        guard let documentView else { return nil }
        let clipSize = contentView.bounds.size
        let docSize = documentView.frame.size
        guard clipSize.width > 0, clipSize.height > 0, docSize.width > 0, docSize.height > 0 else { return nil }

        let insetX = max((clipSize.width - docSize.width) / 2.0, 0)
        let insetY = max((clipSize.height - docSize.height) / 2.0, 0)
        return NSEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
    }

    // MARK: - Scroll Helpers

    /// 切換圖片後回到頂部（macOS 座標系：maxY = 頂部）
    /// 使用 contentInsets 計算正確的最大 Y 位置，避免黑邊
    func scrollToTop() {
        guard let docView = documentView else { return }
        let yBounds = yScrollBounds(docHeight: docView.frame.height, clipHeight: contentView.bounds.height, insets: contentInsets)
        let topPoint = NSPoint(x: contentView.bounds.origin.x, y: yBounds.max)
        contentView.scroll(to: topPoint)
        reflectScrolledClipView(contentView)
    }

    /// 切換圖片後跳到底部
    /// 使用 contentInsets 計算正確的最小 Y 位置，避免被 status bar 遮擋
    func scrollToBottom() {
        let yBounds = yScrollBounds(docHeight: documentView?.frame.height ?? 0, clipHeight: contentView.bounds.height, insets: contentInsets)
        let bottomPoint = NSPoint(x: contentView.bounds.origin.x, y: yBounds.min)
        contentView.scroll(to: bottomPoint)
        reflectScrolledClipView(contentView)
    }

    // MARK: - Drag and Drop (Phase 2: Browse Mode)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        cachedValidURLs = URLFilter.extractImageURLs(from: sender.draggingPasteboard)
        isDragOver = !cachedValidURLs.isEmpty
        return cachedValidURLs.isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return cachedValidURLs.isEmpty ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDragOver = false
        cachedValidURLs = []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return !cachedValidURLs.isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = cachedValidURLs
        guard !urls.isEmpty else { return false }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.scrollDelegate?.scrollViewDidReceiveDrop(self, urls: urls)
        }
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        isDragOver = false
        cachedValidURLs = []
    }

}
