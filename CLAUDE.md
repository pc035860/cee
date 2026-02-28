# Cee — CLAUDE.md

macOS image viewer (AppKit, Swift 6.2, arm64, Xcode 26).
Replaces XEE. Core flow: Finder right-click → Open With → folder browse → pinch zoom.

## Build & Test

```bash
xcodegen generate          # regenerate .xcodeproj after project.yml changes
xcodebuild -project Cee.xcodeproj -scheme Cee -configuration Debug build
./scripts/test-e2e.sh      # run full XCUITest suite
xcodebuild test -project Cee.xcodeproj -scheme Cee -destination 'platform=macOS,arch=arm64' -only-testing:CeeUITests/CeeUITests/testSmoke_AppLaunchesAndDisplaysImage
```

## Project Structure

```
Cee/
├── App/            AppDelegate.swift, main.swift, Info.plist
├── Controllers/    ImageWindowController, ImageViewController
├── Models/         ImageItem, ImageFolder, ViewerSettings
├── Services/       ImageLoader (actor, PDF+image), FittingCalculator
├── Views/          ImageScrollView, ImageContentView
└── Utilities/      Constants.swift, TestMode.swift (DEBUG only)
CeeUITests/
├── CeeUITests.swift          main smoke test file
├── Fixtures/Images/          001-landscape.jpg, 002-portrait.png, 003-square.jpg
└── Helpers/                  ScrollHelpers.swift, WaitExtensions.swift
specs/init/         Phase specs (phase-1..6) + SPEC.md
```

## Key Conventions

- **No XIB/Storyboard** — all UI is programmatic. Menu built in `AppDelegate.setupMenuBar()`.
- **Entry point** — `main.swift` (not `@main`/`@NSApplicationMain`). AppDelegate is a plain class.
- **Single window reuse** — `ImageWindowController.shared` (private static) prevents ARC release and reuses the window when a second image is opened from Finder.
- **project.yml** — source of truth for Xcode project. Re-run `xcodegen generate` after any structural change (new files, targets, settings). `.xcodeproj` is gitignored.
- **MainActor-first UI updates** — AppKit state changes from async loading paths must stay on main actor (prefer `@MainActor` on controller-level UI coordinators).

## Swift 6 Gotchas

- **`ImageLoader` is an `actor`** — never pass `ImageFolder` (a non-Sendable class) across actor boundaries. Use value types: `updateCache(currentIndex: Int, items: [ImageItem])`. `ImageItem` is `Sendable`.
- **CGContext interpolation** — `NSGraphicsContext.imageInterpolation` is silently ignored on macOS Big Sur+ Retina. Always set `cgCtx.interpolationQuality` directly.
- **`setMagnification(_:centeredAt:)`** — parameter label is `centeredAt:`, not `centeredAtPoint:` (renamed in recent SDK).
- **NSImage coordinate system** — `NSImage.draw(in:)` handles the macOS bottom-left origin automatically. Only manual-flip needed when drawing a raw `CGImage` via `cgContext.draw(_:in:)`.
- **Protocol + @MainActor** — delegate protocols called from NSScrollView subclasses must be marked `@MainActor` to avoid Swift 6 "crosses into main actor-isolated code" errors when the conforming type (e.g. NSViewController) is implicitly `@MainActor`.
- **Scroll geometry clamp** — for “scroll to top” in NSScrollView, use `docHeight - clipHeight` (clamped to `>= 0`), not raw `docHeight`.
- **NSScrollView unflipped coordinates — isAtTop/isAtBottom are counter-intuitive.** In macOS's default (non-flipped) coordinate system, the visual top corresponds to high Y values (`clipBounds.maxY >= docFrame.height`), and visual bottom to low Y values (`clipBounds.minY <= 0`). Easy to swap.
- **CALayer y-axis is flipped in layer-backed NSView.** When using `wantsLayer = true`, AppKit sets `layer.isGeometryFlipped = true` so `y=0` is the **visual top** (not bottom). Sublayer frames and `CAGradientLayer` startPoint/endPoint must account for this — the opposite of raw Core Animation convention.

## Window Sizing Gotchas

**Window restoration can produce unusable tiny windows.** On macOS, restored/saved state can reopen with near-zero content size. Enforce minimum content size, reject tiny persisted sizes, and run a post-show sanity check.

**Treat “title updates but image area looks empty” as a layout-size issue first.** Verify window/content/clip sizes before blaming decode logic.

## Scroll & Page-Turn Gotchas

**Trackpad vs mouse wheel need completely separate handling.** Trackpad events have a phase lifecycle (`.began`/`.changed`/`.ended`); mouse wheel events have no phase. Detect via `event.phase != [] || event.momentumPhase != []`. They need independent sensitivity thresholds (trackpad ~130pt, wheel ~20pt).

