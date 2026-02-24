# Cee - Technical Specification

## 1. Technology Stack

| Category | Technology | Version | Notes |
|----------|-----------|---------|-------|
| Language | Swift | 6.2 | Xcode 26 內建 |
| IDE | Xcode | 26 | 最低需求 |
| UI Framework | AppKit | macOS 14+ | 核心圖片顯示 |
| Image Decoding | ImageIO | macOS 14+ | HEIC/WebP/JPEG XL 原生支援 |
| Target | macOS 14 Sonoma | arm64 | Apple Silicon only |
| Build System | Swift Package Manager | - | Xcode 內建 |
| 第三方依賴 | 無 | - | 純 Apple SDK |

## 2. Project Structure

```
Cee/
├── Cee.xcodeproj
├── Cee/
│   ├── App/
│   │   ├── AppDelegate.swift          # NSApplicationDelegate, Open With 處理
│   │   ├── MainMenu.xib               # 主選單（View menu 含 Fitting/Scaling 選項）
│   │   └── Info.plist                  # CFBundleDocumentTypes 設定
│   ├── Controllers/
│   │   ├── ImageWindowController.swift # 視窗管理、標題列更新
│   │   └── ImageViewController.swift   # 主檢視控制器，協調各元件
│   ├── Views/
│   │   ├── ImageScrollView.swift       # NSScrollView 子類，處理縮放與捲動
│   │   └── ImageContentView.swift      # NSView 子類，圖片繪製與插值控制
│   ├── Models/
│   │   ├── ImageFolder.swift           # 資料夾掃描、圖片列表管理
│   │   ├── ImageItem.swift             # 單張圖片資料模型
│   │   └── ViewerSettings.swift        # 使用者設定（縮放、Fitting、Scaling）
│   ├── Services/
│   │   ├── ImageLoader.swift           # 非同步圖片載入、快取、Lazy Loading
│   │   └── FittingCalculator.swift     # 圖片適配計算邏輯
│   └── Utilities/
│       └── Constants.swift             # 支援的檔案格式、預設值
├── PRD.md
├── SPEC.md
└── brainstorm-macos-image-viewer.md
```

## 3. Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│ AppDelegate                                             │
│  application(_:open:) ← macOS "Open With" 入口          │
└──────────┬──────────────────────────────────────────────┘
           │ 建立 / 傳遞 URL
┌──────────▼──────────────────────────────────────────────┐
│ ImageWindowController                                    │
│  - NSWindowController                                    │
│  - 管理視窗大小、標題、Float on Top                        │
│  - 全螢幕切換                                             │
└──────────┬──────────────────────────────────────────────┘
           │ contentViewController
┌──────────▼──────────────────────────────────────────────┐
│ ImageViewController                                      │
│  - 協調 ImageFolder + ImageScrollView + ImageLoader      │
│  - 處理鍵盤快捷鍵                                         │
│  - 管理當前圖片索引與翻頁邏輯                               │
└──────┬──────────┬──────────────┬────────────────────────┘
       │          │              │
┌──────▼───┐ ┌───▼──────┐ ┌────▼──────────┐
│ImageFolder│ │ImageLoader│ │ImageScrollView│
│ 掃描資料夾 │ │ 非同步載入  │ │ 縮放+捲動     │
│ 圖片排序   │ │ Lazy Cache│ │ 翻頁偵測      │
└──────────┘ └──────────┘ │ ImageContent- │
                          │ View (繪製)   │
                          └───────────────┘
