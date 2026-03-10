# Plan: Continuous Scroll Zoom Support ✅ COMPLETED

## Context

連續捲動模式 (Phase 3.1-3.2) 的佈局完全基於 fit-to-width（`containerWidth = scrollView.bounds.width`），設計時假定 `magnification = 1.0`。但 zoom 事件（pinch、Cmd+scroll）完全沒被攔截，導致：

1. **圖片與視窗不符**：AppKit 的 affine transform 改變了視覺尺寸，但佈局不響應 → magnification > 1.0 圖片溢出、< 1.0 出現黑邊
2. **縮放非常卡**：zoom 觸發了不必要的 window resize 嘗試、recenterViewport、schedulePostMagnifyCentering 等整條 single-page code path

**解決方案**：利用 NSScrollView 原生 magnification（GPU affine transform），magnification=1.0 = fit-to-width，zoom in 允許水平捲動，zoom out clamp 在 1.0。佈局邏輯（`updateVisibleSlots`、`calculateVisibleRange`、binary search）已使用 document-space 座標，對 magnification 變化是透明的，**不需修改**。

---

## Changes

### 1. `Cee/Views/ImageScrollView.swift` — `effectiveMinMagnification()` (L1040)

在方法開頭加入連續捲動 early return：

```swift
if continuousScrollEnabled { return 1.0 }
```

此變更自動傳播到 `magnify(with:)` (L993)、`handleCmdScrollZoom()` (L921) 的 clamping。

### 2. `Cee/Controllers/ImageViewController.swift` — `scrollViewMagnificationDidChange()` (L1710)

在共用操作後（L1733 `updateScalingQuality()` 之後）插入連續捲動 fast path：

```swift
// 連續捲動模式：GPU affine transform only, skip window resize / recenter
if settings.continuousScrollEnabled {
    applyCenteringInsetsIfNeeded(reason: "magnify.continuous")
    // 保守呼叫 updateVisibleSlots — magnification 改變後 visible bounds 在 document space 改變
    if let csView = continuousScrollContentView {
        csView.updateVisibleSlots(for: scrollView.contentView.bounds)
    }
    let isFitting = !settings.isManualZoom && settings.alwaysFitOnOpen
    statusBarView.updateZoom(magnification, isFitting: isFitting)

    if gesturePhase.isEmpty || gesturePhase.contains(.ended) || gesturePhase.contains(.cancelled) {
        activeMagnifyAnchor = nil
        isZooming = false
    }
    return
}
```

**保留**：`isZooming`、anchor lock、`settings.magnification` 存檔、`updateScalingQuality()`
**跳過**：`recenterViewport()`、`resizeWindowToFitZoomedImagePreservingCenter()`、`scheduleResizeToFitAfterZoom()`、`schedulePostMagnifyCentering()`

### 3. `Cee/Controllers/ImageViewController.swift` — Zoom actions

**`zoomIn()`** (L976)、**`zoomOut()`** (L988)：

Guard `scheduleResizeToFitAfterZoom()` 呼叫：
```swift
if !settings.continuousScrollEnabled {
    scheduleResizeToFitAfterZoom(magnification: scrollView.magnification)
}
```

### 3.5. `Cee/Controllers/ImageViewController.swift` — `actualSize()` continuous scroll redirect

在連續捲動模式下，`actualSize` 語意上等同於 `fitOnScreen`（magnification 1.0 = fit-to-width），因此直接 redirect：

```swift
@objc func actualSize(_ sender: Any? = nil) {
    if settings.continuousScrollEnabled {
        fitOnScreen(sender)
        return
    }
    // ... existing code
}
```

同時保留原有的 `scheduleResizeToFitAfterZoom` guard（僅對非連續模式生效）。

### 4. `Cee/Controllers/ImageViewController.swift` — `fitOnScreen()` (L991)

加入連續捲動分支（在 `settings.isManualZoom = false` 之後）：

```swift
if settings.continuousScrollEnabled {
    setMagnificationCentered(1.0)
    updateScalingQuality()
    applyCenteringInsetsIfNeeded(reason: "fitOnScreen.continuous")
    statusBarView.updateZoom(scrollView.magnification, isFitting: true)
    settings.save()
    return
}
```

### 5. `Cee/Controllers/ImageViewController.swift` — `toggleContinuousScroll()` (L1235)

進入/離開連續模式時重設 magnification：

```swift
if settings.continuousScrollEnabled {
    scrollView.magnification = 1.0  // reset to fit-to-width
    configureContinuousScrollView()
} else {
    scrollView.magnification = 1.0  // reset before switching back to single/dual page
    // ... existing teardown code
}
```

