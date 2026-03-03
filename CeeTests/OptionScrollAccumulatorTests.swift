import XCTest
@testable import Cee

final class OptionScrollAccumulatorTests: XCTestCase {

    // MARK: - Basic Accumulation

    func testBelowThresholdReturnsZero() {
        var acc = OptionScrollAccumulator(trackpadThreshold: 40, mouseThreshold: 8, momentumLimit: 10)
        XCTAssertEqual(acc.accumulate(delta: 10, isTrackpad: true, isMomentum: false), 0)
        XCTAssertEqual(acc.accumulate(delta: 10, isTrackpad: true, isMomentum: false), 0)
    }

    func testExactThresholdTriggersOne() {
        var acc = OptionScrollAccumulator(trackpadThreshold: 40, mouseThreshold: 8, momentumLimit: 10)
        XCTAssertEqual(acc.accumulate(delta: 40, isTrackpad: true, isMomentum: false), 1)
    }

    func testAccumulationAcrossMultipleCalls() {
        var acc = OptionScrollAccumulator(trackpadThreshold: 40, mouseThreshold: 8, momentumLimit: 10)
        XCTAssertEqual(acc.accumulate(delta: 25, isTrackpad: true, isMomentum: false), 0)
        XCTAssertEqual(acc.accumulate(delta: 20, isTrackpad: true, isMomentum: false), 1) // 45 → 1 step, remainder 5
    }

    func testRemainderPreserved() {
        var acc = OptionScrollAccumulator(trackpadThreshold: 40, mouseThreshold: 8, momentumLimit: 10)
        XCTAssertEqual(acc.accumulate(delta: 45, isTrackpad: true, isMomentum: false), 1)
        // remainder = 5, need 35 more
        XCTAssertEqual(acc.accumulate(delta: 34, isTrackpad: true, isMomentum: false), 0)
        XCTAssertEqual(acc.accumulate(delta: 1, isTrackpad: true, isMomentum: false), 1) // 5+34+1=40
    }

    func testMultipleStepsInOneEvent() {
        var acc = OptionScrollAccumulator(trackpadThreshold: 40, mouseThreshold: 8, momentumLimit: 10)
        XCTAssertEqual(acc.accumulate(delta: 120, isTrackpad: true, isMomentum: false), 3)
    }

    // MARK: - Negative Direction (Previous)

    func testNegativeDeltaNavigatesPrevious() {
        var acc = OptionScrollAccumulator(trackpadThreshold: 40, mouseThreshold: 8, momentumLimit: 10)
        XCTAssertEqual(acc.accumulate(delta: -40, isTrackpad: true, isMomentum: false), -1)
    }

    func testNegativeAccumulation() {
        var acc = OptionScrollAccumulator(trackpadThreshold: 40, mouseThreshold: 8, momentumLimit: 10)
        XCTAssertEqual(acc.accumulate(delta: -25, isTrackpad: true, isMomentum: false), 0)
        XCTAssertEqual(acc.accumulate(delta: -20, isTrackpad: true, isMomentum: false), -1)
    }

    // MARK: - Mouse vs Trackpad Threshold

    func testMouseUsesLowerThreshold() {
        var acc = OptionScrollAccumulator(trackpadThreshold: 40, mouseThreshold: 8, momentumLimit: 10)
        XCTAssertEqual(acc.accumulate(delta: 8, isTrackpad: false, isMomentum: false), 1)
    }

    func testTrackpadNeedsHigherThreshold() {
        var acc = OptionScrollAccumulator(trackpadThreshold: 40, mouseThreshold: 8, momentumLimit: 10)
        XCTAssertEqual(acc.accumulate(delta: 8, isTrackpad: true, isMomentum: false), 0)
    }

    // MARK: - Momentum Capping

    func testMomentumCapAt10() {
        var acc = OptionScrollAccumulator(trackpadThreshold: 10, mouseThreshold: 8, momentumLimit: 10)
        // Navigate 10 images in momentum
        for i in 1...10 {
            XCTAssertEqual(acc.accumulate(delta: 10, isTrackpad: true, isMomentum: true), 1,
                           "Step \(i) should navigate")
        }
        // 11th should be blocked
        XCTAssertEqual(acc.accumulate(delta: 10, isTrackpad: true, isMomentum: true), 0)
    }

