# 快速瀏覽資料夾圖片：方案腦力激盪報告

> 日期：2026-03-03
> 團隊：4 人（3 提案者 + 1 Devil's Advocate）

## 背景與訴求

- Cee 是 macOS 原生圖片檢視器（AppKit, Swift 6.2, GPU layer rendering）
- 使用者需要在大量圖片（數百至上千張）的資料夾中快速找到目標圖片
- **不一定要有 Thumbnail**，任何能讓使用者視覺化高速掃描的方式都可行
- **效能最優先**

## 方案總覽（9 個提案）

### A 類：高速切換型

| 方案 | 核心概念 | 實作難度 | 效能風險 |
|------|----------|----------|----------|
| A1 鍵盤長按加速 | 長按方向鍵漸進加速翻頁 | 低 | 低 |
| A2 Scrubber Bar | 底部拖曳時間軸 + 縮圖 tooltip | 中高 | 中 |
| A3 Option+scroll | 修飾鍵 + 滾輪快速切圖 | 中 | 低 |

### B 類：視覺化索引型

| 方案 | 核心概念 | 實作難度 | 效能風險 |
|------|----------|----------|----------|
| B1 底部膠卷條 | 水平 NSCollectionView 縮圖條 | 中 | 高 |
| B2 側邊縮圖面板 | NSSplitView + 垂直縮圖列 | 中高 | 中 |
| B3 快速預覽網格 | 快捷鍵觸發全畫面縮圖 overlay | 低中 | 中 |

### C 類：創新互動型

| 方案 | 核心概念 | 實作難度 | 效能風險 |
|------|----------|----------|----------|
| C1 Pressure-Scrub | Force Touch 壓力控制瀏覽速度 | 高 | 中 |
| C2 Filmstrip Bar | 可展開影片式縮圖刮擦條 | 高 | 高 |
| C3 Gesture Ring | 兩指旋轉手勢導航 | 中高 | 高 |

---

## Devil's Advocate 批判重點摘要

### 所有方案的共通根本問題

> **現有圖片載入管線不支援快速切換。**
> `loadSpread` → `loadImageForItem` → async full-resolution decode 是為「逐張瀏覽」設計的。
> 任何快速切換方案都需要先解決這個前提。

### Phase 0 必做前提（任何方案之前）

1. **`ImageLoader` 新增 thumbnail/low-res 載入路徑** — 使用 `CGImageSourceCreateThumbnailAtIndex`（JPEG 16ms，比 NSImage 快 40 倍）
2. **導航節流機制** — 快速切換時 debounce/throttle，避免大量 cancelled async tasks
3. **Status Bar 位置顯示** — "N/Total" 計數器，讓使用者知道目前位置

### PDF 場景是放大器

每個效能問題在 PDF 場景下放大 5-10 倍。PDF 不能用 `CGImageSourceCreateThumbnailAtIndex`，每張縮圖需要完整 CGContext 渲染。

### 被否決的方案及原因

| 方案 | 否決原因 |
|------|----------|
| B2 側邊面板 | 偽需求。Cee 是輕量 viewer，不是 asset manager。佔用 120-160pt 視窗寬度，與 Dual Page 嚴重衝突。NSSplitView 重構整個 view hierarchy。磁碟快取命中率極低（違反 MVP）。 |
| C1 Pressure-Scrub | 硬體限制致命。Force Touch 僅限部分 Mac，Magic Mouse 不支援，無 graceful degradation。RSVP 學術研究針對文字非圖片。 |
| C3 Gesture Ring | 與 pinch-to-zoom 手勢衝突無法解決。學習成本高（無主流 App 使用）。無障礙問題。 |

### 有條件可行但投入產出比差的方案

| 方案 | 問題 |
|------|------|
| A2 Scrubber Bar | 實作複雜度高，1000 張 thumbnail 序列生成需 16 秒。64px micro thumbnail 對同類型圖片辨識度極低。與 Status Bar / Dual Page 的 UI 衝突多。 |
| B1 膠卷條 | NSCollectionView 在 macOS 1000+ items 時已知 jank 問題。120px × 2x Retina 記憶體估算被低估（230MB 而非 60MB）。常駐佔用螢幕空間。 |
| C2 Filmstrip Bar | 本質是 A2 + B1 混合體，繼承兩者所有問題。動態 contentInsets 變更觸發複雜的重新計算。 |

---

## 最終推薦方案（批判後改善版）

