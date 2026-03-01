import AppKit

@MainActor
class ImageViewController: NSViewController, NSMenuItemValidation {
    private var folder: ImageFolder
    private let loader = ImageLoader()
    private var scrollView: ImageScrollView!
    private var contentView: ImageContentView!
    private var statusBarView: StatusBarView!
    private var statusBarHeightConstraint: NSLayoutConstraint!
    private var currentLoadRequestID: UUID?  // 防止快速翻頁時舊圖覆蓋新圖
    private var currentLoadTask: Task<Void, Never>?  // 可取消前景載入
    private var errorPlaceholderView: ErrorPlaceholderView?
    private var resizeAfterZoomTask: DispatchWorkItem?
    private var postMagnifyCenteringTask: DispatchWorkItem?
    private var settingsSaveTask: DispatchWorkItem?
    private let resizeAfterZoomDelay: TimeInterval = 0.016  // ≈1 frame @60fps
    private var activeMagnifyAnchor: NSPoint?
    private var isZooming = false
    var settings = ViewerSettings.load()     // Phase 3: var (struct mutates)
    private enum InitialScrollPosition { case preserve, top, bottom }
    private let isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")

    init(folder: ImageFolder) {
        self.folder = folder
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        contentView = ImageContentView()
        scrollView = ImageScrollView(frame: .zero)
        scrollView.documentView = contentView
        scrollView.scrollDelegate = self

        statusBarView = StatusBarView()

        let container = NSView()
        container.addSubview(scrollView)
        container.addSubview(statusBarView)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        statusBarView.translatesAutoresizingMaskIntoConstraints = false

        statusBarHeightConstraint = statusBarView.heightAnchor.constraint(
            equalToConstant: Constants.statusBarHeight
        )

        NSLayoutConstraint.activate([
            // ScrollView fills container except bottom
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusBarView.topAnchor),

            // StatusBar at bottom
            statusBarView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBarView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBarView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusBarHeightConstraint,
        ])

