import AppKit

class ImageWindowController: NSWindowController {

    /// 靜態持有，防止 ARC 釋放；同時實現單視窗重用策略
    private static var shared: ImageWindowController?

    // MARK: - Phase 4: Window Size Memory
    private var resizeSaveTask: DispatchWorkItem?
    private var isTransitioningFullScreen = false

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
        window.contentViewController = viewController
        window.center()

        let controller = ImageWindowController(window: window)
        shared = controller  // 靜態持有，防止 ARC 釋放
        controller.showWindow(nil)
        controller.setupResizeObserver()
        controller.updateTitle(folder: folder)
    }

    /// 從 ViewerSettings 讀取儲存的視窗大小；若未儲存則用螢幕可見區域 80%
    private static func savedOrDefaultWindowSize() -> NSSize {
        let settings = ViewerSettings.load()
        if let w = settings.lastWindowWidth, let h = settings.lastWindowHeight, w > 0, h > 0 {
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
        nc.addObserver(self, selector: #selector(windowDidExitFullScreen(_:)),
                       name: NSWindow.didExitFullScreenNotification, object: window)
    }

    @objc private func windowWillEnterFullScreen(_ notification: Notification) {
        isTransitioningFullScreen = true
    }

    @objc private func windowDidExitFullScreen(_ notification: Notification) {
        isTransitioningFullScreen = false
    }

    @objc private func windowDidResizeNotification(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              !window.styleMask.contains(.fullScreen),
              !isTransitioningFullScreen else { return }

        resizeSaveTask?.cancel()
        let size = window.contentView?.bounds.size ?? window.frame.size
        let task = DispatchWorkItem {
            var settings = ViewerSettings.load()
            settings.lastWindowWidth = size.width
            settings.lastWindowHeight = size.height
            settings.save()
        }
        resizeSaveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
    }

    // MARK: - Resize to Fit Image

    func resizeToFitImage(_ size: NSSize) {
        guard let window, let screen = window.screen else { return }
        let maxSize = screen.visibleFrame.size
        let targetSize = NSSize(
            width: min(size.width, maxSize.width),
            height: min(size.height, maxSize.height)
        )
        window.setContentSize(targetSize)
        window.center()
    }

    // MARK: - Window Title

    func updateTitle(folder: ImageFolder) {
        guard let item = folder.currentImage else {
            window?.title = "Cee"
            return
        }
        let position = "\(folder.currentIndex + 1)/\(folder.images.count)"
        window?.title = "\(item.fileName) (\(position))"
    }
}
