# Plan: 連續捲動模式 Resize 時保持捲動位置 ✅ 已完成

## Context

在連續捲動模式下，拖拉視窗寬度 resize 時，因為 fit-to-width 會重算所有圖片高度，clipView 的 scroll position 卻沒跟著調整，導致使用者正在看的圖片位置「滑走」。

## 修改檔案

- `Cee/Views/ContinuousScrollContentView.swift` — 唯一需要修改的檔案

## 方案：Anchor-based Scroll Preservation（Review 修正版）

在 `relayoutSlots()` 前後加入位置保持邏輯：

```swift
private func relayoutSlots() {
    // 1. Capture anchor before relayout
    let scrollView = enclosingScrollView
    let hadLayout = !scaledHeights.isEmpty
    let viewportMidY = scrollView?.contentView.bounds.midY ?? 0
    let anchorIndex = hadLayout ? calculateCurrentIndex(for: viewportMidY) : 0
    let fraction: CGFloat
    if hadLayout {
        let imageOriginY = yOffsets[anchorIndex]
        let imageHeight = scaledHeights[anchorIndex]
        fraction = imageHeight > 0 ? (viewportMidY - imageOriginY) / imageHeight : 0
    } else {
        fraction = 0
    }

    // 2. Relayout
    recalculateLayout()
    for slot in activeSlots {
        slot.frame = frameForImage(at: slot.imageIndex)
    }

    // 3. Restore scroll position
    guard hadLayout, let sv = scrollView, !scaledHeights.isEmpty,
          anchorIndex < yOffsets.count else { return }
    let clipView = sv.contentView
    let newImageOriginY = yOffsets[anchorIndex]
    let newImageHeight = scaledHeights[anchorIndex]
    let newMidY = newImageOriginY + fraction * newImageHeight
    let clipHeight = clipView.bounds.height  // fresh read after relayout
    let targetY = max(0, min(newMidY - clipHeight / 2, frame.height - clipHeight))
    clipView.scroll(to: NSPoint(x: 0, y: targetY))
    sv.reflectScrolledClipView(clipView)
}
```

### Review 修正摘要

1. `clipBounds.height` 在 relayout 後重新讀取（resize 時 clipView 大小也變了）
2. 用 `guard let sv = scrollView` 避免 force unwrap
3. `targetY` clamp 到 `[0, frame.height - clipHeight]` 防止 overscroll
4. 變數命名：`imageTop` → `imageOriginY`（unflipped 座標中是 bottom edge）
5. `hadLayout` guard 跳過初始 configure 路徑
6. 防禦性 `anchorIndex < yOffsets.count` 檢查

## 複用的現有方法

- `calculateCurrentIndex(for:)` — O(log n) binary search
- `yOffsets` / `scaledHeights` — 已有的佈局 cache
- `enclosingScrollView` — NSView 內建屬性

## 效能影響

無。新增 O(log n) binary search + O(1) 算術，相對於已有的 O(n) `recalculateLayout()` 可忽略。

## 驗證方式

1. **手動測試**：開啟多張不同尺寸的圖片 → 啟用連續捲動模式 → 捲到中間某張圖 → 拖拉視窗寬度 → 確認圖片位置不滑動
2. **邊界測試**：
   - 在第一張/最後一張圖時 resize
   - imageSpacing 改變時（也觸發 relayoutSlots）
   - 視窗極窄/極寬時
   - 空資料夾（無圖片）
   - zoom 中 resize（magnification > 1.0）
3. **既有測試**：`xcodebuild test -project Cee.xcodeproj -scheme Cee -destination 'platform=macOS' -only-testing:CeeTests`

## Completion Notes

- **Commit**: `8c3f52c` on `feat/webtoon`
- **額外修正（Review + Simplify）**：
  - Inset-aware clamp（`contentInsets.bottom`/`.top`）取代硬編碼 `[0, frame.height]`
  - 保留水平 pan 位置（`currentX`）避免 zoom 後 resize 甩回左邊
  - `fraction` clamp 到 `[0, 1]` 防止 gap 區域越界
  - 統一命名 `scrollView`（消除 `sv` 混用）
