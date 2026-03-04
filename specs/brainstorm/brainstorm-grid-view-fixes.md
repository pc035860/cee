# Grid View 修正 Roadmap

## 問題 1：Highlight 邊框被裁切

### 現象
- **藍色 highlight**（當前顯示圖片）：右側和左上角的邊框有機會被裁切
- **白色 highlight**（鍵盤選擇）：縮放時右側和左上角同樣被裁切

### 現行實作分析
- `QuickGridCell` 使用單一 `CALayer` border 作為 highlight（`QuickGridCell.swift`）
- `highlightLayer` 是 cell `layer` 的 sublayer，`borderWidth = 2`，`cornerRadius = 4`
- Cell 的 `layer.masksToBounds = true` → border 的外半部分（1pt）被裁切
- `autoresizingMask = [.layerWidthSizable, .layerHeightSizable]` 跟隨 cell 大小
- 藍色：`NSColor.controlAccentColor`，白色：`NSColor.white`

### 根因推測
border 畫在 layer bounds 的邊緣上（內外各佔一半），而 `masksToBounds = true` 把外側裁掉。加上 NSCollectionView FlowLayout 在排版時，相鄰 cell 的 frame 緊貼，導致邊框被鄰居覆蓋。

### 建議修正方向
在 cell view 上方疊加一個獨立的 highlight overlay view（或 overlay layer），使其：
1. 不受 `masksToBounds` 影響
2. 繪製區域略大於 cell bounds（或使用 inset 讓 thumbnail 內縮）
3. z-order 高於所有 cell content，確保不被覆蓋

---

## 問題 2：Grid 縮放時 Layout 閃爍

### 現象
進行 zoom in / zoom out（pinch、Cmd+Scroll、Cmd+=/-）時，畫面偶爾出現閃爍或不穩定的 layout 跳動。

### 現行實作分析
- 三種縮放路徑最終都呼叫 `applyItemSize(_:animated:)`（`QuickGridView.swift`）
- 一般縮放：`updateSpaceAroundLayout()` → `invalidateLayout()`（不 reload data）
- 跨越 thumbnail tier 邊界（240→480→1024px）：`cancelAndClearThumbnails()` + `reloadData()`
- Space-around 計算使用 `floor()` 和 `max(0, ...)` 防護，`lastLayoutWidth` 快取避免重複計算
- 動畫路徑（Cmd+=/-）使用 `NSAnimationContext`（0.15s）+ `allowsImplicitAnimation`

### 可能的閃爍原因
1. **Tier 邊界跨越**：`reloadData()` 是昂貴操作，清除所有 cell 重建，可能造成短暫空白
2. **列數跳變**：cell 大小在臨界點附近時，columns 數在 N ↔ N+1 間跳動
3. **Space-around 重算**：inset/spacing 突變導致 layout 位置大幅移動
4. **動畫與非動畫路徑混合**：pinch 期間如果也觸發 tier 變更，animated=false 的 invalidateLayout 和 reloadData 交錯

### 建議修正方向
- 調查具體閃爍場景（tier 邊界？列數跳變？）再針對性修正
- 考慮 tier 切換時使用漸進載入而非全量 reloadData
- 列數跳變時可加入 hysteresis（遲滯）避免在臨界點反覆切換

---

## 問題 3：鍵盤導航不自動捲動到選取項目

### 現象
在 Grid 中使用方向鍵瀏覽，當選取項目移出 viewport 範圍時，畫面不會自動捲動跟隨。

### 現行實作分析
- `configure()` 初始化時有呼叫 `scrollToItems(at:scrollPosition:.centeredVertically)`（`QuickGridView.swift`）
- 但 `didSelectItemsAt` delegate 中**沒有**呼叫 `scrollToItems`
- NSCollectionView 的內建方向鍵導航會改變 selection，但不保證自動 scroll into view
- 目前 `didSelectItemsAt` 只做了 mouse click 過濾（`event.type == .leftMouseUp`），鍵盤路徑無額外處理

### 建議修正方向
在 `didSelectItemsAt` 中（或監聽 selection change），當偵測到非滑鼠觸發的 selection 變更時，呼叫 `scrollToItems(at:scrollPosition:)` 確保選取項目保持在 viewport 內。使用 `.nearestHorizontalEdge` 或自訂邏輯避免不必要的大幅跳動。

---

## 問題 4：Grid Drag-Drop 只能在間隙觸發

### 現象
拖放檔案/資料夾到 Grid 上時，只有拖到 cell 之間的「間隙」才能觸發 drop，拖到 cell 上方無法觸發。使用者必須刻意避開圖片找到縫隙才能放手。

### 現行實作分析
- `QuickGridView`（NSView）註冊了 `.fileURL` drag type（`QuickGridView.swift`）
- 拖放方法（`draggingEntered`/`performDragOperation`）實作在 `QuickGridView` 上
- `QuickGridCell` **沒有**實作任何拖放方法，也沒有呼叫 `unregisterDraggedTypes()`
- View 階層：`QuickGridView` → `GridScrollView` → `NSClipView` → `GridCollectionView` → `QuickGridCell`

### 根因分析
CLAUDE.md 已記錄此 AppKit 行為：
> For drag-drop containers, child views (especially `NSImageView`) must call `unregisterDraggedTypes()` to prevent intercepting parent's drag session — AppKit drag destination resolution doesn't purely use `hitTest`.

Cell 內的 `NSImageView` 預設會攔截 drag 事件，阻止事件冒泡到父層的 `QuickGridView`。

### 建議修正方向
在 `QuickGridCell` 的 view 設定中，對 `thumbnailView`（NSImageView）呼叫 `unregisterDraggedTypes()`，讓 drag 事件能穿透 cell 冒泡到 `QuickGridView`。這是 CLAUDE.md 中已記錄的標準解法。

---

## 執行優先序建議

| 優先 | 問題 | 難度 | 理由 |
|------|------|------|------|
| 1 | #4 Drag-Drop 穿透 | 低 | 已知解法（`unregisterDraggedTypes`），一行修正 |
| 2 | #3 鍵盤自動捲動 | 低 | 加一個 `scrollToItems` 呼叫 |
| 3 | #1 Highlight 裁切 | 中 | 需重構 highlight 為 overlay 機制 |
| 4 | #2 縮放閃爍 | 中~高 | 需先定位具體閃爍場景再修正 |
