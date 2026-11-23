import AppKit
import QuartzCore

/// 悬挂架收起后藏在屏幕边外面的小把手：一小截绳子从屏幕边伸出来，挂着最新的两张截图（后面那张露一角），
/// 右下角的小牌写着挂着几张。和截图架用同样的绳子、挂扣、卡片样子，一看就知道是收起来的截图架。
/// 平时完全看不见，不挡东西：鼠标推到屏幕边上、菜单栏下面那一小段停一下，把手才从边上滑出来；
/// 鼠标走开就滑回去。滑出来以后碰到（或点一下，看设置）就展开悬挂架；
/// 按住横着拖到屏幕另一边，悬挂架就改成从那边出来。
@MainActor
final class ShelfHandle {
    /// 请求展开。byHover 表示是鼠标碰到触发的
    var onReveal: ((_ byHover: Bool) -> Void)?
    /// 拖到另一边松手后调用
    var onSideChange: ((ShelfSide) -> Void)?

    private let panel: HandlePanel
    private let view: HandleView
    private(set) var side: ShelfSide = .right
    private var screen: NSScreen?
    private var topInset: CGFloat = 24
    /// 悬挂架收起着，鼠标碰到边上时可以滑出来
    private var armed = false
    /// 正滑出来（或已经滑出来了）
    private(set) var isPeeking = false
    private var dwellTimer: Timer?
    private var retractTimer: Timer?

    static let tabSize = CGSize(width: 46, height: 66)

    /// 换截图文件夹时整个截图架关掉，把手也收走
    func close() {
        dwellTimer?.invalidate()
        retractTimer?.invalidate()
        panel.orderOut(nil)
    }
    /// 窗口比把手大一圈，给阴影留地方
    static let shadowMargin: CGFloat = 14
    /// 屏幕边上从菜单栏底下往下这么长的一段算触发区（把手就在这一段的上部）
    static let triggerBandHeight: CGFloat = 150
    /// 鼠标在触发区停多久把手才滑出来。路过、拖窗口贴边、换到旁边的显示器都不会触发
    static let dwell: TimeInterval = 0.12
    /// 鼠标离开把手和触发区多久后滑回去
    static let retractDelay: TimeInterval = 0.7
    /// 滑出来以后鼠标在把手上停多久展开悬挂架（设置成"碰到展开"时）
    static let hoverDelay: TimeInterval = 0.2

    init() {
        view = HandleView(frame: .zero)
        panel = HandlePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.contentView = view
        view.handle = self
    }

    var trigger: RevealTrigger = .hover

    func setCount(_ n: Int) {
        view.count = n
        if n == 0, isPeeking { retract() }
    }

    /// 把手上挂的两张（最新的在前）：已经做好的卡片图
    func setCards(_ images: [CGImage]) { view.cards = images }

    /// 悬挂架收起时为 true：等鼠标碰到边上再滑出来。展开时为 false，把手马上滑回去
    func setArmed(_ on: Bool) {
        armed = on
        if !on {
            dwellTimer?.invalidate(); dwellTimer = nil
            if isPeeking { retract() }
        }
    }

