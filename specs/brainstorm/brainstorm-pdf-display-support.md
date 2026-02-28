# PDF 顯示支援 — 研究報告

**日期**：2026-02-28
**參與角色**：PDFKit 研究員、UX 研究員、效能研究員、程式碼分析員、架構研究員（5 人平行研究）

---

## 需求摘要

為 Cee 加入 PDF 顯示支援，讀入 PDF 後能像一般圖片那樣換頁。選擇換頁時，是在 PDF 內部換到下一頁，而不是切換到下一份檔案。

---

## 一、架構方案比較

### 總覽矩陣

| 指標 | A: PDFView | **B: PDFPage→NSImage** | C: Hybrid PDFKit | D: CGPDFDocument |
|------|:---------:|:---------------------:|:---------------:|:---------------:|
| MVP 適合度 | ❌ | **✅ 最佳** | ❌ | ❌ |
| 與現有 ScrollView 相容 | ❌ 衝突 | **✅ 零修改** | ⚠️ 部分 | ✅ 完全掌控 |
| 實作複雜度 | 低但不可用 | **中（改 3-4 檔）** | 高 | 最高 |
| 新增檔案數 | 0-1 | 1-2 | 3-5 | 3-5 |
| Zoom/Scroll 一致性 | ❌ 完全不同 | **✅ 完美整合** | ⚠️ 需橋接 | ✅ 完全掌控 |
| Cmd+scroll zoom | ❌ 需 hack | **✅ 原生支援** | ⚠️ 需橋接 | ✅ 原生支援 |
| 渲染效能 | 最佳（Apple 管理） | 中（按需渲染） | 中 | 可優化 |
| 記憶體可控性 | 差（PDFView 自管） | **好（ImageLoader cache）** | 中 | 最好 |
| 文字選取/搜尋 | ✅ 免費獲得 | ❌ | ⚠️ 部分 | ❌ |
| 維護負擔 | 低（Apple 維護） | 中 | 高 | 最高 |

### 各方案評估

#### A: PDFView（Apple 內建）❌ 不推薦

PDFView 是 NSScrollView 的子類，有自己的 `scaleFactor`（非 `magnification`）和 gesture recognizer，與 Cee 的 `ImageScrollView` 根本不相容：

- `PDFView.scaleFactor` ≠ `NSScrollView.magnification`：無法統一 zoom 邏輯
- PDFView 的 pinch/scroll gesture 與外層 gesture 互相干擾
- viewport-center zoom 邏輯由 PDFView 自行決定，無法移植現有行為
- 已知記憶體問題：大量 ink annotation 的 PDF zoom 時 IOSurface 暴增 crash

唯一優點是文字選取、搜尋免費獲得，但 MVP 目標「像圖片一樣顯示 PDF 頁面」不需要這些。

#### B: PDFPage → NSImage ✅ 推薦

PDF 頁面渲染成 NSImage 後，直接走現有 `ImageItem` / `ImageScrollView` pipeline：

```
PDF 開啟 → PDFDocument 解析 → 每頁展開為 ImageItem(pdfPageIndex:)
→ ImageLoader.loadPDFPage() 渲染成 NSImage
→ ImageScrollView 顯示（零修改）
```

- zoom/scroll/pan/page-turn 全部零修改
- `ImageViewController` 的導航邏輯只需換資料來源
- 最符合 MVP 原則

#### C: Hybrid PDFKit ❌ 過度設計

用 PDFKit 渲染但自訂 scroll/zoom，實質上就是方案 B + 額外複雜度。

#### D: CGPDFDocument（低層次）❌ 不推薦 MVP

比方案 B 多大量旋轉/cropBox 手動處理程式碼，只在需要 annotation 渲染時才有優勢。

---

## 二、PDFKit 框架技術要點

### 2.1 核心 API

