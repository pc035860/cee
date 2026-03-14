# Cee — CLAUDE.md

macOS image viewer (AppKit, Swift 6.2, arm64, Xcode 26).
Replaces XEE. Core flow: Finder right-click → Open With → folder browse → pinch zoom.

## Build & Test

```bash
xcodegen generate          # regenerate .xcodeproj after project.yml changes
xcodebuild -project Cee.xcodeproj -scheme Cee -configuration Debug build
xcodebuild test -project Cee.xcodeproj -scheme Cee -destination 'platform=macOS' -only-testing:CeeTests
./scripts/test-e2e.sh      # XCUITest suite
```

Debug: `CEE_DEBUG_CENTERING=1` env var or `--debug-centering` flag.

## Key Conventions

- **No XIB/Storyboard** — all UI is programmatic.
- **Entry point** — `main.swift` (not `@main`/`@NSApplicationMain`).
- **Multi-instance window support** — `ImageWindowController.windows` (array) replaces the old `shared` singleton. `reuseWindow` setting (default `true`) controls whether new files open in the same window or a new one.
- **project.yml** — source of truth for Xcode project. `.xcodeproj` is gitignored.
- **Test targets** — `CeeTests` (unit) and `CeeUITests` (E2E). `TestHelpers.swift` provides shared `minimalPNG()`, `createJPEG(width:height:)`, `createPNG(width:height:)`.
- **URL comparison gotcha** — `URL ==` can fail between manually constructed URLs and URLs from `contentsOfDirectory`. Use `.path` comparison.

## Swift 6 Gotchas

- **`ImageLoader` is an `actor`** — never pass `ImageFolder` (non-Sendable) across actor boundaries. Use `ImageItem` (Sendable).
- **`setMagnification(_:centeredAt:)`** — parameter label is `centeredAt:`, not `centeredAtPoint:`.
- **Protocol + @MainActor** — delegate protocols called from NSScrollView subclasses must be marked `@MainActor`.
- **NSScrollView unflipped coordinates** — visual top = high Y, visual bottom = low Y.
- **NSScrollView `contentInsets` visual semantics** — `.top` = visual top (high Y), `.bottom` = visual bottom (low Y). In `scrollRange`: `minY = -insets.bottom`, `maxY = docH - clipH + insets.top`.
- **CALayer y-axis flipped in layer-backed NSView** — `wantsLayer = true` → `y=0` is visual top. Opposite of raw Core Animation.
- **`deinit` cannot access stored properties** in strict concurrency. Use notification-based cleanup.
- **CGImageSource pixel dimensions ignore EXIF orientation** — `kCGImagePropertyPixelWidth/Height` report raw sensor dimensions. For orientation 5-8, swap w/h. Thumbnails with `kCGImageSourceCreateThumbnailWithTransform: true` are auto-rotated, but `fullSize` is not.
- **`@objc func` + default parameter + menu action** — `@objc func foo(amount: Int = 1)` gets ObjC selector `fooWithAmount:`. AppKit passes `NSMenuItem` pointer as the argument → huge `Int`. Fix: separate `@objc` action from internal impl.

## XcodeGen Gotchas

- **Unit test bundle type is `bundle.unit-test`**, not `bundle.unit-testing`. UI test is `bundle.ui-testing`.
- **`GENERATE_INFOPLIST_FILE: YES`** required for test targets without custom Info.plist.
- **Xcode 26 debug dylib** — `ENABLE_DEBUG_DYLIB` splits app into stub + `Cee.debug.dylib`. Requires `CODE_SIGNING_ALLOWED: YES` with ad-hoc signing, otherwise dylib fails system policy.
- **Signing / test failures** — If CodeSign fails ("code object is not signed at all" in test bundle, or dylib system policy) or tests fail to run: run `xcodegen generate` then `xcodebuild clean build`. Regenerating syncs project.yml; clean build refreshes stale signatures. Incremental builds can leave dylib/test bundle signatures out of sync.

## AppKit Gotchas