### Tier 1 — MVP（立即做）

#### 簡化版 A1：流暢鍵盤導航 + 位置指示

**概念**：不追求「加速」，而是確保 key repeat 時的導航流暢不卡頓。

- 移除「加速階段」設計（過度工程化），直接讓系統 key repeat 驅動逐張導航
- 快速 key repeat 時使用 low-res fallback 顯示，停止後載入全解析度
- Status Bar 新增 "42/1000" 位置計數器
- 修飾鍵跳躍：`Option+方向鍵` 一次跳 10 張（避免 Ctrl 衝突 Mission Control）

**為什麼是 MVP**：
- 實作成本最低（主要是 ImageLoader 的 thumbnail 路徑 + 節流）
- 零新 UI 元件
- 利用現有 keyDown + prefetch 架構
- 立即改善日常瀏覽體驗

**效能關鍵**：
- `CGImageSourceCreateThumbnailAtIndex` 做 low-res fallback（JPEG ~16ms/張）
- 方向性 prefetch（往使用者翻頁方向多預載 5 張）
- 導航節流：throttle 到 ~20fps，避免 async task 堆積

**Dual Page 注意**：spread navigation 的 `buildSpreads` 在高速翻頁時可能是瓶頸，需評估。

---

### Tier 2 — Phase 2（高價值）✅ COMPLETED

#### 改良版 B3：Quick Grid（按需縮圖網格）

**概念**：按快捷鍵（如 `G`）彈出全畫面縮圖 overlay，找到圖片後點擊跳轉。

**針對批判的改良**：
- **解決初始載入延遲**：先顯示檔名文字列表（零延遲），背景逐步填入縮圖
- **解決 EXIF fallback**：三級漸進載入
  1. 立即：檔名 + 檔案圖示（零成本）
  2. 快速：EXIF 內嵌縮圖（JPEG 有，PNG/PDF 無 → 跳過）
  3. 背景：`CGImageSourceCreateThumbnailAtIndex` 精確縮圖（可見範圍優先）
- **解決記憶體**：overlay 關閉後釋放；重新開啟時，如果 Tier 1 的 thumbnail cache 還在就直接用
- **解決焦點管理**：overlay 用獨立 NSPanel（`becomesKeyOnlyIfNeeded`），ESC 關閉時 first responder 回到 scrollView

**效能分析**：
- 不影響正常瀏覽的啟動速度和記憶體
- 60px 縮圖 × 可見範圍 ~50 張 = ~15MB 峰值，可接受
- PDF 頁面使用低解析度渲染（scale 0.5x），控制在 ~50ms/頁

---

### Tier 3 — Phase 3（可選增強）

#### 改良版 A3：Option+scroll 快速切圖

**概念**：`Option+滾輪` 觸發快速翻頁，配合位置指示器。

**針對批判的改良**：
- **節流機制**：累積 delta 到閾值才切換，避免過度觸發
- **位置指示器**：快速切換時在畫面中央顯示大字 "42/1000"（類似音量 HUD）
- **momentum 限制**：momentum 翻頁上限 10 張，防止盲飛
- **取消機制**：快速切換時只保留最後一次的 full-res 載入請求

**前提**：依賴 Tier 1 的 thumbnail fallback 和節流基礎設施。

---

## 共用基礎設施（Phase 0）

所有 Tier 都依賴的底層能力，需優先建設：

```
ImageLoader
├── loadFullResolution(item:)     ← 現有
├── loadThumbnail(item:, maxSize:) ← 新增：CGImageSource thumbnail
└── cancelLoad(item:)              ← 強化：更積極的取消

ImageViewController
├── navigationThrottle             ← 新增：debounce 快速導航
└── prefetchDirection              ← 新增：方向性預載入

StatusBar
└── positionIndicator              ← 新增："N/Total" 顯示
```

## 技術參考

### 縮圖 API 效能（實測數據）
| API | JPEG | HEIC | PNG |
|-----|------|------|-----|
| `CGImageSourceCreateThumbnailAtIndex` | 16ms | 43ms | 145ms |
| `NSImage(contentsOf:)` → resize | 628ms | — | — |

### 快取策略建議
- 不用 `NSCache`（淘汰策略不可控，非 LRU）
- 自建 LRU Cache 或使用 Nick Lockwood 的 LRUCache 開源庫
- 注意：ARC 遞迴釋放 linked list 會 stack overflow，需手動 loop 刪除

