# Brainstorm: 條漫風格連續捲動模式 (Continuous Scroll / Webtoon Mode)

## 實作狀態

| Phase | 狀態 | 說明 |
|-------|------|------|
| Phase 1 | ✅ 完成 | 基礎可用版：`ContinuousScrollContentView`、圖片尺寸預載、fit-to-width 佈局、index 追蹤、menu toggle |
| Phase 2 | ✅ 完成 | 動態視窗 Resize：`CADisplayLink` 動畫、中心點保持、全螢幕處理、狀態恢復修正 |
| Phase 3.1 | ✅ 完成 | 實際圖片渲染：`ImageSlotView` (layer-backed GPU 渲染)、view recycling、非同步載入 |
| Phase 3.2 | ✅ 完成 | 捲動方向感知預取：`NavigationThrottle` 20Hz 節流、`PrefetchDirection` 整合 |
| Phase 3.3 | ✅ 完成 | Zoom 支援：`effectiveMinMagnification` 1.0 clamp、magnification fast path、scaling filters、模式切換 reset |
| Phase 3.3.1 | ✅ 完成 | Zoom 閃爍修復：`beginZoomSuppression`/`endZoomSuppression` API + `calculateVisibleRange` O(log n) binary search |
| Phase 3.4 | ✅ 完成 | 記憶體監控整合（MemoryPressureMonitor warning/critical 兩階段） |
| Phase 3.5 | ✅ 完成 | 大圖 Subsample（kCGImageSourceSubsampleFactor + displayCache） |
| Phase 3.6+ | 📋 待辦 | 鍵盤導航、Quick Grid、間距、Fitting UI 適配 |

---

## Phase 2 實作細節

### 已完成功能

1. **狀態恢復修正**
   - `ImageViewController.viewDidAppear()` 現在會檢查 `settings.continuousScrollEnabled` 並恢復模式
   - `validateMenuItem` 支援 `toggleContinuousScroll` 選項顯示勾選狀態
   - `loadFolder(_:)` 正確處理 `continuousScrollEnabled` 設定

2. **佈局與中心修正**
   - `applyCenteringInsetsIfNeeded()` 在連續捲動模式下使用 fit-to-width insets
   - `scrollRange(for:)` 支援連續捲動模式的 document size
   - `currentDocumentSize` 在連續捲動模式下使用 `imageSizes`

3. **Status Bar 修正**
   - `updateStatusBar()` 在連續捲動模式下使用 `continuousScrollContentView?.imageSizes[safe: folder.currentIndex]`

4. **CADisplayLink 動態 Resize**
   - `ImageWindowController.animateResize()` 使用 CADisplayLink 平滑動畫
   - 中心點保持計算

5. **座標系統**
   - `ContinuousScrollContentView` 使用標準 macOS 座標系統（y=0 在底部）以配合 `ImageScrollView` 的 unflipped 行為
   - Binary search (O(log n)) 用於 index tracking
   - `scaledHeights` cache 避免重複計算

---

## Phase 3 實作細節

### ✅ 3.1 實際圖片渲染（已完成）

**實作檔案**：
- `Cee/Views/ImageSlotView.swift` - Layer-backed GPU 渲染 slot
- `Cee/Views/ContinuousScrollContentView.swift` - View recycling 邏輯

**技術方案**：
- `ImageSlotView` 使用 `wantsUpdateLayer = true` + `layer.contents = cgImage`
- View recycling：`activeSlots` / `reusableSlots` + `bufferCount = 2`
- 非同步載入：透過 `ImageLoader.loadImage(at:)` / `loadPDFPage(url:pageIndex:)`
- Stale write 防護：`slot.imageIndex == index` 檢查
- Configuration generation ID：防止 folder 切換時的 stale write

### ✅ 3.2 捲動方向感知預取（已完成）

**實作檔案**：
- `Cee/Views/ContinuousScrollContentView.swift` - `triggerPrefetch(visibleRange:)`

**技術方案**：
- 捲動方向追蹤：`lastScrollY` 比較（標準座標系統）
- 20Hz 節流：複用 `NavigationThrottle`
- 預取觸發：`ImageLoader.updateCache(prefetchDirection:)`

### ✅ 3.3 Zoom 支援（已完成）

**實作檔案**：
- `Cee/Views/ImageScrollView.swift` - `effectiveMinMagnification()` early return
- `Cee/Controllers/ImageViewController.swift` - magnification fast path, zoom action guards, mode toggle reset
- `Cee/Views/ContinuousScrollContentView.swift` - `setScalingFilters()` 方法
- `Cee/Views/ImageSlotView.swift` - `setScalingFilters()` 方法

