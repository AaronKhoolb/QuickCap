import AppKit
import QuartzCore

/// 扫描时选区外面那圈光。和 macOS 截图里 Visual Intelligence 的光边是同一套做法
/// （screencaptureui 的 GlowBorderController，反编译出来的图层结构和参数，一个不差）：
/// - ring：一圈边，只当形状用、自己不显示，宽 (5−3k)/scale
/// - image：一张很模糊的彩色渐变图，拉成 786pt 的正方形、按选区对角线放大，4 秒转一圈
/// - glow-primary：ring 的形状 × 转动的颜色，颜色的饱和度降到 0.3−0.1k
/// - glow：叠加（plusL）、增亮 clamp(12·h, 12, 16) 倍；里面是 primary 和两层模糊的 primary（2/scale、(15−10k)/scale）
/// h 是屏幕能到的最大 HDR 余量（XDR 屏 16，普通屏 1），k = clamp((h−1)/3, 0, 1)。
/// 所以 XDR 屏上是 1pt 的亮线、光晕很小；普通屏 2.5pt、光晕大一点。
/// 用到的 CAPortalLayer、CAFilter、gain 是系统私有的，没有的话退回用公开的图层画一个相近的
@MainActor
final class ScanGlow {
    let layer = CALayer()
    private let ring = CALayer()
    private let image = CALayer()
    private let p: Params
    private var fallback: CAShapeLayer?

    /// iridescent：系统那种彩色流光（Scan）。orange：同一套做法，颜色是 Capture 的橙色，不转、不去饱和，增益低很多
    /// （橙色乘 12 倍，红通道先到顶，会被烧成黄白）
    enum Tint: String { case iridescent, orange, white, cool
        /// 区域选区那圈光用哪种（defaults write <bundle id> glowStyle orange|white|cool）
        static var selection: Tint {
            // --glow-style=orange|white|cool 只给调试用（对比截图），不写进设置
            let arg = CommandLine.arguments.first { $0.hasPrefix("--glow-style=") }?.dropFirst(13)
            let v = arg.map(String.init) ?? UserDefaults.standard.string(forKey: "glowStyle") ?? ""
            return Tint(rawValue: v).flatMap { $0 == .iridescent ? nil : $0 } ?? .cool
        }
    }

    struct Params {
        let ringWidth: CGFloat, bloom: CGFloat, spread: CGFloat, gain: Float, haloGain: Float, saturation: Float
        /// 彩色流光时光晕套在增亮的容器里（系统就是这样）；其他颜色不套，光晕才真的比细线暗，颜色才保得住
        let nestedGain: Bool

        init(headroom h: CGFloat, scale s: CGFloat, tint: Tint) {
            let k = min(max((h - 1) / 3, 0), 1)
            ringWidth = (5 - 3 * k) / s
            bloom = 2 / s
            spread = (15 - 10 * k) / s
            switch tint {
            case .iridescent:
                gain = Float(min(max(12, h * 12), 16))
                haloGain = gain
                saturation = Float(0.3 - 0.1 * k)
                nestedGain = true
            case .orange, .white, .cool:
                gain = Float(h > 1 ? 2.4 : 1.5)
                // 光晕比细线暗得多：三层都用同一个增益叠在一起，橙色会被冲成白色
                haloGain = gain * 0.45
                saturation = 1
                nestedGain = false
            }
        }

    }

    let tint: Tint
    /// 已经收起来了（外面要让它亮回来时看这个）
    private(set) var hidden = false

    /// bounds：整个截图界面（光的图层要铺满，模糊才不会被切掉）
    init(bounds: CGRect, screen: NSScreen?, tint: Tint = .iridescent) {
        self.tint = tint
        let h = screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1
        p = Params(headroom: h, scale: screen?.backingScaleFactor ?? 2, tint: tint)
        layer.frame = bounds
        layer.name = "scanGlow"
        Motion.allowHDR(layer, h > 1)
        ring.opacity = 0
        if Self.privateAvailable { buildSystem(bounds) } else { buildFallback(bounds) }
    }