### Cee 現有可利用的基礎設施
- `ImageLoader` actor — 非同步圖片載入
- `imageSizeCache` — 尺寸快取（index-based）
- `prefetchTasks` dict — 可取消的背景預載入
- `layer.contents = cgImage` — GPU 渲染，更新圖片只需設定一次

---

## 實作路線圖

```
Phase 0: 基礎設施（thumbnail loader + 節流 + 位置顯示）
    ↓
Phase 1 (Tier 1): 流暢鍵盤導航 + Option+方向鍵跳躍
    ↓
Phase 2 (Tier 2): Quick Grid 按需縮圖網格 ✅ COMPLETED
    ↓
Phase 3 (Tier 3): Option+scroll 快速切圖 ✅ COMPLETED
```

每個 Phase 獨立可用，不依賴後續 Phase。

---

## Phase 2 完成記錄

**實作日期**：2026-03-03
**Branch**：feat/image-browse-phase2
**Commits**：5 commits (e3c69e0..0846641)

### 實作內容
- **QuickGridView.swift** — NSCollectionView overlay with grid-local thumbnail cache
- **QuickGridCell.swift** — NSCollectionViewItem with thumbnail/filename/highlight
- **Keyboard**: bare G toggle, Enter confirm, ESC dismiss, arrow keys navigate
- **Thumbnails**: async loading via ImageLoader.loadThumbnail(maxSize:240), grid-local cache
- **Integration**: menu item, context menu toggle, delegate-based navigation
- **Drag-drop in grid**: grid accepts `.fileURL` drops, refreshes with new folder content instead of dismissing. `clearCache()` (light reset) vs `cleanup()` (full teardown). Drop handling shared via `handleDrop(urls:)`

### MVP 簡化決策
- EXIF tier 2 + CGImageSource tier 3 合併為單一 async load（CGImageSource 已內含 EXIF extraction）
- PDF 僅顯示檔名（無縮圖），defer 到未來
- 使用 NSView overlay 而非 NSPanel（與 EmptyStateView 一致）
- NSCollectionViewPrefetching 不存在於 AppKit，改用 itemForRepresentedObjectAt 觸發載入

### Review 中發現的重要修正
- `didSelectItemsAt` 會在鍵盤 arrow 時觸發 → 用 NSApp.currentEvent 過濾
- Enter key 不會透過 responder chain 到達 QuickGridView → 建立 GridCollectionView subclass
- Thumbnail cache 污染（240px 寫入 shared cache）→ Task.isCancelled guard + clearThumbnailCache()
- G key 在 grid 開啟時不生效（first responder 是 collection view）→ GridCollectionView 處理 bare G

---

## Phase 3 完成記錄

**實作日期**：2026-03-04
**Branch**：feat/image-browse-phase3
**Commits**：8 commits (d4b6a9c..a36049d)

### 實作內容
- **OptionScrollAccumulator.swift** — Testable struct accumulating scroll delta, threshold-based triggering (trackpad 40pt / mouse 8pt), momentum capping (limit 10)
- **PositionHUDView.swift** — NSVisualEffectView HUD (.hudWindow material, darkAqua, cornerRadius 16) showing "N / Total" with auto-fade (1s delay + 0.3s animation), showVersion token prevents stale completions
- **ImageScrollView.swift** — Option+scroll intercept before pageTurnLock, Natural Scrolling correction, delegate-based navigation
- **ImageViewController.swift** — Dedicated `optionScrollNavigate()` bypassing NavigationThrottle, lazy HUD creation, folder-change cleanup
- **Constants.swift** — Phase 3 thresholds and HUD fade delay
- **OptionScrollAccumulatorTests.swift** — 14 unit tests covering accumulation, remainder, negative direction, mouse/trackpad thresholds, momentum capping, reset

### Review 中發現的重要修正
- Option+scroll 必須在 pageTurnLockUntil 之前攔截 → 避免被鎖死阻擋
- NavigationThrottle 阻擋多步導航 → 建立專用路徑 `optionScrollNavigate()` 繞過 throttle
- Dual-page mode amount>1 被 guard 擋住 → for loop 每次 amount=1
- HUD 在無移動時仍顯示 → `optionScrollNavigate` 回傳 Bool 做 guard
- 移除 dead `isOptionScrolling` flag（專用路徑不需要此狀態）
- 空資料夾防禦 → guard `!folder.images.isEmpty`
