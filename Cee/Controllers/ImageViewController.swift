import AppKit

class ImageViewController: NSViewController {
    private var folder: ImageFolder
    private let loader = ImageLoader()
    private var scrollView: ImageScrollView!
    private var contentView: ImageContentView!
    private var currentLoadRequestID: UUID?  // 防止快速翻頁時舊圖覆蓋新圖

    init(folder: ImageFolder) {
        self.folder = folder
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        contentView = ImageContentView()
        scrollView = ImageScrollView(frame: .zero)
        scrollView.documentView = contentView
        scrollView.scrollDelegate = self   // Phase 2: delegate for navigation + edge detection
        self.view = scrollView
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        loadCurrentImage()
        // 確保 scroll view 成為 first responder 以接收鍵盤事件
        view.window?.makeFirstResponder(scrollView)
    }

    /// 視窗重用時載入新資料夾
    func loadFolder(_ newFolder: ImageFolder) {
        self.folder = newFolder
        loadCurrentImage()
        view.window?.makeFirstResponder(scrollView)
    }

    // MARK: - Image Loading

    private func loadCurrentImage() {
        guard let item = folder.currentImage else { return }
        let requestID = UUID()
        currentLoadRequestID = requestID

        Task {
            guard let image = await loader.loadImage(at: item.url) else { return }

            // 防止快速翻頁時舊圖覆蓋新圖
            guard currentLoadRequestID == requestID else { return }

            contentView.image = image
            applyFitting(for: image.size)

            // 預載 ±2 張（傳入值型別避免 Swift 6 Sendable 問題）
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

        let options = FittingOptions()  // Default: shrink both, no stretch
        let fitted = FittingCalculator.calculate(
            imageSize: imageSize,
            viewportSize: viewportSize,
            options: options
        )
        let scale = fitted.width / imageSize.width
        scrollView.magnification = scale
    }

    // MARK: - Navigation

    func goToNextImage() {
        guard folder.goNext() else { return }
        loadCurrentImage()
        scrollView.scrollToTop()
        updateWindowTitle()
    }

    func goToPreviousImage() {
        guard folder.goPrevious() else { return }
        loadCurrentImage()
        scrollView.scrollToBottom()
        updateWindowTitle()
    }

    func goToFirstImage() {
        guard !folder.images.isEmpty else { return }
        folder.currentIndex = 0
        loadCurrentImage()
        scrollView.scrollToTop()
        updateWindowTitle()
    }

    func goToLastImage() {
        guard !folder.images.isEmpty else { return }
        folder.currentIndex = folder.images.count - 1
        loadCurrentImage()
        scrollView.scrollToTop()
        updateWindowTitle()
    }

    // MARK: - Space Key: Scroll Page Down or Next Image

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

    // MARK: - Window Title Update

    func updateWindowTitle() {
        (view.window?.windowController as? ImageWindowController)?
            .updateTitle(folder: folder)
    }
}

// MARK: - ImageScrollViewDelegate

extension ImageViewController: ImageScrollViewDelegate {
    func scrollViewDidReachBottom(_ scrollView: ImageScrollView) {
        goToNextImage()
    }

    func scrollViewDidReachTop(_ scrollView: ImageScrollView) {
        goToPreviousImage()
    }

    func scrollViewMagnificationDidChange(_ scrollView: ImageScrollView, magnification: CGFloat) {
        // Phase 3: save to ViewerSettings
    }

    func scrollViewRequestNextImage(_ scrollView: ImageScrollView) {
        goToNextImage()
    }

    func scrollViewRequestPreviousImage(_ scrollView: ImageScrollView) {
        goToPreviousImage()
    }

    func scrollViewRequestFirstImage(_ scrollView: ImageScrollView) {
        goToFirstImage()
    }

    func scrollViewRequestLastImage(_ scrollView: ImageScrollView) {
        goToLastImage()
    }

    func scrollViewRequestPageDown(_ scrollView: ImageScrollView) {
        scrollPageDownOrNext()
    }
}
