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
- **Single window reuse** — `ImageWindowController.shared`.
- **project.yml** — source of truth for Xcode project. `.xcodeproj` is gitignored.
- **Test targets** — `CeeTests` (unit, pure logic) and `CeeUITests` (E2E). Unit tests use temp directories with minimal PNG files for ImageFolder tests. `TestHelpers.swift` provides shared `minimalPNG()`.
- **URL comparison gotcha** — `URL ==` can fail between manually constructed URLs (`appendingPathComponent`) and URLs from `contentsOfDirectory`. Use `.path` comparison for reliable matching in tests.

## Swift 6 Gotchas

- **`ImageLoader` is an `actor`** — never pass `ImageFolder` (non-Sendable class) across actor boundaries. Use `ImageItem` (Sendable).
- **`setMagnification(_:centeredAt:)`** — parameter label is `centeredAt:`, not `centeredAtPoint:`.
- **Protocol + @MainActor** — delegate protocols called from NSScrollView subclasses must be marked `@MainActor`.
- **NSScrollView unflipped coordinates** — visual top = high Y, visual bottom = low Y. Easy to swap.
- **NSScrollView `contentInsets` uses visual semantics** — `.top` = visual top (high Y), `.bottom` = visual bottom (low Y). In `scrollRange`: `minY = -insets.bottom`, `maxY = docH - clipH + insets.top`. Getting this backwards causes asymmetric scroll range bugs.
- **CALayer y-axis flipped in layer-backed NSView** — `wantsLayer = true` → `y=0` is visual top. Opposite of raw Core Animation.
- **`deinit` cannot access stored properties** in strict concurrency. Use notification-based cleanup.

## XcodeGen Gotchas

- **Unit test bundle type is `bundle.unit-test`**, not `bundle.unit-testing`. UI test is `bundle.ui-testing`.
- **`GENERATE_INFOPLIST_FILE: YES`** required for test targets without custom Info.plist.

## Fullscreen & Centering

- **Never sync fullscreen with fixed delays.** Use `didEnterFullScreen`/`didExitFullScreen` notifications.
- **Centering math must stay in one coordinate space.** Never divide `statusBarHeight` by magnification — all insets/bounds share the same space.
- **Re-apply AutoFit after fullscreen transition** in `handleFullscreenTransitionDidComplete()`.
- **Degenerate scroll ranges are normal.** When image < viewport, `min == max`; clamp exactly.
- **Pinch lifecycle:** final normalization only at `.ended/.cancelled`, not during `.changed`.
- **Anchor out-of-bounds** — When recenter anchor lies outside document bounds (e.g. after zoom shrink), use document center. Clamping with out-of-bounds anchor causes rightward bias.

## Scroll & Page-Turn

