import AppKit

/// 畫面中央的位置 HUD，在 Option+scroll 快速切圖時顯示 "42 / 1000"
/// 類似 macOS 音量 HUD 的設計：深色半透明背景 + 圓角 + 自動淡出
///
/// 使用純色半透明背景而非 NSVisualEffectView，因為 NSVisualEffectView
/// 的 material 合成在 alpha 動畫時會先變深再淡出（即使用 wrapper 也一樣）。
final class PositionHUDView: NSView {

    /// HUD 淡出完成後呼叫（可選的外部通知回呼）
    var onFadeOut: (() -> Void)?

    private let positionLabel = NSTextField(labelWithString: "")
    private var fadeTimer: DispatchWorkItem?
    private var showVersion: UInt = 0  // 防止舊 fade completion 蓋掉新顯示

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.82).cgColor
        layer?.cornerRadius = 16

        positionLabel.font = .monospacedDigitSystemFont(ofSize: 36, weight: .bold)
        positionLabel.textColor = .white
        positionLabel.alignment = .center
        positionLabel.lineBreakMode = .byWordWrapping
        positionLabel.maximumNumberOfLines = 2
        positionLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(positionLabel)
        NSLayoutConstraint.activate([
            positionLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            positionLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            positionLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            positionLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
        ])

        // 初始隱藏
        alphaValue = 0
        isHidden = true
    }

    // MARK: - Hit Testing

    /// HUD 純顯示用，所有滑鼠事件穿透到下層 view
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    // MARK: - Public API

    func show(current: Int, total: Int) {
        positionLabel.font = .monospacedDigitSystemFont(ofSize: 36, weight: .bold)
        positionLabel.stringValue = "\(current) / \(total)"
        present(fadeDelay: Constants.positionHUDFadeDelay)
    }

    func show(message: String, fadeDelay: TimeInterval = Constants.positionHUDFadeDelay) {
        positionLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        positionLabel.stringValue = message
        present(fadeDelay: fadeDelay)
    }

    func dismiss() {
        fadeTimer?.cancel()
        fadeTimer = nil
        alphaValue = 0
        isHidden = true
    }

    // MARK: - Private

    private func present(fadeDelay: TimeInterval) {
        fadeTimer?.cancel()
        showVersion &+= 1

        if isHidden || alphaValue < 1 {
            isHidden = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                animator().alphaValue = 1
            }
        }

        scheduleFadeOut(after: fadeDelay)
    }

    private func scheduleFadeOut(after delay: TimeInterval) {
        fadeTimer?.cancel()
        let version = showVersion
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.showVersion == version else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                self.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.showVersion == version else { return }
                    self.isHidden = true
                    self.onFadeOut?()
                }
            }
        }
        fadeTimer = timer
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: timer
        )
    }
}