    func testMomentumCapWithMultiSteps() {
        var acc = OptionScrollAccumulator(trackpadThreshold: 10, mouseThreshold: 8, momentumLimit: 10)
        // 8 steps via momentum
        XCTAssertEqual(acc.accumulate(delta: 80, isTrackpad: true, isMomentum: true), 8)
        // Only 2 more allowed
        XCTAssertEqual(acc.accumulate(delta: 50, isTrackpad: true, isMomentum: true), 2)
        // No more
        XCTAssertEqual(acc.accumulate(delta: 30, isTrackpad: true, isMomentum: true), 0)
    }

    func testNonMomentumIgnoresCap() {
        var acc = OptionScrollAccumulator(trackpadThreshold: 10, mouseThreshold: 8, momentumLimit: 10)
        // 15 steps without momentum — no cap
        for _ in 1...15 {
            XCTAssertEqual(acc.accumulate(delta: 10, isTrackpad: true, isMomentum: false), 1)
        }
    }

    // MARK: - Reset

    func testResetClearsAccumulatorAndMomentum() {
        var acc = OptionScrollAccumulator(trackpadThreshold: 40, mouseThreshold: 8, momentumLimit: 10)
        _ = acc.accumulate(delta: 30, isTrackpad: true, isMomentum: true)
        acc.resetForNewGesture()
        XCTAssertEqual(acc.accumulator, 0)
        XCTAssertEqual(acc.momentumCount, 0)
    }

    func testResetAllowsMomentumAgain() {
        var acc = OptionScrollAccumulator(trackpadThreshold: 10, mouseThreshold: 8, momentumLimit: 3)
        // Exhaust momentum cap
        _ = acc.accumulate(delta: 30, isTrackpad: true, isMomentum: true)
        XCTAssertEqual(acc.accumulate(delta: 10, isTrackpad: true, isMomentum: true), 0)
        // Reset and try again
        acc.resetForNewGesture()
        XCTAssertEqual(acc.accumulate(delta: 10, isTrackpad: true, isMomentum: true), 1)
    }

    // MARK: - Realistic Mouse Delta (with sensitivity factor)

    func testRealisticMouseDeltaWithSensitivity() {
        // 真實滑鼠 delta ~0.1-1.0，乘以 sensitivity=10 後送進 accumulator
        var acc = OptionScrollAccumulator(trackpadThreshold: 40, mouseThreshold: 8, momentumLimit: 10)
        let sensitivity: CGFloat = 10.0

        // 單次 delta=1.0 × 10 = 10.0 → 超過 threshold 8，觸發 1 step
        XCTAssertEqual(acc.accumulate(delta: 1.0 * sensitivity, isTrackpad: false, isMomentum: false), 1)
    }

    func testSmallMouseDeltaAccumulatesWithSensitivity() {
        var acc = OptionScrollAccumulator(trackpadThreshold: 40, mouseThreshold: 8, momentumLimit: 10)
        let sensitivity: CGFloat = 10.0

        // delta=0.3 × 10 = 3.0 → 不足 threshold 8
        XCTAssertEqual(acc.accumulate(delta: 0.3 * sensitivity, isTrackpad: false, isMomentum: false), 0)
        // 累積 3.0 + 3.0 = 6.0 → 不足
        XCTAssertEqual(acc.accumulate(delta: 0.3 * sensitivity, isTrackpad: false, isMomentum: false), 0)
        // 累積 6.0 + 3.0 = 9.0 → 超過 8，觸發 1 step，餘 1.0
        XCTAssertEqual(acc.accumulate(delta: 0.3 * sensitivity, isTrackpad: false, isMomentum: false), 1)
    }

    func testConsecutiveMouseScrollsWithSensitivity() {
        var acc = OptionScrollAccumulator(trackpadThreshold: 40, mouseThreshold: 8, momentumLimit: 10)
        let sensitivity: CGFloat = 10.0

        // 模擬連續快速滾輪，每次 delta=0.8 × 10 = 8.0 → 剛好 threshold
        XCTAssertEqual(acc.accumulate(delta: 0.8 * sensitivity, isTrackpad: false, isMomentum: false), 1)
        XCTAssertEqual(acc.accumulate(delta: 0.8 * sensitivity, isTrackpad: false, isMomentum: false), 1)
        XCTAssertEqual(acc.accumulate(delta: 0.8 * sensitivity, isTrackpad: false, isMomentum: false), 1)
    }
}
