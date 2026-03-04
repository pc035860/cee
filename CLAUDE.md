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
- **Test targets** — `CeeTests` (unit) and `CeeUITests` (E2E). `TestHelpers.swift` provides shared `minimalPNG()`.
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
- **Xcode 26 debug dylib** — `ENABLE_DEBUG_DYLIB` splits app into stub + `Cee.debug.dylib`. Requires `CODE_SIGNING_ALLOWED: YES` with ad-hoc signing, otherwise dylib fails system policy. Incremental builds may stale the signature — clean build fixes it.

## AppKit Gotchas

- **Cmd-shortcuts vs keyDown** — `performKeyEquivalent` fires before `keyDown`. Cmd-modified → menu items; bare keys → `ImageScrollView.keyDown`.
- **Never put `keyDown` on NSViewController when NSScrollView is first responder.** NSScrollView intercepts arrow/Space/PageUp/PageDown. Override on NSScrollView subclass.
- **`NSMenuItemValidation`** — protocol conformance, not `override`.
- **Overlay event passthrough** — display-only overlays override `hitTest` → `nil`. For drag-drop, child `NSImageView` must call `unregisterDraggedTypes()` to prevent intercepting parent's drag session.
- **NSVisualEffectView + alpha animation** — animating `alphaValue` causes material compositing flash. Use plain `layer.backgroundColor` with semi-transparent color instead.
- **NSCollectionView re-enables scrollers** during layout/reloadData. Override getter+setter in subclass to lock off; simple property assignment is insufficient.
- **NSCollectionView `didSelectItemsAt` fires on arrow keys** — filter with `NSApp.currentEvent?.type == .leftMouseUp` for click-only.
- **`NSCollectionViewPrefetching` doesn't exist in AppKit** — UIKit-only.

## XCUITest Gotchas

- **NSScrollView accessibility** — only `setAccessibilityIdentifier`; never override `.scrollArea` role.
- **Bare key events unreliable.** Use Cmd-modified menu shortcuts.
- **Always assert `XCTWaiter` result** — `.wait(...)` returns `.timedOut` silently.

## Centering & Zoom

- **Never sync fullscreen with fixed delays.** Use `didEnterFullScreen`/`didExitFullScreen` notifications.
- **Centering math: one coordinate space.** Never divide `statusBarH` by magnification.
- **Anchor out-of-bounds** — When anchor lies outside document bounds, use document center. Clamping causes rightward bias.
- **`isZooming` flag** suppresses force-recenter during zoom to preserve pan position.
- **resizeToFitImage below min** — When target < window minimum, early return to avoid drift.

## Scroll & Page-Turn

- **Trackpad vs mouse wheel** — Detect via `event.phase != [] || event.momentumPhase != []`. Thresholds: trackpad ~130pt, wheel ~20pt.
- **Trackpad page-turn: edge-start + accumulate + once-per-gesture.** Momentum lock ~1s after turn.
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

- **`ImageLoader.loadThumbnail`** returns `(image, fullSize)` tuple. `ThumbnailCacheKey(url, maxSize)` composite key isolates grid vs main view caches. **Known issue**: `fullSize` doesn't handle EXIF orientation — rotated images report swapped dimensions.
- **Navigation throttle** ~20fps; `scheduleFullResLoad` 100ms after last key. Full-res must use scroll intent (`.top`/`.bottom`), never `.preserve`.
- **Thumbnail fallback is opt-in** — `settings.thumbnailFallback` (default off).
- **`applyInitialScrollPosition`** must run after `applyCenteringInsetsIfNeeded`. For `.bottom`, defer one frame.
- **Option+scroll** — `OptionScrollAccumulator` with separate trackpad/mouse thresholds. Mouse delta ×10 sensitivity, steps clamped to 1, time-based reset (0.3s). Must intercept BEFORE `pageTurnLockUntil` check.

## Quick Grid

- **`QuickGridView`** — NSCollectionView overlay (G key toggle). Grid-local thumbnail cache separate from `ImageLoader.thumbnailCache`.
- **Grid cell resize** — Pinch, Cmd+Scroll, Cmd+=+-, slider. All route through `applyItemSize()` → `invalidateLayout()` (never `reloadData()`). Three thumbnail tiers: ≤tier1→240px, ≤tier2→480px, >tier2→1024px; tier change clears thumbnails + reloads.
- **Dynamic cell aspect ratio** — `sampleMedianAspectRatio()` reads image headers (no decode). EXIF orientation 5-8 requires swapping w/h.
- **Space-around layout** — `max(0, remaining)` + `floor(gap)` guards: negative remaining crashes FlowLayout; unrounded gaps cause line wrapping. Width-cache skips height-only recalcs.
- **Grid persists across folder changes** — `clearCache()` + `configure()` instead of dismiss.

## Recent Significant Changes

- **@objc selector fix:** Split `goToNextImage(amount:)` into `@objc` action + internal `navigateNext(amount:)` to prevent pointer-as-Int.
- **Grid layout Phase 3-4:** Dynamic cell aspect ratio (EXIF-aware), smooth resize, space-around layout, thumbnail tiers with cache isolation.
- **Option+scroll fast nav:** OptionScrollAccumulator, PositionHUDView, mouse sensitivity fix.
- **Quick Grid:** Thumbnail grid overlay, async loading, keyboard handling, drag-drop support.
- **Fast browse:** Thumbnail loader, navigation throttle, directional prefetch, Option+arrow jump 10.