**Trackpad page-turn: require edge-start + accumulate + once-per-gesture.** Record whether the gesture began at an edge (`event.phase == .began`); only allow page turn if it started at edge, accumulated overscroll exceeds threshold, and at most one turn per gesture. Without edge-start check, mid-scroll momentum triggers false page turns.

**Momentum lock after page turn.** After triggering a page turn, suppress all scroll events for ~1s (`CACurrentMediaTime()` + duration). On trackpad, a new `.began` phase immediately unlocks. Without this, residual momentum scrolls the new image and can trigger a second page turn.

**Use `scrollerStyle = .overlay`** so scrollbars overlay content instead of consuming width, matching modern macOS behavior.

**Keyboard edge-press guard for all page-turn keys.** Arrow keys, PageUp/PageDown, and Space all require extra presses at the edge before turning page. Arrow keys use a higher threshold (3 presses) since each press is a small pan step; PageUp/PageDown/Space use threshold 1 (one confirmation press) since each press scrolls a full page and the intent is clearer. Logic: no overflow → navigate directly (no guard); overflow + not at edge → pan/scroll; overflow + at edge → edge-press counter. All implemented in `ImageScrollView.handleEdgePress(keyCode:threshold:)`.

**Edge indicator visual feedback.** `CAGradientLayer` overlays at viewport edges show page-turn progress (#F97068 coral gradient, opacity scales with press count). Auto-fade after 1.5s idle. Must call `resetEdgeState()` on any page navigation or direction change to prevent stale indicators.

## AppKit Menu Gotchas

**Cmd-key shortcuts vs keyDown — no duplication.** AppKit processes `performKeyEquivalent` (menu system) before `keyDown`. If a menu item has `keyEquivalent: "="` with `.command`, pressing `Cmd+=` fires the menu and `keyDown` is never called. Rule: Cmd-modified shortcuts live **only** in NSMenuItem keyEquivalents; bare keys (arrows, Space, Home/End) live **only** in `ImageScrollView.keyDown`.

**Go menu — Cmd+]/[ for Next/Prev; bare arrow keys in keyDown only.** Next/Previous Image have `keyEquivalent: "]"/"["` (Cmd-modified) so XCUITest can trigger them reliably via `app.typeKey("]", modifierFlags: .command)`. Home/End/arrows remain bare-key-only in `ImageScrollView.keyDown`; giving them menu equivalents would double-trigger.

**Navigation methods need `@objc`.** Any method referenced in `#selector` for menu routing must be `@objc`. Forgetting this causes a build error: "argument of #selector refers to instance method that is not exposed to Objective-C".

**`NSMenuItemValidation` not `override`.** Implement `func validateMenuItem(_:) -> Bool` via `NSMenuItemValidation` protocol conformance on the class declaration — do NOT use `override` (NSViewController has no such method to override).

**`@MainActor` on `@objc` methods in AppDelegate** that call `NSOpenPanel` or other main-actor-isolated AppKit APIs — add `@MainActor` to the method to silence Swift 6 isolation warnings.

## AppKit Key Event Gotcha

**Never put `keyDown(with:)` on NSViewController when NSScrollView is the first responder.**
NSScrollView internally intercepts arrow keys, Space, PageUp/PageDown and does NOT call `super.keyDown`. The VC sits *after* its view in the responder chain, so those events never reach it.

**Correct pattern:** Override `keyDown(with:)` on the `NSScrollView` subclass (the first responder) and delegate navigation actions back to the VC via the `ImageScrollViewDelegate` protocol. Call `window.makeFirstResponder(scrollView)` in `viewDidAppear`.

## XCUITest Gotchas (macOS)

**NSScrollView hit point is broken ({1,0}).** `setAccessibilityRole(.scrollArea)` on NSScrollView overrides the native role and corrupts the accessibility frame. Only set `setAccessibilityIdentifier`; never override `.scrollArea` role. Even without the override, `app.scrollViews["imageScrollView"].click()` fails — avoid clicking the scroll view in tests.

**Bare key events are unreliable in XCUITest macOS.** `app.typeKey(.rightArrow, modifierFlags: [])` may silently fail if the scroll view doesn't have accessibility focus. Use Cmd-modified menu shortcuts (`app.typeKey("]", modifierFlags: .command)`) for navigation — these route through `NSApp.performKeyEquivalent` and are reliable.

**`@MainActor` + async lifecycle for XCTestCase.** To avoid Swift 6 actor-isolation warnings on `XCUIApplication` / `XCUIElement` access, annotate the test class `@MainActor` and use `async` lifecycle: `override func setUp() async throws` and `override func tearDown() async throws`. Do NOT use `nonisolated(unsafe) var app`.

**Always assert `XCTWaiter` result.** `XCTWaiter().wait(...)` does NOT fail the test on timeout by itself — it returns `.timedOut`. Always capture the result and `XCTAssertEqual(result, .completed, ...)`.

**`TestMode` enum in `Cee/Utilities/TestMode.swift`.** App reads `--ui-testing` / `--reset-state` / `--disable-animations` from launch arguments and `UITEST_FIXTURE_PATH` from launch environment. The fixture path points to the first image; the app opens that file and discovers sibling images automatically.

## PDF Support

**PDF pages are expanded into individual `ImageItem` entries.** Each PDF page becomes a separate `ImageItem` with `pdfPageIndex` set (0-based). This means a 10-page PDF creates 10 items in the folder list, enabling standard prev/next navigation per page.

**PDF page count: Spotlight first, CGPDFDocument fallback.** `MDItemCopyAttribute(kMDItemNumberOfPages)` is near-instant for indexed files. Falls back to `CGPDFDocument.numberOfPages` if Spotlight metadata is unavailable.

**PDF rendering uses fixed 2x Retina scale.** No dynamic `backingScaleFactor` detection — almost all Macs are Retina, and 2x on non-Retina is harmless. Avoids complexity of tracking screen changes.

**Pixel limit guard (100M pixels) prevents OOM on huge pages.** `renderPDFPage` returns nil if `width * height > 100_000_000` (~400MB RGBA).

**PDF rotation handling.** `page.rotation` (0/90/180/270) requires swapping width/height for 90°/270° and applying CG transform (translate to center → rotate → translate back). The rotation angle is negated because CG's Y-axis points up.

**Cancelable prefetch tasks.** `prefetchTasks` and `imagePrefetchTasks` dictionaries track background `Task` instances keyed by `PDFCacheKey`/`URL`. `updateCache` cancels out-of-range tasks before starting new ones. `cancelAllPrefetchTasks()` clears everything on folder change.

**Last-viewed page persistence.** PDF page position is saved to `UserDefaults` with key `pdf.lastPage.\(url.path)` and restored on next open. Clamped to valid range.

**`ImageItem` is `Sendable`.** Required for passing items across actor boundaries to `ImageLoader.updateCache(currentIndex:items:)`.

**Window subtitle shows PDF page number.** `window?.subtitle` displays "Page N" for PDF items, empty string for images.

## Implementation Phases

| Phase | Status | Scope |
|-------|--------|-------|
| 1 — Project Setup + Display | ✅ done | XcodeGen, AppDelegate, Models, Services, Views, Controllers (basic) |
| 2 — Navigation | ✅ done | Keyboard nav, scroll-to-page, Natural Scrolling, edge detection |
| 3 — Menu + Settings | ✅ done | Full NSMenu, ViewerSettings (Codable struct, UserDefaults) |
| 4 — Window Behavior | ✅ done | Resize-to-fit, float on top, window size memory |
| 5 — Polish | ✅ done | Error handling, edge cases, perf validation |
| 6 — E2E Testing | ✅ done | XCUITest smoke suite passing, xcodegen UITests target |
| PDF Support | 🔄 in progress | PDF display, per-page navigation, prefetch, last-page memory |

## Mouse & Gesture Interaction Gotchas

**Cmd+scroll wheel = zoom, not scroll.** Intercepted at the top of `scrollWheel(with:)` before any other logic. Uses viewport center (matching pinch zoom), not cursor position. Sensitivity differs by device: `hasPreciseScrollingDeltas` distinguishes trackpad (0.003) from mouse wheel (0.08). Zoom direction does NOT follow Natural Scrolling — "scroll up = zoom in" always.

**Mouse drag pan: full mouseDown/mouseDragged/mouseUp chain.** `mouseDown` skips `super` (avoids NSScrollView's scroller modal tracking loop) and only activates drag when no modifier keys are held. `mouseDragged` MUST call `super` when not in drag mode — otherwise AppKit's event chain breaks for modifier-key clicks. `mouseUp` always calls `super`.

**NSCursor push/pop requires focus-loss safety.** If the window loses key status mid-drag, `mouseUp` won't fire. Monitor `NSWindow.didResignKeyNotification` (filtered to own window) to pop cursor and reset drag state. Also guard against double-push in `mouseDown`.

**`performPan(deltaX:deltaY:)` is the shared pan helper** used by both mouse drag and three-finger trackpad pan. Single implementation avoids drift between the two input methods.

**Swift 6: `deinit` cannot access stored properties** due to strict concurrency isolation. Don't try to add cleanup guards in `deinit` for properties like cursor state — use notification-based cleanup instead.

## Zoom & Fit Behavior

- **`alwaysFitOnOpen` takes precedence over `isManualZoom`** in `applyFitting`. Check fit flag first.
- **Zoom actions (`zoomIn`/`zoomOut`/`actualSize`) must call `resizeWindowToFitZoomedImage`** after applying magnification so the window tracks the new content size.
- **`toggleAlwaysFit` clears `isManualZoom`** and immediately applies fitting. `toggleResizeAutomatically` immediately resizes if enabled.