        self.view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        applySettings()
        loadCurrentImage(initialScroll: .top)
        view.window?.makeFirstResponder(scrollView)
        // 視窗重新取得 key window 時自動回到 scrollView
        view.window?.initialFirstResponder = scrollView
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyCenteringInsetsIfNeeded(reason: "viewDidLayout")
    }

    /// 視窗重用時載入新資料夾
    func loadFolder(_ newFolder: ImageFolder) {
        Task { await loader.cancelAllPrefetchTasks() }
        self.folder = newFolder
        loadCurrentImage(initialScroll: .top)
        view.window?.makeFirstResponder(scrollView)
    }

    // MARK: - Settings Application

    private func applySettings() {
        updateScalingQuality()
        applyScrollSensitivity()
        if settings.floatOnTop { view.window?.level = .floating }
        applyStatusBar()  // 內部已呼叫 applyCenteringInsetsIfNeeded
    }

    private func applyScrollSensitivity() {
        scrollView.trackpadOverscrollThreshold = settings.trackpadSensitivity.trackpadThreshold
        scrollView.wheelOverscrollThreshold = settings.wheelSensitivity.wheelThreshold
    }

    /// settings.save() 的防抖版本，避免 magnify 60fps 時每幀都做 JSON encode + UserDefaults I/O
    private func scheduleDebouncedSettingsSave() {
        settingsSaveTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.settings.save()
        }
        settingsSaveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + resizeAfterZoomDelay, execute: task)
    }

    private func applyStatusBar() {
        let visible = settings.showStatusBar
        statusBarView.isHidden = !visible
        statusBarHeightConstraint.constant = visible ? Constants.statusBarHeight : 0
        applyCenteringInsetsIfNeeded(reason: "applyStatusBar")  // 重要：重新計算置中 insets
    }

    private func updateStatusBar() {
        guard let image = contentView.image else { return }
        let index = folder.currentIndex + 1
        let total = folder.images.count
        let zoom = scrollView.magnification
        let isFitting = !settings.isManualZoom && settings.alwaysFitOnOpen

        statusBarView.update(
            index: index,
            total: total,
            zoom: zoom,
            imageSize: image.size,
            isFitting: isFitting
        )
    }

    private func updateScalingQuality() {
        // GPU layer filters — no needsDisplay, no CPU redraw.
        let showPixels = settings.showPixelsWhenZoomingIn && scrollView.magnification > 1.0
        if showPixels {
            contentView.layerScalingFilter = .nearest
            contentView.layerMinificationFilter = .nearest
        } else {
            switch settings.scalingQuality {
            case .low:
                contentView.layerScalingFilter = .nearest
                contentView.layerMinificationFilter = .linear
            case .medium:
                contentView.layerScalingFilter = .linear
                contentView.layerMinificationFilter = .linear
            case .high:
                contentView.layerScalingFilter = .linear
                contentView.layerMinificationFilter = .trilinear
            }
        }
    }

    private func showErrorPlaceholder(_ show: Bool) {
        if show {
            if errorPlaceholderView == nil {
                let placeholder = ErrorPlaceholderView()
                placeholder.translatesAutoresizingMaskIntoConstraints = false
                scrollView.addSubview(placeholder)
                NSLayoutConstraint.activate([
                    placeholder.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
                    placeholder.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
                    placeholder.topAnchor.constraint(equalTo: scrollView.topAnchor),
                    placeholder.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
                ])
                errorPlaceholderView = placeholder
            }
            errorPlaceholderView?.isHidden = false
        } else {
            errorPlaceholderView?.isHidden = true
        }
    }

    private func shouldResizeWindowToMatchImage() -> Bool {
        settings.resizeWindowAutomatically || settings.alwaysFitOnOpen
    }

    // MARK: - Image Loading

    private func loadCurrentImage(initialScroll: InitialScrollPosition = .preserve) {
        // Phase 5: 空資料夾處理
        guard !folder.images.isEmpty else {
            contentView.image = nil
            contentView.loadingState = .error
            showErrorPlaceholder(true)
            return
        }

        guard let item = folder.currentImage else { return }
        let requestID = UUID()
        currentLoadRequestID = requestID
        showErrorPlaceholder(false)  // 立即隱藏舊 error placeholder
        contentView.loadingState = .loading  // Phase 6: accessibility state tracking

        currentLoadTask?.cancel()
        currentLoadTask = Task {
            // PDF 或一般圖片走不同載入路徑
            let image: NSImage?
            if let pageIndex = item.pdfPageIndex {
                image = await loader.loadPDFPage(url: item.url, pageIndex: pageIndex)
            } else {
                image = await loader.loadImage(at: item.url)
            }

            guard let image else {
                // Phase 5: 載入失敗（檔案缺失 / 格式不支援）
                guard currentLoadRequestID == requestID else { return }
                contentView.image = nil
                contentView.loadingState = .error
                showErrorPlaceholder(true)
                return
            }
            guard currentLoadRequestID == requestID else { return }

            showErrorPlaceholder(false)
            contentView.image = image
            contentView.loadingState = .loaded
            contentView.setAccessibilityLabel(item.fileName)  // Phase 6: for test assertions
            applyFitting(for: image.size)
            applyInitialScrollPosition(initialScroll)
            applyCenteringInsetsIfNeeded(reason: "loadCurrentImage")
            updateStatusBar()  // Status Bar 更新

            await loader.updateCache(
                currentIndex: folder.currentIndex,
                items: folder.images
            )

            // 儲存 PDF 頁碼（用於下次開啟時恢復）
            savePDFLastViewedPage()
        }
    }

    /// 儲存當前 PDF 頁碼到 UserDefaults
    private func savePDFLastViewedPage() {
        guard let item = folder.currentImage,
              let pageIndex = item.pdfPageIndex else { return }
        let key = "pdf.lastPage.\(item.url.path)"
        UserDefaults.standard.set(pageIndex, forKey: key)
    }

    private func applyFitting(for imageSize: NSSize) {
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        // documentView frame 必須設定為圖片原始尺寸，magnification 才有東西可縮放
        contentView.frame = NSRect(origin: .zero, size: imageSize)
        let viewportSize = scrollView.bounds.size
        guard viewportSize.width > 0, viewportSize.height > 0 else {
            setMagnificationCentered(1.0)
            return
        }

        if settings.alwaysFitOnOpen {
            let fitted = FittingCalculator.calculate(
                imageSize: imageSize,
                viewportSize: viewportSize,
                options: settings.fittingOptions
            )
            setMagnificationCentered(fitted.width / imageSize.width)
        } else if settings.isManualZoom {
            setMagnificationCentered(settings.magnification)
        } else {
            setMagnificationCentered(scrollView.magnification)
        }
        updateScalingQuality()

        applyCenteringInsetsIfNeeded(reason: "applyFitting")
        scheduleResizeToFitAfterZoom(magnification: scrollView.magnification)
    }

    // MARK: - Zoom Center Helpers

    private func viewportCenterInDocumentCoordinates() -> NSPoint {
        let visible = scrollView.contentView.bounds
        return NSPoint(x: visible.midX, y: visible.midY)
    }

    private func setMagnificationCentered(_ targetMagnification: CGFloat) {
        isZooming = true
        defer { isZooming = false }
        let clamped = max(Constants.minMagnification, min(Constants.maxMagnification, targetMagnification))
        scrollView.setMagnification(clamped, centeredAt: viewportCenterInDocumentCoordinates())
        applyCenteringInsetsIfNeeded(reason: "setMagnificationCentered")
    }

    /// 根據圖片原始尺寸與視窗最小尺寸動態計算最小 magnification。
    /// 防止 magnification 低於視窗最小尺寸對應的臨界值（否則 resizeToFitImage 停止縮小但 mag 繼續降，造成漂移）。
    private func effectiveMinMagnification() -> CGFloat {
        guard let imageSize = contentView.image?.size,
              imageSize.width > 0, imageSize.height > 0 else {
            return Constants.minMagnification
        }
        let minMagW = Constants.minWindowContentWidth / imageSize.width
        let minMagH = Constants.minWindowContentHeight / imageSize.height
        return max(Constants.minMagnification, max(minMagW, minMagH))
    }

    private struct ScrollRange {
        let minX: CGFloat
        let maxX: CGFloat
        let minY: CGFloat
        let maxY: CGFloat

        var width: CGFloat { maxX - minX }
        var height: CGFloat { maxY - minY }
    }

    private func debugFloat(_ value: CGFloat) -> String {
        String(format: "%.3f", value)
    }

    private func debugPoint(_ point: NSPoint) -> String {
        "(\(debugFloat(point.x)),\(debugFloat(point.y)))"
    }

    private func debugSize(_ size: NSSize) -> String {
        "(\(debugFloat(size.width))x\(debugFloat(size.height)))"
    }

    private func debugInsets(_ insets: NSEdgeInsets) -> String {
        "(t:\(debugFloat(insets.top)),l:\(debugFloat(insets.left)),b:\(debugFloat(insets.bottom)),r:\(debugFloat(insets.right)))"
    }

    private func debugRange(_ range: ScrollRange?) -> String {
        guard let range else { return "nil" }
        return "(x:\(debugFloat(range.minX))...\(debugFloat(range.maxX)),y:\(debugFloat(range.minY))...\(debugFloat(range.maxY)))"
    }

    private func debugPhase(_ phase: NSEvent.Phase) -> String {
        phase.isEmpty ? "none" : "\(phase.rawValue)"
    }

    private func scrollRange(for insets: NSEdgeInsets) -> ScrollRange? {
        let clipView = scrollView.contentView
        let visibleSize = clipView.bounds.size
        let docSize = contentView.frame.size

        guard visibleSize.width > 0, visibleSize.height > 0,
              docSize.width > 0, docSize.height > 0 else { return nil }

        let minX = -insets.left
        let minY = -insets.top
        let maxX = max(docSize.width - visibleSize.width + insets.right, minX)
        let maxY = max(docSize.height - visibleSize.height + insets.bottom, minY)
        return ScrollRange(minX: minX, maxX: maxX, minY: minY, maxY: maxY)
    }

    private func updateScrollDebugAccessibilityValue(range: ScrollRange?) {
        guard isUITesting else { return }
        guard let range else {
            scrollView.setAccessibilityValue("unavailable")
            return
        }

        let origin = scrollView.contentView.bounds.origin
        let value = String(
            format: "mag=%.4f;originX=%.4f;originY=%.4f;minX=%.4f;maxX=%.4f;minY=%.4f;maxY=%.4f",
            scrollView.magnification,
            origin.x, origin.y,
            range.minX, range.maxX, range.minY, range.maxY
        )
        scrollView.setAccessibilityValue(value)
    }

    private func centerScrollPositionInValidRange() {
        guard let range = scrollRange(for: scrollView.contentInsets) else {
            updateScrollDebugAccessibilityValue(range: nil)
            DebugCentering.log("centerScrollPositionInValidRange skipped range=nil")
            return
        }

        let clipView = scrollView.contentView
        let before = clipView.bounds.origin
        let centeredOrigin = NSPoint(
            x: (range.minX + range.maxX) / 2.0,
            y: (range.minY + range.maxY) / 2.0
        )
        clipView.scroll(to: centeredOrigin)
        scrollView.reflectScrolledClipView(clipView)
        updateScrollDebugAccessibilityValue(range: range)
        let after = clipView.bounds.origin
        DebugCentering.log(
            "centerScrollPositionInValidRange range=\(debugRange(range)) before=\(debugPoint(before)) after=\(debugPoint(after))"
        )
    }

    private func applyCenteringInsetsIfNeeded(reason: String = "unspecified") {
        let zeroInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        guard let imageSize = contentView.image?.size,
              imageSize.width > 0,
              imageSize.height > 0 else {
            if !insetsNearlyEqual(scrollView.contentInsets, zeroInsets) {
                scrollView.contentInsets = zeroInsets
            }
            updateScrollDebugAccessibilityValue(range: scrollRange(for: zeroInsets))
            DebugCentering.log("applyCentering reason=\(reason) image=nil resetInsets=\(debugInsets(zeroInsets))")
            return
        }

        let clipView = scrollView.contentView
        let viewport = scrollView.bounds.size
        let clipSize = clipView.bounds.size
        guard viewport.width > 0, viewport.height > 0, clipSize.width > 0, clipSize.height > 0 else {
            DebugCentering.log(
                "applyCentering reason=\(reason) skipped viewport=\(debugSize(viewport)) clip=\(debugSize(clipSize))"
            )
            return
        }

        // 重要：contentInsets / clip origin / document frame 都在文件座標系。
        // 這裡必須用 clipView.bounds.size 與 contentView.frame.size 計算，避免縮放時座標系混用。
        let documentSize = contentView.frame.size
        let insetX = max((clipSize.width - documentSize.width) / 2.0, 0)
        let insetY = max((clipSize.height - documentSize.height) / 2.0, 0)
        let targetInsets = NSEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
        let previousInsets = scrollView.contentInsets
        let previousRange = scrollRange(for: previousInsets)
        let epsilon: CGFloat = 0.5
        let currentOrigin = scrollView.contentView.bounds.origin

        DebugCentering.log(
            "applyCentering:start reason=\(reason) mag=\(debugFloat(scrollView.magnification)) " +
            "viewport=\(debugSize(viewport)) clip=\(debugSize(clipSize)) image=\(debugSize(imageSize)) doc=\(debugSize(documentSize)) " +
            "origin=\(debugPoint(currentOrigin)) previousInsets=\(debugInsets(previousInsets)) targetInsets=\(debugInsets(targetInsets))"
        )

        // 用較小容忍值判斷 insets 變化，避免像 0.017 這種小偏移被忽略，
        // 造成看起來應置中但實際未套用 insets。
        let insetsChanged = !insetsNearlyEqual(scrollView.contentInsets, targetInsets, epsilon: 0.01)
        if insetsChanged {
            scrollView.contentInsets = targetInsets
        }

        let effectiveInsets = scrollView.contentInsets
        guard let targetRange = scrollRange(for: effectiveInsets) else {
            updateScrollDebugAccessibilityValue(range: nil)
            return
        }

        // 從「不可捲動」切到「可捲動」時，改以中點初始化，避免落在左上角邊界
        let becameScrollableX = (previousRange?.width ?? 0) <= epsilon && targetRange.width > epsilon
        let becameScrollableY = (previousRange?.height ?? 0) <= epsilon && targetRange.height > epsilon
        // 從 inset 置中模式跨到 scroll 模式時，保守回中，避免放大後貼左
        let crossedInsetThresholdX = previousInsets.left > epsilon && targetInsets.left <= epsilon
        let crossedInsetThresholdY = previousInsets.top > epsilon && targetInsets.top <= epsilon
        // 縮放期間不強制 recenter — 保留用戶的 pan 位置，僅 clamp 到合法範圍
        let shouldRecenterX = !isZooming && (becameScrollableX || crossedInsetThresholdX)
        let shouldRecenterY = !isZooming && (becameScrollableY || crossedInsetThresholdY)

        DebugCentering.log(
            "applyCentering:range reason=\(reason) previousRange=\(debugRange(previousRange)) " +
            "targetRange=\(debugRange(targetRange)) insetsChanged=\(insetsChanged) " +
            "effectiveInsets=\(debugInsets(effectiveInsets)) " +
            "recenterX=\(shouldRecenterX) recenterY=\(shouldRecenterY)"
        )

        // 每次都修正 scroll position（不只在 inset 變更時）
        // 這確保全螢幕轉換後位置正確
        clampScrollPositionToValidRange(
            range: targetRange,
            recenterX: shouldRecenterX,
            recenterY: shouldRecenterY,
            reason: reason
        )
        updateScrollDebugAccessibilityValue(range: targetRange)
        DebugCentering.log("applyCentering:end reason=\(reason) origin=\(debugPoint(scrollView.contentView.bounds.origin))")
    }

    /// 將 scroll position 限制在合法範圍內，確保置中效果
    private func clampScrollPositionToValidRange(
        range: ScrollRange,
        recenterX: Bool = false,
        recenterY: Bool = false,
        reason: String = "unspecified"
    ) {
        let clipView = scrollView.contentView
        let currentOrigin = clipView.bounds.origin
        let clampedX = recenterX
            ? (range.minX + range.maxX) / 2.0
            : min(max(currentOrigin.x, range.minX), range.maxX)
        let clampedY = recenterY
            ? (range.minY + range.maxY) / 2.0
            : min(max(currentOrigin.y, range.minY), range.maxY)

        DebugCentering.log(
            "clamp reason=\(reason) current=\(debugPoint(currentOrigin)) target=\(debugPoint(NSPoint(x: clampedX, y: clampedY))) " +
            "range=\(debugRange(range)) recenterX=\(recenterX) recenterY=\(recenterY)"
        )

        if currentOrigin.x != clampedX || currentOrigin.y != clampedY {
            clipView.scroll(to: NSPoint(x: clampedX, y: clampedY))
            scrollView.reflectScrolledClipView(clipView)
            DebugCentering.log("clamp applied reason=\(reason) newOrigin=\(debugPoint(clipView.bounds.origin))")
        }
    }

    private func insetsNearlyEqual(_ lhs: NSEdgeInsets, _ rhs: NSEdgeInsets, epsilon: CGFloat = 0.5) -> Bool {
        lhs.isNearlyEqual(to: rhs, epsilon: epsilon)
    }

    private func applyInitialScrollPosition(_ position: InitialScrollPosition) {
        switch position {
        case .preserve:
            return
        case .top:
            scrollView.scrollToTop()
        case .bottom:
            scrollView.scrollToBottom()
        }
    }

    // MARK: - Navigation

    @objc func goToNextImage() {
        guard folder.goNext() else { return }
        loadCurrentImage(initialScroll: .top)
        updateWindowTitle()
    }

    @objc func goToPreviousImage() {
        guard folder.goPrevious() else { return }
        loadCurrentImage(initialScroll: .bottom)
        updateWindowTitle()
    }

    @objc func goToFirstImage() {
        guard !folder.images.isEmpty else { return }
        folder.currentIndex = 0
        loadCurrentImage(initialScroll: .top)
        updateWindowTitle()
    }

    @objc func goToLastImage() {
        guard !folder.images.isEmpty else { return }
        folder.currentIndex = folder.images.count - 1
        loadCurrentImage(initialScroll: .top)
        updateWindowTitle()
    }

    /// Space / PageDown：視覺向下捲動一頁，到底部則翻到下一張
    /// macOS unflipped: visual bottom = minY ≈ 0, scroll down = decrease Y
    private func scrollPageDownOrNext() {
        let clipView = scrollView.contentView
        let visibleHeight = clipView.bounds.height
        let currentMinY = clipView.bounds.minY

        // Visual bottom in unflipped coords = minY near 0
        if currentMinY <= Constants.scrollEdgeThreshold {
            goToNextImage()
        } else {
            let newY = max(currentMinY - visibleHeight, 0)
            clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: newY))
            scrollView.reflectScrolledClipView(clipView)
        }
    }

    /// PageUp：視覺向上捲動一頁，到頂部則翻到上一張
    /// macOS unflipped: visual top = maxY ≈ docHeight, scroll up = increase Y
    private func scrollPageUpOrPrev() {
        let clipView = scrollView.contentView
        let visibleHeight = clipView.bounds.height
        let currentMinY = clipView.bounds.minY
        let docHeight = scrollView.documentView?.frame.height ?? 0

        // Visual top in unflipped coords = maxY near docHeight
        let clipMaxY = currentMinY + visibleHeight
        if clipMaxY >= docHeight - Constants.scrollEdgeThreshold {
            goToPreviousImage()
        } else {
            let newY = min(currentMinY + visibleHeight, docHeight - visibleHeight)
            clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: newY))
            scrollView.reflectScrolledClipView(clipView)
        }
    }

    // MARK: - Zoom Actions (@objc for menu routing via first responder chain)

    @objc func zoomIn(_ sender: Any? = nil) {
        settings.isManualZoom = true
        let newMag = scrollView.magnification + Constants.zoomStep
        setMagnificationCentered(min(newMag, Constants.maxMagnification))
        settings.magnification = scrollView.magnification
        settings.save()
        updateScalingQuality()

        scheduleResizeToFitAfterZoom(magnification: scrollView.magnification)
    }

    @objc func zoomOut(_ sender: Any? = nil) {
        settings.isManualZoom = true
        let newMag = scrollView.magnification - Constants.zoomStep
        let effectiveMin = effectiveMinMagnification()
        setMagnificationCentered(max(newMag, effectiveMin))
        settings.magnification = scrollView.magnification
        settings.save()
        updateScalingQuality()

        scheduleResizeToFitAfterZoom(magnification: scrollView.magnification)
    }

    @objc func fitOnScreen(_ sender: Any? = nil) {
        settings.isManualZoom = false
        if let imageSize = contentView.image?.size {
            applyFitting(for: imageSize)
        }
        settings.save()
        scheduleResizeToFitAfterZoom(magnification: scrollView.magnification)
    }

    @objc func actualSize(_ sender: Any? = nil) {
        settings.isManualZoom = true
        setMagnificationCentered(1.0)
        settings.magnification = 1.0
        settings.save()
        updateScalingQuality()

        scheduleResizeToFitAfterZoom(magnification: scrollView.magnification)
    }

    // MARK: - Toggle Actions (@objc for menu routing)

    @objc func toggleAlwaysFit(_ sender: Any? = nil) {
        settings.alwaysFitOnOpen.toggle()
        if settings.alwaysFitOnOpen {
            settings.isManualZoom = false
        }
        settings.save()
        if let imageSize = contentView.image?.size { applyFitting(for: imageSize) }
    }

    @objc func toggleShowPixels(_ sender: Any? = nil) {
        settings.showPixelsWhenZoomingIn.toggle()
        settings.save()
        updateScalingQuality()
    }

    @objc func toggleResizeAutomatically(_ sender: Any? = nil) {
        settings.resizeWindowAutomatically.toggle()
        settings.save()
        if shouldResizeWindowToMatchImage() {
            scheduleResizeToFitAfterZoom(magnification: scrollView.magnification)
        } else {
            resizeAfterZoomTask?.cancel()
        }
    }

    @objc func toggleFloatOnTop(_ sender: Any? = nil) {
        settings.floatOnTop.toggle()
        view.window?.level = settings.floatOnTop ? .floating : .normal
        settings.save()
    }

    @objc func toggleStatusBar(_ sender: Any? = nil) {
        settings.showStatusBar.toggle()
        settings.save()
        applyStatusBar()
    }

    @objc func toggleFullScreen(_ sender: Any? = nil) {
        let isFullscreen = view.window?.styleMask.contains(.fullScreen) == true
        DebugCentering.log(
            "toggleFullScreen requested wasFullscreen=\(isFullscreen) origin=\(debugPoint(scrollView.contentView.bounds.origin)) " +
            "insets=\(debugInsets(scrollView.contentInsets))"
        )
        view.window?.toggleFullScreen(nil)
    }

    func handleFullscreenTransitionDidComplete() {
        let isFullscreen = view.window?.styleMask.contains(.fullScreen) == true
        DebugCentering.log(
            "fullscreenTransition:didComplete start isFullscreen=\(isFullscreen) viewport=\(debugSize(scrollView.bounds.size)) " +
            "origin=\(debugPoint(scrollView.contentView.bounds.origin)) insets=\(debugInsets(scrollView.contentInsets))"
        )

        view.layoutSubtreeIfNeeded()
        applyCenteringInsetsIfNeeded(reason: "fullscreenTransitionDidComplete.preCenter")
        centerScrollPositionInValidRange()
        applyCenteringInsetsIfNeeded(reason: "fullscreenTransitionDidComplete.postCenter")
        DebugCentering.log(
            "fullscreenTransition:didComplete end origin=\(debugPoint(scrollView.contentView.bounds.origin)) " +
            "insets=\(debugInsets(scrollView.contentInsets))"
        )
    }

    // MARK: - Fitting Options (@objc)

    @objc func toggleShrinkH(_ sender: Any? = nil) {
        settings.fittingOptions.shrinkHorizontally.toggle()
        settings.save()
        if let imageSize = contentView.image?.size { applyFitting(for: imageSize) }
    }

    @objc func toggleShrinkV(_ sender: Any? = nil) {
        settings.fittingOptions.shrinkVertically.toggle()
        settings.save()
        if let imageSize = contentView.image?.size { applyFitting(for: imageSize) }
    }

    @objc func toggleStretchH(_ sender: Any? = nil) {
        settings.fittingOptions.stretchHorizontally.toggle()
        settings.save()
        if let imageSize = contentView.image?.size { applyFitting(for: imageSize) }
    }

    @objc func toggleStretchV(_ sender: Any? = nil) {
        settings.fittingOptions.stretchVertically.toggle()
        settings.save()
        if let imageSize = contentView.image?.size { applyFitting(for: imageSize) }
    }

    // MARK: - Scaling Quality (@objc)

    @objc func setScalingLow(_ sender: Any? = nil) {
        settings.scalingQuality = .low
        settings.save()
        updateScalingQuality()
    }

    @objc func setScalingMedium(_ sender: Any? = nil) {
        settings.scalingQuality = .medium
        settings.save()
        updateScalingQuality()
    }

    @objc func setScalingHigh(_ sender: Any? = nil) {
        settings.scalingQuality = .high
        settings.save()
        updateScalingQuality()
    }

    // MARK: - Trackpad Sensitivity (@objc)

    @objc func setTrackpadLow(_ sender: Any? = nil) {
        settings.trackpadSensitivity = .low
        settings.save()
        applyScrollSensitivity()
    }

    @objc func setTrackpadMedium(_ sender: Any? = nil) {
        settings.trackpadSensitivity = .medium
        settings.save()
        applyScrollSensitivity()
    }

    @objc func setTrackpadHigh(_ sender: Any? = nil) {
        settings.trackpadSensitivity = .high
        settings.save()
        applyScrollSensitivity()
    }

    // MARK: - Wheel Sensitivity (@objc)

    @objc func setWheelLow(_ sender: Any? = nil) {
        settings.wheelSensitivity = .low
        settings.save()
        applyScrollSensitivity()
    }

    @objc func setWheelMedium(_ sender: Any? = nil) {
        settings.wheelSensitivity = .medium
        settings.save()
        applyScrollSensitivity()
    }

    @objc func setWheelHigh(_ sender: Any? = nil) {
        settings.wheelSensitivity = .high
        settings.save()
        applyScrollSensitivity()
    }

    // MARK: - Menu Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(fitOnScreen(_:)):
            return true
        case #selector(actualSize(_:)):
            return true
        case #selector(toggleAlwaysFit(_:)):
            menuItem.state = settings.alwaysFitOnOpen ? .on : .off; return true
        case #selector(toggleShrinkH(_:)):
            menuItem.state = settings.fittingOptions.shrinkHorizontally ? .on : .off; return true
        case #selector(toggleShrinkV(_:)):
            menuItem.state = settings.fittingOptions.shrinkVertically ? .on : .off; return true
        case #selector(toggleStretchH(_:)):
            menuItem.state = settings.fittingOptions.stretchHorizontally ? .on : .off; return true
        case #selector(toggleStretchV(_:)):
            menuItem.state = settings.fittingOptions.stretchVertically ? .on : .off; return true
        case #selector(setScalingLow(_:)):
            menuItem.state = settings.scalingQuality == .low ? .on : .off; return true
        case #selector(setScalingMedium(_:)):
            menuItem.state = settings.scalingQuality == .medium ? .on : .off; return true
        case #selector(setScalingHigh(_:)):
            menuItem.state = settings.scalingQuality == .high ? .on : .off; return true
        case #selector(toggleShowPixels(_:)):
            menuItem.state = settings.showPixelsWhenZoomingIn ? .on : .off; return true
        case #selector(setTrackpadLow(_:)):
            menuItem.state = settings.trackpadSensitivity == .low ? .on : .off; return true
        case #selector(setTrackpadMedium(_:)):
            menuItem.state = settings.trackpadSensitivity == .medium ? .on : .off; return true
        case #selector(setTrackpadHigh(_:)):
            menuItem.state = settings.trackpadSensitivity == .high ? .on : .off; return true
        case #selector(setWheelLow(_:)):
            menuItem.state = settings.wheelSensitivity == .low ? .on : .off; return true
        case #selector(setWheelMedium(_:)):
            menuItem.state = settings.wheelSensitivity == .medium ? .on : .off; return true
        case #selector(setWheelHigh(_:)):
            menuItem.state = settings.wheelSensitivity == .high ? .on : .off; return true
        case #selector(toggleResizeAutomatically(_:)):
            menuItem.state = settings.resizeWindowAutomatically ? .on : .off; return true
        case #selector(toggleFloatOnTop(_:)):
            menuItem.state = settings.floatOnTop ? .on : .off; return true
        case #selector(toggleStatusBar(_:)):
            menuItem.title = settings.showStatusBar ? "Hide Status Bar" : "Show Status Bar"
            return true
        case #selector(ImageViewController.toggleFullScreen(_:)):
            let isFullscreen = view.window?.styleMask.contains(.fullScreen) == true
            menuItem.title = isFullscreen ? "Exit Full Screen" : "Enter Full Screen"
            return true
        default:
            return true
        }
    }

    // MARK: - Window Resize for Zoom

    private func scheduleResizeToFitAfterZoom(magnification: CGFloat) {
        guard shouldResizeWindowToMatchImage(),
              let window = view.window,
              !window.styleMask.contains(.fullScreen) else { return }

        resizeAfterZoomTask?.cancel()
        let targetMag = magnification
        let task = DispatchWorkItem { [weak self] in
            self?.resizeWindowToFitZoomedImagePreservingCenter(magnification: targetMag)
        }
        resizeAfterZoomTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + resizeAfterZoomDelay, execute: task)
    }

    private func resizeWindowToFitZoomedImagePreservingCenter(magnification: CGFloat) {
        guard shouldResizeWindowToMatchImage(),
              let window = view.window,
              !window.styleMask.contains(.fullScreen),
              let imageSize = contentView.image?.size else { return }

        let anchorPoint = viewportCenterInDocumentCoordinates()
        let statusBarH = statusBarHeightConstraint.constant
        let displayedSize = NSSize(
            width: imageSize.width * magnification,
            height: imageSize.height * magnification + statusBarH
        )
        (window.windowController as? ImageWindowController)?
            .resizeToFitImage(displayedSize, center: false)

        // Window resize 後 Auto Layout 可能 pixel-align scrollView bounds，
        // 導致 scrollView 比 imageSize * mag 小幾個 pixel。
        // 在 auto-fit 模式下重新校正 magnification 以匹配實際 viewport。
        if settings.alwaysFitOnOpen && !settings.isManualZoom {
            view.layoutSubtreeIfNeeded()
            let actualViewport = scrollView.bounds.size
            if actualViewport.width > 0, actualViewport.height > 0 {
                let fitted = FittingCalculator.calculate(
                    imageSize: imageSize,
                    viewportSize: actualViewport,
                    options: settings.fittingOptions
                )
                let refitMag = fitted.width / imageSize.width
                if abs(refitMag - scrollView.magnification) > 1e-6 {
                    isZooming = true
                    scrollView.magnification = refitMag
                    isZooming = false
                }
            }
        }

        recenterViewport(around: anchorPoint)
        applyCenteringInsetsIfNeeded(reason: "resizeWindowToFitZoomedImagePreservingCenter")
    }

    private func recenterViewport(around anchorPoint: NSPoint) {
        guard let documentView = scrollView.documentView else { return }
        let clipView = scrollView.contentView
        let clipSize = clipView.bounds.size
        guard clipSize.width > 0, clipSize.height > 0 else { return }

        let unclampedOrigin = NSPoint(
            x: anchorPoint.x - clipSize.width / 2.0,
            y: anchorPoint.y - clipSize.height / 2.0
        )

        let targetOrigin: NSPoint
        if let range = scrollRange(for: scrollView.contentInsets) {
            targetOrigin = NSPoint(
                x: min(max(unclampedOrigin.x, range.minX), range.maxX),
                y: min(max(unclampedOrigin.y, range.minY), range.maxY)
            )
            DebugCentering.log(
                "recenterViewport rangeClamp insets=\(debugInsets(scrollView.contentInsets)) " +
                "range=\(debugRange(range)) unclamped=\(debugPoint(unclampedOrigin))"
            )
        } else {
            let maxOriginX = max(documentView.frame.width - clipSize.width, 0)
            let maxOriginY = max(documentView.frame.height - clipSize.height, 0)
            targetOrigin = NSPoint(
                x: min(max(unclampedOrigin.x, 0), maxOriginX),
                y: min(max(unclampedOrigin.y, 0), maxOriginY)
            )
            DebugCentering.log(
                "recenterViewport fallbackClamp doc=\(debugSize(documentView.frame.size)) " +
                "clip=\(debugSize(clipSize)) unclamped=\(debugPoint(unclampedOrigin))"
            )
        }
        DebugCentering.log(
            "recenterViewport anchor=\(debugPoint(anchorPoint)) clip=\(debugSize(clipSize)) doc=\(debugSize(documentView.frame.size)) " +
            "target=\(debugPoint(targetOrigin)) current=\(debugPoint(clipView.bounds.origin))"
        )
        clipView.scroll(to: targetOrigin)
        scrollView.reflectScrolledClipView(clipView)
        DebugCentering.log("recenterViewport applied origin=\(debugPoint(clipView.bounds.origin))")
    }

    // MARK: - Window Title Update

    func updateWindowTitle() {
        (view.window?.windowController as? ImageWindowController)?
            .updateTitle(folder: folder)
    }
}