```swift
import PDFKit

// 載入（只解析 header，成本低）
guard let doc = PDFDocument(url: fileURL) else { return }

// 頁數與頁面存取（0-based index）
let total = doc.pageCount
guard let page = doc.page(at: 0) else { return }

// 頁面尺寸（PDF points, 72pt = 1 inch）
let bounds = page.bounds(for: .cropBox)  // 建議用 cropBox（實際顯示範圍）

// 頁面旋轉
let rotation = page.rotation  // 0, 90, 180, 270
```

### 2.2 三種渲染方式

| 方式 | 典型耗時（A4 @ screen res） | 備註 |
|---|---|---|
| `page.thumbnail(of:for:)` | ~150-300ms | 最簡單，一行搞定 |
| `page.draw(with:to:)` | ~200-350ms | 可控背景色等 |
| `CGContext.drawPDFPage` | ~200-400ms | 最底層、最可控 |

效能差異很小（PDFKit 底層也是呼叫 CGPDFPage）。MVP 建議用 `thumbnail(of:for:)` 最簡單。

### 2.3 渲染範例

```swift
// 最簡單：thumbnail
let nsImage = page.thumbnail(of: page.bounds(for: .cropBox).size, for: .cropBox)

// 更可控：draw + 白色背景
let pageRect = page.bounds(for: .cropBox)
let image = NSImage(size: pageRect.size)
image.lockFocus()
if let ctx = NSGraphicsContext.current?.cgContext {
    ctx.setFillColor(CGColor.white)
    ctx.fill(CGRect(origin: .zero, size: pageRect.size))
    page.draw(with: .cropBox, to: ctx)
}
image.unlockFocus()
```

### 2.4 Swift 6 Actor 安全

**問題**：`PDFDocument` / `PDFPage` 不是 Sendable，不能跨 actor 邊界傳遞。

**推薦做法**：在 `ImageLoader` actor 內只傳 `URL` + `pageIndex: Int`（都是 Sendable），在 actor 方法內建立 `PDFDocument`：

```swift
// In ImageLoader actor
func loadPDFPage(url: URL, pageIndex: Int) async throws -> NSImage {
    guard let doc = PDFDocument(url: url),
          let page = doc.page(at: pageIndex) else {
        throw ImageError.failedToLoad
    }
    let size = page.bounds(for: .cropBox).size
    return page.thumbnail(of: size, for: .cropBox)
}
```

⚠️ `PDFDocument(url:)` 建立成本低（只解析 header），但內部有 ~19MB 基礎消耗。同一 PDF 應快取 `PDFDocument` 實例，不要每頁重建。

---

## 三、記憶體與效能

### 3.1 每頁記憶體估算（RGBA 32-bit = 4 bytes/pixel）

| 頁面 | Scale | 像素尺寸 | 記憶體 |
|---|---|---|---|
| A4 (595×842 pt) | 1x | 595×842 | ~2.0 MB |
| A4 (595×842 pt) | 2x Retina | 1190×1684 | **~8.0 MB** |
| Letter (612×792 pt) | 2x Retina | 1224×1584 | ~7.5 MB |

### 3.2 快取策略

```swift
let pageCache = NSCache<NSNumber, NSImage>()
pageCache.countLimit = 10                        // 最多 10 頁
pageCache.totalCostLimit = 80 * 1024 * 1024      // 80 MB 上限
```

### 3.3 鄰頁預載

±2 頁滑動視窗（共 5 頁 ≈ 40MB @2x），頁面切換時清除視窗外快取並預載新的鄰頁。

### 3.4 Zoom 策略（兩層）

- zoom < 2x：顯示 screen-res bitmap（Retina 2x 已夠清晰）
- zoom ≥ 2x：觸發背景高解析度重渲染，完成前先放大點陣圖顯示
- 不需要 `CATiledLayer` 的複雜度

### 3.5 背景渲染

`CGContext.drawPDFPage` 多執行緒會產生 artifact。使用 actor 的 serial executor 保證單一渲染，自然避免問題。

---

## 四、UX 導航設計

### 4.1 主要 Viewer 行為參考

