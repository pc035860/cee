# Grid View 效能優化計畫

> **目標**：解決大量圖片（1000+）時 Grid View 捲動卡頓 + 記憶體暴增（~1GB）問題
> **研究日期**：2026-03-05
> **研究方法**：4 角度平行研究（捲動效能、執行緒管理、記憶體管理、業界實踐）

---

## 問題分析

### 捲動卡頓根因
1. **無並發限制**：快速捲動時 20-40 個 `Task.detached(priority: .userInitiated)` 同時解碼 → CPU 飽和 → main thread 被壓縮
2. **無載入優先級區分**：可見 cell 與 buffer cell 都用 `.userInitiated`
3. **無 prefetch 機制**：AppKit 不提供 `NSCollectionViewPrefetching`，目前無替代方案
4. **CGImageSource 解碼不可中斷**：cancel 只在前/後檢查，解碼中 16-100ms+ 無法中止

### 記憶體暴增根因
1. **Grid 快取無上限**：`gridThumbnails: [Int: NSImage]` 載入即保留，從不驅逐
2. **縮圖解析度偏高**：最大 tier 1024px → 每張 ~4MB（RGBA），100 張 = 400MB
3. **無記憶體壓力回應**：沒有監聽系統記憶體壓力事件
4. **多層快取重複**：ImageLoader.thumbnailCache + gridThumbnails 可能存相同圖片的不同尺寸

---

## 策略總覽與交叉比較

| # | 策略 | 目標 | 複雜度 | FPS 提升 | 記憶體縮減 | 侵入性 | 風險 |
|---|------|------|--------|----------|-----------|--------|------|
| A | 並發限制 throttle actor | FPS | 中 | ⭐⭐⭐ | 間接改善 | 低 | 低 |
| B | 捲動時取消非可見任務 | FPS | 低 | ⭐⭐⭐ | 間接改善 | 低 | 極低 |
| C | 雙優先級載入 | FPS | 低 | ⭐⭐ | — | 低 | 極低 |
| D | 手動 prefetch 管道 | FPS | 中 | ⭐⭐⭐ | — | 低-中 | 低 |
| E | Grid 視窗快取策略 | 記憶體 | 中 | — | ⭐⭐⭐⭐ | 低-中 | 中 |
| F | 縮圖解析度降級 | 記憶體 | 低 | — | ⭐⭐⭐ | 極低 | 低 |
| G | 動態記憶體上限 | 記憶體 | 低 | — | ⭐⭐ | 低 | 低 |
| H | NSCache 替換 Dictionary | 記憶體 | 低 | — | ⭐⭐ | 中 | 中 |
| I | 記憶體壓力通知 | 記憶體 | 低 | — | 安全網 | 低 | 低 |
| J | Layer-backed cell 優化 | FPS | 低 | ⭐ | — | 低 | 低 |
| K | CALayer.contents 替代 NSImageView | FPS | 中 | ⭐⭐ | — | 中 | 中 |
| L | EXIF 內嵌縮圖快速預覽 | UX | 中 | ⭐ | — | 低 | 低 |
| M | 磁碟縮圖快取 | 記憶體 | 高 | — | 允許更激進驅逐 | 高 | 中 |
| N | Metal 直接渲染 | FPS | 極高 | ⭐⭐⭐⭐⭐ | — | 極高 | 高 |

---

## 分階段開發計畫

### Phase 1 — 立即見效（預期：FPS 接近 60fps + 記憶體降至 ~200MB）

**目標**：用最低侵入性修改解決最大瓶頸

#### 1.1 並發限制 Throttle Actor（策略 A）
- **做法**：建立 `ThumbnailThrottle` actor，限制同時解碼數為 **3-4 個**
- **原理**：Swift cooperative thread pool = CPU core 數，留一半給 UI
- **修改範圍**：`ImageLoader` 內部，外部 API 不變
- **實作概要**：
  ```swift
  actor ThumbnailThrottle {
      private let maxConcurrent = 4
      private var active = 0
      private var waiters: [CheckedContinuation<Void, Never>] = []
      func acquire() async { ... }
      func release() { ... }
  }
  ```

