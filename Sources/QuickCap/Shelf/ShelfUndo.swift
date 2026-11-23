import AppKit
import QuartzCore

/// 删掉一张截图后，在它原来的位置下面出现几秒的"已移到废纸篓 · 撤销"。点一下就放回去。
@MainActor
final class UndoPill {
    let layer = CALayer()
    private let text = CATextLayer()
    private let button = CALayer()
    private let buttonText = CATextLayer()

    private let height: CGFloat = 28
    private let padding: CGFloat = 12
    private let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    private let buttonFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

    /// 还要显示多久（秒）
    private var remaining: CGFloat = 0
    private var onUndo: (() -> Void)? { stack.last?.undo }
    /// 连着删了好几张：每一张都能撤销（以前第二次删除会把第一次的撤销顶掉）。撤销按最近的先来
    private var stack: [(message: String, undo: () -> Void)] = []
    private var lastBounds: CGRect = .zero
    private var hot = false

    /// 显示时长
    static let duration: CGFloat = 5

    init(contentsScale s: CGFloat) {
        layer.backgroundColor = NSColor(white: 0.12, alpha: 0.9).cgColor
        layer.cornerRadius = height / 2
        layer.cornerCurve = .continuous
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 3)
        layer.opacity = 0
        layer.zPosition = 40
        layer.isHidden = true

        for t in [text, buttonText] {
            t.alignmentMode = .center
            t.contentsScale = s
        }
        text.font = font
        text.fontSize = font.pointSize
        text.foregroundColor = NSColor(white: 1, alpha: 0.92).cgColor
        buttonText.font = buttonFont
        buttonText.fontSize = buttonFont.pointSize
        buttonText.foregroundColor = Metrics.pinColor.cgColor
        buttonText.string = "Undo"

        button.cornerRadius = (height - 8) / 2
        button.cornerCurve = .continuous
        button.addSublayer(buttonText)
        layer.addSublayer(text)
        layer.addSublayer(button)
        setContentsScale(s)
    }

    func setContentsScale(_ s: CGFloat) {
        layer.contentsScale = s
        text.contentsScale = s
        buttonText.contentsScale = s
    }

    var isVisible: Bool { remaining > 0 && onUndo != nil }
    /// 还在显示或正在淡出（动画循环要接着跑）
    var isActive: Bool { remaining > 0 || layer.opacity > 0 }

    /// center 是根图层坐标，会被限制在 bounds 里面
    func show(_ message: String, at center: CGPoint, in bounds: CGRect, onUndo: @escaping () -> Void) {
        stack.append((message, onUndo))
        lastBounds = bounds
        layout(at: center)
    }

    private func layout(at center: CGPoint) {
        guard let top = stack.last else { return }
        remaining = Self.duration
        let message = stack.count > 1 ? "\(top.message) (\(stack.count))" : top.message
        let bounds = lastBounds
        let tw = (message as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        let bw = ("Undo" as NSString).size(withAttributes: [.font: buttonFont]).width.rounded(.up) + 16
        let width = padding + tw + 6 + bw + 4
        var x = center.x
        x = min(max(x, bounds.minX + width / 2 + 12), bounds.maxX - width / 2 - 12)
        withoutAnimation {
            layer.isHidden = false
            layer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            layer.position = CGPoint(x: x.rounded(), y: center.y.rounded())
            layer.shadowPath = CGPath(roundedRect: layer.bounds, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil)
            text.string = message
            text.frame = CGRect(x: padding, y: (height - 15) / 2, width: tw, height: 15)
            button.frame = CGRect(x: width - 4 - bw, y: 4, width: bw, height: height - 8)
            buttonText.frame = CGRect(x: 0, y: (height - 8 - 15) / 2, width: bw, height: 15)
        }
        setHot(false)
    }

    func hide() {
        remaining = 0
        stack = []
        setHot(false)
    }

    /// 整排滚动了：跟着被删那张原来的位置走（以前停在原地，和卡片对不上）
    func move(toX x: CGFloat) {
        guard isVisible else { return }
        let w = layer.bounds.width
        let nx = min(max(x, lastBounds.minX + w / 2 + 12), lastBounds.maxX - w / 2 - 12).rounded()
        guard nx != layer.position.x else { return }
        withoutAnimation { layer.position.x = nx }
    }

    /// point 是根图层坐标
    func contains(_ point: CGPoint) -> Bool {
        isVisible && layer.frame.insetBy(dx: -4, dy: -4).contains(point)
    }

    func setHot(_ on: Bool) {
        guard on != hot else { return }
        hot = on
        withoutAnimation { button.backgroundColor = on ? NSColor(white: 1, alpha: 0.14).cgColor : nil }
    }

    /// 点了撤销
    func fire() {
        guard let top = stack.popLast() else { return }
        if stack.isEmpty { hide() } else { layout(at: layer.position) }
        top.undo()
    }

    /// 返回 true 表示还在显示或淡出
    func step(_ dt: CGFloat) -> Bool {
        if remaining > 0 {
            remaining -= dt
            if remaining <= 0 { hide() }
        }
        let target: Float = remaining > 0 ? 1 : 0
        let o = layer.opacity
        guard o != target else {
            if target == 0 && !layer.isHidden { withoutAnimation { layer.isHidden = true } }
            return remaining > 0
        }
        let rate: CGFloat = target > o ? 18 : 7
        var next = o + (target - o) * Float(1 - exp(-rate * dt))
        if abs(target - next) < 0.01 { next = target }
        withoutAnimation { layer.opacity = next }
        return true
    }
}
