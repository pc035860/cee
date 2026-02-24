import XCTest

extension XCUIElement {
    /// macOS: scroll by delta (trackpad/mouse wheel simulation)
    func scrollDown(by delta: CGFloat = 50) {
        scroll(byDeltaX: 0, deltaY: -delta)
    }

    func scrollUp(by delta: CGFloat = 50) {
        scroll(byDeltaX: 0, deltaY: delta)
    }

    /// Scroll until target element becomes hittable
    @discardableResult
    func scrollToReveal(_ element: XCUIElement, maxAttempts: Int = 20) -> Bool {
        guard self.elementType == .scrollView else {
            return false
        }

        for _ in 0..<maxAttempts {
            if element.isHittable { return true }

            let before = element.frame
            scrollDown(by: 50)

            if element.frame == before { break }  // 到底了
        }
        return element.isHittable
    }
}