```

### 設計原則
- **MVC 架構**：AppKit 原生模式，Controller 協調 Model 和 View
- **單一職責**：每個類別只負責一件事
- **依賴注入**：ImageViewController 接收 URL，不自行決定資料來源
- **無第三方依賴**：全部使用 Apple SDK

## 4. Core Components

### 4.1 AppDelegate — Open With 入口

```swift
// AppDelegate.swift
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        ImageWindowController.open(with: url)
    }
}
```

**Info.plist — CFBundleDocumentTypes：**

```xml
<key>CFBundleDocumentTypes</key>
<array>
  <dict>
    <key>CFBundleTypeName</key>
    <string>Image</string>
    <key>CFBundleTypeRole</key>
    <string>Viewer</string>
    <key>LSHandlerRank</key>
    <string>Alternate</string>
    <key>LSItemContentTypes</key>
    <array>
      <string>public.jpeg</string>
      <string>public.png</string>
      <string>public.tiff</string>
      <string>public.heic</string>
      <string>public.heif</string>
      <string>com.compuserve.gif</string>
      <string>org.webmproject.webp</string>
      <string>public.bmp</string>
    </array>
  </dict>
</array>
```

### 4.2 ImageItem — 圖片資料模型

```swift
// ImageItem.swift
import Foundation

struct ImageItem: Equatable {
    let url: URL
    var fileName: String { url.lastPathComponent }
}

// MARK: - Safe Array Subscript

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
```

### 4.3 Constants — 常數定義

```swift
// Constants.swift
import Foundation

enum Constants {
    static let defaultWindowWidth: CGFloat = 800
    static let defaultWindowHeight: CGFloat = 600
    static let cacheRadius: Int = 2           // 預載當前 ±2 張
    static let scrollEdgeThreshold: CGFloat = 2.0  // 捲動邊界容差 px
    static let zoomStep: CGFloat = 0.25       // 鍵盤縮放步進
    static let minMagnification: CGFloat = 0.1
    static let maxMagnification: CGFloat = 10.0
}
```

### 4.4 ImageFolder — 資料夾掃描

```swift
// ImageFolder.swift
import Foundation
import UniformTypeIdentifiers

class ImageFolder {
    let folderURL: URL
    private(set) var images: [ImageItem] = []
    var currentIndex: Int = 0

    static let supportedTypes: Set<UTType> = [
        .jpeg, .png, .tiff, .heic, .heif, .gif, .webP, .bmp
    ]

    init(containing fileURL: URL) {
        self.folderURL = fileURL.deletingLastPathComponent()
        self.images = scanFolder()
        self.currentIndex = images.firstIndex { $0.url == fileURL } ?? 0
    }

    private func scanFolder() -> [ImageItem] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.contentTypeKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return contents
            .filter { url in
                guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
                else { return false }
                return Self.supportedTypes.contains(where: { type.conforms(to: $0) })
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { ImageItem(url: $0) }
    }

    var currentImage: ImageItem? { images[safe: currentIndex] }
    var hasNext: Bool { currentIndex < images.count - 1 }
    var hasPrevious: Bool { currentIndex > 0 }

    @discardableResult
    func goNext() -> Bool {
        guard hasNext else { return false }
        currentIndex += 1
        return true
    }

    @discardableResult
    func goPrevious() -> Bool {
        guard hasPrevious else { return false }
        currentIndex -= 1
        return true
    }
}
```

### 4.3 ImageLoader — 非同步載入與快取

```swift
// ImageLoader.swift
import AppKit
import ImageIO

/// 使用 actor 確保快取的執行緒安全
actor ImageLoader {
    private var cache: [URL: NSImage] = [:]
    private let cacheRadius = Constants.cacheRadius

    func loadImage(at url: URL) async -> NSImage? {
        if let cached = cache[url] { return cached }

        // 在背景 Task 解碼，避免阻塞 MainActor
        let image = await Task.detached(priority: .userInitiated) {
            Self.decodeImage(at: url)
        }.value

        if let image { cache[url] = image }
        return image
    }

    /// 使用 ImageIO 高效解碼（避免全圖解壓到記憶體）
    private static func decodeImage(at url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldAllowFloat: true
        ]
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(
            width: cgImage.width,
            height: cgImage.height
        ))
    }

    /// 預載周圍圖片，釋放遠離的快取
    func updateCache(for folder: ImageFolder) {
        let current = folder.currentIndex
        guard !folder.images.isEmpty else { return }
        let range = max(0, current - cacheRadius)...min(folder.images.count - 1, current + cacheRadius)

        // 釋放超出範圍的快取
        let activeURLs = Set(range.map { folder.images[$0].url })
        cache = cache.filter { activeURLs.contains($0.key) }

        // 預載範圍內圖片
        for i in range {
            let url = folder.images[i].url
            if cache[url] == nil {
                Task { _ = await loadImage(at: url) }
            }
        }
    }
}
```

### 4.4 ImageScrollView — 縮放與捲動核心

```swift
// ImageScrollView.swift
import AppKit

