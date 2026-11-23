import AppKit
import QuartzCore

/// 滑动时浮在绳子上的日期牌，像挂在绳子上的一个小标签。
/// 停下来一会儿就淡出；置顶那一段显示"置顶"。
@MainActor
final class DateBubble {
    let layer = CALayer()
    private let text = CATextLayer()
    /// 当前显示的文字（调试用）
    private(set) var label: String = ""
    private var current: String?
    /// 停下后还留多久（秒）
    private var hold: CGFloat = 0
    private var shown = false

    private let height: CGFloat = 22
    private let padding: CGFloat = 11

    init(contentsScale: CGFloat) {
        layer.backgroundColor = NSColor(white: 0.985, alpha: 0.96).cgColor
        layer.cornerRadius = height / 2
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5
        layer.borderColor = NSColor(white: 0, alpha: 0.07).cgColor
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.14
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.opacity = 0
        layer.contentsScale = contentsScale
        layer.zPosition = 30

        text.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        text.fontSize = 11.5
        text.foregroundColor = NSColor(white: 0.18, alpha: 1).cgColor
        text.alignmentMode = .center
        text.contentsScale = contentsScale
        // 换字时不要系统默认的淡入淡出：快速滑过好几天时，新旧两行字会叠在一起
        let none: [String: CAAction] = ["contents": NSNull(), "string": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        text.actions = none
        layer.actions = none
        layer.addSublayer(text)
    }

    func setContentsScale(_ s: CGFloat) {
        layer.contentsScale = s
        text.contentsScale = s
    }

    /// 显示某一天（nil 表示置顶那一段）
    func show(day: Date?, at center: CGPoint) {
        let next = day.map { ShelfDates.bubble(for: $0) } ?? "Pinned"
        if next != current {
            current = next
            label = next
            let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
            let w = (next as NSString).size(withAttributes: [.font: font]).width
            let width = (w + 2 * padding).rounded()
            withoutAnimation {
                layer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
                layer.shadowPath = CGPath(roundedRect: layer.bounds, cornerWidth: height / 2,
                                          cornerHeight: height / 2, transform: nil)
                text.string = next
                text.frame = CGRect(x: 0, y: (height - 14) / 2, width: width, height: 14)
            }
        }
        withoutAnimation { layer.position = center }
        hold = 0.9
        shown = true
    }

    func hide() {
        hold = 0
        shown = false
    }

    /// 返回 true 表示还在动（需要继续刷新）
    func step(_ dt: CGFloat) -> Bool {
        if hold > 0 { hold -= dt }
        let target: Float = (shown || hold > 0) ? 1 : 0
        let o = layer.opacity
        if o == target { return false }
        // 出现快、消失慢
        let rate: CGFloat = target > o ? 16 : 6
        let k = Float(1 - exp(-rate * dt))
        var next = o + (target - o) * k
        if abs(target - next) < 0.01 { next = target }
        withoutAnimation { layer.opacity = next }
        return true
    }
}
