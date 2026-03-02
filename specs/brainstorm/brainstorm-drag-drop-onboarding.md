# Brainstorm: Drag-and-Drop Onboarding (Empty State + Drop to Open)

## 概述

當 Cee 啟動但未載入任何圖片時，顯示一個 onboarding 介面，讓使用者可以拖曳圖片進入視窗。同時在瀏覽圖片時，也支援拖入新圖片來切換資料夾。

## 動機

- 目前啟動 App 不帶檔案時，沒有任何視窗出現，使用者不知道 App 是否已經啟動
- 提供直覺的「拖曳圖片進來」互動，降低使用門檻
- 瀏覽中拖入新圖片可快速切換資料夾，提升工作流

---

## 研究發現

### 1. macOS Drag-and-Drop API

#### 核心協議：NSDraggingDestination

NSView 和 NSWindow 都已遵循此協議，只需 override 相關方法。

**生命週期：**
```
drag enters view → draggingEntered(_:)     → return .copy / empty
drag moves       → draggingUpdated(_:)     → (optional)
drag exits       → draggingExited(_:)      → cleanup highlight
user drops       → prepareForDragOperation → return true
                 → performDragOperation    → extract URLs, handle
                 → concludeDragOperation   → final cleanup
```

#### 類型註冊

```swift
// 註冊接受檔案 URL（涵蓋所有從 Finder 拖曳的檔案）
registerForDraggedTypes([.fileURL])
```

只需 `.fileURL` 即可處理 Finder 拖曳，在 handler 中用 UTType 過濾：

```swift
func isSupported(_ url: URL) -> Bool {
    guard let uttype = UTType(filenameExtension: url.pathExtension) else { return false }
    return uttype.conforms(to: .image) || uttype.conforms(to: .pdf)
}
```

#### URL 提取（推薦方式）

```swift
let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
    .urlReadingFileURLsOnly: true
]) as? [URL]
```

#### Swift 6 注意事項

- NSDraggingDestination 方法在 MainActor 上執行（NSView 是 `@MainActor` isolated）
- `NSDraggingInfo` 不是 `Sendable`，必須在主線程同步提取所有資料
- `ImageFolder` 是 non-Sendable class，所有操作保持在 `@MainActor`
- 非同步工作（如 ImageLoader）用 `Task { @MainActor in }` dispatch

#### NSView-level vs NSWindow-level

| 面向 | NSWindow | NSView |
|------|----------|--------|
| 命中區域 | 整個視窗 | 特定 view bounds |
| 多區域支援 | 單一 handler | 不同 view 不同 handler |
| Cee 建議 | — | ✅ ImageScrollView（與現有 input handling 一致） |

**建議**：在 `ImageScrollView` 上註冊（涵蓋整個內容區域），透過 `ImageScrollViewDelegate` 委派處理。

### 2. Empty State UI 設計

#### 主流 macOS App 做法

- **Apple Preview / Pixelmator / Affinity Photo**：Document-based 架構，無檔案時顯示 Open Dialog 或還原上次 session
- **Cee 的差異**：單視窗重用模式（`ImageWindowController.shared`），必須自行處理空狀態

#### 推薦設計：置中 Placeholder View

```
┌──────────────────────────────┐
│                              │
│                              │
│         ┌──────────┐         │
│         │  📷 icon │         │  SF Symbol, 48pt, hierarchical
│         └──────────┘         │
│                              │
│    Drop images here to view  │  16pt, .secondaryLabelColor
│    Or use File › Open (⌘O)   │  13pt, .tertiaryLabelColor
│                              │
│                              │
└──────────────────────────────┘
```

**拖曳中高亮：**
```
┌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┐
╎                              ╎
╎         ┌──────────┐         ╎  accent-colored dashed border
╎         │  📷 icon │         ╎
╎         └──────────┘         ╎
╎                              ╎
╎    Drop images here to view  ╎
╎    Or use File › Open (⌘O)   ╎
╎                              ╎
└╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┘
```

#### 視覺元素

| 元素 | 規格 | 說明 |
|------|------|------|
| Icon | SF Symbol `photo.on.rectangle.angled`, 48pt | `.hierarchical` rendering, `.secondaryLabelColor` |
| 主文字 | "Drop images here to view", 16pt | `.secondaryLabelColor`, system font |
| 副文字 | "Or use File › Open (⌘O)", 13pt | `.tertiaryLabelColor`, system font |
| 拖曳框線 | 2pt dashed, `controlAccentColor` | 僅在 `draggingEntered` 時顯示 |

#### 設計原則

- 使用語義化系統顏色（自動適配 Dark Mode + Accessibility）
- 不使用自訂顏色
- 遵循 Apple ContentUnavailableView 視覺層級：Icon → Title → Description
- 低調、不搶眼的外觀

#### 狀態轉換動畫

```swift
// 隱藏 empty state (0.25s fade out)
NSAnimationContext.runAnimationGroup({ context in
    context.duration = 0.25
    emptyStateView.animator().alphaValue = 0.0
}) {
    emptyStateView.isHidden = true
}
```

### 3. 架構整合方案

#### 核心決策：Empty State View 放在哪裡？

**✅ 推薦：ImageViewController 內的 Overlay View**

理由：
- `ImageWindowController` 使用 static singleton，換 `contentViewController` 會與 reuse check 衝突
- 已有 `ErrorPlaceholderView` overlay 先例，empty state 用同樣模式
- 單一 window controller，不需要額外複雜度