- **Cmd-shortcuts vs keyDown** — `performKeyEquivalent` fires before `keyDown`. Cmd-modified → menu items; bare keys → `ImageScrollView.keyDown`.
- **Never put `keyDown` on NSViewController when NSScrollView is first responder.** NSScrollView intercepts arrow/Space/PageUp/PageDown. Override on NSScrollView subclass.
- **`NSMenuItemValidation`** — protocol conformance, not `override`.
- **Overlay event passthrough** — display-only overlays override `hitTest` → `nil`. For drag-drop, child `NSImageView` must call `unregisterDraggedTypes()` to prevent intercepting parent's drag session.
- **NSVisualEffectView + alpha animation** — animating `alphaValue` causes material compositing flash. Use plain `layer.backgroundColor` with semi-transparent color instead.
- **NSCollectionView re-enables scrollers** during layout/reloadData. Override getter+setter in subclass to lock off; simple property assignment is insufficient.
- **NSCollectionView `didSelectItemsAt` fires on arrow keys** — filter with `NSApp.currentEvent?.type == .leftMouseUp` for click-only. Arrow key selection does NOT auto-scroll; call `scrollToItems(at:scrollPosition:)` manually in the else branch.
- **NSCollectionView `scrollToItems` unreliable** — use `layoutAttributesForItem(at:)?.frame` + `scrollToVisible(_:)` instead for reliable programmatic scrolling.
- **NSCollectionView internal auto-scroll during selection** — `NSCollectionView` calls `scrollToItems` internally after selection changes (arrow keys). Suppress by overriding `scrollToItems(at:scrollPosition:)` in a subclass with a `suppressAutoScroll` flag; set the flag around your own scroll calls so only your animation runs.
- **NSCollectionView scrollbar + `availableLayoutWidth`** — When using a legacy always-visible scrollbar (`VisibleScroller` subclass), use `contentView.bounds.width` for `availableLayoutWidth`, not `bounds.width`, to account for the scroller's width.
- **CALayer border clipping in NSCollectionView cells** — `borderWidth` draws half inside, half outside bounds. With `masksToBounds = true` + adjacent cell overlap, borders get clipped. Fix: inset highlightLayer frame by `borderWidth/2` so border is fully inside bounds; set `zPosition` high to render above subview layers.
- **`NSCollectionViewPrefetching` doesn't exist in AppKit** — UIKit-only.
- **`setMagnification` synchronously triggers `reflectScrolledClipView`** — Any state that must be set before the scroll/magnify callback (e.g., zoom suppression flags) must be set BEFORE calling `setMagnification`, not after. The delegate callback (`scrollViewMagnificationDidChange`) fires even later.
- **Hidden views still affect `fittingSize`** — `isHidden = true` does NOT deactivate Auto Layout constraints. `NSView.fittingSize` on the container will include hidden subviews' intrinsic content widths. Fix: deactivate the hidden view's positional constraints (e.g., leading/trailing) when hiding; reactivate when showing.
- **DocumentView frame change triggers `reflectScrolledClipView`** — Setting `frame` on documentView (e.g., after `recalculateLayout()`) synchronously fires `reflectScrolledClipView` → `updateVisibleSlots`. If this overwrites mutable state (like `folder.currentIndex`) before an async callback completes, capture critical state before the frame change. Note: capturing only protects the callback's target value; the intermediate overwrites still happen. For full protection, add a suppression flag to block `notifyImageChanged` during bootstrap.

## XCUITest Gotchas

- **NSScrollView accessibility** — only `setAccessibilityIdentifier`; never override `.scrollArea` role.
- **Bare key events unreliable.** Use Cmd-modified menu shortcuts.
- **Always assert `XCTWaiter` result** — `.wait(...)` returns `.timedOut` silently.

## Centering & Zoom

