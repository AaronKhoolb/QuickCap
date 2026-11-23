import AppKit

/// 截图界面里的条：白色 Liquid Glass、悬停提示、出现和收起的动画。选择条和操作条都用它
@MainActor
class GlassBar: NSView {
    let glass = NSGlassEffectView()
    let stack = NSStackView()
    private var tooltip: BarTooltip?
    private var tooltipPanel: TooltipPanel?
    private var tooltipTimer: Timer?
    private(set) var isShown = false

    static let height: CGFloat = 48
    /// 这根条多高（颜色、粗细的小条矮一点）
    var barHeight: CGFloat { Self.height }

    /// 子类先把按钮放进 stack，再调这个
    func setupGlass() {
        wantsLayer = true
        appearance = NSAppearance(named: .aqua)
        isHidden = true
        layer?.opacity = 0
        glass.style = .regular
        glass.cornerRadius = 17
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 7, bottom: 0, right: 7)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        glass.contentView = content
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.heightAnchor.constraint(equalToConstant: barHeight),
        ])
        glass.cornerRadius = barHeight >= Self.height ? 17 : barHeight / 2
        // 条里所有的按钮（包括装在别的视图里的）都有悬停提示
        func buttons(_ v: NSView) -> [BarButton] { v.subviews.flatMap { ($0 as? BarButton).map { [$0] } ?? buttons($0) } }
        for b in buttons(stack) {
            b.onHover = { [weak self] button, on in self?.hover(button, on) }
        }
    }

    override var fittingSize: NSSize {
        NSSize(width: stack.fittingSize.width.rounded(.up), height: Self.height)
    }

    // MARK: 出现、收起

    /// 弹出来，带一点回弹。anchor 是缩放的中心（0...1，左下为原点），offsetY 是从下面多远弹上来
    func animateIn(anchor: CGPoint = CGPoint(x: 0.5, y: 0.5), scale: CGFloat = 0.96, offsetY: CGFloat = 0) {
        guard !isShown, let layer else { return }
        isShown = true
        isHidden = false
        superview?.layoutSubtreeIfNeeded()
        let fromOpacity = layer.presentation()?.opacity ?? 0
        layer.removeAnimation(forKey: "out")
        layer.removeAnimation(forKey: "outFade")
        // 和截图界面其他动画同一套弹簧：轻轻弹一下就停，120Hz
        let spring = Motion.spring("sublayerTransform",
                                   from: NSValue(caTransform3D: transform(anchor: anchor, scale: scale, dy: -offsetY)),
                                   to: NSValue(caTransform3D: CATransform3DIdentity), duration: 0.38, bounce: 0.18)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fromOpacity
        fade.toValue = 1
        fade.duration = 0.18
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayerTransform = CATransform3DIdentity
        layer.opacity = 1
        CATransaction.commit()
        layer.add(spring, forKey: "in")
        layer.add(fade, forKey: "fade")
    }

    /// 收起来：淡出，稍微缩小、往下一点
    func animateOut(duration: CFTimeInterval = 0.15, offsetY: CGFloat = 8) {
        guard isShown, let layer else { return }
        isShown = false
        hideTooltip()
        let t = transform(anchor: CGPoint(x: 0.5, y: 0.5), scale: 0.98, dy: -offsetY)
        let move = CABasicAnimation(keyPath: "sublayerTransform")
        move.fromValue = NSValue(caTransform3D: layer.presentation()?.sublayerTransform ?? CATransform3DIdentity)
        move.toValue = NSValue(caTransform3D: t)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? 1
        fade.toValue = 0
        for a in [move, fade] {
            a.duration = duration
            a.timingFunction = CAMediaTimingFunction(name: .easeIn)
        }
        layer.removeAnimation(forKey: "in")
        layer.removeAnimation(forKey: "fade")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayerTransform = t
        layer.opacity = 0
        CATransaction.commit()
        layer.add(move, forKey: "out")
        layer.add(fade, forKey: "outFade")
        // 收起后不再接鼠标
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.01) { [weak self] in
            guard let self, !self.isShown else { return }
            self.isHidden = true
        }
    }

    private func transform(anchor: CGPoint, scale: CGFloat, dy: CGFloat) -> CATransform3D {
        let px = bounds.width * anchor.x, py = bounds.height * anchor.y
        var t = CATransform3DMakeTranslation(px, py + dy, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        return CATransform3DTranslate(t, -px, -py, 0)
    }

    // MARK: 悬停提示

    private func hover(_ button: BarButton, _ on: Bool) {
        tooltipTimer?.invalidate()
        guard on, let text = button.tipTitle else { hideTooltip(); return }
        // 已经有提示在显示时（在按钮之间移动），新提示马上出来
        let delay = tooltip == nil ? 0.5 : 0
        tooltipTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.showTooltip(text, key: button.tipKey, sub: button.tipSub, over: button) }
        }
    }

    func showTooltip(_ text: String, key: String?, sub: String?, over button: BarButton) {
        guard let host = superview, let win = window else { return }
        hideTooltip()
        let tip = BarTooltip(title: text, key: key, sub: sub)
        let s = tip.fittingSize
        // 条在自己的小面板里（滚动截图的条）：面板只比条大一圈，提示放不下会被切掉，放进一个单独的小面板，按屏幕摆
        if win is FloatingPanel {
            let r = win.convertToScreen(button.convert(button.bounds, to: nil))
            let bar = win.convertToScreen(convert(bounds, to: nil))
            let vis = (win.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
            var x = (r.midX - s.width / 2).rounded()
            x = min(max(x, vis.minX + 8), vis.maxX - s.width - 8)
            // 优先放在条上面；上面放不下才放下面（下面常常是 Dock）
            var y = (bar.maxY + 8).rounded()
            if y + s.height > vis.maxY - 4 { y = (bar.minY - 8 - s.height).rounded() }
            let panel = TooltipPanel(tip: tip, level: NSWindow.Level(rawValue: win.level.rawValue + 1))
            panel.place(CGRect(x: x, y: y, width: s.width, height: s.height))
            tooltipPanel = panel
            return
        }
        let r = button.convert(button.bounds, to: host)
        var x = (r.midX - s.width / 2).rounded()
        x = min(max(x, 8), host.bounds.width - s.width - 8)
        var y = (frame.maxY + 8).rounded()
        if y + s.height > host.bounds.height - 4 { y = (frame.minY - 8 - s.height).rounded() }
        tip.frame = CGRect(x: x, y: y, width: s.width, height: s.height)
        host.addSubview(tip)
        tooltip = tip
    }

    func hideTooltip() {
        tooltipTimer?.invalidate()
        tooltip?.removeFromSuperview()
        tooltip = nil
        tooltipPanel?.orderOut(nil)
        tooltipPanel = nil
    }
}