    /// 由控制器在鼠标移动时调用（悬挂架收起时）
    func pointerMoved() {
        guard armed, view.count > 0, !view.isDragging else { return }
        if isPeeking {
            if isNearTab || isInTrigger {
                retractTimer?.invalidate(); retractTimer = nil
                view.beginHoverIfUnderMouse()
            } else if retractTimer == nil {
                retractTimer = Timer.scheduledTimer(withTimeInterval: Self.retractDelay, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.retractTimer = nil
                        if !self.isNearTab, !self.isInTrigger, !self.view.isDragging { self.retract() }
                    }
                }
            }
            return
        }
        // 按着鼠标（拖窗口、拖文件、选文字）碰到边上不算
        if isInTrigger, NSEvent.pressedMouseButtons == 0 {
            guard dwellTimer == nil else { return }
            dwellTimer = Timer.scheduledTimer(withTimeInterval: Self.dwell, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.dwellTimer = nil
                    if self.armed, self.isInTrigger, NSEvent.pressedMouseButtons == 0 { self.peek() }
                }
            }
        } else {
            dwellTimer?.invalidate(); dwellTimer = nil
        }
    }

    /// 屏幕坐标里的点是否在 screen 的触发区（贴着这一边，菜单栏下面那一段）
    func wouldTrigger(at p: NSPoint, on screen: NSScreen, side: ShelfSide, topInset: CGFloat) -> Bool {
        let f = screen.frame
        let atEdge = side == .right ? p.x >= f.maxX - 2 : p.x <= f.minX + 1
        let top = f.maxY - topInset
        return atEdge && p.y <= top && p.y >= top - Self.triggerBandHeight
    }

    private var isInTrigger: Bool {
        guard let screen else { return false }
        return wouldTrigger(at: NSEvent.mouseLocation, on: screen, side: side, topInset: topInset)
    }

    /// 鼠标在把手上或旁边一点
    private var isNearTab: Bool {
        view.tabScreenRect.insetBy(dx: -24, dy: -24).contains(NSEvent.mouseLocation)
    }

    private func peek() {
        guard !isPeeking else { return }
        isPeeking = true
        retractTimer?.invalidate(); retractTimer = nil
        if !panel.isVisible {
            panel.alphaValue = 1
            view.setSlide(out: false, animated: false)
            panel.orderFrontRegardless()
        }
        view.setSlide(out: true, animated: true)
        // 把手滑到鼠标下面时系统不会发 mouseEntered，自己判断一次
        view.beginHoverIfUnderMouse()
    }

    private func retract() {
        dwellTimer?.invalidate(); dwellTimer = nil
        retractTimer?.invalidate(); retractTimer = nil
        guard isPeeking else { return }
        isPeeking = false
        view.endHover()
        view.setSlide(out: false, animated: true) { [weak self] in
            guard let self, !self.isPeeking else { return }
            self.panel.orderOut(nil)
        }
    }

    func place(on screen: NSScreen, topInset: CGFloat, side: ShelfSide) {
        self.screen = screen
        self.topInset = topInset
        self.side = side
        view.side = side
        // 拖完松手时已经在做贴边动画了，同一个位置不再直接设，否则动画会被打断、一下跳过去
        let f = dockedFrame(side)
        if !view.isDragging, f != dockedTarget {
            dockedTarget = f
            panel.setFrame(f, display: true)
        }
    }

    /// 最近一次让窗口贴到的位置
    private var dockedTarget: NSRect?

    /// 贴边时窗口的位置（屏幕坐标，y 向上）。把手顶部和绳子差不多高
    private func dockedFrame(_ side: ShelfSide) -> NSRect {
        guard let f = screen?.frame else { return .zero }
        let m = Self.shadowMargin, s = Self.tabSize
        let w = s.width + m, h = s.height + 2 * m
        let top = f.maxY - topInset - 4
        let x = side == .right ? f.maxX - w : f.minX
        return NSRect(x: x, y: top - s.height - m, width: w + (side == .right ? 0 : 0), height: h)
    }

    // MARK: 由 HandleView 调用

    func hoverFired() {
        guard trigger == .hover, isPeeking, !view.isDragging else { return }
        onReveal?(true)
    }

    func clicked() {
        guard isPeeking else { return }
        onReveal?(false)
    }

    /// 悬停计时要等多久
    var hoverDelay: TimeInterval { Self.hoverDelay }

    func dragMoved(toScreenX x: CGFloat) {
        guard let f = screen?.frame else { return }
        var frame = panel.frame
        frame.origin.x = min(max(x - frame.width / 2, f.minX), f.maxX - frame.width)
        panel.setFrame(frame, display: true)
    }

    func dragEnded(atScreenX x: CGFloat) {
        guard let f = screen?.frame else { return }
        let newSide: ShelfSide = x > f.midX ? .right : .left
        view.side = newSide
        let target = dockedFrame(newSide)
        dockedTarget = target
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            panel.animator().setFrame(target, display: true)
        }
        if newSide != side {
            side = newSide
            onSideChange?(newSide)
        }
    }
}