| Viewer | PDF 換頁按鍵 | 最後頁+Next | 備註 |
|--------|-------------|------------|------|
| Preview.app | Option+↓/↑ | 停在最後頁 | 保守風格 |
| Skim | ↓ / PageDown | 停在最後頁 | 純 PDF viewer |
| EdgeView 3 | 方向鍵（統一） | 跳到下一個檔案 | **最相關：comic reader 風格** |
| Sequential | 方向鍵（統一） | 跳到下一個檔案 | 開源、統一頁面序列 |

### 4.2 推薦模式：EdgeView 風格（連貫穿越）

PDF 頁面展開為獨立的「虛擬圖片」，統一進入導航序列：

```
[img1.jpg] → [doc.pdf p1] → [doc.pdf p2] → [doc.pdf p3] → [img2.jpg]
```

- `Cmd+]` / `Cmd+[`：下一頁/上一頁（PDF 內部 or 跨檔案，統一處理）
- 最後 PDF 頁 + Next → 自動跳到資料夾下一個檔案
- 第一 PDF 頁 + Prev → 跳回上一個檔案

### 4.3 視窗標題

使用 `NSWindow.subtitle`（macOS 11+）：
```swift
window.title    = "document.pdf"
window.subtitle = "Page 3 of 10"    // 只在 PDF 模式顯示
```

一般圖片時 subtitle 為空或不設定。

### 4.4 功能優先序

1. **必須有**：PDF 能顯示、翻頁、title bar 顯示頁碼
2. **最好有**：邊界自動穿越到下一個檔案
3. **可以有**：Go menu 動態更名（"Next Page" vs "Next Image"）

---

## 五、程式碼整合點

### 5.1 修改清單

| 檔案 | 修改內容 | 複雜度 |
|------|---------|--------|
| **ImageItem.swift** | 新增 `pdfPageIndex: Int?` 欄位，fileName 加頁碼顯示 | 低 |
| **ImageFolder.swift** | PDF 偵測（`UTType.pdf`）→ 展開為多個 `ImageItem(pdfPageIndex:)` | 中 |
| **ImageLoader.swift** | 新增 `loadPDFPage(url:pageIndex:)` + PDFDocument/NSImage 快取 | 中 |
| **ImageViewController.swift** | `loadCurrentImage()` 判斷 `pdfPageIndex` 走 PDF 載入路徑 | 低 |
| **ImageWindowController.swift** | `updateTitle` 加 `window.subtitle` 顯示頁碼 | 低 |
| **AppDelegate.swift** | `openFile` panel 加入 `.pdf` 到 `allowedContentTypes` | 低 |
| **ImageScrollView.swift** | **零修改** | — |

### 5.2 ImageItem 修改

```swift
struct ImageItem: Equatable {
    let url: URL
    let pdfPageIndex: Int?  // nil for regular images

    var fileName: String {
        guard let page = pdfPageIndex else { return url.lastPathComponent }
        return "\(url.lastPathComponent) — Page \(page + 1)"
    }
}
```

### 5.3 ImageFolder 修改

`scanFolder()` 中偵測到 PDF 時，用 `PDFDocument(url:).pageCount` 展開為多個 `ImageItem`：

```swift
if contentType.conforms(to: .pdf) {
    if let doc = PDFDocument(url: fileURL) {
        for i in 0..<doc.pageCount {
            items.append(ImageItem(url: fileURL, pdfPageIndex: i))
        }
    }
} else if Self.supportedTypes.contains(contentType) {
    items.append(ImageItem(url: fileURL, pdfPageIndex: nil))
}
```

### 5.4 ImageLoader 修改

```swift
func loadPDFPage(url: URL, pageIndex: Int) async throws -> NSImage {
    // CacheKey 需包含 pageIndex
    let cacheKey = CacheKey(url: url, pageIndex: pageIndex)
    if let cached = cache[cacheKey] { return cached }

    guard let doc = PDFDocument(url: url),
          let page = doc.page(at: pageIndex) else {
        throw ImageError.failedToLoad
    }
    let size = page.bounds(for: .cropBox).size
    let image = page.thumbnail(of: size, for: .cropBox)
    cache[cacheKey] = image
    return image
}
```

