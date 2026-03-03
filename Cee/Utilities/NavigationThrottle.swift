import Foundation

/// 導航節流：限制快速 key repeat 時的觸發頻率（~20fps）
struct NavigationThrottle {
    private var lastTime: Date
    private let interval: TimeInterval

    init(interval: TimeInterval = 0.05, lastTime: Date = .distantPast) {
        self.interval = interval
        self.lastTime = lastTime
    }

    /// 是否應繼續執行導航。若在 interval 內則回傳 false。
    mutating func shouldProceed(now: Date = Date()) -> Bool {
        let elapsed = now.timeIntervalSince(lastTime)
        guard elapsed >= interval else { return false }
        lastTime = now
        return true
    }
}
