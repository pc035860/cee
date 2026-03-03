import Foundation

/// Option+scroll 快速切圖的累積器
/// 追蹤滾輪 delta 累積量和動量計數，達到閾值後觸發導航。
/// 遵循 NavigationThrottle 的 testable struct 模式。
struct OptionScrollAccumulator {
    private(set) var accumulator: CGFloat = 0
    private(set) var momentumCount: Int = 0

    let trackpadThreshold: CGFloat
    let mouseThreshold: CGFloat
    let momentumLimit: Int

    init(
        trackpadThreshold: CGFloat = Constants.optionScrollThresholdTrackpad,
        mouseThreshold: CGFloat = Constants.optionScrollThresholdMouse,
        momentumLimit: Int = Constants.optionScrollMomentumLimit
    ) {
        self.trackpadThreshold = trackpadThreshold
        self.mouseThreshold = mouseThreshold
        self.momentumLimit = momentumLimit
    }

    /// 累積 scroll delta，回傳應導航的圖片數量。
    /// - Parameters:
    ///   - delta: 已校正方向的 delta（正 = next，負 = previous）
    ///   - isTrackpad: 是否為 trackpad（影響閾值）
    ///   - isMomentum: 是否在動量階段（受 momentumLimit 限制）
    /// - Returns: 導航數量（正 = next，負 = previous，0 = 不導航）
    mutating func accumulate(delta: CGFloat, isTrackpad: Bool, isMomentum: Bool) -> Int {
        // 動量上限檢查
        if isMomentum && momentumCount >= momentumLimit {
            return 0
        }

        accumulator += delta

        let threshold = isTrackpad ? trackpadThreshold : mouseThreshold
        guard threshold > 0 else { return 0 }

        let steps = Int(accumulator / threshold)
        guard steps != 0 else { return 0 }

        // 保留餘數
        accumulator -= CGFloat(steps) * threshold

        // 更新動量計數
        if isMomentum {
            momentumCount += abs(steps)
            // 動量計數超限時裁剪
            if momentumCount > momentumLimit {
                let overflow = momentumCount - momentumLimit
                momentumCount = momentumLimit
                let sign = steps > 0 ? 1 : -1
                let clamped = abs(steps) - overflow
                return clamped > 0 ? clamped * sign : 0
            }
        }

        return steps
    }

    /// 新手勢開始時重置累積器和動量計數
    mutating func resetForNewGesture() {
        accumulator = 0
        momentumCount = 0
    }
}