/// 装一个悬停提示的小窗口：点得穿，比条那一层高一点，外面留一圈给阴影
@MainActor
final class TooltipPanel: NSPanel {
    private static let margin: CGFloat = 12

    init(tip: BarTooltip, level: NSWindow.Level) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        self.level = level
        let v = NSView()
        contentView = v
        tip.frame = CGRect(x: Self.margin, y: Self.margin, width: tip.fittingSize.width, height: tip.fittingSize.height)
        v.addSubview(tip)
    }

    /// 提示放在屏幕上的 rect（不含留白）
    func place(_ r: CGRect) {
        setFrame(r.insetBy(dx: -Self.margin, dy: -Self.margin), display: true)
        orderFrontRegardless()
    }
}

/// 框选之前的选择条：关闭、四种模式、Options
@MainActor
final class SelectionBar: GlassBar {
    var onMode: ((CaptureMode) -> Void)?
    var onClose: (() -> Void)?
    var onOptions: ((BarButton) -> Void)?

    private var modeButtons: [CaptureMode: BarButton] = [:]
    private(set) var optionsButton: BarButton!
    private var closeButton: BarButton!

    static let modes: [(CaptureMode, String, String, String)] = [
        (.screen, "rectangle.inset.filled", "Capture Entire Screen", "F"),
        (.window, "macwindow", "Capture Window", "W"),
        (.area, "rectangle.dashed", "Capture Area", "A"),
        (.text, "qrcode.viewfinder", "Scan Text & QR Codes", "S"),
    ]

