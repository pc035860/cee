import Foundation

#if DEBUG
enum TestMode {
    static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
    }

    static var testFixturePath: URL? {
        guard let path = ProcessInfo.processInfo.environment["UITEST_FIXTURE_PATH"] else {
            return nil
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static var shouldResetState: Bool {
        ProcessInfo.processInfo.arguments.contains("--reset-state")
    }

    static var shouldDisableAnimations: Bool {
        ProcessInfo.processInfo.arguments.contains("--disable-animations")
    }
}
#endif
