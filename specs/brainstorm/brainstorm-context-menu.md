# Context Menu（右鍵選單）設計研究報告

**日期**：2026-03-02
**參與角色**：competitor-analyst、hig-researcher、usage-analyst、structure-researcher（4 人平行研究）
**實作進度**：Phase 1 完成

---

## 需求摘要

在圖片上右鍵點擊時顯示 context menu，提供 View menu bar 中常用功能的快速存取，以及 macOS 慣例的檔案操作。

**設計要求**：
1. 符合 Apple HIG context menu 規範
2. 是 menu bar 的精簡子集，不包含所有功能
3. 包含 macOS 慣例的檔案操作（Copy、Reveal in Finder、Open With）

---

## 一、Apple HIG 規範重點

### 核心原則
- **相關性優先**：只放使用者在當前情境最可能需要的指令
- **精簡數量**：不宜過長，**最多約 3 組**（separator 分隔）
- **Menu bar 的子集**：所有 context menu 項目必須同時存在於 menu bar
- **不顯示快捷鍵**：context menu 本身就是捷徑，顯示快捷鍵是多餘的
- **隱藏不可用項目**：不像 menu bar 用灰色顯示，context menu 直接隱藏不適用的項目
- **Submenu 最多 1 層**：超過 1 層會難以操作
- **Submenu 項目不超過 5 個**
- **破壞性操作放最後**：並標記為 destructive

### Checkmark 與 Toggle
- 用 **checkmark（✓）** 標示目前生效的屬性
- 可切換的項目可用 checkmark 或 label 變化（Show ↔ Hide）
- 互斥選項群組中，checkmark 標記當前選中項