private final class HandlePanel: NSPanel {
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // 和截图架一样高（见 ShelfWindow），把手在它上面一层
        level = NSWindow.Level(rawValue: CaptureOverlayWindow.captureLevel.rawValue - 1)
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 画把手：一小截绳子从屏幕边伸出来（微微下垂），挂着两张卡片，右下角的小牌写张数。
/// 没有底板，像截图架收起来时留在边上的一截。拖动时整块跟着走
@MainActor
private final class HandleView: NSView {
    weak var handle: ShelfHandle?
    var side: ShelfSide = .right { didSet { needsLayout = true } }
    var count = 0 {
        didSet {
            label.string = count > 99 ? "99+" : "\(count)"
            needsLayout = true
        }
    }
    /// 挂着的两张（最新的在前）
    var cards: [CGImage] = [] {
        didSet {
            front.image.contents = cards.first
            back.image.contents = cards.count > 1 ? cards[1] : nil
            back.root.isHidden = cards.count < 2
            front.image.backgroundColor = cards.isEmpty ? NSColor(white: 0.9, alpha: 1).cgColor : nil
        }
    }
    private(set) var isDragging = false

    /// 整块（绳子、卡片、小牌）放在这一层里，滑出来、滑回去、拖动都动它
    private let tab = CALayer()
    private let rope = CAShapeLayer()
    private let ropeShadow = CAShapeLayer()
    private let badge = CALayer()
    private let label = CATextLayer()
    private let front = HandleCard()
    private let back = HandleCard()
    private var hoverTimer: Timer?
    private var hovering = false
    private var pressX: CGFloat?
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(tab)
        for l in [ropeShadow, rope] {
            l.fillColor = nil
            l.lineCap = .round
            tab.addSublayer(l)
        }
        // 和截图架的绳子一样
        rope.strokeColor = NSColor(calibratedRed: 0.44, green: 0.44, blue: 0.46, alpha: 0.95).cgColor
        rope.lineWidth = 1.6
        ropeShadow.strokeColor = NSColor(white: 0, alpha: 0.16).cgColor
        ropeShadow.lineWidth = 2.4
        tab.addSublayer(back.root)
        tab.addSublayer(front.root)
        badge.backgroundColor = NSColor(white: 0.17, alpha: 0.92).cgColor
        badge.shadowColor = NSColor.black.cgColor
        badge.shadowOpacity = 0.25
        badge.shadowRadius = 2.5
        badge.shadowOffset = CGSize(width: 0, height: -1)
        badge.borderWidth = 0.5
        badge.borderColor = NSColor(white: 1, alpha: 0.18).cgColor
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .bold)
        label.fontSize = 9.5
        label.foregroundColor = NSColor.white.cgColor
        label.alignmentMode = .center
        badge.addSublayer(label)
        tab.addSublayer(badge)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let s = window?.backingScaleFactor ?? 2
        for l in [tab, rope, ropeShadow, badge, label] { l.contentsScale = s }
        let clip = ClipRenderer.image(scale: s)
        for c in [front, back] { c.setScale(s, clip: clip) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let m = ShelfHandle.shadowMargin, s = ShelfHandle.tabSize
        // 贴右边时把手靠窗口右边，阴影留在左边；贴左边反过来
        let x = side == .right ? bounds.width - s.width : 0
        let inward: CGFloat = side == .right ? 1 : -1
        withoutAnimation {
            // 用 bounds + position 摆放：图层带着滑动的平移，设 frame 会把平移算进去
            tab.bounds = CGRect(origin: .zero, size: s)
            tab.position = CGPoint(x: x + s.width / 2, y: m + s.height / 2)
            if tab.animation(forKey: "slide") == nil {
                tab.transform = CATransform3DMakeTranslation(slidOut ? 0 : hiddenOffset, 0, 0)
            }
            // 图层坐标 y 向上：顶部是 s.height
            let ropeY = s.height - 7
            // 绳子从屏幕边（贴边那一侧，伸出去一点）拉过来，往里一点就结束，中间微微下垂
            let edge = side == .right ? s.width + 2 : -2
            let end = side == .right ? 4.0 : s.width - 4
            let path = CGMutablePath()
            path.move(to: CGPoint(x: end, y: ropeY + 1))
            path.addQuadCurve(to: CGPoint(x: edge, y: ropeY + 2), control: CGPoint(x: s.width / 2, y: ropeY - 4))
            rope.path = path
            var down = CGAffineTransform(translationX: 0, y: -1.4)
            ropeShadow.path = path.copy(using: &down)
            // 两张卡片挂在绳子上，前面那张靠中间，后面那张往里错开一点、转得多一点
            let cx = s.width / 2 + inward * -1
            // 绳子在 cx 处的高度（二次曲线），挂扣套在上面
            func ropeYAt(_ px: CGFloat) -> CGFloat {
                let t = (px - end) / (edge - end)
                let a = (1 - t) * (1 - t), b = 2 * (1 - t) * t, c = t * t
                return a * (ropeY + 1) + b * (ropeY - 4) + c * (ropeY + 2)
            }
            back.place(hangX: cx + inward * -8, ropeY: ropeYAt(cx + inward * -8), size: CGSize(width: 24, height: 30), angle: inward * 0.09)
            front.place(hangX: cx, ropeY: ropeYAt(cx), size: CGSize(width: 28, height: 36), angle: inward * -0.07)
            // 张数的小牌：前面那张卡片的右下角（贴左边时左下角）
            let text = label.string as? String ?? ""
            let w = max(17, CGFloat(text.count) * 6 + 8)
            let bx = side == .right ? cx + 4 : cx - 4 - w
            badge.frame = CGRect(x: bx, y: 3, width: w, height: 14)
            badge.cornerRadius = 7
            label.frame = CGRect(x: 0, y: 1, width: w, height: 12)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    /// 鼠标停在上面：卡片轻轻往外荡一点、影子变深（像被碰了一下）
    private func setHighlighted(_ on: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1))
        for c in [front, back] { c.setLifted(on) }
        CATransaction.commit()
    }

