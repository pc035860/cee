# Cee

一個輕量的 macOS 圖片瀏覽器，設計來取代 XEE。

開啟一張圖片後，Cee 會自動掃描同一資料夾內的所有圖片，讓你用鍵盤或滑鼠輕鬆翻頁瀏覽。

**系統需求：** macOS 14.0 (Sonoma) 以上、Apple Silicon (M1 以上)

**授權條款：** [MIT License](LICENSE)

---

## 功能

- 從 Finder 右鍵「打開方式」開啟圖片，自動讀取同資料夾的圖片列表
- 支援格式：JPEG、PNG、TIFF、HEIC/HEIF、GIF、WebP、BMP
- 鍵盤快速鍵導航（Cmd+]/[ 切換圖片）
- 方向鍵平移放大圖片，到邊緣後連續按鍵可翻頁
- PageUp/PageDown/Space 逐頁捲動，到底/頂自動翻頁
- 滑鼠拖曳平移圖片
- 三指觸控板拖曳平移圖片
- 邊緣翻頁進度指示器（珊瑚色漸層提示）
- 捏合縮放、Cmd+滾輪縮放
- 適合螢幕大小 / 實際像素 / 自訂縮放
- 全螢幕模式、永遠浮於最上層
- 開窗時自動調整視窗大小（可選）
- 觸控板與滑鼠滾輪分離的靈敏度設定

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

開啟後，Cee 會自動掃描同一資料夾裡所有支援格式的圖片。

### 鍵盤快速鍵

| 動作 | 快速鍵 |
|------|--------|
| 下一張 | Cmd+] 或 右方向鍵 |
| 上一張 | Cmd+[ 或 左方向鍵 |
| 第一張 | Home |
| 最後一張 | End |
| 向下捲動一頁 | Space 或 PageDown |
| 向上捲動一頁 | PageUp |
| 適合螢幕 | Cmd+0 |
| 實際大小 | Cmd+1 |
| 放大 | Cmd+= |
| 縮小 | Cmd+- |
| 全螢幕 | Cmd+F |
| 退出全螢幕 | Esc |
| 開啟檔案 | Cmd+O |
| 關閉視窗 | Cmd+W |
| 結束 | Cmd+Q |

> **方向鍵行為：** 當圖片超出視窗範圍時，方向鍵會平移圖片。到達邊緣後，連續按 3 次同方向即可翻頁（邊緣會顯示珊瑚色漸層進度提示）。圖片未超出視窗時，方向鍵直接切換上/下一張。

> **PageDown / Space 行為：** 逐頁捲動圖片，到底部後再按一次即翻到下一張。PageUp 同理。

### 縮放

- **捏合手勢**：觸控板雙指縮放
- **Cmd+滾輪**：放大縮小
- **Cmd+0**：縮放至適合螢幕
- **Cmd+1**：顯示原始像素大小

### 滑鼠與手勢

- **滑鼠拖曳**：按住左鍵拖曳來平移圖片（游標會變成手掌圖示）
- **三指拖曳**：觸控板三指拖曳平移圖片
- **捲動到頂/底**：觸控板從邊緣開始滑動超過門檻值，自動翻頁

---

## 開發者

### 執行 E2E 測試

```bash
./scripts/test-e2e.sh
```

會自動 build 並跑全部 12 個 XCUITest smoke tests。

### 修改專案結構後

新增 / 刪除檔案或修改 target 設定後，需要重新產生 Xcode 專案：

```bash
xcodegen generate
```

> `Cee.xcodeproj` 是自動產生的，請勿手動編輯。
