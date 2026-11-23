import CoreGraphics

/// 两端固定的绳子，用 Verlet 积分加距离约束模拟。
/// 坐标系 y 轴向下。挂在绳上的卡片按质量分摊到相邻节点上，
/// 所以挂的地方会被压低，取下时会弹回去。
final class Rope {
    struct Load { var x: CGFloat; var mass: CGFloat }

    private(set) var points: [CGPoint] = []
    private var previous: [CGPoint] = []
    private var invMass: [CGFloat] = []
    private var segmentLength: CGFloat = 0

    var gravity: CGFloat = 1400
    /// 每秒速度保留比例的对数衰减，越大停得越快
    var damping: CGFloat = 4.5
    var iterations = 90

    private(set) var leftAnchor = CGPoint.zero
    private(set) var rightAnchor = CGPoint.zero

    /// 按给定的下垂量重建绳子。总长度用抛物线弧长近似。
    func reset(left: CGPoint, right: CGPoint, sag: CGFloat, count: Int = 36) {
        leftAnchor = left
        rightAnchor = right
        let span = right.x - left.x
        let length = span + 8 * sag * sag / (3 * max(span, 1))
        segmentLength = length / CGFloat(count - 1)
        points = (0..<count).map { i in
            let t = CGFloat(i) / CGFloat(count - 1)
            let x = left.x + span * t
            let y = left.y + (right.y - left.y) * t + 4 * sag * t * (1 - t)
            return CGPoint(x: x, y: y)
        }
        previous = points
        invMass = Array(repeating: 1, count: count)
    }

    func step(dt: CGFloat, loads: [Load]) {
        guard points.count > 2 else { return }
        let n = points.count

        var mass = Array(repeating: CGFloat(1), count: n)
        for load in loads {
            let (i, t) = segment(at: load.x)
            mass[i] += load.mass * (1 - t)
            mass[i + 1] += load.mass * t
        }
        for i in 0..<n { invMass[i] = 1 / mass[i] }
        invMass[0] = 0
        invMass[n - 1] = 0

        let keep = exp(-damping * dt)
        for i in 1..<(n - 1) {
            let p = points[i]
            let v = CGPoint(x: (p.x - previous[i].x) * keep, y: (p.y - previous[i].y) * keep)
            previous[i] = p
            points[i] = CGPoint(x: p.x + v.x, y: p.y + v.y + gravity * dt * dt)
        }
        points[0] = leftAnchor
        points[n - 1] = rightAnchor
        previous[0] = leftAnchor
        previous[n - 1] = rightAnchor

        for _ in 0..<iterations {
            for i in 0..<(n - 1) {
                let a = points[i], b = points[i + 1]
                let dx = b.x - a.x, dy = b.y - a.y
                let d = max(sqrt(dx * dx + dy * dy), 0.0001)
                let wa = invMass[i], wb = invMass[i + 1]
                let w = wa + wb
                guard w > 0 else { continue }
                let diff = (d - segmentLength) / (d * w)
                points[i].x += dx * diff * wa
                points[i].y += dy * diff * wa
                points[i + 1].x -= dx * diff * wb
                points[i + 1].y -= dy * diff * wb
            }
        }
    }

    /// 绳子上横坐标为 x 的点。超出两端（滚动时卡片滑到屏幕外）就水平延伸，高度和端点一样。
    /// 不能沿着端点的斜率延长：绳子两端往上翘，延长下去卡片会越来越高，滑回来时从上面掉下来。
    func point(at x: CGFloat) -> CGPoint {
        guard points.count > 1 else { return CGPoint(x: x, y: leftAnchor.y) }
        if x < points[0].x { return CGPoint(x: x, y: points[0].y) }
        if x > points[points.count - 1].x { return CGPoint(x: x, y: points[points.count - 1].y) }
        let (i, t) = segment(at: x)
        let a = points[i], b = points[i + 1]
        return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// 在 x 附近给绳子一个竖直方向的冲量（正数向下）。
    func kick(at x: CGFloat, dy: CGFloat, radius: CGFloat = 140) {
        for i in 1..<max(points.count - 1, 1) {
            let d = abs(points[i].x - x)
            guard d < radius else { continue }
            let f = 0.5 * (1 + cos(.pi * d / radius))
            previous[i].y -= dy * f
        }
    }

    /// 最近一步里节点移动的最大距离，用来判断绳子是否已经静止。
    var maxMotion: CGFloat {
        zip(points, previous).reduce(0) { max($0, abs($1.0.x - $1.1.x) + abs($1.0.y - $1.1.y)) }
    }

    private func segment(at x: CGFloat) -> (Int, CGFloat) {
        let n = points.count
        let span = rightAnchor.x - leftAnchor.x
        let f = min(max((x - leftAnchor.x) / max(span, 1), 0), 1) * CGFloat(n - 1)
        let i = min(Int(f), n - 2)
        return (i, f - CGFloat(i))
    }
}

/// 一维弹簧，用于卡片横向滑动和整体收起/展开。
struct Spring {
    var value: CGFloat
    var velocity: CGFloat = 0
    var target: CGFloat
    var stiffness: CGFloat = 170
    var damping: CGFloat = 22

    init(_ value: CGFloat) {
        self.value = value
        self.target = value
    }

    mutating func step(_ dt: CGFloat) {
        let a = stiffness * (target - value) - damping * velocity
        velocity += a * dt
        value += velocity * dt
    }

    var isSettled: Bool { abs(target - value) < 0.3 && abs(velocity) < 2 }
}