- **Never sync fullscreen with fixed delays.** Use `didEnterFullScreen`/`didExitFullScreen` notifications.
- **Centering math: one coordinate space.** Never divide `statusBarH` by magnification.
- **Anchor out-of-bounds** — When anchor lies outside document bounds, use document center. Clamping causes rightward bias.
- **`isZooming` flag** suppresses force-recenter during zoom to preserve pan position.
- **resizeToFitImage clamps to effective minimum** — `effectiveMinimumContentSize()` computes dynamic floor from `max(Constants, contentMinSize, fittingSize)`. `resizeToFitImage` clamps target to this floor (no early return). `effectiveWindowResizeMinMagnification()` uses this to set zoom magnification floor. `resolvedMinMagnification()` in `ImageScrollView` is the delegate-aware entry point for zoom clamping.
- **Zoom state model** — `ZoomStatusMode` enum (`.fit`/`.actual`/`.manual`) + `ZoomStatusFormatter` for status bar display. `isAutoFitActive` computed property = `alwaysFitOnOpen && !isManualZoom`; always use this instead of inline checks. All manual zoom entry must go through `enterManualZoom()` (handles one-time hint + state transition).

## Scroll & Page-Turn

- **Trackpad vs mouse wheel** — Detect via `event.phase != [] || event.momentumPhase != []`. Thresholds: trackpad 80–250pt, wheel 10–40pt (3-tier sensitivity).
- **Trackpad page-turn: edge-start + accumulate + once-per-gesture.** Momentum lock 0.6s after turn. `suppressScrollSequenceAfterPageTurn` flag blocks the entire old scroll sequence until a fresh `phase=.began && momentumPhase=[]` gesture.
- **Momentum must not accumulate for page-turn** — Momentum delta is massive; if accumulated, all sensitivity levels feel identical. Exclude via early `return` inside `if isTrackpad`, NOT via `if isTrackpad && !isMomentumEvent` — the latter causes momentum to fall into the `else` mouse-wheel branch which lacks `gestureBeganAtEdge` protection, breaking the "extra swipe at edge" requirement.
- **NSScrollView fallback deceleration** — If momentum events are blocked without calling `super.scrollWheel`, NSScrollView detects disrupted momentum tracking and launches its own fallback deceleration animation after `momentumPhase=.ended`, directly manipulating clipView and bypassing `scrollWheel` override entirely. Fix: still call `super.scrollWheel` for momentum events; suppress visual movement by overriding `reflectScrolledClipView` to clamp position to top/bottom. Use `isEnforcingScrollPosition` guard to prevent recursion. **Critical**: do NOT add an `isInScrollWheelHandler` guard to `reflectScrolledClipView` — CoreAnimation-driven fallback updates happen outside `scrollWheel`, so the guard would let them bypass the clamp and cause half-page drift. Instead, rely on clearing `suppressScrollSequenceAfterPageTurn` on `momentumPhase=.ended` to re-enable arrow keys/programmatic scroll after momentum finishes.
- **`isAtTop`/`isAtBottom` must use `yScrollBounds(contentInsets)`** — comparing directly against `docFrame.height` ignores `contentInsets` and causes premature page-turn trigger when status bar padding is non-zero. Always derive top/bottom thresholds via `yScrollBounds` for consistency with `reflectScrolledClipView` clamp logic.
- **Keyboard nav** — Arrow left/right and up/down are separate toggles. 3 extra presses at edge for arrows; 1 for PageUp/PageDown/Space.

## GPU Rendering

- **`ImageContentView` uses `layer.contents = cgImage`**, not `draw()`. GPU affine transform for zoom.
- **`wantsUpdateLayer = true`** — never mix with `draw()`.
- **Error placeholder** must be added to `self.view`, NOT `scrollView` — clipView covers subviews.

## Dual Page View

- **`DualPageContentView`** is permanent documentView. Use `currentDocumentSize` for fitting, not `contentView.image?.size`.
- **`contentView` is computed** — `dualPageView.leadingPage`.
- **All loading goes through `loadSpread`** — single mode wraps as `.single`.
- **`imageSizeCache`** — index-based. Unknown sizes default to portrait. Clear on folder change.

## Drag-Drop

