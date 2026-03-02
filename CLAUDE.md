# Cee — CLAUDE.md

macOS image viewer (AppKit, Swift 6.2, arm64, Xcode 26).
Replaces XEE. Core flow: Finder right-click → Open With → folder browse → pinch zoom.

## Build & Test

```bash
xcodegen generate          # regenerate .xcodeproj after project.yml changes
xcodebuild -project Cee.xcodeproj -scheme Cee -configuration Debug build
xcodebuild test -project Cee.xcodeproj -scheme Cee -destination 'platform=macOS' -only-testing:CeeTests  # unit tests
./scripts/test-e2e.sh      # run full XCUITest suite (E2E)
xcodebuild test -project Cee.xcodeproj -scheme Cee -destination 'platform=macOS,arch=arm64' -only-testing:CeeUITests/CeeUITests/testSmoke_AppLaunchesAndDisplaysImage
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
- **Test targets** — `CeeTests` (unit tests, pure logic) and `CeeUITests` (E2E). Unit tests focus on non-UI modules (SpreadManager, ImageFolder navigation). Use temp directories with minimal PNG files for ImageFolder tests that need real file system.

## Swift 6 Gotchas

- **`ImageLoader` is an `actor`** — never pass `ImageFolder` (non-Sendable class) across actor boundaries. Use value types (`ImageItem` is `Sendable`).
- **CGContext interpolation (legacy)** — `NSGraphicsContext.imageInterpolation` is silently ignored on macOS Big Sur+ Retina. `ImageContentView` now uses GPU `layer.contents` instead of `draw()`; see "GPU Layer Rendering" section.
- **`setMagnification(_:centeredAt:)`** — parameter label is `centeredAt:`, not `centeredAtPoint:`.
- **Protocol + @MainActor** — delegate protocols called from NSScrollView subclasses must be marked `@MainActor` to avoid Swift 6 isolation errors.
- **NSScrollView unflipped coordinates** — visual top = high Y (`clipBounds.maxY >= docFrame.height`), visual bottom = low Y (`clipBounds.minY <= 0`). Easy to swap.
- **NSScrollView `contentInsets` uses visual semantics** — `.top` = visual top (high Y), `.bottom` = visual bottom (low Y), regardless of unflipped coordinate system. In `scrollRange`: `minY = -insets.bottom`, `maxY = docH - clipH + insets.top`. Getting this backwards causes asymmetric scroll range bugs.
- **CALayer y-axis is flipped in layer-backed NSView.** `wantsLayer = true` → AppKit sets `layer.isGeometryFlipped = true` → `y=0` is visual top. Opposite of raw Core Animation.
- **`deinit` cannot access stored properties** in strict concurrency. Use notification-based cleanup instead.

## XcodeGen Gotchas

- **Unit test bundle type is `bundle.unit-test`**, not `bundle.unit-testing`. UI test is `bundle.ui-testing`.
- **`GENERATE_INFOPLIST_FILE: YES`** required for test targets without a custom Info.plist. Without it, code signing fails with "target does not have an Info.plist file".

## Window Sizing Gotchas

- **Window restoration can produce tiny windows.** Enforce minimum content size, reject tiny persisted sizes, post-show sanity check.
- **"Title updates but image area empty"** = layout-size issue. Verify window/content/clip sizes before blaming decode.

## Fullscreen & Centering Conventions

- **Never sync fullscreen with fixed delays.** Use `NSWindow.didEnterFullScreen` / `didExitFullScreen` notifications as the only reliable sync point.
- **Fullscreen UX policy:** hide both scrollbars in fullscreen, restore outside fullscreen.
- **Re-apply AutoFit after fullscreen transition.** `handleFullscreenTransitionDidComplete()` must call `applyFitting()` when `!isManualZoom && alwaysFitOnOpen` to handle viewport size changes.
- **Centering math must stay in one coordinate space.** `clipView.bounds`, `contentView.frame`, `contentInsets`, and `clip origin` are all in the same space. Never convert screen-point constants (like `statusBarHeight`) by dividing by magnification.
- **Degenerate ranges are normal.** When image is smaller than viewport, scroll range may collapse (`min == max`); clamp exactly instead of treating as error.
- **Pinch lifecycle rule:** avoid extra deferred recenter work during `.changed`; do final normalization only at `.ended/.cancelled` to prevent visual jitter.

## Scroll & Page-Turn Gotchas

- **Trackpad vs mouse wheel need separate handling.** Trackpad has phase lifecycle; mouse wheel has none. Detect via `event.phase != [] || event.momentumPhase != []`. Independent thresholds (trackpad ~130pt, wheel ~20pt).
- **Trackpad page-turn: edge-start + accumulate + once-per-gesture.** Without edge-start check, mid-scroll momentum triggers false page turns.
- **Momentum lock after page turn (~1s).** New `.began` phase immediately unlocks. Without this, residual momentum triggers second page turn.
- **Keyboard navigation: left/right only.** Arrow up/down only scroll, never navigate. Left/right arrows: 3 extra presses at edge to navigate. PageUp/PageDown/Space: 1 extra press. See `handleEdgePress(keyCode:threshold:)`.
- **Arrow pan animation** uses `NSAnimationContext` with `allowsImplicitAnimation = true` + `clip.scroll(to:)`, duration 0.1s. `reflectScrolledClipView` in completion handler syncs scrollbars.
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

## GPU Layer Rendering

- **`ImageContentView` uses `layer.contents = cgImage`**, not `NSView.draw()`. Image is rasterized once into GPU texture; NSScrollView magnification applies GPU affine transform with zero CPU redraw.
- **`wantsUpdateLayer = true`** — `updateLayer()` sets `layer.contents`, `contentsScale`, `contentsGravity`, and filters. Never mix with `draw()`.
- **`layerContentsRedrawPolicy = .onSetNeedsDisplay`** — prevents magnification changes from invalidating the layer cache. Only `needsDisplay = true` (image change) triggers `updateLayer()`.
- **Scaling quality = layer filters.** `layerScalingFilter` (magnification) and `layerMinificationFilter` (minification) map to `.nearest`/`.linear`/`.trilinear`. These are GPU-side — setting them does NOT trigger `needsDisplay`.
- **`viewDidChangeBackingProperties()`** — triggers `needsDisplay` to refresh `contentsScale` when dragging across Retina/non-Retina displays.
- **Error placeholder is a separate view** (`ErrorPlaceholderView`), overlaid on `scrollView`, not drawn in `draw()`.

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

- **Overlay design** — StatusBarView (`NSVisualEffectView`, `.titlebar` material) overlays at the bottom of the scroll view. ScrollView fills the entire container; status bar floats on top for translucent immersive effect.
- **View hierarchy**: `container → [scrollView, statusBarView]`. ScrollView fills entire container; StatusBar pinned to bottom with fixed 22pt height.
- **contentInsets for padding** — `applyCenteringInsetsIfNeeded` adds `statusBarH` to `.bottom` inset (visual bottom) so images aren't obscured. All scroll helpers (`scrollToTop/Bottom`, `panUp/Down`, `performPan`) must use insets-aware range, not hardcoded `0`/`doc-clip`.
- **No magnification conversion for statusBarH** — `clipView.bounds.size`, `contentView.frame.size`, and `contentInsets` are all in the same coordinate space. Do NOT divide `statusBarH` by magnification; it causes padding to vary with zoom level.
- **applyFitting uses effectiveViewportSize** — `scrollView.bounds.height - statusBarH` for fitting calculation, keeping the status bar area as overlay-only space.
- **Toggle pattern** — `statusBarView.isHidden` controls visibility; `statusBarHeightConstraint` stays at 22pt. `applyCenteringInsetsIfNeeded()` called after toggle.
- **Zoom display** — "Fit" when `!isManualZoom && alwaysFitOnOpen`; "100%" when zoom=1.0 in manual mode; otherwise percentage.
- **Settings persistence** — `ViewerSettings.showStatusBar` defaults to `true`. New fields are backward-compatible via Codable default values.

## Dual Page View

- **Architecture**: `DualPageContentView` is the permanent `scrollView.documentView`. Contains 1–2 `ImageContentView` children. NSScrollView magnification auto-applies to all children — zoom/pan works identically to single page.
- **`contentView` is a computed property** — `dualPageView.leadingPage`. Minimized diff when adding dual page support. Use `currentDocumentSize` (returns `dualPageView.compositeSize`) instead of `contentView.image?.size` for fitting/centering calculations.
- **Spread model**: `PageSpread` enum (`.single`/`.double`) + `SpreadManager` (pure static `Sendable` struct). Wide page detection: `width > height` → auto-single. Cover mode: first page alone when `firstPageIsCover`.
- **Navigation is spread-aware**: When `settings.dualPageEnabled`, all nav methods (goNext/goPrev/Home/End) use spread stepping. `ImageFolder.goNext()`/`goPrevious()` auto-call `syncSpreadIndex()`.
- **Height normalization**: Different-resolution pages are scaled proportionally so both render at the same visual height (`maxH`). Without this, pages appear mismatched.
- **RTL support**: Three layers — `DualPageContentView.configureDouble(isRTL:)` swaps page positions, `ImageScrollView.isRTLNavigation` reverses arrow keys, `ViewerSettings.readingDirection` persists setting.
- **Per-folder persistence**: `FolderDualPageSettings` Codable struct in UserDefaults at `dualPage.settings.\(folderURL.path)`. Loaded on `loadFolder()`, saved on toggle.
- **Menu shortcuts**: ⌘K (dual page), ⌘⇧O (cover mode), ⌘⇧K (reading direction). Go menu shows "Next Spread"/"Previous Spread" dynamically.
- **`imageSizeCache`**: Keyed by flat image index. Used by `rebuildSpreads` for wide page detection. Unknown sizes default to portrait (paired). Cache cleared on folder change.

## Recent Significant Changes

- **Unit test target:** `CeeTests` with SpreadManager and ImageFolder navigation tests. Pure logic, no UI dependencies.
- **Dual page view:** `DualPageContentView` container with spread-aware navigation, RTL support, per-folder settings persistence. PDF pages participate in spread pairing natively. See "Dual Page View" section.
- **GPU-accelerated rendering:** `ImageContentView` migrated from CPU `draw()` to GPU `layer.contents = cgImage`. Scaling quality uses `CALayer` filters.
- **Zoom viewport-center preservation:** zoom keeps user's pan position. Dynamic min magnification prevents window-resize desync drift.
- **Fullscreen hardening:** notification-driven transition handling. AutoFit re-applies after fullscreen transition.
- **Status bar overlay with material effect:** `NSVisualEffectView` with `.titlebar` material. `contentInsets`-based padding.