protocol ImageScrollViewDelegate: AnyObject {
    func scrollViewDidReachBottom(_ scrollView: ImageScrollView)
    func scrollViewDidReachTop(_ scrollView: ImageScrollView)
    func scrollViewMagnificationDidChange(_ scrollView: ImageScrollView, magnification: CGFloat)
}

class ImageScrollView: NSScrollView {
    weak var scrollDelegate: ImageScrollViewDelegate?

    private var isAtBottom = false
    private var isAtTop = false
    private let edgeThreshold: CGFloat = 2.0  // px 容差

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        allowsMagnification = true
        minMagnification = 0.1
        maxMagnification = 10.0
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        backgroundColor = .black

        // 監聽捲動位置變化
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(boundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: contentView
        )
    }

    @objc private func boundsDidChange(_ notification: Notification) {
        guard let docView = documentView else { return }
        let clipBounds = contentView.bounds
        let docFrame = docView.frame

        // macOS 座標系：原點左下
        let currentAtBottom = clipBounds.maxY >= docFrame.height - edgeThreshold
        let currentAtTop = clipBounds.minY <= edgeThreshold

        isAtBottom = currentAtBottom
        isAtTop = currentAtTop
    }

    override func scrollWheel(with event: NSEvent) {
        // Pinch zoom（ctrlKey + scroll = magnify on trackpad）
        // NSScrollView 已自動處理 allowsMagnification，這裡不需額外處理

        let wasAtBottom = isAtBottom
        let wasAtTop = isAtTop

        super.scrollWheel(with: event)

        // Natural Scrolling 修正：
        // isDirectionInvertedFromDevice == true 時，deltaY 已被系統反轉
        // 使用者「向下滑」的意圖 = deltaY < 0（自然捲動）或 deltaY > 0（傳統捲動）
        // 統一以「已到邊界 + 仍有相同方向的 delta」判斷
        let userScrollsDown = event.scrollingDeltaY < 0
        let userScrollsUp = event.scrollingDeltaY > 0

        // Natural scrolling 下 deltaY 已反轉，方向與視覺一致
        // 傳統捲動下需反轉判斷
        let isNatural = event.isDirectionInvertedFromDevice
        let intentDown = isNatural ? userScrollsDown : userScrollsUp
        let intentUp = isNatural ? userScrollsUp : userScrollsDown

        if wasAtBottom && intentDown {
            scrollDelegate?.scrollViewDidReachBottom(self)
        }
        if wasAtTop && intentUp {
            scrollDelegate?.scrollViewDidReachTop(self)
        }
    }

    /// 以游標位置為中心的 Pinch Zoom（覆寫取得更精確的控制）
    override func magnify(with event: NSEvent) {
        let point = contentView.convert(event.locationInWindow, from: nil)
        let newMag = magnification + event.magnification
        setMagnification(
            max(minMagnification, min(maxMagnification, newMag)),
            centeredAtPoint: point
        )
        scrollDelegate?.scrollViewMagnificationDidChange(self, magnification: magnification)
    }

    /// 切換圖片後回到頂部
    func scrollToTop() {
        guard let docView = documentView else { return }
        // macOS 座標系：maxY = 頂部
        let topPoint = NSPoint(x: 0, y: docView.frame.height)
        contentView.scroll(to: topPoint)
        reflectScrolledClipView(contentView)
    }

    /// 切換圖片後跳到底部
    func scrollToBottom() {
        contentView.scroll(to: .zero)
        reflectScrolledClipView(contentView)
    }
}
```

### 4.5 ImageContentView — 圖片繪製與插值控制

```swift
// ImageContentView.swift
import AppKit

