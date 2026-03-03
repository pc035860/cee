@testable import Cee
import XCTest

final class NavigationThrottleTests: XCTestCase {

    func testThrottle_blocksWithinInterval() {
        var throttle = NavigationThrottle(interval: 0.05, lastTime: .distantPast)
        let now = Date()
        XCTAssertTrue(throttle.shouldProceed(now: now))
        // Within 50ms - should block
        let soon = now.addingTimeInterval(0.01)
        XCTAssertFalse(throttle.shouldProceed(now: soon))
    }

    func testThrottle_allowsAfterInterval() {
        var throttle = NavigationThrottle(interval: 0.05, lastTime: .distantPast)
        let now = Date()
        XCTAssertTrue(throttle.shouldProceed(now: now))
        // After 50ms - should allow
        let later = now.addingTimeInterval(0.06)
        XCTAssertTrue(throttle.shouldProceed(now: later))
    }
}
