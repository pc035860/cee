# Phase 3: Menu System & Settings Persistence

## Goal

建立完整的選單系統（View / Go menu）和設定持久化。完成後所有 Fitting Options、Scaling Quality、Zoom 模式都可透過選單或快捷鍵操作，且設定跨重啟保存。

## Prerequisites

- [ ] Phase 2 completed — Navigation and keyboard shortcuts working

## Tasks

### 3.1 ViewerSettings — Settings Persistence

- [ ] Create `Cee/Models/ViewerSettings.swift`
  - `Codable` class with `UserDefaults` storage
  - Properties:
    - `magnification: CGFloat` (default 1.0)
    - `isManualZoom: Bool` (default false = Fit on Screen mode)
    - `alwaysFitOnOpen: Bool` (default true)
    - `fittingOptions: FittingOptions` (default: shrink both ON, stretch both OFF)
    - `scalingQuality: ScalingQuality` enum (low/medium/high, default medium)
    - `showPixelsWhenZoomingIn: Bool` (default true)
    - `resizeWindowAutomatically: Bool` (default false)
    - `floatOnTop: Bool` (default false)
    - `lastWindowWidth / lastWindowHeight: CGFloat`
  - `static func load() -> ViewerSettings`
  - `func save()`

### 3.2 ImageViewController — Zoom Actions

- [ ] `zoomIn()` — Cmd+=: magnification + 0.25, switch to manual zoom mode
- [ ] `zoomOut()` — Cmd+-: magnification - 0.25, switch to manual zoom mode
- [ ] `fitOnScreen()` — Cmd+0: switch to fit mode, recalculate
- [ ] `actualSize()` — Cmd+1: magnification = 1.0, manual zoom mode
- [ ] `toggleAlwaysFit()` — Cmd+*: toggle `alwaysFitOnOpen`
- [ ] `toggleShowPixels()` — Shift+Cmd+P: toggle `showPixelsWhenZoomingIn`

- [ ] Add Cmd keyboard shortcuts to `keyDown(with:)`:
  ```swift
  if flags.contains(.command) {
      switch event.charactersIgnoringModifiers {
      case "=", "+": zoomIn()
      case "-": zoomOut()
      case "0": fitOnScreen()
      case "1": actualSize()
      case "*": toggleAlwaysFit()
      case "f": toggleFullScreen()  // placeholder for Phase 4
      default: break
      }
      if flags.contains(.shift) && event.charactersIgnoringModifiers == "p" {
          toggleShowPixels()
      }
  }
  ```

### 3.3 Zoom Mode Persistence

- [ ] Integrate `ViewerSettings` into `ImageViewController`
  - Load settings on init: `let settings = ViewerSettings.load()`
  - Save on every zoom/setting change
- [ ] `applyFitting(for:)` checks `isManualZoom`:
  - `true` → apply saved magnification
  - `false` → calculate fit using `FittingCalculator`
- [ ] `scrollViewMagnificationDidChange` delegate: update settings
- [ ] `updateScalingQuality()`: apply interpolation + showPixels threshold (mag > 1.0)

### 3.4 Menu Structure — Expand Programmatic Menu

- [ ] Expand the minimal menu created in Phase 1's `AppDelegate`
  - Add View menu, Go menu with full structure
  - Use `@objc` actions routed through First Responder chain
  - Consider extracting to a `MenuBuilder` helper class if AppDelegate gets too large

**Menu structure:**

