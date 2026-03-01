# Cee — CLAUDE.md

macOS image viewer (AppKit, Swift 6.2, arm64, Xcode 26).
Replaces XEE. Core flow: Finder right-click → Open With → folder browse → pinch zoom.

## Build & Test

```bash
xcodegen generate          # regenerate .xcodeproj after project.yml changes
xcodebuild -project Cee.xcodeproj -scheme Cee -configuration Debug build
./scripts/test-e2e.sh      # run full XCUITest suite
xcodebuild test -project Cee.xcodeproj -scheme Cee -destination 'platform=macOS,arch=arm64' -only-testing:CeeUITests/CeeUITests/testSmoke_AppLaunchesAndDisplaysImage
xcodebuild test -project Cee.xcodeproj -scheme Cee -destination 'platform=macOS' -only-testing:CeeUITests/CeeUITests/testFullscreenZoom_RemainsHorizontallyCentered
```

Runtime debug toggles:

```bash
# either one enables CenteringDebug logs
CEE_DEBUG_CENTERING=1 /path/to/Cee.app/Contents/MacOS/Cee
/path/to/Cee.app/Contents/MacOS/Cee --debug-centering
```

## Key Conventions

- **No XIB/Storyboard** — all UI is programmatic.
- **Entry point** — `main.swift` (not `@main`/`@NSApplicationMain`).
- **Single window reuse** — `ImageWindowController.shared` prevents ARC release and reuses the window.
- **project.yml** — source of truth for Xcode project. `.xcodeproj` is gitignored. Re-run `xcodegen generate` after structural changes.

## Swift 6 Gotchas

- **`ImageLoader` is an `actor`** — never pass `ImageFolder` (non-Sendable class) across actor boundaries. Use value types (`ImageItem` is `Sendable`).
- **CGContext interpolation** — `NSGraphicsContext.imageInterpolation` is silently ignored on macOS Big Sur+ Retina. Always set `cgCtx.interpolationQuality` directly.
- **`setMagnification(_:centeredAt:)`** — parameter label is `centeredAt:`, not `centeredAtPoint:`.
- **Protocol + @MainActor** — delegate protocols called from NSScrollView subclasses must be marked `@MainActor` to avoid Swift 6 isolation errors.
- **NSScrollView unflipped coordinates** — visual top = high Y (`clipBounds.maxY >= docFrame.height`), visual bottom = low Y (`clipBounds.minY <= 0`). Easy to swap.
- **CALayer y-axis is flipped in layer-backed NSView.** `wantsLayer = true` → AppKit sets `layer.isGeometryFlipped = true` → `y=0` is visual top. Opposite of raw Core Animation.
- **`deinit` cannot access stored properties** in strict concurrency. Use notification-based cleanup instead.

## Window Sizing Gotchas

- **Window restoration can produce tiny windows.** Enforce minimum content size, reject tiny persisted sizes, post-show sanity check.
- **"Title updates but image area empty"** = layout-size issue. Verify window/content/clip sizes before blaming decode.

## Fullscreen & Centering Conventions

- **Never sync fullscreen with fixed delays.** Use `NSWindow.didEnterFullScreen` / `didExitFullScreen` notifications as the only reliable sync point.
- **Fullscreen UX policy:** hide both scrollbars in fullscreen, restore outside fullscreen.
- **Centering math must stay in one coordinate space.** Use document-space values (`clipView.bounds`, `contentView.frame`, `contentInsets`, `clip origin`) consistently.
- **Degenerate ranges are normal.** When image is smaller than viewport, scroll range may collapse (`min == max`); clamp exactly instead of treating as error.
- **Pinch lifecycle rule:** avoid extra deferred recenter work during `.changed`; do final normalization only at `.ended/.cancelled` to prevent visual jitter.

## Scroll & Page-Turn Gotchas

