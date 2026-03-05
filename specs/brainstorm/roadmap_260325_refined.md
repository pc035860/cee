# Quick Grid UX 優化 Roadmap（精煉版）

> **研究日期**：2026-03-05  
> **實作日期**：2026-03-06
> **來源**：todo_260325.md 四項任務 + 程式碼探索結果  
> **狀態**：✅ 已完成

---

## 總覽

| # | 任務 | 複雜度 | 依賴 | 建議順序 | 狀態 |
|---|------|--------|------|----------|------|
| 1 | Scrollbar 優化 | 低 | 無 | 1st | ✅ 完成 |
| 2 | 進入/離開 Grid 時捲動到當前圖片 | 低 | 無 | 2nd | ✅ 完成（併入 #1） |
| 3 | Pinch zoom 高 loading 時中斷 | 中 | 無 | 3rd | ✅ 完成 |
| 4 | PageUp/PageDown 支援 | 低 | #1 | 4th | ✅ 完成 |

**實作順序**：1 → 3 → 4（#2 功能已併入 #1 實作）

---

## Completion Status

### #1 Scrollbar 優化
- 實作：`GridScrollView.wantsVerticalScroller` 動態屬性
- 設定：`scrollerStyle = .overlay`, `autohidesScrollers = true`
- 更新位置：`gridFrameDidChange()`, `configure()`, `applyItemSize()`

### #2 捲動到當前圖片
- 實作：在 `configure()` 中使用 `layoutSubtreeIfNeeded()` + `scrollItemIntoView(at:animated:)`
- 取代不可靠的 `scrollToItems`

### #3 Pinch zoom 中斷
- 實作：延遲 tier change reload ~150ms（gesture ended 後執行）
- 新增 `tierChangeWorkItem`, `pendingTierChange` 屬性
- 支援 `phase` 參數（結合 `momentumPhase`）

### #4 PageUp/PageDown 支援
- 實作：`scrollGridPage(by:)` 方法
- 支援 Space 鍵（等同 PageDown）

---

## 1. Scrollbar 優化 ✅

### 現況

- `GridScrollView`（QuickGridView.swift:19-59）override `hasVerticalScroller` / `hasHorizontalScroller` 永遠回傳 `false`
- 註解說明：NSCollectionView 在 layout/reloadData 時會重新啟用 scrollers，故刻意鎖住
- 專案中無 `scrollerStyle`、`autohidesScrollers` 等設定

### 解決方案概念

**A. 最小改動（推薦 MVP）**

1. 移除或修改 override，改為依內容是否可捲動動態決定：
   - `documentView.frame.height > bounds.height` → `hasVerticalScroller = true`
2. 在 `GridScrollView.init` 設定：
   - `scrollerStyle = .overlay`（浮動、半透明，較現代）
   - `autohidesScrollers = true`（捲動結束後自動隱藏）

**B. 維持 override 但改為可控制**

- 若 NSCollectionView 在 layout 時會強制啟用 scrollers，可保留 override，但改為讀取一個 `wantsScrollers` 屬性
- 在 `layout()` 完成後或 `gridFrameDidChange` 時，依 `documentView.frame.height > bounds.height` 更新 `wantsScrollers`

**已決策**

- `scrollerStyle = .overlay`
- 橫向捲軸：不顯示（`hasHorizontalScroller = false`）

---

## 2. 進入/離開 Grid 時捲動到當前圖片

### 現況

- `configure()` 已有 `scrollToItems(at: [indexPath], scrollPosition: .centeredVertically)`（QuickGridView.swift:818-825）
- **根因**：`NSCollectionView.scrollToItems` 不可靠（CLAUDE.md 已註記）
- 鍵盤導航時使用 `scrollItemIntoView`（layoutAttributesForItem + scrollTargetYForItem + clipView.setBoundsOrigin）較可靠

### 解決方案概念

**A. 複用 scrollItemIntoView 邏輯（推薦）**

在 `configure()` 的 `DispatchQueue.main.async` 區塊中：

1. 改為呼叫 `scrollItemIntoView(at: indexPath, animated: false)` 取代 `scrollToItems`
2. `scrollItemIntoView` 已實作：`layoutAttributesForItem` → `scrollTargetYForItem` → `clipView.setBoundsOrigin`

**B. 處理 layout 尚未完成的時序（已決策）**

- `reloadData()` 後 layout 可能非同步，`layoutAttributesForItem` 在 layout 未完成時可能回傳 nil
- **決策**：使用 `collectionView.layoutSubtreeIfNeeded()` 強制同步 layout 後再捲動
- 理由：一次呼叫即可保證 layout 完成，行為穩定；進入 Grid 僅執行一次，成本可接受

**實作範例**

```swift
DispatchQueue.main.async { [weak self] in
    guard let self else { return }
    self.collectionView.layoutSubtreeIfNeeded()
    self.scrollItemIntoView(at: indexPath, animated: false)
    self.collectionView.selectionIndexPaths = [indexPath]
}
```