class ImageContentView: NSView {
    var image: NSImage? { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }
    var interpolation: NSImageInterpolation = .default { didSet { needsDisplay = true } }
    var showPixels: Bool = false { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize {
        image?.size ?? .zero
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let ctx = NSGraphicsContext.current else { return }

        // 縮放品質控制
        // 注意：NSGraphicsContext.imageInterpolation 在 macOS Big Sur+ Retina 已失效
        // 必須使用 CGContext 層級的 interpolationQuality
        let cgCtx = ctx.cgContext
        if showPixels {
            cgCtx.interpolationQuality = .none
        } else {
            switch interpolation {
            case .none: cgCtx.interpolationQuality = .none
            case .low:  cgCtx.interpolationQuality = .low
            case .high: cgCtx.interpolationQuality = .high
            default:    cgCtx.interpolationQuality = .medium
            }
        }

        image.draw(in: bounds)
    }
}
```

### 4.6 FittingCalculator — 圖片適配計算

```swift
// FittingCalculator.swift
import Foundation

struct FittingOptions: Codable {
    var shrinkHorizontally: Bool = true
    var shrinkVertically: Bool = true
    var stretchHorizontally: Bool = false
    var stretchVertically: Bool = false
}

struct FittingCalculator {
    /// 根據 FittingOptions 計算圖片應顯示的大小
    static func calculate(
        imageSize: NSSize,
        viewportSize: NSSize,
        options: FittingOptions
    ) -> NSSize {
        var width = imageSize.width
        var height = imageSize.height

        let needsShrinkH = width > viewportSize.width && options.shrinkHorizontally
        let needsShrinkV = height > viewportSize.height && options.shrinkVertically
        let needsStretchH = width < viewportSize.width && options.stretchHorizontally
        let needsStretchV = height < viewportSize.height && options.stretchVertically

        if needsShrinkH || needsStretchH {
            let scaleX = viewportSize.width / imageSize.width
            width = viewportSize.width
            if !needsShrinkV && !needsStretchV {
                height = imageSize.height * scaleX  // 等比例
            }
        }

        if needsShrinkV || needsStretchV {
            let scaleY = viewportSize.height / imageSize.height
            height = viewportSize.height
            if !needsShrinkH && !needsStretchH {
                width = imageSize.width * scaleY  // 等比例
            }
        }

        // 兩個方向都要適配時，取最小縮放比（Fit on Screen 邏輯）
        if (needsShrinkH && needsShrinkV) || (needsStretchH && needsStretchV) {
            let scaleX = viewportSize.width / imageSize.width
            let scaleY = viewportSize.height / imageSize.height
            let scale = (needsShrinkH && needsShrinkV)
                ? min(scaleX, scaleY)  // 縮小：取較小比例，確保完全可見
                : min(scaleX, scaleY)  // 放大：也取較小比例，避免超出
            width = imageSize.width * scale
            height = imageSize.height * scale
        }

        return NSSize(width: width, height: height)
    }
}
```

### 4.7 ViewerSettings — 使用者設定持久化

```swift
// ViewerSettings.swift
import Foundation

class ViewerSettings: Codable {
    // 縮放
    var magnification: CGFloat = 1.0
    var isManualZoom: Bool = false  // true = 固定縮放, false = Fit on Screen

    // 適配
    var alwaysFitOnOpen: Bool = true
    var fittingOptions = FittingOptions()

    // 縮放品質
    enum ScalingQuality: String, Codable { case low, medium, high }
    var scalingQuality: ScalingQuality = .medium
    var showPixelsWhenZoomingIn: Bool = true

    // 視窗
    var resizeWindowAutomatically: Bool = false
    var floatOnTop: Bool = false
    var lastWindowWidth: CGFloat = Constants.defaultWindowWidth
    var lastWindowHeight: CGFloat = Constants.defaultWindowHeight

    // UserDefaults 儲存
    private static let key = "CeeViewerSettings"

