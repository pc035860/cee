# Status Bar（Bottom Bar）設計研究報告

**日期**：2026-02-28
**參與角色**：competitive-analyst、appkit-researcher、ux-researcher、integration-researcher（4 人平行研究）
**實作進度**：Phase 1 完成（2026-03-01，`feat/status-bar` branch）

---

## 需求摘要

設計一個類似 Status Bar 的 UI 元件，顯示在 Viewport 底部，呈現圖片相關資訊。

**設計要求**：
1. 符合 General Image Viewer Design 慣例
2. 顯示資訊足夠詳細但不繁雜
3. Menu Bar 選項可 Toggle 顯示/隱藏

---

## 一、競品分析

### 9 款主流圖片瀏覽器對比

| 瀏覽器 | Status Bar 位置 | 核心欄位 | 自訂程度 | Toggle 快捷鍵 |
|--------|---------------|---------|---------|------------|
| XnView MP | 底部固定 | 尺寸、色彩深度、長寬比、索引、縮放 | 中 | Ctrl+Shift+B |
| IrfanView | 底部固定 | 尺寸、索引、縮放、檔案大小、日期 | 低 | View 選單 |
| FastStone | 底部 / 邊緣懸浮 | 縮放工具 / EXIF 面板 | 中 | View 選單 |
| macOS Preview | 無（Inspector） | 尺寸、色彩空間、ICC Profile | — | Cmd+I |
| XEE | 底部固定 | 尺寸、格式、色彩、DPI | 低 | View 選單 |
| ACDSee | 底部固定 | 完全自訂（Token） | 高 | Settings |
| Nomacs | 底部固定 | 縮放、索引、大小、日期 | 低 | Panels 選單 |
| qView | 無（Title Bar） | 依模式顯示 | 中 | Options |
| ImageGlass | 無傳統（Title Bar） | 檔名、縮放 | 低 | T/G |

### 共通模式

**核心資訊三要素（幾乎所有瀏覽器標配）**：
1. 圖片尺寸（W×H 像素）
2. 縮放比例（百分比）
3. 資料夾索引（N / Total）

**次要資訊（50% 以上提供）**：檔案大小（KB/MB）、色彩深度（BPP）、日期時間

**進階資訊（少數高階工具）**：色彩空間/ICC Profile、EXIF、評分/標籤

### 設計趨勢分歧

| 路線 | 代表 | 特點 |
|------|------|------|
| 傳統 | IrfanView、XnView、XEE | 完整底部 Status Bar |
| 現代極簡 | qView、ImageGlass v9 | 移除 Status Bar，資訊集中 Title Bar |
| macOS 慣例 | Preview | Inspector 面板 |

**Cee 定位**：作為 XEE 替代品，**固定底部 Status Bar** 最合理。

### 重要 UX 教訓

> **Pixea** 的浮動 overlay status bar 被使用者抱怨「stays on the image」導致用戶流失。Overlay 覆蓋圖片內容是 UX 反模式。

---

## 二、UI/UX 最佳實踐

### Apple HIG 定位

Apple HIG 中 "Status Bar" 是 iOS 概念（macOS 不支援）。macOS 對應概念是 **Bottom Bar**。

Apple HIG Windows 頁面說明：
> "Avoid putting critical information or actions in a bottom bar... use it only to display a small amount of information directly related to a window's contents."

### 資訊優先級

| 層級 | 資訊 | 格式範例 | 理由 |
|------|------|---------|------|
| **Must-have** | 圖片索引 | `3 / 47` | 位置感知，最核心的瀏覽狀態 |
| **Must-have** | 縮放比例 | `75%` 或 `Fit` | 最常確認的視圖狀態 |
| **Must-have** | 圖片尺寸 | `3840 × 2160` | 判斷圖片規格的核心需求 |
| Nice-to-have | 檔案名稱 | `DSC_0042.jpg` | 確認目前看的檔案（標題列已有） |
| Nice-to-have | 檔案大小 | `2.4 MB` | 輔助資訊 |
| Nice-to-have | 格式 | `JPEG` / `PNG` | 快速識別格式 |
| Overkill | 色彩空間、EXIF、磁碟路徑 | — | 對一般使用者太多 |

### 推薦佈局

```
┌──────────────────────────────────────────────────────────────┐
│  photo_001.jpg │ 3840 × 2160  JPEG  2.4 MB │  3 / 47  75%  │
│  ←── 左側（可截斷）────  中間（寬視窗才顯示）──  右側（不截斷）→  │
└──────────────────────────────────────────────────────────────┘
```

