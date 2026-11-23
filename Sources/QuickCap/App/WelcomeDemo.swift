import SwiftUI

/// 欢迎页第一页的演示，循环播放，和真的截图一样的过程：
/// 截图架收起、屏幕变暗 → 从图表左上角拖到右下角（靠近边缘时吸附，橙线闪一下）→ 点 Capture、闪白 →
/// 截图架出来，截下的那块缩小飞上去挂好、晃几下停住。
/// 打开"减少动态效果"时停在框选好的那一刻
struct WelcomeDemo: View {
    @State private var start = Date()
    @Environment(\.accessibilityReduceMotion) private var systemReduce
    static let loop = 5.6
    /// 调试用：固定在某一刻（截图对比用）
    static var debugTime: Double?

    var body: some View {
        let still = systemReduce || ReduceMotion.forced || Self.debugTime != nil
        TimelineView(.animation(paused: still)) { ctx in
            let t = Self.debugTime ?? (still ? 1.6 : ctx.date.timeIntervalSince(start).truncatingRemainder(dividingBy: Self.loop))
            DemoFrame(t: t)
        }
        .accessibilityElement()
        .accessibilityLabel("A selection is dragged over a chart, captured, and hung on the Shelf.")
    }
}

// MARK: 布局（500×264，原点左上）

private enum L {
    static let size = WelcomeView.artSize
    static let window = CGRect(x: 28, y: 84, width: 290, height: 164)
    /// 窗口里那张图表
    static let chart = CGRect(x: 122, y: 108, width: 176, height: 104)
    static let snap: CGFloat = 8
    /// 绳子：两头高、中间垂下来一点
    static func ropeY(_ x: CGFloat) -> CGFloat { let u = x / size.width; return 22 + 36 * u * (1 - u) }
    static let hangX: CGFloat = 300
    static var hangTop: CGPoint { CGPoint(x: hangX, y: ropeY(hangX) + 9) }
    static let hangScale: CGFloat = 0.34

    // 时间（秒）
    static let shelfOut = (0.30, 0.45), dimIn = (0.32, 0.48), approach = (0.18, 0.45)
    static let drag = (0.45, 1.25), settle = (1.25, 1.42)
    static let barIn = (1.45, 1.62), toBar = (1.50, 1.80), press = 1.86, captureAt = 1.95
    static let flight = (2.0, 2.85), fadeOut = (4.7, 5.1)
}

private func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }
private func seg(_ t: Double, _ r: (Double, Double)) -> Double { clamp01((t - r.0) / (r.1 - r.0)) }
private func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
private func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
private func mix(_ a: CGFloat, _ b: CGFloat, _ k: Double) -> CGFloat { a + (b - a) * CGFloat(k) }
private func mix(_ a: CGPoint, _ b: CGPoint, _ k: Double) -> CGPoint { CGPoint(x: mix(a.x, b.x, k), y: mix(a.y, b.y, k)) }

/// 某一刻的画面
private struct DemoFrame: View {
    let t: Double

    var body: some View {
        let sel = selection
        ZStack(alignment: .topLeading) {
            Wallpaper()
            DemoWindow().place(L.window)
            // 截图界面：暗下来的四周、选区的白边、吸附的橙线、Capture 条、闪白
            Group {
                DimHole(hole: sel).fill(Color.black.opacity(0.34), style: FillStyle(eoFill: true))
                if sel.width > 1 {
                    Rectangle().strokeBorder(.white, lineWidth: 1).shadow(color: .black.opacity(0.25), radius: 1)
                        .place(sel.insetBy(dx: -1, dy: -1))
                }
            }
            .opacity(dim)
            SnapGuide(vertical: true).opacity(guide).place(CGRect(x: L.chart.maxX - 0.5, y: L.chart.minY - 14, width: 1, height: L.chart.height + 28))
            SnapGuide(vertical: false).opacity(guide).place(CGRect(x: L.chart.minX - 14, y: L.chart.maxY - 0.5, width: L.chart.width + 28, height: 1))
            CaptureBar(pressed: t >= L.press && t < L.captureAt + 0.05)
                .scaleEffect(0.94 + 0.06 * barShown)
                .opacity(barShown)
                .position(barCenter)
            Rectangle().fill(.white).opacity(flash).place(L.chart)
            // 截图架
            DemoShelf().opacity(shelf)
            hungCard
            DemoPointer(arrow: t > L.drag.1 + 0.1).opacity(pointerShown).position(pointer)
        }
        .frame(width: L.size.width, height: L.size.height, alignment: .topLeading)
    }

    // MARK: 截图界面