```
Cee (App menu)
├── About Cee
├── ─────
├── Quit Cee                          Cmd+Q

File
├── Open...                           Cmd+O
├── Close Window                      Cmd+W

View
├── Fit on Screen                     Cmd+0
├── Actual Size                       Cmd+1
├── ─────
├── Always Fit Opened Images          Cmd+*     (toggle ✓)
├── Fitting Options                   ►
│   ├── Shrink to Fit Horizontally              (toggle ✓)
│   ├── Shrink to Fit Vertically                (toggle ✓)
│   ├── Stretch to Fit Horizontally             (toggle)
│   └── Stretch to Fit Vertically               (toggle)
├── Scaling Quality                   ►
│   ├── Low                                     (radio)
│   ├── Medium                                  (radio ✓)
│   ├── High                                    (radio)
│   ├── ─────
│   └── Show Pixels When Zooming In  Shift+Cmd+P (toggle ✓)
├── ─────
├── Resize Window Automatically                 (toggle)
├── Enter Full Screen                 Cmd+F     (Phase 4)
└── Float on Top                                (toggle, Phase 4)

Go
├── Next Image                        →
├── Previous Image                    ←
├── First Image                       Home
└── Last Image                        End

Window
├── Minimize                          Cmd+M
└── Zoom
```

### 3.5 Menu Action Binding

- [ ] Toggle menu items use `NSMenuItem.state` (.on / .off)
- [ ] Radio menu items (Scaling Quality): set clicked = .on, others = .off
- [ ] Actions target `nil` (First Responder chain → ImageViewController)
- [ ] Implement `validateMenuItem(_:)` in ImageViewController to update checkmarks

### 3.6 Open File Dialog

- [ ] Implement File → Open (`Cmd+O`)
  - `NSOpenPanel` with allowed content types = supported image types
  - On selection: `ImageWindowController.open(with: url)`

### 3.7 Fitting Options Integration

- [ ] Connect Fitting Options toggles to `settings.fittingOptions`
- [ ] On toggle: save settings + reapply fitting to current image
- [ ] Verify: changing shrink/stretch affects image display immediately

### 3.8 Scaling Quality Integration

- [ ] Connect Scaling Quality radio to `settings.scalingQuality`
- [ ] Update `ImageContentView.interpolation` on change
- [ ] Show Pixels logic in `updateScalingQuality()`:
  - Check both conditions: `settings.showPixelsWhenZoomingIn == true` AND `scrollView.magnification > 1.0`
  - If both true → `contentView.interpolation = .none` (Nearest Neighbor, shows pixel grid)
  - Otherwise → use `settings.scalingQuality` mapped interpolation
  - Call `updateScalingQuality()` from: zoom actions, magnification delegate, toggle actions

## Verification

### Manual Tests
- [ ] `Cmd+=` zooms in, `Cmd+-` zooms out
- [ ] `Cmd+0` returns to Fit on Screen
- [ ] `Cmd+1` shows 100% actual size
- [ ] After manual zoom, switching images keeps same zoom level
- [ ] After `Cmd+0`, switching images auto-fits each image
- [ ] `Cmd+*` toggles Always Fit (visible as checkmark in menu)
- [ ] Fitting Options: toggle each item, see immediate effect on image
- [ ] Scaling Quality: switch between Low/Medium/High, visible quality change
- [ ] `Shift+Cmd+P`: toggle Show Pixels, zoom >100% shows pixel grid
- [ ] File → Open: opens file dialog, selecting image loads it
- [ ] Close app → reopen: all settings preserved
- [ ] Menu checkmarks reflect current state correctly

### Settings Persistence
- [ ] Change zoom to manual → quit → relaunch → zoom is manual with same level
- [ ] Change Fitting Options → quit → relaunch → options preserved
- [ ] Change Scaling Quality → quit → relaunch → quality preserved

## Files Created/Modified

| File | Change |
|------|--------|
| `Cee/Models/ViewerSettings.swift` | new |
| `Cee/Controllers/ImageViewController.swift` | Add zoom actions, settings, menu validation |
| `Cee/App/AppDelegate.swift` | Add programmatic menu setup, Open panel |
| (No XIB — menu is programmatic since Phase 1) | |

## Notes

- **Programmatic Menu**: Phase 1 already established programmatic menu in AppDelegate. Phase 3 expands it with View/Go menus. No XIB involved.
- **First Responder Chain**: Menu actions with `target: nil` automatically route to the first responder (ImageViewController when the window is key). This is the standard AppKit pattern for menu commands.
- **validateMenuItem**: AppKit calls this automatically before showing a menu. Use it to set `.state = .on/.off` for toggles and radio items based on current settings.