**技術方案**：
- `effectiveMinMagnification()` 在連續捲動模式回傳 1.0（fit-to-width 基線）
- `scrollViewMagnificationDidChange` fast path：跳過 window resize/recenter，僅更新 centering insets + visible slots + status bar
- `zoomIn/zoomOut` guard `scheduleResizeToFitAfterZoom`
- `actualSize` redirect 到 `fitOnScreen`（連續模式下 1.0 = fit-to-width）
- `toggleContinuousScroll` 進入/離開時 reset magnification + `isManualZoom` + `settings.magnification`
- `ImageSlotView.setScalingFilters` + `ContinuousScrollContentView.setScalingFilters`（含 early-return guard + stored filters for new slots）
- `configureContinuousScrollView` 同步 `scrollView.continuousScrollEnabled` + 套用 scaling quality

### ✅ 3.3.1 Zoom 閃爍修復（已完成）

**實作檔案**：
- `Cee/Views/ContinuousScrollContentView.swift` - `beginZoomSuppression()`/`endZoomSuppression()` API、`calculateVisibleRange` binary search
- `Cee/Views/ImageScrollView.swift` - `setMagnificationPreservingInsets` 前置保護
- `Cee/Controllers/ImageViewController.swift` - 三條 zoom 路徑的 suppression 管理

**技術方案**：
- `calculateVisibleRange` 從 O(n) 線性掃描改為 O(log n)，重用 `calculateCurrentIndex` binary search
- `beginZoomSuppression()` / `endZoomSuppression(visibleBounds:)` 封裝 zoom 期間的 slot 回收暫停
- **關鍵時序**：`setMagnification` 同步觸發 `reflectScrolledClipView`，必須在呼叫前設好 suppression
- 三條路徑保護：pinch zoom（`setMagnificationPreservingInsets`）、Cmd+scroll（同上）、鍵盤 zoom（`setMagnificationCentered` defer）
- `isZooming` 為 `private(set)`，外部只能透過 `begin`/`end` 方法操作

### 📋 待辦功能（Phase 3.4+）

### 🟡 效能優化

#### 3.4 記憶體監控整合 ✅
- **目標**：記憶體壓力過高時自動清理 cache
- **技術方案**：整合 `MemoryPressureMonitor`（DispatchSource）
- **可複用**：`QuickGridView` 已有的 monitor 實作
- **實作**：warning → 縮減 buffer 到 0（下次 scroll 恢復）；critical → 清空 reusable pool + ImageLoader 全快取。Zoom 中延遲處理（escalate only）。

#### 3.5 大圖 Subsample ✅
- **目標**：使用 `kCGImageSourceSubsampleFactor` 降低大圖記憶體佔用
- **技術方案**：
  - 載入時檢查圖片尺寸
  - 若超過閾值（如 4K），使用 subsample factor 2 或 4
- **可複用**：`ThumbnailThrottle` 的 subsample 邏輯
- **實作**：`loadImageForDisplay(at:maxWidth:)` + `DisplayCacheKey(url, maxWidth)` 複合鍵 + 20px 量化。EXIF orientation 5-8 交換寬高。`displayCache` 獨立於 main cache，eviction 跟隨 `updateCache`。

### 🟢 功能增強（Nice to have）

#### 3.6 鍵盤導航
- **目標**：Arrow key 觸發 smooth scroll（而非 page-turn）
- **實作**：在 `ImageScrollView.keyDown` 中分支處理 continuous mode

#### 3.7 Quick Grid 整合
- **目標**：從 grid 選擇圖片後，`scrollToIndex()` 跳轉到對應位置
- **實作**：`ContinuousScrollContentView.scrollToIndex(_:)` 方法

#### 3.8 圖片間距設定
- **目標**：可調整圖片間距（0px 預設）
- **實作**：`ViewerSettings.continuousScrollGap` 屬性

#### 3.9 Fitting options UI 適配
- **目標**：連續捲動模式下 disable 不適用的 menu items，避免介面混淆
- **範圍**：Shrink H/V、Stretch H/V 等 fitting 選項在連續模式下無意義，應在 `validateMenuItem` 中 disable。`applyFitting` 加 continuous scroll guard。

### 建議實作順序

```
Phase 3.1 ─ 實際圖片渲染（核心，才能正常使用）✅
    ↓
Phase 3.2 ─ 捲動方向感知預取（流暢度）✅
    ↓
Phase 3.3 ─ Zoom 支援（pinch/keyboard zoom）✅
    ↓
Phase 3.3.1 ─ Zoom 閃爍修復（bug fix）✅
    ↓
Phase 3.4 ─ 記憶體監控整合（穩定性）✅
    ↓
Phase 3.5 ─ 大圖 Subsample（記憶體效率）✅
    ↓
Phase 3.6+ ─ 鍵盤導航 / Quick Grid / 間距 / UI 適配（UX polish）
```

---

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

**核心（必須）：**
- 🔴 實際圖片渲染（view recycling + `layer.contents = cgImage`）
- 🔴 捲動方向感知預取

**效能優化：**
- 🟡 `MemoryPressureMonitor` 整合
- 🟡 大圖片 subsample（`kCGImageSourceSubsampleFactor`）

**功能增強（Nice to have）：**
- 🟢 鍵盤導航（arrow = smooth scroll）
- 🟢 Quick Grid 整合（scrollToIndex）
- 🟢 圖片間距設定（0px 預設，可調）

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
