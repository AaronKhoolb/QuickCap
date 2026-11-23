import AppKit

/// 框选时可以吸附的边：窗口的四条边（被前面的窗口挡住的部分不算）、屏幕四边、菜单栏下沿。
/// 坐标是覆盖窗口里的坐标：原点在左下角，单位 pt。
///
/// 第一层只吸窗口边框。之后再加界面元素（辅助功能）和画面里的直线（边缘检测）。
struct SnapLines {
    struct Segment {
        /// 竖线的 x，或横线的 y
        var pos: CGFloat
        /// 线的范围：竖线是 y 的范围，横线是 x 的范围
        var from: CGFloat
        var to: CGFloat
    }

    var vertical: [Segment] = []
    var horizontal: [Segment] = []

    /// 离线多近开始吸（pt）
    static let threshold: CGFloat = 7
    /// 线的范围要和正在动的那条边有重叠（放宽这么多）才吸，离得很远的窗口边不吸
    static let reach: CGFloat = 48

    /// windows 从前往后排（见 ScreenWindows.list）
    @MainActor
    static func build(for screen: NSScreen, size: CGSize, windows: [ScreenWindow]) -> SnapLines {
        var s = SnapLines()
        s.vertical = [Segment(pos: 0, from: 0, to: size.height), Segment(pos: size.width, from: 0, to: size.height)]
        s.horizontal = [Segment(pos: 0, from: 0, to: size.width), Segment(pos: size.height, from: 0, to: size.width)]
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        if menuBar > 0 { s.horizontal.append(Segment(pos: size.height - menuBar, from: 0, to: size.width)) }
        var front: [CGRect] = []
        for w in windows {
            let r = w.rect
            for x in [r.minX, r.maxX] where x > 0.5 && x < size.width - 0.5 {
                let hidden = front.filter { $0.minX < x - 0.5 && $0.maxX > x + 0.5 }.map { ($0.minY, $0.maxY) }
                for (a, b) in visible(r.minY, r.maxY, minus: hidden) { s.vertical.append(Segment(pos: x, from: a, to: b)) }
            }
            for y in [r.minY, r.maxY] where y > 0.5 && y < size.height - 0.5 {
                let hidden = front.filter { $0.minY < y - 0.5 && $0.maxY > y + 0.5 }.map { ($0.minX, $0.maxX) }
                for (a, b) in visible(r.minX, r.maxX, minus: hidden) { s.horizontal.append(Segment(pos: y, from: a, to: b)) }
            }
            front.append(r)
        }
        return s
    }

    /// 线段 [a, b] 去掉被挡住的几段后，剩下的可见部分（太短的不要）
    private static func visible(_ a: CGFloat, _ b: CGFloat, minus cuts: [(CGFloat, CGFloat)]) -> [(CGFloat, CGFloat)] {
        var pieces = [(a, b)]
        for (c0, c1) in cuts {
            pieces = pieces.flatMap { (p0, p1) -> [(CGFloat, CGFloat)] in
                guard c1 > p0, c0 < p1 else { return [(p0, p1)] }
                var out: [(CGFloat, CGFloat)] = []
                if c0 > p0 { out.append((p0, c0)) }
                if c1 < p1 { out.append((c1, p1)) }
                return out
            }
        }
        return pieces.filter { $0.1 - $0.0 >= 8 }
    }

    /// v 附近有没有可以吸的线。span 是正在动的那条边在另一个方向上的范围
    static func snap(_ v: CGFloat, along span: ClosedRange<CGFloat>, in segments: [Segment]) -> Segment? {
        var best: Segment?
        var d = threshold
        for g in segments where g.to >= span.lowerBound - reach && g.from <= span.upperBound + reach {
            let dd = abs(g.pos - v)
            if dd < d { d = dd; best = g }
        }
        return best
    }
}
