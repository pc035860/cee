# Phase 1: Project Setup + Image Display Pipeline

## Goal

從零建立 Xcode 專案，實現「Finder 右鍵 Open With → Cee 顯示圖片 + Pinch Zoom」的完整流程。

## Prerequisites

- [x] Xcode 26 installed
- [x] XcodeGen installed (`/opt/homebrew/bin/xcodegen`)
- [x] PRD.md and SPEC.md completed

## Tasks

### 1.1 XcodeGen Project Setup

- [ ] Create `project.yml` at project root
  - Target: `Cee` (macOS Application)
  - Deployment target: macOS 14.0
  - Swift language version: 6
  - Architecture: arm64
  - Sources: `Cee/`
  - Info.plist: `Cee/App/Info.plist`

```yaml
# project.yml
name: Cee
options:
  bundleIdPrefix: com.local
  deploymentTarget:
    macOS: "14.0"
settings:
  base:
    SWIFT_VERSION: "6"
    ARCHS: arm64
    MACOSX_DEPLOYMENT_TARGET: "14.0"
targets:
  Cee:
    type: application
    platform: macOS
    sources:
      - Cee
    settings:
      base:
        INFOPLIST_FILE: Cee/App/Info.plist
        PRODUCT_BUNDLE_IDENTIFIER: com.local.cee
        PRODUCT_NAME: Cee
        CODE_SIGN_IDENTITY: "-"
        CODE_SIGNING_ALLOWED: false
```

- [ ] Run `xcodegen generate` to create `.xcodeproj`
- [ ] Verify project opens in Xcode and builds

### 1.2 Info.plist — Open With Registration

- [ ] Create `Cee/App/Info.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Cee</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.cee</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>LSMinimumSystemVersion</key>
    <string>$(MACOSX_DEPLOYMENT_TARGET)</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
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
</dict>
</plist>
```

### 1.3 Programmatic Menu Setup (Minimal)

- [ ] Build minimal NSMenu programmatically in `AppDelegate.applicationDidFinishLaunching(_:)`
  - Application menu (Cee → Quit Cmd+Q)
  - File menu (Close Window Cmd+W)
  - Window menu (Minimize Cmd+M)
  - **Note**: Full View/Go menus added in Phase 3
  - **No XIB**: Remove `NSMainNibFile` from Info.plist, use `NSApplication.shared.mainMenu = menu` instead

### 1.4 AppDelegate — Entry Point

- [ ] Create `Cee/App/AppDelegate.swift`
  - Implement `NSApplicationDelegate`
  - Handle `application(_:open:)` for Open With
  - Call `ImageWindowController.open(with: url)`

### 1.5 Models

- [ ] Create `Cee/Utilities/Constants.swift`
  - Window defaults, cache radius, zoom limits, edge threshold

- [ ] Create `Cee/Models/ImageItem.swift`
  - Struct with `url: URL` and computed `fileName`
  - `Collection` safe subscript extension

- [ ] Create `Cee/Models/ImageFolder.swift`
  - Init with file URL → scan parent folder
  - Filter by UTType (JPEG, PNG, TIFF, HEIC, HEIF, GIF, WebP, BMP)
  - Sort with `localizedStandardCompare` (Finder-style natural sort)
  - Navigation: `currentIndex`, `hasNext`, `hasPrevious`, `goNext()`, `goPrevious()`

### 1.6 Services

- [ ] Create `Cee/Services/ImageLoader.swift`
  - `actor ImageLoader` for thread-safe cache
  - `loadImage(at:)` → async decode with `CGImageSourceCreateImageAtIndex`
  - `Task.detached(priority: .userInitiated)` for background decoding
  - `updateCache(for:)` → preload ±2, evict out-of-range

- [ ] Create `Cee/Services/FittingCalculator.swift`
  - `FittingOptions` struct (shrink/stretch H/V toggles)
  - `FittingCalculator.calculate()` → compute display size
  - Default: shrink both enabled, stretch both disabled

### 1.7 Views

- [ ] Create `Cee/Views/ImageContentView.swift`
  - `NSView` subclass with `image`, `interpolation`, `showPixels` properties
  - `draw(_ dirtyRect:)` using `cgContext.interpolationQuality`
  - `intrinsicContentSize` returns image size

- [ ] Create `Cee/Views/ImageScrollView.swift` (Basic version)
  - `NSScrollView` subclass
  - `allowsMagnification = true`, range 0.1~10.0
  - Vertical + horizontal scrollers (autohide)
  - Black background
  - `magnify(with:)` override for cursor-centered zoom
  - `scrollToTop()` / `scrollToBottom()` helpers
  - **Note**: Scroll edge detection + delegate deferred to Phase 2

### 1.8 Controllers

- [ ] Create `Cee/Controllers/ImageViewController.swift` (Basic version)
  - Init with `ImageFolder`
  - `loadView()`: create ImageScrollView + ImageContentView
  - `loadCurrentImage()`: async load + display + fit on screen
  - `currentLoadRequestID` (UUID) to prevent stale image display
  - Basic `applyFitting()` for Fit on Screen mode
  - **Note**: Navigation, keyboard, zoom actions deferred to Phase 2/3

- [ ] Create `Cee/Controllers/ImageWindowController.swift` (Basic version)
  - `static var shared` for single-window reuse
  - `open(with:)`: create/reuse window + load folder
  - `updateTitle()`: "filename.jpg (3/42)" format
  - Window size: 首次使用螢幕可見區域 80%（`screen.visibleFrame * 0.8`），之後記憶上次大小
  - **Note**: Resize observer, Float on Top deferred to Phase 4

## Verification

### Build & Run
```bash
cd /Users/pc035860/code/cee
xcodegen generate
xcodebuild -project Cee.xcodeproj -scheme Cee -configuration Debug build
```

### Manual Tests
- [ ] App builds without errors
- [ ] App launches (even if no image opened yet)
- [ ] Finder → right-click image → Open With → Cee → image displays
- [ ] Pinch zoom works (trackpad)
- [ ] Image fits to window on open
- [ ] Black background behind image
- [ ] Window title shows filename

## Files Created

| File | Status |
|------|--------|
| `project.yml` | new |
| `Cee/App/Info.plist` | new |
| `Cee/App/AppDelegate.swift` | new (含 minimal programmatic menu) |
| `Cee/Utilities/Constants.swift` | new |
| `Cee/Models/ImageItem.swift` | new |
| `Cee/Models/ImageFolder.swift` | new |
| `Cee/Services/ImageLoader.swift` | new |
| `Cee/Services/FittingCalculator.swift` | new |
| `Cee/Views/ImageContentView.swift` | new |
| `Cee/Views/ImageScrollView.swift` | new |
| `Cee/Controllers/ImageViewController.swift` | new |
| `Cee/Controllers/ImageWindowController.swift` | new |

## Notes

- **純程式碼菜單**: 全程不使用 XIB，在 AppDelegate 中以 `NSMenu()` 程式碼建立菜單。Info.plist 不含 `NSMainNibFile`，改用 `NSApplication.shared.mainMenu = menu`。這樣更容易維護和 code review。
- **Swift 6 Concurrency**: `actor ImageLoader` 天然滿足 Swift 6 的 strict concurrency。`ImageViewController` 的 `Task {}` 預設在 `@MainActor` 上執行（因為 NSViewController 是 @MainActor），UI 更新安全。
- **XcodeGen**: 每次修改 `project.yml` 後需重新 `xcodegen generate`。`.xcodeproj` 應加入 `.gitignore`。
