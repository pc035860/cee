# Phase 6: E2E UI Testing (Smoke Test)

## Goal

用 Xcode 內建 UI Tests（XCTest/XCUIAutomation）建立 smoke E2E 測試：啟動 app → 載入固定測試圖片 → 驗證預覽/切換/捲動 → 結束。用 `xcodebuild test` 從 command line 全自動執行並產出 `.xcresult`。

## Prerequisites

- [ ] Phase 5 completed — All features implemented and polished
- [ ] Xcode 26 with XCUIAutomation framework

## Architecture Overview

```
Test Process (CeeUITests)              App Process (Cee.app)
┌────────────────────────────┐         ┌──────────────────────────────┐
│ XCTestCase                 │         │ AppDelegate                   │
│                            │         │                                │
│ 1. Bundle(for: self)       │ launch  │ 2. ProcessInfo                 │
│    取得 fixture 路徑        │ ──────→ │    .isUITesting?               │
│                            │ args +  │    .testFixturePath?           │
│ 3. launchArguments +       │ env     │                                │
│    launchEnvironment       │         │ 4. 直接呼叫                     │
│    傳給 app                │         │    ImageWindowController       │
│                            │         │    .open(with: fixtureURL)     │
└────────────────────────────┘         └──────────────────────────────┘
```

### Design Decisions

| 決策 | 選擇 | 原因 |
|------|------|------|
| 測試碼保護 | `#if DEBUG` + Runtime Flag 混合 | Release 不含測試碼，且每個 test case 可注入不同 fixture |
| 繞過 NSOpenPanel | `launchEnvironment` 傳路徑 | NSOpenPanel 在 UI test 中無法可靠操作 |
| Fixture 存放 | UI test target 目錄內 | 自動包入 test bundle，test code 可用 `Bundle(for:)` 存取 |
| 捲動方式 | `scroll(byDeltaX:deltaY:)` | macOS 專用 API，比 swipe 更精確 |
| 等待策略 | Cookpad-style `wait(until:)` extension | KeyPath-based chainable wait，比 sleep 穩定 |
| 動畫處理 | `NSAnimationContext.current.duration = 0` | AppKit 無 `UIView.setAnimationsEnabled(false)` |

---

## Tasks

### 6.1 App 端：測試模式支援

- [ ] 新增 `Cee/Utilities/TestMode.swift`

```swift
// TestMode.swift
import Foundation

#if DEBUG
enum TestMode {
    static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
    }

    static var testFixturePath: URL? {
        guard let path = ProcessInfo.processInfo.environment["UITEST_FIXTURE_PATH"] else {
            return nil
        }
        let url = URL(fileURLWithPath: path)
        // 驗證檔案存在且為支援的圖片格式
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static var shouldResetState: Bool {
        ProcessInfo.processInfo.arguments.contains("--reset-state")
    }

    static var shouldDisableAnimations: Bool {
        ProcessInfo.processInfo.arguments.contains("--disable-animations")
    }
}
#endif
```

- [ ] 修改 `AppDelegate.swift`：在 `applicationDidFinishLaunching` 中加入測試模式入口

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    #if DEBUG
    if TestMode.isUITesting {
        // 禁用動畫
        if TestMode.shouldDisableAnimations {
            NSAnimationContext.current.duration = 0
        }

        // 重置測試相關狀態（只清除 ViewerSettings，不清除所有 UserDefaults）
        if TestMode.shouldResetState {
            UserDefaults.standard.removeObject(forKey: "CeeViewerSettings")
        }

        // 直接載入 fixture（繞過 NSOpenPanel）
        if let fixtureURL = TestMode.testFixturePath {
            ImageWindowController.open(with: fixtureURL)
            return
        }
    }
    #endif

    // 正常啟動邏輯...
}
```

### 6.2 App 端：Accessibility Identifier 設定

為關鍵 UI 元件加穩定定位點。AppKit 使用 `setAccessibilityIdentifier()` / `setAccessibilityRole()`。

- [ ] `ImageScrollView.swift`

```swift
private func setup() {
    // ... existing setup code ...

    // Accessibility
    setAccessibilityIdentifier("imageScrollView")
    setAccessibilityRole(.scrollArea)
}
```

- [ ] `ImageContentView.swift`

```swift
// 載入狀態追蹤
enum LoadingState { case idle, loading, loaded, error }

var loadingState: LoadingState = .idle {
    didSet { updateAccessibilityState() }
}

