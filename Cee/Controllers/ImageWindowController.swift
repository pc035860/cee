import AppKit

class ImageWindowController: NSWindowController {

    /// 所有開啟的視窗控制器；multi-instance 支援
    private static var windows: [ImageWindowController] = []

    // MARK: - Phase 4: Window Size Memory
    private var resizeSaveTask: DispatchWorkItem?
    private var isTransitioningFullScreen = false

    /// 取得當前活動的視窗控制器（用於復用模式）
    /// 優先使用有鍵盤焦點的視窗，次要才用最後建立的視窗
    private static var current: ImageWindowController? {
        let active = (NSApp.keyWindow?.windowController ?? NSApp.mainWindow?.windowController) as? ImageWindowController
        return active ?? windows.last
    }

    // MARK: - Empty State Launch

    /// Open empty state window (for drag-drop onboarding)
    static func openEmpty() {
        let settings = ViewerSettings.load()

        // 復用模式：如果已有視窗，直接帶到前景
        if settings.reuseWindow, let existing = current {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        // 建立新視窗
        createWindow(with: nil)
    }

    /// Open URL (called from Finder or file open dialog)
    static func open(with url: URL) {
        let folder = ImageFolder(containing: url)
        let settings = ViewerSettings.load()

        // 復用模式：重用現有視窗
        if settings.reuseWindow, let existing = current, let vc = existing.contentViewController as? ImageViewController {
            vc.loadFolder(folder)
            existing.updateTitle(folder: folder)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        // 建立新視窗
        createWindow(with: folder)
    }

    /// 建立新視窗（內部方法）
    private static func createWindow(with folder: ImageFolder?) {
        let windowSize = savedOrDefaultWindowSize()
        let viewController = ImageViewController(folder: folder)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowSize.width, height: windowSize.height),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(
            width: Constants.minWindowContentWidth,
            height: Constants.minWindowContentHeight
        )
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.contentViewController = viewController
        window.center()
        window.setAccessibilityIdentifier("imageWindow")

        let controller = ImageWindowController(window: window)
        windows.append(controller)  // 加入 collection
        controller.showWindow(nil)
        controller.ensureUsableWindowSize()
        controller.setupWindowObservers()
        controller.updateTitle(folder: folder)
    }

    /// 從 ViewerSettings 讀取儲存的視窗大小；若未儲存則用螢幕可見區域 80%
    private static func savedOrDefaultWindowSize() -> NSSize {
        let settings = ViewerSettings.load()
        if let w = settings.lastWindowWidth,
           let h = settings.lastWindowHeight,
           w >= Constants.minWindowContentWidth,
           h >= Constants.minWindowContentHeight {
            return NSSize(width: w, height: h)
        }
        return defaultWindowSize()
    }

    private static func defaultWindowSize() -> NSSize {
        guard let screen = NSScreen.main else {
            return NSSize(width: Constants.defaultWindowWidth, height: Constants.defaultWindowHeight)
        }
        let ratio = Constants.defaultWindowSizeRatio
        return NSSize(
            width: screen.visibleFrame.width * ratio,
            height: screen.visibleFrame.height * ratio
        )
    }

    // MARK: - Phase 4: Resize Observer

    private func setupWindowObservers() {
        guard let window = window else { return }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(windowDidResizeNotification(_:)),
                       name: NSWindow.didResizeNotification, object: window)
        nc.addObserver(self, selector: #selector(windowWillEnterFullScreen(_:)),
                       name: NSWindow.willEnterFullScreenNotification, object: window)
        nc.addObserver(self, selector: #selector(windowDidEnterFullScreen(_:)),
                       name: NSWindow.didEnterFullScreenNotification, object: window)
        nc.addObserver(self, selector: #selector(windowDidExitFullScreen(_:)),
                       name: NSWindow.didExitFullScreenNotification, object: window)
        // Multi-instance: 視窗關閉時從 collection 移除
        nc.addObserver(self, selector: #selector(windowWillCloseNotification(_:)),
                       name: NSWindow.willCloseNotification, object: window)
    }

    @objc private func windowWillCloseNotification(_ notification: Notification) {
        // 清理 CADisplayLink 防止記憶體洩漏
        resizeDisplayLink?.invalidate()
        resizeDisplayLink = nil
        Self.windows.removeAll { $0 === self }
    }

    @objc private func windowWillEnterFullScreen(_ notification: Notification) {
        isTransitioningFullScreen = true
        DebugCentering.log("windowWillEnterFullScreen transitioning=true")
    }

    @objc private func windowDidEnterFullScreen(_ notification: Notification) {
        isTransitioningFullScreen = false
        DebugCentering.log("windowDidEnterFullScreen transitioning=false")
        notifyFullscreenTransitionCompleted()
    }

    @objc private func windowDidExitFullScreen(_ notification: Notification) {
        isTransitioningFullScreen = false
        DebugCentering.log("windowDidExitFullScreen transitioning=false")
        notifyFullscreenTransitionCompleted()
    }

