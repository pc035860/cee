# Brainstorm: 條漫風格連續捲動模式 (Continuous Scroll / Webtoon Mode)

## 概述

新增類似韓國條漫的連續垂直捲動瀏覽模式。圖片垂直堆疊，使用者可無限往下滑，新圖片自動載入。

### 核心需求
1. **Zoom Level 一致**：切換圖片時維持相同縮放比例
2. **動態視窗 Resize**：滑到不同尺寸圖片時，視窗依新圖片尺寸動態調整
3. **中心點保持**：Resize 時視窗中心點維持在同一螢幕位置

---

## 業界現況

### 桌面應用調查

| App | 平台 | 連續捲動 | 動態 Resize | 備註 |
|-----|------|---------|------------|------|
| OpenComic | Electron, 跨平台 | ✅ Webtoon 模式 | ❌ | 最佳開源參考，0px gap，fit-to-width |
| Yomikiru | Electron/React | ✅ 無縫捲動 | ❌ | 解碼卡頓經驗值得參考 |
| SumatraPDF | C/C++, Windows | ✅ PDF 式連續 | ❌ | 有頁間距，非 webtoon 風格 |
| CDisplayEx | Windows | ❌ | ❌ | 僅翻頁模式 |
| YACReader | C++/Qt, 跨平台 | ❌（僅 iOS） | ❌ | 多年 feature request 未實作 |

**關鍵發現：**
- **沒有任何桌面應用**在連續捲動中動態調整視窗大小 — 全部使用固定視窗 + fit-to-width
- 動態視窗 Resize 是**獨創設計**
- 最大技術挑戰：圖片解碼卡頓 + 記憶體管理

### 業界 UX 共識
- **Fit-to-width** 是連續捲動的標準預設
- **0px gap**（無縫）為 webtoon，可選間距為漫畫
- Zoom = 統一 scale factor 套用所有圖片
- 大量圖片需 lazy loading + cache eviction

---

## 推薦技術架構

### 核心架構：ContinuousScrollContentView

```
ImageScrollView (NSScrollView)
└── NSClipView
    └── ContinuousScrollContentView (documentView, frame.height = 所有圖片總高度)
        ├── ImageSlotView[0] (recycled, layer.contents = cgImage)
        ├── ImageSlotView[1] (recycled, layer.contents = cgImage)
        ├── ImageSlotView[2] (recycled, layer.contents = cgImage)
        └── ... (僅 visible + buffer 存在於 view hierarchy)
```

### 關鍵設計決定

| 項目 | 推薦方案 | 理由 |
|------|---------|------|
| DocumentView 策略 | 單一高文件視圖 + view recycling | AppKit 支援極大座標空間（Helftone 已驗證） |
| View Recycling | `reflectScrolledClipView` + pool | NSScrollView 沒有 cell reuse，這是 canonical 做法 |
| 圖片尺寸 | 啟動時 pre-scan headers（~0.1ms/張） | Cee 已有 `sampleMedianAspectRatio` 和 `imageSizeCache` 可複用 |
| 渲染 | `layer.contents = cgImage`（GPU） | Cee 既有模式，60fps 保證 |
| 寬度策略 | Fit-to-width（所有圖統一寬度） | 業界標準，佈局最簡潔 |
| Pool 大小 | visible + 2×buffer ≈ 8-12 slots | 足夠平滑捲動又不浪費記憶體 |

### View Recycling 核心模式

```swift
// reflectScrolledClipView — canonical hook for AppKit scroll-driven updates
override func reflectScrolledClipView(_ cView: NSClipView) {
    super.reflectScrolledClipView(cView)
    let visibleRect = documentVisibleRect
    let visibleRange = calculateVisibleRange(for: visibleRect, buffer: 2)

    // Recycle out-of-range slots
    for slot in activeSlots where !visibleRange.contains(slot.imageIndex) {
        slot.removeFromSuperview()
        slot.prepareForReuse()  // clear layer.contents
        reusableSlots.append(slot)
    }

    // Place newly visible slots
    for index in visibleRange where !isSlotActive(for: index) {
        let slot = dequeueOrCreateSlot()
        slot.frame = frameForImage(at: index)
        documentView?.addSubview(slot)
        loadImage(for: index, into: slot)
    }
}
```

### 可直接複用的 Cee 元件

- `ImageContentView` — 無需修改（GPU 渲染）
- `ImageLoader` — 快取/預取架構
- `NavigationThrottle` — 20Hz 捲動節流
- `ThumbnailThrottle` — 並行解碼限制（max 4）
- `MemoryPressureMonitor` — 記憶體壓力監控
- `imageSizeCache` — 圖片尺寸快取
- `FittingCalculator` — Width-only fitting

---

## 動態視窗 Resize

### 動畫方案比較

| 方案 | 優缺點 | 評級 |
|------|--------|------|
| `setFrame(animate: true)` | 最簡單，但阻塞主線程、無法中斷 | C |
| `NSAnimationContext` | 有 completion handler，但不易重定向 | B |
| **`window.displayLink()`** (macOS 14+) | 可重定向、display-aware、可中斷 | **A** |

**推薦 CADisplayLink**：連續捲動時「目標圖片」快速變化，動畫必須能中途重新指向新目標。

