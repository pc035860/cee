import Foundation

enum Constants {
    static let defaultWindowWidth: CGFloat = 800
    static let defaultWindowHeight: CGFloat = 600
    static let defaultWindowSizeRatio: CGFloat = 0.8   // 首次視窗使用螢幕可見區域 80%
    static let minWindowContentWidth: CGFloat = 300
    static let minWindowContentHeight: CGFloat = 300
    static let minWindowContentSize = NSSize(
        width: minWindowContentWidth,
        height: minWindowContentHeight
    )

    static let continuousScrollNewWindowContentWidth: CGFloat = 850
    static let cacheRadius: Int = 2                     // 預載當前 ±2 張
    static let prefetchDirectionExtraCount: Int = 5     // 方向性 prefetch 額外預載數

    /// PDF 頁面光柵化時，像素長邊上限（避免超大 crop 拖慢換頁／記憶體）
    static let maxPDFRenderLongEdgePixels: CGFloat = 4000
    static let optionKeyJumpAmount: Int = 10            // Option+方向鍵一次跳躍張數
    static let fullResLoadDelayAfterNav: TimeInterval = 0.1  // 導航停止後延遲載入全解析度
    static let scrollEdgeThreshold: CGFloat = 2.0       // 捲動邊界容差 px
    static let zoomStep: CGFloat = 0.25                 // 鍵盤縮放步進
    static let minMagnification: CGFloat = 0.1
    static let maxMagnification: CGFloat = 10.0
    static let arrowPanStep: CGFloat = 75.0                // 方向鍵平移步距 px
    static let arrowPanAnimationDuration: TimeInterval = 0.1  // 方向鍵平移動畫時長

    // Status Bar
    static let statusBarHeight: CGFloat = 22

    // Quick Grid
    static let quickGridCellSize: CGFloat = 160    // matches min; slider left = this size
    static let quickGridMinCellSize: CGFloat = 160  // tier2 decode 480px; user-preferred min zoom
    static let quickGridMaxCellSize: CGFloat = 512
    static let quickGridSliderMaxWidth: CGFloat = 400  // Finder-style centered slider
    static let quickGridSpacing: CGFloat = 4
    static let quickGridInset: CGFloat = 8
    static let quickGridCellAspectRatio: CGFloat = 9.0 / 16.0  // height / width, fallback default
    static let quickGridAspectRatioSampleCount: Int = 50       // 取樣數量 for median ratio

    // Grid Thumbnail Tiers — cell size boundary → thumbnail resolution
    static let quickGridTier0MinPx: CGFloat = 80       // micro-thumbnail pixel floor (ensures legibility)
    static let quickGridTier0QuantizeStep: CGFloat = 20 // quantization step to avoid cache churn on pinch
    static let quickGridSubsampleThresholdPx: CGFloat = 120  // ≤ this px → 4x DCT subsample fast path
    static let quickGridTier0Boundary: CGFloat = 60    // ≤60pt → adaptive micro-thumbnail (Phase 3.1)
    static let quickGridTier1Boundary: CGFloat = 120   // ≤120pt → tier1 size
    static let quickGridTier2Boundary: CGFloat = 240   // ≤240pt → tier2 size
    static let quickGridThumbnailSize1: CGFloat = 240  // low-res tier
    static let quickGridThumbnailSize2: CGFloat = 480  // mid-res tier
    static let quickGridThumbnailSize3: CGFloat = 720  // high-res tier (was 1024; halves memory per image)
    static let quickGridTierChangeDelay: TimeInterval = 0.15  // defer tier reload after pinch to avoid gesture interruption

    // Option+Scroll Fast Navigation (Phase 3)
    static let optionScrollThresholdTrackpad: CGFloat = 40   // trackpad 每張圖的累積閾值
    static let optionScrollThresholdMouse: CGFloat = 8       // 滑鼠滾輪每張圖的累積閾值
    static let optionScrollMouseSensitivity: CGFloat = 10.0  // 滑鼠 delta 放大因子（真實 delta ~0.1-1.0，需放大至閾值量級）
    static let optionScrollMouseResetInterval: TimeInterval = 0.3  // 滑鼠事件間隔超過此值則重置累積器
    static let optionScrollMomentumLimit: Int = 10           // 動量階段最多切換張數
    static let positionHUDFadeDelay: TimeInterval = 1.0      // HUD 無操作後開始淡出的延遲
    static let manualZoomHintFadeDelay: TimeInterval = 3.0   // 手動縮放提示停留時間

    // Page-turn scroll clamping
    static let scrollPositionClampTolerance: CGFloat = 1.0  // reflectScrolledClipView 強制位置的容差，避免浮點抖動
}