    init(mode: CaptureMode) {
        super.init(frame: .zero)
        let close = BarButton(symbol: "xmark.circle.fill", pointSize: 17, width: 32, tint: .tertiaryLabelColor)
        close.help("Close", key: "Esc")
        close.onClick = { [weak self] _ in self?.onClose?() }
        closeButton = close
        stack.addArrangedSubview(close)
        stack.addArrangedSubview(BarSeparator())
        for (m, symbol, title, key) in Self.modes {
            let b = BarButton(symbol: symbol, pointSize: 16, width: 38)
            b.help(title, key: key)
            b.onClick = { [weak self] _ in self?.onMode?(m) }
            modeButtons[m] = b
            stack.addArrangedSubview(b)
        }
        stack.addArrangedSubview(BarSeparator())
        let opt = BarButton(title: "Options", trailingSymbol: "chevron.down")
        opt.onClick = { [weak self] b in self?.hideTooltip(); self?.onOptions?(b) }
        optionsButton = opt
        stack.addArrangedSubview(opt)
        setupGlass()
        setMode(mode)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 从下方弹上来
    func animateIn() { animateIn(anchor: CGPoint(x: 0.5, y: 0.5), scale: 0.94, offsetY: 18) }

    func setMode(_ mode: CaptureMode) {
        for (m, b) in modeButtons { b.isSelected = m == mode }
    }

    /// 调试用：按钮中心（选择条坐标）。name 是 close、options 或模式名
    func debugCenter(_ name: String) -> CGPoint? {
        let b = name == "close" ? closeButton : name == "options" ? optionsButton
            : CaptureMode(rawValue: name).flatMap { modeButtons[$0] }
        guard let b else { return nil }
        let r = b.convert(b.bounds, to: self)
        return CGPoint(x: r.midX, y: r.midY)
    }
}

/// 框好之后贴在选区旁边的操作条：取消、橙色的 Capture。
/// Capture（和回车）：保存到截图文件夹、挂上截图架（挂上去就是保存好了），设置开着的话同时放进剪贴板。
/// 屏幕上这块有 HDR 内容时按钮写 "Capture in HDR"。⌘C 一定会复制
@MainActor
final class ActionBar: GlassBar {
    enum Output { case save, saveAndCopy }
    /// 截图时（框好选区）；滚动截图拼好以后接着画（review）；从截图架拿下来改（edit：主按钮是 Replace / Save as New）
    enum Kind { case capture, review, edit }
    /// 改截图架上的图：存回原来那张，还是另存一张新的
    enum EditSave: String { case replace, saveAsNew
        var title: String { self == .replace ? "Replace" : "Save as New" }
        static var last: EditSave {
            get { EditSave(rawValue: UserDefaults.standard.string(forKey: "editSave") ?? "") ?? .replace }
            set { UserDefaults.standard.set(newValue.rawValue, forKey: "editSave") }
        }
    }
    let kind: Kind
    /// edit：按了主按钮（存回还是另存）
    var onEditSave: ((EditSave) -> Void)?

    var onCancel: (() -> Void)?
    var onRun: ((Output) -> Void)?
    /// 按钮的字变了，宽度跟着变，要重新摆位置
    var onResize: (() -> Void)?
    /// 点了画画的工具（再点一次同一个：nil，不画了）
    var onTool: ((AnnotationTool?) -> Void)?
    var onUndo: (() -> Void)?
    var onPin: (() -> Void)?
    /// 背景按钮（美化背景）
    var onBeauty: (() -> Void)?
    /// 滚动截图
    var onScroll: (() -> Void)?

    private let settings: AppSettings
    private var cancelButton: BarButton!
    private var primary: PrimaryButton!
    private var toolButtons: [AnnotationTool: BarButton] = [:]
    private var undoButton: BarButton!
    private var pinButton: BarButton!
    private var beautyButton: BarButton!
    private var scrollButton: BarButton!
    private(set) var tool: AnnotationTool?
    private(set) var hdr = false
    /// 按下后先倒数几秒再截（0：马上截）
    private(set) var timer = 0

