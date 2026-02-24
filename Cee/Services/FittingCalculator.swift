import Foundation

struct FittingOptions: Codable {
    var shrinkHorizontally: Bool = true
    var shrinkVertically: Bool = true
    var stretchHorizontally: Bool = false
    var stretchVertically: Bool = false
}

struct FittingCalculator {
    /// 根據 FittingOptions 計算圖片應顯示的大小
    static func calculate(
        imageSize: NSSize,
        viewportSize: NSSize,
        options: FittingOptions
    ) -> NSSize {
        var width = imageSize.width
        var height = imageSize.height

        let needsShrinkH = width > viewportSize.width && options.shrinkHorizontally
        let needsShrinkV = height > viewportSize.height && options.shrinkVertically
        let needsStretchH = width < viewportSize.width && options.stretchHorizontally
        let needsStretchV = height < viewportSize.height && options.stretchVertically

        if needsShrinkH || needsStretchH {
            let scaleX = viewportSize.width / imageSize.width
            width = viewportSize.width
            if !needsShrinkV && !needsStretchV {
                height = imageSize.height * scaleX  // 等比例
            }
        }

        if needsShrinkV || needsStretchV {
            let scaleY = viewportSize.height / imageSize.height
            height = viewportSize.height
            if !needsShrinkH && !needsStretchH {
                width = imageSize.width * scaleY  // 等比例
            }
        }

        // 兩個方向都要適配時，取最小縮放比（Fit on Screen 邏輯）
        if (needsShrinkH && needsShrinkV) || (needsStretchH && needsStretchV) {
            let scaleX = viewportSize.width / imageSize.width
            let scaleY = viewportSize.height / imageSize.height
            let scale = min(scaleX, scaleY)  // 取較小比例，確保完全可見
            width = imageSize.width * scale
            height = imageSize.height * scale
        }

        return NSSize(width: width, height: height)
    }
}