    static var privateAvailable: Bool {
        guard let portal = NSClassFromString("CAPortalLayer") as? NSObject.Type, NSClassFromString("CAFilter") != nil else { return false }
        let probe = portal.init()
        return CALayer().responds(to: NSSelectorFromString("setGain:"))
            && probe.responds(to: NSSelectorFromString("setSourceLayer:"))
            && probe.responds(to: NSSelectorFromString("setHidesSourceLayer:"))
    }

    // MARK: 系统那套

    private func buildSystem(_ b: CGRect) {
        ring.name = "rect"
        ring.borderWidth = p.ringWidth
        ring.borderColor = CGColor(gray: 0, alpha: 1)
        ring.cornerCurve = .continuous
        ring.allowsEdgeAntialiasing = true

        image.name = "colorImage"
        image.contents = Self.texture(for: tint)
        image.bounds = CGRect(x: 0, y: 0, width: 786, height: 786)
        if tint == .iridescent {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 2 * Double.pi
            spin.toValue = 0
            spin.duration = 4
            spin.repeatCount = .infinity
            image.add(spin, forKey: "rotation")
        }

        let glow = full(b, "glow")
        glow.compositingFilter = Self.filter("plusL")
        glow.setValue(p.nestedGain ? p.gain : 1, forKey: "gain")
        let primary = full(b, "glow-primary")
        if !p.nestedGain {
            primary.compositingFilter = Self.filter("plusL")
            primary.setValue(p.gain, forKey: "gain")
        }
        let mask = Self.portal(ring, hides: true, opacity: true)
        mask.frame = b
        primary.mask = mask
        let color = Self.portal(image, hides: true, opacity: false)
        color.frame = b
        color.name = "color"
        let sat = Self.filter("colorSaturate")
        sat.setValue("colorSaturate", forKey: "name")
        sat.setValue(p.saturation, forKey: "inputAmount")
        color.filters = [sat]
        primary.addSublayer(color)
        glow.sublayers = [primary, blurred(primary, b, "glow-inner-bloom", p.bloom), blurred(primary, b, "glow-duplicate", p.spread)]

        let wrapper = full(b, "glowGroupWrapper")
        wrapper.allowsGroupOpacity = false
        wrapper.setValue(false, forKey: "allowsGroupBlending")
        wrapper.sublayers = [glow]
        layer.sublayers = [ring, image, wrapper]
    }

    private func blurred(_ src: CALayer, _ b: CGRect, _ name: String, _ radius: CGFloat) -> CALayer {
        let l = full(b, name)
        l.compositingFilter = Self.filter("plusL")
        l.setValue(p.haloGain, forKey: "gain")
        let blur = Self.filter("gaussianBlur")
        blur.setValue("gaussianBlur", forKey: "name")
        blur.setValue(Float(radius), forKey: "inputRadius")
        l.filters = [blur]
        let portal = Self.portal(src, hides: false, opacity: false)
        portal.frame = b
        l.addSublayer(portal)
        return l
    }

    private func full(_ b: CGRect, _ name: String) -> CALayer {
        let l = CALayer()
        l.frame = b
        l.name = name
        return l
    }

    static func filter(_ type: String) -> NSObject {
        let cls = NSClassFromString("CAFilter") as! NSObject.Type
        return cls.perform(NSSelectorFromString("filterWithType:"), with: type)!.takeUnretainedValue() as! NSObject
    }

    private static func portal(_ src: CALayer, hides: Bool, opacity: Bool) -> CALayer {
        let l = (NSClassFromString("CAPortalLayer") as! CALayer.Type).init()
        l.setValue(src, forKey: "sourceLayer")
        if hides { l.setValue(true, forKey: "hidesSourceLayer") }
        if opacity { l.setValue(true, forKey: "matchesOpacity") }
        l.setValue(true, forKey: "matchesPosition")
        l.setValue(true, forKey: "matchesTransform")
        return l
    }