    init(settings: AppSettings, kind: Kind = .capture) {
        self.settings = settings
        self.kind = kind
        super.init(frame: .zero)
        let cancel = BarButton(symbol: "xmark.circle.fill", pointSize: 17, width: 32, tint: .tertiaryLabelColor)
        cancel.help(kind == .capture ? "Cancel Selection" : kind == .review ? "Discard" : "Cancel", key: "Esc")
        cancel.onClick = { [weak self] _ in self?.onCancel?() }
        cancelButton = cancel
        let p = PrimaryButton(title: kind == .edit ? EditSave.last.title : "Capture")
        p.onClick = { [weak self] _ in
            guard let self else { return }
            if self.kind == .edit { self.onEditSave?(EditSave.last) } else { self.onRun?(self.primaryOutput) }
        }
        primary = p
        stack.addArrangedSubview(cancel)
        stack.addArrangedSubview(BarSeparator())
        // 画画的工具：框好就能直接画
        for t in AnnotationTool.allCases {
            // 和选择条上的图标一样大（16pt），线一样粗
            let b = BarButton(symbol: t.symbol, pointSize: 16, width: 36)
            b.help(t.title, key: CaptureSession.toolKeys.first { $0.value == t }?.key.uppercased())
            b.onClick = { [weak self] _ in
                guard let self else { return }
                self.onTool?(self.tool == t ? nil : t)
            }
            toolButtons[t] = b
            stack.addArrangedSubview(b)
        }
        stack.addArrangedSubview(BarSeparator())
        let beauty = BarButton(symbol: "photo.artframe", pointSize: 16, width: 36)
        beauty.help("Background", key: "G", sub: "Padding, shadow and a backdrop")
        beauty.onClick = { [weak self] _ in self?.onBeauty?() }
        beautyButton = beauty
        stack.addArrangedSubview(beauty)
        let scroll = BarButton(symbol: "rectangle.expand.vertical", pointSize: 16, width: 36)
        scroll.help("Scrolling Capture", key: "S", sub: "Scroll the content yourself; it stitches as you go")
        scroll.onClick = { [weak self] _ in self?.onScroll?() }
        scrollButton = scroll
        if kind == .capture { stack.addArrangedSubview(scroll) }
        let undo = BarButton(symbol: "arrow.uturn.backward", pointSize: 16, width: 36)
        undo.help("Undo", key: "⌘Z")
        undo.onClick = { [weak self] _ in self?.onUndo?() }
        undoButton = undo
        stack.addArrangedSubview(undo)
        let pin = BarButton(symbol: "pin", pointSize: 16, width: 36)
        pin.help("Pin to Desktop", key: nil, sub: "Float the capture above all windows")
        pin.onClick = { [weak self] _ in self?.onPin?() }
        pinButton = pin
        if kind != .edit { stack.addArrangedSubview(pin) }
        stack.setCustomSpacing(6, after: kind != .edit ? pin : undo)
        stack.addArrangedSubview(p)
        // 改图时主按钮旁边一个小箭头：Replace / Save as New 换着用（记住上次选的）
        if kind == .edit {
            let more = BarButton(symbol: "chevron.down", pointSize: 10, width: 22)
            more.help("Replace or Save as New", key: nil)
            more.onClick = { [weak self] b in self?.showEditMenu(from: b) }
            stack.setCustomSpacing(2, after: p)
            stack.addArrangedSubview(more)
        }
        setupGlass()
        setCanUndo(false)
        refresh()
    }

    /// 回车：和点主按钮一样（主按钮按下去的那一下也有）
    func performPrimary() {
        if kind == .edit { onEditSave?(EditSave.last) } else { onRun?(primaryOutput) }
    }

    /// 现在选的工具（按钮变灰底）
    func setTool(_ t: AnnotationTool?) {
        tool = t
        for (k, b) in toolButtons { b.isSelected = k == t }
    }