    override func mouseEntered(with event: NSEvent) { beginHover() }

    override func mouseExited(with event: NSEvent) { endHover() }

    private func beginHover() {
        guard !hovering else { return }
        hovering = true
        setHighlighted(true)
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: handle?.hoverDelay ?? 0.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.hovering, self.pressX == nil else { return }
                self.handle?.hoverFired()
            }
        }
    }

    /// 把手滑到鼠标下面时不会收到 mouseEntered，由 ShelfHandle 主动问一下
    func beginHoverIfUnderMouse() {
        if tabScreenRect.contains(NSEvent.mouseLocation) { beginHover() }
    }

    func endHover() {
        hovering = false
        hoverTimer?.invalidate()
        if !isDragging { setHighlighted(false) }
    }

    /// 把手（不含阴影留白）在屏幕上的位置，按滑出来以后的位置算
    var tabScreenRect: NSRect {
        guard let window else { return .zero }
        let m = ShelfHandle.shadowMargin, s = ShelfHandle.tabSize
        let x = side == .right ? bounds.width - s.width : 0
        return window.convertToScreen(NSRect(x: x, y: m, width: s.width, height: s.height))
    }

    /// 把手往屏幕边外面藏多远：整个把手加上阴影
    private var hiddenOffset: CGFloat { (ShelfHandle.tabSize.width + 24) * (side == .right ? 1 : -1) }
    private var slidOut = true

    /// 滑出来（out）或藏到屏幕边外面。窗口不动，只移动里面的把手图层，窗口边缘就是屏幕边缘，藏起来的部分被裁掉。
    /// 动画从当前看到的位置开始，中途反向也不会跳。
    func setSlide(out: Bool, animated: Bool, completion: (() -> Void)? = nil) {
        slidOut = out
        let to = CATransform3DMakeTranslation(out ? 0 : hiddenOffset, 0, 0)
        let from = tab.presentation()?.transform ?? tab.transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated { completion?() }
        }
        tab.removeAnimation(forKey: "slide")
        tab.transform = to
        if animated {
            let a = CABasicAnimation(keyPath: "transform")
            a.fromValue = from
            a.toValue = to
            // 滑出来先快后慢，滑回去先慢后快、更短
            a.duration = out ? 0.22 : 0.16
            a.timingFunction = out ? CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                                   : CAMediaTimingFunction(controlPoints: 0.5, 0, 0.9, 0.5)
            tab.add(a, forKey: "slide")
        }
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        hoverTimer?.invalidate()
        pressX = NSEvent.mouseLocation.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressX else { return }
        let x = NSEvent.mouseLocation.x
        if !isDragging, abs(x - start) > 4 {
            isDragging = true
            needsLayout = true
        }
        if isDragging { handle?.dragMoved(toScreenX: x) }
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressX = nil }
        if isDragging {
            isDragging = false
            needsLayout = true
            handle?.dragEnded(atScreenX: NSEvent.mouseLocation.x)
            setHighlighted(hovering)
        } else {
            handle?.clicked()
        }
    }
}

