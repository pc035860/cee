# Cee Implementation Plan

## Overview

Cee 是一個 macOS 原生看圖軟體，使用 Swift 6.2 + AppKit 開發，目標取代已停更的 XEE。專注於「右鍵開啟 → 資料夾瀏覽 → 縮放捲動」的核心流程。

## Tech Stack

| Item | Value |
|------|-------|
| Language | Swift 6.2 (Xcode 26) |
| UI | AppKit (NSScrollView, NSWindow) |
| Image Decoding | ImageIO (CGImageSource) |
| Target | macOS 14+, arm64 only |
| Project Gen | XcodeGen (`project.yml`) |
| Dependencies | None (pure Apple SDK) |

## Phase Summary

| Phase | Name | Duration | Key Deliverables |
|-------|------|----------|------------------|
| 1 | Project Setup + Image Display | 1 day | Xcode project, Open With, single image display with pinch zoom |
| 2 | Navigation & Scroll-to-Page | 1 day | Folder navigation, scroll paging, keyboard shortcuts |
| 3 | Menu System & Settings | 1 day | View/Go menus, Fitting Options, Scaling Quality, settings persistence |
| 4 | Window Behavior & Fullscreen | 0.5-1 day | Fullscreen, Float on Top, Resize Auto, window size memory |
| 5 | Polish & Performance | 0.5 day | Error handling, 1000-image perf test, edge cases, FR checklist |
| 6 | E2E UI Testing | 0.5-1 day | XCUITest smoke tests, test mode, accessibility IDs, test-e2e.sh |

## Dependencies

```
Phase 1 ──▶ Phase 2 ──▶ Phase 3 ──▶ Phase 4 ──▶ Phase 5 ──▶ Phase 6
                              │
                              └── Phase 3 的 ViewerSettings 被 Phase 4 使用
```

All phases are sequential. Each phase builds on the previous one.

## Session Strategy

| Session | Phases | Notes |
|---------|--------|-------|
| Session 1 | Phase 1 | Project scaffolding + core display pipeline |
| Session 2 | Phase 2 | Navigation is self-contained |
| Session 3 | Phase 3 | Menu and settings are tightly coupled |
| Session 4 | Phase 4 | Window behavior + fullscreen |
| Session 5 | Phase 5 | QA: 25 FR checks + edge cases + performance |
| Session 6 | Phase 6 | E2E UI Testing: smoke tests + test runner script |

## Project Structure (Final)

```
Cee/
├── project.yml                    # XcodeGen config
├── Cee/
│   ├── App/
│   │   ├── AppDelegate.swift          # 含 programmatic NSMenu setup
│   │   └── Info.plist                 # 無 NSMainNibFile（純程式碼菜單）
│   ├── Controllers/
│   │   ├── ImageWindowController.swift
│   │   └── ImageViewController.swift
│   ├── Views/
│   │   ├── ImageScrollView.swift
│   │   └── ImageContentView.swift
│   ├── Models/
│   │   ├── ImageFolder.swift
│   │   ├── ImageItem.swift
│   │   └── ViewerSettings.swift
│   ├── Services/
│   │   ├── ImageLoader.swift
│   │   └── FittingCalculator.swift
│   └── Utilities/
│       └── Constants.swift
├── CeeUITests/                    # UI Test target (Phase 6)
│   ├── CeeUITests.swift
│   ├── Helpers/
│   │   ├── WaitExtensions.swift
│   │   └── ScrollHelpers.swift
│   └── Fixtures/
│       └── Images/
├── scripts/
│   └── test-e2e.sh               # CLI test runner
├── specs/
│   └── init/
│       ├── PRD.md
│       ├── SPEC.md
│       └── overview.md (this file)
└── README.md
```

## Verification Criteria (Overall)

- [ ] Finder 右鍵 Open With → Cee → 1 秒內顯示圖片
- [ ] Pinch Zoom 流暢（10%~1000%）
- [ ] 捲動到底 → 翻頁 → 回到頂部，流程自然
- [ ] 所有 FR-001 ~ FR-025 功能正常
- [ ] 1000 張圖片資料夾：掃描 < 500ms、記憶體 < 500MB
- [ ] 設定跨重啟持久化（縮放模式、視窗大小、Fitting Options）
- [ ] `./scripts/test-e2e.sh` 一鍵 E2E smoke test 通過

## Key Technical Notes (from Spec Review)

1. **CGContext interpolation**: 必須用 `cgContext.interpolationQuality`，不用 `NSGraphicsContext.imageInterpolation`（Big Sur+ 已失效）
2. **Natural Scrolling**: 用 `event.isDirectionInvertedFromDevice` 判斷使用者實際捲動意圖
3. **Actor for ImageLoader**: 確保快取讀寫執行緒安全
4. **currentLoadRequestID**: UUID 防止快速翻頁時舊圖覆蓋新圖
5. **單視窗重用**: `ImageWindowController.shared` 靜態持有
6. **macOS 座標系**: 原點左下角，scrollToTop = scroll to maxY
7. **菜單方案**: 全程式碼建立（不用 XIB），AppDelegate 中 programmatic NSMenu setup
8. **首次視窗大小**: 使用螢幕可見區域 80%（PRD 要求），後續記憶上次大小
9. **E2E Testing**: `#if DEBUG` + `ProcessInfo` 混合方案，macOS 用 `scroll(byDeltaX:deltaY:)` 捲動，Cookpad-style wait extension
