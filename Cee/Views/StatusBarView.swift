import AppKit

final class StatusBarView: NSView {

    // MARK: - UI Elements

    private let sizeLabel = NSTextField(labelWithString: "")
    private let indexLabel = NSTextField(labelWithString: "")
    private let zoomLabel = NSTextField(labelWithString: "")

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        wantsLayer = true

        // 頂部分隔線
        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor

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

        NSLayoutConstraint.activate([
            // 分隔線：頂部全寬
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            // 尺寸標籤（中間偏左）
            sizeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            sizeLabel.centerXAnchor.constraint(equalTo: centerXAnchor, constant: -80),

            // 索引標籤（右側倒數第二）
            indexLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            indexLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -80),

            // 縮放標籤（最右側，固定寬度）
            zoomLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            zoomLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            zoomLabel.widthAnchor.constraint(equalToConstant: 50),
        ])
    }

    // MARK: - Update Methods

    /// 更新所有顯示內容
    /// - Parameter `isFitting`: 當圖片處於 fitting 模式時為 true
    func update(index: Int, total: Int, zoom: CGFloat, imageSize: NSSize, isFitting: Bool) {
        // 索引：N / M
        indexLabel.stringValue = "\(index) / \(total)"

        // 縮放：Fit（fitting 模式）或 100%（actual size）或百分比
        if isFitting {
            zoomLabel.stringValue = "Fit"
        } else if zoom >= 0.99 && zoom <= 1.01 {
            zoomLabel.stringValue = "100%"
        } else {
            zoomLabel.stringValue = "\(Int(round(zoom * 100)))%"
        }

        // 尺寸：W × H（整數）
        sizeLabel.stringValue = "\(Int(imageSize.width)) × \(Int(imageSize.height))"
    }

    /// 僅更新縮放
    /// - Parameter `isFitting`: 當圖片處於 fitting 模式時為 true
    func updateZoom(_ zoom: CGFloat, isFitting: Bool) {
        if isFitting {
            zoomLabel.stringValue = "Fit"
        } else if zoom >= 0.99 && zoom <= 1.01 {
            zoomLabel.stringValue = "100%"
        } else {
            zoomLabel.stringValue = "\(Int(round(zoom * 100)))%"
        }
    }

    /// 僅更新索引
    func updateIndex(current: Int, total: Int) {
        indexLabel.stringValue = "\(current) / \(total)"
    }
}
