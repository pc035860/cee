# Grid View 效能優化計畫

> **目標**：解決大量圖片（1000+）時 Grid View 捲動卡頓 + 記憶體暴增（~1GB）問題
> **研究日期**：2026-03-05
> **研究方法**：4 角度平行研究（捲動效能、執行緒管理、記憶體管理、業界實踐）

## Implementation Status

- [x] **Phase 1** — 完成（2026-03-05, branch `feat/grid-performance`）
  - [x] 1.1 ThumbnailThrottle Actor — FIFO async semaphore, maxConcurrent=4
  - [x] 1.2 Cancel Non-Visible Tasks — 20Hz scroll observer + task cancellation
  - [x] 1.3 Dual Priority Loading — visible=.userInitiated, buffer=.utility
  - [x] 1.4 Grid Window Cache — evict outside visible ± 50 buffer on scroll
  - [x] 1.5 Resolution Cap — highest tier 1024px → 720px (~2MB/image)
  - [x] 1.6 Dynamic Memory Cap — 5% system RAM, evict farthest on overflow
- [x] **Phase 2** — 完成（2026-03-05, branch `feat/grid-performance-phase2`）
  - [x] 2.1 Manual Prefetch Pipeline — scroll direction detect + 2-row ahead prefetch + keep-set cancel
  - [x] 2.2 Memory Pressure Notification — DispatchSource warning/critical + idempotent start
  - [x] 2.3 Generation ID — Int counter on clearCache, stale-write guard in Task closures
  - [x] 2.4 Layer-backed Cell — canDrawSubviewsIntoLayer + onSetNeedsDisplay
- [ ] **Phase 3** — 部分完成（推薦實作順序：3.1 → 3.2 → 3.3 → 3.4 → 3.5）
  - [x] 3.1 自適應解析度 + SubsampleFactor — 完成（2026-03-05, branch `feat/grid-performance-phase3`）
    - Tier0 adaptive resolution: ≤60pt cells use quantized `max(cellSize*scale, 80)` in 20px steps
    - SubsampleFactor=4 for JPEG/HEIF when maxSize ≤ 120px (DCT fast path)
    - Constants: `quickGridTier0Boundary`, `quickGridTier0MinPx`, `quickGridTier0QuantizeStep`, `quickGridSubsampleThresholdPx`
    - **實測確認（2026-03-05, logs/1816.txt）**：ss=4 在極小 zoom 100% 觸發
  - [x] 3.2 優先級隊列 + 批次送出 — 完成（2026-03-05, branch `feat/grid-performance-phase3`）
    - ThumbnailThrottle FIFO → priority dequeue (smaller = higher urgency, FIFO tie-break)
    - `throttlePriority` pass-through: ImageLoader → ThumbnailThrottle
    - `cachedVisibleCenter` updated at 20Hz by scroll handler, used in cellForItem
    - Early cancellation guard in withThrottle closure (skip decode if Task cancelled)
    - **實測確認（2026-03-05, logs/1806-1809.txt）**：throttle avg waited 降低 75-90%，peak waiters 降低 45-89%
  - [ ] 3.3 PNG 磁碟縮圖快取 ~70 行，影片 PNG 84ms → 8ms
  - [x] 3.4 算術計算 Visible Range ~15 行，visible 計算 0.38ms → 0.05ms — 完成（2026-03-05）
  - [ ] 3.5 捲動速度自適應 ~25 行，快速捲動零 decode 開銷
- [ ] **Phase 4** — 極端縮放問題（發現於 2026-03-05 實測）
  - [x] 4.1 **限制最小格子尺寸**（✅ 決策確認）— 完成（2026-03-05）
    - **根因**：visible=2827 >> cache cap=828，永久有 ~1999 格空白，throttle 崩潰（avg 1596ms, max 8151ms）
    - **做法**：調整 zoom slider 最小值 40→160pt，讓最小 cell 對應 decode target 480px（tier2 範圍）
    - **效果**：visible 格數回到設計舒適區，避免 visible >> cache cap 的根本問題
    - **改動**：Constants.quickGridMinCellSize 40→160；quickGridCellSize 預設 160；ViewerSettings 預設 160；slider 改 Finder 風格（置中、max 400pt）
  - [ ] 4.2 **Idle 後補發遺漏 task**（低優先，4.1 後決定是否實作）
    - **重新診斷（2026-03-05）**：logs/1816.txt 的 7 秒空窗根因是 **throttle 飽和**（2819 waiters，4 workers 消化不完），而非 cancel 後不重載
    - **正常 cancel 流程沒有 bug**：cell 離開 viewport → cancel → 再回來 → NSCollectionView 重呼 `cellForItem` → OK
    - **真正存在的 edge case**：Tier change 時快速捲動導致部分 visible cell 沒有 task，或捲動停止後 prefetchRange 外的 visible cell 無 thumbnail 也無 task
    - **修法候選**：scroll 停止 ~150ms 後，掃描 visible 中無 thumbnail 且無 task 的 cell，補發 `loadThumbnailAsync`
    - **優先級**：4.1 實作後 visible 降至 ~500-900，throttle 能正常消化，此 edge case 極少發生 → 低優先

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

