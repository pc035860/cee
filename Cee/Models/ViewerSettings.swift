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

    // MARK: - Arrow Key Navigation
    var arrowLeftRightNavigation: Bool = true   // left/right arrows navigate images
    var arrowUpDownNavigation: Bool = false      // up/down arrows navigate images at edges

    // MARK: - Fast Browse
    var thumbnailFallback: Bool = false          // use low-res preview while fast browsing

    // MARK: - Scroll Sensitivity
    enum ScrollSensitivity: String, Codable {
        case low, medium, high

        var trackpadThreshold: CGFloat {
            switch self {
            case .low:    return 250
            case .medium: return 160
            case .high:   return 80
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
    var reuseWindow: Bool = true  // true = 復用現有視窗，false = 每次開新視窗
    var lastWindowWidth: CGFloat? = nil   // nil = 未曾儲存，首次啟動使用螢幕 80%
    var lastWindowHeight: CGFloat? = nil  // nil = 未曾儲存，首次啟動使用螢幕 80%

    // MARK: - Quick Grid
    var quickGridCellSize: CGFloat = 160  // matches Constants.quickGridMinCellSize
    var quickGridScrollAfterZoom: Bool = false  // scroll cursor card to center after zoom ends

    // MARK: - UI
    var showStatusBar: Bool = true

    // MARK: - Dual Page
    var dualPageEnabled: Bool = false
    var firstPageIsCover: Bool = false  // true = first page displayed solo (cover mode)

    enum ReadingDirection: String, Codable, Sendable {
        case leftToRight
        case rightToLeft

        var isRTL: Bool { self == .rightToLeft }
    }
    var readingDirection: ReadingDirection = .rightToLeft
    /// true = DuoPage 模式下左箭頭為下一頁（日文漫畫右翻左）；false = 右箭頭永遠為下一頁
    var duoPageRTLNavigation: Bool = true
    /// true = 單頁模式下左箭頭為下一頁；false = 右箭頭為下一頁（預設）
    var singlePageRTLNavigation: Bool = false

    // MARK: - Navigation Behavior
    /// true = 回到上一頁時從圖片底端開始（預設）；false = 從頂端開始
    var scrollToBottomOnPrevious: Bool = true
    /// true = 點擊/輕拍換下一頁；Shift+點擊換上一頁
    var clickToTurnPage: Bool = false

    // MARK: - Continuous Scroll Mode
    /// true = 啟用連續捲動模式（webtoon-style vertical scrolling）
    var continuousScrollEnabled: Bool = false

    // MARK: - Codable (backward-compatible decoding)

    init() {}

    init(from decoder: Decoder) throws {
        let d = ViewerSettings()  // defaults
        let c = try decoder.container(keyedBy: CodingKeys.self)
        magnification = (try? c.decode(CGFloat.self, forKey: .magnification)) ?? d.magnification
        isManualZoom = (try? c.decode(Bool.self, forKey: .isManualZoom)) ?? d.isManualZoom
        alwaysFitOnOpen = (try? c.decode(Bool.self, forKey: .alwaysFitOnOpen)) ?? d.alwaysFitOnOpen
        fittingOptions = (try? c.decode(FittingOptions.self, forKey: .fittingOptions)) ?? d.fittingOptions
        scalingQuality = (try? c.decode(ScalingQuality.self, forKey: .scalingQuality)) ?? d.scalingQuality
        showPixelsWhenZoomingIn = (try? c.decode(Bool.self, forKey: .showPixelsWhenZoomingIn)) ?? d.showPixelsWhenZoomingIn
        arrowLeftRightNavigation = (try? c.decode(Bool.self, forKey: .arrowLeftRightNavigation)) ?? d.arrowLeftRightNavigation
        arrowUpDownNavigation = (try? c.decode(Bool.self, forKey: .arrowUpDownNavigation)) ?? d.arrowUpDownNavigation
        thumbnailFallback = (try? c.decode(Bool.self, forKey: .thumbnailFallback)) ?? d.thumbnailFallback
        trackpadSensitivity = (try? c.decode(ScrollSensitivity.self, forKey: .trackpadSensitivity)) ?? d.trackpadSensitivity
        wheelSensitivity = (try? c.decode(ScrollSensitivity.self, forKey: .wheelSensitivity)) ?? d.wheelSensitivity
        resizeWindowAutomatically = (try? c.decode(Bool.self, forKey: .resizeWindowAutomatically)) ?? d.resizeWindowAutomatically
        floatOnTop = (try? c.decode(Bool.self, forKey: .floatOnTop)) ?? d.floatOnTop
        lastWindowWidth = try? c.decode(CGFloat.self, forKey: .lastWindowWidth)
        lastWindowHeight = try? c.decode(CGFloat.self, forKey: .lastWindowHeight)
        showStatusBar = (try? c.decode(Bool.self, forKey: .showStatusBar)) ?? d.showStatusBar
        dualPageEnabled = (try? c.decode(Bool.self, forKey: .dualPageEnabled)) ?? d.dualPageEnabled
        firstPageIsCover = (try? c.decode(Bool.self, forKey: .firstPageIsCover)) ?? d.firstPageIsCover
        readingDirection = (try? c.decode(ReadingDirection.self, forKey: .readingDirection)) ?? d.readingDirection
        duoPageRTLNavigation = (try? c.decode(Bool.self, forKey: .duoPageRTLNavigation)) ?? d.duoPageRTLNavigation
        singlePageRTLNavigation = (try? c.decode(Bool.self, forKey: .singlePageRTLNavigation)) ?? d.singlePageRTLNavigation
        scrollToBottomOnPrevious = (try? c.decode(Bool.self, forKey: .scrollToBottomOnPrevious)) ?? d.scrollToBottomOnPrevious
        clickToTurnPage = (try? c.decode(Bool.self, forKey: .clickToTurnPage)) ?? d.clickToTurnPage
        quickGridCellSize = (try? c.decode(CGFloat.self, forKey: .quickGridCellSize)) ?? d.quickGridCellSize
        reuseWindow = (try? c.decode(Bool.self, forKey: .reuseWindow)) ?? d.reuseWindow
        continuousScrollEnabled = (try? c.decode(Bool.self, forKey: .continuousScrollEnabled)) ?? d.continuousScrollEnabled
    }

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
