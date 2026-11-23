import AppKit

/// 按下 Capture 之后，截好的图从选区里"拿起来"飞向截图架：
/// 1. 一开始和选区一模一样大、一样的位置（看不出换了东西），闪一下白
/// 2. 稍微浮起来（放大一点点、阴影变深），同时缩到差不多卡片大小，朝截图架那边挪一点，圆角变成卡片的圆角
/// 3. 截图架打开、文件写好后，同样位置、同样大小、同样圆角的卡片接手，飞到绳子上挂好；这张图在同一刻消失
///
/// 图层都只动位置、大小、圆角、不透明度，显卡直接算。截图界面在这张图下面淡出
@MainActor
final class CaptureFlight {
    private let panel: NSPanel
    private let card = CALayer()
    private let image = CALayer()
    private let flash = CALayer()
    private let screen: NSScreen
    /// 停下来等截图架接手时的位置和大小（屏幕坐标）
    private(set) var holdRect: CGRect = .zero
    /// 停下来时是卡片的几倍大（截图架的卡片按这个倍数开始飞）
    private(set) var holdScale: CGFloat = 1
    private var heldAt = Date.distantFuture
    private var finished = false

    /// 和截图架卡片一样：圆角、底色、描边
    static let cardCorner = Metrics.cardCorner
    static let cardBackground = NSColor(white: 0.90, alpha: 1)

    /// image：截好的图（有 HDR 的话给 HDR 版，显示时和截图界面一样亮）。
    /// rect：选区在屏幕上的位置（pt）。corner：窗口截图的圆角（框选是 0）
    init(image img: CGImage, hdr: CGImage?, rect: CGRect, corner: CGFloat, screen: NSScreen) {
        self.screen = screen
        panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: CaptureOverlayWindow.captureLevel.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        let v = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        v.wantsLayer = true
        panel.contentView = v
        let root = v.layer!
        let scale = screen.backingScaleFactor

        let local = rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        for l in [card, image, flash] { l.contentsScale = scale }
        card.frame = local
        card.cornerRadius = corner
        card.cornerCurve = .continuous
        card.shadowColor = NSColor.black.cgColor
        card.shadowOpacity = 0
        card.shadowRadius = 6
        card.shadowOffset = CGSize(width: 0, height: -3)
        image.frame = CGRect(origin: .zero, size: local.size)
        image.contents = hdr ?? img
        if hdr != nil { image.preferredDynamicRange = .high }
        image.contentsGravity = .resizeAspectFill
        image.masksToBounds = true
        image.cornerRadius = corner
        image.cornerCurve = .continuous
        image.minificationFilter = .trilinear
        flash.frame = image.bounds
        flash.backgroundColor = NSColor.white.cgColor
        flash.opacity = 0
        image.addSublayer(flash)
        card.addSublayer(image)
        root.addSublayer(card)
        holdRect = rect
        panel.orderFrontRegardless()
    }

