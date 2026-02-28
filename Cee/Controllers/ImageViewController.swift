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
    private var resizeAfterZoomTask: DispatchWorkItem?
    private let resizeAfterZoomDelay: TimeInterval = 0.016  // ≈1 frame @60fps
    var settings = ViewerSettings.load()     // Phase 3: var (struct mutates)
    private enum InitialScrollPosition { case preserve, top, bottom }

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
        applyCenteringInsetsIfNeeded()
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
        applyStatusBar()
        applyCenteringInsetsIfNeeded()
    }

    private func applyScrollSensitivity() {
        scrollView.trackpadOverscrollThreshold = settings.trackpadSensitivity.trackpadThreshold
        scrollView.wheelOverscrollThreshold = settings.wheelSensitivity.wheelThreshold
    }

    private func applyStatusBar() {
        let visible = settings.showStatusBar
        statusBarView.isHidden = !visible
        statusBarHeightConstraint.constant = visible ? Constants.statusBarHeight : 0
        applyCenteringInsetsIfNeeded()  // 重要：重新計算置中 insets
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
        let showPixels = settings.showPixelsWhenZoomingIn && scrollView.magnification > 1.0
        contentView.showPixels = showPixels
        if showPixels {
            contentView.interpolation = .none
        } else {
            switch settings.scalingQuality {
            case .low:    contentView.interpolation = .low
            case .medium: contentView.interpolation = .default
            case .high:   contentView.interpolation = .high
            }
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
            return
        }

        guard let item = folder.currentImage else { return }
        let requestID = UUID()
        currentLoadRequestID = requestID
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
                return
            }
            guard currentLoadRequestID == requestID else { return }

            contentView.image = image
            contentView.loadingState = .loaded
            contentView.setAccessibilityLabel(item.fileName)  // Phase 6: for test assertions
            applyFitting(for: image.size)
            applyInitialScrollPosition(initialScroll)
            applyCenteringInsetsIfNeeded()
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
        applyCenteringInsetsIfNeeded()
        scheduleResizeToFitAfterZoom(magnification: scrollView.magnification)
    }

    // MARK: - Zoom Center Helpers

    private func viewportCenterInDocumentCoordinates() -> NSPoint {
        let visible = scrollView.contentView.bounds
        return NSPoint(x: visible.midX, y: visible.midY)
    }

    private func setMagnificationCentered(_ targetMagnification: CGFloat) {
        let clamped = max(Constants.minMagnification, min(Constants.maxMagnification, targetMagnification))
        scrollView.setMagnification(clamped, centeredAt: viewportCenterInDocumentCoordinates())
        applyCenteringInsetsIfNeeded()
    }

    private func applyCenteringInsetsIfNeeded() {
        let zeroInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        guard let imageSize = contentView.image?.size,
              imageSize.width > 0,
              imageSize.height > 0 else {
            if !insetsNearlyEqual(scrollView.contentInsets, zeroInsets) {
                scrollView.contentInsets = zeroInsets
            }
            return
        }

        let viewport = scrollView.bounds.size
        guard viewport.width > 0, viewport.height > 0 else { return }

        let displayedWidth = imageSize.width * scrollView.magnification
        let displayedHeight = imageSize.height * scrollView.magnification
        let insetX = max((viewport.width - displayedWidth) / 2.0, 0)
        let insetY = max((viewport.height - displayedHeight) / 2.0, 0)
        let targetInsets = NSEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)

        let insetsChanged = !insetsNearlyEqual(scrollView.contentInsets, targetInsets)
        if insetsChanged {
            scrollView.contentInsets = targetInsets
        }

        // 每次都修正 scroll position（不只在 inset 變更時）
        // 這確保全螢幕轉換後位置正確
        clampScrollPositionToValidRange(insets: targetInsets)
    }

    /// 將 scroll position 限制在合法範圍內，確保置中效果
    /// - Parameter insets: 目標 contentInsets（已計算好的置中 insets）
    private func clampScrollPositionToValidRange(insets: NSEdgeInsets) {
        let clipView = scrollView.contentView
        let viewportSize = scrollView.bounds.size

        guard viewportSize.width > 0, viewportSize.height > 0 else { return }

        // 置中模式下，合法的 scroll 範圍：
        // - 當圖片小於 viewport 時，origin 應該在 [-inset, -inset]（讓內容置中）
        // - 當圖片大於 viewport 時，origin 可以從 -inset 捲到 (docSize - viewport + inset)
        let minX = -insets.left
        let minY = -insets.top
        // maxX/maxY 的計算：當沒有額外捲動空間時，應該等於 minX/minY
        let docSize = contentView.frame.size
        let maxX = max(docSize.width - viewportSize.width + insets.right, minX)
        let maxY = max(docSize.height - viewportSize.height + insets.bottom, minY)

        let currentOrigin = clipView.bounds.origin
        let clampedX = min(max(currentOrigin.x, minX), maxX)
        let clampedY = min(max(currentOrigin.y, minY), maxY)

        if currentOrigin.x != clampedX || currentOrigin.y != clampedY {
            clipView.scroll(to: NSPoint(x: clampedX, y: clampedY))
            scrollView.reflectScrolledClipView(clipView)
        }
    }

    private func insetsNearlyEqual(_ lhs: NSEdgeInsets, _ rhs: NSEdgeInsets, epsilon: CGFloat = 0.5) -> Bool {
        abs(lhs.top - rhs.top) <= epsilon &&
        abs(lhs.left - rhs.left) <= epsilon &&
        abs(lhs.bottom - rhs.bottom) <= epsilon &&
        abs(lhs.right - rhs.right) <= epsilon
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
        setMagnificationCentered(max(newMag, Constants.minMagnification))
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
        view.window?.toggleFullScreen(nil)
        // 全螢幕轉換需要等佈局完成後再調整置中
        // 使用 asyncAfter 確保 Auto Layout 已更新 scrollView.bounds
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.view.layoutSubtreeIfNeeded()
            self?.applyCenteringInsetsIfNeeded()
        }
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
        let displayedSize = NSSize(
            width: imageSize.width * magnification,
            height: imageSize.height * magnification
        )
        (window.windowController as? ImageWindowController)?
            .resizeToFitImage(displayedSize, center: false)
        recenterViewport(around: anchorPoint)
        applyCenteringInsetsIfNeeded()
    }

    private func recenterViewport(around anchorPoint: NSPoint) {
        guard let documentView = scrollView.documentView else { return }
        let clipView = scrollView.contentView
        let clipSize = clipView.bounds.size
        guard clipSize.width > 0, clipSize.height > 0 else { return }

        let maxOriginX = max(documentView.frame.width - clipSize.width, 0)
        let maxOriginY = max(documentView.frame.height - clipSize.height, 0)
        let targetOrigin = NSPoint(
            x: min(max(anchorPoint.x - clipSize.width / 2.0, 0), maxOriginX),
            y: min(max(anchorPoint.y - clipSize.height / 2.0, 0), maxOriginY)
        )
        clipView.scroll(to: targetOrigin)
        scrollView.reflectScrolledClipView(clipView)
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
        settings.isManualZoom = true
        settings.magnification = magnification
        settings.save()
        updateScalingQuality()
        applyCenteringInsetsIfNeeded()
        let isFitting = !settings.isManualZoom && settings.alwaysFitOnOpen
        statusBarView.updateZoom(magnification, isFitting: isFitting)  // Status Bar 更新縮放

        if gesturePhase.isEmpty {
            scheduleResizeToFitAfterZoom(magnification: magnification)
            return
        }

        // Trackpad pinch phases should resize window in lockstep with magnification.
        resizeAfterZoomTask?.cancel()
        resizeWindowToFitZoomedImagePreservingCenter(magnification: magnification)
    }

    func scrollViewRequestNextImage(_ scrollView: ImageScrollView) { goToNextImage() }
    func scrollViewRequestPreviousImage(_ scrollView: ImageScrollView) { goToPreviousImage() }
    func scrollViewRequestFirstImage(_ scrollView: ImageScrollView) { goToFirstImage() }
    func scrollViewRequestLastImage(_ scrollView: ImageScrollView) { goToLastImage() }
    func scrollViewRequestPageDown(_ scrollView: ImageScrollView) { scrollPageDownOrNext() }
    func scrollViewRequestPageUp(_ scrollView: ImageScrollView) { scrollPageUpOrPrev() }
}