    private func notifyFullscreenTransitionCompleted() {
        DebugCentering.log("notifyFullscreenTransitionCompleted dispatch")
        Task { @MainActor [weak self] in
            guard let self,
                  let vc = self.window?.contentViewController as? ImageViewController else { return }
            DebugCentering.log("notifyFullscreenTransitionCompleted invoke VC handler")
            vc.handleFullscreenTransitionDidComplete()
        }
    }

    @objc private func windowDidResizeNotification(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              !window.styleMask.contains(.fullScreen),
              !isTransitioningFullScreen else { return }

        resizeSaveTask?.cancel()
        let size = window.contentView?.bounds.size ?? window.frame.size
        guard size.width >= Constants.minWindowContentWidth,
              size.height >= Constants.minWindowContentHeight else {
            return
        }
        let task = DispatchWorkItem {
            var settings = ViewerSettings.load()
            settings.lastWindowWidth = size.width
            settings.lastWindowHeight = size.height
            settings.save()
        }
        resizeSaveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
    }

    private func ensureUsableWindowSize() {
        guard let window else { return }
        DispatchQueue.main.async {
            let size = window.contentView?.bounds.size ?? window.frame.size
            guard size.width < Constants.minWindowContentWidth ||
                  size.height < Constants.minWindowContentHeight else { return }
            window.setContentSize(Self.defaultWindowSize())
            window.center()
        }
    }

    // MARK: - Resize to Fit Image