    private var dim: Double { t < L.captureAt ? easeOut(seg(t, L.dimIn)) : 1 - seg(t, (L.captureAt, L.captureAt + 0.2)) }

    private var shelf: Double { t < 1 ? 1 - seg(t, L.shelfOut) : seg(t, (L.captureAt, L.captureAt + 0.25)) }

    /// 鼠标没吸附时的位置（拖动的路径）
    private static func raw(_ t: Double) -> CGPoint {
        let c = L.chart
        let over = CGPoint(x: c.maxX + 6, y: c.maxY + 5)
        if t < L.drag.1 { return mix(CGPoint(x: c.minX, y: c.minY), over, easeInOut(seg(t, L.drag))) }
        return mix(over, CGPoint(x: c.maxX + 2, y: c.maxY + 1), easeOut(seg(t, L.settle)))
    }

    private static func snapped(_ p: CGPoint) -> CGPoint {
        let c = L.chart
        return CGPoint(x: abs(p.x - c.maxX) <= L.snap ? c.maxX : p.x, y: abs(p.y - c.maxY) <= L.snap ? c.maxY : p.y)
    }

    /// 两条边都吸上的那一刻
    private static let snapTime: Double = stride(from: L.drag.0, to: L.drag.1, by: 0.005).first {
        let p = raw($0)
        return abs(p.x - L.chart.maxX) <= L.snap && abs(p.y - L.chart.maxY) <= L.snap
    } ?? L.drag.1

    private var selection: CGRect {
        guard t >= L.drag.0 else { return CGRect(origin: L.chart.origin, size: .zero) }
        let p = Self.snapped(Self.raw(t))
        return CGRect(x: L.chart.minX, y: L.chart.minY, width: max(0, p.x - L.chart.minX), height: max(0, p.y - L.chart.minY))
    }

    /// 吸上时橙线亮一下，松手后慢慢淡掉
    private var guide: Double {
        guard t >= Self.snapTime, t < L.captureAt else { return 0 }
        let on = seg(t, (Self.snapTime, Self.snapTime + 0.06))
        return on * (1 - seg(t, (L.settle.1, L.settle.1 + 0.45)))
    }

    private var barShown: Double { t < L.captureAt ? easeOut(seg(t, L.barIn)) : 1 - seg(t, (L.captureAt, L.captureAt + 0.1)) }
    private var barCenter: CGPoint { CGPoint(x: L.chart.midX, y: L.chart.maxY + 21) }

    private var flash: Double {
        guard t >= L.captureAt else { return 0 }
        let k = (t - L.captureAt) / 0.22
        return k > 1 ? 0 : 0.6 * (k < 0.15 ? k / 0.15 : 1 - (k - 0.15) / 0.85)
    }

    // MARK: 鼠标

    private var pointer: CGPoint {
        let c = L.chart
        if t < L.drag.0 { return mix(CGPoint(x: c.minX - 34, y: c.minY + 26), c.origin, easeOut(seg(t, L.approach))) }
        if t < L.toBar.0 { return Self.raw(t) }
        return mix(Self.raw(L.toBar.0), CGPoint(x: barCenter.x + 6, y: barCenter.y + 2), easeInOut(seg(t, L.toBar)))
    }

    private var pointerShown: Double {
        t < L.captureAt ? seg(t, (L.approach.0, L.approach.0 + 0.12)) : 1 - seg(t, (L.captureAt + 0.02, L.captureAt + 0.14))
    }

    // MARK: 飞上去挂好的那张

    @ViewBuilder
    private var hungCard: some View {
        if t >= L.flight.0, t < L.fadeOut.1 {
            let f = Flight(t: t)
            let c = L.chart
            ZStack(alignment: .top) {
                ChartCard(opaque: true)
                    .frame(width: c.width, height: c.height)
                    .clipShape(RoundedRectangle(cornerRadius: f.corner, style: .continuous))
                    .shadow(color: .black.opacity(f.shadowOpacity), radius: f.shadowRadius, y: f.shadowY)
                    .scaleEffect(f.scale, anchor: .top)
                DemoClip().opacity(f.clip).offset(y: -11)
            }
            .rotationEffect(.degrees(f.swing), anchor: .top)
            .frame(width: c.width, height: c.height, alignment: .top)
            .offset(x: f.top.x - c.width / 2, y: f.top.y)
            .opacity(f.opacity)
        }
    }
}

/// 飞上去的那张在某一刻的样子：先稍微浮起来一点，再缩小飞向绳子（路线往上拱一点），挂上后晃几下停住
private struct Flight {
    var scale: CGFloat = 1, top = CGPoint.zero, swing: Double = 0, opacity: Double = 1, clip: Double = 0
    var corner: CGFloat = 8, shadowOpacity: Double = 0.18, shadowRadius: CGFloat = 2, shadowY: CGFloat = 2

