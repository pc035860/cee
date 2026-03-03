# Brainstorm: Quick Grid 縮圖大小調整

> 研究日期：2026-03-04
> 分支：feat/image-browse-phase2
> 前置功能：Quick Grid (Phase 2) — G 鍵切換的 NSCollectionView 縮圖網格 overlay

## 目標

在 Quick Grid overlay 介面中，允許使用者動態調整縮圖大小，提升不同瀏覽情境的靈活性。

---

## 一、競品調查

### 1.1 各競品方案一覽

| 競品 | 大小範圍 | Pinch | Slider | 鍵盤 | Cmd+Scroll | 記憶 |
|------|----------|-------|--------|------|-----------|------|
| macOS Finder | 16–512px | ❌（10.9 後移除） | ✅ Status Bar 右下 | ❌ | ❌ | Per-folder |
| Adobe Bridge | 40–1024px | ❌ | ✅ 底部狀態列 | Cmd+=/- | ❌ | 全域 |
| Apple Photos | ~3–6 欄 | ✅ | ❌ | ❌ | ❌ | 全域 |
| Lightroom Classic | 40–340px | ❌ | ✅ 底部工具列 | -/+ 裸鍵 | ❌ | 全域 |
| XnViewMP | 32–1000px | ❌ | ✅ 工具列 | ❌ | ❌（長期 FR） | 全域 |
| FastStone | 5 固定 preset | ❌ | ❌ | ❌ | ❌ | 全域 |
| ACDSee | Tiles 有 slider | ❌ | ✅ Options 內 | ❌ | ❌ | 全域 |

### 1.2 關鍵觀察

1. **Slider 是最普遍的機制**：Finder、Bridge、Lightroom、XnViewMP 都有
2. **Pinch 手勢只有 Apple Photos 使用**：但在 macOS trackpad 普及的環境下最直覺
3. **鍵盤快捷鍵**：Bridge 用 Cmd+=/-, Lightroom 用裸 -/+ 鍵
4. **Cmd+Scroll**：無競品實作，但社群長期要求（XnViewMP forum）
5. **記憶設定**：多數全域儲存，Finder 例外（per-folder）
6. **常見合理範圍**：60px–512px，預設 120–200px

### 1.3 操作直覺性排名

1. Apple Photos（Pinch）⭐⭐⭐⭐⭐
2. Lightroom（裸鍵 + Slider）⭐⭐⭐⭐⭐
3. Adobe Bridge（Cmd+=/- + Slider）⭐⭐⭐⭐
4. macOS Finder（Slider）⭐⭐⭐
5. FastStone（Settings preset）⭐

---

## 二、技術方案研究

### 2.1 NSCollectionViewFlowLayout 動態調整

**推薦方法**：直接修改 `flowLayout.itemSize` + `invalidateLayout()`

```swift
flowLayout.itemSize = NSSize(width: newSize, height: newSize)
collectionView.collectionViewLayout.invalidateLayout()
```

**效能比較**（1000+ items）：

| 方法 | 行為 | 效能 |
|------|------|------|
| `invalidateLayout()` | 只重算佈局，保留 cells | ~1-5ms ✅ |
| `reloadData()` | 重建所有可見 cells | ~50-200ms ❌ |

**結論**：縮放時只用 `invalidateLayout()`，永不 `reloadData()`。

### 2.2 Pinch-to-Zoom 實作

**核心要點**：不能用 `NSScrollView.allowsMagnification`（那是整體視覺縮放），必須 override `magnifyWithEvent`。

```swift
// 在 GridCollectionView（已有子類別）中 override
override func magnifyWithEvent(_ event: NSEvent) {
    let delta = event.magnification
    let newSize = clamp(currentItemSize * (1 + delta), min: minSize, max: maxSize)
    applyItemSize(newSize)
    // 不呼叫 super，防止 NSScrollView 視覺縮放
}
```

- Scroll 和 magnify 是分開的 event 類型，不衝突
- 建議 `.ended` 時 snap 到步進值（可選）

### 2.3 Cmd+Scroll 實作

```swift
// 在 QuickGridView 的 enclosing NSScrollView 中
override func scrollWheel(with event: NSEvent) {
    if event.modifierFlags.contains(.command) {
        let delta = event.scrollingDeltaY
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 0.5 : 3.0
        let newSize = clamp(currentItemSize + delta * factor, min: minSize, max: maxSize)
        applyItemSize(newSize)
    } else {
        super.scrollWheel(with: event)
    }
}
```

**注意**：須防止 Cmd+Scroll 穿透到底層 `ImageScrollView`（主視圖的 Cmd+Scroll = 圖片縮放）。

### 2.4 Slider 整合

