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
        self.view = scrollView
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        loadCurrentImage()
    }

    /// 視窗重用時載入新資料夾
    func loadFolder(_ newFolder: ImageFolder) {
        self.folder = newFolder
        loadCurrentImage()
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

    // MARK: - Window Title Update

    func updateWindowTitle() {
        (view.window?.windowController as? ImageWindowController)?
            .updateTitle(folder: folder)
    }
}
