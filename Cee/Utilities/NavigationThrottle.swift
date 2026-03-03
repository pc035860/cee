import Foundation

/// 導航節流：限制快速 key repeat 時的觸發頻率（~20fps）
/// 使用 CFAbsoluteTimeGetCurrent() 避免 Date() 的 NTP/時區影響
struct NavigationThrottle {
    private var lastTimestamp: CFAbsoluteTime
    private let interval: TimeInterval

    init(interval: TimeInterval = 0.05) {
        self.interval = interval
        self.lastTimestamp = 0  // epoch — 首次必定通過
    }

    /// 是否應繼續執行導航。若在 interval 內則回傳 false。
    /// `now` 參數供測試注入，生產路徑使用預設值
    mutating func shouldProceed(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Bool {
        guard now - lastTimestamp >= interval else { return false }
        lastTimestamp = now
        return true
    }
}
