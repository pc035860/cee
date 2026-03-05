import Foundation

/// Monitors system memory pressure and invokes callbacks.
@MainActor
final class MemoryPressureMonitor {
    enum PressureLevel: Equatable {
        case warning, critical
    }

    var onPressure: ((PressureLevel) -> Void)?

    /// Test-only: simulate a pressure event.
    func _testSimulatePressure(_ level: PressureLevel) {
        // TODO: Implement in GREEN phase
    }
}