---

## 六、技術陷阱清單

1. **頁碼索引**：`PDFDocument.page(at:)` 從 **0** 開始；`CGPDFDocument.page(at:)` 從 **1** 開始
2. **Y 軸翻轉**：PDF 座標系原點左下，用 `CGContext.drawPDFPage` 時需 `translateBy` + `scaleBy(1, -1)`
3. **`bytesPerRow` 傳 `0`**：讓 CG 自動對齊，傳非整數值效能嚴重下降
4. **colorspace**：用 `NSScreen.main?.colorSpace.cgColorSpace`，非 `CGColorSpaceCreateDeviceRGB()`，否則記憶體洩漏
5. **頁面尺寸不一致**：PDF 每頁可以不同大小，必須逐頁讀取 `bounds(for:)`
6. **PDFDocument 快取**：同一 PDF 只建一次（~19MB 基礎消耗）
7. **CG 渲染非執行緒安全**：`drawPDFPage` 多執行緒產生 artifact，用 actor serial executor
8. **白色背景**：PDF 頁面預設透明，必須先填白色再渲染
9. **旋轉頁面**：`page.rotation != 0` 時必須套 `page.transform(for:)` 才正確顯示
10. **cropBox vs mediaBox**：`cropBox` 是實際顯示範圍，`mediaBox` 可能更大，建議用 `.cropBox`

---

## 七、效能瓶頸分析與優化方案（2026-02-28 研究）

**研究方法**：4 人平行研究（CGPDFDocument 效能、Swift actor 快取、延遲展開模式、業界最佳實踐）

### 7.1 瓶頸分析

#### 瓶頸 1：`scanFolder()` 同步建立所有 PDFDocument（主執行緒阻塞）

`ImageFolder.swift:42` — 掃描資料夾時，每個 PDF 都建一次 `PDFDocument(url:)` 來取 `pageCount`。spec 說「只解析 header，成本低」，但對 10-22MB 的 PDF，cross-reference table 解析仍然耗時。

#### 瓶頸 2：`renderPDFPage()` 每頁都重建 PDFDocument

`ImageLoader.swift:40` — 開啟第 0 頁時，載入當前頁 + updateCache 預載 page 1, 2 = 3 次 `PDFDocument(url:)` 建立。加上 scanFolder 的建立次數，開啟資料夾總共建了 ~5 個同一份 PDF 的 PDFDocument。

### 7.2 關鍵發現

#### CGPDFDocument vs PDFDocument（效能比較研究）

| 面向 | CGPDFDocument | PDFDocument (PDFKit) |
|------|:---:|:---:|
| xref table 解析 | ✅ 必須 | ✅ 必須（相同 Core Graphics 引擎） |
| PDFPage 物件建立 | ❌ lazy（`page(at:)` 時才建） | ⚠️ 初始化時預建 PDFPage 陣列 |
| 文字/annotation 基礎設施 | ❌ 無 | ⚠️ 初始化時建立 |
| Outline/書籤解析 | ❌ 無 | ⚠️ 初始化時解析 |
| 記憶體 baseline | ~6MB → ~25MB（含渲染快取） | 更高（ObjC 物件圖 + 上述開銷） |

**結論**：兩者底層共用 Core Graphics xref 解析（主要成本），但 CGPDFDocument 省掉 PDFKit wrapper 開銷，**適合只取 `pageCount` 的場景**。

#### Spotlight 元資料取頁數（驚喜發現）

`kMDItemNumberOfPages` 可**不開啟 PDF** 就取得頁數（使用 Spotlight 預索引資料），本地檔案幾乎零成本：
```swift
// Shell: mdls -name kMDItemNumberOfPages document.pdf
// Swift: NSMetadataItem 或 MDItemCopyAttribute
```
適合作為 Phase 2 的 scanFolder 加速方案，失敗時 fallback 到 `CGPDFDocument`。

