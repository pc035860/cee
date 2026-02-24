# Phase 2: Navigation & Scroll-to-Page

## Goal

實現資料夾內圖片導航：鍵盤翻頁、捲動到底自動翻頁、Natural Scrolling 支援。完成後使用者可以流暢地瀏覽整個資料夾的圖片。

## Prerequisites

- [ ] Phase 1 completed — App can open and display a single image

## Tasks

### 2.1 ImageScrollView — Scroll Edge Detection

- [ ] Add `ImageScrollViewDelegate` protocol
  ```swift
  protocol ImageScrollViewDelegate: AnyObject {
      func scrollViewDidReachBottom(_ scrollView: ImageScrollView)
      func scrollViewDidReachTop(_ scrollView: ImageScrollView)
      func scrollViewMagnificationDidChange(_ scrollView: ImageScrollView, magnification: CGFloat)
  }
  ```

- [ ] Add `scrollDelegate` weak property

- [ ] Add `boundsDidChange` observer
  - Monitor `NSView.boundsDidChangeNotification` on `contentView`
  - Track `isAtBottom` / `isAtTop` flags
  - macOS coordinate: bottom = `clipBounds.maxY >= docFrame.height - threshold`

- [ ] Override `scrollWheel(with:)` for page-turn detection
  - Detect: was at edge BEFORE scroll + continued scrolling in same direction
  - **Natural Scrolling handling**:
    - `event.isDirectionInvertedFromDevice == true` → deltaY already inverted by system
    - User "swipe down" intent = `deltaY < 0` (natural) or `deltaY > 0` (traditional)
    - Use `isNatural` flag to unify direction interpretation

- [ ] Override `magnify(with:)` — notify delegate of magnification changes

### 2.2 ImageViewController — Navigation Methods

- [ ] `goToNextImage()` → `folder.goNext()` + load + scrollToTop + updateTitle
- [ ] `goToPreviousImage()` → `folder.goPrevious()` + load + scrollToBottom + updateTitle
- [ ] `goToFirstImage()` → `folder.currentIndex = 0` + load + scrollToTop + updateTitle
- [ ] `goToLastImage()` → `folder.currentIndex = count-1` + load + scrollToTop + updateTitle

### 2.3 ImageViewController — Keyboard Shortcuts

- [ ] Override `keyDown(with:)` for navigation keys (no modifier):

| keyCode | Key | Action |
|---------|-----|--------|
| 124 | `→` (kVK_RightArrow) | Next image |
| 123 | `←` (kVK_LeftArrow) | Previous image |
| 49 | `Space` | Scroll page down, or next image if at bottom |
| 115 | `Home` (kVK_Home) | First image |
| 119 | `End` (kVK_End) | Last image |
| 121 | `PageDown` (kVK_PageDown) | Next image |
| 116 | `PageUp` (kVK_PageUp) | Previous image |
| 53 | `Esc` (kVK_Escape) | Exit fullscreen (placeholder, full impl Phase 4) |

- [ ] Implement `scrollPageDownOrNext()`
  - If not at bottom: scroll down one viewport height
  - If at bottom: go to next image

### 2.4 ImageScrollViewDelegate Implementation

- [ ] `ImageViewController` conforms to `ImageScrollViewDelegate`
- [ ] `scrollViewDidReachBottom` → `goToNextImage()`
- [ ] `scrollViewDidReachTop` → `goToPreviousImage()`
- [ ] `scrollViewMagnificationDidChange` → (placeholder, full impl in Phase 3)

### 2.5 Cache Updates on Navigation

- [ ] Call `loader.updateCache(for: folder)` after each navigation
- [ ] Verify cache eviction: only ±2 images kept in memory

### 2.6 Window Title Updates

- [ ] `updateWindowTitle()` calls `ImageWindowController.updateTitle(folder:)`
- [ ] Format: `"filename.jpg (3/42)"`
- [ ] Update on every navigation action

## Verification

### Manual Tests
- [ ] `→` / `←` navigate between images
- [ ] `PageDown` / `PageUp` navigate between images
- [ ] `Home` goes to first image, `End` goes to last image
- [ ] `Space` scrolls down one page; at bottom → next image
- [ ] Scroll (trackpad) to bottom → continue scroll → next image
- [ ] Scroll to top → continue scroll → previous image
- [ ] After next image: view starts at top
- [ ] After previous image: view starts at bottom
- [ ] Natural Scrolling ON: swipe down = content goes up, edge-scroll triggers correctly
- [ ] Natural Scrolling OFF: same behavior (reversed delta handling)
- [ ] Window title updates on every navigation
- [ ] No image flickering during rapid navigation (requestID guard)
- [ ] First image: previous does nothing; Last image: next does nothing

### Performance
- [ ] Rapid arrow key presses: no crash, final image displays correctly
- [ ] Memory: only ~5 images in cache at any time (current ±2)

## Files Modified

| File | Change |
|------|--------|
| `Cee/Views/ImageScrollView.swift` | Add delegate, edge detection, scrollWheel override |
| `Cee/Controllers/ImageViewController.swift` | Add navigation, keyboard, delegate conformance |

## Notes

- **keyCode vs charactersIgnoringModifiers**: Arrow keys and function keys have no character representation; must use `event.keyCode`. SPEC provides correct keyCode values (verified in review).
- **Scroll debounce**: The `wasAtBottom + intentDown` pattern provides natural debounce. After page turn, `scrollToTop()` resets `isAtBottom`, preventing rapid re-trigger.
- **acceptsFirstResponder**: `ImageViewController` must return `true` from `acceptsFirstResponder` to receive `keyDown` events. Also ensure the view controller's view becomes first responder on appear.
