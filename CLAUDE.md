# Cee — CLAUDE.md

macOS image viewer (AppKit, Swift 6.2, arm64, Xcode 26).
Replaces XEE. Core flow: Finder right-click → Open With → folder browse → pinch zoom.

## Build & Test

```bash
xcodegen generate          # regenerate .xcodeproj after project.yml changes
xcodebuild -project Cee.xcodeproj -scheme Cee -configuration Debug build
./scripts/test-e2e.sh      # run all 7 XCUITest smoke tests
```

## Project Structure

```
Cee/
├── App/            AppDelegate.swift, main.swift, Info.plist
├── Controllers/    ImageWindowController, ImageViewController
├── Models/         ImageItem, ImageFolder, ViewerSettings
├── Services/       ImageLoader (actor), FittingCalculator
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

## Swift 6 Gotchas

- **`ImageLoader` is an `actor`** — never pass `ImageFolder` (a non-Sendable class) across actor boundaries. Use value types: `updateCache(currentIndex: Int, imageURLs: [URL])`.
- **CGContext interpolation** — `NSGraphicsContext.imageInterpolation` is silently ignored on macOS Big Sur+ Retina. Always set `cgCtx.interpolationQuality` directly.
- **`setMagnification(_:centeredAt:)`** — parameter label is `centeredAt:`, not `centeredAtPoint:` (renamed in recent SDK).
- **NSImage coordinate system** — `NSImage.draw(in:)` handles the macOS bottom-left origin automatically. Only manual-flip needed when drawing a raw `CGImage` via `cgContext.draw(_:in:)`.
- **Protocol + @MainActor** — delegate protocols called from NSScrollView subclasses must be marked `@MainActor` to avoid Swift 6 "crosses into main actor-isolated code" errors when the conforming type (e.g. NSViewController) is implicitly `@MainActor`.

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

## Implementation Phases

| Phase | Status | Scope |
|-------|--------|-------|
| 1 — Project Setup + Display | ✅ done | XcodeGen, AppDelegate, Models, Services, Views, Controllers (basic) |
| 2 — Navigation | ✅ done | Keyboard nav, scroll-to-page, Natural Scrolling, edge detection |
| 3 — Menu + Settings | ✅ done | Full NSMenu, ViewerSettings (Codable struct, UserDefaults) |
| 4 — Window Behavior | ✅ done | Resize-to-fit, float on top, window size memory |
| 5 — Polish | ✅ done | Error handling, edge cases, perf validation |
| 6 — E2E Testing | ✅ done | XCUITest smoke suite (7/7 passing), xcodegen UITests target |
