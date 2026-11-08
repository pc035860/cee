import XCTest
@testable import Cee

@MainActor
final class FinderServiceTests: XCTestCase {

    func testServiceMessage_matchesAppDelegateSelector() {
        let services = Bundle(for: AppDelegate.self).infoDictionary?["NSServices"] as? [[String: Any]]
        let message = services?.first?["NSMessage"] as? String

        XCTAssertEqual(message, "openFolderService")
        XCTAssertTrue(AppDelegate().responds(to: Selector("openFolderService:userData:error:")))
    }

    func testServiceAcceptsFolders() {
        let services = Bundle(for: AppDelegate.self).infoDictionary?["NSServices"] as? [[String: Any]]
        let types = services?.first?["NSSendFileTypes"] as? [String]

        XCTAssertEqual(types, ["public.folder"])
    }
}
