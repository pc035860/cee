import Foundation

enum Constants {
    static let defaultWindowWidth: CGFloat = 800
    static let defaultWindowHeight: CGFloat = 600
    static let defaultWindowSizeRatio: CGFloat = 0.8   // 首次視窗使用螢幕可見區域 80%
    static let minWindowContentWidth: CGFloat = 320
    static let minWindowContentHeight: CGFloat = 240
    static let cacheRadius: Int = 2                     // 預載當前 ±2 張
    static let prefetchDirectionExtraCount: Int = 5     // 方向性 prefetch 額外預載數
    static let scrollEdgeThreshold: CGFloat = 2.0       // 捲動邊界容差 px
    static let zoomStep: CGFloat = 0.25                 // 鍵盤縮放步進
    static let minMagnification: CGFloat = 0.1
    static let maxMagnification: CGFloat = 10.0
    static let arrowPanStep: CGFloat = 75.0                // 方向鍵平移步距 px
    static let arrowPanAnimationDuration: TimeInterval = 0.1  // 方向鍵平移動畫時長

    // Status Bar
    static let statusBarHeight: CGFloat = 22
}