離開連續模式時也需要 reset，避免高倍 magnification 值影響 `applyFitting` 的計算。

### 6. (Optional) Scaling quality for ImageSlotView

**`ImageViewController.updateScalingQuality()`** (L273)：加入連續捲動分支

```swift
if settings.continuousScrollEnabled {
    continuousScrollContentView?.setScalingFilters(magnification: magFilter, minification: minFilter)
}
```

**`ContinuousScrollContentView`**：新增 `setScalingFilters()` 方法 + 儲存 filter 供新 slot 套用

---

## Files Modified

| File | Changes |
|------|---------|
| `Cee/Views/ImageScrollView.swift` | `effectiveMinMagnification()` 加 1 行 early return |
| `Cee/Controllers/ImageViewController.swift` | `scrollViewMagnificationDidChange` fast path、`zoomIn/Out/actualSize` guard、`fitOnScreen` 分支、`toggleContinuousScroll` reset |
| `Cee/Views/ContinuousScrollContentView.swift` | (Optional) `setScalingFilters()` 方法 |

## Files NOT Modified

| File | Why |
|------|-----|
| `ContinuousScrollContentView.swift` 佈局邏輯 | document-space 座標對 magnification 透明 |
| `ImageWindowController.swift` | `animateResize()` 已有連續捲動 early return |
| `ImageSlotView.swift` | layer rendering 不受影響 |

---

## Zoom Behavior

| Action | Continuous Scroll |
|--------|-------------------|
| Pinch in | magnification > 1.0, 可水平捲動 |
| Pinch out | clamp at 1.0 (fit-to-width) |
| Cmd+= / Cmd+- | 步進 ±0.25, clamp 1.0~10.0, 不 resize window |
| Cmd+0 (fit) | magnification → 1.0 |
| Cmd+1 (actual) | redirect 到 fitOnScreen (magnification → 1.0) |

---

## Implementation Order

1. `effectiveMinMagnification()` — 基礎 clamping
2. `scrollViewMagnificationDidChange()` — 核心 fast path（最大效能影響）+ updateVisibleSlots
3. `zoomIn/Out` guard + `actualSize` continuous redirect — keyboard zoom
4. `fitOnScreen` — continuous branch + status bar update
5. `toggleContinuousScroll` — 進入/離開模式 magnification reset
6. scaling quality — optional polish

---

## Verification

```bash
xcodebuild -project Cee.xcodeproj -scheme Cee -configuration Debug build
```

### Manual Testing
1. **Pinch zoom in**：連續捲動中 pinch → 60fps smooth、圖片放大、可水平捲動
2. **Pinch zoom out**：clamp 在 1.0、不會出現黑邊
3. **Cmd+=/-**：magnification 變化、視窗不 resize
4. **Cmd+0**：reset 到 fit-to-width
5. **Cmd+1 (actual size)**：行為與 Cmd+0 相同（redirect 到 fitOnScreen）
6. **模式切換 (進入)**：zoomed 到 3x → toggle continuous scroll on → magnification 重設為 1.0
7. **模式切換 (離開)**：連續模式 zoom 到 3x → toggle continuous scroll off → magnification 重設為 1.0，applyFitting 正確
8. **垂直捲動**：zoomed 狀態下捲動 → slot 正常 recycle
9. **水平捲動**：zoomed > 1.0 → 可水平 pan
10. **Status bar**：zoom 時 status bar 的 zoom indicator 正確更新
11. **Strip 邊界 overscroll**：在最頂端/最底端連續 overscroll → 不應觸發意外行為

### Known Limitations
- 高倍 zoom 時圖片會模糊（GPU 放大固定解析度圖片）→ 留待 Phase 3.5 subsample 優化
- **Zoom 閃爍 + 效能差**：slot recycling 使用 document-space bounds，zoom 時仍可見的 slot 被誤回收 → Phase 3.3.1 修復
- `calculateVisibleRange` 為 O(n) 線性掃描，zoom 時高頻呼叫成為瓶頸 → Phase 3.3.1 改 binary search

---

## Completion Notes

- **Completed**: 2026-03-10
- **Commits**: `5458afc`, `1cad1bf`, `aa850be`
- **All 6 steps implemented** including optional Step 6 (scaling quality)
- **Review findings fixed**: `configureContinuousScrollView` sync, `toggleContinuousScroll` persistence ordering, `updateScalingQuality` branch isolation
- **Simplify applied**: Dead `isFitting` computation removed, inactive view update eliminated