- 左側：識別資訊（可截斷）
- 右側：視圖狀態（**永不截斷**）
- 縮放用百分比（比 `3:4` 對一般使用者更直觀）
- Fit 狀態顯示 `Fit` 字樣

### 響應式降級

| 視窗寬度 | 顯示項目 | 隱藏項目 |
|---------|---------|---------|
| 寬（>600px） | 全部：名稱 + 尺寸 + 格式 + 大小 + 索引 + 縮放 | — |
| 中（400-600px） | 名稱截斷 + 尺寸 + 索引 + 縮放 | 格式、大小 |
| 窄（<400px） | **僅索引 + 縮放** | 名稱、尺寸、格式、大小 |

### Fullscreen 互動

Apple HIG 建議：
> "Prioritize content by temporarily hiding toolbars and navigation controls... let people restore the hidden elements with a familiar gesture or action."

- 進入全螢幕 → **自動隱藏** bottom bar
- 滑鼠移至視窗底部 → **半透明浮現**
- 不應永遠顯示（干擾沉浸感）或完全隱藏無法喚回

### 無障礙與主題

- 所有 UI 元素提供 `accessibilityLabel`
- 圖片切換時觸發 `AccessibilityNotification`
- 最低對比度：小文字 4.5:1（WCAG AA）
- 使用 semantic colors（`NSColor.labelColor`、`NSColor.secondaryLabelColor`）自動適配 dark/light mode
- 高度 **22pt**（同 Finder 慣例）

---

## 三、技術實作方案比較

### 方案一覽

| 方案 | 說明 | 優點 | 缺點 |
|------|------|------|------|
| **Container View + Auto Layout** | container 包含 scrollView + statusBar | 標準 AppKit、不碰 contentInsets、佈局自動 | loadView 改動較多 |
| Overlay + scrollerInsets | statusBar 浮在 window contentView 上 | 架構影響最小 | 遮圖片（UX 反模式）、contentInsets 衝突 |
| NSSplitView | 垂直分割 | 現成 API | 過度設計、多餘的拖拉分割線 |
| contentInsets | 用 NSScrollView.contentInsets 留白 | 簡單 | 與現有 applyCenteringInsetsIfNeeded() 衝突 |

### 採用方案：Container View + Auto Layout ✅

**理由**：
1. **零衝突**：不碰 `contentInsets`，`applyCenteringInsetsIfNeeded()` 完全不需修改（`scrollView.bounds.size` 在 layout pass 後自動正確）
2. **不遮圖片**：scrollView 被 Auto Layout 自動縮小，status bar 在圖片區域之外
3. **符合 UX 慣例**：固定底部條，同 Finder、XEE
4. **改動集中**：主要只改 `loadView()`，其他邏輯幾乎不受影響
5. **First Responder 不受影響**：scrollView 仍是 NSScrollView 實例

### 架構變化

**現有**：
```
NSWindow.contentView
  └── ImageScrollView (= ImageViewController.view)
        └── ImageContentView (documentView)
```

**改為**：
```
NSWindow.contentView
  └── NSView container (= ImageViewController.view)
        ├── ImageScrollView
        │     └── ImageContentView (documentView)
        └── StatusBarView (高度 22pt，底部固定)
```

### loadView() 改動

```swift
override func loadView() {
    contentView = ImageContentView()
    scrollView = ImageScrollView(frame: .zero)
    scrollView.documentView = contentView
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
        scrollView.topAnchor.constraint(equalTo: container.topAnchor),
        scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        scrollView.bottomAnchor.constraint(equalTo: statusBarView.topAnchor),

        statusBarView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        statusBarView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        statusBarView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        statusBarHeightConstraint,
    ])

    self.view = container
}
```

### 顯示/隱藏動態切換

```swift
private func applyStatusBar() {
    let visible = settings.showStatusBar
    statusBarView.isHidden = !visible
    statusBarHeightConstraint.constant = visible ? Constants.statusBarHeight : 0
    applyCenteringInsetsIfNeeded(reason: "applyStatusBar")  // 重要：重新計算置中 insets
}
```

### 動態更新時機

- 圖片載入完成 → `loadCurrentImage` Task 完成後 → `updateStatusBar()`
- Zoom 變化 → `scrollViewMagnificationDidChange` delegate callback → `statusBarView.updateZoom(_:isFitting:)`
- 翻頁 → `goToNextImage` / `goToPreviousImage`（透過 `loadCurrentImage` 間接觸發）

### 縮放顯示邏輯

實作時確立的三態顯示規則：
- **Fit 模式**（`!isManualZoom && alwaysFitOnOpen`）→ 顯示 `Fit`
- **100% 手動**（`zoom ≈ 1.0`，容差 ±1%）→ 顯示 `100%`
- **其他百分比** → 顯示 `N%`（四捨五入至整數）