    /// 拿起来、缩小、朝 target（截图架挂绳那边，屏幕坐标）挪一点。pixelSize：截图的像素大小（算卡片大小）
    func lift(toward target: CGPoint?, pixelSize: CGSize) {
        let f = screen.frame
        let start = card.frame
        let cardSize = Metrics.cardSize(for: pixelSize)
        // 停下来时比卡片稍大一点（还在"拿着"的感觉），但不会比选区还大
        holdScale = max(1, min(1.3, start.width / cardSize.width, start.height / cardSize.height))
        let hold = CGSize(width: cardSize.width * holdScale, height: cardSize.height * holdScale)
        var c = CGPoint(x: start.midX, y: start.midY)
        if let t = target {
            let tl = CGPoint(x: t.x - f.minX, y: t.y - f.minY)
            c.x += (tl.x - c.x) * 0.2
            c.y += (tl.y - c.y) * 0.2
        }
        c.y += 14 // 往上浮一点
        // 整张都留在屏幕里（菜单栏下面）
        let vis = screen.visibleFrame.offsetBy(dx: -f.minX, dy: -f.minY).insetBy(dx: 16, dy: 16)
        c.x = min(max(c.x, vis.minX + hold.width / 2), vis.maxX - hold.width / 2)
        c.y = min(max(c.y, vis.minY + hold.height / 2), vis.maxY - hold.height / 2)
        let end = CGRect(x: c.x - hold.width / 2, y: c.y - hold.height / 2, width: hold.width, height: hold.height)
        holdRect = end.offsetBy(dx: f.minX, dy: f.minY)
        let corner = Self.cardCorner * holdScale

        // 闪一下白
        let fl = CABasicAnimation(keyPath: "opacity")
        fl.fromValue = 0.75
        fl.toValue = 0
        fl.duration = 0.36
        fl.timingFunction = CAMediaTimingFunction(name: .easeOut)
        flash.add(fl, forKey: "flash")
        // 浮起来：先放大一点点再回到 1（和缩小同时进行，看起来是"拿起来"）
        let lift = CAKeyframeAnimation(keyPath: "transform.scale")
        lift.values = [1, 1.035, 1]
        lift.keyTimes = [0, 0.3, 1]
        lift.duration = 0.4
        lift.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        card.add(lift, forKey: "lift")
        // 阴影：拿起来时深、散；停下来时和卡片的阴影一样（按大小放大）
        let k = holdScale
        let restOpacity: Float = 0.2, restRadius = 6 * k, restOffset = CGSize(width: 0, height: -3 * k)
        let so = CAKeyframeAnimation(keyPath: "shadowOpacity")
        so.values = [0, 0.34, restOpacity]
        let sr = CAKeyframeAnimation(keyPath: "shadowRadius")
        sr.values = [6, 16, restRadius]
        let sf = CAKeyframeAnimation(keyPath: "shadowOffset")
        sf.values = [NSValue(size: CGSize(width: 0, height: -3)), NSValue(size: CGSize(width: 0, height: -9)), NSValue(size: restOffset)]
        for a in [so, sr, sf] {
            a.keyTimes = [0, 0.3, 1]
            a.duration = 0.42
            a.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            card.add(a, forKey: a.keyPath)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.shadowOpacity = restOpacity
        card.shadowRadius = restRadius
        card.shadowOffset = restOffset
        // 透明的窗口圆角外面慢慢变成卡片的底色（截图架卡片也是这个底色）
        image.backgroundColor = Self.cardBackground.cgColor
        CATransaction.commit()
        let bg = CABasicAnimation(keyPath: "backgroundColor")
        bg.fromValue = NSColor.clear.cgColor
        bg.toValue = Self.cardBackground.cgColor
        bg.duration = 0.3
        image.add(bg, forKey: "bg")
        // 缩小、挪过去、圆角变成卡片的
        Motion.move(card, frame: end, corner: corner, animated: true, duration: 0.34, bounce: 0.06)
        Motion.move(image, frame: CGRect(origin: .zero, size: end.size), corner: corner, animated: true, duration: 0.34, bounce: 0.06)
        Motion.move(flash, frame: CGRect(origin: .zero, size: end.size), corner: 0, animated: true, duration: 0.34, bounce: 0.06)
        heldAt = Date().addingTimeInterval(0.34)
    }

    /// 停稳了（等这么久再交给截图架，接手时两样一模一样）
    var secondsUntilHeld: TimeInterval { max(0, heldAt.timeIntervalSinceNow) }

    /// 截图架的卡片已经在同一个位置出来了：这张图消失。隔两帧再拿走，中间不会空一下
    func handedOff() {
        guard !finished else { return }
        finished = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.034) { [panel, card] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            card.opacity = 0
            CATransaction.commit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { panel.orderOut(nil) }
        }
    }

    /// 出错（没存上）：淡掉
    func cancel() {
        guard !finished else { return }
        finished = true
        Motion.fade(card, to: 0, duration: 0.18)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [panel] in panel.orderOut(nil) }
    }
}