// MARK: - ImageScrollViewDelegate

extension ImageViewController: ImageScrollViewDelegate {
    func scrollViewDidReachBottom(_ scrollView: ImageScrollView) { goToNextImage() }
    func scrollViewDidReachTop(_ scrollView: ImageScrollView) { goToPreviousImage() }

    func scrollViewMagnificationDidChange(
        _ scrollView: ImageScrollView,
        magnification: CGFloat,
        gesturePhase: NSEvent.Phase
    ) {
        DebugCentering.log(
            "magnify:start phase=\(debugPhase(gesturePhase)) mag=\(debugFloat(magnification)) " +
            "origin=\(debugPoint(self.scrollView.contentView.bounds.origin)) insets=\(debugInsets(self.scrollView.contentInsets))"
        )
        isZooming = true

        if !gesturePhase.isEmpty && gesturePhase.contains(.began) {
            // 鎖定手勢開始時的視窗中心，避免縮放過程漂移到左側
            activeMagnifyAnchor = viewportCenterInDocumentCoordinates()
            if let anchor = activeMagnifyAnchor {
                DebugCentering.log("magnify anchor locked=\(debugPoint(anchor))")
            }

        }

        settings.isManualZoom = true
        settings.magnification = magnification
        scheduleDebouncedSettingsSave()
        updateScalingQuality()
        applyCenteringInsetsIfNeeded(reason: "magnify.phase=\(debugPhase(gesturePhase))")

        if !gesturePhase.isEmpty, let anchor = activeMagnifyAnchor {
            recenterViewport(around: anchor)
            applyCenteringInsetsIfNeeded(reason: "magnify.recenter.phase=\(debugPhase(gesturePhase))")
        }

        let isFitting = !settings.isManualZoom && settings.alwaysFitOnOpen
        statusBarView.updateZoom(magnification, isFitting: isFitting)  // Status Bar 更新縮放

        if gesturePhase.isEmpty {
            isZooming = false
            scheduleResizeToFitAfterZoom(magnification: magnification)
            return
        }

        // Trackpad pinch phases should resize window in lockstep with magnification.
        resizeAfterZoomTask?.cancel()
        resizeWindowToFitZoomedImagePreservingCenter(magnification: magnification)

        if gesturePhase.contains(.ended) || gesturePhase.contains(.cancelled) {
            activeMagnifyAnchor = nil
            // isZooming 延後到 schedulePostMagnifyCentering 的 finalize 完成後才設 false
            DebugCentering.log("magnify anchor cleared phase=\(debugPhase(gesturePhase))")
        }

        schedulePostMagnifyCentering(for: gesturePhase)
    }