### Phase 3 — 極小 Zoom + 大量可見格優化

> **背景**：Phase 1+2 完成後，Release build 實測顯示極小 zoom level（可見格 ~928）
> 快速捲動時仍有 lag。根因不是 scrollHandler 卡（avg 0.44ms），
> 而是 **ThumbnailThrottle 積壓**：4 workers 消化 ~1000 任務，排隊 avg 863ms / max 2.3s。
>
> Phase 3 策略基於 2026-03-05 的效能 log 分析 + 4 角度平行研究制定。

**推薦實作順序：3.1 → 3.2 → 3.3 → 3.4 → 3.5**

| 順序 | 策略 | 解決瓶頸 | ROI | 改動量 |
|------|------|---------|-----|--------|
| 1st ⭐ | 3.1 自適應解析度 | decode 過大（240px vs 60px 顯示） | 極高 | ~10 行 |
| 2nd ⭐ | 3.2 優先級隊列+批次 | throttle 積壓（1000 任務 FIFO） | 極高 | ~45 行 |
| 3rd | 3.3 PNG 磁碟快取 | 影片 PNG 極慢（84ms） | 高 | ~70 行 |
| 4th | 3.4 算術 visible | visible 計算成本（0.38ms, 86%） | 中 | ~15 行 |
| 5th | 3.5 速度自適應 | 快速捲動 churning | 中 | ~25 行 |

> **理由**：3.1+3.2 是最高 ROI 組合 — 總共 ~55 行改動，首屏從 2.3s → 200-400ms。
> 3.1 減少每次 decode 工作量，3.2 確保可見格優先消化，兩者互補。
> 3.3 針對特定格式（PNG p99），3.4/3.5 是 scrollHandler 微優化。

#### 3.1 自適應解析度 + SubsampleFactor（策略 F 升級）⭐ 最高優先
- **問題**：最小 tier 240px，但 cell 實際顯示只有 40-60px，decode 4-6x 浪費
- **做法**：新增 tier0（微縮圖），`maxSize = max(cellSize × retinaScale, 80)`
  - 當 `maxSize ≤ 120` 時加入 `kCGImageSourceSubsampleFactor: 4`（JPEG DCT 快速路徑）
  - JPEG 12MP → 120px 預期 ~2-4ms（vs 目前 240px ~8.6ms）
  - 所有格式通用（JPEG/PNG/HEIC/RAW），不依賴 EXIF
- **改動量**：Constants.swift 1 行 + QuickGridView 3 行 + ImageLoader 5 行 ≈ **~10 行**
- **預期效果**：JPEG decode 降 60-70%，PNG 因需全解碼降幅較小

#### 3.2 優先級隊列 + 批次送出（策略 A+D 升級）⭐ 最高優先
- **問題**：FIFO throttle 不區分可見/prefetch，zoom tier 切換一次注入 ~976 任務
- **做法**：
  - ThumbnailThrottle 改用 **min-heap priority queue**（swift-collections `Heap`），
    以「距離可見中心的 index 距離」排序，可見中心優先 decode
  - `prefetchThumbnails` 限制每次只送 visible + 2 rows（而非全部 prefetch range）
  - Tier 切換時：先只 reload visible cells，off-screen 靠 scroll 漸進補充