#### 1.2 捲動時批量取消非可見任務（策略 B）
- **做法**：監聽 `NSClipView.boundsDidChange`，取消不在可見區域的 thumbnail tasks
- **修改範圍**：`QuickGridView` 加入 scroll 事件處理
- **實作概要**：
  ```swift
  @objc func clipViewBoundsDidChange(_ note: Notification) {
      let visible = Set(collectionView.indexPathsForVisibleItems().map(\.item))
      for (index, task) in thumbnailTasks where !visible.contains(index) {
          task.cancel()
          thumbnailTasks.removeValue(forKey: index)
      }
  }
  ```

#### 1.3 雙優先級載入（策略 C）
- **做法**：可見 cell → `.userInitiated`，預建 cell → `.utility`
- **修改範圍**：`loadThumbnail` 加 `priority` 參數
- **判斷方式**：`collectionView.indexPathsForVisibleItems()` 是否包含該 indexPath

#### 1.4 Grid 視窗快取策略（策略 E）
- **做法**：只保留可見區域 ± 2 行的縮圖，捲出視窗的釋放
- **原理**：記憶體用量與可見範圍成正比，與總圖片數無關
- **修改範圍**：`QuickGridView` 加入 scroll-based eviction
- **預期效果**：從快取所有圖片 → 只快取 ~50-100 張，記憶體降 **70-90%**

#### 1.5 縮圖最大解析度調整（策略 F）
- **做法**：最大 tier 從 1024px → **720px**（或 512px）
- **原理**：1024×1024×4 = 4MB → 720×720×4 = 2MB，減半
- **修改範圍**：常數調整，一行改動
- **風險**：大 cell 時可能稍模糊，但 grid 一般不需全解析度

#### 1.6 動態記憶體上限（策略 G）
- **做法**：基於 `ProcessInfo.processInfo.physicalMemory` 設 hard cap
- **建議**：Grid 快取 = 系統 RAM 的 5%（8GB Mac → 400MB）
- **修改範圍**：快取配置，幾行程式碼

**Phase 1 預期成果**：
- FPS：從卡頓（<30fps）→ 接近 **60fps**（並發限制 + 取消 + 優先級）
- 記憶體：從 ~1GB → **~150-300MB**（視窗策略 + 解析度調整 + 上限）

---

### Phase 2 — 穩健升級

#### 2.1 手動 Prefetch 管道（策略 D）
- **做法**：監聽 clipView bounds 變化，計算捲動方向，預載即將可見的 1-2 行
- **方向改變時取消反方向 prefetch**
- **效果**：消除捲動時的 decode lag，縮圖「提前到位」

#### 2.2 記憶體壓力通知（策略 I）
- **做法**：`DispatchSource.makeMemoryPressureSource` 監聽 `.warning` / `.critical`
- **回應**：warning → 清空非可見快取；critical → 清空所有快取
- **作為安全網，防止極端情況**

#### 2.3 Generation ID 防過期寫入（策略 B 延伸）
- **做法**：每次 folder change 遞增 `generationID`，task 完成時檢查是否過期
- **防止舊資料夾的解碼結果寫入新資料夾的快取**

#### 2.4 Layer-backed Cell 微優化（策略 J）
- **做法**：
  - `canDrawSubviewsIntoLayer = true`（合併子視圖繪製）
  - `layerContentsRedrawPolicy = .onSetNeedsDisplay`（避免不必要的 redraw）
- **幾行設定，低風險低回報**

**Phase 2 預期成果**：
- 捲動體驗更平滑（prefetch 消除 decode lag）
- 極端記憶體情況有安全網
- 總體記憶體穩定在 **<500MB**

---

### Phase 3 — 進階優化（按需）

#### 3.1 NSCache 替換（策略 H）
- 如果自訂 LRU + 視窗策略效果好，可能不需要
- NSCache 驅逐策略不透明，可能導致可見 cell 閃爍

