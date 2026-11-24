import AppKit

/// 截图界面的动画：都用弹簧，从现在看到的样子（动画中途也一样）接着走，120Hz。
/// 高亮框、暗的那块、光晕、标签换窗口时用同一条，一起到
@MainActor
enum Motion {
    /// bounce 0 不回弹；0.1–0.3 轻轻弹一下
    static func spring(_ key: String, from: Any?, to: Any?, duration: CGFloat = 0.26, bounce: CGFloat = 0) -> CASpringAnimation {
        let a = CASpringAnimation(perceptualDuration: duration, bounce: bounce)
        a.keyPath = key
        a.fromValue = from
        a.toValue = to
        a.duration = a.settlingDuration
        a.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        return a
    }

    /// 把图层挪到新位置、新大小、新圆角（frame 是父图层坐标）
    static func move(_ l: CALayer, frame f: CGRect, corner: CGFloat, animated: Bool, duration: CGFloat = 0.26, bounce: CGFloat = 0) {
        let pos = CGPoint(x: f.midX, y: f.midY), b = CGRect(origin: .zero, size: f.size)
        // 位置没变就什么都不做：不然会把正在进行的动画（比如按下去的那一下）打断
        if l.position == pos, l.bounds == b, l.cornerRadius == corner { return }
        let now = l.presentation()
        let fromPos = now?.position ?? l.position, fromBounds = now?.bounds ?? l.bounds, fromCorner = now?.cornerRadius ?? l.cornerRadius
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.bounds = b
        l.position = pos
        l.cornerRadius = corner
        CATransaction.commit()
        guard animated else {
            for k in ["glide.position", "glide.bounds", "glide.corner"] { l.removeAnimation(forKey: k) }
            return
        }
        l.add(spring("position", from: NSValue(point: fromPos), to: NSValue(point: pos), duration: duration, bounce: bounce), forKey: "glide.position")
        l.add(spring("bounds", from: NSValue(rect: fromBounds), to: NSValue(rect: b), duration: duration, bounce: bounce), forKey: "glide.bounds")
        l.add(spring("cornerRadius", from: fromCorner, to: corner, duration: duration, bounce: bounce), forKey: "glide.corner")
    }

    /// 淡入淡出。delay：晚一点开始（开始前保持原来的样子）
    /// curve：不给的话淡入用 easeOut、淡出用 easeIn。两层交替（一层淡入、一层淡出）要用同一条曲线
    static func fade(_ l: CALayer, to v: Float, duration: CFTimeInterval, delay: CFTimeInterval = 0,
                     curve: CAMediaTimingFunctionName? = nil) {
        guard l.opacity != v || l.animation(forKey: "fade") != nil else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = l.presentation()?.opacity ?? l.opacity
        a.toValue = v
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: curve ?? (v > (l.presentation()?.opacity ?? l.opacity) ? .easeOut : .easeIn))
        if delay > 0 {
            a.beginTime = CACurrentMediaTime() + delay
            a.fillMode = .backwards
        }
        a.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.opacity = v
        CATransaction.commit()
        l.add(a, forKey: "fade")
    }

    /// 线性 Display P3 的橙色（#FF9500），k 倍亮。k > 1 时是 HDR（要图层开着 wantsExtendedDynamicRangeContent）
    static func orange(_ k: CGFloat) -> CGColor {
        let base = NSColor(calibratedRed: 1, green: 0.58, blue: 0, alpha: 1).cgColor
        guard let cs = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
              let lin = base.converted(to: cs, intent: .defaultIntent, options: nil),
              let c = lin.components, c.count >= 3 else { return base }
        return CGColor(colorSpace: cs, components: [c[0] * k, c[1] * k, c[2] * k, 1]) ?? base
    }

    /// 冷白：白里带一点蓝（和选区那圈冷白光同一个颜色），k 倍亮
    static func cool(_ k: CGFloat) -> CGColor {
        let base = NSColor(calibratedRed: 0.86, green: 0.92, blue: 1, alpha: 1).cgColor
        guard let cs = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
              let lin = base.converted(to: cs, intent: .defaultIntent, options: nil),
              let c = lin.components, c.count >= 3 else { return base }
        return CGColor(colorSpace: cs, components: [c[0] * k, c[1] * k, c[2] * k, 1]) ?? base
    }

    /// 窗口高亮、吸附线的颜色：冷白（用户 2026-11-25 在屏幕上对比后选了"全部冷白"，和框选统一）
    static func accent(_ k: CGFloat) -> CGColor { cool(k) }

    /// 让图层画出比白色亮的颜色（边框、模糊的光晕）。
    /// 系统说这个开关过时了、改用 preferredDynamicRange，但实测 preferredDynamicRange 对边框颜色不起作用
    /// （只对图片内容有用），所以还用这个；只在这一个地方用
    static func allowHDR(_ l: CALayer, _ on: Bool) { l.setValue(on, forKey: "wantsExtendedDynamicRangeContent") }

    /// 这块屏幕能不能显示 HDR
    static func hdrCapable(_ screen: NSScreen?) -> Bool { (screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1 }
}