private func updateAccessibilityState() {
    switch loadingState {
    case .idle:    setAccessibilityIdentifier("imageContent-idle")
    case .loading: setAccessibilityIdentifier("imageContent-loading")
    case .loaded:  setAccessibilityIdentifier("imageContent-loaded")
    case .error:   setAccessibilityIdentifier("imageContent-error")
    }
    setAccessibilityElement(true)
    setAccessibilityRole(.image)
}
```

- [ ] `ImageViewController.swift`：載入完成後更新狀態

```swift
private func loadCurrentImage() {
    guard let item = folder.currentImage else { return }
    let requestID = UUID()
    currentLoadRequestID = requestID

    contentView.loadingState = .loading  // ← 新增

    Task {
        guard let image = await loader.loadImage(at: item.url) else {
            guard currentLoadRequestID == requestID else { return }
            contentView.loadingState = .error  // ← 新增
            return
        }

        guard currentLoadRequestID == requestID else { return }

        contentView.image = image
        contentView.loadingState = .loaded  // ← 新增
        contentView.setAccessibilityLabel(item.fileName)  // ← 新增

        applyFitting(for: image.size)
        // ... rest of existing code ...
    }
}
```

- [ ] `ImageWindowController.swift`：視窗 identifier

```swift
// 在 open(with:) 中建立視窗後加入
window.setAccessibilityIdentifier("imageWindow")
```

- [ ] 完整 Accessibility Identifier 清單

| 元件 | Identifier | Role | 用途 |
|------|-----------|------|------|
| 主視窗 | `imageWindow` | `.window` | 視窗存在檢查 |
| 捲動區域 | `imageScrollView` | `.scrollArea` | 捲動操作 |
| 圖片內容 | `imageContent-{state}` | `.image` | 載入狀態判斷（idle/loading/loaded/error） |
| 視窗標題 | — | — | 透過 `window.title` 驗證檔名和索引 |

### 6.3 Test Fixtures 準備

- [ ] 建立 fixtures 目錄結構

```
CeeUITests/
├── CeeUITests.swift              # 主測試檔
├── Helpers/
│   ├── WaitExtensions.swift      # Cookpad-style wait helpers
│   └── ScrollHelpers.swift       # NSScrollView 捲動 helpers
└── Fixtures/
    └── Images/
        ├── 001-landscape.jpg     # 橫向圖片（800x600, ~50KB）
        ├── 002-portrait.png      # 直向圖片（600x800, ~50KB）
        └── 003-square.jpg        # 正方形圖片（500x500, ~30KB）
```

- [ ] Fixture 圖片要求：
  - 3 張不同尺寸/格式的小型圖片（< 100KB each）
  - 至少包含 JPEG 和 PNG
  - 放在 `CeeUITests/Fixtures/Images/` 目錄
  - 會自動包入 test bundle 的 Copy Bundle Resources

### 6.4 XcodeGen 設定更新

- [ ] 在 `project.yml` 中新增 UI test target

```yaml
targets:
  # ... existing Cee target ...

  CeeUITests:
    type: bundle.ui-testing
    platform: macOS
    sources:
      - CeeUITests
    resources:
      - CeeUITests/Fixtures
    dependencies:
      - target: Cee
    settings:
      base:
        INFOPLIST_FILE: CeeUITests/Info.plist
        PRODUCT_BUNDLE_IDENTIFIER: com.local.CeeUITests

schemes:
  Cee:
    build:
      targets:
        Cee: all
        CeeUITests: [test]
    run:
      config: Debug
    test:
      config: Debug
      targets:
        - CeeUITests
```

### 6.5 Test Helper Extensions

- [ ] `CeeUITests/Helpers/WaitExtensions.swift`

```swift
import XCTest

extension XCUIElement {
    static let defaultTimeout: TimeInterval = 15

    /// Cookpad-style chainable wait
    @discardableResult
    func wait(
        until expression: @escaping (XCUIElement) -> Bool,
        timeout: TimeInterval = defaultTimeout,
        message: @autoclosure () -> String = "",
        file: StaticString = #file,
        line: UInt = #line
    ) -> Self {
        if expression(self) { return self }

        let predicate = NSPredicate { _, _ in expression(self) }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)