- **Trackpad vs mouse wheel need separate handling.** Trackpad has phase lifecycle; mouse wheel has none. Detect via `event.phase != [] || event.momentumPhase != []`. Independent thresholds (trackpad ~130pt, wheel ~20pt).
- **Trackpad page-turn: edge-start + accumulate + once-per-gesture.** Without edge-start check, mid-scroll momentum triggers false page turns.
- **Momentum lock after page turn (~1s).** New `.began` phase immediately unlocks. Without this, residual momentum triggers second page turn.
- **Keyboard edge-press guard.** Arrow keys: 3 extra presses at edge. PageUp/PageDown/Space: 1 extra press. No overflow → navigate directly. See `handleEdgePress(keyCode:threshold:)`.
- **Edge indicators** (`CAGradientLayer`, #F97068 coral). Must call `resetEdgeState()` on page navigation or direction change.

## AppKit Menu Gotchas

- **Cmd-shortcuts vs keyDown — no duplication.** `performKeyEquivalent` fires before `keyDown`. Rule: Cmd-modified → menu items only; bare keys → `ImageScrollView.keyDown` only.
- **Go menu** — Cmd+]/[ for Next/Prev (reliable in XCUITest). Bare arrow/Space/Home/End in keyDown only.
- **`NSMenuItemValidation`** — protocol conformance, not `override`. NSViewController has no such method.

## AppKit Key Event Gotcha

**Never put `keyDown(with:)` on NSViewController when NSScrollView is first responder.** NSScrollView intercepts arrow/Space/PageUp/PageDown and doesn't call `super.keyDown`. Override on the NSScrollView subclass and delegate via `ImageScrollViewDelegate`.

## XCUITest Gotchas (macOS)

- **NSScrollView accessibility** — only `setAccessibilityIdentifier`; never override `.scrollArea` role (corrupts hit point). Avoid clicking scroll view in tests.
- **Bare key events unreliable.** Use Cmd-modified menu shortcuts for navigation in tests.
- **`@MainActor` + async lifecycle** for XCTestCase to avoid Swift 6 isolation warnings. Do NOT use `nonisolated(unsafe) var app`.
- **Always assert `XCTWaiter` result.** `.wait(...)` returns `.timedOut` silently — must check.
- **`TestMode`** — reads `--ui-testing`/`--reset-state`/`--disable-animations` from launch args, `UITEST_FIXTURE_PATH` from env.
- **Scroll metrics assertions** — `imageScrollView` accessibility value exposes `mag/origin/min/max`; prefer numeric range assertions over screenshot-only checks for centering regressions.

## Mouse & Gesture Interaction Gotchas

- **Cmd+scroll = zoom.** Uses viewport center. `hasPreciseScrollingDeltas` distinguishes trackpad (0.003) from mouse (0.08). Does NOT follow Natural Scrolling.
- **Mouse drag pan** — `mouseDown` skips `super` (avoids scroller modal loop), only when no modifiers. `mouseDragged` MUST call `super` when not dragging.
- **NSCursor push/pop** — monitor `didResignKeyNotification` for focus-loss mid-drag cleanup. Guard against double-push.

## Zoom & Fit Behavior

- **`alwaysFitOnOpen` takes precedence over `isManualZoom`** in `applyFitting`.
- **Zoom actions must call `resizeWindowToFitZoomedImage`** after magnification change.
- **`toggleAlwaysFit` clears `isManualZoom`**.
- **Dynamic min magnification** — `effectiveMinMagnification()` (in both `ImageScrollView` and `ImageViewController`) computes the floor from `minWindowContentWidth/Height ÷ imageSize`. Prevents magnification from dropping below what the window can display, which causes window-resize desync and drift.
- **`isZooming` flag** — suppresses force-recenter in `applyCenteringInsetsIfNeeded` during all zoom paths (keyboard, pinch, Cmd+scroll). Without this, `crossedInsetThreshold`/`becameScrollable` recentering destroys the user's pan position mid-zoom.

## PDF Support

- **PDF pages expand into individual `ImageItem` entries** with `pdfPageIndex` (0-based). Standard prev/next navigation per page.
- **Page count: Spotlight first (`kMDItemNumberOfPages`), `CGPDFDocument` fallback.**
- **Fixed 2x Retina scale.** No dynamic `backingScaleFactor` — almost all Macs are Retina.
- **Pixel limit guard (100M pixels)** prevents OOM on huge pages.
- **PDF rotation** — swap width/height for 90/270°. Negate rotation angle because CG Y-axis points up.
- **Cancelable prefetch** — `prefetchTasks`/`imagePrefetchTasks` dicts track background Tasks. `updateCache` cancels out-of-range; `cancelAllPrefetchTasks()` on folder change.
- **Last-viewed page** — `UserDefaults` key `pdf.lastPage.\(url.path)`, clamped to valid range.
- **Window subtitle** shows "Page N" for PDF items.

## Status Bar

- **Container View pattern** — `ImageViewController.view` is a container NSView, not the scrollView directly. ScrollView + StatusBarView are siblings via Auto Layout.
- **View hierarchy**: `container → [scrollView, statusBarView]`. ScrollView fills except bottom; StatusBar pinned to bottom with 22pt height.
- **Toggle pattern** — `statusBarHeightConstraint.constant` toggles between 22pt/0; `applyCenteringInsetsIfNeeded()` called after toggle to recalculate centering.
- **Zoom display** — "Fit" when `!isManualZoom && alwaysFitOnOpen`; "100%" when zoom=1.0 in manual mode; otherwise percentage.
- **Settings persistence** — `ViewerSettings.showStatusBar` defaults to `true`. New fields are backward-compatible via Codable default values.

## Recent Significant Changes

- **Fullscreen centering hardening:** migrated from delay-based sync to notification-driven transition handling, with explicit post-transition recentering.
- **Pinch stability improvements:** centering/clamp flow now avoids per-frame deferred corrections that cause flicker.
- **Fullscreen presentation polish:** scrollbars are hidden while fullscreen is active.
- **Regression coverage upgraded:** UI tests now include horizontal centering checks with parsed scroll metrics, not only visibility checks.
- **Zoom viewport-center preservation:** zoom now keeps the user's pan position instead of snapping back to image center. Dynamic min magnification prevents window-resize desync drift.