```swift
let slider = NSSlider()
slider.minValue = Double(minCellSize)
slider.maxValue = Double(maxCellSize)
slider.isContinuous = true  // 拖動即時觸發
```

不需 debounce — `invalidateLayout()` 在 1000+ items 下也夠快。

### 2.5 動畫過渡

```swift
NSAnimationContext.runAnimationGroup { context in
    context.duration = 0.2
    context.allowsImplicitAnimation = true
    flowLayout.itemSize = NSSize(width: newSize, height: newSize)
    collectionView.collectionViewLayout.invalidateLayout()
}
```

前提：NSScrollView 必須 `wantsLayer = true`（否則動畫不可見）。

### 2.6 關鍵陷阱

1. **不要用 `allowsMagnification = true`** — 視覺縮放，非 itemSize 調整
2. **不要用 `reloadData()` 縮放** — 1000+ items 卡頓
3. **不要用舊 API** `setMinItemSize:/setMaxItemSize:` + private method
4. **`wantsLayer = true`** 才有動畫
5. **Cmd+Scroll 攔截** 需防穿透到底層

---

## 三、現有架構分析

### 3.1 關鍵架構約束

**Constants.swift（第23-27行）**：
- `quickGridCellSize = 120`（固定值，無 min/max）

**QuickGridView.swift**：
- `setupUI()` 用常數設定 `layout.itemSize`，初始化後不再更新
- `loadThumbnail` 硬編碼 `maxSize: 240`
- `gridThumbnails: [Int: NSImage]` — Grid-local 快取，index-based

**ImageLoader.swift（第20行）— 核心限制**：
```swift
private var thumbnailCache: [URL: ThumbnailEntry] = [:]
```
快取 key 只有 URL，**沒有 maxSize**。相同圖片不同 maxSize 會 cache hit 舊尺寸。

### 3.2 縮圖解析度策略

| 策略 | 適用範圍 | 改動量 | 建議 |
|------|----------|--------|------|
| 固定 240px | 80–200pt cell | 無需改動 | ✅ MVP |
| 動態 maxSize | 200pt+ 需更高解析度 | thumbnailCache key 需加 size 維度 | Phase 2+ |

**MVP 建議**：保持 `maxSize: 240` 不變。80–200pt 範圍內，240px 縮圖品質足夠（@1x 有餘，@2x 在小 cell 下也可接受）。

---

## 四、方案評估

### 方案 A：純 Pinch-to-Zoom（最小改動）

| 項目 | 內容 |
|------|------|
| 修改檔案 | Constants.swift (+3行), QuickGridView.swift (+35-45行) |
| 機制 | `magnifyWithEvent` override on `GridCollectionView` |
| 優點 | 改動最少、Apple Photos 風格、trackpad 直覺 |
| 缺點 | 無滑鼠用戶無法使用、可發現性中等 |
| 風險 | 中等（需確保 `allowsMagnification = false`） |
| MVP 適合 | ✅ Phase 1 首選 |

### 方案 B：Slider + Pinch（Finder/Bridge 風格）

| 項目 | 內容 |
|------|------|
| 修改檔案 | Constants.swift (+3行), QuickGridView.swift (+60-80行) |
| 機制 | 底部 NSSlider + magnifyWithEvent |
| 優點 | 可發現性高、滑鼠用戶友好、業界標準 |
| 缺點 | UI 複雜度增加、z-order 處理 |
| 風險 | 中高（Slider 與 ESC 焦點衝突、底部 layout） |
| MVP 適合 | ✅ Phase 2 |

### 方案 C：Slider + Pinch + 鍵盤（完整版）

| 項目 | 內容 |
|------|------|
| 修改檔案 | Constants.swift (+3行), QuickGridView.swift (+80-100行), GridCollectionView (+10行) |
| 機制 | Slider + Pinch + Cmd+=/- 或裸 -/+ |
| 優點 | 全方位覆蓋、專業用戶最愛 |
| 缺點 | 鍵盤快捷鍵衝突測試複雜 |
| 風險 | 中高（Cmd+=/- 可能與系統 Zoom 衝突） |
| MVP 適合 | ❌ 過度工程化 |

### 方案 D：僅鍵盤 Cmd+/-（最簡方案）

| 項目 | 內容 |
|------|------|
| 修改檔案 | Constants.swift (+3行), QuickGridView.swift (+30行), GridCollectionView (+8行) |
| 機制 | Cmd+= / Cmd+- 在 keyDown 處理 |
| 優點 | 最易實作、無手勢衝突 |
| 缺點 | 可發現性最低、不直覺 |
| 風險 | 最低 |
| MVP 適合 | ✅ 可作為快速驗證 |

---

## 五、建議參數