```swift
// macOS 14+ — 從 window 取得 display link
let displayLink = window.displayLink(target: self, selector: #selector(animationStep(_:)))

@objc func animationStep(_ link: CADisplayLink) {
    let progress = min(1.0, elapsedTime / animationDuration)
    let easedProgress = easeInOut(progress)
    let currentFrame = interpolate(from: startFrame, to: targetFrame, t: easedProgress)
    window.setFrame(currentFrame, display: true)
    if progress >= 1.0 { link.invalidate() }
}
```

### 中心點保持演算法

```swift
func centeredFrame(for newSize: NSSize, relativeTo current: NSRect) -> NSRect {
    let cx = current.midX, cy = current.midY
    return NSRect(x: cx - newSize.width/2, y: cy - newSize.height/2,
                  width: newSize.width, height: newSize.height)
}
// + screen edge clamping via screen.visibleFrame
```

### 觸發策略

- **偵測方式**：Viewport 中心點跨越圖片邊界
- **防抖**：150ms debounce（複用 `NavigationThrottle`）
- **快速捲動**：滾動速度高於閾值時暫停 resize，停下來才觸發
- **全螢幕**：跳過 resize，僅調整 magnification/insets

### Zoom 一致性

維持 **zoom mode**（不是原始 magnification 值）：

```swift
enum ZoomMode {
    case fitWidth    // 預設 — 圖片寬度 = 視窗寬度
    case fitHeight
    case fitBoth
    case actualSize
    case custom(CGFloat)  // 使用者手動縮放
}
```

切圖時：`fitWidth` → 重算 `magnification = windowWidth / imageWidth`

### Edge Cases

| 情境 | 處理方式 |
|------|---------|
| 極高圖片（條漫長條） | Cap 在螢幕高度，不 resize |
| 極寬圖片 | 最小視窗高度限制（200px / 螢幕 25%） |
| 快速連續捲動 | Debounce + retargetable animation |
| 全螢幕模式 | 跳過 resize |
| 多螢幕 | `window.screen ?? NSScreen.main` |
| 動畫中切圖 | Retarget to new size（不重啟動畫） |

---

## 需要修改/新增的檔案

### 新增

| 檔案 | 內容 |
|------|------|
| `ContinuousScrollContentView.swift` | 垂直堆疊 + view recycling + 佈局計算 |

### 修改

| 檔案 | 變更 |
|------|------|
| `ViewerSettings.swift` | 加 `continuousScrollEnabled` 設定 |
| `ImageViewController.swift` | Mode 分支（載入、fitting、centering、導航） |
| `ImageScrollView.swift` | 關閉 page-turn、boundsDidChange 追蹤 current index |
| `ImageWindowController.swift` | 動態 resize 邏輯 |
| `AppDelegate.swift` | Menu item |

### 複雜度預估

- 新增程式碼：~400-600 行（ContinuousScrollContentView + layout）
- 修改程式碼：~200-300 行（ImageViewController mode branching）
- 風險區域：centering insets with very tall document、zoom anchor、memory management

---

## MVP 三階段開發計畫

### Phase 1 — 基礎可用版
- `ContinuousScrollContentView` + view recycling pool
- Pre-scan 圖片尺寸，設定 documentView 總高度
- Fit-to-width 佈局（所有圖統一寬度）
- 基本捲動 + 當前圖片 index 追蹤
- 關閉 page-turn 邏輯
- Menu item toggle

### Phase 2 — 動態視窗 Resize
- CADisplayLink 動畫 + 中心點保持
- Viewport 中心點觸發 + debounce
- Zoom mode 保持（fitWidth 預設）
- Edge case 處理（極高/極寬、全螢幕、快速捲動）

### Phase 3 — 優化完善
- 捲動方向感知預取
- `MemoryPressureMonitor` 整合
- 大圖片 subsample（`kCGImageSourceSubsampleFactor`）
- 鍵盤導航（arrow = smooth scroll）
- Quick Grid 整合（scrollToIndex）
- 圖片間距設定（0px 預設，可調）

---

## 參考資源

| 資源 | 用途 |
|------|------|
| [Helftone Infinite NSScrollView](https://blog.helftone.com/infinite-nsscrollview/) | AppKit 無限捲動核心模式 |
| [HTInfiniteScrollView (Swift)](https://github.com/dagronf/HTInfiniteScrollView) | Swift port |
| [SO: NSScrollView subview reuse](https://stackoverflow.com/questions/9115944) | `reflectScrolledClipView` view recycling |
| [CADisplayLink best practices](https://philz.blog/in-process-animations-and-transitions-with-cadisplaylink-done-right/) | macOS 14+ 動畫最佳實踐 |
| [Center-preserving resize](https://stackoverflow.com/questions/13053227) | 中心點保持數學 |
| [Optimized NSTableView Scrolling](https://jwilling.com/blog/optimized-nstableview-scrolling/) | Layer-backing 效能模式 |
| [OpenComic](https://github.com/ollm/OpenComic) | 最佳 Webtoon UX 參考 |
| [Yomikiru](https://github.com/mienaiyami/yomikiru) | 效能問題經驗教訓 |
| [InfiniteScrollViews (AppKit)](https://github.com/b5i/InfiniteScrollViews) | AppKit 無限捲動 Swift package |
