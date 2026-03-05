import Foundation
import os.log

/// Lightweight performance logger for grid scroll diagnostics.
/// Output visible in Console.app → filter by "GridPerf".
/// Toggle at runtime: `GridPerfLog.enabled = false` to silence.
enum GridPerfLog {
    nonisolated(unsafe) static var enabled = true

    private static let log = OSLog(subsystem: "com.cee.app", category: "GridPerf")

    /// Log a timed block on the main thread (scroll handler, layout, etc.).
    static func measure(_ label: String, body: () -> Void) {
        guard enabled else { return body() }
        let start = CFAbsoluteTimeGetCurrent()
        body()
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        os_log(.debug, log: log, "%{public}@: %.2fms", label, ms)
    }

    /// Log a single metric value.
    static func log(_ message: String) {
        guard enabled else { return }
        os_log(.debug, log: log, "%{public}@", message)
    }

    /// Log a timed async operation (thumbnail decode, etc.). Call from Task context.
    static func measureAsync(_ label: String, body: () async -> Void) async {
        guard enabled else { return await body() }
        let start = CFAbsoluteTimeGetCurrent()
        await body()
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        os_log(.debug, log: log, "%{public}@ (async): %.2fms", label, ms)
    }
}
