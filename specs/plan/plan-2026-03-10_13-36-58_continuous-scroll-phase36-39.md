# Plan: Continuous Scroll Phase 3.6-3.9

## Context

Continuous scroll (webtoon mode) is implemented through Phase 3.5. The remaining 4 phases are UX polish — all independent, no cross-dependencies. Total: ~115-180 lines.

## Implementation Order

3.9 → 3.7 → 3.6 → 3.8 (easiest first, highest risk last)

---

## Phase 3.9: Fitting UI Adaptation (~15-25 lines, Low)

**Why**: Fitting options (Shrink H/V, Stretch H/V) are meaningless in continuous mode (fit-to-width only). Users see confusing enabled menu items that do nothing.

**File**: `Cee/Controllers/ImageViewController.swift`

### Changes

1. **`validateMenuItem`** (line 1512): Add `let isContinuous = settings.continuousScrollEnabled`, then for each fitting case return `!isContinuous`:
   - `toggleAlwaysFit` (1518)
   - `toggleShrinkH` (1520)
   - `toggleShrinkV` (1522)
   - `toggleStretchH` (1524)
   - `toggleStretchV` (1526)
   - `toggleResizeAutomatically` (1556) — continuous mode uses CADisplayLink resize
   - `toggleDualPage` (1568) — mutual exclusion with continuous
   - `togglePageOffset` (1571) — depends on dual page
   - `toggleReadingDirection` (1574) — depends on dual page
   - `toggleDuoPageRTLNavigation` (1581) — depends on dual page
   - `toggleSinglePageRTLNavigation` (1584) — irrelevant in continuous mode
   - `toggleClickToTurnPage` (1590) — nonsensical in continuous scroll

2. **`applyFitting`** (line 578): Add defensive early return:
   ```swift
   guard !settings.continuousScrollEnabled else { return }
   ```

### Keep enabled
- `fitOnScreen` — resets zoom to 1.0
- `actualSize` — already redirects to fitOnScreen (Phase 3.3)
- Scaling quality, show pixels, float on top, status bar, arrow nav settings

### Edge case
- Switching back from continuous mode auto-re-enables items (validateMenuItem recalculates each time)
- Set `menuItem.state` BEFORE returning false so checkmark state is correct when re-enabled

---

## Phase 3.7: Quick Grid Integration (~10-15 lines, Low)

**Why**: Grid selection currently calls `loadCurrentImage` which is unnecessary — continuous mode already has all images in the scroll view. Should just scroll to the selected image.

**File**: `Cee/Controllers/ImageViewController.swift`

### Changes

**`quickGridView(_:didSelectItemAt:)`** (line 2087): Add continuous mode branch:

```swift
func quickGridView(_ view: QuickGridView, didSelectItemAt index: Int) {
    dismissQuickGrid()
    guard let folder else { return }
    folder.currentIndex = index

    if settings.continuousScrollEnabled {
        scrollToCurrentImageInContinuousMode()  // already exists (line 1311)
        updateWindowTitle()
        updateStatusBar()  // fallback in case scroll position didn't change
        return
    }

    if settings.dualPageEnabled { folder.syncSpreadIndex() }
    loadCurrentImage(initialScroll: .top)
    updateWindowTitle()
}
```

### Reused
- `scrollToCurrentImageInContinuousMode()` (line 1311) — calculates frame, centers image in viewport
- `handleContinuousScrollImageChanged` auto-triggers via `updateVisibleSlots`, updates status bar

---

## Phase 3.6: Keyboard Navigation (~40-60 lines, Low)

**Why**: In continuous mode, arrow keys should smooth-scroll (not page-turn), Space/PageDown should only scroll (never navigate to next image), Home/End should go to document top/bottom.

### Files

#### 1. `Cee/Views/ImageScrollView.swift` — `keyDown` (line 702)

Add `continuousScrollEnabled` early branch before existing `switch`:

```swift
if continuousScrollEnabled {
    switch event.keyCode {
    case 124, 123:  // Left/Right Arrow
        if overflow.horizontal {  // only when zoomed past fit-to-width
            event.keyCode == 124 ? panRight() : panLeft()
        }
    case 125: panDown()   // Down — smooth scroll, no edge-press navigate
    case 126: panUp()     // Up — smooth scroll, no edge-press navigate
    case 49, 121:         // Space / PageDown
        scrollDelegate?.scrollViewRequestPageDown(self)
    case 116:             // PageUp
        scrollDelegate?.scrollViewRequestPageUp(self)
    case 115:             // Home → delegate (repurposed for continuous)
        scrollDelegate?.scrollViewRequestFirstImage(self)
    case 119:             // End → delegate (repurposed for continuous)
        scrollDelegate?.scrollViewRequestLastImage(self)
    case 5 where event.modifierFlags.intersection(.deviceIndependentFlagsMask) == []:
        scrollDelegate?.scrollViewRequestToggleQuickGrid(self)
    case 53:
        if window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil) }
        else { super.keyDown(with: event) }
    default: super.keyDown(with: event)
    }
    return
}
```

Key differences from normal mode:
- Up/Down: always `panUp()`/`panDown()`, **never** `handleEdgePress` or navigate
- Left/Right: no-op (or pan if zoomed)
- Space/PageDown/PageUp: delegate to VC (which now has continuous guard)
- Home/End: delegate to VC (repurposed)

#### 2. `Cee/Controllers/ImageViewController.swift`

**`scrollPageDownOrNext()`** (line 942): Add continuous mode guard — scroll only, never navigate:

```swift
if settings.continuousScrollEnabled {
    guard let range = scrollRange(for: scrollView.contentInsets) else { return }
    let newY = max(currentMinY - visibleHeight, range.minY)
    clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: newY))
    scrollView.reflectScrolledClipView(clipView)
    return
}
```

**`scrollPageUpOrPrev()`** (line 957): Same pattern — scroll only, never navigate:

```swift
if settings.continuousScrollEnabled {
    guard let range = scrollRange(for: scrollView.contentInsets) else { return }
    let newY = min(currentMinY + visibleHeight, range.maxY)
    clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: newY))
    scrollView.reflectScrolledClipView(clipView)
    return
}
```

**`scrollViewRequestFirstImage`** (line 1845): Repurpose for Home key:

```swift
func scrollViewRequestFirstImage(_ scrollView: ImageScrollView) {
    if settings.continuousScrollEnabled {
        // Home: scroll to visual top (highest Y in unflipped coords)
        let clipView = self.scrollView.contentView
        guard let range = scrollRange(for: self.scrollView.contentInsets) else { return }
        clipView.scroll(to: NSPoint(x: 0, y: range.maxY))
        self.scrollView.reflectScrolledClipView(clipView)
        return
    }
    goToFirstImage()
}
```

**`scrollViewRequestLastImage`** (line 1846): Repurpose for End key:

```swift
func scrollViewRequestLastImage(_ scrollView: ImageScrollView) {
    if settings.continuousScrollEnabled {
        // End: scroll to visual bottom (lowest Y in unflipped coords)
        let clipView = self.scrollView.contentView
        guard let range = scrollRange(for: self.scrollView.contentInsets) else { return }
        clipView.scroll(to: NSPoint(x: 0, y: range.minY))
        self.scrollView.reflectScrolledClipView(clipView)
        return
    }
    goToLastImage()
}
```

### Edge cases
- **Option+Arrow**: Ignored in continuous mode (MVP). `panUp()`/`panDown()` use fixed step.
- **Continuous + zoom (horizontal overflow)**: Left/Right arrows still pan horizontally — correct behavior.
- **`edgePressCount`**: Not modified in continuous branch, remains at whatever it was — harmless.

---

## Phase 3.8: Image Gap Setting (~50-80 lines, Low-Medium)

**Why**: Allow adjustable spacing between images (0px default, webtoon style). The layout math already accounts for `imageSpacing` — it's just hardcoded to 0.

### Files

#### 1. `Cee/Views/ContinuousScrollContentView.swift` — line 37

Change `private let imageSpacing: CGFloat = 0` to `var` with `didSet`, matching `containerWidth` pattern (line 25-33):

```swift
var imageSpacing: CGFloat = 0 {
    didSet {
        guard oldValue != imageSpacing else { return }
        recalculateLayout()
        for slot in activeSlots {
            slot.frame = frameForImage(at: slot.imageIndex)
        }
    }
}
```

#### 2. `Cee/Models/ViewerSettings.swift` — near line 88

Add setting:
```swift
var continuousScrollGap: CGFloat = 0
```

Add decode in `init(from:)` (backward-compatible with `?? default`):
```swift
continuousScrollGap = (try? c.decode(CGFloat.self, forKey: .continuousScrollGap)) ?? d.continuousScrollGap
```

