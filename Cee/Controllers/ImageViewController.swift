import AppKit

@MainActor
class ImageViewController: NSViewController, NSMenuItemValidation {
    private var folder: ImageFolder?  // Modified: now optional for empty state
    private let loader = ImageLoader()
    private var scrollView: ImageScrollView!
    private var dualPageView: DualPageContentView!
    private var continuousScrollContentView: ContinuousScrollContentView?
    /// Convenience: always the leading page (replaces old stored contentView)
    private var contentView: ImageContentView { dualPageView.leadingPage }
    private var statusBarView: StatusBarView!
    private var statusBarHeightConstraint: NSLayoutConstraint!
    private var currentLoadRequestID: UUID?  // 防止快速翻頁時舊圖覆蓋新圖
    private var currentLoadTask: Task<Void, Never>?  // 可取消前景載入
    private var errorPlaceholderView: ErrorPlaceholderView?
    private var emptyStateView: EmptyStateView?  // New: empty state overlay
    private var quickGridView: QuickGridView?
    private var positionHUDView: PositionHUDView?
    private var resizeAfterZoomTask: DispatchWorkItem?
    private var postMagnifyCenteringTask: DispatchWorkItem?
    private var settingsSaveTask: DispatchWorkItem?
    private var isApplyingAutoFitFromWindowResize = false
    private let resizeAfterZoomDelay: TimeInterval = 0.016  // ≈1 frame @60fps
    private var activeMagnifyAnchor: NSPoint?
    private var isZooming = false
    /// The page targeted by the most recent right-click (for Copy Image / Reveal in dual page mode).
    private var contextMenuTarget: (page: ImageContentView, item: ImageItem)?
    var settings = ViewerSettings.load()     // Phase 3: var (struct mutates)

    /// StatusBar 佔用的實際高度（隱藏時為 0）
    private var effectiveStatusBarHeight: CGFloat {
        settings.showStatusBar ? Constants.statusBarHeight : 0
    }

    /// ScrollView bounds 扣除 statusBar overlay 後的有效 viewport
    private var effectiveScrollViewport: NSSize {
        NSSize(
            width: scrollView.bounds.width,
            height: scrollView.bounds.height - effectiveStatusBarHeight
        )
    }

    private var isAutoFitActive: Bool {
        settings.alwaysFitOnOpen && !settings.isManualZoom
    }

    private var imageSizeCache: [Int: CGSize] = [:]
    private var navigationThrottle = NavigationThrottle(interval: 0.05)
    private var lastPrefetchDirection: PrefetchDirection = .none
    private var fullResLoadWorkItem: DispatchWorkItem?
    private enum InitialScrollPosition { case preserve, top, bottom }
    private let isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")

    /// Unified document size — uses compositeSize in dual mode, single image size otherwise.
    private var currentDocumentSize: NSSize? {
        // 連續捲動模式：使用當前圖片的縮放尺寸（fit-to-width）
        if settings.continuousScrollEnabled,
           let contentView = continuousScrollContentView,
           let folder = folder,
           contentView.scaledHeights.indices.contains(folder.currentIndex) {
            let scaledHeight = contentView.scaledHeights[folder.currentIndex]
            return NSSize(width: contentView.containerWidth, height: scaledHeight)
        }

        // 單頁/雙頁模式
        let size = dualPageView.compositeSize
        guard size.width > 0, size.height > 0 else { return nil }
        return size
    }

    init(folder: ImageFolder? = nil) {
        self.folder = folder
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        dualPageView = DualPageContentView()
        scrollView = ImageScrollView(frame: .zero)
        scrollView.documentView = dualPageView
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
            // ScrollView fills entire container (statusBar overlays on top)
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            // StatusBar overlays at bottom
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

        // CRITICAL: Handle nil folder first (empty state)
        guard folder != nil else {
            showEmptyState(true)
            view.window?.makeFirstResponder(scrollView)
            view.window?.initialFirstResponder = scrollView
            return
        }

        // 恢復連續捲動模式
        if settings.continuousScrollEnabled {
            configureContinuousScrollView()
        } else {
            loadFolderDualPageSettings()
            if settings.dualPageEnabled {
                rebuildSpreadsAndReload()
            } else {
                loadCurrentImage(initialScroll: .top)
            }
        }
        view.window?.makeFirstResponder(scrollView)
        // 視窗重新取得 key window 時自動回到 scrollView
        view.window?.initialFirstResponder = scrollView
    }

    override func viewDidLayout() {
        super.viewDidLayout()

        // 連續捲動模式：更新容器寬度
        if settings.continuousScrollEnabled {
            continuousScrollContentView?.containerWidth = scrollView.bounds.width
        }

        applyCenteringInsetsIfNeeded(reason: "viewDidLayout")
    }

    private func fittedMagnification(for imageSize: NSSize, viewport: NSSize? = nil) -> CGFloat? {
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }

        let viewport = viewport ?? effectiveScrollViewport
        guard viewport.width > 0, viewport.height > 0 else { return nil }

