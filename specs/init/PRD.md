# Cee - Product Requirements Document

## 1. Overview

- **專案名稱**：Cee
- **類型**：macOS 原生看圖軟體
- **問題陳述**：XEE 已 3 年未更新、無 Apple Silicon 原生支援，常出現圖片無法顯示的問題。macOS 內建的 Preview 不適合大量連續瀏覽圖片。需要一個輕量、操作直覺的看圖工具。
- **目標使用者**：開發者自用（個人工具）
- **定位**：類似 XEE 的精簡看圖工具，專注於「大量圖片順序瀏覽」場景

## 2. Goals & Success Metrics

### 目標
- 透過右鍵「Open With」開啟任意圖片，自動載入同資料夾所有圖片並順序瀏覽
- 提供舒適的縮放與捲動體驗，讓看圖流程不中斷

### 成功標準
- 右鍵開啟圖片後，1 秒內顯示圖片並完成資料夾掃描
- Pinch Zoom 流暢無延遲
- 捲動到底 → 翻頁 → 回到頂部的流程自然無卡頓

## 3. MVP Scope

### 3.1 In Scope（MVP 必做）

1. **右鍵開啟 + 資料夾載入**
2. **縮放等級持久化**（Pinch Zoom + 鍵盤快捷鍵）
3. **捲動到底自動翻頁**
4. **鍵盤快捷鍵**
5. **圖片適配模式**（Fit on Screen、Fitting Options、Scaling Quality）
6. **全螢幕模式**
7. **視窗行為**（Resize Window Automatically、Float on Top）

### 3.2 Out of Scope（未來再說）

- 縮圖面板 / 檔案列表
- 圖片編輯（裁切、旋轉、調色）
- 幻燈片自動播放
- 圖片檔案管理（刪除、搬移、重新命名）
- 書籤 / 收藏
- 多視窗支援
- 跨平台支援

## 4. Functional Requirements

### 4.1 右鍵開啟與資料夾載入

- **FR-001**：App 註冊為圖片類型的 Open With 選項（不搶預設）
  - 支援格式：JPEG、PNG、GIF、TIFF、HEIC/HEIF、WebP、BMP
  - 透過 Info.plist `CFBundleDocumentTypes` + `LSHandlerRank: Alternate` 實現
- **FR-002**：收到檔案開啟請求後，掃描該檔案所在資料夾的所有圖片
  - 排序方式：依檔名字母/數字順序排列
  - 跳過隱藏檔案（以 `.` 開頭）
  - 定位到使用者點擊的那張圖片
- **FR-003**：Lazy Loading，僅載入當前顯示 ±2 張圖片，其餘延遲載入以節省記憶體

### 4.2 縮放機制

- **FR-004**：支援 Trackpad Pinch Zoom
  - 利用 NSScrollView 的 `magnification` 屬性
  - 縮放範圍：10% ~ 1000%
- **FR-005**：支援鍵盤縮放
  - `Cmd + =`（或 `Cmd + +`）：放大
  - `Cmd + -`：縮小
  - `Cmd + 0`：重置為適合視窗大小（Fit to Window）
  - `Cmd + 1`：100% 原始大小
- **FR-006**：縮放等級持久化
  - 切換圖片時保持當前縮放等級
  - 首次開啟時預設為 Fit to Window
  - 手動縮放後切換到「固定縮放」模式
  - `Cmd + 0` 可回到 Fit to Window 模式

### 4.3 捲動與翻頁

- **FR-007**：縮放後圖片超出 Viewport 時，可在視窗內捲動瀏覽
- **FR-008**：捲動到底後，繼續往下捲動觸發切換到下一張圖片
  - 需有合理的 debounce / threshold，避免誤觸
- **FR-009**：捲動到頂後，繼續往上捲動觸發切換到上一張圖片
- **FR-010**：切換到下一張後，自動回到圖片頂部
- **FR-011**：切換到上一張後，自動跳到圖片底部（方便倒著看）

### 4.4 鍵盤快捷鍵

- **FR-012**：導航快捷鍵
  - `→` 或 `PageDown`：下一張
  - `←` 或 `PageUp`：上一張
  - `Home`：第一張
  - `End`：最後一張
  - `Space`：往下捲動一個 viewport 高度（到底則翻頁）
- **FR-013**：縮放快捷鍵（見 FR-005）
- **FR-014**：全螢幕切換
  - `Cmd + F`：切換全螢幕模式（與 XEE 一致）

### 4.5 圖片適配模式（View Menu）

- **FR-015**：Fit on Screen（適合螢幕）
  - 將圖片縮放至完全可見於視窗內（不超出邊界）
  - 這是預設的顯示模式