#### Swift Actor 快取模式

- **Dictionary 優於 NSCache**：actor 已提供序列化存取，NSCache 的執行緒安全是多餘的；NSCache 驅逐行為不可預測（非 LRU）
- **`renderPDFPage` 從 `static` 改為 instance method**：才能存取 actor 內的 `pdfDocumentCache`
- **移除 `Task.detached`**：actor 方法已在非主執行緒執行，actor serial queue 不會成為瓶頸
- **window-based eviction**：延伸現有 `updateCache` 滑動視窗機制，清理視窗外的 PDFDocument

#### Sequential 開源閱覽器的作法

Sequential 使用 **tree-based deferred loading**：
- PDF 被視為容器（`PGPDFAdapter` 繼承 `PGContainerAdapter`）
- 資料夾掃描時只建立節點，不解析 PDF
- `loadIfNecessary` 機制在使用者導航到 PDF 時才展開頁面

#### 業界 PDF 渲染最佳實踐

- **PDFDocument 不是 thread-safe**：不能跨執行緒共用。但 actor 的 serial executor 天然解決此問題
- **Pre-render ±1-2 頁**：顯示預渲染的 NSImage，避免 tile rendering lag
- **可取消渲染**：快速翻頁時取消不再需要的背景渲染（Swift Task cancellation）
- **兩層解析度**：zoom < 2x 用螢幕解析度；zoom ≥ 2x 觸發高解析度重渲染

### 7.3 推薦方案：A + B 都做

#### 方案 A：PDFDocument 快取（解決翻頁速度）

在 `ImageLoader` actor 內快取 `PDFDocument` per URL：

```swift
// ImageLoader actor
private var pdfDocumentCache: [URL: PDFDocument] = [:]

// 從 static 改為 instance method
private func cachedDocument(url: URL) -> PDFDocument? {
    if let doc = pdfDocumentCache[url] { return doc }
    let doc = PDFDocument(url: url)
    if let doc { pdfDocumentCache[url] = doc }
    return doc
}

// updateCache 時清理視窗外的 PDFDocument
func updateCache(currentIndex: Int, items: [ImageItem]) {
    let range = max(0, currentIndex - cacheRadius)...min(items.count - 1, currentIndex + cacheRadius)
    let activePDFURLs = Set(items[range].filter { $0.isPDF }.map(\.url))
    pdfDocumentCache = pdfDocumentCache.filter { activePDFURLs.contains($0.key) }
    // ... existing image cache logic
}
```

#### 方案 B：scanFolder 輕量取頁數（解決開啟速度）

優先順序：

1. **Spotlight 元資料**（零成本，本地檔案幾乎一定有索引）
2. **`CGPDFDocument`**（比 PDFKit 輕，只取 `numberOfPages`）
3. **`PDFDocument`**（最後 fallback）

```swift
// scanFolder 中
if contentType.conforms(to: .pdf) {
    let pageCount: Int
    // 嘗試 Spotlight 元資料（最快）
    if let mdItem = MDItemCreateWithURL(nil, fileURL as CFURL),
       let pages = MDItemCopyAttribute(mdItem, kMDItemNumberOfPages) as? Int {
        pageCount = pages
    }
    // Fallback: CGPDFDocument（比 PDFKit 輕）
    else if let cgDoc = CGPDFDocument(fileURL as CFURL) {
        pageCount = cgDoc.numberOfPages
    } else {
        pageCount = 0
    }
    for i in 0..<pageCount {
        items.append(ImageItem(url: fileURL, pdfPageIndex: i))
    }
}
```

### 7.4 研究來源