    func setBeauty(_ on: Bool) { beautyButton.isSelected = on }
    var beautyButtonFrame: CGRect { beautyButton.convert(beautyButton.bounds, to: self) }

    func setCanUndo(_ on: Bool) {
        undoButton.alphaValue = on ? 1 : 0.35
    }

    /// 某个工具按钮在条上的位置（颜色小条对着它出来）
    func toolButtonFrame(_ t: AnnotationTool) -> CGRect? {
        guard let b = toolButtons[t] else { return nil }
        return b.convert(b.bounds, to: self)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Capture（和回车）这次做什么
    var primaryOutput: Output { settings.captureCopy ? .saveAndCopy : .save }

    func setHDR(_ on: Bool) {
        guard on != hdr else { return }
        hdr = on
        refresh()
        onResize?()
    }

    func setTimer(_ s: Int) {
        guard s != timer else { return }
        timer = s
        refresh()
        onResize?()
    }

    /// Capture 按钮现在在屏幕上的右边和竖着的中线（倒数条从这里出来）
    var primaryAnchor: (rightX: CGFloat, midY: CGFloat)? {
        guard let w = window else { return nil }
        let r = w.convertToScreen(convert(bounds, to: nil))
        return (r.maxX, r.midY)
    }

    private func showEditMenu(from b: BarButton) {
        let m = NSMenu()
        for e in [EditSave.replace, .saveAsNew] {
            let i = ClosureMenuItem(e == .replace ? "Replace Original" : "Save as New") { [weak self] in
                EditSave.last = e
                self?.refresh()
                self?.onResize?()
            }
            i.state = EditSave.last == e ? .on : .off
            m.addItem(i)
        }
        m.popUp(positioning: nil, at: CGPoint(x: 0, y: -4), in: b)
    }

    func refresh() {
        if kind == .edit {
            primary.setTitle(EditSave.last.title)
            primary.help(EditSave.last == .replace ? "Save over the original" : "Save a new copy; the original stays", key: "↩")
            needsLayout = true
            return
        }
        primary.setTitle("Capture", suffix: hdr ? "in HDR" : nil, timer: timer)
        let what = primaryOutput == .saveAndCopy ? "Save and Copy" : "Save"
        primary.help(what, key: "↩", sub: hdr ? "Saved in HDR. Copies and drags are normal PNG." : primaryOutput == .save ? "⌘C to also copy" : nil)
        needsLayout = true
    }

    /// 从选区那个角放大出来
    func animateIn(fromTopRight: Bool) {
        animateIn(anchor: CGPoint(x: 1, y: fromTopRight ? 1 : 0), scale: 0.9, offsetY: fromTopRight ? -8 : 8)
    }

    // 调试用
    var debugText: String { "primary=\"\(primary.title ?? "")\" output=\(primaryOutput) hdr=\(hdr) timer=\(timer) tool=\(tool?.rawValue ?? "none")" }

    func debugCenter(_ name: String) -> CGPoint? {
        let b: BarButton? = name == "cancel" ? cancelButton : name == "primary" ? primary : name == "undo" ? undoButton : name == "pin" ? pinButton : name == "beauty" ? beautyButton : name == "scroll" ? scrollButton
            : AnnotationTool(rawValue: name).flatMap { toolButtons[$0] }
        guard let b, !b.isHidden else { return nil }
        let r = b.convert(b.bounds, to: self)
        return CGPoint(x: r.midX, y: r.midY)
    }
}

/// 条上的一个按钮：只有图标，或者文字（可以带小箭头）。
/// 悬停时浅灰底，按下深一点，选中时灰底。
@MainActor
class BarButton: NSView {
    var onClick: ((BarButton) -> Void)?
    var onHover: ((BarButton, Bool) -> Void)?
    private(set) var tipTitle: String?
    private(set) var tipKey: String?
    private(set) var tipSub: String?
    private(set) var label: NSTextField?

    var isSelected = false { didSet { refresh() } }
    private(set) var hovered = false { didSet { refresh() } }
    private(set) var pressed = false { didSet { refresh() } }
    private let fixedWidth: CGFloat?
    private let fixedHeight: CGFloat
    private var symbolPointSize: CGFloat = 16

