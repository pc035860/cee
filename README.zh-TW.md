# Cee

[English](README.md) | **[繁體中文](README.zh-TW.md)**

一個輕量的 macOS 圖片瀏覽器，設計來取代 XEE。

開啟一張圖片後，Cee 會自動掃描同一資料夾內的所有圖片，讓你用鍵盤或滑鼠輕鬆翻頁瀏覽。

**系統需求：** macOS 14.0 (Sonoma) 以上、Apple Silicon (M1 以上)

**授權條款：** [MIT License](LICENSE)

---

## 功能

### 圖片瀏覽
- 從 Finder 右鍵「打開方式」開啟圖片，自動讀取同資料夾的圖片列表
- 可選擇在同一視窗或新視窗開啟圖片（Window 選單 > Reuse Window）
- 支援格式：JPEG、PNG、TIFF、HEIC/HEIF、GIF、WebP、BMP、PDF
- 鍵盤快速鍵導航（Cmd+]/[ 切換圖片）
- 左/右方向鍵平移放大圖片，到邊緣後連續按 3 次可翻頁（珊瑚色漸層進度提示）
- 上/下方向鍵捲動圖片（預設不導航，可在 Navigation 選單切換）
- PageUp/PageDown/Space 逐頁捲動，到底/頂自動翻頁
- Option+方向鍵一次跳轉 10 張圖片（僅限單頁模式）
- 拖放圖片或資料夾即可開啟（支援瀏覽模式、網格模式、空白狀態）
- 子資料夾自動搜尋：拖入的資料夾若無圖片，會自動搜尋含有圖片的子資料夾（BFS，最深 2 層）

### 縮放與顯示
- 捏合縮放、Cmd+滾輪縮放
- 適合螢幕大小 / 實際像素 / 自訂縮放
- 縮放狀態顯示：FIT（自動適應）、ACTUAL 100% 或 MANUAL xx%，視窗自動調整時附帶 WINDOW AUTO 後綴
- 全螢幕模式、永遠浮於最上層
- 拉滿視窗高度但不進入全螢幕（⌥⌘F）
- 透過 CALayer 進行 GPU 加速渲染
- 底部狀態列顯示圖片尺寸、索引、縮放比例（Cmd+/ 切換）
  - 自適應顯示：寬視窗顯示完整資訊，窄視窗僅顯示百分比，極窄時隱藏縮放
- 開窗時自動調整視窗大小（可選），視窗調整時自動重新適應
- 觸控板與滑鼠滾輪分離的靈敏度設定

### 快速網格
- 按 **G** 鍵切換縮圖網格，一覽資料夾內所有圖片
- 點擊或按 Enter 跳轉至該圖片；按 G 或 Esc 關閉
- 捏合、Cmd+滾輪、Cmd+=+- 調整格子大小；底部滑桿可微調
- 根據資料夾內容動態調整格子比例
- 網格在切換資料夾時保持開啟，支援拖放

### 連續捲動
- 漫畫式垂直連續捲動模式（在 Navigation 選單或右鍵選單中切換）
- 資料夾內所有圖片垂直排列，一路捲動瀏覽
- 可調整圖片間距（0 / 2 / 4 / 8 pt），在 Navigation 選單設定
- 支援縮放，以適合寬度為基準
- GPU 加速渲染搭配視圖回收，確保流暢效能
- 記憶體壓力感知：低記憶體時自動縮減緩衝區

### 雙頁檢視
- 左右並排雙頁顯示，自動高度正規化
- 支援 RTL（由右至左）閱讀方向；雙頁與單頁模式各有獨立的 RTL 導航切換（Navigation 選單）
- 展頁感知導航

### 快速瀏覽
- 可選的低解析度縮圖預覽（View 選單：「Use Low-Res Preview While Browsing」）
- 方向性預取，流暢瀏覽體驗
- Option+滾輪快速切換圖片，附帶位置 HUD 浮層顯示
- 導航節流（~20fps），延遲載入全解析度圖片

### PDF
- PDF 逐頁瀏覽，記憶上次閱讀頁碼
- 可取消的 PDF 頁面預取

### 滑鼠與手勢
- 滑鼠拖曳平移圖片（游標會變成手掌圖示）
- 三指觸控板拖曳平移圖片
- 觸控板從邊緣開始滑動超過門檻值，自動翻頁
- 點擊翻頁：左鍵點擊切換下一張，Shift+點擊切換上一張（可選，在 Navigation 選單啟用）
- Cmd+滾輪在視窗中心縮放

---

## 從原始碼執行

目前 Cee 沒有提供預編譯的發行版，需要自行 build。

### 1. 安裝必要工具

需要 **Xcode 16 以上**（建議從 Mac App Store 安裝），以及 **xcodegen**（用來產生 Xcode 專案檔）：

```bash
brew install xcodegen
```

如果還沒裝 Homebrew，請先參考 [brew.sh](https://brew.sh)。

### 2. Clone 專案

```bash
git clone <repo-url>
cd cee
```

### 3. 產生 Xcode 專案

`.xcodeproj` 不放進 Git，每次都要用 xcodegen 產生：

```bash
xcodegen generate
```

### 4. 用 Xcode 開啟並執行

```bash
open Cee.xcodeproj
```

在 Xcode 裡選好 scheme（`Cee`）和目標裝置（`My Mac`），按 Cmd+R 即可執行。

#### 或者用命令列 Build

```bash
xcodebuild -project Cee.xcodeproj -scheme Cee -configuration Debug build
```

Build 完成後，.app 會在：

```
build/Debug/Cee.app
```

可以直接雙擊執行，或把它拖到 `/Applications` 資料夾。

---

## 使用方式

### 開啟圖片

- **從 Finder：** 在圖片上右鍵 → 打開方式 → Cee
- **從 App 內：** Cmd+O 開啟檔案選擇器
- **拖放：** 將圖片檔案或資料夾拖放到視窗上

開啟後，Cee 會自動掃描同一資料夾裡所有支援格式的圖片。

### 鍵盤快速鍵

| 動作 | 快速鍵 |
|------|--------|
| 下一張 | Cmd+] 或 右方向鍵（邊緣時） |
| 上一張 | Cmd+[ 或 左方向鍵（邊緣時） |
| 向前跳轉 10 張 | Option+右方向鍵 |
| 向後跳轉 10 張 | Option+左方向鍵 |
| 第一張 | Home |
| 最後一張 | End |
| 向下捲動一頁 | Space 或 PageDown |
| 向上捲動一頁 | PageUp |
| 適合螢幕 | Cmd+0 |
| 實際大小 | Cmd+1 |
| 放大 | Cmd+= |
| 縮小 | Cmd+- |
| 全螢幕 | Cmd+F |
| 拉滿視窗高度 | Option+Cmd+F |
| 退出全螢幕 | Esc |
| 切換狀態列 | Cmd+/ |
| 切換快速網格 | G |
| 開啟檔案 | Cmd+O |
| 關閉視窗 | Cmd+W |
| 結束 | Cmd+Q |

> **方向鍵行為：** 左/右方向鍵用於平移圖片，到達邊緣後連續按 3 次同方向即可翻頁（邊緣會顯示珊瑚色漸層進度提示）。上/下方向鍵預設僅用於捲動，不會觸發翻頁（可在 Navigation 選單切換）。圖片未超出視窗時，左/右方向鍵直接切換上/下一張。

> **PageDown / Space 行為：** 逐頁捲動圖片，到底部後再按一次即翻到下一張。PageUp 同理。

### 縮放

- **捏合手勢**：觸控板雙指縮放
- **Cmd+滾輪**：放大縮小
- **Cmd+0**：縮放至適合螢幕
- **Cmd+1**：顯示原始像素大小

---

## 開發者

### 執行 E2E 測試

```bash
./scripts/test-e2e.sh
```

會自動 build 並跑全部 XCUITest smoke tests。

### 修改專案結構後

新增 / 刪除檔案或修改 target 設定後，需要重新產生 Xcode 專案：

```bash
xcodegen generate
```

> `Cee.xcodeproj` 是自動產生的，請勿手動編輯。