- **Trackpad vs mouse wheel need separate handling.** Detect via `event.phase != [] || event.momentumPhase != []`. Thresholds: trackpad ~130pt, wheel ~20pt.
- **Trackpad page-turn: edge-start + accumulate + once-per-gesture.** Without edge-start check, momentum triggers false turns.
- **Momentum lock after page turn (~1s).** New `.began` unlocks. Prevents double page turn from residual momentum.
- **Keyboard nav: configurable arrow navigation.** Left/right and up/down arrow navigation are separate toggles in View menu (`arrowLeftRightNavigation`, `arrowUpDownNavigation`). Left/right default on, up/down default off. When enabled: 3 extra presses at edge. PageUp/PageDown/Space: 1 extra press.
- **Edge indicators** (`CAGradientLayer`, #F97068 coral). `resetEdgeState()` on navigation or direction change.

## AppKit Gotchas

- **Cmd-shortcuts vs keyDown — no duplication.** `performKeyEquivalent` fires before `keyDown`. Cmd-modified → menu items; bare keys → `ImageScrollView.keyDown`.
- **Never put `keyDown(with:)` on NSViewController when NSScrollView is first responder.** NSScrollView intercepts arrow/Space/PageUp/PageDown. Override on NSScrollView subclass, delegate via protocol.
- **`NSMenuItemValidation`** — protocol conformance, not `override`.
- **Context menu** — `menu(for: event)` → delegate. Dual page mode hit-tests click position for correct page target. Labels must match AppDelegate's menu bar; `validateMenuItem` updates dynamically.

## XCUITest Gotchas

- **NSScrollView accessibility** — only `setAccessibilityIdentifier`; never override `.scrollArea` role.
- **Bare key events unreliable.** Use Cmd-modified menu shortcuts (Cmd+]/[ for Next/Prev).
- **`@MainActor` + async lifecycle** for XCTestCase. Do NOT use `nonisolated(unsafe) var app`.
- **Always assert `XCTWaiter` result** — `.wait(...)` returns `.timedOut` silently.
- **`TestMode`** — reads `--ui-testing`/`--reset-state`/`--disable-animations` from args, `UITEST_FIXTURE_PATH` from env.

## Mouse & Gesture

- **Cmd+scroll = zoom** at viewport center. `hasPreciseScrollingDeltas` distinguishes trackpad (0.003) from mouse (0.08). Does NOT follow Natural Scrolling.
- **Mouse drag pan** — `mouseDown` skips `super` (avoids scroller modal loop) when no modifiers.
- **NSCursor push/pop** — monitor `didResignKeyNotification` for focus-loss cleanup. Guard double-push.

## GPU Layer Rendering

- **`ImageContentView` uses `layer.contents = cgImage`**, not `draw()`. GPU affine transform for zoom; zero CPU redraw.
- **`wantsUpdateLayer = true` + `layerContentsRedrawPolicy = .onSetNeedsDisplay`** — only image changes trigger `updateLayer()`. Never mix with `draw()`.
- **Scaling quality = CALayer filters** (`layerScalingFilter`/`layerMinificationFilter`). GPU-side; does NOT trigger `needsDisplay`.
- **Error placeholder** is a separate overlay view, not drawn in `draw()`. Must be added to container `self.view`, NOT `scrollView` — NSScrollView's clipView covers subviews added directly to it.

## Zoom & Fit

- **`alwaysFitOnOpen` takes precedence over `isManualZoom`** in `applyFitting`.
- **Zoom actions must call `resizeWindowToFitZoomedImage`** after magnification change.
- **Dynamic min magnification** — `effectiveMinMagnification()` prevents magnification below window minimum, avoiding desync drift.
- **`isZooming` flag** — suppresses force-recenter during zoom to preserve pan position.
- **resizeToFitImage below min** — When target size < window minimum and would shrink, early return. Otherwise origin updates without size change → window drift.

## PDF Support

- **PDF pages expand into individual `ImageItem` entries** with `pdfPageIndex` (0-based).
- **Page count: Spotlight first, `CGPDFDocument` fallback.** Fixed 2x Retina scale. 100M pixel limit.
- **PDF rotation** — swap width/height for 90/270°. Negate angle (CG Y-axis up).
- **Cancelable prefetch** — `prefetchTasks` dicts; `cancelAllPrefetchTasks()` on folder change.

## Status Bar

- **Overlay design** — floats at bottom of scroll view. `contentInsets` adds `statusBarH` to `.bottom` inset so images aren't obscured.
- **No magnification conversion** — insets and bounds share coordinate space. Never divide `statusBarH` by magnification.
- **`applyFitting` uses `effectiveViewportSize`** — `scrollView.bounds.height - statusBarH`.

## Dual Page View

- **`DualPageContentView`** is permanent `scrollView.documentView`. Use `currentDocumentSize` (composite) for fitting, not `contentView.image?.size`.
- **`contentView` is a computed property** — `dualPageView.leadingPage`.
- **Height normalization** — different-resolution pages scaled to same visual height.
- **Navigation is spread-aware** — `goNext()`/`goPrevious()` auto-call `syncSpreadIndex()`.
- **RTL**: `configureDouble(isRTL:)` swaps positions, `isRTLNavigation` reverses keys, `readingDirection` persists.
- **All loading goes through `loadSpread`** — single mode wraps as `.single` spread.
- **`imageSizeCache`** — index-based `(Int) -> CGSize?`. Unknown sizes default to portrait. Clear on folder change.

## Drag-Drop

- **Empty state**: `applicationOpenUntitledFile` → `openEmpty()`. `EmptyStateView` overlay with drag support. `folder` is optional (~17 guard-let sites).
- **Browse-mode**: `ImageScrollView` also accepts drops. Same `cachedValidURLs` pattern.
- **Folder drops**: `URLFilter.isDirectory(url:)` via resource values. Use `ImageFolder(folderURL:)` initializer (not `appendingPathComponent(".")` — breaks `deletingLastPathComponent()` with pasteboard URLs).
- **Same-folder optimization**: Dropping file from current folder updates `currentIndex` directly without rescanning.
- **`ImageFolder.isSupported(url:)`**: Uses `supportedTypes` set, not generic `.image` conformance.
- **Subfolder discovery**: `init(folderURL:)` auto-searches up to 2 levels of subdirectories (BFS) when top-level has no images. `folderURL` is `private(set) var` to allow redirect.

## Fast Browse (Phase 0–1)

- **ImageLoader** — `loadThumbnail(at:maxSize:)` returns `(image, fullSize)` tuple; decodes thumbnail and reads full-res dimensions from the same `CGImageSource` in one file open. `thumbnailCache` stores `ThumbnailEntry(image, fullSize)` for zero-I/O cache hits. `cancelLoad(for:)`. Directional prefetch: `updateCache(prefetchDirection:)` extends ±cacheRadius in nav direction.
- **Navigation throttle** — `NavigationThrottle` ~20fps (`CFAbsoluteTimeGetCurrent`); `scheduleFullResLoad` 100ms after last key. Full-res load must use scroll intent (`.top`/`.bottom` from `lastPrefetchDirection`), never `.preserve` — document size change makes preserve meaningless.
- **Thumbnail fallback is opt-in** — `settings.thumbnailFallback` (default off). When off, navigation loads full-res directly. When on, shows thumbnail first then delays full-res. Toggle in View menu: "Use Low-Res Preview While Browsing".
- **Thumbnail→fullRes layout** — `resolveLayoutSize` helper: when `thumbnailOnly`, uses full-res dimensions from `loadThumbnail` result (or `imageSizeCache`) for `configureSingle`/`applyFitting`. Avoids magnification jump on portrait fit-to-width. Don't overwrite `imageSizeCache` during thumbnail load.
- **applyInitialScrollPosition** — Must run after `applyCenteringInsetsIfNeeded`; else recenter overwrites top/bottom. For `.bottom`, defer one frame to avoid jump.
- **Option+方向鍵** — Jump 10 images (single-page mode). Dual page keeps 1 spread.

## Recent Significant Changes

- **Centering/window drift fixes:** Anchor-out-of-bounds → use document center; resizeToFitImage below min → early return to avoid drift.
- **Fast browse (Phase 0–1):** Thumbnail loader, navigation throttle, directional prefetch, low-res fallback with delayed full-res, Option+arrow jump 10.
- **Subfolder auto-discovery (Phase 2.5):** Folder drops with no top-level images auto-find first subfolder with images (BFS, max depth 2). Error placeholder fix (z-order), status bar clear on empty folder.
- **Browse-mode drag-drop (Phase 2):** ImageScrollView drop support, folder drops, same-folder optimization, visual feedback.
- **Empty state with drag-drop (Phase 1):** `EmptyStateView`, optional folder, onboarding flow.
- **Dual page view:** Spread-aware navigation, RTL, per-folder persistence, PDF spread pairing.
- **Context menu:** Zoom/display/file actions, dual page hit-test, PDF copy renders image not URL.
- **GPU rendering:** `layer.contents` pipeline, CALayer filter scaling.
- **Status bar overlay:** `NSVisualEffectView` with insets-based padding.