/// 窗口高亮外面那圈光：和系统 Visual Intelligence 的光边同一套做法（叠加发光），颜色是冷白。
/// 一圈细线加两层模糊的光，亮度跟着屏幕的 HDR 余量走。所有图层只改位置、大小、圆角，跟着高亮框用同一条弹簧走
@MainActor
final class CaptureHalo {
    /// 外面的容器：淡入淡出改它的透明度（子图层不合成成一整块，叠加的光才能和下面的画面叠）
    let layer = CALayer()
    private let glow: ScanGlow

    init(hdr: Bool, bounds: CGRect, screen: NSScreen?) {
        glow = ScanGlow(bounds: bounds, screen: screen, tint: .cool)
        layer.frame = bounds
        layer.opacity = 0
        layer.allowsGroupOpacity = false
        layer.addSublayer(glow.layer)
        glow.setVisible()
    }

    /// 窗口在 r（父图层坐标），圆角 c
    func move(to r: CGRect, corner c: CGFloat, animated: Bool, clamp: CGRect? = nil) {
        glow.move(to: r, corner: c, animated: animated, outside: true, clamp: clamp, duration: 0.26, bounce: 0)
    }

    /// 按下去的手感由高亮线收紧来表现，光不再单独变亮
    func press(_ on: Bool) {}
}


/// 吸附线：和窗口高亮同一套光（细线加两层模糊的光，叠加混合），颜色是冷白。
/// 没有私有接口时退回一条细线加阴影
@MainActor
final class GuideGlow {
    let layer = CALayer()
    private var shapes: [CAShapeLayer] = []

    init(bounds: CGRect, screen: NSScreen?) {
        layer.frame = bounds
        layer.opacity = 0
        layer.allowsGroupOpacity = false
        let h = screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1
        Motion.allowHDR(layer, h > 1)
        // 和选区、窗口那圈光用同一个橙（光的贴图那个颜色，叠亮以后看起来是 #FF9500）
        let tone = CGColor(red: 0.86, green: 0.92, blue: 1, alpha: 1)
        func shape(_ width: CGFloat) -> CAShapeLayer {
            let l = CAShapeLayer()
            l.frame = bounds
            l.fillColor = nil
            l.strokeColor = tone
            l.lineWidth = width
            return l
        }
        guard ScanGlow.privateAvailable else {
            let l = shape(1)
            l.shadowColor = tone
            l.shadowOpacity = 0.7
            l.shadowRadius = 2
            l.shadowOffset = .zero
            shapes = [l]
            layer.addSublayer(l)
            return
        }
        // 细线不冲白，外面的光淡一点
        let gain: Float = h > 1 ? 1.6 : 1.2
        for (width, g, blur) in [(CGFloat(1), gain, CGFloat(0)), (CGFloat(2), gain * 0.5, CGFloat(1.5)), (CGFloat(4), gain * 0.35, CGFloat(5))] {
            let l = shape(width)
            l.compositingFilter = ScanGlow.filter("plusL")
            l.setValue(g, forKey: "gain")
            if blur > 0 {
                let f = ScanGlow.filter("gaussianBlur")
                f.setValue("gaussianBlur", forKey: "name")
                f.setValue(Float(blur), forKey: "inputRadius")
                l.filters = [f]
            }
            shapes.append(l)
            layer.addSublayer(l)
        }
    }

    var path: CGPath? {
        didSet {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for s in shapes { s.path = path }
            CATransaction.commit()
        }
    }

    func resize(_ b: CGRect) {
        layer.frame = b
        for s in shapes { s.frame = b }
    }
}