- [CGPDFDocument Apple Docs](https://developer.apple.com/documentation/coregraphics/cgpdfdocument)
- [PDFDocument Apple Docs](https://developer.apple.com/documentation/pdfkit/pdfdocument)
- [WWDC22: What's new in PDFKit](https://developer.apple.com/videos/play/wwdc2022/10089/)
- [PSPDFKit: What contributes to slow PDF rendering](https://pspdfkit.com/blog/2021/what-contributes-to-slow-pdf-rendering/)
- [PSPDFKit: Tackling PDF performance issues](https://pspdfkit.com/blog/2021/tackling-pdf-performance-issues/)
- [PSPDFKit: Rendering PDF pages](https://pspdfkit.com/guides/ios/getting-started/rendering-pdf-pages)
- [PDF xref table parsing](https://eliot-jones.com/2025/8/pdf-parsing-xref)
- [CGPDFDocument memory secrets (SO)](https://stackoverflow.com/questions/4668772/)
- [CGPDFDocument threading rules (SO)](https://stackoverflow.com/questions/8199929/cgpdfdocument-threading)
- [NSCache vs LRU](https://mjtsai.com/blog/2025/05/09/nscache-and-lrucache/)
- [Swift actors guide](https://www.avanderlee.com/swift/actors/)
- [Non-Sendable types in actors](https://www.massicotte.org/non-sendable/)
- [Sequential source (GitHub)](https://github.com/btrask/Sequential)
- [Spotlight PDF page count](https://leancrew.com/all-this/2017/04/pdf-page-counts-and-mdls/)
- [Fast thumbnails with CGImageSource](https://macguru.dev/fast-thumbnails-with-cgimagesource/)
- [Fast PDF viewer patterns (SO)](https://stackoverflow.com/questions/3889634/fast-and-lean-pdf-viewer-for-iphone-ipad-ios-tips-and-hints)
- [Swift structured caching in actors (Swift Forums)](https://forums.swift.org/t/structured-caching-in-an-actor/65501)

---

## 八、MVP 實作階段

### Phase 1 — 基礎可用（最小改動）✅ Done (2026-02-28, commit `cae2134`)
- `ImageItem` 加 `pdfPageIndex: Int?` + `Sendable`
- `ImageFolder` 偵測 PDF（`.pdf` 加入 `supportedTypes`）並用 `flatMap` 展開頁面
- `ImageLoader` 加 `loadPDFPage()` + `pdfCache`（用 `thumbnail(of:for:)`）
- `ImageViewController` 分支 PDF/圖片載入路徑，`updateCache` 改接 `[ImageItem]`
- `ImageWindowController` title bar 加 `window.subtitle` 顯示頁碼
- `AppDelegate` 自動繼承（`supportedTypes` 已含 `.pdf`）
- **設計決策**：title bar `(x/y)` 保持扁平化索引（含 PDF 頁面），不改成檔案索引

### Phase 2 — 效能優化 ✅ Done (2026-02-28)

**方案 B：scanFolder 輕量化**（`ImageFolder.swift`）
- `import PDFKit` → `import CoreGraphics` + `import CoreServices`
- 新增 `pdfPageCount(for:)` helper：Spotlight `kMDItemNumberOfPages`（零成本） → `CGPDFDocument`（fallback） → 0
- `scanFolder()` 不再建立 `PDFDocument`，主執行緒阻塞完全解除

**方案 A：PDFDocument 快取**（`ImageLoader.swift`）
- 新增 `pdfDocumentCache: [URL: PDFDocument]`，同一 PDF 只建立一次
- `renderPDFPage` 從 `static` 改為 instance method，存取快取
- 移除 `Task.detached`（actor serial executor 已非主執行緒）
- `updateCache` 新增 pdfDocumentCache window-based eviction

**Retina 渲染修正**
- `thumbnail(of:for:)` 改用 `pointSize × backingScaleFactor` 作為 pixel 尺寸
- `image.size` 設回 points，保留高解析度 bitmap representation

**未完成項目（移至 Phase 3）**
- 白色背景 + 旋轉頁面處理（`page.rotation != 0` 時套 `page.transform(for:)`）
- `pdfCache` key 改用 `struct PDFCacheKey: Hashable` 取代 String

### Phase 3 — 進階優化
- 白色背景 + 旋轉頁面處理（`page.rotation != 0` 時套 `page.transform(for:)`）
- `pdfCache` key 改用 `struct PDFCacheKey: Hashable` 取代 String
- Zoom ≥ 2x 高解析度重渲染（兩層解析度策略）
- 可取消背景渲染（快速翻頁時 cancel 不需要的 Task）
- Go menu 動態標題（"Next Page" vs "Next Image"）
- 密碼保護 PDF 處理（`doc.isLocked`）
- 記憶體壓力處理（`DispatchSource.makeMemoryPressureSource`）
- **記住上次 PDF 頁碼**（重開時回到上次閱讀位置）

---

## 參考來源

### 原始研究
- [Apple PDFKit 文件](https://developer.apple.com/documentation/pdfkit)
- [Apple CGPDFDocument 文件](https://developer.apple.com/documentation/coregraphics/cgpdfdocument)
- [Apple ZoomingPDFViewer 範例](https://developer.apple.com/library/archive/samplecode/ZoomingPDFViewer/)
- [WWDC22: What's new in PDFKit](https://developer.apple.com/videos/play/wwdc2022/10089/)
- [PSPDFKit: PDF to Image in Swift](https://pspdfkit.com/blog/2020/convert-pdf-to-image-in-swift/)
- [Correctly Drawing PDFs in Cocoa](https://ryanbritton.com/2015/09/correctly-drawing-pdfs-in-cocoa/)
- [Sequential (開源 macOS 圖片+PDF 閱覽器)](https://github.com/chuchusoft/Sequential)
- [EdgeView 功能頁](https://www.edgeview.co.kr/?page_id=71)
- [Preview 鍵盤快捷鍵](https://support.apple.com/guide/preview/keyboard-shortcuts-cpprvw0003/mac)
- [Skim 操作手冊](https://skim-app.sourceforge.io/manual/SkimHelp_4.html)
- [Swift Concurrency Image Loader 模式](https://www.donnywals.com/using-swifts-async-await-to-build-an-image-loader/)
- [NSCache 與 LRUCache](https://mjtsai.com/blog/2025/05/09/nscache-and-lrucache/)
- [CGPDFDocument 記憶體行為](https://stackoverflow.com/questions/4668772/)

### 效能研究（2026-02-28 追加）
- [PSPDFKit: What contributes to slow PDF rendering](https://pspdfkit.com/blog/2021/what-contributes-to-slow-pdf-rendering/)
- [PSPDFKit: Tackling PDF performance issues](https://pspdfkit.com/blog/2021/tackling-pdf-performance-issues/)
- [PSPDFKit: Rendering PDF pages guide](https://pspdfkit.com/guides/ios/getting-started/rendering-pdf-pages)
- [PDF xref table parsing](https://eliot-jones.com/2025/8/pdf-parsing-xref)
- [CGPDFDocument threading rules (SO)](https://stackoverflow.com/questions/8199929/cgpdfdocument-threading)
- [Swift actors guide](https://www.avanderlee.com/swift/actors/)
- [Non-Sendable types in actors](https://www.massicotte.org/non-sendable/)
- [Sequential 原版 source (GitHub)](https://github.com/btrask/Sequential)
- [Spotlight PDF page count](https://leancrew.com/all-this/2017/04/pdf-page-counts-and-mdls/)
- [Fast thumbnails with CGImageSource](https://macguru.dev/fast-thumbnails-with-cgimagesource/)
- [Fast PDF viewer patterns (SO)](https://stackoverflow.com/questions/3889634/fast-and-lean-pdf-viewer-for-iphone-ipad-ios-tips-and-hints)
- [Swift structured caching in actors (Swift Forums)](https://forums.swift.org/t/structured-caching-in-an-actor/65501)
