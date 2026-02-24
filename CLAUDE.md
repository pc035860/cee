# Cee — CLAUDE.md

macOS image viewer (AppKit, Swift 6.2, arm64, Xcode 26).
Replaces XEE. Core flow: Finder right-click → Open With → folder browse → pinch zoom.

## Build

```bash
xcodegen generate          # regenerate .xcodeproj after project.yml changes
xcodebuild -project Cee.xcodeproj -scheme Cee -configuration Debug build
```

## Project Structure

```
Cee/
├── App/            AppDelegate.swift, main.swift, Info.plist
├── Controllers/    ImageWindowController, ImageViewController
├── Models/         ImageItem, ImageFolder
├── Services/       ImageLoader (actor), FittingCalculator
├── Views/          ImageScrollView, ImageContentView
├── Models/         ImageItem, ImageFolder, ViewerSettings
└── Utilities/      Constants.swift
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

**Go menu items have no `keyEquivalent`.** Arrow/Home/End keys are handled by `ImageScrollView.keyDown`. Setting them as menu keyEquivalents would double-trigger navigation.

**Navigation methods need `@objc`.** Any method referenced in `#selector` for menu routing must be `@objc`. Forgetting this causes a build error: "argument of #selector refers to instance method that is not exposed to Objective-C".

**`NSMenuItemValidation` not `override`.** Implement `func validateMenuItem(_:) -> Bool` via `NSMenuItemValidation` protocol conformance on the class declaration — do NOT use `override` (NSViewController has no such method to override).

**`@MainActor` on `@objc` methods in AppDelegate** that call `NSOpenPanel` or other main-actor-isolated AppKit APIs — add `@MainActor` to the method to silence Swift 6 isolation warnings.

## AppKit Key Event Gotcha

**Never put `keyDown(with:)` on NSViewController when NSScrollView is the first responder.**
NSScrollView internally intercepts arrow keys, Space, PageUp/PageDown and does NOT call `super.keyDown`. The VC sits *after* its view in the responder chain, so those events never reach it.

**Correct pattern:** Override `keyDown(with:)` on the `NSScrollView` subclass (the first responder) and delegate navigation actions back to the VC via the `ImageScrollViewDelegate` protocol. Call `window.makeFirstResponder(scrollView)` in `viewDidAppear`.

## Implementation Phases

| Phase | Status | Scope |
|-------|--------|-------|
| 1 — Project Setup + Display | ✅ done | XcodeGen, AppDelegate, Models, Services, Views, Controllers (basic) |
| 2 — Navigation | ✅ done | Keyboard nav, scroll-to-page, Natural Scrolling, edge detection |
| 3 — Menu + Settings | ✅ done | Full NSMenu, ViewerSettings (Codable struct, UserDefaults) |
| 4 — Window Behavior | pending | Resize-to-fit, float on top, window size memory |
| 5 — Polish | pending | Error handling, edge cases, perf validation |
| 6 — E2E Testing | pending | XCUITest smoke suite, xcodegen UITests target |