    /// 换图标（开、关两种样子的按钮），交叉淡一下
    func setSymbol(_ name: String) {
        guard let iv = subviews.compactMap({ $0 as? NSImageView }).first else { return }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: symbolPointSize, weight: .regular))
        let t = CATransition()
        t.type = .fade
        t.duration = 0.15
        iv.layer?.add(t, forKey: "swap")
        iv.image = img
    }

    static let height: CGFloat = 34
    var title: String? { label?.stringValue }

    init(symbol: String, pointSize: CGFloat, width: CGFloat, tint: NSColor = NSColor(white: 0, alpha: 0.8)) {
        fixedWidth = width
        fixedHeight = Self.height
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: Self.height))
        setup()
        let iv = Self.symbolView(symbol, pointSize: pointSize, weight: .regular, tint: tint)
        symbolPointSize = pointSize
        addSubview(iv)
        NSLayoutConstraint.activate([iv.centerXAnchor.constraint(equalTo: centerXAnchor),
                                     iv.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }

    init(title: String, trailingSymbol: String?, padding: CGFloat = 10) {
        fixedWidth = nil
        fixedHeight = Self.height
        super.init(frame: .zero)
        setup()
        let l = NSTextField(labelWithString: title)
        l.font = .systemFont(ofSize: 13, weight: .medium)
        l.textColor = NSColor(white: 0, alpha: 0.82)
        label = l
        var views: [NSView] = [l]
        var chev: NSImageView?
        if let trailingSymbol {
            let c = Self.symbolView(trailingSymbol, pointSize: 8, weight: .bold, tint: NSColor(white: 0, alpha: 0.42))
            views.append(c)
            chev = c
        }
        let row = NSStackView(views: views)
        row.spacing = 5
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        if let chev { chev.centerYAnchor.constraint(equalTo: l.centerYAnchor, constant: 1).isActive = true }
    }

    /// 里面放任意的东西（扫描结果条上可以点的文字）。悬停时整块浅灰底
    init(content: NSView, height: CGFloat, padding: NSEdgeInsets, corner: CGFloat = 7) {
        fixedWidth = nil
        fixedHeight = height
        super.init(frame: .zero)
        setup()
        layer?.cornerRadius = corner
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding.left),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding.right),
            content.centerYAnchor.constraint(equalTo: centerYAnchor, constant: (padding.bottom - padding.top) / 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: fixedHeight).isActive = true
        if let fixedWidth { widthAnchor.constraint(equalToConstant: fixedWidth).isActive = true }
    }

    static func symbolView(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, tint: NSColor) -> NSImageView {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))
        let iv = NSImageView(image: img ?? NSImage())
        iv.contentTintColor = tint
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }

    func help(_ title: String, key: String?, sub: String? = nil) {
        tipTitle = title
        tipKey = key
        tipSub = sub
        setAccessibilityLabel(title)
    }

    func refresh() {
        let a: CGFloat = pressed ? 0.11 : isSelected ? 0.09 : hovered ? 0.055 : 0
        layer?.backgroundColor = NSColor(white: 0, alpha: a).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; onHover?(self, true) }
    override func mouseExited(with event: NSEvent) { hovered = false; pressed = false; onHover?(self, false) }
    override func mouseDown(with event: NSEvent) { pressed = true; onHover?(self, false) }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { onClick?(self) }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityPerformPress() -> Bool { onClick?(self); return true }
}

