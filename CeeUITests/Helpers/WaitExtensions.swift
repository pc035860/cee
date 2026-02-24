import XCTest

extension XCUIElement {
    static let defaultTimeout: TimeInterval = 15

    /// Cookpad-style chainable wait
    @discardableResult
    func wait(
        until expression: @escaping (XCUIElement) -> Bool,
        timeout: TimeInterval = defaultTimeout,
        message: @autoclosure () -> String = "",
        file: StaticString = #file,
        line: UInt = #line
    ) -> Self {
        if expression(self) { return self }

        let predicate = NSPredicate { _, _ in expression(self) }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)

        if result != .completed {
            let msg = message()
            XCTFail(msg.isEmpty ? "Timed out waiting for condition on \(self)" : msg,
                     file: file, line: line)
        }
        return self
    }

    /// KeyPath-based wait
    @discardableResult
    func wait(
        until keyPath: KeyPath<XCUIElement, Bool>,
        timeout: TimeInterval = defaultTimeout,
        message: @autoclosure () -> String = "",
        file: StaticString = #file,
        line: UInt = #line
    ) -> Self {
        wait(until: { $0[keyPath: keyPath] }, timeout: timeout,
             message: message(), file: file, line: line)
    }

    /// Wait for element to disappear
    func waitForNonExistence(timeout: TimeInterval = defaultTimeout) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        return result == .completed
    }
}