        if result != .completed {
            let msg = message()
            XCTFail(msg.isEmpty ? "Timed out waiting for condition on \(self)" : msg,
                     file: file, line: line)
        }
        return self
    }

    /// KeyPath-based wait
    @discardableResult
    func wait(
        until keyPath: KeyPath<XCUIElement, Bool>,
        timeout: TimeInterval = defaultTimeout,
        message: @autoclosure () -> String = "",
        file: StaticString = #file,
        line: UInt = #line
    ) -> Self {
        wait(until: { $0[keyPath: keyPath] }, timeout: timeout,
             message: message(), file: file, line: line)
    }

    /// Wait for element to disappear
    func waitForNonExistence(timeout: TimeInterval = defaultTimeout) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        return result == .completed
    }
}
```

- [ ] `CeeUITests/Helpers/ScrollHelpers.swift`

```swift
import XCTest

extension XCUIElement {
    /// macOS: scroll by delta (trackpad/mouse wheel simulation)
    func scrollDown(by delta: CGFloat = 50) {
        scroll(byDeltaX: 0, deltaY: -delta)
    }

    func scrollUp(by delta: CGFloat = 50) {
        scroll(byDeltaX: 0, deltaY: delta)
    }

    /// Scroll until target element becomes hittable
    @discardableResult
    func scrollToReveal(_ element: XCUIElement, maxAttempts: Int = 20) -> Bool {
        guard self.elementType == .scrollView || self.elementType == .scrollArea else {
            return false
        }

        for _ in 0..<maxAttempts {
            if element.isHittable { return true }

            let before = element.frame
            scrollDown(by: 50)

            // 沒有移動 = 到底了
            if element.frame == before { break }
        }
        return element.isHittable
    }
}
```

### 6.6 Smoke E2E Test Case

- [ ] `CeeUITests/CeeUITests.swift`

```swift
import XCTest