- **`folder` is optional** (~17 guard-let sites). Empty state: `EmptyStateView` overlay with drag support.
- **Folder drops** — Use `ImageFolder(folderURL:)` (not `appendingPathComponent(".")` — breaks `deletingLastPathComponent()`).
- **Subfolder discovery** — `init(folderURL:)` auto-searches up to 2 levels (BFS) when top-level has no images.

## Fast Browse

- **`ImageLoader.loadThumbnail`** returns `(image, fullSize)` tuple. `ThumbnailCacheKey(url, maxSize)` composite key isolates grid vs main view caches. `priority` parameter (default `.userInitiated`) allows `.utility` for buffer cells. Throttled by `ThumbnailThrottle` actor (max 4 concurrent). **Known issue**: `fullSize` doesn't handle EXIF orientation — rotated images report swapped dimensions.
- **Navigation throttle** ~20fps; `scheduleFullResLoad` 100ms after last key. Full-res must use scroll intent (`.top`/`.bottom`), never `.preserve`.
- **Thumbnail fallback is opt-in** — `settings.thumbnailFallback` (default off).
- **`applyInitialScrollPosition`** must run after `applyCenteringInsetsIfNeeded`. For `.bottom`, defer one frame.
- **Option+scroll** — `OptionScrollAccumulator` with separate trackpad/mouse thresholds. Mouse delta ×10 sensitivity, steps clamped to 1, time-based reset (0.3s). Must intercept BEFORE `pageTurnLockUntil` check.

## Quick Grid

- **`QuickGridView`** — NSCollectionView overlay (G key toggle). Grid-local thumbnail cache separate from `ImageLoader.thumbnailCache`.
- **Grid cell resize** — Pinch, Cmd+Scroll, Cmd+=+-, slider. All route through `applyItemSize()` → `invalidateLayout()` (never `reloadData()`). Four thumbnail tiers: ≤tier0→adaptive (quantized 20px steps), ≤tier1→240px, ≤tier2→480px, >tier2→720px; tier change clears thumbnails + reloads.
- **Dynamic cell aspect ratio** — `sampleMedianAspectRatio()` reads image headers (no decode). EXIF orientation 5-8 requires swapping w/h.
- **Space-around layout** — `max(0, remaining)` + `floor(gap)` guards: negative remaining crashes FlowLayout; unrounded gaps cause line wrapping. Width-cache skips height-only recalcs.
- **Grid persists across folder changes** — `clearCache()` + `configure()` instead of dismiss.
- **Grid performance (Phase 1)** — `ThumbnailThrottle` actor limits concurrent decodes to 4. Scroll handler (20Hz) cancels non-visible tasks + evicts cache outside visible ± 50 buffer. Visible cells use `.userInitiated`, buffer cells `.utility`. Memory capped at 5% system RAM.
- **Grid performance (Phase 2)** — Scroll-direction-aware prefetch (2 rows ahead), `MemoryPressureMonitor` (DispatchSource warning/critical), `generationID` stale-write guard on folder change, layer-backed cell optimization (`canDrawSubviewsIntoLayer` + `.onSetNeedsDisplay`).
- **Keep-set cancel pattern** — When prefetch + cancel coexist, cancel must use `keepSet = visible ∪ prefetchRange`, not just visible indices. Otherwise prefetch tasks are immediately cancelled by the scroll handler.
- **Generation ID pattern** — Int counter incremented on `clearCache()`, captured in Task closure, checked before cache write. Prevents stale folder thumbnails from overwriting new folder's cache. Same concept as `ImageViewController.currentLoadRequestID` (UUID) but simpler.
- **DispatchSource idempotent start** — `DispatchSource.makeMemoryPressureSource` must guard `source == nil` before creating; repeated `start()` leaks un-cancelled sources.
- **Reuse `NavigationThrottle`** — For any CFAbsoluteTime-based throttle (scroll handlers, etc.), use the existing `NavigationThrottle` struct instead of inline `lastTimestamp` + `guard` patterns.
- **Grid performance (Phase 3.1-3.2)** — Tier0 adaptive resolution (`max(cellSize*scale, 80)` quantized to 20px steps) + `kCGImageSourceSubsampleFactor: 4` for JPEG/HEIF ≤120px. Priority dequeue in `ThumbnailThrottle` (smaller priority = higher urgency, FIFO tie-break). `cachedVisibleCenter` updated at 20Hz by scroll handler for `cellForItem` priority. Early `Task.isCancelled` guard after throttle acquire, before decode.
- **`cachedVisibleCenter` pattern** — Avoid calling `indexPathsForVisibleItems()` per-cell in data source. Cache the visible center in the scroll handler (20Hz) and reuse in `cellForItem` + eviction. Initialize in `configure()` to `currentIndex`.
- **Quantize to prevent cache churn** — When computed `maxSize` varies continuously (e.g., during pinch), quantize to fixed steps (`ceil(raw / step) * step`) so tier comparisons don't flush cache every frame.
- **Grid scroll anchor on resize** — `gridFrameDidChange` captures viewport-center anchor (item index + fraction) before layout, restores after. Gated by `isContinuousScrollMode`. Must call `layoutSubtreeIfNeeded()` after `invalidateLayout()` to force immediate layout — otherwise NSCollectionView's deferred layout pass overwrites the restored scroll position. Uses analytical document height (`topInset + totalRows * rowHeight - lineSpacing + bottomInset`) instead of `collectionView.frame.height` which may be stale during resize.

