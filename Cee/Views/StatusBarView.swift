import AppKit

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
        wantsLayer = true
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
            label.backgroundColor = .clear  // 確保透明背景
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

    /// 更新所有顯示內容
    /// - Parameter `isFitting`: 當圖片處於 fitting 模式時為 true
    func update(index: Int, total: Int, zoom: CGFloat, imageSize: NSSize, isFitting: Bool) {
        indexLabel.stringValue = "\(index) / \(total)"
        zoomLabel.stringValue = zoomText(for: zoom, isFitting: isFitting)
        sizeLabel.stringValue = "\(Int(imageSize.width)) × \(Int(imageSize.height))"
    }

    /// 僅更新縮放
    /// - Parameter `isFitting`: 當圖片處於 fitting 模式時為 true
    func updateZoom(_ zoom: CGFloat, isFitting: Bool) {
        zoomLabel.stringValue = zoomText(for: zoom, isFitting: isFitting)
    }

    private func zoomText(for zoom: CGFloat, isFitting: Bool) -> String {
        if isFitting {
            return "Fit"
        } else if zoom >= 0.99 && zoom <= 1.01 {
            return "100%"
        } else {
            return "\(Int(round(zoom * 100)))%"
        }
    }

    /// 僅更新索引
    func updateIndex(current: Int, total: Int) {
        indexLabel.stringValue = "\(current) / \(total)"
    }
}