final class CeeUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false

        // 取得 fixture 路徑（從 test bundle）
        let testBundle = Bundle(for: type(of: self))
        guard let fixtureFolder = testBundle.url(
            forResource: "Images",
            withExtension: nil,
            subdirectory: "Fixtures"
        ) else {
            XCTFail("Fixtures/Images not found in test bundle")
            return
        }

        // 取得第一張圖片的路徑（app 會自動掃描整個資料夾）
        let firstImage = fixtureFolder.appendingPathComponent("001-landscape.jpg")

        app.launchArguments = [
            "--ui-testing",
            "--reset-state",
            "--disable-animations"
        ]
        app.launchEnvironment = [
            "UITEST_FIXTURE_PATH": firstImage.path
        ]

        app.launch()
    }

    override func tearDownWithError() throws {
        // 失敗時保留截圖
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .deleteOnSuccess
        add(attachment)

        app.terminate()
        try super.tearDownWithError()
    }

    // MARK: - Smoke Test

    func testSmoke_AppLaunchesAndDisplaysImage() throws {
        // 1. 驗證主視窗出現
        let window = app.windows["imageWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 10),
            "Main window should appear after launch")

        // 2. 驗證圖片載入完成
        let loadedImage = app.otherElements["imageContent-loaded"]
        XCTAssertTrue(loadedImage.waitForExistence(timeout: 10),
            "Image should finish loading")

        // 3. 驗證視窗標題包含檔名和位置資訊
        let windowTitle = window.title
        XCTAssertTrue(windowTitle.contains("001-landscape.jpg"),
            "Window title should contain filename, got: \(windowTitle)")
        XCTAssertTrue(windowTitle.contains("/3"),
            "Window title should show total count of 3, got: \(windowTitle)")
    }

    func testSmoke_NavigateToNextImage() throws {
        // 1. 等待首張圖片載入
        let loadedImage = app.otherElements["imageContent-loaded"]
        XCTAssertTrue(loadedImage.waitForExistence(timeout: 10))

        // 2. 按右鍵切換到下一張
        app.typeKey(.rightArrow, modifierFlags: [])

        // 3. 等待新圖片載入（identifier 會先變 loading 再變 loaded）
        // 先等 loaded 消失（變成 loading）
        // 再等 loaded 出現
        let newLoaded = app.otherElements["imageContent-loaded"]
        newLoaded.wait(until: { element in
            element.exists && (element.label.contains("002") == true)
        }, timeout: 10, message: "Second image should load after navigation")

        // 4. 驗證視窗標題更新
        let window = app.windows["imageWindow"]
        let title = window.title
        XCTAssertTrue(title.contains("002-portrait.png"),
            "Title should show second image, got: \(title)")
        XCTAssertTrue(title.contains("2/3"),
            "Title should show position 2/3, got: \(title)")
    }

    func testSmoke_NavigateToPreviousImage() throws {
        // 1. 等待首張圖片載入
        let loadedImage = app.otherElements["imageContent-loaded"]
        XCTAssertTrue(loadedImage.waitForExistence(timeout: 10))

        // 2. 先前進到第二張
        app.typeKey(.rightArrow, modifierFlags: [])
        loadedImage.wait(until: { $0.exists && $0.label.contains("002") }, timeout: 10)

        // 3. 按左鍵回到第一張
        app.typeKey(.leftArrow, modifierFlags: [])
        loadedImage.wait(until: { $0.exists && $0.label.contains("001") }, timeout: 10)

        // 4. 驗證
        let window = app.windows["imageWindow"]
        XCTAssertTrue(window.title.contains("001-landscape.jpg"))
        XCTAssertTrue(window.title.contains("1/3"))
    }

    func testSmoke_KeyboardZoom() throws {
        // 1. 等待圖片載入
        let loadedImage = app.otherElements["imageContent-loaded"]
        XCTAssertTrue(loadedImage.waitForExistence(timeout: 10))

        // 2. Cmd+1 = Actual Size (100%)
        app.typeKey("1", modifierFlags: .command)

        // 3. Cmd+= = Zoom In
        app.typeKey("=", modifierFlags: .command)

        // 4. Cmd+0 = Fit on Screen
        app.typeKey("0", modifierFlags: .command)

        // 5. 驗證圖片仍然正常顯示（未 crash）
        XCTAssertTrue(loadedImage.exists, "Image should still be visible after zoom operations")
    }

    func testSmoke_FullscreenToggle() throws {
        // 1. 等待圖片載入
        let loadedImage = app.otherElements["imageContent-loaded"]
        XCTAssertTrue(loadedImage.waitForExistence(timeout: 10))

        // 2. Cmd+F 進入全螢幕
        app.typeKey("f", modifierFlags: .command)

        // 3. 等待全螢幕轉換完成（macOS 全螢幕有動畫）
        sleep(2)  // 全螢幕轉換即使禁用動畫也需要時間

        // 4. 驗證圖片仍然可見
        XCTAssertTrue(loadedImage.exists, "Image should be visible in fullscreen")

        // 5. Esc 退出全螢幕
        app.typeKey(.escape, modifierFlags: [])
        sleep(2)

        // 6. 驗證回到正常模式
        let window = app.windows["imageWindow"]
        XCTAssertTrue(window.exists, "Window should exist after exiting fullscreen")
    }

    func testSmoke_ScrollToPageTurn() throws {
        // 1. 等待圖片載入
        let loadedImage = app.otherElements["imageContent-loaded"]
        XCTAssertTrue(loadedImage.waitForExistence(timeout: 10))

        // 2. Cmd+1 放大到 Actual Size（需要捲動的大小）
        app.typeKey("1", modifierFlags: .command)

        // 3. 取得 scroll view
        let scrollView = app.scrollViews["imageScrollView"]
        guard scrollView.exists else {
            // 圖片可能不夠大，跳過測試
            return
        }

        // 4. 持續向下捲動直到觸發翻頁
        let window = app.windows["imageWindow"]
        let initialTitle = window.title

        for _ in 0..<50 {
            scrollView.scrollDown(by: 100)
            if window.title != initialTitle {
                break  // 標題變了 = 翻頁成功
            }
        }

        // 5. 驗證已翻到下一張（標題應包含 002）
        let newTitle = window.title
        XCTAssertTrue(newTitle.contains("002"),
            "Should have paged to next image via scroll, got: \(newTitle)")
    }

    func testSmoke_ScrollView() throws {
        // 1. 等待圖片載入
        let loadedImage = app.otherElements["imageContent-loaded"]
        XCTAssertTrue(loadedImage.waitForExistence(timeout: 10))

        // 2. 先放大到需要捲動的大小
        app.typeKey("1", modifierFlags: .command)  // Actual Size

        // 3. 取得 scroll view 並嘗試捲動
        let scrollView = app.scrollViews["imageScrollView"]
        if scrollView.exists {
            scrollView.scrollDown(by: 100)
            scrollView.scrollUp(by: 100)
        }

        // 4. 驗證未 crash
        XCTAssertTrue(loadedImage.exists)
    }
}
```

### 6.7 Test Runner Script

- [ ] 建立 `scripts/test-e2e.sh`

```bash
#!/bin/bash
set -euo pipefail

# =============================================================================
# test-e2e.sh - Cee macOS App E2E Test Runner
# =============================================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_FILE="${PROJECT_DIR}/Cee.xcodeproj"
SCHEME="Cee"
DESTINATION="platform=macOS,arch=arm64"
RESULT_BUNDLE="${PROJECT_DIR}/TestResults.xcresult"
LOG_FILE="${PROJECT_DIR}/xcodebuild.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