    static func load() -> ViewerSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(ViewerSettings.self, from: data)
        else { return ViewerSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
```

### 4.10 ImageViewController — 主檢視控制器

```swift
// ImageViewController.swift
import AppKit

class ImageViewController: NSViewController {
    private var folder: ImageFolder
    private let loader = ImageLoader()
    private let settings = ViewerSettings.load()
    private var scrollView: ImageScrollView!
    private var contentView: ImageContentView!
    private var currentLoadRequestID: UUID?  // 防止舊圖覆蓋新圖

    init(folder: ImageFolder) {
        self.folder = folder
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

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
    }

    /// 載入新資料夾（視窗重用時呼叫）
    func loadFolder(_ newFolder: ImageFolder) {
        self.folder = newFolder
        if settings.alwaysFitOnOpen {
            settings.isManualZoom = false
        }
        loadCurrentImage()
    }

    // MARK: - Settings 接線

    private func applySettings() {
        // Scaling Quality → ImageContentView
        updateScalingQuality()

        // Float on Top
        if settings.floatOnTop {
            view.window?.level = .floating
        }

        // Resize Window Automatically
        // （在 loadCurrentImage 完成後根據此 flag 決定是否 resize）
    }

    private func updateScalingQuality() {
        switch settings.scalingQuality {
        case .low:    contentView.interpolation = .low
        case .medium: contentView.interpolation = .default
        case .high:   contentView.interpolation = .high
        }
        // Show Pixels：超過 100% 時自動啟用
        contentView.showPixels = settings.showPixelsWhenZoomingIn
            && scrollView.magnification > 1.0
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

            // Resize Window Automatically
            if settings.resizeWindowAutomatically {
                (view.window?.windowController as? ImageWindowController)?
                    .resizeToFitImage(image.size)
            }

            await loader.updateCache(for: folder)
        }
    }

    private func applyFitting(for imageSize: NSSize) {
        if settings.isManualZoom {
            scrollView.magnification = settings.magnification
        } else if settings.alwaysFitOnOpen {
            let fitted = FittingCalculator.calculate(
                imageSize: imageSize,
                viewportSize: scrollView.bounds.size,
                options: settings.fittingOptions
            )
            let scale = fitted.width / imageSize.width
            scrollView.magnification = scale
        }
        updateScalingQuality()  // 縮放後重新判斷 showPixels 門檻
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
        folder.currentIndex = 0
        loadCurrentImage()
        scrollView.scrollToTop()
        updateWindowTitle()
    }

    func goToLastImage() {
        folder.currentIndex = folder.images.count - 1
        loadCurrentImage()
        scrollView.scrollToTop()
        updateWindowTitle()
    }

    private func updateWindowTitle() {
        (view.window?.windowController as? ImageWindowController)?
            .updateTitle(folder: folder)
    }

    // MARK: - Keyboard Shortcuts

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Cmd 組合鍵
        if flags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "=", "+": zoomIn();  return
            case "-":      zoomOut(); return
            case "0":      fitOnScreen(); return
            case "1":      actualSize();  return
            case "*":      toggleAlwaysFit(); return
            case "f":      toggleFullScreen(); return
            default: break
            }
            // Shift+Cmd+P
            if flags.contains(.shift) && event.charactersIgnoringModifiers == "p" {
                toggleShowPixels(); return
            }
        }

