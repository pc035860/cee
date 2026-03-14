import AppKit

enum ZoomStatusMode: Equatable {
    case fit
    case actual(windowAuto: Bool)
    case manual(percent: Int, windowAuto: Bool)
}

enum ZoomStatusStyle {
    case full
    case compactPercentOnly
}

enum ZoomStatusFormatter {
    static func text(for mode: ZoomStatusMode, style: ZoomStatusStyle = .full) -> String {
        switch style {
        case .full:
            return fullText(for: mode)
        case .compactPercentOnly:
            return compactText(for: mode)
        }
    }

    private static func fullText(for mode: ZoomStatusMode) -> String {
        let baseText: String
        let windowAuto: Bool

        switch mode {
        case .fit:
            return String(localized: "status.fit")
        case .actual(let isWindowAuto):
            baseText = String(localized: "status.actual") + " 100%"
            windowAuto = isWindowAuto
        case .manual(let percent, let isWindowAuto):
            baseText = String(localized: "status.manual") + " \(percent)%"
            windowAuto = isWindowAuto
        }

        guard windowAuto else { return baseText }
        return baseText + " · " + String(localized: "status.windowAuto")
    }

    private static func compactText(for mode: ZoomStatusMode) -> String {
        switch mode {
        case .fit:
            return String(localized: "status.fit")
        case .actual:
            return "100%"
        case .manual(let percent, _):
            return "\(percent)%"
        }
    }
}

final class StatusBarView: NSVisualEffectView {

    enum DisplayMode {
        case regular
        case compact
        case minimal
    }

    // MARK: - UI Elements

    private let separator = NSBox()
    private let sizeLabel = NSTextField(labelWithString: "")
    private let indexLabel = NSTextField(labelWithString: "")
    private let zoomLabel = NSTextField(labelWithString: "")

    // MARK: - State

    private var currentZoomMode: ZoomStatusMode?
    private(set) var currentDisplayMode: DisplayMode = .regular
    private var cachedRegularThreshold: CGFloat = 0
    private var cachedCompactThreshold: CGFloat = 0

    // MARK: - Constraints

    private var zoomLabelConstraints: [NSLayoutConstraint] = []
    private var minimalIndexTrailingConstraint: NSLayoutConstraint!