cleanup() {
    rm -rf "$RESULT_BUNDLE"
}

check_prerequisites() {
    info "Checking prerequisites..."

    if ! command -v xcodebuild &> /dev/null; then
        error "xcodebuild not found. Please install Xcode."
        exit 1
    fi

    if [ ! -d "$PROJECT_FILE" ]; then
        warn "Xcode project not found. Running xcodegen..."
        if command -v xcodegen &> /dev/null; then
            (cd "$PROJECT_DIR" && xcodegen generate)
        else
            error "Neither .xcodeproj nor xcodegen found."
            exit 1
        fi
    fi

    if ! xcodebuild -project "$PROJECT_FILE" -list 2>/dev/null | grep -q "$SCHEME"; then
        error "Scheme '$SCHEME' not found."
        exit 1
    fi

    info "Prerequisites OK."
}

run_tests() {
    info "Running E2E tests..."
    info "  Scheme:      $SCHEME"
    info "  Destination: $DESTINATION"
    info "  Results:     $RESULT_BUNDLE"

    local exit_code=0

    xcodebuild test \
        -project "$PROJECT_FILE" \
        -scheme "$SCHEME" \
        -destination "$DESTINATION" \
        -resultBundlePath "$RESULT_BUNDLE" \
        -parallel-testing-enabled NO \
        2>&1 | tee "$LOG_FILE" || exit_code=$?

    return $exit_code
}

print_summary() {
    if [ ! -d "$RESULT_BUNDLE" ]; then
        warn "No result bundle found."
        return
    fi

    info "=== Test Summary ==="
    # Xcode 16+ new API, fallback to legacy
    if xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" 2>/dev/null; then
        :
    elif xcrun xcresulttool get object --legacy --format json --path "$RESULT_BUNDLE" 2>/dev/null | head -50; then
        :
    else
        warn "Could not extract summary from xcresult."
    fi
}

main() {
    info "Cee E2E Test Runner"
    info "==================="

    cleanup
    check_prerequisites

    local exit_code=0
    run_tests || exit_code=$?

    echo ""
    print_summary

    echo ""
    if [ $exit_code -eq 0 ]; then
        info "=== ALL TESTS PASSED ==="
    else
        error "=== TESTS FAILED (exit code: $exit_code) ==="
    fi

    info "Result bundle: $RESULT_BUNDLE"
    info "Build log:     $LOG_FILE"

    exit $exit_code
}

main "$@"
```

---

## Key Technical Notes

### macOS vs iOS XCUITest 差異

| 面向 | macOS (AppKit) | iOS (UIKit) |
|------|---------------|-------------|
| 視窗 | 多視窗，用 `app.windows["id"]` 定位 | 通常單視窗 |
| 座標原點 | 左下角 | 左上角 |
| 捲動 | `scroll(byDeltaX:deltaY:)` | `swipeUp()` / `swipeDown()` |
| 動畫禁用 | `NSAnimationContext.current.duration = 0` | `UIView.setAnimationsEnabled(false)` |
| 點擊 | `.click()` | `.tap()` |
| 鍵盤快捷鍵 | `typeKey(_:modifierFlags:)` | 有限支援 |
| Menu bar | `app.menuBars.menuBarItems["File"]` | N/A |
| 裝置模擬 | `XCUIDevice` 不適用 | 支援 |

### AppKit Accessibility Identifier 設定方式

```swift
// AppKit (NSView) — 使用 NSAccessibilityProtocol
view.setAccessibilityIdentifier("myId")     // 或
view.accessibilityIdentifier = "myId"       // Swift property syntax