- **FR-016**：Always Fit Opened Images on Screen（開啟圖片時自動適配）
  - 開關選項（toggle），啟用時每次開啟/切換圖片都自動 Fit on Screen
  - 關閉時，切換圖片保持當前手動設定的縮放等級
  - 快捷鍵：`Cmd + *`
- **FR-017**：Fitting Options（適配選項）子選單
  - Shrink Image to Fit Horizontally：圖片寬度超出時縮小至符合視窗寬度
  - Shrink Image to Fit Vertically：圖片高度超出時縮小至符合視窗高度
  - Stretch Image to Fit Horizontally：小圖放大至符合視窗寬度
  - Stretch Image to Fit Vertically：小圖放大至符合視窗高度
  - Shrink 和 Stretch 可分別獨立開關，組合出不同適配行為
  - 預設：Shrink 兩項都啟用、Stretch 兩項都關閉（即大圖縮小、小圖維持原尺寸）
- **FR-018**：Scaling Quality（縮放品質）子選單
  - Low：最近鄰插值（Nearest Neighbor），速度最快
  - Medium：雙線性插值（Bilinear），預設值
  - High：高品質插值（Lanczos 或類似）
  - Show Pixels When Zooming In：放大超過 100% 時顯示像素格（不做平滑），方便查看原始像素
    - 快捷鍵：`Shift + Cmd + P`

### 4.6 全螢幕模式

- **FR-019**：進入全螢幕後，隱藏標題列和 Dock，圖片佔滿螢幕
  - 使用 macOS 原生全螢幕 API（`toggleFullScreen`）
  - 快捷鍵：`Cmd + F`
- **FR-020**：全螢幕下保留所有操作功能（縮放、捲動、翻頁、快捷鍵）
- **FR-021**：按 `Esc` 退出全螢幕

### 4.7 視窗行為

- **FR-022**：視窗標題顯示當前圖片檔名和序號（例：`photo_001.jpg (3/42)`）
- **FR-023**：Resize Window Automatically（自動調整視窗大小）
  - 開關選項，啟用時視窗大小自動配合圖片尺寸調整
  - 關閉時視窗大小固定，圖片在視窗內適配
- **FR-024**：Float on Top（視窗置頂）
  - 開關選項，啟用時視窗永遠在最上層
- **FR-025**：首次開啟時視窗大小合理（例如螢幕 80%），之後記住視窗大小

## 5. Non-Functional Requirements

- **效能**：開啟含 1000 張圖片的資料夾不應明顯延遲（目錄掃描 < 500ms）
- **記憶體**：瀏覽 1000 張圖片時記憶體使用 < 500MB（透過 lazy loading 控制）
- **響應性**：切換圖片 < 100ms 感知延遲

## 6. Technical Constraints

- **平台**：macOS 14 Sonoma 以上
- **架構**：Apple Silicon（arm64），不需支援 Intel
- **語言**：Swift
- **框架**：AppKit 為主（核心圖片顯示用 NSScrollView），SwiftUI 僅用於非核心簡單 UI（若需要）
- **開發工具**：Xcode
- **分發**：自用，不上 App Store，無需簽名公證
- **開發者背景**：前端開發者，無 Swift/AppKit 經驗（需考慮學習曲線）

## 7. Boundaries

### Always（安全，可自動執行）
- 遵循 Apple Human Interface Guidelines 基本原則
- 使用 ARC 自動記憶體管理
- 錯誤處理（檔案不存在、格式不支援時顯示 placeholder）

### Ask First（高影響，需確認）
- 增加新的圖片格式支援
- 變更 Info.plist 的 UTType 註冊

### Never（禁止）
- 寫入或修改使用者的圖片檔案
- 存取圖片所在資料夾以外的檔案系統
- 網路存取（這是純離線工具）

## 8. Timeline

- **Phase 1**：基礎可用版 — 能開啟圖片、瀏覽資料夾、Pinch Zoom、基本 Fit on Screen
- **Phase 2**：核心體驗版 — 縮放持久化、捲動翻頁、鍵盤快捷鍵
- **Phase 3**：顯示模式版 — Fitting Options、Scaling Quality、Always Fit、視窗行為選項
- **Phase 4**：完善版 — 全螢幕、Float on Top、UI 打磨、效能優化

## 9. Assumptions & Dependencies

- 開發者已安裝 Xcode（最新版）
- macOS 原生支援所有目標圖片格式（HEIC、WebP 等）
- 使用 ImageIO framework 進行高效圖片解碼
- 參考 FlowVision 開源專案的實作方式

## 10. Open Questions

- 是否需要支援動態 GIF 播放？（MVP 先只顯示第一幀）
- 是否需要記住上次瀏覽的位置（下次開啟同資料夾時繼續）？
- 捲動到底翻頁的 threshold 和 debounce 時間需實測調整
