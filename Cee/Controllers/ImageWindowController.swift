import AppKit

class ImageWindowController: NSWindowController {

    /// 靜態持有，防止 ARC 釋放；同時實現單視窗重用策略
    private static var shared: ImageWindowController?

    // MARK: - Phase 4: Window Size Memory
    private var resizeSaveTask: DispatchWorkItem?
    private var isTransitioningFullScreen = false

    // MARK: - Empty State Launch

    /// Open empty state window (for drag-drop onboarding)
    static func openEmpty() {
        // Reuse existing window
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        // Create new window with empty state
        let windowSize = savedOrDefaultWindowSize()
        let viewController = ImageViewController(folder: nil)  // nil = empty state

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
        window.contentViewController = viewController
        window.center()
        window.setAccessibilityIdentifier("imageWindow")

        let controller = ImageWindowController(window: window)
        shared = controller
        controller.showWindow(nil)
        controller.ensureUsableWindowSize()
        controller.setupResizeObserver()

        // Empty state title
        controller.window?.title = "Cee"
        controller.window?.subtitle = ""
    }

    static func open(with url: URL) {
        let folder = ImageFolder(containing: url)

        if let existing = shared, let vc = existing.contentViewController as? ImageViewController {
            // 重用現有視窗，載入新資料夾
            vc.loadFolder(folder)
            existing.updateTitle(folder: folder)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        // 首次建立視窗，優先使用儲存的視窗大小，否則用螢幕 80%
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
        window.contentViewController = viewController
        window.center()
        window.setAccessibilityIdentifier("imageWindow")  // Phase 6: UI test anchor

        let controller = ImageWindowController(window: window)
        shared = controller  // 靜態持有，防止 ARC 釋放
        controller.showWindow(nil)
        controller.ensureUsableWindowSize()
        controller.setupResizeObserver()
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

    private func setupResizeObserver() {
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
        window?.subtitle = item.pdfPageIndex.map { "Page \($0 + 1)" } ?? ""
    }
}