// 自訂 NSView 額外需要：
view.setAccessibilityElement(true)          // 確保在 accessibility tree 中
view.setAccessibilityRole(.image)           // 設定 role（影響 XCUIElement type）
```

### AppKit 元件 → XCUIElement 對照表

| AppKit | XCUIElement Query | 注意事項 |
|--------|-------------------|---------|
| `NSWindow` | `app.windows["id"]` | — |
| `NSButton` | `app.buttons["id"]` | — |
| `NSTextField` (label) | `app.staticTexts["id"]` | — |
| `NSScrollView` | `app.scrollViews["id"]` | — |
| `NSImageView` | `app.images["id"]` | 需 `setAccessibilityElement(true)` |
| Custom `NSView` | `app.otherElements["id"]` | 需 `setAccessibilityElement(true)` |

### 圖片載入完成判斷

使用動態 `accessibilityIdentifier` 反映載入狀態：
- `imageContent-idle` → 閒置
- `imageContent-loading` → 載入中
- `imageContent-loaded` → 載入完成（測試中 `waitForExistence` 此 ID）
- `imageContent-error` → 載入失敗

### CI 注意事項

| 項目 | 說明 |
|------|------|
| GUI Session | macOS UI test 需要 WindowServer（不能 headless） |
| TCC 權限 | 需要 Accessibility 權限；SIP 啟用時無法修改 TCC.db |
| GitHub Actions | hosted runner SIP 啟用，建議用 self-hosted runner |
| 平行測試 | macOS UI test 建議 `-parallel-testing-enabled NO` |
| XcodeGen | CI 中需先執行 `xcodegen generate` 產生 .xcodeproj |

---

## Files Modified / Created

| File | Change |
|------|--------|
| `Cee/Utilities/TestMode.swift` | **新增** — 測試模式偵測（`#if DEBUG`） |
| `Cee/App/AppDelegate.swift` | **修改** — 加入 `applicationDidFinishLaunching` 測試模式入口 |
| `Cee/Views/ImageScrollView.swift` | **修改** — 加入 `accessibilityIdentifier` |
| `Cee/Views/ImageContentView.swift` | **修改** — 加入 `LoadingState` + 動態 accessibility ID |
| `Cee/Controllers/ImageViewController.swift` | **修改** — 載入時更新 `loadingState` 和 `accessibilityLabel` |
| `Cee/Controllers/ImageWindowController.swift` | **修改** — 視窗加 `accessibilityIdentifier` |
| `CeeUITests/CeeUITests.swift` | **新增** — Smoke E2E test cases |
| `CeeUITests/Helpers/WaitExtensions.swift` | **新增** — Cookpad-style wait helpers |
| `CeeUITests/Helpers/ScrollHelpers.swift` | **新增** — macOS scroll helpers |
| `CeeUITests/Fixtures/Images/` | **新增** — 3 張測試圖片 |
| `CeeUITests/Info.plist` | **新增** — UI Test target 配置檔（可為空 plist） |
| `project.yml` | **修改** — 加入 CeeUITests target（含 resources）+ scheme |
| `scripts/test-e2e.sh` | **新增** — CLI test runner |

## Verification

### 驗收標準
1. `./scripts/test-e2e.sh` 一鍵執行，退出碼 0 = 全過
2. `TestResults.xcresult` 可用 `xcrun xcresulttool` 解析
3. 7 個 smoke test 全部通過：
   - [ ] App 啟動並顯示圖片
   - [ ] 右鍵導航到下一張
   - [ ] 左鍵導航回上一張
   - [ ] 鍵盤縮放操作不 crash
   - [ ] 全螢幕切換（Cmd+F / Esc）
   - [ ] 捲動到底觸發翻頁
   - [ ] ScrollView 捲動正常
4. 測試碼不影響 Release build（`#if DEBUG` 包裝）
5. 測試完全獨立（random order 執行仍通過）

## Research Sources

### Apple 官方
- https://developer.apple.com/documentation/xcuiautomation
- https://developer.apple.com/documentation/AppKit/accessibility-for-appkit
- https://developer.apple.com/forums/thread/759226 — Test Plan args 不自動轉發給 app
- https://developer.apple.com/forums/thread/793342 — UI test bundle 和 app bundle 分離

### 技術文章
- https://sourcediving.com/clean-waiting-in-xcuitest-43bab495230f — Cookpad Clean Wait
- https://pfandrade.me/blog/ui-testing-and-nsscrollview/ — macOS NSScrollView UI testing
- https://www.jessesquires.com/blog/2021/03/17/xcode-ui-testing-reliability-tips/ — 穩定性建議
- https://www.polpiella.dev/configuring-ui-tests-with-launch-arguments/ — Launch arguments 配置
- https://pfandrade.me/blog/managing-ios-ui-testing-fixtures/ — Fixture 管理

### Stack Overflow
- https://stackoverflow.com/questions/55257246/nsopenpanel-breaks-ui-testing-on-macos
- https://stackoverflow.com/questions/77141644 — resultBundlePath 行為

### 工具
- https://qiita.com/irgaly/items/1221133786bbb76d9ba2 — Xcode 16.3+ xcresulttool 新 API
- https://github.com/ChargePoint/xcparse — xcresult 解析工具