/// 把手上挂的一张卡片：挂扣（和截图架一样的图）+ 卡片图（圆角、细边、影子）
@MainActor
private final class HandleCard {
    let root = CALayer()
    let image = CALayer()
    private let clip = CALayer()
    private var angle: CGFloat = 0

    init() {
        root.anchorPoint = CGPoint(x: 0.5, y: 1)
        image.masksToBounds = true
        image.contentsGravity = .resizeAspectFill
        image.borderWidth = 0.5
        image.borderColor = NSColor(white: 0, alpha: 0.1).cgColor
        // 影子放在 root 上（image 要裁圆角，影子会被裁掉）
        root.shadowColor = NSColor.black.cgColor
        root.shadowOpacity = 0.24
        root.shadowRadius = 2.5
        root.shadowOffset = CGSize(width: 0, height: -1.5)
        root.addSublayer(clip)
        root.addSublayer(image)
    }

    func setScale(_ s: CGFloat, clip img: CGImage?) {
        for l in [root, image, clip] { l.contentsScale = s }
        clip.contents = img
    }

    /// hangX、ropeY：挂扣套在绳子上的点（父图层坐标，y 向上）。卡片从挂扣往下挂，绕挂点转 angle
    func place(hangX: CGFloat, ropeY: CGFloat, size: CGSize, angle a: CGFloat) {
        angle = a
        // 挂扣图：宽 12、高 24，套环中心离顶 3，卡片顶边离顶 21（和截图架一样，按 0.7 缩）
        let k: CGFloat = 0.7
        let cs = CGSize(width: Metrics.clipSize.width * k, height: Metrics.clipSize.height * k)
        let drop = (Metrics.clipGripY - Metrics.clipRopeY) * k
        let total = CGSize(width: size.width, height: drop + size.height)
        root.bounds = CGRect(origin: .zero, size: total)
        root.position = CGPoint(x: hangX, y: ropeY + Metrics.clipRopeY * k)
        clip.frame = CGRect(x: (size.width - cs.width) / 2, y: total.height - cs.height, width: cs.width, height: cs.height)
        image.frame = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        image.cornerRadius = 4
        image.cornerCurve = .continuous
        root.shadowPath = CGPath(roundedRect: image.frame, cornerWidth: 4, cornerHeight: 4, transform: nil)
        root.transform = CATransform3DMakeRotation(a, 0, 0, 1)
    }

    func setLifted(_ on: Bool) {
        root.transform = CATransform3DMakeRotation(on ? angle * 0.4 : angle, 0, 0, 1)
        root.shadowOpacity = on ? 0.32 : 0.24
        root.shadowRadius = on ? 3.5 : 2.5
    }
}