- 離開 Grid 時：單圖模式本身會顯示 `currentIndex` 對應的圖片，無需額外捲動

---

## 3. Trackpad pinch zoom 在高 loading 時被中斷

### 現況

- Pinch 由 `GridCollectionView.magnify(with:)` 接收，呼叫 `onCellSizeChange` → `applyItemSize`
- 高 loading 時 main thread 可能被佔用：
  - `clipViewBoundsDidChange`（~20Hz）：cancel、evict、prefetch
  - `applyItemSize`：tier 變更時 `reloadVisibleThumbnails()`（indexPathsForVisibleItems + 多個 loadThumbnail）
  - Thumbnail 完成：`setThumbnail`、`enforceGridThumbnailCap` 等回呼

### 解決方案概念

**A. 降低 pinch 期間的 main thread 負擔（推薦）**

1. **Tier 變更時延遲 reload**：pinch 進行中（例如 `magnification` 事件連續觸發）時，若跨越 tier，不立即 `reloadVisibleThumbnails()`，改為設一個 ~150ms 的 idle timer，手勢停止後再執行
2. **Thumbnail 完成批次化**：多張 thumbnail 同時完成時，改為 `DispatchQueue.main.async` 合併到下一 frame，避免同一 run loop 內連續多個 `setThumbnail`

**B. 提高 pinch 事件優先級**

- 理論上 `magnify(with:)` 已在 first responder，但若 main thread 阻塞，事件仍會堆積
- 可考慮在 `applyItemSize` 內用 `DispatchQueue.main.async(flags: .userInteractive)` 確保 layout 更新在較高優先級執行（需驗證是否有效）

**C. 簡化 tier 變更時的處理**

- 目前 tier 變更會 `cancelPendingThumbnailTasks()` + `reloadVisibleThumbnails()`
- 可改為只 cancel，不立即 reload，讓 scroll 時的 prefetch 自然補上（減少 pinch 瞬間的負擔）

**已決策**

- 方案 A.1（延遲 ~150ms reload）：可接受 tier 切換時短暫顯示舊解析度

---

## 4. PageUp/PageDown 支援（有捲軸後）

### 現況

- `GridCollectionView.keyDown` 只處理 Return、G、Cmd+=、Cmd+-，PageUp/PageDown 交給 `super`
- `ImageScrollView` 有完整 PageUp/PageDown 處理，並有 `scrollViewRequestPageDown` / `scrollViewRequestPageUp` delegate
- Grid 目前無捲軸，故「有捲軸後」才支援 PageUp/PageDown 是合理的前置條件

### 解決方案概念

**A. 在 GridCollectionView.keyDown 加入 case**

```swift
case 121:  // PageDown
    onPageDown?()
case 116:  // PageUp
    onPageUp?()
case 49 where modifiers == []:  // Space（可選，與 PageDown 同義）
    onPageDown?()
```

**B. 實作 scrollGridPageDown / scrollGridPageUp**

- 參考 `ImageViewController.scrollPageDownOrNext` / `scrollPageUpOrPrev`（約 836-869 行）
- 使用 `gridScrollView.contentView.bounds`：
  - PageDown：`origin.y -= visibleRect.height`（向下捲動一頁）
  - PageUp：`origin.y += visibleRect.height`（向上捲動一頁）
- 邊界 clamp：`min(0, max(maxScrollY, newY))`

**C. 與 #1 的整合**

- 當 `hasVerticalScroller = true` 時，PageUp/PageDown 才有意義（使用者可看到捲軸位置變化）
- 若維持無捲軸，PageUp/PageDown 仍可實作，但視覺回饋較弱

**已決策**

- 到底/頂時**無操作**（不 wrap 到另一側）。Grid 無「下一張/上一張」語意，維持一般捲動行為。

---

## 實作順序建議

1. **#1 Scrollbar**：先讓捲軸顯示，為 #4 鋪路
2. **#2 捲動到當前圖片**：獨立、低風險，可立即改善體驗
3. **#3 Pinch 中斷**：需實測與調參，建議先做 A.1（tier 變更延遲 reload）
4. **#4 PageUp/PageDown**：依賴 #1，實作簡單

---

## 已決策項目

| 項目 | 決策 |
|------|------|
| Scrollbar 風格 | **overlay** |
| 橫向捲軸 | 不顯示 |
| Pinch tier 變更 | 延遲 ~150ms reload（可接受短暫舊解析度） |
| PageUp/PageDown 邊界 | 到底/頂無操作 |
| #2 Layout 時序 | `layoutSubtreeIfNeeded()` 後再捲動 |

---

## 參考資料

- `Cee/Views/QuickGridView.swift`：GridScrollView、GridCollectionView、configure、scrollItemIntoView、applyItemSize
- `Cee/Views/ImageScrollView.swift`：PageUp/PageDown keyDown、scroll delegate
- `Cee/Controllers/ImageViewController.swift`：scrollPageDownOrNext、scrollPageUpOrPrev
- `CLAUDE.md`：NSCollectionView scrollToItems unreliable、NSScrollView 相關 gotchas
