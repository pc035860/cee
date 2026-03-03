@testable import Cee
import XCTest

final class NavigationThrottleTests: XCTestCase {

    func testThrottle_blocksWithinInterval() {
        var throttle = NavigationThrottle(interval: 0.05)
        let now: CFAbsoluteTime = 1000.0
        XCTAssertTrue(throttle.shouldProceed(now: now))
        // Within 50ms - should block
        XCTAssertFalse(throttle.shouldProceed(now: now + 0.01))
    }

    func testThrottle_allowsAfterInterval() {
        var throttle = NavigationThrottle(interval: 0.05)
        let now: CFAbsoluteTime = 1000.0
        XCTAssertTrue(throttle.shouldProceed(now: now))
        // After 50ms - should allow
        XCTAssertTrue(throttle.shouldProceed(now: now + 0.06))
    }
}