    // MARK: 没有私有接口时：一圈白线加一点白光

    private func buildFallback(_ b: CGRect) {
        let s = CAShapeLayer()
        s.fillColor = nil
        s.strokeColor = NSColor(white: 1, alpha: 0.95).cgColor
        s.lineWidth = p.ringWidth
        s.shadowColor = NSColor(calibratedRed: 0.85, green: 0.8, blue: 1, alpha: 1).cgColor
        s.shadowOpacity = 0.9
        s.shadowRadius = p.spread
        s.shadowOffset = .zero
        ring.addSublayer(s)
        fallback = s
        layer.sublayers = [ring]
    }

    // MARK: 位置、出现、消失

    var ringWidth: CGFloat { p.ringWidth }

    /// 光贴着 r 的里面一圈（和系统一样：边往里画）。animated：从现在的样子弹过去（认出二维码时缩过去）。
    /// outside：画在 r 外面一圈（框着二维码时，不压在码的白边上，亮线落在暗处看得清）
    /// clamp：贴着屏幕边的那几边收进来，不被屏幕边切掉（窗口铺满屏幕时，外面已经没有位置了）
    func move(to rect: CGRect, corner c: CGFloat, animated: Bool, outside: Bool = false, clamp: CGRect? = nil,
              duration: CGFloat = 0.42, bounce: CGFloat = 0.16) {
        var r = outside ? rect.insetBy(dx: -p.ringWidth, dy: -p.ringWidth) : rect
        if outside, let clamp {
            let k = r.intersection(clamp.insetBy(dx: 0.5, dy: 0.5))
            if !k.isNull { r = k }
        }
        let corner = outside && c > 0 ? c + p.ringWidth : c
        Motion.move(ring, frame: r, corner: corner, animated: animated, duration: duration, bounce: bounce)
        if let fallback {
            let path = CGPath(roundedRect: CGRect(origin: .zero, size: r.size).insetBy(dx: p.ringWidth / 2, dy: p.ringWidth / 2),
                              cornerWidth: max(0, corner - p.ringWidth / 2), cornerHeight: max(0, corner - p.ringWidth / 2), transform: nil)
            let from = fallback.presentation()?.path ?? fallback.path
            CATransaction.begin(); CATransaction.setDisableActions(true)
            fallback.frame = CGRect(origin: .zero, size: r.size)
            fallback.path = path
            CATransaction.commit()
            if animated, let from { fallback.add(Motion.spring("path", from: from, to: path, duration: duration, bounce: bounce), forKey: "path") }
            return
        }
        // 颜色图跟着选区中心走，按对角线放大（至少 786pt），转起来才盖得住四个角
        let k = max(hypot(r.width, r.height), 786) / 786
        let t = CATransform3DMakeScale(k, k, 1)
        let pos = CGPoint(x: r.midX, y: r.midY)
        let fromPos = image.presentation()?.position ?? image.position
        let fromT = image.presentation()?.transform ?? image.transform
        CATransaction.begin(); CATransaction.setDisableActions(true)
        image.position = pos
        image.transform = t
        CATransaction.commit()
        guard animated else { return }
        image.add(Motion.spring("position", from: NSValue(point: fromPos), to: NSValue(point: pos), duration: duration, bounce: bounce), forKey: "glide.position")
        // 只动缩放，不要盖掉转动的动画（transform.rotation.z 是加在上面的）
        let fromScale = fromT.m11 == 0 ? k : hypot(fromT.m11, fromT.m12)
        image.add(Motion.spring("transform.scale", from: fromScale, to: k, duration: duration, bounce: bounce), forKey: "glide.scale")
    }

    /// 亮起来。整个光的亮度跟着 ring 的透明度走（遮罩 matchesOpacity），所以只动 ring
    func show(duration: CFTimeInterval = 0.18) {
        hidden = false
        Motion.fade(ring, to: 1, duration: duration, curve: .easeOut)
    }

