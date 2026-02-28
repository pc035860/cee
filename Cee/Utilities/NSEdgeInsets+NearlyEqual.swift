import AppKit

extension NSEdgeInsets {
    /// 判斷兩組 insets 是否在容忍範圍內相等
    func isNearlyEqual(to other: NSEdgeInsets, epsilon: CGFloat = 0.5) -> Bool {
        abs(top - other.top) <= epsilon &&
        abs(left - other.left) <= epsilon &&
        abs(bottom - other.bottom) <= epsilon &&
        abs(right - other.right) <= epsilon
    }
}