    private static let contentPadding: CGFloat = 8
    private static let labelGap: CGFloat = 4
    private static let zoomGap: CGFloat = 8
    private static let hysteresis: CGFloat = 20

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupVisualEffect()
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupVisualEffect()
        setupUI()
    }

    private func setupVisualEffect() {
        material = .titlebar
        blendingMode = .withinWindow
        state = .active
    }

    private func setupUI() {
        separator.boxType = .separator

        [sizeLabel, indexLabel, zoomLabel].forEach { label in
            label.font = .systemFont(ofSize: 11)
            label.textColor = NSColor.secondaryLabelColor
            label.alignment = .center
            label.lineBreakMode = .byClipping
        }

        addSubview(separator)
        addSubview(sizeLabel)
        addSubview(indexLabel)
        addSubview(zoomLabel)

        separator.translatesAutoresizingMaskIntoConstraints = false
        sizeLabel.translatesAutoresizingMaskIntoConstraints = false
        indexLabel.translatesAutoresizingMaskIntoConstraints = false
        zoomLabel.translatesAutoresizingMaskIntoConstraints = false

        zoomLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let indexToZoom = indexLabel.trailingAnchor.constraint(
            equalTo: zoomLabel.leadingAnchor, constant: -Self.zoomGap)
        indexToZoom.priority = .defaultHigh

        let zoomToTrailing = zoomLabel.trailingAnchor.constraint(
            equalTo: trailingAnchor, constant: -Self.contentPadding)
        zoomToTrailing.priority = .defaultHigh

        zoomLabelConstraints = [indexToZoom, zoomToTrailing]

        minimalIndexTrailingConstraint = indexLabel.trailingAnchor.constraint(
            lessThanOrEqualTo: trailingAnchor, constant: -Self.contentPadding)
        minimalIndexTrailingConstraint.isActive = false

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),

            sizeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.contentPadding),
            sizeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            sizeLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: indexLabel.leadingAnchor, constant: -Self.labelGap),

            indexLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            zoomLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ] + zoomLabelConstraints)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let newMode = computeDisplayMode(for: bounds.width)
        guard newMode != currentDisplayMode else { return }
        applyDisplayMode(newMode)
    }

    private func computeDisplayMode(for width: CGFloat) -> DisplayMode {
        guard currentZoomMode != nil else { return .regular }

        switch currentDisplayMode {
        case .regular:
            if width < cachedCompactThreshold { return .minimal }
            if width < cachedRegularThreshold { return .compact }
            return .regular
        case .compact:
            if width < cachedCompactThreshold { return .minimal }
            if width >= cachedRegularThreshold + Self.hysteresis { return .regular }
            return .compact
        case .minimal:
            if width >= cachedRegularThreshold + Self.hysteresis { return .regular }
            if width >= cachedCompactThreshold + Self.hysteresis { return .compact }
            return .minimal
        }
    }

    private func recomputeThresholds() {
        guard let zoomMode = currentZoomMode else {
            cachedRegularThreshold = 0
            cachedCompactThreshold = 0
            return
        }

        let font = zoomLabel.font ?? .systemFont(ofSize: 11)
        let coreWidth = Self.contentPadding
            + sizeLabel.intrinsicContentSize.width
            + Self.labelGap
            + indexLabel.intrinsicContentSize.width
            + Self.zoomGap

        let fullText = ZoomStatusFormatter.text(for: zoomMode, style: .full)
        cachedRegularThreshold = coreWidth + textWidth(fullText, font: font) + Self.contentPadding

        let compactText = ZoomStatusFormatter.text(for: zoomMode, style: .compactPercentOnly)
        cachedCompactThreshold = coreWidth + textWidth(compactText, font: font) + Self.contentPadding
    }

    private func applyDisplayMode(_ mode: DisplayMode) {
        currentDisplayMode = mode

        switch mode {
        case .regular, .compact:
            zoomLabel.isHidden = false
            NSLayoutConstraint.deactivate([minimalIndexTrailingConstraint])
            NSLayoutConstraint.activate(zoomLabelConstraints)
            applyZoomText()
        case .minimal:
            zoomLabel.isHidden = true
            NSLayoutConstraint.deactivate(zoomLabelConstraints)
            NSLayoutConstraint.activate([minimalIndexTrailingConstraint])
        }
    }

    private func applyZoomText() {
        guard let zoomMode = currentZoomMode else { return }
        let style: ZoomStatusStyle = currentDisplayMode == .compact ? .compactPercentOnly : .full
        zoomLabel.stringValue = ZoomStatusFormatter.text(for: zoomMode, style: style)
    }

    private func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    // MARK: - Update Methods

    func update(index: Int, total: Int, zoomMode: ZoomStatusMode, imageSize: NSSize,
                indexOverride: String? = nil) {
        indexLabel.stringValue = indexOverride ?? "\(index) / \(total)"
        currentZoomMode = zoomMode
        sizeLabel.stringValue = "\(Int(imageSize.width)) × \(Int(imageSize.height))"
        recomputeThresholds()
        applyZoomText()
        needsLayout = true
    }

    func updateZoom(_ zoomMode: ZoomStatusMode) {
        currentZoomMode = zoomMode
        recomputeThresholds()
        applyZoomText()
        needsLayout = true
    }

    func updateIndex(current: Int, total: Int) {
        indexLabel.stringValue = "\(current) / \(total)"
        recomputeThresholds()
        needsLayout = true
    }

    func clear() {
        sizeLabel.stringValue = ""
        indexLabel.stringValue = ""
        zoomLabel.stringValue = ""
        currentZoomMode = nil
    }
}