    func hide(duration: CFTimeInterval = 0.26, then: (() -> Void)? = nil) {
        hidden = true
        Motion.fade(ring, to: 0, duration: duration, curve: .easeIn)
        guard let then else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.02) { then() }
    }

    /// 一直亮着（淡入淡出交给外面的容器）
    func setVisible() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ring.opacity = 1
        CATransaction.commit()
    }

    var opacity: Float { ring.presentation()?.opacity ?? ring.opacity }
    var frame: CGRect { ring.frame }

    // MARK: 颜色图

    /// 单色的渐变小图：橙（Capture 的橙）、白（干净的白边）、冷白（白芯偏一点蓝的光）
    private static func texture(for tint: Tint) -> CGImage? {
        if tint == .iridescent { return texture }
        let pair: [CGColor]
        switch tint {
        case .orange: pair = [CGColor(red: 1, green: 0.46, blue: 0.02, alpha: 1), CGColor(red: 1, green: 0.38, blue: 0, alpha: 1)]
        case .white: pair = [CGColor(gray: 1, alpha: 1), CGColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1)]
        case .cool: pair = [CGColor(red: 0.93, green: 0.96, blue: 1, alpha: 1), CGColor(red: 0.74, green: 0.85, blue: 1, alpha: 1)]
        case .iridescent: pair = []
        }
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let g = CGGradient(colorsSpace: cs, colors: pair as CFArray, locations: [0, 1]) else { return nil }
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 64, y: 64), options: [])
        return ctx.makeImage()
    }

    /// 自己画的一张很模糊的渐变：上面暖（褐、橙），中间浅紫和天蓝，下面蓝紫、品红、深靛。
    /// 竖长的（和系统那张一样，拉成正方形后上下的颜色带变窄）
    private static let texture: CGImage? = {
        let rows: [[UInt32]] = [
            [0x7A5A52, 0x8E5A30, 0x9A5410, 0x9C4A00],
            [0x8D7FA8, 0xA5778A, 0xB26A3A, 0xB25C08],
            [0x7F9EE0, 0x9A94C8, 0xB47E86, 0xBA6A26],
            [0x6585EC, 0x8A86D6, 0xA874A8, 0xB45A62],
            [0x4462D8, 0x6A58C8, 0x9440A0, 0xA82A76],
            [0x1C38B0, 0x3A2AA4, 0x64148C, 0x7E006A],
            [0x02206F, 0x0F1670, 0x2C0A64, 0x3C0048],
        ]
        let w = 96, h = 208
        var px = [UInt8](repeating: 255, count: w * h * 4)
        func ch(_ c: UInt32, _ i: Int) -> CGFloat { CGFloat((c >> (16 - 8 * i)) & 0xFF) }
        func smooth(_ x: CGFloat) -> CGFloat { x * x * (3 - 2 * x) }
        for y in 0..<h {
            let fy = CGFloat(y) / CGFloat(h - 1) * CGFloat(rows.count - 1)
            let y0 = min(Int(fy), rows.count - 2), ty = smooth(fy - CGFloat(y0))
            for x in 0..<w {
                let fx = CGFloat(x) / CGFloat(w - 1) * CGFloat(rows[0].count - 1)
                let x0 = min(Int(fx), rows[0].count - 2), tx = smooth(fx - CGFloat(x0))
                for i in 0..<3 {
                    let a = ch(rows[y0][x0], i) * (1 - tx) + ch(rows[y0][x0 + 1], i) * tx
                    let b = ch(rows[y0 + 1][x0], i) * (1 - tx) + ch(rows[y0 + 1][x0 + 1], i) * tx
                    px[(y * w + x) * 4 + i] = UInt8(max(0, min(255, a * (1 - ty) + b * ty)).rounded())
                }
            }
        }
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: cs,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }()
}
