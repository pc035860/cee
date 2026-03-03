import AppKit

/// 畫面中央的位置 HUD，在 Option+scroll 快速切圖時顯示 "42 / 1000"
/// 類似 macOS 音量 HUD 的設計：毛玻璃背景 + 圓角 + 自動淡出
final class PositionHUDView: NSVisualEffectView {

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
        // 毛玻璃效果（HUD 風格）
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = 16

        // 標籤
        positionLabel.font = .monospacedDigitSystemFont(ofSize: 36, weight: .bold)
        positionLabel.textColor = .white
        positionLabel.alignment = .center
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

    // MARK: - Public API

    /// 更新位置文字並顯示 HUD，自動排程淡出
    func show(current: Int, total: Int) {
        positionLabel.stringValue = "\(current) / \(total)"

        // 取消之前的淡出計時
        fadeTimer?.cancel()
        showVersion &+= 1  // 遞增版本，使舊的 fade completion 失效

        if isHidden || alphaValue < 1 {
            isHidden = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                animator().alphaValue = 1
            }
        }

        // 排程淡出
        scheduleFadeOut()
    }

    /// 立即隱藏 HUD（不帶動畫）
    func dismiss() {
        fadeTimer?.cancel()
        fadeTimer = nil
        alphaValue = 0
        isHidden = true
    }

    // MARK: - Private

    private func scheduleFadeOut() {
        fadeTimer?.cancel()
        let version = showVersion
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.showVersion == version else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                self.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                guard let self, self.showVersion == version else { return }
                self.isHidden = true
                self.onFadeOut?()
            }
        }
        fadeTimer = timer
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Constants.positionHUDFadeDelay,
            execute: timer
        )
    }
}