        // 無修飾鍵
        switch event.keyCode {
        case 124: goToNextImage()         // → (kVK_RightArrow)
        case 123: goToPreviousImage()     // ← (kVK_LeftArrow)
        case 49:  scrollPageDownOrNext()  // Space
        case 115: goToFirstImage()        // Home (kVK_Home = 0x73)
        case 119: goToLastImage()         // End  (kVK_End  = 0x77)
        case 121: goToNextImage()         // PageDown (kVK_PageDown = 0x79)
        case 116: goToPreviousImage()     // PageUp  (kVK_PageUp  = 0x74)
        case 53:  escapeFullScreen()      // Esc
        default:  super.keyDown(with: event)
        }
    }

    // MARK: - Zoom Actions（由 Menu 和鍵盤共用）

    func zoomIn() {
        settings.isManualZoom = true
        let newMag = scrollView.magnification + Constants.zoomStep
        scrollView.magnification = min(newMag, Constants.maxMagnification)
        settings.magnification = scrollView.magnification
        settings.save()
        updateScalingQuality()
    }

    func zoomOut() {
        settings.isManualZoom = true
        let newMag = scrollView.magnification - Constants.zoomStep
        scrollView.magnification = max(newMag, Constants.minMagnification)
        settings.magnification = scrollView.magnification
        settings.save()
        updateScalingQuality()
    }

    func fitOnScreen() {
        settings.isManualZoom = false
        if let imageSize = contentView.image?.size {
            applyFitting(for: imageSize)
        }
        settings.save()
    }

    func actualSize() {
        settings.isManualZoom = true
        scrollView.magnification = 1.0
        settings.magnification = 1.0
        settings.save()
        updateScalingQuality()
    }

    func toggleAlwaysFit() {
        settings.alwaysFitOnOpen.toggle()
        settings.save()
    }

    func toggleShowPixels() {
        settings.showPixelsWhenZoomingIn.toggle()
        updateScalingQuality()
        settings.save()
    }

    func toggleFullScreen() {
        view.window?.toggleFullScreen(nil)
    }

    func escapeFullScreen() {
        if let window = view.window, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    // MARK: - Float on Top / Resize（Menu action targets）

    func toggleFloatOnTop() {
        settings.floatOnTop.toggle()
        view.window?.level = settings.floatOnTop ? .floating : .normal
        settings.save()
    }

    func toggleResizeAutomatically() {
        settings.resizeWindowAutomatically.toggle()
        settings.save()
    }

    private func scrollPageDownOrNext() {
        let visibleHeight = scrollView.contentView.bounds.height
        let currentY = scrollView.contentView.bounds.minY
        let docHeight = scrollView.documentView?.frame.height ?? 0

        if currentY + visibleHeight >= docHeight - Constants.scrollEdgeThreshold {
            goToNextImage()
        } else {
            let newY = min(currentY + visibleHeight, docHeight - visibleHeight)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: newY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
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
        settings.isManualZoom = true
        settings.magnification = magnification
        settings.save()
        updateScalingQuality()  // 縮放變化後重新判斷 showPixels 門檻
    }
}
```

### 4.11 ImageWindowController — 視窗管理

```swift
// ImageWindowController.swift
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

        // 首次建立視窗，使用儲存的大小（FR-025）
        let settings = ViewerSettings.load()
        let viewController = ImageViewController(folder: folder)
        let window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0,
                width: settings.lastWindowWidth,
                height: settings.lastWindowHeight
            ),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = viewController
        window.center()

        let controller = ImageWindowController(window: window)
        shared = controller  // 靜態持有
        controller.showWindow(nil)
        controller.updateTitle(folder: folder)

        // 監聽視窗大小變化，自動儲存
        NotificationCenter.default.addObserver(
            controller,
            selector: #selector(controller.windowDidResize),
            name: NSWindow.didResizeNotification,
            object: window
        )
    }

    @objc private func windowDidResize(_ notification: Notification) {
        guard let window else { return }
        let settings = ViewerSettings.load()
        settings.lastWindowWidth = window.contentView?.bounds.width ?? Constants.defaultWindowWidth
        settings.lastWindowHeight = window.contentView?.bounds.height ?? Constants.defaultWindowHeight
        settings.save()
    }

    func updateTitle(folder: ImageFolder) {
        guard let item = folder.currentImage else { return }
        let name = item.url.lastPathComponent
        let position = "\(folder.currentIndex + 1)/\(folder.images.count)"
        window?.title = "\(name) (\(position))"
    }

    func toggleFloatOnTop(_ enabled: Bool) {
        window?.level = enabled ? .floating : .normal
    }

    func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }

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
}
```

## 5. Menu Structure

```
Cee
├── File
│   ├── Open...                    (Cmd+O)  → showOpenPanel, 選擇圖片/資料夾
│   └── Close Window               (Cmd+W)
├── View
│   ├── Fit on Screen              (Cmd+0)  → FR-015
│   ├── Actual Size                (Cmd+1)  → 100%
│   ├── ─────────────
│   ├── Always Fit Opened Images   (Cmd+*)  → FR-016 toggle
│   ├── Fitting Options            ►        → FR-017 submenu
│   │   ├── ✓ Shrink to Fit Horizontally
│   │   ├── ✓ Shrink to Fit Vertically
│   │   ├── Stretch to Fit Horizontally
│   │   └── Stretch to Fit Vertically
│   ├── Scaling Quality            ►        → FR-018 submenu
│   │   ├── Low
│   │   ├── ✓ Medium
│   │   ├── High
│   │   └── ─────────────
│   │   └── ✓ Show Pixels When Zooming In  (Shift+Cmd+P)
│   ├── ─────────────
│   ├── Resize Window Automatically         → FR-023 toggle
│   ├── Enter Full Screen          (Cmd+F)  → FR-019
│   └── Float on Top                        → FR-024 toggle
├── Go
│   ├── Next Image                 (→)      → FR-012
│   ├── Previous Image             (←)      → FR-012
│   ├── First Image                (Home)
│   └── Last Image                 (End)
└── Window
    ├── Minimize                   (Cmd+M)
    └── Zoom                       (Cmd+Shift+M)  ← macOS 標準
