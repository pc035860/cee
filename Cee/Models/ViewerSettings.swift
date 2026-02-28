import Foundation

struct ViewerSettings: Codable {

    // MARK: - Zoom
    var magnification: CGFloat = 1.0
    var isManualZoom: Bool = false      // false = Fit on Screen mode

    // MARK: - Fitting
    var alwaysFitOnOpen: Bool = true
    var fittingOptions: FittingOptions = FittingOptions()

    // MARK: - Scaling Quality
    enum ScalingQuality: String, Codable {
        case low, medium, high
    }
    var scalingQuality: ScalingQuality = .medium
    var showPixelsWhenZoomingIn: Bool = true  // Nearest Neighbor when mag > 1.0

    // MARK: - Scroll Sensitivity
    enum ScrollSensitivity: String, Codable {
        case low, medium, high

        var trackpadThreshold: CGFloat {
            switch self {
            case .low:    return 200
            case .medium: return 130
            case .high:   return 60
            }
        }

        var wheelThreshold: CGFloat {
            switch self {
            case .low:    return 40
            case .medium: return 20
            case .high:   return 10
            }
        }
    }
    var trackpadSensitivity: ScrollSensitivity = .medium
    var wheelSensitivity: ScrollSensitivity = .medium

    // MARK: - Window
    var resizeWindowAutomatically: Bool = false
    var floatOnTop: Bool = false
    var lastWindowWidth: CGFloat? = nil   // nil = 未曾儲存，首次啟動使用螢幕 80%
    var lastWindowHeight: CGFloat? = nil  // nil = 未曾儲存，首次啟動使用螢幕 80%

    // MARK: - UI
    var showStatusBar: Bool = true

    // MARK: - Persistence
    private static let key = "CeeViewerSettings"

    static func load() -> ViewerSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(ViewerSettings.self, from: data)
        else { return ViewerSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: ViewerSettings.key)
        }
    }
}
