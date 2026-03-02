# Dual Page View（雙頁檢視）設計研究報告

**日期**：2026-03-02
**參與角色**：existing-readers-researcher、appkit-tech-researcher、offset-researcher、cee-arch-researcher、devil's-advocate（4+1 人平行研究）

---

## 需求摘要

新增「雙頁檢視」模式，讓看圖軟體可以將兩張圖片並排顯示，模擬漫畫成冊印刷的視覺效果。

**核心需求**：
1. 兩張圖片並排顯示，操作起來如同一張圖片
2. 解決排序偏移（Offset）問題（封面、插頁導致配對錯位）
3. 使用者可自行調整 offset

---

## 一、現有漫畫閱讀器調查

### 閱讀器概覽

| 閱讀器 | 平台 | 雙頁模式 | 寬頁偵測 | RTL 支援 |
|--------|------|----------|----------|----------|
| **MComix** | Linux/Windows | ✅ | ✅ (width > height) | ✅ (Manga Mode) |
| **Simple Comic** | macOS | ✅ | ✅ | ✅ |
| **YACReader** | 跨平台 | ✅ | ✅ | ✅ |
| **CDisplayEx** | Windows | ✅ | ✅ | ✅ |
| **Komga** | Web | ✅ | ✅ (`isPageLandscape`) | ✅ |
| **KOReader** | 多平台 | ✅ | ✅ | ✅ |

### 業界標準：Spread 配對模型

所有成熟閱讀器使用 **Spread（跨頁）配對**模型：

```
Pages: [0] [1] [2] [3] [4] [5(wide)] [6] [7]
Spreads: [0] [1,2] [3,4] [5] [6,7]
```