### 注意事項

- `resizeToFitImage` 傳入的尺寸需考慮 status bar 高度偏移
- `lastWindowHeight` 持久化包含 status bar 高度（預期行為）
- `window.makeFirstResponder(scrollView)` 仍然有效

---

## 四、Menu 與 Settings 整合方案

### macOS 慣例

| App | Menu 項目 | 快捷鍵 |
|-----|---------|--------|
| Finder | View → "Show Status Bar" / "Hide Status Bar" | **Cmd+/** |
| TextEdit | View → "Show/Hide" 系列 | — |
| Xcode | View → 子選單 | — |

### ViewerSettings 新增

```swift
// MARK: - UI
var showStatusBar: Bool = true
```

Codable struct，decode 失敗時自動用預設值，向後兼容。

### AppDelegate.setupMenuBar() 新增

在 Float on Top 之後，加 separator + toggle：
```swift
viewMenu.addItem(.separator())
viewMenu.addItem(makeItem("Show Status Bar",
    action: #selector(ImageViewController.toggleStatusBar(_:)),
    key: "/"))
```

### ImageViewController toggle action

```swift
@objc func toggleStatusBar(_ sender: Any? = nil) {
    settings.showStatusBar.toggle()
    settings.save()
    applyStatusBar()
}
```

### validateMenuItem 更新

```swift
case #selector(toggleStatusBar(_:)):
    menuItem.title = settings.showStatusBar ? "Hide Status Bar" : "Show Status Bar"
    return true
```

---

## 五、實作過程中發現的重要 Gotchas

Phase 1 實作過程中，Container View 架構改造引發了幾個全螢幕置中相關的連鎖問題，需要額外修復：

### 5.1 AppKit magnify 期間 contentInsets 被重置

**問題**：`setMagnification(_:centeredAt:)` 在 pinch zoom 期間會將 `contentInsets` 重置為零，導致置中效果瞬間消失，畫面閃動到左上角。

**解法**：新增 `setMagnificationPreservingInsets()` wrapper，在 `setMagnification` 後立即恢復上一幀的 insets，並提供 `computedCenteringInsets()` 作為 fallback 保底。同時設定 `automaticallyAdjustsContentInsets = false` 防止 AppKit 自動干預。

### 5.2 全螢幕轉換後 scroll position 漂移

**問題**：進入/退出全螢幕後，scroll position 可能停留在非法範圍（例如超出 inset 後的有效區域），導致圖片貼在左邊或上邊。

**解法**：
- `ImageWindowController` 新增 `windowDidEnterFullScreen` 通知監聽（原本只有 `willEnter` 和 `didExit`）
- 全螢幕轉換完成後呼叫 `handleFullscreenTransitionDidComplete()`，執行 `layoutSubtreeIfNeeded()` → `applyCenteringInsetsIfNeeded()` → `centerScrollPositionInValidRange()` 三步驟確保位置正確
- 全螢幕時隱藏 scrollers（`hasVerticalScroller = false`），避免 scroller 殘影

### 5.3 Pinch zoom anchor 漂移

**問題**：連續 pinch zoom 時，每幀的 viewport center 會因為上一幀的 inset 變化而偏移，導致放大過程中畫面逐漸往左飄。

**解法**：`activeMagnifyAnchor` 在手勢 `.began` 時鎖定 viewport 中心座標，整個手勢過程中使用同一個 anchor point。手勢 `.ended`/`.cancelled` 時清除。新增 `zoomAnchorPoint()` 智慧計算：當圖片小於視窗時使用文件中心，避免 anchor 落在空白區域。

### 5.4 DebugCentering 日誌系統

為追蹤上述置中問題，新增了 `DebugCentering` 日誌系統（`TestMode.swift`）：
- 透過 `--debug-centering` 啟動參數或 `CEE_DEBUG_CENTERING=1` 環境變數啟用
- 使用 `OSLog` + stderr 雙通道輸出
- `applyCenteringInsetsIfNeeded()` 新增 `reason` 參數追蹤呼叫來源

### 5.5 XCUITest 全螢幕縮放測試

新增 `testFullscreenZoom_RemainsHorizontallyCentered` 測試，透過 `accessibilityValue` 暴露 scroll metrics（magnification、originX、minX、maxX），驗證全螢幕下放大/縮小後圖片不會貼邊。

---

## 六、MVP 分層實作建議

### Phase 1 — 基礎可用（MVP）✅ 完成
- [x] StatusBarView（NSView 子類，高度 22pt）— `Cee/Views/StatusBarView.swift`
- [x] 顯示：**索引 N/M** + **縮放 %/Fit** + **圖片尺寸 W×H**
- [x] Container View + Auto Layout 架構改造
- [x] Menu toggle（Cmd+/）+ ViewerSettings 持久化
- [x] Semantic colors（`NSColor.secondaryLabelColor`，自動 dark/light mode）
- [x] 頂部 1px 分隔線（`NSColor.separatorColor`）
- [x] 全螢幕置中穩定性修復（連鎖問題，見第五節）

### Phase 2 — 需求滿足
- [ ] 檔名顯示（左側，可截斷）
- [ ] 格式 + 檔案大小顯示
- [ ] 響應式降級（視窗變窄時隱藏次要資訊）

### Phase 3 — 優化完善
- [ ] Fullscreen 自動隱藏 + 滑鼠移至底部喚回
- [ ] VoiceOver accessibility 支援
- [ ] 動畫顯示/隱藏過渡效果

---

## 七、變更的檔案清單（Phase 1）

| 檔案 | 變更類型 | 說明 |
|------|---------|------|
| `Cee/Views/StatusBarView.swift` | 新增 | Status bar UI 元件（3 個 label + separator） |
| `Cee/Controllers/ImageViewController.swift` | 修改 | Container View 架構、toggle、updateStatusBar、全螢幕置中修復 |
| `Cee/Controllers/ImageWindowController.swift` | 修改 | 新增 `windowDidEnterFullScreen` 通知、全螢幕轉換回調 |
| `Cee/Views/ImageScrollView.swift` | 修改 | `setMagnificationPreservingInsets`、`zoomAnchorPoint`、`automaticallyAdjustsContentInsets = false` |
| `Cee/Models/ViewerSettings.swift` | 修改 | 新增 `showStatusBar: Bool = true` |
| `Cee/Utilities/Constants.swift` | 修改 | 新增 `statusBarHeight: CGFloat = 22` |
| `Cee/Utilities/TestMode.swift` | 修改 | 新增 `DebugCentering` 日誌系統 |
| `Cee/App/AppDelegate.swift` | 修改 | View menu 加 separator + "Show Status Bar"（Cmd+/） |
| `CeeUITests/CeeUITests.swift` | 修改 | 新增全螢幕縮放置中測試 |
| `CLAUDE.md` | 修改 | 新增 Status Bar section 記錄架構慣例 |

---

## 八、參考來源

| 類別 | 來源 |
|------|------|
| Apple HIG: Windows（Bottom Bar） | https://developer.apple.com/design/human-interface-guidelines/windows |
| Apple HIG: Toolbars | https://developer.apple.com/design/human-interface-guidelines/toolbars |
| Apple HIG: Going Full Screen | https://developer.apple.com/design/human-interface-guidelines/going-full-screen |
| Apple HIG: Accessibility | https://developer.apple.com/design/human-interface-guidelines/accessibility |
| Apple HIG: Dark Mode | https://developer.apple.com/design/human-interface-guidelines/dark-mode |
| Finder Status Bar 慣例 | https://mactrast.com/2017/03/show-status-bar-finder-macos-sierra |
| Pixea UX 問題（overlay 反模式） | https://forums.macrumors.com/threads/minimalistic-image-viewer.2433354/ |
| NSScrollView.contentInsets 文件 | https://developer.apple.com/documentation/appkit/nsscrollview/contentinsets |
| Overlay NSView over NSScrollView | https://stackoverflow.com/questions/4723199/overlay-nsview-over-nsscrollview |
| NSScrollView scroller insets | https://stackoverflow.com/questions/9140768/nsscrollview-content-and-scroller-insets |
| ACDSee Status Bar 設定 | https://help.acdsystems.com/en/acdsee-photo-studio-11-mac/Content/1Topics/Setting_options/setting_statusbar.htm |
| Nomacs GitHub Issues | https://github.com/nomacs/nomacs/issues/1297 |
| ImageGlass 文件 | https://imageglass.org/docs/features |
| XnView MP 論壇 | https://newsgroup.xnview.com/viewtopic.php?t=46995 |
| IrfanView 論壇 | https://irfanview-forum.de/forum/program/support/94699-editing-bottom-status-bar |
| FastStone 文件 | https://documentation.help/FastStone-Image-Viewer/ViewingImages.htm |
| Geeqie Status Bar | https://www.geeqie.org/help/GuideMainWindowStatusBar.html |
| EdgeView 3 Zoom | https://www.edgeview.co.kr/?docs=help/image-viewer/zoom-in-out |
| Mario Guzman Toolbar Guidelines | https://marioaguzman.github.io/design/toolbarguidelines/ |