#### 修改清單

##### 新增檔案

| 檔案 | 類型 | 用途 |
|------|------|------|
| `Cee/Views/EmptyStateView.swift` | NSView | 程式化「拖曳圖片到這裡」placeholder |

##### 修改檔案

| 檔案 | 變更 |
|------|------|
| `ImageViewController.swift` | `folder` 改為 optional、empty state overlay 邏輯、drag 註冊 |
| `ImageWindowController.swift` | 新增 `openEmpty()` static method、expose shared nil check |
| `AppDelegate.swift` | 新增 `applicationOpenUntitledFile(_:)` 顯示空視窗 |
| `ImageScrollView.swift` | 註冊 `registerForDraggedTypes`、delegate drag events |
| `project.yml` | 加入新 source file |

#### AppDelegate 啟動流程

```swift
// 最佳方案：applicationOpenUntitledFile
// macOS 在啟動/啟用 App 但無文件時自動呼叫
func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
    ImageWindowController.openEmpty()
    return true
}
```

#### ImageWindowController 變更

```swift
// 新增：空狀態啟動
static func openEmpty() {
    if let existing = shared {
        existing.window?.makeKeyAndOrderFront(nil)
        return
    }
    let viewController = ImageViewController(folder: nil)  // nil folder
    // ... 建立視窗（同 open(with:)）...
    // title = "Cee"
}

// 既有 open(with:) 不變
// 呼叫 vc.loadFolder() 時自動隱藏 empty state
```

#### Drag-and-Drop 註冊位置

| 位置 | 場景 | Phase |
|------|------|-------|
| `EmptyStateView` | 空狀態時的拖曳區域 | MVP (Phase 1) |
| `ImageScrollView` | 瀏覽中拖入新圖片 | Phase 2 |

兩者都用 `.fileURL` + UTType 過濾，透過 delegate 或直接呼叫 `ImageWindowController.open(with:)`。

#### 狀態轉換表

| From | To | Trigger | Action |
|------|----|---------|--------|
| Empty | Image loaded | Drop 或 Open With | `open(with:)` → `loadFolder()` → hide empty state |
| Browsing | New folder | Drop 新圖片 | `open(with:)` → reuse window → `loadFolder()` |
| Browsing | Empty | N/A (MVP 不需要) | 暫不實作 |

---

## MVP 分階段規劃

### Phase 1 — 基礎可用版（MVP 核心）

1. **`EmptyStateView`** — 置中 icon + 文字 + 拖曳高亮
2. **`ImageWindowController.openEmpty()`** — 無檔案時開啟空視窗
3. **`AppDelegate.applicationOpenUntitledFile`** — 系統回呼
4. **`ImageViewController` optional folder** — 支援 nil folder + empty state overlay
5. **Drag-and-drop on EmptyStateView** — 拖曳檔案開啟圖片

### Phase 2 — 瀏覽中拖曳

6. **`ImageScrollView` drag-and-drop** — 瀏覽中拖入新圖片切換資料夾
7. **視覺拖曳回饋** — highlight border overlay

### Phase 3 — 精緻化

8. **狀態轉換動畫** — fade in/out
9. **最近檔案列表** — empty state 中顯示（可選）

---

## 影響評估

- **低風險**：所有變更都是 additive，既有 `open(with:)` 路徑不受影響
- **`ImageFolder` 不需修改**：永遠需要 file URL，empty state 概念在 VC 層處理
- **`ImageViewController.folder` optional**：最大變更。需要 null check（`loadCurrentImage`、`updateStatusBar`、navigation）。但多數已有 guard（`folder.currentImage`、`folder.images.isEmpty`）
- **Menu validation**：`validateMenuItem` 需處理 nil folder（disable nav items）

---

## 參考來源

### API & 實作
- [Apple - Receiving Drag Operations](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/DragandDrop/Tasks/acceptingdrags.html)
- [Apple - NSView.registerForDraggedTypes](https://developer.apple.com/documentation/appkit/nsview/registerfordraggedtypes(_:))
- [Apple - NSWindow.registerForDraggedTypes](https://developer.apple.com/documentation/appkit/nswindow/registerfordraggedtypes(_:))
- [Kodeco Drag-and-Drop Tutorial](https://www.kodeco.com/1016-drag-and-drop-tutorial-for-macos)
- [AppCoda NSPasteboard](https://www.appcoda.com/nspasteboard-macos/)
- [GitHub - DSFDropFilesView](https://github.com/dagronf/DSFDropFilesView)
- [GitHub - onmyway133 drag-drop NSView](https://github.com/onmyway133/blog/issues/410)

### UI 設計
- [Apple ContentUnavailableView](https://developer.apple.com/documentation/SwiftUI/ContentUnavailableView)
- [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/)
- [SF Symbols](https://developers.apple.com/sf-symbols)
- [Mobbin Empty State Patterns](https://mobbin.com/glossary/empty-state)

### Swift 6 Concurrency
- [Approachable Concurrency in Swift 6.2](https://www.avanderlee.com/concurrency/approachable-concurrency-in-swift-6-2-a-clear-guide/)
- [NSView Animation Guide](https://www.advancedswift.com/nsview-animations-guide/)
- [Programmatic macOS App Setup](https://sarunw.com/posts/how-to-create-macos-app-without-storyboard/)