- 導航單位是 spread，不是 page
- 寬頁（width > height）自動獨佔一個 spread
- 來源：[Komga buildSpreads()](https://github.com/gotson/komga/commit/5fe015ede0329ed85b39b78f11d55150214f65bf)

### 三種頁面佈局模式

1. **Single Page** — 一次顯示一頁
2. **Double Page (with cover)** — 第一頁單獨作為封面，之後配對
3. **Double Page (no cover)** — 所有頁面都配對

### 寬頁偵測

業界一致使用 `width > height` 判斷，準確度極高。

- 來源：[MComix 文件](https://sourceforge.net/p/mcomix/wiki/Documentation/)、[SumatraPDF 討論](https://github.com/sumatrapdfreader/sumatrapdf/discussions/2341)

### RTL 閱讀順序

RTL 模式影響：spread 內頁面排列左右互換、翻頁方向反轉、鍵盤左右鍵語意互換。

---

## 二、AppKit 技術方案比較

### 四種方案

| 維度 | A: 雙 ScrollView | B: 單 ScrollView + 雙子 View | C: CGImage 合成 | D: SplitView |
|------|:-:|:-:|:-:|:-:|
| GPU rendering 保留 | ✅ | ✅ | ✅ | ✅ |
| 同步複雜度 | ❌ 高 | ✅ 無需 | ✅ 無需 | ❌ 高 |
| 縮放自然度 | ⚠️ 需鏡像 | ✅ 自動 | ✅ 自動 | ⚠️ 需鏡像 |
| 平移自然度 | ⚠️ 需同步 | ✅ 自動 | ✅ 自動 | ⚠️ 需同步 |
| Cee 改動量 | 大 | 中 | 小 | 大 |
| CPU 額外開銷 | 中（通知） | 無 | 高（合成） | 中（通知） |
| 記憶體 | 2x | 2x | 3x | 2x |
| 翻頁延遲 | 低 | 低 | 高 | 低 |

### 推薦：方案 B — 單一 NSScrollView + 雙 ImageContentView

```
ImageScrollView (NSScrollView)
  └─ documentView: DualPageContentView (NSView)
      ├─ leftPage: ImageContentView (layer.contents = leftCGImage)
      └─ rightPage: ImageContentView (layer.contents = rightCGImage)
```

**核心優勢：**
- NSScrollView.magnification 自動對整個 documentView 生效，兩頁等比縮放如同一張圖
- 無同步問題，平移、縮放都自然作用於整個 documentView
- 保持 Cee GPU-first 架構（layer.contents = cgImage）

**方案 A（CGImage 合成）被否決的原因：**
- Retina 2x 下合成記憶體 ~278MB（非 80MB），每次翻頁都需 CPU 合成
- 違背 Cee 從 CPU draw() 遷移到 GPU layer.contents 的設計方向

**參考資料：**
- [Apple NSScrollView.magnification](https://developer.apple.com/documentation/appkit/nsscrollview/magnification)
- [objc.io - Getting Pixels onto the Screen](https://www.objc.io/issues/3-views/moving-pixels-onto-the-screen/)
- [Christian Tietze - Synchronize NSScrollView](https://christiantietze.de/posts/2018/07/synchronize-nsscrollview/)

---

## 三、Offset 管理方案

### 問題本質

雙頁配對在以下情況會錯位：封面單頁、無封面章節、跨頁大圖、中間插頁/廣告頁。

### 業界方案

| 方案 | 採用者 |
|------|--------|
| Cover mode toggle（第一頁是否獨立） | Komga、CDisplayEx、MangaDex |
| 自動偵測寬頁打斷配對 | MComix、Komga、Tachiyomi |
| Per-manga 持久化 | Paperback iOS |

### 推薦 MVP

- **Per-folder offset toggle**：一個 boolean，true = 第一頁獨佔（有封面），false = 第一頁即配對
- **自動寬頁偵測**：width > height 的頁面自動獨佔
- **持久化**：UserDefaults + `manga.offset.\(folderURL.path)` key（沿用 pdf.lastPage 模式）
- **封面偵測不可靠**，讓用戶手動 toggle 更好

### UI 方案

- 快捷鍵 ⌘⇧O 切換 offset
- Status Bar 顯示 offset 狀態
- Go 選單項目

**參考來源：**
- [MangaDex offset 討論](https://www.reddit.com/r/mangadex/comments/uu4bjf/)
- [Kavita #2660](https://github.com/Kareadita/Kavita/discussions/2660)
- [Paperback iOS offset](https://github.com/Paperback-iOS/app/issues/220)

---

## 四、Cee 架構整合點

### 資料模型

- **ImageItem**：不需修改，已是良好的「單一頁面」抽象
- **新增 PageSpread**：
  ```swift
  enum PageSpread: Sendable {
      case single(ImageItem)
      case double(left: ImageItem, right: ImageItem)
  }
  ```
- **ImageFolder**：新增 `currentSpread()`, `goNextSpread()`, `goPreviousSpread()`

### 核心修改點

| 檔案 | 影響程度 | 說明 |
|------|---------|------|
| ImageViewController | 重大 | loadCurrentImage → loadCurrentSpread，導航邏輯改為 spread-aware |
| ImageScrollView | 小幅 | 鍵盤方向鍵在 RTL 時反轉（Phase 2） |
| ImageContentView | 不變 | 方案 B 下完全復用 |
| ImageFolder | 中度 | 新增 spread 導航方法 |
| StatusBarView | 小幅 | 顯示 "5-6 / 100" 格式 + "Dual" 指示器 |
| ViewerSettings | 小幅 | 新增 `dualPageEnabled: Bool` |
| AppDelegate | 小幅 | 新增選單項 |
| FittingCalculator | 不變 | 只看最終 imageSize vs viewport |
| ImageLoader | 不變 | prefetch 調度在 VC 層 |

### 快捷鍵分配

| 快捷鍵 | 功能 | 理由 |
|--------|------|------|
| ⌘K | Toggle Dual Page | ⌘M 已被 Minimize 佔用 |
| ⌘⇧O | Toggle Page Offset | ⌘O 的 shift 變體 |
| ⌘⇧K | Toggle Reading Direction | 與 ⌘K 配對（Phase 2） |

---

## 五、Devil's Advocate 批判

### 命名建議

將「漫畫模式 (Manga Mode)」改為「雙頁檢視 (Dual Page View)」，強調通用性，避免用戶期待 CBZ 支援等漫畫閱讀器功能。

### MVP 範圍過大

研究員建議的 MVP 包含 RTL、per-folder 持久化等，應削減為極簡版本。

### 維護成本警告

- ImageViewController 預計增加 150-250 LOC（已是專案最複雜檔案）
- 建議抽取 `SpreadManager` 獨立類 + Strategy Pattern 隔離模式邏輯
- 每次修改 zoom/pan/fullscreen 都需驗證雙頁模式（永久維護稅）

### 被遺漏的風險

1. **Window resize**：fit 基準是合成 spread 的合計寬度
2. **Fullscreen 轉場**：re-apply fitting 需要 spread-aware
3. **Pinch zoom 錨點**：viewport center 在雙頁模式下可能感覺不自然
4. **模式切換 index 對齊**：雙頁 spread 2+3 切回單頁應停在哪頁
5. **奇數總頁數**：最後一頁獨佔顯示
6. **PDF 互動**：PDF 是否參與雙頁顯示需明確定義
7. **效能**：雙頁模式 cacheRadius 建議減為 1（cache 6 張 ≈ 209MB）

---

## 六、最終推薦方案

### 技術架構

**方案 B：單一 NSScrollView + DualPageContentView 容器 + 雙 ImageContentView**

- 單頁模式時退化為只有一個子 view，行為不變
- 不等高頁面：以較高頁為基準，較矮頁垂直置中
- magnification 自動覆蓋所有子 view，操作如同單張圖片

### MVP 範圍（Phase 1）— ✅ 已完成

| 功能 | 狀態 |
|------|------|
| ⌘K toggle 單頁/雙頁 | ✅ 已完成 |
| 方案 B 雙頁並排 | ✅ 已完成 |
| 寬頁自動偵測 (width > height) | ✅ 已完成 |
| Offset toggle（⌘⇧O） | ✅ 已完成 |
| Status Bar "Dual" 指示器 + 頁碼 | ✅ 已完成 |
| RTL 閱讀方向 | ✅ 已完成（Phase 2） |
| Per-folder 持久化 | ✅ 已完成（Phase 2） |
| PDF 雙頁顯示 | ✅ 已完成（Phase 2，原生支援） |
| 翻頁動畫 | ❌ Phase 3 |

### 架構建議

- 抽取 `SpreadManager` 獨立類，避免 ImageViewController 膨脹
- 考慮 Strategy Pattern：`SinglePageStrategy` / `DualPageStrategy`
- Prefetch 調度放在 VC 層，不修改 ImageLoader
- 雙頁模式下 `cacheRadius` 從 2 減為 1

### Phase 1 — 基礎可用版（MVP）

核心目標：雙頁並排可用，操作如同單張圖片。

1. **ViewerSettings** 新增 `dualPageEnabled: Bool`
2. **PageSpread enum** + **SpreadManager** 獨立類
   - Spread 配對邏輯（含寬頁自動偵測 `width > height`）
   - Offset toggle（第一頁是否獨佔）
3. **DualPageContentView** 容器 view
   - 內含左右兩個 ImageContentView，水平並排
   - 不等高頁面：較矮頁垂直置中
   - 單頁模式退化為只有一個子 view
4. **ImageFolder** 新增 spread 導航
   - `currentSpread()`, `goNextSpread()`, `goPreviousSpread()`
5. **ImageViewController** 改為 spread-aware
   - `loadCurrentImage` → `loadCurrentSpread`
   - `applyFitting` 以合成 spread 尺寸計算
   - 導航方法改為 spread 步進
6. **AppDelegate** 新增選單項
   - ⌘K：Toggle Dual Page
   - ⌘⇧O：Toggle Page Offset
7. **StatusBarView** 調整
   - 頁碼格式 "5-6 / 100"
   - "Dual" 指示器

**需解決的邊界情況：**
- 奇數總頁數：最後一頁獨佔，靠左顯示
- 模式切換 index 對齊：雙頁切回單頁時保持左頁 index
- Fullscreen 轉場：re-apply fitting 需 spread-aware
- Window resize：fit 基準為 spread 合計寬度
- cacheRadius 減為 1（控制記憶體 ~209MB）

### Phase 2 — 需求滿足版 — ✅ 已完成

1. ✅ **RTL 閱讀方向**
   - ViewerSettings 新增 `ReadingDirection` enum（`.leftToRight` | `.rightToLeft`）
   - DualPageContentView `configureDouble(isRTL:)` 左右互換
   - ImageScrollView `isRTLNavigation` 鍵盤左右鍵反轉
   - ⌘⇧K toggle 方向
2. ✅ **Per-folder 設定持久化**
   - UserDefaults + `dualPage.settings.\(folderURL.path)` key
   - 記住每個資料夾的 dualPageEnabled、firstPageIsCover、readingDirection
3. ✅ **PDF 雙頁顯示**
   - PDF 頁面已原生參與 spread 配對（ImageItem 展開為個別頁面，SpreadManager 自動配對）
   - `lastPage` 持久化不變（存 page index）
4. ❌ **Per-file 單頁標記**（進階 offset）— 延遲至 Phase 3
   - 右鍵選單「標記此頁為單頁」
   - 處理中間插頁打斷配對的情況
5. ✅ **Go 選單動態文字**
   - "Next Image" → "Next Spread"（雙頁模式下）

### Phase 3 — 優化完善版

確認瓶頸後再做。

1. **翻頁動畫**：spread 切換時的過渡效果
2. **Spread 預載優化**：以 spread 為單位的 prefetch 策略
3. **自動偵測封面**：根據第一頁寬高比自動設定 offset
4. **螢幕方向適配**：窄螢幕自動切回單頁模式

---

## 七、參考資料

1. [MComix 文件](https://sourceforge.net/p/mcomix/wiki/Documentation/)
2. [Simple Comic (macOS)](https://github.com/MaddTheSane/Simple-Comic)
3. [YACReader](https://github.com/YACReader/yacreader)
4. [Komga Spread 實作](https://github.com/gotson/komga/commit/5fe015ede0329ed85b39b78f11d55150214f65bf)
5. [SumatraPDF 雙頁討論](https://github.com/sumatrapdfreader/sumatrapdf/discussions/2341)
6. [KOReader RTL Issue](https://github.com/koreader/koreader/issues/4583)
7. [Paperback iOS Offset](https://github.com/Paperback-iOS/app/issues/220)
8. [Apple NSScrollView.magnification](https://developer.apple.com/documentation/appkit/nsscrollview/magnification)
9. [objc.io - Getting Pixels onto the Screen](https://www.objc.io/issues/3-views/moving-pixels-onto-the-screen/)
10. [Christian Tietze - Synchronize NSScrollView](https://christiantietze.de/posts/2018/07/synchronize-nsscrollview/)
11. [MangaDex offset 討論](https://www.reddit.com/r/mangadex/comments/uu4bjf/)
12. [Kavita offset 討論](https://github.com/Kareadita/Kavita/discussions/2660)

---

## 八、實作記錄

**實作日期**：2026-03-02
**分支**：`feat/dual-page-view`
**總計**：10 files changed, +610/-84 lines, 7 commits

### 已完成（Phase 1 + Phase 2）

| 檔案 | 變更 |
|------|------|
| `Cee/Models/PageSpread.swift` | 新增：Sendable enum `.single`/`.double` |
| `Cee/Models/SpreadManager.swift` | 新增：純靜態 Sendable struct，spread 配對 + 寬頁偵測 |
| `Cee/Models/ViewerSettings.swift` | 新增：`dualPageEnabled`、`firstPageIsCover`、`ReadingDirection` enum |
| `Cee/Models/ImageFolder.swift` | 新增：spread 導航方法，goNext/goPrevious 自動 syncSpreadIndex |
| `Cee/Utilities/Constants.swift` | 新增：`dualPageCacheRadius` |
| `Cee/Views/DualPageContentView.swift` | 新增：容器 NSView，高度正規化雙頁佈局，RTL 支援 |
| `Cee/Views/ImageScrollView.swift` | 修改：`isRTLNavigation` flag + 鍵盤反轉 |
| `Cee/Views/StatusBarView.swift` | 修改：`indexOverride`/`sizeText` 參數支援 spread 顯示 |
| `Cee/Controllers/ImageViewController.swift` | 重大修改：spread-aware 載入/導航/fitting/狀態列/持久化 |
| `Cee/App/AppDelegate.swift` | 修改：3 個新選單項（⌘K、⌘⇧O、⌘⇧K） |

### 架構決策記錄

1. **方案 B 確認**：DualPageContentView 作為永久 documentView，magnification 自動覆蓋
2. **contentView 計算屬性**：`var contentView: ImageContentView { dualPageView.leadingPage }` 最小化改動
3. **高度正規化**：不同解析度頁面按比例縮放至相同視覺高度（Gemini 審查建議）
4. **Strategy Pattern 延遲**：MVP 使用 if/else 分支即可，不過度抽象
5. **Per-file 單頁標記延遲至 Phase 3**：需要右鍵選單 + per-item metadata 儲存，複雜度高