## Recent Significant Changes

- **Zoom state surfacing:** `ZoomStatusMode` enum + `ZoomStatusFormatter` replaced raw `(zoom, isFitting)` pairs in status bar. Three modes: FIT (auto-fit active), ACTUAL 100%, MANUAL xx%. Optional `WINDOW AUTO` suffix when window auto-resize is active. `enterManualZoom()` encapsulates all manual zoom transitions with a one-time `PositionHUDView` hint (persisted via `hasShownManualZoomHint`). `PositionHUDView` now supports arbitrary text messages in addition to position display.
- **Auto-fit on window resize:** `alwaysFitOnOpen` now also re-applies fitting during `NSWindow.didResizeNotification`, but only when `isManualZoom == false` and not in continuous scroll mode. `ImageWindowController.windowDidResizeNotification` forwards resize events to `ImageViewController.handleWindowDidResize()`; manual zoom must remain untouched.
- **Trackpad page-turn momentum fix:** NSScrollView fallback deceleration animation bypasses `scrollWheel` override. Solved by passing momentum to super + `reflectScrolledClipView` clamp. `suppressScrollSequenceAfterPageTurn` blocks old scroll sequence; `commitPageTurn(goingDown:)` unifies page-turn state. See "Scroll & Page-Turn" gotchas above.
- **Click to turn page:** Single-click on left/right edge turns page (configurable in Navigation menu).
- **Navigation menu:** New "Navigation" menu between View and Go. Reading mode (Dual Page, RTL) and nav settings (Arrow keys, Scroll to Bottom, page-turn sensitivity) moved there from View/Go menus.
- **RTL nav + scroll settings:** `duoPageRTLNavigation` (default on) / `singlePageRTLNavigation` (default off) as independent settings; `effectiveRTLNavigation` picks based on current mode. `scrollToBottomOnPrevious` (default on) controls scroll position when navigating backward.
- **Grid progressive tier reload:** Tier change no longer clears `gridThumbnails`; stale images stay visible until new tier finishes. `gridThumbnailSizes` tracks cached tier per index.
- **Grid scrollbar:** Replaced overlay/autohide with legacy `VisibleScroller` subclass (always-visible, custom knob). `availableLayoutWidth` must use `contentView.bounds.width`.
- **Multi-instance window support:** `ImageWindowController` now manages a `windows: [ImageWindowController]` array instead of a `shared` singleton. `reuseWindow: Bool` setting in `ViewerSettings` toggles behavior. `current` property prefers `NSApp.keyWindow` → `NSApp.mainWindow` → `windows.last`. Multi-file open deduplicates by folder path to prevent race conditions. Window cleanup via `willCloseNotification`.
- **Fill window height action:** View menu + context menu action (`⌥⌘F`) expands the current window to `screen.visibleFrame.height` without entering fullscreen. `ImageWindowController.expandedHeightFrame(from:within:)` clamps X into the visible frame and shrinks over-wide windows to fit the screen.
- **Grid performance (Phases 1-3.2):** ThumbnailThrottle (max 4 concurrent), scroll-direction prefetch, MemoryPressureMonitor, generationID stale-write guard, layer-backed cells, Tier0 adaptive resolution + SubsampleFactor, priority dequeue, cachedVisibleCenter.
- **Option+scroll fast nav:** OptionScrollAccumulator, PositionHUDView, mouse sensitivity fix.
- **Quick Grid:** NSCollectionView overlay (G key), dynamic cell aspect ratio (EXIF-aware), space-around layout, thumbnail tiers, always-visible scrollbar, Finder-style slider.
- **Continuous Scroll Mode (Phases 1-3.5):** Webtoon-style vertical scrolling. `ContinuousScrollContentView` uses standard macOS coordinates (y=0 at bottom). `yOffsets` array is **descending** (index 0 = highest y = visual top). Binary search (O(log n)) for both index tracking and visible range calculation. `scaledHeights` cache avoids redundant calculations. CADisplayLink for smooth window resize with center-preserving animation. `ImageSlotView` (layer-backed GPU rendering via `wantsUpdateLayer` + `layer.contents = cgImage`), view recycling (`activeSlots`/`reusableSlots` + `bufferCount`), scroll direction-aware prefetch (`NavigationThrottle` 20Hz + `PrefetchDirection`), configuration generation ID (stale write guard on folder switch), async image loading with stale-write prevention (`slot.imageIndex == index` check). **Zoom support (Phase 3.3):** `effectiveMinMagnification()` returns 1.0 in continuous mode (fit-to-width baseline); `scrollViewMagnificationDidChange` fast path skips window resize/recenter; `actualSize` redirects to `fitOnScreen`; mode toggle resets magnification + `isManualZoom`; `ImageSlotView.setScalingFilters` + `ContinuousScrollContentView.setScalingFilters` for scaling quality. **Zoom flicker fix:** `beginZoomSuppression()`/`endZoomSuppression(visibleBounds:)` on `ContinuousScrollContentView` suppresses slot recycling during zoom; must be called before `setMagnification` (see AppKit gotcha). **Memory pressure (Phase 3.4):** `MemoryPressureMonitor` integration — warning shrinks `bufferCount` to 0 (restored on next scroll), critical also clears reusable pool + `ImageLoader.clearImageCache()`. Pressure during zoom is deferred via `pendingPressureLevel` (escalate-only: critical overrides warning). **Large image subsample (Phase 3.5):** `loadImageForDisplay(at:maxWidth:)` with `DisplayCacheKey(url, maxWidth)` composite key (quantized 20px steps). `decodeImageForDisplay` uses `kCGImageSourceSubsampleFactor` (2 or 4) + `CGImageSourceCreateThumbnailAtIndex`. EXIF orientation 5-8 swap. `displayCache` eviction follows `updateCache` via `activeImageURLs`. **UX polish (Phase 3.6-3.9):** Keyboard nav uses separate `continuousScrollEnabled` early branch in `ImageScrollView.keyDown` (smooth scroll only, no page-turn). `scrollPageDownOrNext`/`scrollPageUpOrPrev` use `scrollRange(for:)` for inset-aware bounds. `validateMenuItem` uses `isContinuous` flag to disable fitting/dual-page/click-to-turn items. Quick grid selection scrolls to image via `scrollToCurrentImageInContinuousMode()` instead of reloading. `imageSpacing` + `continuousScrollGap` setting (0/2/4/8pt presets) with `relayoutSlots()` shared helper for `containerWidth`/`imageSpacing` didSet. **Resize anchor preservation:** `relayoutSlots()` captures viewport center's image index + fractional position before relayout, restores after. Fraction clamped to [0,1] (gap zones). Inset-aware Y clamp matches `yScrollBounds` semantics. Preserves horizontal pan position for zoom scenarios.