#### 3.2 CALayer.contents 替代 NSImageView（策略 K）
- 省去 NSImageView 的 scaling/layout overhead
- 已在 `ImageContentView` 有成功先例
- 需手動管理 `contentsGravity`、`contentsScale`

#### 3.3 EXIF 內嵌縮圖快速預覽（策略 L）
- JPEG/HEIC 內嵌 160px 縮圖，讀取 <5ms
- 作為解碼完成前的 placeholder，提升感知速度

#### 3.4 磁碟縮圖快取（策略 M）
- **僅在支援 RAW 格式（解碼 >100ms）時考慮**
- JPEG 縮圖 16ms 解碼，不值得磁碟 I/O 開銷

#### 3.5 Metal 直接渲染（策略 N）
- **僅在 >10K 圖片場景確認 NSCollectionView 為瓶頸時考慮**
- 參考 [Photon Transfer](https://toaster.llc/blog/high-perf-nsscrollview/) 方案
- 實作成本極高，需自建所有 UI 邏輯

---

## 技術決策記錄

### 為什麼選 Swift Concurrency 而非 GCD/OperationQueue？
- Cee 已使用 actor + Task 架構，回退 GCD 會製造 Sendability 衝突
- Swift cooperative thread pool 天然防 thread explosion
- OperationQueue 的 `maxConcurrentOperationCount` 好用，但 actor-based throttle 可達到相同效果

### 為什麼不用 NSCache？
- 驅逐策略不透明（Michael Tsai：剛放入的物件可能立即被驅逐）
- Grid 視窗策略（visible ± buffer）提供更可預測的行為
- Phase 3 如果視窗策略有問題再考慮 NSCache

### 為什麼不做磁碟快取？
- JPEG 縮圖解碼 ~16ms，240px tier 更快
- 磁碟 I/O + cache invalidation 的複雜度不值得
- 等 RAW 支援時再評估

---

## 參考來源

### 效能基準
- [Fast Thumbnails with CGImageSource](https://macguru.dev/fast-thumbnails-with-cgimagesource/) — CGImageSource 比 NSImage 快 40x
- [Zero to Photon: Metal Grid](https://toaster.llc/blog/high-perf-nsscrollview/) — 百萬縮圖 Metal 渲染

### Apple 官方
- [WWDC21: Make blazing fast lists and collection views](https://developer.apple.com/videos/play/wwdc2021/10252/)
- [WWDC18: A Tour of UICollectionView](https://nonstrict.eu/wwdcindex/wwdc2018/225)
- [DispatchSource Memory Pressure](https://developer.apple.com/documentation/dispatch/dispatchsource/memorypressureevent)
- [os_proc_available_memory](https://developer.apple.com/documentation/os/os_proc_available_memory)

### 記憶體管理
- [NSCache and LRUCache](https://mjtsai.com/blog/2025/05/09/nscache-and-lrucache/) — NSCache 驅逐問題
- [NSImage is Dangerous](https://wadetregaskis.com/nsimage-is-dangerous/) — NSImage 隱藏快取行為
- [Reduce UIImage Memory Footprint](https://swiftsenpai.com/development/reduce-uiimage-memory-footprint/)
- [Optimizing Images](https://www.swiftjectivec.com/optimizing-images/)

### 執行緒與並發
- [TaskGroup Best Practices](https://swiftwithmajid.com/2025/02/04/mastering-task-groups-in-swift/)
- [Constrain Concurrency in Swift](https://stackoverflow.com/questions/70976323/)
- [GCD vs Swift Concurrency](https://medium.com/@subhangdxt/structured-concurrency-vs-gcd-grand-central-dispatch-in-swift-detailed-comparison-20dfafd2ad1b)

### 業界實踐
- [FlowVision (GitHub)](https://github.com/netdcy/flowvision) — macOS 圖片瀏覽器，1136 stars
- [NSCollectionView Smooth Scroll](https://stackoverflow.com/questions/56270210/) — FlowLayout jerkiness
- [NSCollectionView Performance Test](https://github.com/seido/testCollectionViewPerformance)
- [High-Perf NSScrollView (CALayer vs NSView)](https://stackoverflow.com/questions/35734858/)
