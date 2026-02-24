# macOS 看圖軟體 — 腦力激盪報告

**日期**：2026-02-24
**參與角色**：Native 提案者、Tauri 提案者、Web 提案者、技術研究員、Devil's Advocate

---

## 需求摘要

製作一個類似 XEE 的 macOS 看圖軟體，核心功能：

1. **右鍵開啟**：右鍵點擊圖片 → Open With → 自動載入該圖及同資料夾所有圖片
2. **縮放持久化**：Pinch Zoom 設定縮放等級後，切換圖片時保持固定
3. **捲動翻頁**：捲動到底自動切換下一張，回到頂部繼續看圖

---

## 市場背景（研究結果）

| 項目 | 內容 |
|------|------|
| **XEE 現狀** | 最後更新 2021-12-21，無 Apple Silicon 原生支援，Rosetta 2 執行，圖片偶爾無法顯示 |
| **市場缺口** | Reddit 大量 macOS 用戶抱怨 Preview 不夠直觀，需「快速開啟 + 資料夾瀏覽」 |
| **現有替代** | XnView MP（功能多但重）、qView（極簡但缺功能）、FlowVision（SwiftUI 開源，瀑布流非連續瀏覽）|
| **開源參考** | FlowVision（Swift, 698 stars）、tauview / Electro（Tauri）、ViewSkater（Rust + GPU） |

---

## 三方案總覽

### 方案 A：Native macOS（SwiftUI + AppKit 混合）

| 面向 | 評估 |
|------|------|
| **右鍵整合** | 最佳：Info.plist + `application(_:open:)` delegate，原生支援 |
| **縮放** | NSScrollView `magnification` 屬性，trackpad pinch 自動處理 |
| **捲動翻頁** | `scrollWheel(with:)` 偵測到底，行為完全可控 |
| **圖片格式** | HEIC、RAW、WebP 全部原生支援，無需額外 codec |
| **App 大小** | 5-20 MB |
| **預估工時** | 提案 30h → 批判者修正為 45-60h（若非 Swift 開發者） |

**Devil's Advocate 批判**：
- SwiftUI + AppKit 混合架構的座標系統衝突不容小覷（SwiftUI 原點左上，AppKit 原點左下）
- 建議改用**純 AppKit**，行為更可預測，避免橋接問題
- Swift 6 Strict Concurrency 對前端開發者是全新心智模型
- 30h 預估過於樂觀，但仍是三方案中最確定能完成的

### 方案 B：Tauri v2（Rust + Svelte + Vite）

| 面向 | 評估 |
|------|------|
| **右鍵整合** | 可行：`bundle.fileAssociations` + `RunEvent::Opened` |
| **縮放** | CSS transform scale + wheel event（ctrlKey），需手動處理慣性 |
| **捲動翻頁** | scroll event 偵測，前端實現 |
| **圖片格式** | WKWebView 支援 HEIC（Safari 引擎），WebP 亦可 |
| **App 大小** | 3-15 MB（最小可 < 1 MB） |
| **預估工時** | 約 40-50h |

**Devil's Advocate 批判**：
- WKWebView 的 pinch zoom **無法達到 native 體驗**（缺少慣性物理模型）
- `RunEvent::Opened` 在 frontend 就緒前觸發，需 AppState 暫存 + 雙方握手，非「少量 Rust」
- 「只需少量 Rust」嚴重低估：實際至少 200-400 行 Rust + 10-15h 學習
- Intel Mac segfault issue（#11912）仍 open，影響部分用戶
- 簽名公證流程繁瑣

### 方案 C：Pure Web App / PWA

| 面向 | 評估 |
|------|------|
| **右鍵整合** | 幾乎不可能：僅 Chrome 安裝的 PWA 支援 file_handlers，Safari 完全不行 |
| **同資料夾載入** | 需二次操作（showDirectoryPicker），無法自動 |
| **HEIC** | Chrome 不支援，需 JS 解碼，效能差 |

**結論：直接淘汰。** 無法滿足「右鍵開啟 + 自動載入同資料夾」的核心需求。

---

## Devil's Advocate 排序

### 按「完成核心需求的確定性」

| 排名 | 方案 | 理由 |
|------|------|------|
| 1 | **A（Native）** | 所有核心功能都有成熟、穩定的 API 支援 |
| 2 | **B（Tauri）** | 可行但有 WKWebView 限制和 Rust 學習曲線 |
| 3 | C（Web） | 無法達成核心需求 |

### 按「前端開發者友善度」

| 排名 | 方案 | 理由 |
|------|------|------|
| 1 | **B（Tauri）** | 前端技術棧為主，Rust 為輔 |
| 2 | A（Native） | 需學 Swift + AppKit，門檻較高 |
| 3 | C（Web） | 最熟悉但功能受限 |

### 按「長期維護性」

| 排名 | 方案 | 理由 |
|------|------|------|
| 1 | **A（Native）** | Apple 自家框架，macOS 每次更新都會維護相容性 |
| 2 | B（Tauri） | 依賴 Tauri 團隊持續維護，WKWebView 行為可能隨 macOS 更新改變 |
| 3 | C（Web） | 不適用 |

---

## 被忽略的方案

| 方案 | 評估 |
|------|------|
| **純 AppKit（不混 SwiftUI）** | Devil's Advocate 推薦，避免座標系統衝突，文件/範例更多 |
| **Flutter for macOS** | 自帶渲染引擎，但 macOS 支援成熟度不如 native，Open With 整合需繞路 |
| **Kotlin Multiplatform** | macOS 支援極不成熟，不建議 |
| **Rust + Iced/egui** | ViewSkater 證明可行，但 GUI 生態不如 Swift/Web 成熟 |

---

## 最終建議

### 首選：方案 A — Native macOS App

**推薦 Tech Stack**：純 AppKit（或 SwiftUI 僅用於簡單 UI 部分，核心圖片顯示用 AppKit）

**理由**：
1. 所有核心功能（Open With、Pinch Zoom、捲動翻頁）都有成熟 API，**確定能做到**
2. HEIC/RAW/WebP 原生支援，不需要任何 workaround
3. Apple 長期維護 AppKit 相容性，維護成本最低
4. 開源參考多（FlowVision、Picasa）

**風險緩解**：
- 若不熟 Swift，預留 2 週學習時間（Swift 語法 + AppKit 基礎）
- 參考 FlowVision 原始碼加速開發
- 避免 SwiftUI/AppKit 混合，或僅在非核心 UI 使用 SwiftUI

### 次選：方案 B — Tauri v2

**適用場景**：如果你是前端開發者且排斥學 Swift，Tauri 是可行的替代方案。

**條件**：
- 接受 pinch zoom 體驗不如 native
- 願意學習基礎 Rust（~15h）
- 可參考 Electro 的 Open With 實作

### 不建議：方案 C — Pure Web App

核心需求無法達成，直接排除。

---

## 開源參考快速連結

- **FlowVision**（SwiftUI）：`github.com/netdcy/FlowVision`（698 stars）
- **Electro**（Tauri）：`github.com/pTinosq/Electro`（含 Open With 教學）
- **tauview**（Tauri）：`github.com/sprout2000/tauview`（Leaflet.js 縮放方案）
- **ViewSkater**（Rust + GPU）：`github.com/ggand0/viewskater`（212 stars）
- **ryohey/Zoomable**（SwiftUI）：修正 pinch zoom 中心點問題
