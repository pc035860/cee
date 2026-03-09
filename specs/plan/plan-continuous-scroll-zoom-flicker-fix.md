# Bug Fix: Continuous Scroll Zoom Flicker + Performance

## Problem

連續捲動模式下 zoom（pinch 或 keyboard）會出現：
1. **黑色閃爍**：可見的圖片 slot 被回收後重建，`prepareForReuse` 清除 `cachedCGImage = nil` 造成瞬間黑色
2. **效能差**：`calculateVisibleRange` 為 O(n) 線性掃描，zoom 時每次 magnification 變化都觸發

## Root Cause

### 閃爍

Zoom 改變 magnification 時，`scrollView.contentView.bounds` 在 document-space 座標下改變（zoom in → 可見區域縮小）。`updateVisibleSlots` 使用這個 bounds 呼叫 `calculateVisibleRange`，導致仍在**螢幕上可見**（因 GPU affine transform 放大）但已超出 **document-space 可見範圍**的 slot 被判定為超出範圍 → 回收 → 重建 → 黑色閃爍。

例：magnification 從 1.0 → 2.0 時，document-space 可見區域高度減半，邊緣的圖片在 document-space 中消失但在螢幕上仍可見。

**關鍵時序問題**：`setMagnification` 會**同步**觸發 `reflectScrolledClipView` → `updateVisibleSlots`，此時呼叫端（`magnify(with:)` 或 `setMagnificationCentered`）尚未設定任何保護 flag。因此 `isZooming` 必須在 `setMagnification` **之前**設定，否則第一次 `updateVisibleSlots` 呼叫就會回收 slot。

### 效能

`calculateVisibleRange`（`ContinuousScrollContentView.swift:227`）使用 `for i in 0..<imageSizes.count` 線性掃描。`yOffsets` 陣列已排序，可用 binary search。此方法被以下路徑高頻呼叫：
- `reflectScrolledClipView` → `updateVisibleSlots` → `manageSlotViews` → `calculateVisibleRange`（每次 scroll/magnify）
- `scrollViewMagnificationDidChange` fast path → `updateVisibleSlots`（每次 magnify gesture event）

## Key Code Locations

| File | Method | Line | Role |
|------|--------|------|------|
| `Cee/Views/ContinuousScrollContentView.swift` | `calculateVisibleRange(for:)` | ~227 | O(n) 線性掃描，需改 O(log n) |
| `Cee/Views/ContinuousScrollContentView.swift` | `manageSlotViews(for:)` | ~280 | 回收 + 建立 slots（閃爍來源）|
| `Cee/Views/ContinuousScrollContentView.swift` | `updateVisibleSlots(for:)` | ~197 | 入口，被 scroll 和 magnify 呼叫 |
| `Cee/Views/ImageSlotView.swift` | `prepareForReuse()` | ~56 | 清除 `cachedCGImage = nil`（黑色來源）|
| `Cee/Controllers/ImageViewController.swift` | `setMagnificationCentered` | ~613 | 鍵盤 zoom 路徑，呼叫 `scrollView.setMagnification` |
| `Cee/Controllers/ImageViewController.swift` | magnify fast path | ~1771 | 連續捲動 pinch zoom delegate callback |
| `Cee/Views/ImageScrollView.swift` | `setMagnificationPreservingInsets` | ~1008 | Pinch/CmdScroll zoom 的 `setMagnification` 包裝 |
| `Cee/Views/ImageScrollView.swift` | `reflectScrolledClipView` | ~1087 | scroll/magnify 時呼叫 `updateVisibleSlots` |

## Existing Data Structures

- `yOffsets: [CGFloat]` — 每張圖片的 Y 座標起始點，**遞減排列**（index 0 = 最大 y = 視覺頂端，index N-1 = 最小 y = 視覺底部）
- `scaledHeights: [CGFloat]` — 每張圖片的 scaled 高度
- `activeSlots: [ImageSlotView]` — 當前活躍的 slot views
- `reusableSlots: [ImageSlotView]` — 回收池
- `bufferCount: Int = 2` — visible 前後各 buffer 2 張

## Fix Strategy

### Fix 1: `calculateVisibleRange` 改 Binary Search ✅

重用現有的 `calculateCurrentIndex`（~412 行，已有 binary search），分別找到包含 `visibleRect.maxY`（頂端）和 `visibleRect.minY`（底端）的圖片索引。