- **技術背景**：Swift Concurrency 的 `TaskPriority` **不保證** actor 內排程順序
  （[Swift Forums](https://forums.swift.org/t/why-do-task-executions-appear-ordered-inside-an-actor-even-when-priorities-differ/80182)），
  必須 application-level 自行實作
- **改動量**：ThumbnailThrottle ~30 行重構 + QuickGridView prefetch ~15 行
- **預期效果**：首屏完成時間從 ~2.3s → ~200-400ms

#### 3.3 PNG 磁碟縮圖快取（策略 M 修訂）
- **問題**：影片截圖 PNG（.mkv/.mp4 frame）decode avg 84ms，是 JPEG 的 10 倍
  - PNG 無 DCT subsampling 快速路徑，必須全解碼再縮放
  - vImage/Accelerate 只加速 resize 部分（~14ms），decode 瓶頸（~70ms）無法繞過
- **做法**：
  - 副檔名判斷 `isSlowDecodeFormat()`（png/bmp/tiff）
  - 慢格式首次 decode 後存為 JPEG 到 `~/Library/Caches/com.cee/thumbnails/`
  - Key: `SHA256(filePath + modDate + maxSize).jpg`，modDate 自動失效
  - 後續讀取走 JPEG 快速路徑（~8ms vs 84ms）
- **改動量**：新增 DiskThumbnailCache ~50 行 + ImageLoader 分流 ~20 行
- **預期效果**：PNG 從 84ms → 8ms（快取命中後），首次仍 84ms

#### 3.4 算術計算 Visible Range（策略 B 延伸）
- **問題**：`indexPathsForVisibleItems()` 在 928 格時需 0.38ms（佔 scrollHandler 86%）
- **做法**：用 `documentVisibleRect` + cell size 算術計算 visible index range（O(1)）
  - `firstVisible = floor(scrollOffset.y / rowHeight) * columnsPerRow`
  - `lastVisible = ceil((scrollOffset.y + viewportHeight) / rowHeight) * columnsPerRow`
- **改動量**：QuickGridView scrollHandler ~15 行
- **預期效果**：visible 計算從 0.38ms → ~0.05ms

#### 3.5 捲動速度自適應（策略 D 延伸）
- **問題**：快速捲動時 cancel+prefetch churning 嚴重（每 50ms cancel ~500 + prefetch ~500）
- **做法**：
  - Velocity detection：`deltaY / deltaTime` 計算捲動速度
  - **慢速捲動**（< 500pt/s）：正常 prefetch + decode
  - **快速捲動**（≥ 500pt/s）：暫停 decode，只顯示已快取的縮圖
  - 捲動停止 ~100ms 後恢復 decode（idle timer）
- **改動量**：QuickGridView scrollHandler ~25 行
- **預期效果**：快速捲動時 scrollHandler 近零成本，停止後秒出圖

#### 3.6 進階優化（按需）

**3.6.1 CALayer Cell 替代（策略 K）**
- NSCollectionViewItem 繼承 NSViewController，比純 CALayer 重
- 如果 3.1-3.5 不夠，將 cell 改為純 `CALayer.contents = cgImage`
- 需重新實作 hit test + selection highlight
- **參考**：ImageContentView 已有 GPU 渲染先例

**3.6.2 Metal Tile Rendering（策略 N）**
- [Photon Transfer](https://toaster.llc/blog/high-perf-nsscrollview/) 方案：10⁶ 張 60fps
- CAMetalLayer + 2048 張 texture array 批次送 GPU
- AnchoredScrollView 攔截 scroll → GPU transform
- **僅在 >10K 可見格確認為瓶頸時考慮**，實作成本極高

**3.6.3 EXIF 內嵌縮圖 Placeholder（策略 L）**
- `kCGImageSourceCreateThumbnailFromImageIfAbsent` 優先提取 EXIF 縮圖（<1ms）
- 僅 JPEG（相機拍攝）/HEIC/RAW 有內嵌，軟體輸出 JPEG 和 PNG 沒有
- 可作為 decode 完成前的 instant placeholder，但覆蓋率不穩定
- **3.1 的自適應解析度更通用**，EXIF 作為可選增強

**Phase 3 預期成果**：
- 3.1+3.2 組合：極小 zoom 首屏從 ~2.3s → **~200-400ms**
- 3.3：影片 PNG 從 84ms → **8ms**（快取後）
- 3.4+3.5：scrollHandler 從 0.44ms → **~0.1ms**，快速捲動零 decode 開銷

---

## 效能 Log 分析（2026-03-05 實測數據）

> 測試環境：Release build（`-O` 優化），Apple Silicon，無 debugger attach

### 0421.txt — 極小 zoom 快速捲動（2.5 秒）
- scrollHandler: avg=0.44ms, visible=**928 格**, cancel 最多 533 任務
- decode: avg=8.59ms, p95=19ms, p99=52ms, **max=117ms（影片 PNG）**
- throttle: avg waited=863ms, **max=1547ms**, peak waiters=**728**
- 影片截圖 PNG（10 個）: avg=**84ms**，佔 4 workers 中 1 個 thread 80ms+

### 0422.txt — pinch zoom 放大（2.3 秒）
- decode: avg=9.10ms, p95=17.9ms, max=41ms（正常 JPEG）
- throttle: avg waited=1118ms, **max=2259ms**, 起始 waiters=**976**
- Zoom tier 切換一次性注入 ~980 個任務，全部消化耗時 **2.27 秒**

### 瓶頸排名
1. **Throttle 積壓**（4 workers vs ~1000 任務）→ 3.2 解決
2. **Decode 過大**（240px vs 60px 顯示）→ 3.1 解決
3. **影片 PNG 極慢**（avg 84ms）→ 3.3 解決
4. **visible 計算成本**（0.38ms, 86%）→ 3.4 解決

---

## 技術決策記錄

### 為什麼選 Swift Concurrency 而非 GCD/OperationQueue？
- Cee 已使用 actor + Task 架構，回退 GCD 會製造 Sendability 衝突
- Swift cooperative thread pool 天然防 thread explosion
- OperationQueue 的 `maxConcurrentOperationCount` 好用，但 actor-based throttle 可達到相同效果

### 為什麼不用 NSCache？
- 驅逐策略不透明（Michael Tsai：剛放入的物件可能立即被驅逐）
- Grid 視窗策略（visible ± buffer）提供更可預測的行為

### 為什麼 PNG 需要磁碟快取但 JPEG 不需要？
- JPEG 有 DCT subsampling 快速路徑，240px decode ~8ms，不值得磁碟 I/O
- PNG 必須全解碼再縮放，1080p → 240px 需 84ms，磁碟快取後走 JPEG 路徑 ~8ms
- 快取格式用 JPEG（即使原圖是 PNG），利用 JPEG 的快速 decode

### 為什麼 Swift Concurrency TaskPriority 不夠用？
- Swift actor 內部任務排程是 **implementation-defined**，不保證按 TaskPriority 排序
- 不能靠 `.high` vs `.utility` 保證可見格先 decode
- 必須在 application level 用 priority queue 自行實作排程

---

## 參考來源

### 效能基準
- [Fast Thumbnails with CGImageSource](https://macguru.dev/fast-thumbnails-with-cgimagesource/) — CGImageSource 比 NSImage 快 40x，含各格式 decode 時間實測
- [Zero to Photon: Metal Grid](https://toaster.llc/blog/high-perf-nsscrollview/) — 百萬縮圖 Metal 渲染（[GitHub](https://github.com/toasterllc/AnchoredScrollView)）

### Apple 官方
- [WWDC21: Make blazing fast lists and collection views](https://developer.apple.com/videos/play/wwdc2021/10252/)
- [kCGImageSourceSubsampleFactor](https://developer.apple.com/documentation/imageio/kcgimagesourcesubsamplefactor) — JPEG/HEIF/PNG subsample 支援
- [DispatchSource Memory Pressure](https://developer.apple.com/documentation/dispatch/dispatchsource/memorypressureevent)
- [Optimizing image-processing performance](https://developer.apple.com/documentation/accelerate/optimizing-image-processing-performance) — vImage 最佳實踐

### 記憶體管理
- [NSCache and LRUCache](https://mjtsai.com/blog/2025/05/09/nscache-and-lrucache/) — NSCache 驅逐問題
- [NSImage is Dangerous](https://wadetregaskis.com/nsimage-is-dangerous/) — NSImage 隱藏快取行為
- [Downsampling images for better memory](https://mehmetbaykar.com/posts/reduce-ios-image-memory-with-downsampling/)

### 執行緒與並發
- [Swift Forums: Actor task ordering vs priority](https://forums.swift.org/t/why-do-task-executions-appear-ordered-inside-an-actor-even-when-priorities-differ/80182)
- [Netflix concurrency-limits](https://github.com/Netflix/concurrency-limits) — Gradient2Limit adaptive concurrency
- [Swift Collections (Heap)](https://github.com/apple/swift-collections) — Priority queue 實作

### 業界實踐
- [FlowVision (GitHub)](https://github.com/netdcy/flowvision) — macOS 圖片瀏覽器，BTree 排序 + 效能優化
- [TheNounProject/CollectionView](https://github.com/TheNounProject/CollectionView) — 自訂高效能 NSCollectionView 替代
- [NSCollectionView Performance Test](https://github.com/seido/testCollectionViewPerformance)
- [JPEG thumbnail formats (EXIF)](https://entropymine.wordpress.com/2018/07/01/jpeg-thumbnail-formats/) — EXIF 縮圖規格
- [Image Resizing Techniques](https://nshipster.com/image-resizing/) — 五種 resize 方案效能比較