| 參數 | 建議值 | 理由 |
|------|--------|------|
| 最小 cell size | 80pt | 可辨認內容，1920px 螢幕 ~20 張/行 |
| 最大 cell size | 200pt | 再大失去 Grid 瀏覽優勢 |
| 預設值 | 120pt | 現有值，保持 UX 基準 |
| 縮圖 maxSize | 固定 240px（MVP） | 涵蓋 80-200pt @1x，避免快取衝突 |
| 記憶設定 | 全域（非 per-folder） | 競品主流做法，實作簡單 |

---

## 六、推薦實作路線

### Phase 1 — MVP（方案 A：Pinch + Cmd+Scroll）✅ 已完成

> 完成日期：2026-03-04 | 分支：feat/grid-thumnail-resize | Commits: 7738b20, 128a571

實際改動：~100 行

1. ✅ `Constants.swift`：加 `quickGridMinCellSize = 80`, `quickGridMaxCellSize = 200`
2. ✅ `QuickGridView.swift`：加 `currentCellSize` 狀態 + `applyItemSize()` 統一入口
3. ✅ `GridCollectionView`：override `magnify(with:)`（Pinch，incremental 計算）
4. ✅ `GridScrollView`（新增 NSScrollView 子類別）：override `scrollWheel`（Cmd+Scroll）
5. ✅ 縮圖保持 `maxSize: 240`，不改 ImageLoader
6. ✅ 240px 縮圖在 80-200pt 範圍內有效，resize 時不清除快取（NSImageView 自動縮放）

**實作要點**：
- Pinch 使用 `currentCellSize * (1 + event.magnification)` incremental 計算，匹配 ImageScrollView 模式
- Cmd+Scroll 區分 trackpad (sensitivity 0.5) vs mouse (sensitivity 3.0) via `hasPreciseScrollingDeltas`
- 兩個 override 都不呼叫 `super`，防止事件穿透到底層 ImageScrollView
- `allowsMagnification = false` 防止 NSScrollView 消費 pinch 事件

### Phase 2 — 增強（方案 B：加 Slider）✅ 已完成

> 完成日期：2026-03-04 | 分支：feat/grid-thumnail-resize | Commits: 9173bb5, c902642

實際改動：~120 行

1. ✅ 底部加 NSSlider（30pt sliderContainer，仿 Finder Status Bar）
2. ✅ Slider 與 Pinch/Cmd+Scroll 雙向同步（`isUpdatingSliderProgrammatically` 防回授迴圈）
3. ✅ Cmd+=/- 鍵盤快捷鍵（含 Cmd+Shift+= 變體）
4. ✅ size 記憶（ViewerSettings.quickGridCellSize + UserDefaults）

### Phase 3 — 優化（確認瓶頸才做）

1. 動態縮圖解析度（cellSize > 200pt 時用更高 maxSize）
2. thumbnailCache key 加入 size 維度
3. 縮放動畫（NSAnimationContext）

---

## 七、參考來源

### Apple 官方文件
- [NSCollectionViewFlowLayout](https://developer.apple.com/documentation/appkit/nscollectionviewflowlayout)
- [NSCollectionViewDelegateFlowLayout sizeForItemAt](https://developer.apple.com/documentation/appkit/nscollectionviewdelegateflowlayout/collectionview(_:layout:sizeforitemat:))
- [NSMagnificationGestureRecognizer](https://developer.apple.com/documentation/appkit/nsmagnificationgesturerecognizer)

### 競品參考
- [macOS Finder icon size](https://support.apple.com/en-bn/guide/mac-help/mchldaafb302/mac)
- [Adobe Bridge content panel](https://helpx.adobe.com/bridge/using/adjust-bridge-content-panel-display.html)
- [Lightroom Grid View](https://jkost.com/blog/2024/06/working-in-grid-and-loupe-view-in-lightroom-classic.html)
- [Apple Photos keyboard shortcuts](https://support.apple.com/guide/photos/keyboard-shortcuts-and-gestures-pht9b4411b24/mac)

### 技術參考
- [NSCollectionView pinch zoom (SO)](https://stackoverflow.com/questions/6897086/nscollectionview-pinch-zoom)
- [Animate NSCollectionView relayout (SO)](https://stackoverflow.com/questions/52091074/how-to-animate-a-relayout-of-nscollectionviewlayout-on-bounds-change)
- [Cmd+Scroll magnify (SO)](https://stackoverflow.com/questions/46785553/nsscrollview-magnify-with-cmdscroll-interaction-with-preserved-responsive-scro)
- [XnViewMP Ctrl+Wheel FR](https://newsgroup.xnview.com/viewtopic.php?t=50323)
- [NSCollectionView performance](https://github.com/seido/testCollectionViewPerformance)
