# Phase 4: Window Behavior & Fullscreen

## Goal

實現視窗行為選項（Resize Auto、Float on Top、視窗大小記憶）和全螢幕模式。完成後所有 FR-019 ~ FR-025 功能就位。

## Prerequisites

- [ ] Phase 3 completed — Menu system and settings persistence working

## Tasks

### 4.1 Window Size Memory (FR-025)

- [ ] In `ImageWindowController`: add `NSWindow.didResizeNotification` observer
- [ ] On resize: save `window.contentView.bounds.size` to `ViewerSettings`
- [ ] On first launch: use saved size (or default 800x600)
- [ ] Throttle save: use `DispatchWorkItem` with 0.5s delay to avoid excessive writes

### 4.2 Resize Window Automatically (FR-023)

- [ ] In `ImageWindowController`: `resizeToFitImage(_ size: NSSize)`
  - Clamp to screen visible frame
  - Center window after resize
- [ ] In `ImageViewController.loadCurrentImage()`:
  - After image loads, if `settings.resizeWindowAutomatically` → call `resizeToFitImage`
- [ ] Connect to View menu toggle
- [ ] Toggle state saved in ViewerSettings

### 4.3 Float on Top (FR-024)

- [ ] `toggleFloatOnTop()` in ImageViewController
  - `window.level = .floating` or `.normal`
  - Save to ViewerSettings
- [ ] Apply on window creation if `settings.floatOnTop == true`
- [ ] Connect to View menu toggle

### 4.4 Fullscreen Mode (FR-019 ~ FR-021)

- [ ] `Cmd+F`: `window.toggleFullScreen(nil)`
  - Uses macOS native fullscreen API
  - Hides title bar and Dock automatically

- [ ] `Esc`: exit fullscreen only
  ```swift
  case 53: // Esc (kVK_Escape)
      if window.styleMask.contains(.fullScreen) {
          window.toggleFullScreen(nil)
      }
  ```

- [ ] Verify all operations work in fullscreen (FR-020):
  - Pinch zoom
  - Scroll navigation
  - Keyboard shortcuts
  - Menu bar (accessible on hover)

### 4.5 Menu Items Activation

- [ ] Enable the Phase 4 menu items that were placeholders in Phase 3:
  - View → Enter Full Screen (`Cmd+F`)
  - View → Float on Top
  - View → Resize Window Automatically
- [ ] Update `validateMenuItem` for these items

## Verification

### Fullscreen Tests
- [ ] `Cmd+F` enters fullscreen (title bar and Dock hidden)
- [ ] `Esc` exits fullscreen
- [ ] `Cmd+F` again exits fullscreen (toggle behavior)
- [ ] All keyboard shortcuts work in fullscreen (→←, Space, Cmd+=/-, etc.)
- [ ] Pinch zoom works in fullscreen
- [ ] Scroll-to-page works in fullscreen
- [ ] Menu bar appears on mouse hover at top edge

### Window Behavior Tests
- [ ] Float on Top: enable → window stays above other apps
- [ ] Float on Top: disable → window behaves normally
- [ ] Resize Window Automatically: enable → open large image → window grows
- [ ] Resize Window Automatically: enable → open small image → window shrinks
- [ ] Resize Window Automatically: window clamped to screen bounds
- [ ] Window Size Memory: resize window → quit → relaunch → same size
- [ ] Float on Top persists across restart
- [ ] Resize Window Automatically persists across restart

## Files Modified

| File | Change |
|------|--------|
| `Cee/Controllers/ImageWindowController.swift` | Resize observer, resizeToFitImage, window size save/restore |
| `Cee/Controllers/ImageViewController.swift` | Fullscreen toggle, Float on Top, Resize Auto integration |
| `Cee/App/AppDelegate.swift` | Enable Phase 4 menu items |

## Notes

- **Fullscreen + magnification**: macOS native fullscreen preserves NSScrollView state. No special handling needed for magnification during fullscreen transition.
- **Resize save throttling**: Without throttling, `didResizeNotification` fires for every pixel during drag resize, causing excessive UserDefaults writes. A 0.5s `DispatchWorkItem` delay solves this.
- **Float on Top persistence**: Must apply `window.level = .floating` in `ImageWindowController.open(with:)` if `settings.floatOnTop` is true, before `showWindow`.