#### 3. `Cee/Controllers/ImageViewController.swift`

**`configureContinuousScrollView()`** (line 1287): After `contentView.containerWidth = ...`, add:
```swift
contentView.imageSpacing = settings.continuousScrollGap
```

**New action methods** (4 preset values):
```swift
@objc func setContinuousGap0(_ sender: Any?) { setContinuousGap(0) }
@objc func setContinuousGap2(_ sender: Any?) { setContinuousGap(2) }
@objc func setContinuousGap4(_ sender: Any?) { setContinuousGap(4) }
@objc func setContinuousGap8(_ sender: Any?) { setContinuousGap(8) }

private func setContinuousGap(_ gap: CGFloat) {
    settings.continuousScrollGap = gap
    settings.save()
    guard let contentView = continuousScrollContentView else { return }
    contentView.imageSpacing = gap       // didSet → recalculateLayout + update frames
    scrollToCurrentImageInContinuousMode()  // preserve scroll position
}
```

**`validateMenuItem`**: Add cases for gap items — `menuItem.state` based on current gap, return `settings.continuousScrollEnabled`.

#### 4. `Cee/App/AppDelegate.swift` — menu setup

Add "Image Gap" submenu after `toggleContinuousScroll` item:
- None (0px) ✓
- Small (2px)
- Medium (4px)
- Large (8px)

### Scroll position preservation
- `setContinuousGap` saves `folder.currentIndex` (unchanged by gap change)
- After `imageSpacing` didSet recalculates layout, call `scrollToCurrentImageInContinuousMode()` to re-center current image
- `updateVisibleSlots` will be triggered by `reflectScrolledClipView`, updating slots naturally

### Edge case
- Gap items only enabled when `continuousScrollEnabled` (return false otherwise)
- CGFloat comparison: integer presets (0, 2, 4, 8) avoid floating point issues

---

## Verification

### Build
```bash
xcodegen generate && xcodebuild -project Cee.xcodeproj -scheme Cee -configuration Debug build
```

### Manual Testing Checklist

**Phase 3.9**:
- [ ] Open image → enter continuous mode → check View menu: Shrink/Stretch/Always Fit/Resize Auto/Dual Page grayed out
- [ ] Exit continuous mode → all items re-enabled
- [ ] Fit on Screen / Actual Size still work in continuous mode

**Phase 3.7**:
- [ ] In continuous mode, press G to open grid → click an image → grid closes, scrolls to selected image
- [ ] Verify status bar shows correct index after grid selection

**Phase 3.6**:
- [ ] In continuous mode: Up/Down arrows smooth-scroll, never trigger page navigation
- [ ] Space/PageDown scrolls one viewport down, never navigates to next image
- [ ] PageUp scrolls one viewport up, never navigates to previous image
- [ ] Home scrolls to document top (first image visible)
- [ ] End scrolls to document bottom (last image visible)
- [ ] Left/Right arrows: no-op at 1x zoom, pan when zoomed in
- [ ] In normal mode: all keyboard behavior unchanged

**Phase 3.8**:
- [ ] In continuous mode → Navigation menu → Image Gap submenu visible
- [ ] Select each preset (0/2/4/8) → gap visually changes between images
- [ ] Current image stays centered after gap change
- [ ] Gap setting persists after restart
- [ ] Gap submenu grayed out when not in continuous mode

### Unit Tests
```bash
xcodebuild test -project Cee.xcodeproj -scheme Cee -destination 'platform=macOS' -only-testing:CeeTests
```

---

## Completion Status

All 4 phases implemented and verified on 2026-03-10.

| Phase | Status | Commit | Notes |
|-------|--------|--------|-------|
| 3.9 | ✅ Done | `7e1cd2b` | Also disables `toggleSinglePageRTLNavigation` and `toggleClickToTurnPage` |
| 3.7 | ✅ Done | `7e1cd2b` | Added fallback `updateStatusBar()` for same-index selection |
| 3.6 | ✅ Done | `7e1cd2b` | Uses `scrollRange(for:)` for inset-aware scroll bounds |
| 3.8 | ✅ Done | `7e1cd2b` | Gap decode clamped to >= 0; units are points (not pixels) |

Review fixes: `7fd84f6` — Home/End preserves horizontal scroll position, localization px→pt
Simplify: `9821328` — Extract `relayoutSlots()`, early return on same gap, lazy `viewportOverflow`
