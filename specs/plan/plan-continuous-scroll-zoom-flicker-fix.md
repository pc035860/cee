# Bug Fix: Continuous Scroll Zoom Flicker + Performance

## Problem

連續捲動模式下 zoom（pinch 或 keyboard）會出現：
1. **黑色閃爍**：可見的圖片 slot 被回收後重建，`prepareForReuse` 清除 `cachedCGImage = nil` 造成瞬間黑色
2. **效能差**：`calculateVisibleRange` 為 O(n) 線性掃描，zoom 時每次 magnification 變化都觸發

## Root Cause

### 閃爍

Zoom 改變 magnification 時，`scrollView.contentView.bounds` 在 document-space 座標下改變（zoom in → 可見區域縮小）。`updateVisibleSlots` 使用這個 bounds 呼叫 `calculateVisibleRange`，導致仍在**螢幕上可見**（因 GPU affine transform 放大）但已超出 **document-space 可見範圍**的 slot 被判定為超出範圍 → 回收 → 重建 → 黑色閃爍。

例：magnification 從 1.0 → 2.0 時，document-space 可見區域高度減半，邊緣的圖片在 document-space 中消失但在螢幕上仍可見。

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
| `Cee/Controllers/ImageViewController.swift` | magnify fast path | ~1771 | 呼叫 `updateVisibleSlots` |
| `Cee/Views/ImageScrollView.swift` | `reflectScrolledClipView` | ~1087 | scroll 時也呼叫 `updateVisibleSlots` |

## Existing Data Structures

- `yOffsets: [CGFloat]` — 每張圖片的 Y 座標起始點（從底部累積，已排序遞增）
- `scaledHeights: [CGFloat]` — 每張圖片的 scaled 高度
- `activeSlots: [ImageSlotView]` — 當前活躍的 slot views
- `reusableSlots: [ImageSlotView]` — 回收池
- `bufferCount: Int = 2` — visible 前後各 buffer 2 張

## Fix Strategy

### Fix 1: `calculateVisibleRange` 改 Binary Search

`yOffsets` 是遞增排序陣列。用 binary search 找 firstVisible 和 lastVisible。

注意：`calculateCurrentIndex`（~384 行）已經使用 binary search 模式，可參考。

```swift
// 找 firstVisible: 最後一個 yOffset + height > visibleBottom 的 index（從小到大）
// 找 lastVisible: 第一個 yOffset < visibleTop 的 index（從大到小）
// 兩者都可用 binary search on yOffsets
```

### Fix 2: Zoom 時擴大 buffer 或暫停回收

兩個方向，選一個：

**方案 A — Zoom 時跳過 slot 回收**（簡單）：
- `ContinuousScrollContentView` 加一個 `isZooming: Bool` 屬性
- `manageSlotViews` 中：如果 `isZooming`，只新增 slot，不回收現有 slot
- Zoom 結束後（`isZooming = false`）再做一次完整的 `updateVisibleSlots` 清理

**方案 B — 用 screen-space 計算可見範圍**（精確）：
- 在 `calculateVisibleRange` 中考慮 magnification：實際可見區域 = document-space bounds 擴展 magnification 倍
- 但這需要知道 magnification 值，增加耦合

推薦方案 A，因為簡單且 zoom 結束後會自然清理。

### Fix 3: 雙重呼叫問題

Zoom 時 `reflectScrolledClipView` 和 magnify fast path **都會**呼叫 `updateVisibleSlots`。可以在 magnify fast path 中移除 `updateVisibleSlots` 呼叫，因為 `reflectScrolledClipView` 在 magnification 改變時已會被 AppKit 觸發。

但需先驗證：AppKit 在 `setMagnification` 後是否一定觸發 `reflectScrolledClipView`。如果不確定，保留兩處呼叫但利用 Fix 2 的 `isZooming` 保護。

## Implementation Order

1. **Fix 1** — `calculateVisibleRange` binary search（獨立，無副作用）
2. **Fix 2** — Zoom slot 回收保護（修閃爍）
3. **Fix 3** — 評估並移除雙重呼叫（optional，依 Fix 2 結果決定）

## Verification

```bash
xcodebuild -project Cee.xcodeproj -scheme Cee -configuration Debug build
```

### Manual Testing
1. **Pinch zoom in/out**：不應出現黑色閃爍
2. **快速連續 pinch**：效能流暢，無卡頓
3. **Cmd+=/-**：不閃爍
4. **Zoom 後捲動**：slot recycling 正常
5. **Zoom 結束後**：不需要的 slot 被正確清理（無 memory leak）
6. **非連續模式**：zoom 行為不受影響（regression check）
