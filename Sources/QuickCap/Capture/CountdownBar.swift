import AppKit

/// 计时截图的倒数条，照系统截图的样子：一根小玻璃条，左边灰底的 Cancel，右边 ⏱ 3s。
/// 放在单独一个小面板里：倒数时截图界面点穿（可以去打开菜单、悬停出提示），只有这根条能点
@MainActor
final class CountdownBar: GlassBar {
    var onCancel: (() -> Void)?
    private let cancel = CancelPill()
    private let timerIcon = BarButton.symbolView("timer", pointSize: 13, weight: .regular, tint: NSColor(white: 0, alpha: 0.5))
    private let seconds = NSTextField(labelWithString: "")
    private(set) var value = 0

    init() {
        super.init(frame: .zero)
        cancel.onClick = { [weak self] _ in self?.onCancel?() }
        cancel.help("Cancel Timer", key: "Esc")
        seconds.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        seconds.textColor = NSColor(white: 0, alpha: 0.5)
        seconds.wantsLayer = true
        let right = NSStackView(views: [timerIcon, seconds])
        right.spacing = 5
        right.alignment = .centerY
        right.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 12)
        for v in [cancel, right] { stack.addArrangedSubview(v) }
        setupGlass()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 换数字：旧的往上淡出、新的从下面淡入（和系统计时一样，不是一下跳）
    func setSeconds(_ n: Int, animated: Bool) {
        value = n
        if animated, let l = seconds.layer {
            let t = CATransition()
            t.type = .push
            t.subtype = .fromBottom
            t.duration = 0.22
            t.timingFunction = CAMediaTimingFunction(name: .easeOut)
            l.add(t, forKey: "tick")
        }
        seconds.stringValue = "\(n)s"
    }

    func debugCenter(_ name: String) -> CGPoint? {
        guard name == "cancel" else { return nil }
        let r = cancel.convert(cancel.bounds, to: self)
        return CGPoint(x: r.midX, y: r.midY)
    }
}

/// 灰底的 Cancel（系统计时条上那种），悬停、按下时深一点
@MainActor
private final class CancelPill: BarButton {
    init() {
        super.init(title: "Cancel", trailingSymbol: nil, padding: 16)
        label?.textColor = NSColor(white: 0, alpha: 0.62)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func refresh() {
        let a: CGFloat = pressed ? 0.16 : hovered ? 0.12 : 0.08
        layer?.backgroundColor = NSColor(white: 0, alpha: a).cgColor
    }
}

/// 放倒数条的小面板：在截图界面上面一层、能点；不抢焦点
@MainActor
final class CountdownPanel: NSPanel {
    let bar = CountdownBar()
    /// 条外面留一圈给阴影
    static let margin: CGFloat = 24

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        level = NSWindow.Level(rawValue: CaptureOverlayWindow.captureLevel.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        animationBehavior = .none
        isReleasedWhenClosed = false
        let v = NSView()
        v.wantsLayer = true
        contentView = v
        bar.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(bar)
        let m = Self.margin
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: m),
            bar.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -m),
            bar.topAnchor.constraint(equalTo: v.topAnchor, constant: m),
            bar.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -m),
        ])
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 条的右边对着 rightX、竖着的中线对着 midY（屏幕坐标）。屏幕放不下就往里收
    func show(rightX: CGFloat, midY: CGFloat, seconds: Int, on screen: NSScreen) {
        bar.setSeconds(seconds, animated: false)
        let size = bar.fittingSize
        let m = Self.margin
        var f = CGRect(x: rightX - size.width - m, y: midY - size.height / 2 - m, width: size.width + 2 * m, height: size.height + 2 * m)
        let vis = screen.visibleFrame.insetBy(dx: 8 - m, dy: 8 - m)
        f.origin.x = min(max(f.minX, vis.minX), vis.maxX - f.width)
        f.origin.y = min(max(f.minY, vis.minY), vis.maxY - f.height)
        setFrame(f, display: true)
        orderFrontRegardless()
        // 从右边（原来 Capture 按钮的位置）稍微放大出来
        bar.animateIn(anchor: CGPoint(x: 1, y: 0.5), scale: 0.86, offsetY: 0)
    }

    func dismiss(animated: Bool) {
        bar.animateOut(duration: animated ? 0.12 : 0, offsetY: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + (animated ? 0.13 : 0)) { [weak self] in self?.orderOut(nil) }
    }
}