/// 橙色主按钮
@MainActor
final class PrimaryButton: BarButton {
    init(title: String) {
        super.init(title: title, trailingSymbol: nil, padding: 16)
        label?.font = .systemFont(ofSize: 13, weight: .semibold)
        label?.textColor = .white
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.shadowOpacity = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    /// "Capture in HDR"：后半截字细一点、淡一点，和系统截图工具一样
    /// timer：计时几秒（系统截图也是这样写在按钮上：Capture in HDR ⏱ 5s）
    func setTitle(_ t: String, suffix: String? = nil, timer: Int? = nil) {
        let s = NSMutableAttributedString(string: t, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                                                  .foregroundColor: NSColor.white])
        let light: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .regular),
                                                    .foregroundColor: NSColor(white: 1, alpha: 0.82)]
        if let suffix { s.append(NSAttributedString(string: " " + suffix, attributes: light)) }
        if let timer, timer > 0 {
            let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(white: 1, alpha: 0.82)]))
            if let img = NSImage(systemSymbolName: "timer", accessibilityDescription: "Timer")?.withSymbolConfiguration(cfg) {
                let a = NSTextAttachment()
                a.image = img
                a.bounds = CGRect(x: 0, y: -2, width: img.size.width, height: img.size.height)
                s.append(NSAttributedString(string: "  ", attributes: light))
                s.append(NSAttributedString(attachment: a))
            }
            s.append(NSAttributedString(string: " \(timer)s", attributes: light))
        }
        label?.attributedStringValue = s
        invalidateIntrinsicContentSize()
    }

    override func refresh() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
        let k: CGFloat = pressed ? 0.93 : hovered ? 1.04 : 1
        func c(_ red: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
            NSColor(calibratedRed: min(red * k, 1), green: min(g * k, 1), blue: min(b * k, 1), alpha: 1)
        }
        NSGradient(starting: c(1, 0.64, 0.12), ending: c(1, 0.56, 0))?.draw(in: path, angle: -90)
        NSColor(calibratedRed: 0.84, green: 0.43, blue: 0, alpha: 0.5).setStroke()
        let edge = NSBezierPath(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), xRadius: 9.75, yRadius: 9.75)
        edge.lineWidth = 0.5
        edge.stroke()
        NSColor(white: 1, alpha: 0.45).setFill()
        CGRect(x: 6, y: r.maxY - 0.5, width: r.width - 12, height: 0.5).fill()
    }
}

@MainActor
final class BarSeparator: NSView {
    init(height: CGFloat = 20) {
        super.init(frame: CGRect(x: 0, y: 0, width: 13, height: height))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 13).isActive = true
        heightAnchor.constraint(equalToConstant: height).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.1).setFill()
        CGRect(x: 6, y: 0, width: 1, height: bounds.height).fill()
    }
}

/// 条上方的白色小提示："Capture Area  A"，可以再带一行灰色小字
@MainActor
final class BarTooltip: NSView {
    private let text: NSAttributedString
    private let subText: NSAttributedString?

    init(title: String, key: String?, sub: String? = nil) {
        let s = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: NSColor(white: 0, alpha: 0.85)])
        if let key {
            s.append(NSAttributedString(string: "  " + key, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor(white: 0, alpha: 0.42)]))
        }
        text = s
        subText = sub.map { NSAttributedString(string: $0, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 0, alpha: 0.45)]) }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.14
        layer?.shadowRadius = 7
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize {
        let w = max(text.size().width, subText?.size().width ?? 0)
        return NSSize(width: (w + 16).rounded(.up), height: subText == nil ? 24 : 38)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        NSColor(white: 1, alpha: 0.97).setFill()
        path.fill()
        NSColor(white: 0, alpha: 0.12).setStroke()
        path.lineWidth = 0.5
        path.stroke()
        if let subText {
            let a = text.size(), b = subText.size()
            text.draw(at: CGPoint(x: ((bounds.width - a.width) / 2).rounded(), y: 19))
            subText.draw(at: CGPoint(x: ((bounds.width - b.width) / 2).rounded(), y: 5))
            _ = b
        } else {
            let s = text.size()
            text.draw(at: CGPoint(x: 8, y: ((bounds.height - s.height) / 2).rounded()))
        }
    }
}

/// 选了画画的工具后，操作条旁边多出来的一根小条：颜色和粗细。
/// 文字工具的粗细写成 S、M、L（字的大小）
@MainActor
final class AnnotationStyleBar: GlassBar {
    var onColor: ((Int) -> Void)?
    var onWidth: ((Int) -> Void)?
    private var swatches: [ColorSwatch] = []
    private var widthButtons: [BarButton] = []
    private let colorRow = NSStackView()

