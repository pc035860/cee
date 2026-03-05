import Foundation

/// Monitors system memory pressure and invokes callbacks.
/// Used as safety net for extreme memory situations.
@MainActor
final class MemoryPressureMonitor {
    enum PressureLevel: Equatable {
        case warning, critical
    }

    var onPressure: ((PressureLevel) -> Void)?

    private var source: (any DispatchSourceMemoryPressure)?

    func start() {
        guard source == nil else { return }  // Idempotent — avoid leaking duplicate sources
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data
            if event.contains(.critical) {
                self.onPressure?(.critical)
            } else if event.contains(.warning) {
                self.onPressure?(.warning)
            }
        }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    /// Test-only: simulate a pressure event.
    func _testSimulatePressure(_ level: PressureLevel) {
        onPressure?(level)
    }
}
