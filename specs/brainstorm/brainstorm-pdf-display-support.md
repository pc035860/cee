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

## 七、MVP 實作階段

### Phase 1 — 基礎可用（最小改動）
- `ImageItem` 加 `pdfPageIndex: Int?`
- `ImageFolder` 偵測 PDF 並展開頁面
- `ImageLoader` 加 `loadPDFPage()`（用 `thumbnail(of:for:)` 最簡單）
- `ImageWindowController` title bar 顯示頁碼
- `AppDelegate` open panel 加 `.pdf`

### Phase 2 — 體驗完善
- NSCache 快取 + ±2 頁預載
- PDFDocument 實例快取（避免重複建立）
- 白色背景 + 旋轉頁面處理
- Retina 解析度正確渲染（`window.backingScaleFactor`）

### Phase 3 — 進階優化
- Zoom ≥ 2x 高解析度重渲染
- Go menu 動態標題（"Next Page" vs "Next Image"）
- 密碼保護 PDF 處理（`doc.isLocked`）
- 大型 PDF 效能優化

---

## 參考來源

- [Apple PDFKit 文件](https://developer.apple.com/documentation/pdfkit)
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