    override var barHeight: CGFloat { 36 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        colorRow.orientation = .horizontal
        colorRow.spacing = 2
        for (i, c) in AnnotationStyle.colors.enumerated() {
            let s = ColorSwatch(color: c)
            s.onClick = { [weak self] in self?.onColor?(i) }
            swatches.append(s)
            colorRow.addArrangedSubview(s)
        }
        stack.addArrangedSubview(colorRow)
        stack.addArrangedSubview(BarSeparator(height: 16))
        for i in AnnotationStyle.widths.indices {
            let b = BarButton(content: NSView(), height: 26, padding: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0), corner: 13)
            b.widthAnchor.constraint(equalToConstant: 30).isActive = true
            b.onClick = { [weak self] _ in self?.onWidth?(i) }
            widthButtons.append(b)
            stack.addArrangedSubview(b)
        }
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 5)
        setupGlass()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 换了工具、颜色、粗细
    func show(tool: AnnotationTool, color: Int, width: Int) {
        colorRow.isHidden = !tool.usesColor
        for (i, s) in swatches.enumerated() { s.isSelected = i == color }
        for (i, b) in widthButtons.enumerated() {
            b.isSelected = i == width
            b.subviews.forEach { $0.removeFromSuperview() }
            let icon = tool == .text ? Self.letter(i) : tool == .counter ? Self.dot(i) : Self.line(i)
            icon.translatesAutoresizingMaskIntoConstraints = false
            b.addSubview(icon)
            NSLayoutConstraint.activate([icon.centerXAnchor.constraint(equalTo: b.centerXAnchor),
                                         icon.centerYAnchor.constraint(equalTo: b.centerYAnchor)])
        }
        needsLayout = true
    }

    /// 粗细：一小段横线
    private static func line(_ i: Int) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let h = [1.5, 3, 5][i]
        v.layer?.backgroundColor = NSColor(white: 0, alpha: 0.72).cgColor
        v.layer?.cornerRadius = h / 2
        v.widthAnchor.constraint(equalToConstant: 14).isActive = true
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }

    /// 编号：大中小三个圆
    private static func dot(_ i: Int) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let d: CGFloat = [7, 10, 13][i]
        v.layer?.backgroundColor = NSColor(white: 0, alpha: 0.72).cgColor
        v.layer?.cornerRadius = d / 2
        v.widthAnchor.constraint(equalToConstant: d).isActive = true
        v.heightAnchor.constraint(equalToConstant: d).isActive = true
        return v
    }

    /// 文字：大中小三个 A
    private static func letter(_ i: Int) -> NSView {
        let l = NSTextField(labelWithString: "A")
        l.font = .systemFont(ofSize: [10, 13, 16][i], weight: .semibold)
        l.textColor = NSColor(white: 0, alpha: 0.75)
        return l
    }

    func animateIn(below: Bool) {
        animateIn(anchor: CGPoint(x: 0.5, y: below ? 1 : 0), scale: 0.94, offsetY: below ? -4 : 4)
    }
}

/// 一个颜色圆点。选中时外面一圈白、再一圈深色的环
@MainActor
final class ColorSwatch: NSView {
    var onClick: (() -> Void)?
    let color: NSColor
    var isSelected = false { didSet { needsDisplay = true } }
    private var hovered = false { didSet { needsDisplay = true } }

    init(color: NSColor) {
        self.color = color
        super.init(frame: CGRect(x: 0, y: 0, width: 24, height: 26))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let r: CGFloat = isSelected ? 6.5 : hovered ? 7.5 : 7
        if isSelected {
            NSColor(white: 0, alpha: 0.78).setStroke()
            let ring = NSBezierPath(ovalIn: CGRect(x: c.x - 9.5, y: c.y - 9.5, width: 19, height: 19))
            ring.lineWidth = 1.5
            ring.stroke()
        }
        color.setFill()
        NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
        // 白色和很浅的颜色加一圈细边，在白玻璃上看得见
        NSColor(white: 0, alpha: 0.16).setStroke()
        let edge = NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2).insetBy(dx: 0.25, dy: 0.25))
        edge.lineWidth = 0.5
        edge.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
}
