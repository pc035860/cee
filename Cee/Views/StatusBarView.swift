import AppKit

enum ZoomStatusMode: Equatable {
    case fit
    case actual(windowAuto: Bool)
    case manual(percent: Int, windowAuto: Bool)
}

enum ZoomStatusFormatter {
    static func text(for mode: ZoomStatusMode) -> String {
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
}

final class StatusBarView: NSVisualEffectView {

    // MARK: - UI Elements

    private let separator = NSBox()
    private let sizeLabel = NSTextField(labelWithString: "")
    private let indexLabel = NSTextField(labelWithString: "")
    private let zoomLabel = NSTextField(labelWithString: "")

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
        // 設定毛玻璃效果，與標題列一致
        material = .titlebar
        blendingMode = .withinWindow
        state = .active
    }

    private func setupUI() {
        // 頂部分隔線（NSBox 原生支援 dynamic color，深淺模式自動切換）
        separator.boxType = .separator

        // 設定文字樣式
        [sizeLabel, indexLabel, zoomLabel].forEach { label in
            label.font = .systemFont(ofSize: 11)
            label.textColor = NSColor.secondaryLabelColor
            label.alignment = .center
            label.lineBreakMode = .byClipping
        }

        // 加入 subviews
        addSubview(separator)
        addSubview(sizeLabel)
        addSubview(indexLabel)
        addSubview(zoomLabel)

        // Auto Layout
        separator.translatesAutoresizingMaskIntoConstraints = false
        sizeLabel.translatesAutoresizingMaskIntoConstraints = false
        indexLabel.translatesAutoresizingMaskIntoConstraints = false
        zoomLabel.translatesAutoresizingMaskIntoConstraints = false

        // zoomLabel 靠右側（固定最小寬度，不截斷）
        zoomLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            // 分隔線：頂部全寬
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),

            // 尺寸標籤（置中）
            sizeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            sizeLabel.centerXAnchor.constraint(equalTo: centerXAnchor),

            // 縮放標籤（最右側）
            zoomLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            zoomLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            zoomLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 36),

            // 索引標籤（zoomLabel 左側，保持間距）
            indexLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            indexLabel.trailingAnchor.constraint(equalTo: zoomLabel.leadingAnchor, constant: -12),

            // sizeLabel 不能超出 indexLabel 左邊
            sizeLabel.trailingAnchor.constraint(lessThanOrEqualTo: indexLabel.leadingAnchor, constant: -8),
        ])
    }

    // MARK: - Update Methods

    func update(index: Int, total: Int, zoomMode: ZoomStatusMode, imageSize: NSSize,
                indexOverride: String? = nil) {
        indexLabel.stringValue = indexOverride ?? "\(index) / \(total)"
        zoomLabel.stringValue = ZoomStatusFormatter.text(for: zoomMode)
        sizeLabel.stringValue = "\(Int(imageSize.width)) × \(Int(imageSize.height))"
    }

    func updateZoom(_ zoomMode: ZoomStatusMode) {
        zoomLabel.stringValue = ZoomStatusFormatter.text(for: zoomMode)
    }

    /// 僅更新索引
    func updateIndex(current: Int, total: Int) {
        indexLabel.stringValue = "\(current) / \(total)"
    }

    /// 清空所有顯示內容（用於 empty state）
    func clear() {
        sizeLabel.stringValue = ""
        indexLabel.stringValue = ""
        zoomLabel.stringValue = ""
    }
}
