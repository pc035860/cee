import AppKit

/// 連續捲動內容視圖（Webtoon-style vertical scrolling）
/// Phase 1 Stub - 最小實作以通過編譯
class ContinuousScrollContentView: NSView {

    // MARK: - Configuration

    /// 配置視圖（未來會接收 folder 和 imageLoader）
    func configure(with folder: ImageFolder, imageLoader: ImageLoader) {
        // Phase 1 Stub: 僅設置 frame 讓測試通過
        // TODO: Phase 2 - 實作預載圖片尺寸和佈局
        self.frame = NSRect(x: 0, y: 1, width: 800, height: 1000)
    }

    // MARK: - View Recycling

    /// 更新可見範圍內的 slots
    func updateVisibleSlots(for visibleRect: NSRect) {
        // Phase 1 Stub: 空實作
        // TODO: Phase 2 - 實作 view recycling
    }

    // MARK: - Layout

    /// 計算指定索引圖片的 frame（fit-to-width）
    func frameForImage(at index: Int) -> NSRect {
        // Phase 1 Stub: 返回空 frame
        // TODO: Phase 2 - 實作 fit-to-width 佈局
        return .zero
    }

    /// 計算當前中心點對應的圖片索引
    func calculateCurrentIndex(for scrollY: CGFloat) -> Int {
        // Phase 1 Stub: 返回 0
        // TODO: Phase 2 - 實作 index 追蹤
        return 1
    }
}