```

## 6. Keyboard Shortcuts

### 全部快捷鍵（含 Menu 項目與隱含操作）

| 快捷鍵 | 動作 | Menu 位置 |
|--------|------|----------|
| `Cmd + O` | 開啟檔案 | File → Open |
| `Cmd + W` | 關閉視窗 | File → Close Window |
| `→` / `PageDown` | 下一張 | Go → Next Image |
| `←` / `PageUp` | 上一張 | Go → Previous Image |
| `Home` | 第一張 | Go → First Image |
| `End` | 最後一張 | Go → Last Image |
| `Space` | 向下捲動一頁，到底翻頁 | （隱含操作） |
| `Cmd + =` | 放大（固定倍率模式） | （隱含操作） |
| `Cmd + -` | 縮小（固定倍率模式） | （隱含操作） |
| `Cmd + 0` | Fit on Screen | View → Fit on Screen |
| `Cmd + 1` | 100% 原始大小 | View → Actual Size |
| `Cmd + *` | Always Fit on Open toggle | View → Always Fit... |
| `Shift + Cmd + P` | Show Pixels toggle | View → Scaling Quality → Show Pixels... |
| `Cmd + F` | 全螢幕切換 | View → Enter Full Screen |
| `Esc` | 退出全螢幕 | （隱含操作） |
| `Cmd + M` | 最小化 | Window → Minimize |

## 7. Key Technical Decisions

### 7.1 為何用 AppKit 而非 SwiftUI
- NSScrollView 的 `magnification` 和 `magnify(with:)` 直接支援 Pinch Zoom
- `scrollWheel(with:)` 可精確偵測捲動到邊界
- 座標系統統一（避免 SwiftUI/AppKit 混合的座標衝突）
- 圖片繪製用 `draw(_ dirtyRect:)` 可精確控制插值品質

### 7.2 縮放品質控制
- **統一使用 CGContext 層**：`cgContext.interpolationQuality` 控制所有縮放品質
- **不使用 NSGraphicsContext.imageInterpolation**：macOS Big Sur+ 已靜默失效（setter 被忽略）
- 對應關係：`.none` = Nearest Neighbor、`.low` = 快速、`.medium` = 雙線性、`.high` = Lanczos

### 7.3 座標系統
- macOS AppKit 座標原點在**左下角**（與 iOS/SwiftUI 不同）
- 捲動到底 = `clipView.bounds.maxY >= docView.frame.height`
- 捲動到頂 = `clipView.bounds.minY <= 0`

### 7.4 捲動翻頁的防抖
- 使用 `wasAtBottom` flag：只在「之前已到底 + 仍在向下捲」時觸發
- 翻頁後 scrollToTop() 重置狀態，避免連續觸發

### 7.5 Natural Scrolling 處理
- `event.isDirectionInvertedFromDevice`：macOS 的「自然捲動」會反轉 deltaY
- 需根據此 flag 判斷使用者的實際捲動意圖方向
- 已在 ImageScrollView.scrollWheel 中實作完整的方向判斷邏輯

### 7.6 多視窗策略
- **單視窗重用**：從 Finder 右鍵開啟第二個圖片時，重用現有視窗載入新資料夾
- 實作：`ImageWindowController.shared` 靜態持有 + `loadFolder()` 方法

### 7.7 Show Pixels 觸發門檻
- 當 `showPixelsWhenZoomingIn` 啟用且 `magnification > 1.0`（超過 100%）時自動切換為 Nearest Neighbor
- 縮小時（≤100%）依照 Scaling Quality 設定的插值品質

### 7.8 視窗大小記憶
- 全域記住最後一次視窗大小（存入 UserDefaults）
- 所有資料夾共用同一視窗大小設定

### 7.9 並發安全
- `ImageLoader` 使用 `actor` 確保快取讀寫的執行緒安全
- `currentLoadRequestID` (UUID) 防止快速翻頁時舊圖覆蓋新圖

## 8. Data Flow

### 開啟圖片流程
```
Finder 右鍵 Open With → macOS 啟動 Cee.app
  → AppDelegate.application(_:open:) 收到 [URL]
    → ImageFolder(containing: url) 掃描資料夾
    → ImageWindowController.open(with:) 建立視窗
      → ImageViewController 載入首張圖片
        → ImageLoader.loadImage(at:) 非同步解碼
        → FittingCalculator.calculate() 計算顯示大小
        → ImageContentView.image = decodedImage
        → ImageScrollView.magnification = calculated
        → ImageLoader.updateCache() 預載 ±2 張
