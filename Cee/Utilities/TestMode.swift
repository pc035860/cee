import Foundation
import OSLog

enum DebugCentering {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Cee", category: "CenteringDebug")

    static let isEnabled: Bool = {
        let processInfo = ProcessInfo.processInfo
        if processInfo.environment["CEE_DEBUG_CENTERING"] == "1" {
            return true
        }
        return processInfo.arguments.contains("--debug-centering")
    }()

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = message()
        logger.log("\(text, privacy: .public)")
        fputs("[CenteringDebug] \(text)\n", stderr)
    }
}

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
