import AppKit
import QuartzCore

/// 自动滚动：在后台线程上按屏幕刷新的节奏（120Hz）发很小的连续滚轮（像触控板），速度平滑地起、停。
/// 系统只把滚轮交给鼠标下面的窗口，所以滚的时候指针放在选区中间；用户自己一动鼠标就马上停下、指针交还给用户
/// （可以直接去点 Done）。自己停下（到底了、按了键）时指针回到开始前的位置
final class AutoScroller: @unchecked Sendable {
    /// 发滚轮的位置（窗口坐标：原点在主屏左上）
    private let point: CGPoint
    /// 所有实例共用一条队列：换栏时旧的最后一下和新的开始不会同时跑
    private static let sharedQueue = DispatchQueue(label: "QuickCap.autoscroll", qos: .userInteractive)
    private var queue: DispatchQueue { Self.sharedQueue }
    private var timer: DispatchSourceTimer?
    /// 用户动了鼠标（在主线程上回调）
    var onUserMoved: (() -> Void)?
    // 下面这些只在 queue 上读写
    private var speed: CGFloat
    private var current: CGFloat = 0
    private var goal: CGFloat
    private var carry: CGFloat = 0
    private var last: CFTimeInterval = 0
    private var stopping = false
    /// 停一下（看看是不是真的到底了）：不发滚轮，但还在看用户有没有动鼠标
    private var holding = false
    private var began = false
    private var home: CGPoint = .zero
    private let source = CGEventSource(stateID: .privateState)
    /// 调试用：发了多少、怎么停的
    var debug: String { lock.lock(); defer { lock.unlock() }; return debugShared }
    private var debugShared = ""
    private func setDebug(_ s: String) { lock.lock(); debugShared = s; lock.unlock() }
    private var sent = 0
    /// 一共发了多少 pt（主线程读，拿来和画面实际挪了多少比：差很多就是到底了）
    private let lock = NSLock()
    private var sentShared: CGFloat = 0
    var sentTotal: CGFloat { lock.lock(); defer { lock.unlock() }; return sentShared }

    /// at：在哪里滚（屏幕坐标，原点左下；系统把滚轮交给这下面的那一栏）；speed：每秒滚多少 pt
    /// home：停下后指针回到哪（窗口坐标）。接着滚另一栏时传上一次的，不然记下的是上一次滚的地方
    init(at p: CGPoint, speed: CGFloat, home: CGPoint? = nil) {
        let h = CGDisplayBounds(CGMainDisplayID()).height
        point = CGPoint(x: p.x.rounded(), y: (h - p.y).rounded())
        self.speed = speed
        goal = speed
        givenHome = home
    }
    private let givenHome: CGPoint?
    /// 开始时指针在哪（窗口坐标），start() 之后才有
    var homeLocation: CGPoint { queue.sync { home } }

    func start() {
        queue.async {
            self.home = self.givenHome ?? CGEvent(source: nil)?.location ?? self.point
            self.warp(self.point)
            self.last = CACurrentMediaTime()
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: self.queue)
            t.schedule(deadline: .now(), repeating: .nanoseconds(8_333_333), leeway: .microseconds(500))
            t.setEventHandler { [weak self = self] in self?.tick() }
            t.resume()
            self.timer = t
        }
    }

    /// 停：慢慢减速停下（0.2 秒左右），指针回到开始前的位置。immediately：马上停（关掉截图界面时、到底了：
    /// 再滚只会把页面往上拉过头）
    /// restore：false 时指针不回去（接着去滚另一栏：回去的话会和下一个挪指针的撞上，下一个以为是用户动了鼠标）
    func stop(immediately: Bool = false, restore: Bool = true) {
        queue.async {
            // 停顿中不发滚轮、tick 也走不到减速那步：直接收尾，不然计时器一直跑、指针回不去
            if immediately || self.holding { self.finish(restore: restore); return }
            self.stopping = true
            self.goal = 0
        }
    }

    /// 马上停住，不发滚轮（指针不动）：页面自己弹回来、加载更多。之后 resume() 接着滚
    func hold() {
        queue.async {
            self.holding = true
            self.current = 0
            self.goal = 0
            self.carry = 0
            if self.began { self.post(0, phase: 4); self.began = false }
        }
    }

    /// 接着滚（慢慢起步）
    func resume() {
        queue.async {
            guard self.holding else { return }
            self.holding = false
            self.goal = self.speed
        }
    }

    /// 两帧对不上：滚慢一点
    func slowDown() {
        queue.async {
            self.speed = max(self.speed * 0.8, 160)
            if !self.stopping && !self.holding { self.goal = self.speed }
        }
    }

    private func warp(_ p: CGPoint) {
        CGWarpMouseCursorPosition(p)
        // 挪完马上能接着用鼠标（不然系统会让鼠标停一下）
        CGAssociateMouseAndMouseCursorPosition(1)
        // 直接挪指针不会发"鼠标移动"：Chrome 的侧边栏这类单独的视图不知道指针已经到它上面了，滚轮还送去原来那块（网页），
        // 侧边栏一动不动、被当成"没东西可滚"。补发一次鼠标移动，让指针下面那块知道
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cgSessionEventTap)
    }

    private func finish(restore: Bool) {
        guard let t = timer else { return }
        t.cancel()
        timer = nil
        if began { post(0, phase: 4) }
        if restore { warp(home) }
        // 回调里抓着自己（session 设的 onUserMoved 引用了这个对象）：停完放掉，不然每次换栏都漏一个。
        // 排在上面那个回调之后（同一条主队列，先进先出）
        DispatchQueue.main.async { self.onUserMoved = nil }
    }

    private func tick() {
        // 用户自己动了鼠标：马上停，什么都不再发（不然指针又被拉回来）
        if let now = CGEvent(source: nil)?.location, hypot(now.x - point.x, now.y - point.y) > 3 {
            setDebug("userMoved at=\(Int(now.x)),\(Int(now.y)) point=\(Int(point.x)),\(Int(point.y)) sent=\(sent)")
            DispatchQueue.main.async { self.onUserMoved?() }
            finish(restore: false)
            return
        }
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(now - last, 0.05))
        last = now
        if holding { setDebug("holding sent=\(sent)"); return }
        // 速度朝目标指数靠近：起步、停下都是顺的
        current += (goal - current) * (1 - exp(-dt / 0.14))
        if stopping && current < 3 { setDebug("stopped sent=\(sent)"); finish(restore: true); return }
        carry += current * dt
        let step = Int32(carry.rounded(.down))
        guard step >= 1 else { return }
        carry -= CGFloat(step)
        post(step, phase: began ? 2 : 1)
        began = true
        sent += Int(step)
        lock.lock(); sentShared += CGFloat(step); lock.unlock()
        setDebug("running speed=\(Int(current)) sent=\(sent)")
    }

    /// 连续的滚轮（像触控板：开始、进行中、结束），app 直接按这么多挪，不会自己再加一段动画（加了就一顿一顿）
    private func post(_ px: Int32, phase: Int64) {
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: -px, wheel2: 0, wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        e.location = point
        e.post(tap: .cgSessionEventTap)
    }
}