```

### 翻頁流程
```
使用者捲動到底繼續捲動
  → ImageScrollView.scrollWheel(with:) 偵測
    → scrollDelegate?.scrollViewDidReachBottom()
      → ImageViewController.goToNextImage()
        → folder.goNext()
        → ImageLoader.loadImage(at: newURL)
        → 更新 ImageContentView
        → scrollView.scrollToTop()
        → ImageLoader.updateCache() 更新預載範圍
        → windowController.updateTitle()
```

### 縮放模式切換
```
使用者 Pinch Zoom
  → ImageScrollView.magnify(with:) 觸發
    → settings.isManualZoom = true
    → settings.magnification = newValue
    → 後續圖片切換保持 magnification

使用者按 Cmd+0
  → settings.isManualZoom = false
  → FittingCalculator 重新計算 Fit on Screen
  → 後續圖片切換自動 Fit
```

## 9. Performance Strategy

| 策略 | 實作 | 目標 |
|------|------|------|
| Lazy Loading | 僅載入當前 ±2 張，其餘釋放 | 記憶體 < 500MB |
| ImageIO 解碼 | `CGImageSourceCreateImageAtIndex` | 比 NSImage(contentsOf:) 更高效 |
| 非同步載入 | `actor` + `Task.detached(priority: .userInitiated)` | UI 不卡頓、執行緒安全 |
| 快取淘汰 | 切換圖片時清理超出範圍的快取 | 控制記憶體成長 |
| 排序用 `localizedStandardCompare` | Finder 風格的自然排序 | 數字排序正確（1, 2, 10 而非 1, 10, 2）|

## 10. Security Considerations

- **唯讀存取**：App 只讀取圖片，永不寫入或修改檔案
- **無網路**：不做任何網路請求
- **沙盒外執行**：自用工具，不上 App Store，無需 App Sandbox
- **路徑驗證**：接收 Open With URL 時驗證檔案存在且為支援格式

## 11. Open Source Reference

| 專案 | 用途 |
|------|------|
| [FlowVision](https://github.com/netdcy/FlowVision) | SwiftUI 架構參考、大型目錄最佳化策略 |
| [ryohey/Zoomable](https://github.com/ryohey/Zoomable) | SwiftUI pinch zoom 中心點修正（備用參考） |