    private func schedulePostMagnifyCentering(for phase: NSEvent.Phase) {
        postMagnifyCenteringTask?.cancel()
        let shouldFinalize = phase.contains(.ended) || phase.contains(.cancelled)
        guard shouldFinalize else {
            DebugCentering.log("magnify deferred centering skipped phase=\(debugPhase(phase))")
            return
        }
        let phaseText = debugPhase(phase)
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            DebugCentering.log("magnify deferred finalize phase=\(phaseText)")
            // 只做 insets 更新 + clamp，不做 centerScrollPositionInValidRange()
            // 以保留用戶的 pan 位置
            self.applyCenteringInsetsIfNeeded(reason: "magnify.deferred.phase=\(phaseText)")
            self.isZooming = false
        }
        postMagnifyCenteringTask = task
        // 讓 AppKit magnify 事件鏈先落地，再做一次保底 clamp。
        DispatchQueue.main.async(execute: task)
    }

    func scrollViewRequestNextImage(_ scrollView: ImageScrollView) { goToNextImage() }
    func scrollViewRequestPreviousImage(_ scrollView: ImageScrollView) { goToPreviousImage() }
    func scrollViewRequestFirstImage(_ scrollView: ImageScrollView) { goToFirstImage() }
    func scrollViewRequestLastImage(_ scrollView: ImageScrollView) { goToLastImage() }
    func scrollViewRequestPageDown(_ scrollView: ImageScrollView) { scrollPageDownOrNext() }
    func scrollViewRequestPageUp(_ scrollView: ImageScrollView) { scrollPageUpOrPrev() }
}