        let fitted = FittingCalculator.calculate(
            imageSize: imageSize,
            viewportSize: viewport,
            options: settings.fittingOptions
        )
        return fitted.width / imageSize.width
    }

    func handleWindowDidResize() {
        guard settings.alwaysFitOnOpen,
              !settings.isManualZoom,
              !settings.continuousScrollEnabled,
              !isApplyingAutoFitFromWindowResize,
              let imageSize = currentDocumentSize,
              let targetMagnification = fittedMagnification(for: imageSize) else { return }

        guard abs(targetMagnification - scrollView.magnification) > 1e-6 else { return }

        isApplyingAutoFitFromWindowResize = true
        defer { isApplyingAutoFitFromWindowResize = false }

        setMagnificationCentered(targetMagnification)
        updateScalingQuality()
        updateStatusBarZoom()
    }

    /// 視窗重用時載入新資料夾
    func loadFolder(_ newFolder: ImageFolder) {
        Task { await loader.cancelAllPrefetchTasks() }
        showEmptyState(false)  // Hide empty state when loading folder
        showErrorPlaceholder(false)  // Also hide error placeholder
        dismissPositionHUD()  // Phase 3: clear HUD on folder change
        let wasGridVisible = quickGridView != nil
        self.folder = newFolder
        imageSizeCache.removeAll()
        loadFolderDualPageSettings()

        // 根據模式選擇載入方式
        if settings.continuousScrollEnabled {
            configureContinuousScrollView()
        } else if settings.dualPageEnabled {
            rebuildSpreadsAndReload()
        } else {
            loadCurrentImage(initialScroll: .top)
        }

        // Grid visible → refresh with new folder; otherwise → restore scroll view focus
        if wasGridVisible, let grid = quickGridView, let folder = self.folder, !folder.images.isEmpty {
            grid.clearCache()
            grid.configure(items: folder.images, currentIndex: folder.currentIndex, loader: loader)
            grid.makeCollectionViewFirstResponder()
        } else {
            if wasGridVisible { dismissQuickGrid() }  // Empty folder: dismiss grid
            view.window?.makeFirstResponder(scrollView)
        }
    }

    // MARK: - Settings Application

    /// DuoPage 開啟時用 duoPageRTLNavigation；單頁模式用 singlePageRTLNavigation
    private var effectiveRTLNavigation: Bool {
        settings.dualPageEnabled ? settings.duoPageRTLNavigation : settings.singlePageRTLNavigation
    }

    private func applySettings() {
        updateScalingQuality()
        applyScrollSensitivity()
        scrollView.isRTLNavigation = effectiveRTLNavigation
        scrollView.arrowLeftRightNavigation = settings.arrowLeftRightNavigation
        scrollView.arrowUpDownNavigation = settings.arrowUpDownNavigation
        scrollView.clickToTurnPage = settings.clickToTurnPage
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
        scrollView.dragBottomInset = effectiveStatusBarHeight
        // statusBarHeightConstraint 永遠是 22pt，改由 contentInsets 控制可見性
        applyCenteringInsetsIfNeeded(reason: "applyStatusBar")  // 重要：重新計算置中 insets
    }

    private func updateStatusBar() {
        guard let folder = folder else {
            statusBarView.clear()
            return
        }

        let total = folder.images.count
        let zoom = scrollView.magnification
        let zoomMode = zoomStatusMode(for: zoom)
        
        if settings.continuousScrollEnabled {
            let currentImageSize = continuousScrollContentView?.imageSizes[safe: folder.currentIndex] ?? .zero
            statusBarView.update(
                index: folder.currentIndex + 1,
                total: total,
                zoomMode: zoomMode,
                imageSize: currentImageSize,
                indexOverride: nil
            )
            return
        }

        guard let image = contentView.image else {
            statusBarView.clear()
            return
        }

        if settings.dualPageEnabled, let spread = folder.currentSpread {
            let pageNums = spread.indices.map { String($0 + 1) }.joined(separator: "-")
            let indexText = "\(pageNums) / \(total)"
            statusBarView.update(
                index: folder.currentIndex + 1,
                total: total,
                zoomMode: zoomMode,
                imageSize: image.size,
                indexOverride: indexText
            )
        } else {
            statusBarView.update(
                index: folder.currentIndex + 1,
                total: total,
                zoomMode: zoomMode,
                imageSize: image.size
            )
        }
    }

    private func zoomStatusMode(for zoom: CGFloat? = nil) -> ZoomStatusMode {
        let currentZoom = zoom ?? scrollView.magnification
        let windowAuto = !settings.continuousScrollEnabled && shouldResizeWindowToMatchImage()

        if isAutoFitActive {
            return .fit
        }

        if currentZoom >= 0.99 && currentZoom <= 1.01 {
            return .actual(windowAuto: windowAuto)
        }

        return .manual(percent: Int(round(currentZoom * 100)), windowAuto: windowAuto)
    }

    private func updateStatusBarZoom(_ zoom: CGFloat? = nil) {
        statusBarView.updateZoom(zoomStatusMode(for: zoom))
    }

    private func enterManualZoom() {
        let wasAutoFit = isAutoFitActive
        settings.isManualZoom = true

        if wasAutoFit {
            showManualZoomHintIfNeeded()
        }
    }

    private func showManualZoomHintIfNeeded() {
        guard !isUITesting, !settings.hasShownManualZoomHint else { return }

        settings.hasShownManualZoomHint = true
        settings.save()
        showPositionHUD(
            message: String(localized: "hint.manualZoomExitFit"),
            fadeDelay: Constants.manualZoomHintFadeDelay
        )
    }

    private func updateScalingQuality() {
        // GPU layer filters — no needsDisplay, no CPU redraw.
        let showPixels = settings.showPixelsWhenZoomingIn && scrollView.magnification > 1.0
        let magFilter: CALayerContentsFilter
        let minFilter: CALayerContentsFilter
        if showPixels {
            magFilter = .nearest
            minFilter = .nearest
        } else {
            switch settings.scalingQuality {
            case .low:
                magFilter = .nearest
                minFilter = .linear
            case .medium:
                magFilter = .linear
                minFilter = .linear
            case .high:
                magFilter = .linear
                minFilter = .trilinear
            }
        }
        if settings.continuousScrollEnabled {
            continuousScrollContentView?.setScalingFilters(magnification: magFilter, minification: minFilter)
        } else {
            dualPageView.setScalingFilters(magnification: magFilter, minification: minFilter)
        }
    }

    private func showErrorPlaceholder(_ show: Bool, message: String? = nil) {
        if show {
            if errorPlaceholderView == nil {
                let placeholder = ErrorPlaceholderView()
                placeholder.translatesAutoresizingMaskIntoConstraints = false
                // Add to container view (not scrollView — clipView would cover it)
                self.view.addSubview(placeholder)
                NSLayoutConstraint.activate([
                    placeholder.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
                    placeholder.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
                    placeholder.topAnchor.constraint(equalTo: self.view.topAnchor),
                    placeholder.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
                ])
                errorPlaceholderView = placeholder
            }
            if let message {
                errorPlaceholderView?.setMessage(message)
            }
            errorPlaceholderView?.isHidden = false
        } else {
            errorPlaceholderView?.isHidden = true
        }
    }

    private func showEmptyState(_ show: Bool) {
        // Ensure mutual exclusion with error placeholder
        if show {
            showErrorPlaceholder(false)
        }

        if show {
            if emptyStateView == nil {
                let view = EmptyStateView()
                view.delegate = self
                view.translatesAutoresizingMaskIntoConstraints = false
                // Add to container (same level as statusBarView), not scrollView
                self.view.addSubview(view)
                NSLayoutConstraint.activate([
                    view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
                    view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
                    view.topAnchor.constraint(equalTo: self.view.topAnchor),
                    view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
                ])
                emptyStateView = view
            }
            emptyStateView?.isHidden = false
        } else {
            emptyStateView?.isHidden = true
        }
    }

    private func shouldResizeWindowToMatchImage() -> Bool {
        settings.resizeWindowAutomatically || settings.alwaysFitOnOpen
    }

    // MARK: - Image Loading

    private func loadCurrentImage(initialScroll: InitialScrollPosition = .preserve, thumbnailOnly: Bool = false) {
        fullResLoadWorkItem?.cancel()
        fullResLoadWorkItem = nil

        // CRITICAL: Handle nil folder first (empty state)
        guard let folder else {
            showEmptyState(true)
            return
        }

        // Phase 5: 空資料夾處理
        guard !folder.images.isEmpty else {
            contentView.image = nil
            contentView.loadingState = .error
            showErrorPlaceholder(true, message: String(localized: "error.noSupportedImages"))
            updateStatusBar()  // Clear stale status from previous folder
            (view.window?.windowController as? ImageWindowController)?
                .updateTitle(folder: folder)
            return
        }

        if settings.dualPageEnabled, let spread = folder.currentSpread {
            loadSpread(spread, initialScroll: initialScroll, thumbnailOnly: thumbnailOnly)
        } else if let item = folder.currentImage {
            loadSpread(.single(index: folder.currentIndex, item: item), initialScroll: initialScroll, thumbnailOnly: thumbnailOnly)
        }
    }

    /// 導航停止後 150ms 載入全解析度
    /// 必須使用與 thumbnail 相同的 scroll 方向（.top/.bottom），不可用 .preserve：
    /// 否則 document 尺寸從 thumbnail 變 full-res 時，preserve 會導致錯誤位置，且 setMagnificationCentered 錨點不穩會造成跳動
    private func scheduleFullResLoad() {
        fullResLoadWorkItem?.cancel()
        let scrollIntent: InitialScrollPosition = lastPrefetchDirection == .backward ? .bottom : .top
        let task = DispatchWorkItem { [weak self] in
            self?.loadCurrentImage(initialScroll: scrollIntent)
        }
        fullResLoadWorkItem = task
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.fullResLoadDelayAfterNav, execute: task)
    }

    private func loadSpread(_ spread: PageSpread, initialScroll: InitialScrollPosition, thumbnailOnly: Bool = false) {
        guard let folder else { return }  // Required for cache update
        contextMenuTarget = nil

        let requestID = UUID()
        currentLoadRequestID = requestID
        showErrorPlaceholder(false)
        contentView.loadingState = .loading

        currentLoadTask?.cancel()
        currentLoadTask = Task {
            switch spread {
            case .single(let index, let item):
                let result = await loadImageForItem(item, thumbnailOnly: thumbnailOnly)
                guard currentLoadRequestID == requestID else { return }
                guard let result else {
                    contentView.image = nil
                    contentView.loadingState = .error
                    showErrorPlaceholder(true)
                    return
                }

                contentView.image = result.image
                contentView.imageFileName = item.fileName
                contentView.loadingState = .loaded
                let layoutSize = resolveLayoutSize(
                    index: index, item: item, image: result.image,
                    fullSize: result.fullSize, thumbnailOnly: thumbnailOnly
                )
                dualPageView.configureSingle(imageSize: layoutSize)

            case .double(let leadingIndex, let leading, let trailingIndex, let trailing):
                async let leadingResult = loadImageForItem(leading, thumbnailOnly: thumbnailOnly)
                async let trailingResult = loadImageForItem(trailing, thumbnailOnly: thumbnailOnly)
                let (lResult, tResult) = await (leadingResult, trailingResult)
                guard currentLoadRequestID == requestID else { return }

                guard let lResult else {
                    contentView.image = nil
                    contentView.loadingState = .error
                    showErrorPlaceholder(true)
                    return
                }

                contentView.image = lResult.image
                contentView.imageFileName = leading.fileName
                contentView.loadingState = .loaded
                let leadingLayoutSize = resolveLayoutSize(
                    index: leadingIndex, item: leading, image: lResult.image,
                    fullSize: lResult.fullSize, thumbnailOnly: thumbnailOnly
                )

                if let tResult {
                    let trailingLayoutSize = resolveLayoutSize(
                        index: trailingIndex, item: trailing, image: tResult.image,
                        fullSize: tResult.fullSize, thumbnailOnly: thumbnailOnly
                    )
                    dualPageView.configureDouble(
                        leadingSize: leadingLayoutSize,
                        trailingSize: trailingLayoutSize,
                        isRTL: settings.readingDirection.isRTL
                    )
                    dualPageView.trailingPage?.image = tResult.image
                    dualPageView.trailingPage?.loadingState = .loaded
                    dualPageView.trailingPage?.setAccessibilityLabel(trailing.fileName)
                } else {
                    dualPageView.configureSingle(imageSize: leadingLayoutSize)
                }
            }

            applyFitting(for: dualPageView.compositeSize)
            applyCenteringInsetsIfNeeded(reason: "loadSpread")
            // bottom 時延遲一幀再 scroll，避免 thumbnail→fullRes 轉換時 setMagnificationCentered 錨點造成跳動
            if initialScroll == .bottom {
                DispatchQueue.main.async { [weak self] in
                    self?.scrollView.scrollToBottom()
                }
            } else {
                applyInitialScrollPosition(initialScroll)
            }
            updateStatusBar()

            await loader.updateCache(
                currentIndex: folder.currentIndex,
                items: folder.images,
                prefetchDirection: lastPrefetchDirection
            )
            savePDFLastViewedPage()
        }
    }

    /// 載入圖片，thumbnailOnly 時回傳 thumbnail + fullSize
    /// fullSize 僅 thumbnail 模式有效，full-res 載入時為 nil（image.size 即為真實尺寸）
    private func loadImageForItem(_ item: ImageItem, thumbnailOnly: Bool = false) async -> (image: NSImage, fullSize: CGSize?)? {
        if let pageIndex = item.pdfPageIndex {
            guard let img = await loader.loadPDFPage(url: item.url, pageIndex: pageIndex) else { return nil }
            return (img, nil)
        } else if thumbnailOnly {
            guard let result = await loader.loadThumbnail(at: item.url) else { return nil }
            return (result.image, result.fullSize)
        } else {
            guard let img = await loader.loadImage(at: item.url) else { return nil }
            return (img, nil)
        }
    }

    /// 計算 layout 尺寸：thumbnail 時用 full-res 尺寸避免 magnification 跳動，full-res 時直接用 image.size
    private func resolveLayoutSize(index: Int, item: ImageItem, image: NSImage, fullSize: CGSize?, thumbnailOnly: Bool) -> NSSize {
        if thumbnailOnly, !item.isPDF, let fullSize {
            // 不覆寫 imageSizeCache：thumbnail 的 image.size 不代表真實尺寸
            return imageSizeCache[index] ?? fullSize
        } else {
            imageSizeCache[index] = image.size
            return image.size
        }
    }

    /// 儲存當前 PDF 頁碼到 UserDefaults
    private func savePDFLastViewedPage() {
        guard let folder,
              let item = folder.currentImage,
              let pageIndex = item.pdfPageIndex else { return }
        let key = "pdf.lastPage.\(item.url.path)"
        UserDefaults.standard.set(pageIndex, forKey: key)
    }

    // MARK: - Per-Folder Dual Page Settings

    private struct FolderDualPageSettings: Codable {
        var dualPageEnabled: Bool
        var firstPageIsCover: Bool
        var readingDirection: ViewerSettings.ReadingDirection
        var duoPageRTLNavigation: Bool

        init(dualPageEnabled: Bool, firstPageIsCover: Bool,
             readingDirection: ViewerSettings.ReadingDirection, duoPageRTLNavigation: Bool) {
            self.dualPageEnabled = dualPageEnabled
            self.firstPageIsCover = firstPageIsCover
            self.readingDirection = readingDirection
            self.duoPageRTLNavigation = duoPageRTLNavigation
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            dualPageEnabled = try c.decode(Bool.self, forKey: .dualPageEnabled)
            firstPageIsCover = try c.decode(Bool.self, forKey: .firstPageIsCover)
            readingDirection = try c.decode(ViewerSettings.ReadingDirection.self, forKey: .readingDirection)
            // 舊版資料沒有此欄位，backward-compat 預設 true
            duoPageRTLNavigation = (try? c.decode(Bool.self, forKey: .duoPageRTLNavigation)) ?? true
        }
    }

    private func saveFolderDualPageSettings() {
        guard let folder else { return }
        let key = "dualPage.settings.\(folder.folderURL.path)"
        let folderSettings = FolderDualPageSettings(
            dualPageEnabled: settings.dualPageEnabled,
            firstPageIsCover: settings.firstPageIsCover,
            readingDirection: settings.readingDirection,
            duoPageRTLNavigation: settings.duoPageRTLNavigation
        )
        if let data = try? JSONEncoder().encode(folderSettings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func loadFolderDualPageSettings() {
        guard let folder else { return }
        let key = "dualPage.settings.\(folder.folderURL.path)"
        guard let data = UserDefaults.standard.data(forKey: key),
              let folderSettings = try? JSONDecoder().decode(FolderDualPageSettings.self, from: data)
        else { return }
        settings.dualPageEnabled = folderSettings.dualPageEnabled
        settings.firstPageIsCover = folderSettings.firstPageIsCover
        settings.readingDirection = folderSettings.readingDirection
        settings.duoPageRTLNavigation = folderSettings.duoPageRTLNavigation
        scrollView.isRTLNavigation = effectiveRTLNavigation
    }

    private func applyFitting(for imageSize: NSSize) {
        guard !settings.continuousScrollEnabled else { return }
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        // documentView frame is now set by DualPageContentView.configureSingle/configureDouble
        // 計算有效 viewport：scrollView 現在填滿 container，需扣除覆蓋的 statusBar 高度
        let viewport = effectiveScrollViewport
        guard viewport.width > 0, viewport.height > 0 else {
            setMagnificationCentered(1.0)
            return
        }

        if settings.alwaysFitOnOpen {
            if let targetMagnification = fittedMagnification(for: imageSize, viewport: viewport) {
                setMagnificationCentered(targetMagnification)
            }
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
        // 在 setMagnification 前暫停 slot 回收（setMagnification 會同步觸發 reflectScrolledClipView）
        continuousScrollContentView?.beginZoomSuppression()
        defer {
            isZooming = false
            // 鍵盤 zoom 路徑沒有 delegate callback，需在 defer 清理
            continuousScrollContentView?.endZoomSuppression(visibleBounds: scrollView.contentView.bounds)
        }
        let effectiveMin = effectiveMinMagnification()
        let clamped = max(effectiveMin, min(Constants.maxMagnification, targetMagnification))
        scrollView.setMagnification(clamped, centeredAt: viewportCenterInDocumentCoordinates())
        applyCenteringInsetsIfNeeded(reason: "setMagnificationCentered")
    }

    private func effectiveWindowResizeMinMagnification() -> CGFloat {
        guard shouldResizeWindowToMatchImage(),
              !settings.continuousScrollEnabled,
              let imageSize = currentDocumentSize,
              imageSize.width > 0,
              imageSize.height > 0 else {
            return Constants.minMagnification
        }

        let fallbackMinContentSize = NSSize(
            width: Constants.minWindowContentWidth,
            height: Constants.minWindowContentHeight
        )
        let minContentSize = (view.window?.windowController as? ImageWindowController)?
            .effectiveMinimumContentSize() ?? fallbackMinContentSize
        let minViewportHeight = max(minContentSize.height - effectiveStatusBarHeight, 0)
        let minMagW = minContentSize.width / imageSize.width
        let minMagH = minViewportHeight / imageSize.height
        return max(Constants.minMagnification, max(minMagW, minMagH))
    }

    /// Delegates to scrollView's baseline minimum and upgrades it with the real window/content minimum.
    private func effectiveMinMagnification() -> CGFloat {
        max(scrollView.effectiveMinMagnification(), effectiveWindowResizeMinMagnification())
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

        // 根據當前模式選擇正確的 document size
        let docSize: NSSize
        if settings.continuousScrollEnabled, let contentView = continuousScrollContentView {
            docSize = contentView.frame.size
        } else {
            docSize = dualPageView.frame.size
        }

        guard visibleSize.width > 0, visibleSize.height > 0,
              docSize.width > 0, docSize.height > 0 else { return nil }

        let minX = -insets.left
        // NSScrollView contentInsets 以視覺邊緣為語意：.top = visual top, .bottom = visual bottom
        // unflipped 座標下 visual top = high Y (maxY), visual bottom = low Y (minY)
        let minY = -insets.bottom
        let maxX = max(docSize.width - visibleSize.width + insets.right, minX)
        let maxY = max(docSize.height - visibleSize.height + insets.top, minY)
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

        // 連續捲動模式：fit-to-width，不需要 centering insets
        if settings.continuousScrollEnabled {
            let statusBarH = effectiveStatusBarHeight
            let continuousInsets = NSEdgeInsets(top: 0, left: 0, bottom: statusBarH, right: 0)
            if !insetsNearlyEqual(scrollView.contentInsets, continuousInsets) {
                scrollView.contentInsets = continuousInsets
            }
            updateScrollDebugAccessibilityValue(range: scrollRange(for: continuousInsets))
            DebugCentering.log("applyCentering reason=\(reason) continuousMode insets=\(debugInsets(continuousInsets))")
            return
        }

        guard let imageSize = currentDocumentSize else {
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
        // 這裡必須用 clipView.bounds.size 與 dualPageView.frame.size 計算，避免縮放時座標系混用。
        let documentSize = dualPageView.frame.size
        let insetX = max((clipSize.width - documentSize.width) / 2.0, 0)
        // NSScrollView contentInsets 以視覺邊緣為語意：.top = visual top, .bottom = visual bottom。
        // statusBar 在 visual bottom → statusBarH 加到 .bottom。
        // clipSize / documentSize / contentInsets 皆在同一座標系，statusBarH 直接使用即可。
        let statusBarH = effectiveStatusBarHeight
        let effectiveClipHeight = clipSize.height - statusBarH
        let insetY = max((effectiveClipHeight - documentSize.height) / 2.0, 0)
        // .top = visual top（置中）、.bottom = visual bottom（置中 + status bar padding）
        let targetInsets = NSEdgeInsets(top: insetY, left: insetX, bottom: insetY + statusBarH, right: insetX)
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

    /// Menu action entry point — `sender` is the NSMenuItem; ignore it.
    @objc func goToNextImage(_ sender: Any? = nil) {
        navigateNext(amount: 1)
    }

    /// Menu action entry point — `sender` is the NSMenuItem; ignore it.
    @objc func goToPreviousImage(_ sender: Any? = nil) {
        navigatePrevious(amount: 1)
    }

    func navigateNext(amount: Int = 1) {
        guard let folder else { return }
        guard navigationThrottle.shouldProceed() else { return }
        lastPrefetchDirection = .forward
        if settings.dualPageEnabled {
            guard amount == 1 else { return }  // Option+arrow jump 僅單頁模式
            guard folder.goNextSpread() else { return }
        } else {
            guard folder.goNext(amount: amount) else { return }
        }
        loadCurrentImage(initialScroll: .top, thumbnailOnly: settings.thumbnailFallback)
        if settings.thumbnailFallback { scheduleFullResLoad() }
        updateWindowTitle()
    }

    func navigatePrevious(amount: Int = 1) {
        guard let folder else { return }
        guard navigationThrottle.shouldProceed() else { return }
        lastPrefetchDirection = .backward
        if settings.dualPageEnabled {
            guard amount == 1 else { return }
            guard folder.goPreviousSpread() else { return }
        } else {
            guard folder.goPrevious(amount: amount) else { return }
        }
        let prevScroll: InitialScrollPosition = settings.scrollToBottomOnPrevious ? .bottom : .top
        loadCurrentImage(initialScroll: prevScroll, thumbnailOnly: settings.thumbnailFallback)
        if settings.thumbnailFallback { scheduleFullResLoad() }
        updateWindowTitle()
    }

    @objc func goToFirstImage() {
        guard let folder, !folder.images.isEmpty else { return }
        lastPrefetchDirection = .none
        if settings.dualPageEnabled {
            folder.goToFirstSpread()
        } else {
            folder.currentIndex = 0
        }
        loadCurrentImage(initialScroll: .top)
        updateWindowTitle()
    }

    @objc func goToLastImage() {
        guard let folder, !folder.images.isEmpty else { return }
        lastPrefetchDirection = .none
        if settings.dualPageEnabled {
            folder.goToLastSpread()
        } else {
            folder.currentIndex = folder.images.count - 1
        }
        loadCurrentImage(initialScroll: .top)
        updateWindowTitle()
    }

    /// Space / PageDown：視覺向下捲動一頁，到底部則翻到下一張
    /// macOS unflipped: visual bottom = minY ≈ 0, scroll down = decrease Y
    private func scrollPageDownOrNext() {
        let clipView = scrollView.contentView
        let visibleHeight = clipView.bounds.height
        let currentMinY = clipView.bounds.minY

        // Continuous mode: scroll only, never navigate to next image
        if settings.continuousScrollEnabled {
            guard let range = scrollRange(for: scrollView.contentInsets) else { return }
            let newY = max(currentMinY - visibleHeight, range.minY)
            clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: newY))
            scrollView.reflectScrolledClipView(clipView)
            return
        }

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

        // Continuous mode: scroll only, never navigate to previous image
        if settings.continuousScrollEnabled {
            guard let range = scrollRange(for: scrollView.contentInsets) else { return }
            let newY = min(currentMinY + visibleHeight, range.maxY)
            clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: newY))
            scrollView.reflectScrolledClipView(clipView)
            return
        }

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
        enterManualZoom()
        let newMag = scrollView.magnification + Constants.zoomStep
        setMagnificationCentered(min(newMag, Constants.maxMagnification))
        settings.magnification = scrollView.magnification
        settings.save()
        updateScalingQuality()
        updateStatusBarZoom()

        if !settings.continuousScrollEnabled {
            scheduleResizeToFitAfterZoom(magnification: scrollView.magnification)
        }
    }

    @objc func zoomOut(_ sender: Any? = nil) {
        enterManualZoom()
        let newMag = scrollView.magnification - Constants.zoomStep
        let effectiveMin = effectiveMinMagnification()
        setMagnificationCentered(max(newMag, effectiveMin))
        settings.magnification = scrollView.magnification
        settings.save()
        updateScalingQuality()
        updateStatusBarZoom()

        if !settings.continuousScrollEnabled {
            scheduleResizeToFitAfterZoom(magnification: scrollView.magnification)
        }
    }

    @objc func fitOnScreen(_ sender: Any? = nil) {
        settings.isManualZoom = false

        if settings.continuousScrollEnabled {
            setMagnificationCentered(1.0)
            settings.magnification = 1.0
            updateScalingQuality()
            applyCenteringInsetsIfNeeded(reason: "fitOnScreen.continuous")
            updateStatusBarZoom()
            settings.save()
            return
        }

        if let imageSize = currentDocumentSize,
           let targetMagnification = fittedMagnification(for: imageSize) {
            setMagnificationCentered(targetMagnification)
            updateScalingQuality()
            applyCenteringInsetsIfNeeded(reason: "fitOnScreen")
        }
        settings.save()
        updateStatusBarZoom()
        scheduleResizeToFitAfterZoom(magnification: scrollView.magnification)
    }

    @objc func actualSize(_ sender: Any? = nil) {
        // 連續捲動模式下 actual size = fit-to-width (magnification 1.0)
        if settings.continuousScrollEnabled {
            fitOnScreen(sender)
            return
        }
        enterManualZoom()
        setMagnificationCentered(1.0)
        settings.magnification = 1.0
        settings.save()
        updateScalingQuality()
        updateStatusBarZoom()

        scheduleResizeToFitAfterZoom(magnification: scrollView.magnification)
    }

    // MARK: - Toggle Actions (@objc for menu routing)

    @objc func toggleAlwaysFit(_ sender: Any? = nil) {
        settings.alwaysFitOnOpen.toggle()
        if settings.alwaysFitOnOpen {
            settings.isManualZoom = false
        }
        settings.save()
        if let imageSize = currentDocumentSize { applyFitting(for: imageSize) }
        updateStatusBar()
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
        updateStatusBar()
    }

    @objc func fillWindowHeight(_ sender: Any? = nil) {
        (view.window?.windowController as? ImageWindowController)?.fillWindowHeight()
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
        updateWindowTitle()  // 切換 Status Bar 後更新標題列顯示
    }

    @objc func toggleDualPage(_ sender: Any? = nil) {
        settings.dualPageEnabled.toggle()
        settings.save()
        saveFolderDualPageSettings()
        scrollView.isRTLNavigation = effectiveRTLNavigation
        if settings.dualPageEnabled {
            rebuildSpreadsAndReload()
        } else {
            loadCurrentImage(initialScroll: .preserve)
        }
    }

    @objc func togglePageOffset(_ sender: Any? = nil) {
        settings.firstPageIsCover.toggle()
        settings.save()
        saveFolderDualPageSettings()
        if settings.dualPageEnabled {
            rebuildSpreadsAndReload()
        }
    }

    private func rebuildSpreadsAndReload() {
        guard let folder else { return }
        prepopulatePDFPageSizes()
        folder.rebuildSpreads(
            firstPageIsCover: settings.firstPageIsCover,
            imageSizeProvider: { [weak self] index in
                self?.imageSizeCache[index]
            }
        )
        loadCurrentImage(initialScroll: .preserve)
    }

    /// Pre-populate imageSizeCache with PDF page dimensions from metadata (no rendering needed).
    /// This ensures SpreadManager.isWidePage() has accurate data on first build.
    private func prepopulatePDFPageSizes() {
        guard let folder else { return }
        var pdfDocCache: [URL: CGPDFDocument] = [:]
        for (index, item) in folder.images.enumerated() {
            guard imageSizeCache[index] == nil,
                  let pageIndex = item.pdfPageIndex else { continue }

            let doc: CGPDFDocument
            if let cached = pdfDocCache[item.url] {
                doc = cached
            } else {
                guard let newDoc = CGPDFDocument(item.url as CFURL) else { continue }
                pdfDocCache[item.url] = newDoc
                doc = newDoc
            }

            // CGPDFDocument pages are 1-based
            guard let page = doc.page(at: pageIndex + 1) else { continue }
            let cropBox = page.getBoxRect(.cropBox)
            let rotation = page.rotationAngle

            let pointSize: CGSize
            if rotation == 90 || rotation == 270 {
                pointSize = CGSize(width: cropBox.height, height: cropBox.width)
            } else {
                pointSize = cropBox.size
            }
            imageSizeCache[index] = pointSize
        }
    }

    @objc func toggleArrowLeftRightNav(_ sender: Any? = nil) {
        settings.arrowLeftRightNavigation.toggle()
        settings.save()
        scrollView.arrowLeftRightNavigation = settings.arrowLeftRightNavigation
        scrollView.resetEdgeState()
    }

    @objc func toggleArrowUpDownNav(_ sender: Any? = nil) {
        settings.arrowUpDownNavigation.toggle()
        settings.save()
        scrollView.arrowUpDownNavigation = settings.arrowUpDownNavigation
        scrollView.resetEdgeState()
    }

    @objc func toggleThumbnailFallback(_ sender: Any? = nil) {
        settings.thumbnailFallback.toggle()
        settings.save()
    }

    @objc func toggleQuickGridScrollAfterZoom(_ sender: Any? = nil) {
        settings.quickGridScrollAfterZoom.toggle()
        settings.save()
        quickGridView?.scrollAfterZoomEnabled = settings.quickGridScrollAfterZoom
    }

    // MARK: - Quick Grid

    @objc func toggleQuickGrid(_ sender: Any? = nil) {
        if quickGridView != nil {
            dismissQuickGrid()
        } else {
            showQuickGrid()
        }
    }

    private func showQuickGrid() {
        guard let folder else { return }

        let grid = QuickGridView()
        grid.delegate = self
        grid.translatesAutoresizingMaskIntoConstraints = false

        // Restore saved cell size
        grid.applyItemSize(settings.quickGridCellSize)
        grid.scrollAfterZoomEnabled = settings.quickGridScrollAfterZoom
        grid.isContinuousScrollMode = settings.continuousScrollEnabled

        // Persist cell size changes
        grid.onCellSizeDidChange = { [weak self] size in
            guard let self else { return }
            self.settings.quickGridCellSize = size
            self.scheduleDebouncedSettingsSave()
        }

        self.view.addSubview(grid)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: self.view.topAnchor),
            grid.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
        ])

        grid.configure(items: folder.images, currentIndex: folder.currentIndex, loader: loader)
        grid.makeCollectionViewFirstResponder()
        quickGridView = grid
    }

    private func dismissQuickGrid() {
        quickGridView?.cleanup()
        quickGridView?.removeFromSuperview()
        quickGridView = nil
        view.window?.makeFirstResponder(scrollView)
    }

    @objc func toggleReadingDirection(_ sender: Any? = nil) {
        settings.readingDirection = (settings.readingDirection == .leftToRight)
            ? .rightToLeft : .leftToRight
        settings.save()
        saveFolderDualPageSettings()
        scrollView.isRTLNavigation = effectiveRTLNavigation
        if settings.dualPageEnabled {
            loadCurrentImage(initialScroll: .preserve)
        }
    }

    @objc func toggleDuoPageRTLNavigation(_ sender: Any? = nil) {
        settings.duoPageRTLNavigation.toggle()
        settings.save()
        saveFolderDualPageSettings()
        scrollView.isRTLNavigation = effectiveRTLNavigation
    }

    @objc func toggleSinglePageRTLNavigation(_ sender: Any? = nil) {
        settings.singlePageRTLNavigation.toggle()
        settings.save()
        scrollView.isRTLNavigation = effectiveRTLNavigation
    }

    @objc func toggleScrollToBottomOnPrevious(_ sender: Any? = nil) {
        settings.scrollToBottomOnPrevious.toggle()
        settings.save()
    }

    @objc func toggleClickToTurnPage(_ sender: Any? = nil) {
        settings.clickToTurnPage.toggle()
        settings.save()
        scrollView.clickToTurnPage = settings.clickToTurnPage
    }

    @objc func toggleContinuousScroll(_ sender: Any? = nil) {
        settings.continuousScrollEnabled.toggle()
        scrollView.continuousScrollEnabled = settings.continuousScrollEnabled
        quickGridView?.isContinuousScrollMode = settings.continuousScrollEnabled
        resizeAfterZoomTask?.cancel()  // 隔離舊模式的排隊 resize

        // 重設 magnification 狀態，確保模式切換後 settings 一致
        scrollView.magnification = 1.0
        settings.isManualZoom = false
        settings.magnification = 1.0
        settings.save()

        // 切換模式：更新 documentView
        if settings.continuousScrollEnabled {
            configureContinuousScrollView()
        } else {
            // 切換回單頁/雙頁模式
            scrollView.documentView = dualPageView
            continuousScrollContentView = nil
            loadCurrentImage(initialScroll: .top)
        }
    }

    // MARK: - Image Gap (Continuous Scroll)

    @objc func setContinuousGap0(_ sender: Any?) { setContinuousGap(0) }
    @objc func setContinuousGap2(_ sender: Any?) { setContinuousGap(2) }
    @objc func setContinuousGap4(_ sender: Any?) { setContinuousGap(4) }
    @objc func setContinuousGap8(_ sender: Any?) { setContinuousGap(8) }

    private func setContinuousGap(_ gap: CGFloat) {
        guard gap != settings.continuousScrollGap else { return }
        settings.continuousScrollGap = gap
        settings.save()
        guard let contentView = continuousScrollContentView else { return }
        contentView.imageSpacing = gap
        scrollToCurrentImageInContinuousMode()
    }

    private func configureContinuousScrollView() {
        guard let folder = folder else { return }

        // 確保 scrollView 同步連續捲動狀態（非 toggle 路徑也能正確設定）
        scrollView.continuousScrollEnabled = true

        let contentView = ContinuousScrollContentView()
        contentView.containerWidth = scrollView.bounds.width
        contentView.imageSpacing = settings.continuousScrollGap
        contentView.onCurrentImageChanged = { [weak self] index, scaledSize in
            self?.handleContinuousScrollImageChanged(index: index, scaledSize: scaledSize)
        }
        // 捕獲進入連續捲動模式時的 currentIndex，
        // 避免 recalculateLayout → reflectScrolledClipView → updateVisibleSlots
        // 在 onPreloadComplete 之前將 folder.currentIndex 改成最後一頁
        let targetIndex = folder.currentIndex
        contentView.onPreloadComplete = { [weak self] in
            self?.scrollToImageInContinuousMode(at: targetIndex)
        }

        continuousScrollContentView = contentView
        scrollView.documentView = contentView
        contentView.configure(with: folder, imageLoader: loader)

        // 套用當前的 scaling filters 到新的 content view
        updateScalingQuality()
    }

    /// 捲動到當前圖片位置（連續捲動模式）
    private func scrollToCurrentImageInContinuousMode() {
        guard let folder = folder else { return }
        scrollToImageInContinuousMode(at: folder.currentIndex)
    }

    /// 捲動到指定索引的圖片位置（連續捲動模式）
    private func scrollToImageInContinuousMode(at index: Int) {
        guard let contentView = continuousScrollContentView else { return }

        let imageFrame = contentView.frameForImage(at: index)

        guard imageFrame != .zero else {
            NSLog("[ContinuousScroll] scrollToImage: imageFrame is zero for index=\(index), skipping")
            return
        }

        // 計算捲動目標：將圖片置中
        let clipHeight = scrollView.contentView.bounds.height
        let targetY = imageFrame.midY - clipHeight / 2

        // 捲動到目標位置
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        NSLog("[ContinuousScroll] scrollToImage: index=\(index), imageFrame=\(imageFrame), targetY=\(targetY)")
    }

    private func handleContinuousScrollImageChanged(index: Int, scaledSize: NSSize) {
        NSLog("[ContinuousScroll] handleImageChanged: index=\(index), scaledSize=\(scaledSize)")

        // 同步 folder.currentIndex
        folder?.currentIndex = index

        // 更新 UI（標題列和狀態列）
        updateWindowTitle()
        updateStatusBar()

        // 連續捲動模式下不執行 resize 動畫（使用 fit-to-width， 固定寬度）
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

        if isAutoFitActive {
            if let imageSize = currentDocumentSize {
                applyFitting(for: imageSize)
            }
        }

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
        if let imageSize = currentDocumentSize { applyFitting(for: imageSize) }
    }

    @objc func toggleShrinkV(_ sender: Any? = nil) {
        settings.fittingOptions.shrinkVertically.toggle()
        settings.save()
        if let imageSize = currentDocumentSize { applyFitting(for: imageSize) }
    }

    @objc func toggleStretchH(_ sender: Any? = nil) {
        settings.fittingOptions.stretchHorizontally.toggle()
        settings.save()
        if let imageSize = currentDocumentSize { applyFitting(for: imageSize) }
    }

    @objc func toggleStretchV(_ sender: Any? = nil) {
        settings.fittingOptions.stretchVertically.toggle()
        settings.save()
        if let imageSize = currentDocumentSize { applyFitting(for: imageSize) }
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

    // MARK: - File Actions

    @objc func copyImage(_ sender: Any? = nil) {
        let (item, page) = resolvedTarget()
        guard let item else { return }

        // Build payload first, then clear+write only if we have something to write.
        // Avoids emptying the clipboard when there's nothing to paste.
        let pb = NSPasteboard.general
        if item.isPDF {
            // PDF page: only write rendered image (URL points to whole PDF file).
            guard let image = page.image else { return }
            pb.clearContents()
            pb.writeObjects([image])
        } else {
            // Regular image: write both file URL and image data
            // NSURL provides file paste in Finder; NSImage provides TIFF for image editors
            pb.clearContents()
            if let image = page.image {
                pb.writeObjects([item.url as NSURL, image])
            } else {
                pb.writeObjects([item.url as NSURL])
            }
        }
    }

    @objc func revealInFinder(_ sender: Any? = nil) {
        let (item, _) = resolvedTarget()
        guard let item else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    /// Resolve the target for file actions: use context menu target if set, otherwise current image.
    /// Consumes (clears) the context menu target to prevent stale state.
    private func resolvedTarget() -> (item: ImageItem?, page: ImageContentView) {
        let result = (
            item: contextMenuTarget?.item ?? folder?.currentImage,
            page: contextMenuTarget?.page ?? contentView
        )
        contextMenuTarget = nil
        return result
    }

    // MARK: - Menu Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let isContinuous = settings.continuousScrollEnabled
        switch menuItem.action {
        case #selector(fitOnScreen(_:)):
            return true
        case #selector(actualSize(_:)):
            return true
        case #selector(toggleAlwaysFit(_:)):
            menuItem.state = settings.alwaysFitOnOpen ? .on : .off; return !isContinuous
        case #selector(toggleShrinkH(_:)):
            menuItem.state = settings.fittingOptions.shrinkHorizontally ? .on : .off; return !isContinuous
        case #selector(toggleShrinkV(_:)):
            menuItem.state = settings.fittingOptions.shrinkVertically ? .on : .off; return !isContinuous
        case #selector(toggleStretchH(_:)):
            menuItem.state = settings.fittingOptions.stretchHorizontally ? .on : .off; return !isContinuous
        case #selector(toggleStretchV(_:)):
            menuItem.state = settings.fittingOptions.stretchVertically ? .on : .off; return !isContinuous
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
        case #selector(toggleArrowLeftRightNav(_:)):
            menuItem.state = settings.arrowLeftRightNavigation ? .on : .off; return true
        case #selector(toggleArrowUpDownNav(_:)):
            menuItem.state = settings.arrowUpDownNavigation ? .on : .off; return true
        case #selector(toggleThumbnailFallback(_:)):
            menuItem.state = settings.thumbnailFallback ? .on : .off; return true
        case #selector(toggleQuickGridScrollAfterZoom(_:)):
            menuItem.state = settings.quickGridScrollAfterZoom ? .on : .off; return true
        case #selector(toggleResizeAutomatically(_:)):
            menuItem.state = settings.resizeWindowAutomatically ? .on : .off; return !isContinuous
        case #selector(fillWindowHeight(_:)):
            return view.window?.styleMask.contains(.fullScreen) == false
        case #selector(toggleFloatOnTop(_:)):
            menuItem.state = settings.floatOnTop ? .on : .off; return true
        case #selector(toggleStatusBar(_:)):
            menuItem.title = settings.showStatusBar
                ? String(localized: "menu.view.hideStatusBar")
                : String(localized: "menu.view.showStatusBar")
            return true
        case #selector(toggleQuickGrid(_:)):
            menuItem.state = quickGridView != nil ? .on : .off
            return folder != nil
        case #selector(toggleDualPage(_:)):
            menuItem.state = settings.dualPageEnabled ? .on : .off
            return !isContinuous
        case #selector(togglePageOffset(_:)):
            menuItem.state = settings.firstPageIsCover ? .on : .off
            return !isContinuous && settings.dualPageEnabled
        case #selector(toggleReadingDirection(_:)):
            let isRTL = settings.readingDirection.isRTL
            menuItem.state = isRTL ? .on : .off
            menuItem.title = isRTL
                ? String(localized: "menu.navigation.readingRTL")
                : String(localized: "menu.navigation.readingLTR")
            return !isContinuous && settings.dualPageEnabled
        case #selector(toggleDuoPageRTLNavigation(_:)):
            menuItem.state = settings.duoPageRTLNavigation ? .on : .off
            return !isContinuous && settings.dualPageEnabled
        case #selector(toggleSinglePageRTLNavigation(_:)):
            menuItem.state = settings.singlePageRTLNavigation ? .on : .off
            return !isContinuous && !settings.dualPageEnabled
        case #selector(toggleScrollToBottomOnPrevious(_:)):
            menuItem.state = settings.scrollToBottomOnPrevious ? .on : .off
            return true
        case #selector(toggleClickToTurnPage(_:)):
            menuItem.state = settings.clickToTurnPage ? .on : .off
            return !isContinuous
        case #selector(toggleContinuousScroll(_:)):
            menuItem.state = settings.continuousScrollEnabled ? .on : .off
            return true
        case #selector(setContinuousGap0(_:)):
            menuItem.state = settings.continuousScrollGap == 0 ? .on : .off
            return isContinuous
        case #selector(setContinuousGap2(_:)):
            menuItem.state = settings.continuousScrollGap == 2 ? .on : .off
            return isContinuous
        case #selector(setContinuousGap4(_:)):
            menuItem.state = settings.continuousScrollGap == 4 ? .on : .off
            return isContinuous
        case #selector(setContinuousGap8(_:)):
            menuItem.state = settings.continuousScrollGap == 8 ? .on : .off
            return isContinuous
        case #selector(ImageViewController.toggleFullScreen(_:)):
            let isFullscreen = view.window?.styleMask.contains(.fullScreen) == true
            menuItem.title = isFullscreen
                ? String(localized: "menu.view.exitFullScreen")
                : String(localized: "menu.view.enterFullScreen")
            return true
        case #selector(goToNextImage):
            menuItem.title = settings.dualPageEnabled
                ? String(localized: "menu.go.nextSpread")
                : String(localized: "menu.go.nextImage")
            return folder != nil
        case #selector(goToPreviousImage):
            menuItem.title = settings.dualPageEnabled
                ? String(localized: "menu.go.previousSpread")
                : String(localized: "menu.go.previousImage")
            return folder != nil
        case #selector(copyImage(_:)), #selector(revealInFinder(_:)):
            return folder?.currentImage != nil
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
              let imageSize = currentDocumentSize else { return }

        let anchorPoint = activeMagnifyAnchor ?? viewportCenterInDocumentCoordinates()
        let statusBarH = effectiveStatusBarHeight
        if DebugCentering.isEnabled {
            DebugCentering.log(
                "resizeWindowToFitZoomedImage mag=\(debugFloat(magnification)) " +
                "anchor=\(activeMagnifyAnchor != nil ? "locked" : "viewportCenter") \(debugPoint(anchorPoint))"
            )
        }
        let displayedSize = NSSize(
            width: imageSize.width * magnification,
            height: imageSize.height * magnification + statusBarH
        )
        (window.windowController as? ImageWindowController)?
            .resizeToFitImage(displayedSize, center: false)

        // Window resize 後 Auto Layout 可能 pixel-align scrollView bounds，
        // 導致 scrollView 比 imageSize * mag 小幾個 pixel。
        // 在 auto-fit 模式下重新校正 magnification 以匹配實際 viewport。
        if isAutoFitActive {
            view.layoutSubtreeIfNeeded()
            if let refitMagnification = fittedMagnification(for: imageSize),
               abs(refitMagnification - scrollView.magnification) > 1e-6 {
                isZooming = true
                scrollView.magnification = refitMagnification
                isZooming = false
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

        let docSize = documentView.frame.size
        // 當 anchor 超出 document bounds 時，改用 document 中心，避免 clamp 造成 rightward bias
        let effectiveAnchor: NSPoint
        if anchorPoint.x < 0 || anchorPoint.x > docSize.width ||
           anchorPoint.y < 0 || anchorPoint.y > docSize.height {
            effectiveAnchor = NSPoint(x: docSize.width / 2.0, y: docSize.height / 2.0)
            DebugCentering.log(
                "recenterViewport anchorOutOfBounds anchor=\(debugPoint(anchorPoint)) doc=\(debugSize(docSize)) " +
                "→ effectiveAnchor=\(debugPoint(effectiveAnchor))"
            )
        } else {
            effectiveAnchor = anchorPoint
        }

        let unclampedOrigin = NSPoint(
            x: effectiveAnchor.x - clipSize.width / 2.0,
            y: effectiveAnchor.y - clipSize.height / 2.0
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
            "recenterViewport anchor=\(debugPoint(effectiveAnchor)) clip=\(debugSize(clipSize)) doc=\(debugSize(documentView.frame.size)) " +
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
    func minimumMagnification(for scrollView: ImageScrollView) -> CGFloat { effectiveMinMagnification() }

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

        enterManualZoom()
        settings.magnification = magnification
        scheduleDebouncedSettingsSave()
        updateScalingQuality()

        // 連續捲動模式：GPU affine transform only, skip window resize / recenter
        if settings.continuousScrollEnabled {
            applyCenteringInsetsIfNeeded(reason: "magnify.continuous")
            updateStatusBarZoom(magnification)

            if gesturePhase.isEmpty || gesturePhase.contains(.ended) || gesturePhase.contains(.cancelled) {
                activeMagnifyAnchor = nil
                isZooming = false
                continuousScrollContentView?.endZoomSuppression(visibleBounds: scrollView.contentView.bounds)
            }
            return
        }

        applyCenteringInsetsIfNeeded(reason: "magnify.phase=\(debugPhase(gesturePhase))")

        if !gesturePhase.isEmpty, let anchor = activeMagnifyAnchor {
            recenterViewport(around: anchor)
            applyCenteringInsetsIfNeeded(reason: "magnify.recenter.phase=\(debugPhase(gesturePhase))")
        }

        updateStatusBarZoom(magnification)

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

    func scrollViewRequestNextImage(_ scrollView: ImageScrollView, amount: Int) { navigateNext(amount: amount) }
    func scrollViewRequestPreviousImage(_ scrollView: ImageScrollView, amount: Int) { navigatePrevious(amount: amount) }
    func scrollViewRequestFirstImage(_ scrollView: ImageScrollView) {
        if settings.continuousScrollEnabled {
            // Home: scroll to visual top (highest Y in unflipped coords)
            let clipView = self.scrollView.contentView
            guard let range = scrollRange(for: self.scrollView.contentInsets) else { return }
            clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: range.maxY))
            self.scrollView.reflectScrolledClipView(clipView)
            return
        }
        goToFirstImage()
    }

    func scrollViewRequestLastImage(_ scrollView: ImageScrollView) {
        if settings.continuousScrollEnabled {
            // End: scroll to visual bottom (lowest Y in unflipped coords)
            let clipView = self.scrollView.contentView
            guard let range = scrollRange(for: self.scrollView.contentInsets) else { return }
            clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: range.minY))
            self.scrollView.reflectScrolledClipView(clipView)
            return
        }
        goToLastImage()
    }
    func scrollViewRequestPageDown(_ scrollView: ImageScrollView) {
        if let grid = quickGridView {
            grid.pageDown()
            return
        }
        scrollPageDownOrNext()
    }
    func scrollViewRequestPageUp(_ scrollView: ImageScrollView) {
        if let grid = quickGridView {
            grid.pageUp()
            return
        }
        scrollPageUpOrPrev()
    }

    // MARK: - Drag and Drop (Phase 2: Browse Mode)

    /// Create ImageFolder from a dropped URL (handles both file and folder)
    private func imageFolderFromDrop(url: URL) -> ImageFolder {
        if URLFilter.isDirectory(url) {
            // Folder: use dedicated initializer to scan folder directly
            return ImageFolder(folderURL: url)
        } else {
            // File: use existing logic (extracts parent folder)
            return ImageFolder(containing: url)
        }
    }

    /// Load a folder and update window title (reduces code duplication)
    private func loadFolderAndSetTitle(_ folder: ImageFolder) {
        loadFolder(folder)
        (view.window?.windowController as? ImageWindowController)?
            .updateTitle(folder: folder)
    }

    func scrollViewDidReceiveDrop(_ scrollView: ImageScrollView, urls: [URL]) {
        handleDrop(urls: urls)
    }

    private func handleDrop(urls: [URL]) {
        guard let url = urls.first else { return }  // Use first item

        // Folders always open fresh (no same-folder optimization)
        if URLFilter.isDirectory(url) {
            loadFolderAndSetTitle(imageFolderFromDrop(url: url))
            return
        }

        // File: check for same-folder optimization
        let targetFolderURL = url.deletingLastPathComponent()
        if let currentFolder = folder, currentFolder.folderURL == targetFolderURL {
            // Same folder: try to navigate without reloading
            if let index = currentFolder.images.firstIndex(where: { $0.url == url }) {
                currentFolder.currentIndex = index
                // Sync spread index and reload current image (no folder scan needed)
                if settings.dualPageEnabled {
                    currentFolder.syncSpreadIndex()
                }
                loadCurrentImage(initialScroll: .top)
                updateWindowTitle()
                // Refresh grid if visible (same-folder doesn't go through loadFolder)
                if let grid = quickGridView {
                    grid.configure(items: currentFolder.images, currentIndex: index, loader: loader)
                }
                return  // Only return on successful optimization
            }
            // If not found, fall through to reload folder (new file case)
        }

        // Different folder or new file in same folder: create new folder and load
        loadFolderAndSetTitle(imageFolderFromDrop(url: url))
    }

    func scrollViewRequestToggleQuickGrid(_ scrollView: ImageScrollView) {
        toggleQuickGrid()
    }

    func scrollViewOptionScrollNavigate(_ scrollView: ImageScrollView, forward: Bool, amount: Int) {
        guard optionScrollNavigate(forward: forward, amount: amount) else { return }
        guard let folder else { return }
        showPositionHUD(current: folder.currentIndex + 1, total: folder.images.count)
    }

    /// Phase 3: Option+scroll 專用導航，繞過 NavigationThrottle（accumulator 已是速率控制器）
    /// - Returns: 是否有實際移動
    @discardableResult
    private func optionScrollNavigate(forward: Bool, amount: Int) -> Bool {
        guard let folder, !folder.images.isEmpty else { return false }
        let direction: PrefetchDirection = forward ? .forward : .backward
        lastPrefetchDirection = direction
        var moved = false
        for _ in 0..<amount {
            if settings.dualPageEnabled {
                if forward {
                    if folder.goNextSpread() { moved = true }
                } else {
                    if folder.goPreviousSpread() { moved = true }
                }
            } else {
                if forward {
                    if folder.goNext(amount: 1) { moved = true }
                } else {
                    if folder.goPrevious(amount: 1) { moved = true }
                }
            }
        }
        guard moved else { return false }
        let scroll: InitialScrollPosition = forward ? .top : .bottom
        loadCurrentImage(initialScroll: scroll, thumbnailOnly: settings.thumbnailFallback)
        scheduleFullResLoad()
        updateWindowTitle()
        return true
    }

    // MARK: - Position HUD (Phase 3)

    private func ensurePositionHUD() {
        if positionHUDView == nil {
            let hud = PositionHUDView()
            hud.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(hud)
            NSLayoutConstraint.activate([
                hud.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                hud.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -effectiveStatusBarHeight / 2),
                hud.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
                hud.heightAnchor.constraint(equalToConstant: 72),
            ])
            positionHUDView = hud
        }
    }

    private func showPositionHUD(current: Int, total: Int) {
        ensurePositionHUD()
        positionHUDView?.show(current: current, total: total)
    }

    private func showPositionHUD(message: String, fadeDelay: TimeInterval = Constants.positionHUDFadeDelay) {
        ensurePositionHUD()
        positionHUDView?.show(message: message, fadeDelay: fadeDelay)
    }

    private func dismissPositionHUD() {
        positionHUDView?.dismiss()
        positionHUDView?.removeFromSuperview()
        positionHUDView = nil
    }

    // MARK: - Context Menu

    func contextMenu(for scrollView: ImageScrollView, event: NSEvent) -> NSMenu? {
        resolveContextMenuTarget(event: event)
        return buildContextMenu()
    }

    /// Determine which page the user right-clicked in dual page mode.
    private func resolveContextMenuTarget(event: NSEvent) {
        // Default to leading page
        guard let folder, let item = folder.currentImage else {
            contextMenuTarget = nil
            return
        }
        contextMenuTarget = (page: contentView, item: item)

        // In dual page mode, check if trailing page was clicked
        guard settings.dualPageEnabled,
              let trailing = dualPageView.trailingPage,
              let spread = folder.currentSpread,
              case .double(_, _, _, let trailingItem) = spread else { return }

        let point = dualPageView.convert(event.locationInWindow, from: nil)
        if trailing.frame.contains(point) {
            contextMenuTarget = (page: trailing, item: trailingItem)
        }
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Context")

        // Group 1: Zoom
        menu.addItem(makeContextItem(String(localized: "menu.view.fitOnScreen"), action: #selector(fitOnScreen(_:))))
        menu.addItem(makeContextItem(String(localized: "menu.view.actualSize"), action: #selector(actualSize(_:))))

        menu.addItem(NSMenuItem.separator())

        // Group 2: Display Mode
        menu.addItem(makeContextItem(String(localized: "menu.view.alwaysFit"), action: #selector(toggleAlwaysFit(_:))))
        menu.addItem(makeFittingOptionsSubmenu())
        menu.addItem(makeDualPageSubmenu())
        menu.addItem(makeContextItem(String(localized: "menu.navigation.rtlSingle"),     action: #selector(toggleSinglePageRTLNavigation(_:))))
        menu.addItem(makeContextItem(String(localized: "menu.navigation.continuousScroll"), action: #selector(toggleContinuousScroll(_:))))
        menu.addItem(makeContextItem(String(localized: "menu.view.fillWindowHeight"), action: #selector(fillWindowHeight(_:))))
        menu.addItem(makeContextItem(String(localized: "menu.view.floatOnTop"), action: #selector(toggleFloatOnTop(_:))))
        menu.addItem(makeContextItem(String(localized: "menu.navigation.quickGrid"), action: #selector(toggleQuickGrid(_:))))

        menu.addItem(NSMenuItem.separator())

        // Group 3: File Actions
        menu.addItem(makeContextItem(String(localized: "menu.file.copyImage"), action: #selector(copyImage(_:))))
        menu.addItem(makeContextItem(String(localized: "menu.file.revealInFinder"), action: #selector(revealInFinder(_:))))

        return menu
    }

    private func makeContextItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = nil  // 走 first responder chain
        return item
    }

    private func makeFittingOptionsSubmenu() -> NSMenuItem {
        let submenu = NSMenu(title: String(localized: "menu.view.fittingOptions"))
        submenu.addItem(makeContextItem(String(localized: "menu.view.shrinkH"),  action: #selector(toggleShrinkH(_:))))
        submenu.addItem(makeContextItem(String(localized: "menu.view.shrinkV"),  action: #selector(toggleShrinkV(_:))))
        submenu.addItem(makeContextItem(String(localized: "menu.view.stretchH"), action: #selector(toggleStretchH(_:))))
        submenu.addItem(makeContextItem(String(localized: "menu.view.stretchV"), action: #selector(toggleStretchV(_:))))

        let item = NSMenuItem(title: String(localized: "menu.view.fittingOptions"), action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func makeDualPageSubmenu() -> NSMenuItem {
        let submenu = NSMenu(title: String(localized: "menu.navigation.dualPage"))
        submenu.addItem(makeContextItem(String(localized: "menu.navigation.dualPage"),      action: #selector(toggleDualPage(_:))))
        submenu.addItem(NSMenuItem.separator())
        submenu.addItem(makeContextItem(String(localized: "menu.navigation.firstPageCover"), action: #selector(togglePageOffset(_:))))
        // Initial label matches AppDelegate; validateMenuItem dynamically updates it
        submenu.addItem(makeContextItem(String(localized: "menu.navigation.readingLTR"),    action: #selector(toggleReadingDirection(_:))))
        submenu.addItem(makeContextItem(String(localized: "menu.navigation.rtlDual"),       action: #selector(toggleDuoPageRTLNavigation(_:))))

        let item = NSMenuItem(title: String(localized: "menu.navigation.dualPage"), action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }
}

// MARK: - EmptyStateViewDelegate

extension ImageViewController: EmptyStateView.Delegate {
    func emptyStateViewDidReceiveDrop(_ view: EmptyStateView, urls: [URL]) {
        handleDrop(urls: urls)
    }
}

// MARK: - QuickGridViewDelegate

extension ImageViewController: QuickGridViewDelegate {
    func quickGridView(_ view: QuickGridView, didReceiveDrop urls: [URL]) {
        handleDrop(urls: urls)
    }

    func quickGridView(_ view: QuickGridView, didSelectItemAt index: Int) {
        dismissQuickGrid()
        guard let folder else { return }
        folder.currentIndex = index

        if settings.continuousScrollEnabled {
            scrollToCurrentImageInContinuousMode()
            updateWindowTitle()
            updateStatusBar()
            return
        }

        if settings.dualPageEnabled {
            folder.syncSpreadIndex()
        }
        loadCurrentImage(initialScroll: .top)
        updateWindowTitle()
    }

    func quickGridViewDidRequestClose(_ view: QuickGridView) {
        dismissQuickGrid()
    }
}