    init(t: Double) {
        let c = L.chart
        let u = seg(t, L.flight)
        let lift: Double = easeOut(clamp01(u / 0.18))
        let v: Double = easeInOut(clamp01((u - 0.12) / 0.88))
        scale = u < 0.18 ? mix(1, 1.04, lift) : mix(1.04, L.hangScale, v)
        var p = mix(CGPoint(x: c.midX, y: c.minY), L.hangTop, v)
        let arc: Double = 16 * sin(Double.pi * v) + 3 * lift * (1 - v)
        p.y -= CGFloat(arc)
        top = p
        let landed: Double = max(0, t - L.flight.1)
        let decay: Double = exp(-3.2 * landed)
        swing = landed > 0 ? 8 * decay * sin(2 * Double.pi * 1.35 * landed) : 0
        opacity = 1 - seg(t, L.fadeOut)
        clip = seg(t, (L.flight.1 - 0.08, L.flight.1))
        // 缩小后圆角看起来一样大（挂着的卡片是 4pt 左右）
        corner = 8 / max(scale, 0.5) * 0.9
        let floating: Double = lift * (1 - v)
        shadowOpacity = 0.18 + 0.12 * floating
        shadowRadius = CGFloat(2 + 10 * floating + 3 * v)
        shadowY = CGFloat(2 + 4 * v)
    }
}

// MARK: 画面里的东西

/// 屏幕背景：柔和的渐变，深色模式暗一些
struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [.dyn(0xA7BBD6, 0x24304A), .dyn(0xE9D8C4, 0x40342E)], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [.white.opacity(0.28), .clear], center: UnitPoint(x: 0.8, y: 0), startRadius: 0, endRadius: 320)
        }
    }
}

/// 一个普通的 app 窗口：标题栏的三个点、左边几行字、右边一张图表
private struct DemoWindow: View {
    var body: some View {
        let c = L.chart, w = L.window
        ZStack(alignment: .topLeading) {
            Color.dyn(0xFFFFFF, 0x2C2C2E)
            TrafficLights().offset(x: 12, y: 10)
            VStack(alignment: .leading, spacing: 7) {
                ForEach([62.0, 48, 70, 40, 56, 34], id: \.self) { len in
                    Capsule().fill(Color.primary.opacity(0.1)).frame(width: len, height: 5)
                }
            }
            .offset(x: 14, y: c.minY - w.minY + 6)
            ChartCard(opaque: false)
                .frame(width: c.width, height: c.height)
                .offset(x: c.minX - w.minX, y: c.minY - w.minY)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
    }
}

struct TrafficLights: View {
    var body: some View {
        HStack(spacing: 6) {
            ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { c in
                Circle().fill(Color(rgb: UInt32(c))).frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
            }
        }
    }
}

/// 被截的那张图表（窗口里一份、飞出去的一份，一模一样）
private struct ChartCard: View {
    let opaque: Bool
    private static let bars: [CGFloat] = [26, 38, 31, 50, 43, 62, 47]

    var body: some View {
        ZStack(alignment: .topLeading) {
            if opaque { Color.dyn(0xFFFFFF, 0x2C2C2E) }
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04))
            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            VStack(alignment: .leading, spacing: 2) {
                Text("Weekly visits").font(.system(size: 8.5, weight: .medium)).foregroundStyle(.secondary)
                Text("1,284").font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
            }
            .offset(x: 12, y: 9)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Self.bars.indices, id: \.self) { i in
                    UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3, style: .continuous)
                        .fill(LinearGradient(colors: [Color(rgb: i == 5 ? 0xFFA23A : 0x6AAEFF), Color(rgb: i == 5 ? 0xFF8A00 : 0x2F7BF6)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 14, height: Self.bars[i])
                }
            }
            .frame(width: 176, height: 96, alignment: .bottom)
        }
    }
}

/// 截图时暗下来的四周（中间挖掉选区）
private struct DimHole: Shape {
    let hole: CGRect
    func path(in rect: CGRect) -> Path {
        var p = Path(rect)
        if hole.width > 0, hole.height > 0 { p.addRect(hole) }
        return p
    }
}

/// 吸附时的橙线（带一点光）
private struct SnapGuide: View {
    let vertical: Bool
    var body: some View {
        Rectangle().fill(Color(rgb: 0xFF9F0A))
            .shadow(color: Color(rgb: 0xFF9500).opacity(0.9), radius: 3)
    }
}