    func resizeToFitImage(_ size: NSSize, center: Bool = true) {
        guard let window,
              let screen = window.screen,
              !window.styleMask.contains(.fullScreen) else { return }
        let visibleFrame = screen.visibleFrame
        let maxSize = visibleFrame.size
        var targetSize = NSSize(
            width: min(size.width, maxSize.width),
            height: min(size.height, maxSize.height)
        )
        // 當 requested size 低於視窗 minimum 時，視窗不會再縮小。
        // 若仍依計算值移動 origin，會造成「視窗往右漂移」。
        // 改為不變更視窗（early return），避免漂移。
        if !center {
            let currentContent = window.contentRect(forFrameRect: window.frame).size
            let minFrame = NSRect(origin: .zero, size: window.minSize)
            let effectiveMinContent = window.contentRect(forFrameRect: minFrame).size
            let wouldShrink = targetSize.width < currentContent.width || targetSize.height < currentContent.height
            let belowMin = targetSize.width < effectiveMinContent.width || targetSize.height < effectiveMinContent.height
            if wouldShrink && belowMin {
                DebugCentering.log(
                    "resizeToFitImage skip: target=\(String(format: "%.1f×%.1f", targetSize.width, targetSize.height)) " +
                    "< minContent=\(String(format: "%.0f×%.0f", effectiveMinContent.width, effectiveMinContent.height)) " +
                    "current=\(String(format: "%.1f×%.1f", currentContent.width, currentContent.height))"
                )
                return
            }
        }
        let currentCenter = NSPoint(x: window.frame.midX, y: window.frame.midY)
        let targetFrameSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: targetSize)
        ).size
        var targetFrame = NSRect(origin: .zero, size: targetFrameSize)

        if center {
            targetFrame.origin = NSPoint(
                x: visibleFrame.midX - targetFrame.width / 2.0,
                y: visibleFrame.midY - targetFrame.height / 2.0
            )
        } else {
            targetFrame.origin = NSPoint(
                x: currentCenter.x - targetFrame.width / 2.0,
                y: currentCenter.y - targetFrame.height / 2.0
            )
        }

        targetFrame.origin = clampedWindowOrigin(
            for: targetFrame,
            within: visibleFrame
        )
        if DebugCentering.isEnabled {
            let before = window.frame
            DebugCentering.log(
                "resizeToFitImage before frame=\(String(format: "%.1f,%.1f %.1f×%.1f", before.origin.x, before.origin.y, before.width, before.height)) " +
                "target=\(String(format: "%.1f,%.1f %.1f×%.1f", targetFrame.origin.x, targetFrame.origin.y, targetFrame.width, targetFrame.height)) " +
                "center=\(center)"
            )
        }
        window.setFrame(targetFrame, display: true, animate: false)
        if DebugCentering.isEnabled {
            let after = window.frame
            DebugCentering.log(
                "resizeToFitImage after frame=\(String(format: "%.1f,%.1f %.1f×%.1f", after.origin.x, after.origin.y, after.width, after.height))"
            )
        }
    }

    private func clampedWindowOrigin(for frame: NSRect, within visibleFrame: NSRect) -> NSPoint {
        let minX = visibleFrame.minX
        let minY = visibleFrame.minY
        let maxX = max(visibleFrame.maxX - frame.width, minX)
        let maxY = max(visibleFrame.maxY - frame.height, minY)

        return NSPoint(
            x: min(max(frame.origin.x, minX), maxX),
            y: min(max(frame.origin.y, minY), maxY)
        )
    }

    // MARK: - Phase 2: Continuous Scroll Animated Resize

    private var resizeDisplayLink: CADisplayLink?
    private var resizeAnimationStartFrame: NSRect = .zero
    private var resizeAnimationTargetSize: NSSize = .zero
    private var resizeAnimationStartTime: CFTimeInterval = 0
    private var resizeAnimationDuration: CFTimeInterval = 0.25
    private var resizeAnimationPreserveCenter: Bool = true

    /// 使用 CADisplayLink 執行動態視窗 resize（macOS 14+）
    /// - Parameters:
    ///   - targetSize: 目標視窗大小
    ///   - preserveCenter: 是否保持視窗中心點位置
    func animateResize(to targetSize: NSSize, preserveCenter: Bool = true) {
        guard let window = window else { return }

        // 全螢幕模式下跳過 resize
        guard !window.styleMask.contains(.fullScreen) else { return }

        // 連續捲動模式下跳過 resize（使用 fit-to-width，固定寬度）
        if let vc = contentViewController as? ImageViewController, vc.settings.continuousScrollEnabled {
            return
        }

        // 建立或重用 display link
        let displayLink: CADisplayLink
        if let existing = resizeDisplayLink {
            displayLink = existing
        } else {
            displayLink = window.displayLink(target: self, selector: #selector(resizeAnimationStep(_:)))
            resizeDisplayLink = displayLink
        }

        // 設定動畫參數
        resizeAnimationStartFrame = window.frame
        resizeAnimationTargetSize = targetSize
        resizeAnimationStartTime = CACurrentMediaTime()
        resizeAnimationPreserveCenter = preserveCenter

        displayLink.isPaused = false
    }

    @objc private func resizeAnimationStep(_ link: CADisplayLink) {
        guard let window = window else {
            link.invalidate()
            resizeDisplayLink = nil
            return
        }

        let elapsed = CACurrentMediaTime() - resizeAnimationStartTime
        let progress = min(1.0, elapsed / resizeAnimationDuration)

        // Ease-in-out 曲線
        let easedProgress = easeInOut(progress)

        // 插值計算當前 size
        let currentSize = interpolateSize(
            from: resizeAnimationStartFrame.size,
            to: resizeAnimationTargetSize,
            progress: easedProgress
        )

        var currentFrame: NSRect
        if resizeAnimationPreserveCenter {
            currentFrame = centeredFrame(for: currentSize, relativeTo: resizeAnimationStartFrame)
        } else {
            currentFrame = NSRect(
                x: resizeAnimationStartFrame.origin.x,
                y: resizeAnimationStartFrame.origin.y,
                width: currentSize.width,
                height: currentSize.height
            )
        }

        // 螢幕邊界限制
        if let screen = window.screen {
            currentFrame = clampToScreen(currentFrame, screen: screen)
        }

        window.setFrame(currentFrame, display: true)

        // 動畫完成
        if progress >= 1.0 {
            link.isPaused = true
            link.invalidate()
            resizeDisplayLink = nil
        }
    }

    private func easeInOut(_ t: CGFloat) -> CGFloat {
        return t < 0.5
            ? 2 * t * t
            : 1 - pow(-2 * t + 2, 2) / 2
    }

    private func interpolateSize(from: NSSize, to: NSSize, progress: CGFloat) -> NSSize {
        NSSize(
            width: from.width + (to.width - from.width) * progress,
            height: from.height + (to.height - from.height) * progress
        )
    }

    private func centeredFrame(for newSize: NSSize, relativeTo current: NSRect) -> NSRect {
        let cx = current.midX
        let cy = current.midY
        return NSRect(
            x: cx - newSize.width / 2,
            y: cy - newSize.height / 2,
            width: newSize.width,
            height: newSize.height
        )
    }

    private func clampToScreen(_ frame: NSRect, screen: NSScreen) -> NSRect {
        let screenFrame = screen.visibleFrame
        var clampedFrame = frame

        // 確保視窗不超出螢幕
        if frame.maxX > screenFrame.maxX {
            clampedFrame.origin.x = screenFrame.maxX - frame.width
        }
        if frame.minX < screenFrame.minX {
            clampedFrame.origin.x = screenFrame.minX
        }
        if frame.maxY > screenFrame.maxY {
            clampedFrame.origin.y = screenFrame.maxY - frame.height
        }
        if frame.minY < screenFrame.minY {
            clampedFrame.origin.y = screenFrame.minY
        }

        return clampedFrame
    }

    // MARK: - Window Title

    func updateTitle(folder: ImageFolder?) {
        guard let folder else {
            window?.title = "Cee"
            window?.subtitle = ""
            return
        }
        guard let item = folder.currentImage else {
            window?.title = "Cee"
            window?.subtitle = ""
            return
        }
        // StatusBar 可見時索引在 bar 顯示，標題列不重複
        let showIndex = (contentViewController as? ImageViewController)
            .map { !$0.settings.showStatusBar } ?? true
        if showIndex {
            let position = "\(folder.currentIndex + 1)/\(folder.images.count)"
            window?.title = "\(item.url.lastPathComponent) (\(position))"
        } else {
            window?.title = item.url.lastPathComponent
        }
        window?.subtitle = item.pdfPageIndex.map { String(localized: "window.pdfPage \($0 + 1)") } ?? ""
    }
}
