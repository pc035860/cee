import AppKit

class ImageViewController: NSViewController, NSMenuItemValidation {
    private var folder: ImageFolder
    private let loader = ImageLoader()
    private var scrollView: ImageScrollView!
    private var contentView: ImageContentView!
    private var currentLoadRequestID: UUID?  // 防止快速翻頁時舊圖覆蓋新圖
    var settings = ViewerSettings.load()     // Phase 3: var (struct mutates)

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
        self.view = scrollView
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        applySettings()
        loadCurrentImage()
        view.window?.makeFirstResponder(scrollView)
    }

    /// 視窗重用時載入新資料夾
    func loadFolder(_ newFolder: ImageFolder) {
        self.folder = newFolder
        if settings.alwaysFitOnOpen { settings.isManualZoom = false }
        loadCurrentImage()
        view.window?.makeFirstResponder(scrollView)
    }

    // MARK: - Settings Application

    private func applySettings() {
        updateScalingQuality()
        if settings.floatOnTop { view.window?.level = .floating }
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

    // MARK: - Image Loading

    private func loadCurrentImage() {
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

        Task {
            guard let image = await loader.loadImage(at: item.url) else {
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

            if settings.resizeWindowAutomatically {
                (view.window?.windowController as? ImageWindowController)?
                    .resizeToFitImage(image.size)
            }

            await loader.updateCache(
                currentIndex: folder.currentIndex,
                imageURLs: folder.images.map(\.url)
            )
        }
    }

    private func applyFitting(for imageSize: NSSize) {
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let viewportSize = scrollView.bounds.size
        guard viewportSize.width > 0, viewportSize.height > 0 else {
            scrollView.magnification = 1.0
            return
        }

        if settings.isManualZoom {
            scrollView.magnification = settings.magnification
        } else if settings.alwaysFitOnOpen {
            let fitted = FittingCalculator.calculate(
                imageSize: imageSize,
                viewportSize: viewportSize,
                options: settings.fittingOptions
            )
            scrollView.magnification = fitted.width / imageSize.width
        }
        updateScalingQuality()
    }

    // MARK: - Navigation

    @objc func goToNextImage() {
        guard folder.goNext() else { return }
        loadCurrentImage()
        scrollView.scrollToTop()
        updateWindowTitle()
    }

    @objc func goToPreviousImage() {
        guard folder.goPrevious() else { return }
        loadCurrentImage()
        scrollView.scrollToBottom()
        updateWindowTitle()
    }

    @objc func goToFirstImage() {
        guard !folder.images.isEmpty else { return }
        folder.currentIndex = 0
        loadCurrentImage()
        scrollView.scrollToTop()
        updateWindowTitle()
    }

    @objc func goToLastImage() {
        guard !folder.images.isEmpty else { return }
        folder.currentIndex = folder.images.count - 1
        loadCurrentImage()
        scrollView.scrollToTop()
        updateWindowTitle()
    }

    private func scrollPageDownOrNext() {
        let clipView = scrollView.contentView
        let visibleHeight = clipView.bounds.height
        let currentY = clipView.bounds.minY
        let docHeight = scrollView.documentView?.frame.height ?? 0

        if currentY + visibleHeight >= docHeight - Constants.scrollEdgeThreshold {
            goToNextImage()
        } else {
            let newY = min(currentY + visibleHeight, docHeight - visibleHeight)
            clipView.scroll(to: NSPoint(x: 0, y: newY))
            scrollView.reflectScrolledClipView(clipView)
        }
    }

    // MARK: - Zoom Actions (@objc for menu routing via first responder chain)

    @objc func zoomIn(_ sender: Any? = nil) {
        settings.isManualZoom = true
        let newMag = scrollView.magnification + Constants.zoomStep
        scrollView.magnification = min(newMag, Constants.maxMagnification)
        settings.magnification = scrollView.magnification
        settings.save()
        updateScalingQuality()
    }

    @objc func zoomOut(_ sender: Any? = nil) {
        settings.isManualZoom = true
        let newMag = scrollView.magnification - Constants.zoomStep
        scrollView.magnification = max(newMag, Constants.minMagnification)
        settings.magnification = scrollView.magnification
        settings.save()
        updateScalingQuality()
    }

    @objc func fitOnScreen(_ sender: Any? = nil) {
        settings.isManualZoom = false
        if let imageSize = contentView.image?.size {
            applyFitting(for: imageSize)
        }
        settings.save()
    }

    @objc func actualSize(_ sender: Any? = nil) {
        settings.isManualZoom = true
        scrollView.magnification = 1.0
        settings.magnification = 1.0
        settings.save()
        updateScalingQuality()
    }

    // MARK: - Toggle Actions (@objc for menu routing)

    @objc func toggleAlwaysFit(_ sender: Any? = nil) {
        settings.alwaysFitOnOpen.toggle()
        settings.save()
    }

    @objc func toggleShowPixels(_ sender: Any? = nil) {
        settings.showPixelsWhenZoomingIn.toggle()
        settings.save()
        updateScalingQuality()
    }

    @objc func toggleResizeAutomatically(_ sender: Any? = nil) {
        settings.resizeWindowAutomatically.toggle()
        settings.save()
    }

    @objc func toggleFloatOnTop(_ sender: Any? = nil) {
        settings.floatOnTop.toggle()
        view.window?.level = settings.floatOnTop ? .floating : .normal
        settings.save()
    }

    @objc func toggleFullScreen(_ sender: Any? = nil) {
        view.window?.toggleFullScreen(nil)
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
        case #selector(toggleResizeAutomatically(_:)):
            menuItem.state = settings.resizeWindowAutomatically ? .on : .off; return true
        case #selector(toggleFloatOnTop(_:)):
            menuItem.state = settings.floatOnTop ? .on : .off; return true
        case #selector(ImageViewController.toggleFullScreen(_:)):
            let isFullscreen = view.window?.styleMask.contains(.fullScreen) == true
            menuItem.title = isFullscreen ? "Exit Full Screen" : "Enter Full Screen"
            return true
        default:
            return true
        }
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

    func scrollViewMagnificationDidChange(_ scrollView: ImageScrollView, magnification: CGFloat) {
        settings.isManualZoom = true
        settings.magnification = magnification
        settings.save()
        updateScalingQuality()
    }

    func scrollViewRequestNextImage(_ scrollView: ImageScrollView) { goToNextImage() }
    func scrollViewRequestPreviousImage(_ scrollView: ImageScrollView) { goToPreviousImage() }
    func scrollViewRequestFirstImage(_ scrollView: ImageScrollView) { goToFirstImage() }
    func scrollViewRequestLastImage(_ scrollView: ImageScrollView) { goToLastImage() }
    func scrollViewRequestPageDown(_ scrollView: ImageScrollView) { scrollPageDownOrNext() }
}
