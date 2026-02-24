import AppKit

class ImageWindowController: NSWindowController {

    /// 靜態持有，防止 ARC 釋放；同時實現單視窗重用策略
    private static var shared: ImageWindowController?

    static func open(with url: URL) {
        let folder = ImageFolder(containing: url)

        if let existing = shared, let vc = existing.contentViewController as? ImageViewController {
            // 重用現有視窗，載入新資料夾
            vc.loadFolder(folder)
            existing.updateTitle(folder: folder)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        // 首次建立視窗，使用螢幕可見區域 80%
        let windowSize = defaultWindowSize()
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
        controller.updateTitle(folder: folder)
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

    func updateTitle(folder: ImageFolder) {
        guard let item = folder.currentImage else {
            window?.title = "Cee"
            return
        }
        let position = "\(folder.currentIndex + 1)/\(folder.images.count)"
        window?.title = "\(item.fileName) (\(position))"
    }
}