**來源**：[Apple HIG - Context Menus](https://developer.apple.com/design/human-interface-guidelines/context-menus)、[Apple HIG - Menus](https://developer.apple.com/design/human-interface-guidelines/menus)

---

## 二、競品分析

### macOS 原生 App

| App | 右鍵選單內容 | 特色 |
|-----|------------|------|
| **Preview** | Copy、Share、Look Up、Services | 極度精簡，zoom/navigation 不放 |
| **Photos** | Copy/Paste、Share、Duplicate、Get Info、Rotate、Edit With、Set as Desktop、Delete | 較豐富，包含檔案操作 |
| **Finder（圖片檔）** | Quick Look、Open、Open With、Quick Actions（Rotate/Convert）、Copy、Share、Get Info | macOS 標準範本 |

### 第三方瀏覽器

| App | 右鍵選單風格 | 說明 |
|-----|------------|------|
| **XEE** | 精簡 | 主要靠 menu bar |
| **IrfanView**（Windows） | 塞滿功能 | 幾乎複製整個 menu bar，違反 HIG |
| **FastStone**（Windows） | 邊緣浮動面板 | 不用傳統右鍵選單 |

### 共通模式
- **一定有**：Copy、Share
- **常見**：Rotate、Open With、Reveal in Finder、Get Info
- **幾乎不放**：Zoom 控制、Navigation、View mode 設定、Quality/Sensitivity 設定

**關鍵發現**：Apple 原生 app 的右鍵選單極度精簡。Cee 作為 macOS app，應遵循此風格，但可適度加入 view toggle（因為 Cee 是 image viewer 而非 editor）。

**來源**：[Apple Support - Preview](https://support.apple.com/guide/preview/)、[XnView Forum](https://newsgroup.xnview.com/viewtopic.php?t=35327)

---

## 三、使用頻率與適合度分析

### 功能分類評估

| 功能 | 使用頻率 | 類型 | 有快捷鍵？ | 推薦放入？ | 理由 |
|------|---------|------|-----------|-----------|------|
| Fit on Screen | 高 | 每張圖操作 | ⌘0 | ✅ Yes | 最常用的 zoom 動作 |
| Actual Size | 高 | 每張圖操作 | ⌘1 | ✅ Yes | 核心 zoom 動作 |
| Zoom In/Out | 中 | 每次操作 | ⌘+/⌘-、pinch | ❌ No | Pinch/scroll 已夠快 |
| Always Fit on Open | 中 | 切換模式 | ⌘* | ✅ Yes | 瀏覽中會切換 |
| Fitting Options | 低 | 設一次 | 無 | ❌ No | 偏好設定，極少更改 |
| Scaling Quality | 低 | 設一次 | 無 | ❌ No | 技術性設定 |
| Trackpad/Wheel Sensitivity | 低 | 設一次 | 無 | ❌ No | 偏好設定 |
| Resize Window Auto | 低 | 切換模式 | 無 | ❌ No | 低頻切換 |
| Enter Full Screen | 高 | 切換模式 | ⌘F + 綠色按鈕 | ❌ No | 已有多種快速存取方式 |
| Float on Top | 中 | 切換模式 | **無** | ✅ Yes | 右鍵是最快路徑 |
| Show Status Bar | 低 | 切換模式 | ⌘/ | ❌ No | 有快捷鍵，低頻 |
| Dual Page | 中 | 切換模式 | ⌘K | ✅ Yes | 漫畫瀏覽常切換 |
| First Page as Cover | 低 | Dual 子設定 | ⌘⇧O | ✅ Submenu | Dual Page 啟用時才顯示 |
| Reading Direction | 低 | Dual 子設定 | ⌘⇧K | ✅ Submenu | Dual Page 啟用時才顯示 |
| Next/Prev Image | 高 | 每次操作 | 方向鍵、⌘]/[ | ❌ No | 鍵盤/手勢主導 |

### 新增功能（目前 Cee 尚未實作）

| 功能 | macOS 慣例程度 | 推薦放入？ | 理由 |
|------|--------------|-----------|------|
| Copy Image | 極高（macOS 標配） | ✅ Yes | 所有 macOS app 的右鍵選單基本都有 |
| Reveal in Finder | 高 | ✅ Yes | 檔案瀏覽器常見操作 |
| Open With | 高 | ✅ Yes（submenu） | macOS 標準檔案操作 |

**來源**：[NN/g - Contextual Menus Guidelines](https://www.nngroup.com/articles/contextual-menus-guidelines/)、[Icons8 - Hotkeys vs Context Menu](https://icons8.com/blog/articles/the-ux-dilemma-hotkeys-vs-context-menus/)

---

## 四、選單結構設計

### 最終推薦方案

```
┌─────────────────────────────┐
│ Fit on Screen               │  ← Group 1: Zoom（最常用）
│ Actual Size                 │
│ ─────────────────────────── │
│ ✓ Always Fit on Open        │  ← Group 2: Display Mode
│ ✓ Dual Page               ▸ │  ← submenu（包含子設定）
│   ├ ✓ Dual Page             │
│   ├ ─────────────────────── │
│   ├   First Page as Cover   │
│   └ ✓ Right to Left         │
│ ✓ Float on Top              │
│ ─────────────────────────── │
│ Copy Image                  │  ← Group 3: File Actions（macOS 慣例）
│ Reveal in Finder            │
│ Open With                 ▸ │  ← submenu（系統可開啟的 app 列表）
└─────────────────────────────┘
```

### 設計決策說明

| 決策 | 理由 |
|------|------|
| **3 組分隔** | 符合 HIG 建議的最大分組數 |
| **Zoom 放第一組** | 最高頻操作，靠近點擊位置 |
| **Dual Page 用 submenu** | 子設定只在 Dual Page 模式下有意義，避免主選單過長 |
| **Float on Top 放入** | 無快捷鍵，右鍵選單是最快存取路徑 |
| **不放 Navigation** | 鍵盤/手勢已完整覆蓋，context menu 應聚焦「設定」而非「導航」 |
| **不放 Fullscreen** | ⌘F + 視窗綠色按鈕已提供快速存取 |
| **不放 Show Status Bar** | 有 ⌘/ 快捷鍵且低頻，不值得佔位 |
| **不顯示快捷鍵** | Apple HIG 明確建議 context menu 不顯示快捷鍵 |
| **Checkmark 標示狀態** | Toggle 項目用 ✓ 表示目前生效 |
| **File Actions 放最後** | 較不常用，且與「檢視」主題稍遠 |

### Dual Page Submenu 細節

當 Dual Page **關閉**時：
- submenu 仍可展開，但 First Page as Cover 和 Reading Direction 顯示為灰色（disabled）

當 Dual Page **開啟**時：
- 所有子項目可用
- Reading Direction 的 label 反映當前狀態：「Right to Left」或「Left to Right」

---

## 五、實作需求

### 需要新增的功能（目前 Cee 未實作）

1. **Copy Image**：將當前顯示的圖片複製到系統剪貼簿（`NSPasteboard`）
2. **Reveal in Finder**：用 `NSWorkspace.shared.activateFileViewerSelecting([url])` 開啟 Finder 並選中檔案
3. **Open With submenu**：用 `NSWorkspace.shared.urlsForApplications(toOpen:)` 取得可開啟的 app 列表

### 關鍵檔案

| 檔案 | 角色 | 改動類型 |
|------|------|---------|
| `Cee/Views/ImageScrollView.swift` | 右鍵選單掛載點 | 新增 `menu(for:)` |
| `Cee/Controllers/ImageViewController.swift` | 選單動作處理 + `validateMenuItem` | 新增方法 |
| `Cee/App/AppDelegate.swift` | Menu bar（File menu 新增 Copy/Reveal） | 小改 |
| `Cee/Models/ImageItem.swift` | `url` 屬性供檔案操作使用 | 不改 |
| `Cee/Models/ImageFolder.swift` | `currentImage` 供取得當前檔案 URL | 不改 |

### 既有基礎設施（可直接復用）

- **`NSMenuItemValidation`**（`ImageViewController.swift:968-1035`）：已實作所有 toggle 的 checkmark 同步，新選單項目會自動受管理
- **First responder chain**：AppDelegate 中所有菜單項目 `target = nil`，context menu 可用相同機制路由 action
- **Toggle 方法**：`toggleAlwaysFit`、`toggleDualPage`、`toggleFloatOnTop`、`toggleReadingDirection`、`togglePageOffset` 皆已實作
- **Zoom 方法**：`fitOnScreen`、`actualSize` 已實作
- **ImageItem.url**：提供檔案 URL，供 Copy/Reveal/OpenWith 使用

---

## 六、實作計畫

### Phase 1：基礎右鍵選單框架 + 已有功能

**目標**：右鍵點擊圖片出現選單，包含所有已實作的功能項目。

**改動檔案**：
- `ImageScrollView.swift` — 新增 `menu(for:)` override
- `ImageViewController.swift` — 新增 `buildContextMenu()` 方法

**實作內容**：

1. 在 `ImageScrollView` 中 override `menu(for event: NSEvent) -> NSMenu?`
   - 透過 `ImageScrollViewDelegate` 向 `ImageViewController` 請求選單
   - Delegate 新增 `func contextMenu(for scrollView: ImageScrollView) -> NSMenu?`

2. 在 `ImageViewController` 中建構選單：
   ```
   ┌─────────────────────────────┐
   │ Fit on Screen               │  ← Group 1: Zoom
   │ Actual Size                 │
   │ ─────────────────────────── │
   │ ✓ Always Fit on Open        │  ← Group 2: Display Mode
   │ ✓ Dual Page               ▸ │  ← submenu
   │   ├ ✓ Dual Page             │
   │   ├ ─────────────────────── │
   │   ├   First Page as Cover   │
   │   └ ✓ Right to Left         │
   │ ✓ Float on Top              │
   └─────────────────────────────┘
   ```

3. 選單項目 action/target 設定：
   - `target = nil`（走 first responder chain，與 menu bar 一致）
   - Action 指向 `ImageViewController` 既有的 `@objc` 方法
   - `validateMenuItem` 自動處理 checkmark 狀態

4. Dual Page submenu 邏輯：
   - 主 toggle「Dual Page」永遠可用
   - 「First Page as Cover」和 Reading Direction 在 `validateMenuItem` 中：`dualPageEnabled ? true : false`（disabled 但不隱藏）
   - Reading Direction label 動態切換：「Right to Left」↔「Left to Right」（已有邏輯）

**驗收條件**：
- [x] 右鍵點圖片出現選單
- [x] Fit on Screen / Actual Size 正常運作
- [x] Always Fit、Dual Page、Float on Top 的 checkmark 正確反映狀態
- [x] Dual Page submenu 展開，子項目在 dual page 關閉時為灰色
- [x] 選單項目不顯示快捷鍵（符合 HIG）

---

### Phase 2：Copy Image + Reveal in Finder

**目標**：新增 macOS 慣例的檔案操作功能。

**改動檔案**：
- `ImageViewController.swift` — 新增 `copyImage`、`revealInFinder` 方法
- `AppDelegate.swift` — File menu 新增 Copy Image、Reveal in Finder（menu bar 也要有）
- Context menu 加入第三組

**實作內容**：

1. **Copy Image**（`copyImage(_:)`）：
   ```swift
   @objc func copyImage(_ sender: Any?) {
       guard let item = imageFolder?.currentImage else { return }
       let pb = NSPasteboard.general
       pb.clearContents()
       // 寫入檔案 URL（讓 Finder 可貼上檔案）
       pb.writeObjects([item.url as NSURL])
       // 同時寫入圖片資料（讓圖片編輯器可貼上）
       if let image = imageContentView.layer?.contents as? CGImage {
           let rep = NSBitmapImageRep(cgImage: image)
           if let tiffData = rep.tiffRepresentation {
               pb.setData(tiffData, forType: .tiff)
           }
       }
   }
   ```

2. **Reveal in Finder**（`revealInFinder(_:)`）：
   ```swift
   @objc func revealInFinder(_ sender: Any?) {
       guard let item = imageFolder?.currentImage else { return }
       NSWorkspace.shared.activateFileViewerSelecting([item.url])
   }
   ```

3. **validateMenuItem 擴充**：
   - `copyImage` / `revealInFinder`：當 `imageFolder?.currentImage != nil` 時啟用

4. **Menu bar 同步**（HIG 要求）：
   - File menu 新增 `Copy Image`（⌘C）和 `Reveal in Finder`（⌘⇧R）
   - 注意：⌘C 需確認不與系統 Copy 衝突（可能改用 ⌘⇧C 或不設快捷鍵）

5. **Context menu 更新**：
   ```
   │ ─────────────────────────── │
   │ Copy Image                  │  ← Group 3: File Actions
   │ Reveal in Finder            │
   ```

**驗收條件**：
- [ ] Copy Image 後可在 Finder 貼上檔案、在圖片編輯器貼上圖片
- [ ] PDF 頁面的 Copy Image 正確複製當前頁的渲染結果
- [ ] Reveal in Finder 開啟 Finder 並選中當前檔案
- [ ] 無圖片時兩項都 disabled
- [ ] Menu bar File menu 也有對應項目

---

### Phase 3：Open With Submenu

**目標**：列出系統中可開啟當前檔案類型的應用程式，點選後用該 app 開啟。

**改動檔案**：
- `ImageViewController.swift` — 新增 `openWith` 相關方法
- Context menu 加入 Open With submenu

**實作內容**：

1. **查詢可用 App**：
   ```swift
   func buildOpenWithSubmenu(for url: URL) -> NSMenu {
       let menu = NSMenu(title: "Open With")
       let appURLs = NSWorkspace.shared.urlsForApplications(toOpen: url)

       // 取得預設 app
       let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)

       for appURL in appURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
           let appName = FileManager.default.displayName(atPath: appURL.path)
           let item = NSMenuItem(title: appName, action: #selector(openWithApp(_:)), keyEquivalent: "")
           item.representedObject = appURL
           item.target = nil
           // 預設 app 標記粗體或加上 "(Default)"
           if appURL == defaultApp {
               item.attributedTitle = NSAttributedString(string: appName + " (Default)",
                   attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
           }
           // App icon
           item.image = NSWorkspace.shared.icon(forFile: appURL.path)
           item.image?.size = NSSize(width: 16, height: 16)
           menu.addItem(item)
       }
       return menu
   }
   ```

2. **開啟動作**（`openWithApp(_:)`）：
   ```swift
   @objc func openWithApp(_ sender: NSMenuItem) {
       guard let appURL = sender.representedObject as? URL,
             let item = imageFolder?.currentImage else { return }
       NSWorkspace.shared.open([item.url],
           withApplicationAt: appURL,
           configuration: NSWorkspace.OpenConfiguration())
   }
   ```

3. **Context menu 最終結構**：
   ```
   ┌─────────────────────────────┐
   │ Fit on Screen               │
   │ Actual Size                 │
   │ ─────────────────────────── │
   │ ✓ Always Fit on Open        │
   │   Dual Page               ▸ │
   │ ✓ Float on Top              │
   │ ─────────────────────────── │
   │ Copy Image                  │
   │ Reveal in Finder            │
   │ Open With                 ▸ │
   └─────────────────────────────┘
   ```

4. **效能考量**：
   - `urlsForApplications(toOpen:)` 可能較慢（首次查詢）
   - Submenu 用 lazy 建構：在 `NSMenuDelegate.menuNeedsUpdate` 時才查詢
   - 或在選單即將顯示時（`menu(for:)` 呼叫時）同步建構（項目通常 < 20 個，可接受）

**驗收條件**：
- [ ] Open With submenu 列出所有可開啟當前檔案類型的 app
- [ ] 預設 app 有視覺標記（粗體或 Default 標籤）
- [ ] 每個 app 項目顯示 icon
- [ ] 點選後用對應 app 開啟當前檔案
- [ ] PDF 檔案列出的 app 正確（PDF 閱讀器，非圖片編輯器）
- [ ] 無圖片時 submenu disabled

---

## 參考來源

- [Apple HIG - Context Menus](https://developer.apple.com/design/human-interface-guidelines/context-menus)
- [Apple HIG - Menus](https://developer.apple.com/design/human-interface-guidelines/menus)
- [NN/g - 10 Guidelines for Contextual Menus](https://www.nngroup.com/articles/contextual-menus-guidelines/)
- [NN/g - Contextual Menus: Delivering Relevant Tools](https://www.nngroup.com/articles/contextual-menus/)
- [Icons8 - Hotkeys vs Context Menu UX](https://icons8.com/blog/articles/the-ux-dilemma-hotkeys-vs-context-menus/)
- [Mobbin - Context Menu UI Design](https://mobbin.com/glossary/context-menu)
- [Height - Guide to Building Context Menus](https://height.app/blog/guide-to-build-context-menus)