/// 框选好后出现在下面的 Capture 条（真的那根条的样子，缩小）
private struct CaptureBar: View {
    let pressed: Bool
    var body: some View {
        HStack(spacing: 5) {
            Text("Capture").font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 21)
        .background(Capsule().fill(Color(rgb: 0xFF8A00)))
        .padding(3)
        .background(Capsule().fill(Color.dyn(0xF4F4F6, 0x3A3A3C)).shadow(color: .black.opacity(0.25), radius: 6, y: 2))
        .scaleEffect(pressed ? 0.94 : 1)
    }
}

/// 截图架：一根绳子、两张已经挂着的
private struct DemoShelf: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            DemoRope()
            hanging(x: 378, w: 44, h: 56, colors: [0xFFB36B, 0xFF7E7E])
            hanging(x: 456, w: 62, h: 44, colors: [0x8FA8FF, 0xB18CFF])
        }
    }

    private func hanging(x: CGFloat, w: CGFloat, h: CGFloat, colors: [UInt32]) -> some View {
        let top = L.ropeY(x) + 9
        return ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(LinearGradient(colors: colors.map { Color(rgb: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach([0.6, 0.85, 0.5], id: \.self) { k in
                            Capsule().fill(.white.opacity(0.55)).frame(width: (w - 14) * k, height: 2.5)
                        }
                    }
                    .padding(7)
                }
                .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
                .frame(width: w, height: h)
            DemoClip().offset(y: -11)
        }
        .frame(width: w, height: h, alignment: .top)
        .offset(x: x - w / 2, y: top)
    }
}

private struct DemoRope: View {
    var body: some View {
        let w = L.size.width
        let path = Path { p in
            p.move(to: CGPoint(x: -4, y: L.ropeY(-4)))
            p.addQuadCurve(to: CGPoint(x: w + 4, y: L.ropeY(w + 4)), control: CGPoint(x: w / 2, y: 40))
        }
        ZStack {
            path.stroke(Color.dyn(0x8E8E93, 0x6C6C70), lineWidth: 2)
            path.stroke(Color.white.opacity(0.45), lineWidth: 0.6).offset(y: -0.4)
        }
    }
}

/// 夹在绳子上的小夹子：一个小圈、一小段、底下一块
private struct DemoClip: View {
    var body: some View {
        VStack(spacing: 0) {
            Circle().strokeBorder(Color.dyn(0x8E8E93, 0x8E8E93), lineWidth: 1.2).frame(width: 5, height: 5)
            Rectangle().fill(Color.dyn(0x8E8E93, 0x8E8E93)).frame(width: 1.2, height: 3)
            RoundedRectangle(cornerRadius: 1.2).fill(Color.dyn(0x9A9AA0, 0x8E8E93)).frame(width: 7, height: 3.5)
        }
    }
}

/// 鼠标：框选时是十字，之后是箭头
struct DemoPointer: View {
    let arrow: Bool
    var body: some View {
        if arrow {
            ArrowShape().fill(.black).overlay(ArrowShape().stroke(.white, lineWidth: 1.1))
                .frame(width: 12, height: 18).offset(x: 6, y: 9)
                .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
        } else {
            ZStack {
                Crosshair().stroke(.white, lineWidth: 3)
                Crosshair().stroke(.black, lineWidth: 1)
            }
            .frame(width: 19, height: 19)
        }
    }
}

private struct Crosshair: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            p.move(to: CGPoint(x: r.minX, y: r.midY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        }
    }
}

/// 系统箭头的样子（尖在左上）
struct ArrowShape: Shape {
    func path(in r: CGRect) -> Path {
        let sx = r.width / 12, sy = r.height / 18
        let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, 15.5), (3.6, 12.2), (6.2, 17.8), (8.4, 16.8), (5.9, 11.4), (11, 11.2)]
        return Path { p in
            p.addLines(pts.map { CGPoint(x: r.minX + $0.0 * sx, y: r.minY + $0.1 * sy) })
            p.closeSubpath()
        }
    }
}

extension View {
    /// 放在 topLeading 的 ZStack 里的某个位置
    func place(_ r: CGRect) -> some View { frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY) }
}

extension Color {
    init(rgb: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double(rgb >> 16 & 0xff) / 255, green: Double(rgb >> 8 & 0xff) / 255, blue: Double(rgb & 0xff) / 255, opacity: opacity)
    }

    /// 浅色、深色外观各一个颜色
    static func dyn(_ light: UInt32, _ dark: UInt32, opacity: Double = 1) -> Color {
        func ns(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: opacity)
        }
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light) })
    }
}