```swift
// yOffsets 是遞減排列：index 0 = top (highest y), index N-1 = bottom (lowest y)
let firstVisible = calculateCurrentIndex(for: visibleRect.maxY)  // 頂端 → 最上方的可見圖片
let lastVisible = calculateCurrentIndex(for: visibleRect.minY)   // 底端 → 最底部的可見圖片
```

### Fix 2: Zoom 時跳過 slot 回收（方案 A）✅

`ContinuousScrollContentView` 加 `isZooming: Bool` 屬性。`manageSlotViews` 在 `isZooming` 時只新增 slot，不回收。Zoom 結束後清除 flag 並執行一次 `updateVisibleSlots` 清理多餘 slot。

**關鍵：`isZooming` 必須在 `setMagnification` 之前設定**，因為 `setMagnification` 會同步觸發 `reflectScrolledClipView` → `updateVisibleSlots`。

三條 zoom 路徑的保護：

| 路徑 | 設定 isZooming=true | 清除 isZooming=false |
|------|-------------------|---------------------|
| Pinch zoom | `ImageScrollView.setMagnificationPreservingInsets` 在 `setMagnification` 前 | `scrollViewMagnificationDidChange` gesture end |
| Cmd+scroll zoom | 同上（共用 `setMagnificationPreservingInsets`） | 同上（共用 delegate callback） |
| 鍵盤 zoom (Cmd+=/-)  | `ImageViewController.setMagnificationCentered` 在 `scrollView.setMagnification` 前 | 同函數 `defer` 區塊 |

### Fix 3: 雙重呼叫（保留不修改）✅

Zoom 時 `reflectScrolledClipView` 和 magnify fast path **都會**呼叫 `updateVisibleSlots`。保留兩處呼叫：
- `reflectScrolledClipView` 處理 scroll 和 magnification 觸發的 bounds 變化
- `scrollViewMagnificationDidChange` 處理 gesture end 後的最終更新

雙重呼叫**無害**：Fix 2 的 `isZooming` guard 確保兩次呼叫都只新增 slot（不回收），且 `isSlotActive(for:)` 防止重複新增。`calculateVisibleRange` 現在是 O(log n)，效能無問題。

## Implementation Order

1. **Fix 1** — `calculateVisibleRange` binary search（獨立，無副作用）
2. **Fix 2** — 三條 zoom 路徑的 `isZooming` 保護（修閃爍）
3. **Fix 3** — 確認保留雙重呼叫，無需修改

## Implementation Status: ✅ Complete

所有修改已完成並通過 build 驗證。

### 修改的檔案

| File | Change |
|------|--------|
| `ContinuousScrollContentView.swift` | `calculateVisibleRange` 改 binary search；新增 `isZooming` 屬性；`manageSlotViews` 加 `isZooming` guard |
| `ImageScrollView.swift` | `setMagnificationPreservingInsets` 在 `setMagnification` 前設 `csView.isZooming = true` |
| `ImageViewController.swift` | `setMagnificationCentered` 加 `csView.isZooming` 保護 + defer 清理；`scrollViewMagnificationDidChange` 加 gesture end 清理 |

## Verification

```bash
xcodebuild -project Cee.xcodeproj -scheme Cee -configuration Debug build
```

### Manual Testing
1. **Pinch zoom in/out**：不應出現黑色閃爍
2. **快速連續 pinch**：效能流暢，無卡頓
3. **Cmd+=/-**：不閃爍
4. **Cmd+scroll zoom**：不閃爍
5. **Zoom 後捲動**：slot recycling 正常
6. **Zoom 結束後**：不需要的 slot 被正確清理（無 memory leak）
7. **非連續模式**：zoom 行為不受影響（regression check）
8. **極端 zoom out**：大量圖片同時可見時效能穩定

## Known Risks & Mitigations

1. **activeSlots 暫時膨脹**：zoom 中回收被跳過，`activeSlots` 可能暫時增長。Zoom 結束後的 cleanup `updateVisibleSlots` 會正確清理。若極端情況需要，可加硬上限（如 `activeSlots.count > visibleRange.count * 3`）。
2. **isZooming 卡住**：若 `scrollViewMagnificationDidChange` 未收到 `.ended`/`.cancelled`，`isZooming` 可能殘留為 `true`。目前風險極低（AppKit 保證 gesture phase 完整），鍵盤路徑用 `defer` 確保清除。
