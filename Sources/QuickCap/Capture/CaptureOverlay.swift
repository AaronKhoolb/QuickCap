import AppKit

/// 盖住一整块屏幕的窗口，显示冻结下来的画面。比菜单栏和悬挂架都高。
/// 用不激活 app 的面板（和聚焦搜索一样），不抢别的 app 的焦点也能拿到键盘。
final class CaptureOverlayWindow: NSPanel {
    let overlayView: CaptureOverlayView

    @MainActor
    init(screen: NSScreen, frozen: CGImage, session: CaptureSession) {
        overlayView = CaptureOverlayView(screen: screen, frozen: frozen, session: session)
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        level = Self.captureLevel
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        // 不加 .stationary：Mission Control 时截图界面要跟着让开，不能盖在上面挡住点击
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        appearance = NSAppearance(named: .aqua)
        contentView = overlayView
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 截图界面的层级：和系统截图（screencapture 的全屏窗口）一样，放在辅助功能最高层下面两层。
    /// 有的 app 把自己的浮窗放得很高（荣耀超级工作台是 1000），截图界面低了就会被它盖住、点击被它拿走。
    /// 辅助功能的光标、放大镜这些在更高一层，不会被挡
    static let captureLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)) - 2)
}

/// 只用来放自己画的图层，不接鼠标（点击交给下面的截图界面）
final class CanvasView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 一块屏幕上的截图界面：冻结的画面，选区外的遮罩、虚线框、8 个手柄、吸附线、尺寸标签，
/// 窗口模式下鼠标所在窗口的高亮。选择条只装在鼠标所在的那块屏幕上。坐标原点在左下角，单位 pt。
@MainActor
final class CaptureOverlayView: NSView {
    enum Kind: Equatable { case area, window, screen }

    private weak var session: CaptureSession?
    /// 自己画的图层都放在这里，保证在选择条和尺寸标签下面
    let canvas = CanvasView()
    private let imageLayer = CALayer()
    /// 窗口模式的高亮：spotlight 是一圈很粗的半透明黑边（中间留出窗口那块是亮的），ring 是窗口外面一圈橙线。
    /// 两样都只动位置、大小、圆角、边宽，显卡直接算，不用每一帧重画形状，换窗口时才顺
    private let spotlight = CALayer()
    private let ring = CALayer()
    private var halo: CaptureHalo!
    /// 打开截图界面的时间：刚打开时高亮、标签晚一点出来（先暗下来、选择条升起，再出高亮）
    private let openedAt = Date()
    private var opening: Bool { Date().timeIntervalSince(openedAt) < 0.3 }
    private let dim = CAShapeLayer()
    private let outlineDark = CAShapeLayer()
    private let outlineLight = CAShapeLayer()
    private var guide: GuideGlow!
    private(set) var handleLayers: [CALayer] = []
    private(set) var bar: SelectionBar?
    private weak var actionBar: ActionBar?
    let badge = SelectionBadge()
    /// 冻结的画面（原始像素，不带鼠标指针）：界面上显示、识别文字、放大镜都用它
    private(set) var frozen: CGImage
    /// 带鼠标指针的那张（设置里开了显示鼠标指针才有），出图时用
    private(set) var output: CGImage?
    /// HDR 的那张（设置开了 HDR、屏幕能显示 HDR 才有）
    private(set) var frozenHDR: CGImage?
    /// 带鼠标指针那张的 HDR 版本
    private(set) var outputHDR: CGImage?

    /// 不冻结：覆盖窗口透明，看到的是实时的屏幕
    private(set) var isLive = false
    /// 不冻结时，还没截这一刻
    private(set) var snapshotStale = false
    private let loupe = LoupeView()
    /// 正在倒数：截图界面整个让开（不暗、不显示框），屏幕照常能用
    private(set) var counting = false
    /// 调试用：倒数还剩几秒（session 告诉它）
    var debugCountdown = 0
    /// 选中的窗口（单独截它）
    private(set) var selectedWindow: ScreenWindow?
    var selectedWindowID: CGWindowID? { selectedWindow?.id }
    /// 操作条放在选区下面（true）还是上面
    private(set) var actionBarBelow = true

    /// 打开截图时这块屏幕上的窗口（画面冻结了，窗口位置也不会变）
    private(set) var windows: [ScreenWindow]
    private var snaps: SnapLines { didSet { mergeSnapLines() } }
    /// 冻结画面里的直线和内容外沿（后台算好才有）
    private var contentEdges: ContentEdges? { didSet { mergeSnapLines() } }
    private var contentEdgesToken = 0
    /// 窗口边、屏幕边、菜单栏下沿，加上画面里的长直线
    private var allVertical: [SnapLines.Segment] = []
    private var allHorizontal: [SnapLines.Segment] = []
    private func mergeSnapLines() {
        allVertical = snaps.vertical + (contentEdges?.vertical ?? [])
        allHorizontal = snaps.horizontal + (contentEdges?.horizontal ?? [])
    }
    let screenRef: NSScreen

    /// 这块屏幕上的选区。nil 表示还没框
    private(set) var selection: CGRect?
    private(set) var kind: Kind = .area
    private var label = ""
    /// 窗口模式下鼠标停着的窗口
    private(set) var hover: ScreenWindow?
    private var drag: Drag?
    /// 正在拖选区（新框、挪、调大小）。画标注、挪标注不算
    var isDragging: Bool {
        switch drag {
        case .none, .annotate?, .moveAnnotation?: return false
        default: return true
        }
    }
    private var dragStart = CGPoint.zero
    private var moved = false
    private var shownSelection = false
    private var guides: [(vertical: Bool, seg: SnapLines.Segment)] = []
    private var originGuides: [(vertical: Bool, seg: SnapLines.Segment)] = []
    private(set) var cursorName = "none"

    /// 窗口的圆角（系统没有接口能读到每个窗口的真实圆角，用新系统窗口的常见值）
    static let windowCorner: CGFloat = 16

    enum Handle: CaseIterable { case bottomLeft, bottom, bottomRight, right, topRight, top, topLeft, left }
    /// 框好以后在选区上画的东西
    /// 标注层建过没有（它是用到才建的，换画面时没建过就不用管）
    private var annotatorMade = false
    private(set) lazy var annotator: Annotator = {
        annotatorMade = true
        let a = Annotator(bounds: bounds)
        a.scale = window?.backingScaleFactor ?? 2
        return a
    }()
    private var textEditor: TextAnnotationEditor?
    /// 美化背景：开着时选区外面铺背景，存下来也是这样
    private(set) var beautyOn = false
    private(set) var beautyStyle = BeautyStyle.load()
    private lazy var beautyPreview = BeautyPreview(bounds: bounds)
    var wallpaper: CGImage? { BeautyBackground.wallpaper(for: window?.screen) }
    /// 美化时截图的圆角：窗口用窗口自己的，框选和整个屏幕用一样的
    var beautyCorner: CGFloat { kind == .window ? max(selectedWindow?.corner ?? 0, 6) : BeautyLayout.shotCorner }
    /// 开着美化背景时，整张图（背景）在截图界面里的范围；没开就是选区
    var outputFrame: CGRect? { selection.map { beautyOn ? BeautyLayout.frame(for: $0, style: beautyStyle) : $0 } }

    func setBeauty(_ on: Bool, style: BeautyStyle? = nil) {
        beautyOn = on
        if let style { beautyStyle = style }
        updateLayers()
        layoutActionBar()
    }
    /// 选了画画的工具：选区不能挪、不能改大小，在里面拖就是画
    var annotating: Bool { annotator.tool != nil && selection != nil }

    private enum Drag {
        case annotate
        /// 拖着画好的东西挪
        case moveAnnotation
        case new(origin: CGPoint)
        /// grab：手柄中心减去按下的位置，拖的时候边不会跳到鼠标上
        case resize(Handle, grab: CGPoint, start: CGRect)
        case move(offset: CGPoint, start: CGRect)
    }

    init(screen: NSScreen, frozen: CGImage, session: CaptureSession) {
        self.session = session
        self.frozen = frozen
        let size = screen.frame.size
        screenRef = screen
        windows = ScreenWindows.list(for: screen)
        snaps = SnapLines.build(for: screen, size: size, windows: ScreenWindows.usable(windows))
        super.init(frame: CGRect(origin: .zero, size: size))
        mergeSnapLines()
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        canvas.frame = bounds
        canvas.wantsLayer = true
        canvas.autoresizingMask = [.width, .height]
        addSubview(canvas)
        let root = canvas.layer!
        imageLayer.contents = frozen
        imageLayer.contentsGravity = .resize
        root.addSublayer(imageLayer)

        spotlight.borderColor = Self.dimColor.cgColor
        spotlight.borderWidth = Self.spotPad
        // 橙线：能显示 HDR 的屏幕上一直是 HDR 的（普通白色的 1.6 倍亮），外面一圈 HDR 光晕。
        // 图层开着 wantsExtendedDynamicRangeContent，屏幕会自己打开 HDR 余量来显示
        let hdr = Motion.hdrCapable(screen)
        halo = CaptureHalo(hdr: hdr, bounds: bounds, screen: screen)
        ring.borderWidth = Self.ringWidth
        Motion.allowHDR(ring, hdr)
        ring.borderColor = hdr ? Motion.orange(1.6) : Motion.orange(1)
        dim.fillRule = .evenOdd
        // 一打开整个屏幕就暗一点，框好的地方（或者窗口模式下鼠标停着的窗口）是亮的
        dim.fillColor = Self.dimColor.cgColor
        outlineDark.fillColor = nil
        outlineDark.strokeColor = NSColor(white: 0, alpha: 0.45).cgColor
        outlineDark.lineWidth = 1.5
        outlineLight.fillColor = nil
        outlineLight.strokeColor = NSColor.white.cgColor
        outlineLight.lineWidth = 1
        outlineLight.lineDashPattern = [4, 3]
        guide = GuideGlow(bounds: bounds, screen: screen)
        for l in [dim, spotlight] { l.opacity = 0; root.addSublayer(l) }
        root.addSublayer(beautyPreview.layer)
        root.addSublayer(annotator.layer)
        annotator.clip(to: nil)
        root.addSublayer(halo.layer)
        for l in [ring, outlineDark, outlineLight] { l.opacity = 0; root.addSublayer(l) }
        root.addSublayer(guide.layer)
        for _ in Handle.allCases {
            let h = CALayer()
            h.bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
            h.cornerRadius = 4
            h.backgroundColor = NSColor.white.cgColor
            h.borderWidth = 0.5
            h.borderColor = NSColor(white: 0, alpha: 0.35).cgColor
            h.shadowColor = NSColor.black.cgColor
            h.shadowOpacity = 0.35
            h.shadowRadius = 1.5
            h.shadowOffset = CGSize(width: 0, height: -1)
            h.isHidden = true
            root.addSublayer(h)
            handleLayers.append(h)
        }

        addSubview(badge)
        addSubview(loupe)
        badge.onCommit = { [weak self] size in self?.resizeFromBadge(size) }
        badge.onEndEditing = { [weak self] in self.map { _ = $0.window?.makeFirstResponder($0) } }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: 冻结、实时

    func setSnapshot(_ image: CGImage, output withPointer: CGImage?, hdr: CGImage? = nil, outputHDR: CGImage? = nil) {
        frozen = image
        output = withPointer
        frozenHDR = hdr
        self.outputHDR = outputHDR
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 有 HDR 的那张就显示它（开 HDR 显示），冻结的画面才不会比实时的视频暗一截
        imageLayer.preferredDynamicRange = hdr == nil ? .standard : .high
        imageLayer.contents = hdr ?? image
        CATransaction.commit()
        if annotatorMade { annotator.updateSource((image, bounds), live: false) }
        computeContentEdges(from: image)
    }

    /// 后台算冻结画面里的直线和内容外沿（几十毫秒）。算好之前只吸窗口边
    private func computeContentEdges(from image: CGImage) {
        contentEdgesToken += 1
        let token = contentEdgesToken, size = bounds.size
        let box = UncheckedImage(image)
        Task { @MainActor [weak self] in
            let t0 = Date()
            let e = await Task.detached(priority: .userInitiated) { ContentEdges.build(from: box.image, pointSize: size) }.value
            guard let self, self.contentEdgesToken == token else { return }
            self.contentEdgesSeconds = Date().timeIntervalSince(t0)
            self.contentEdges = e
        }
    }
    private struct UncheckedImage: @unchecked Sendable { let image: CGImage; init(_ i: CGImage) { image = i } }
    /// 调试用：把找到的直线画在冻结画面上存成 PNG（红色竖线、蓝色横线）
    func debugDumpContentLines(to url: URL) {
        guard let e = contentEdges else { return }
        let w = Int(bounds.width), h = Int(bounds.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.draw(frozen, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(NSColor(white: 1, alpha: 0.45).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setLineWidth(1.5)
        ctx.setStrokeColor(NSColor.systemRed.cgColor)
        for g in e.vertical { ctx.move(to: CGPoint(x: g.pos, y: g.from)); ctx.addLine(to: CGPoint(x: g.pos, y: g.to)) }
        ctx.strokePath()
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        for g in e.horizontal { ctx.move(to: CGPoint(x: g.from, y: g.pos)); ctx.addLine(to: CGPoint(x: g.to, y: g.pos)) }
        ctx.strokePath()
        guard let img = ctx.makeImage(), let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
    }

    /// 调试用：算了多久
    private(set) var contentEdgesSeconds: Double = 0
    /// 调试用：画面里找到了几条直线
    var contentLineCount: (Int, Int) { (contentEdges?.vertical.count ?? -1, contentEdges?.horizontal.count ?? -1) }

    /// 实时：窗口透明（遮罩、虚线框照样画），框好那一刻才截
    func setLive(_ on: Bool) {
        isLive = on
        if on { snapshotStale = true }
        if annotatorMade, annotator.sourceIsLive != on { annotator.updateSource((frozen, bounds), live: on) }
        guard let w = window else { return }
        w.isOpaque = !on
        // 几乎透明但不是全透明，点击才不会穿过去
        w.backgroundColor = on ? NSColor(white: 0, alpha: 0.001) : .black
        layer?.backgroundColor = on ? NSColor.clear.cgColor : NSColor.black.cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.isHidden = on
        CATransaction.commit()
        updateLoupe(at: nil)
    }

    // MARK: 滚动截图

    private(set) var scrolling = false
    private let scrollDim = CAShapeLayer()
    private let scrollFrame = CAShapeLayer()

    /// 开始、结束滚动截图：截图界面变成实时、点得穿；选区外面暗、选区一圈白色虚线；别的都收起来
    func setScrolling(_ on: Bool) {
        guard on != scrolling, let s = selection else { return }
        scrolling = on
        commitText()
        annotator.select(nil)
        let chrome: [CALayer] = [dim, spotlight, ring, halo.layer, outlineDark, outlineLight, guide.layer, annotator.layer]
        if on {
            setLive(true)
            for l in chrome { Motion.fade(l, to: 0, duration: 0.12) }
            glow?.hide(duration: 0.12)
            if let l = badge.layer { Motion.fade(l, to: 0, duration: 0.1) }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            handleLayers.forEach { $0.isHidden = true }
            let p = CGMutablePath()
            p.addRect(bounds)
            p.addRect(s)
            scrollDim.path = p
            scrollDim.fillRule = .evenOdd
            scrollDim.fillColor = Self.dimColor.cgColor
            scrollFrame.path = CGPath(rect: s.insetBy(dx: -1, dy: -1), transform: nil)
            scrollFrame.fillColor = nil
            scrollFrame.strokeColor = NSColor.white.cgColor
            scrollFrame.lineWidth = 1.5
            scrollFrame.lineDashPattern = [6, 4]
            scrollFrame.shadowColor = NSColor.black.cgColor
            scrollFrame.shadowOpacity = 0.5
            scrollFrame.shadowRadius = 1
            scrollFrame.shadowOffset = .zero
            if scrollDim.superlayer == nil { canvas.layer?.addSublayer(scrollDim); canvas.layer?.addSublayer(scrollFrame) }
            scrollDim.opacity = 0; scrollFrame.opacity = 0
            CATransaction.commit()
            Motion.fade(scrollDim, to: 1, duration: 0.16)
            Motion.fade(scrollFrame, to: 1, duration: 0.16)
            // 虚线慢慢走（像在录）
            let march = CABasicAnimation(keyPath: "lineDashPhase")
            march.fromValue = 0
            march.toValue = -10
            march.duration = 0.6
            march.repeatCount = .infinity
            scrollFrame.add(march, forKey: "march")
        } else {
            scrollFrame.removeAnimation(forKey: "march")
            Motion.fade(scrollDim, to: 0, duration: 0.12)
            Motion.fade(scrollFrame, to: 0, duration: 0.12)
            // 回到框好的样子：暗的那层、光、标签、手柄、画的东西都回来（和开始时收起来的反过来）
            Motion.fade(annotator.layer, to: 1, duration: 0.16)
            if let l = badge.layer { Motion.fade(l, to: 1, duration: 0.16) }
            updateLayers()
            updateDim(animated: false)
            glow?.show(duration: 0.16)
        }
    }

    /// 倒数开始、结束。开始：暗的那层、框、手柄、标签、橙线都淡掉；结束（取消）时回来。
    /// restore false：数完了马上要截，不用回来（截图界面跟着淡出）
    func setCounting(_ on: Bool, restore: Bool = true) {
        guard on != counting else { return }
        counting = on
        let layers: [CALayer] = [dim, spotlight, ring, halo.layer, outlineDark, outlineLight, guide.layer]
        if on {
            for l in layers { Motion.fade(l, to: 0, duration: 0.14) }
            glow?.hide(duration: 0.14)
            if let l = badge.layer { Motion.fade(l, to: 0, duration: 0.12) }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            handleLayers.forEach { $0.isHidden = true }
            CATransaction.commit()
            loupe.isHidden = true
        } else if restore {
            if let l = badge.layer { Motion.fade(l, to: 1, duration: 0.14) }
            updateLayers()
        }
    }

    /// 这块屏幕这次有没有 HDR 的那张（设置开了 HDR、屏幕能显示 HDR、截到了）。和系统截图一样：有就用 HDR 截
    var hdrAvailable: Bool { frozenHDR != nil }

    /// 后台量完了窗口：换上新的窗口列表，吸附线、高亮跟着更新
    func updateWindows(_ ws: [ScreenWindow]) {
        windows = ws
        snaps = SnapLines.build(for: screenRef, size: bounds.size, windows: ScreenWindows.usable(ws))
        if let h = hover { hover = nil; setHover(ws.first { $0.id == h.id }) }
        refreshHover()
        if let w = window { updateCursor(at: convert(w.mouseLocationOutsideOfEventStream, from: nil)) }
    }

    /// 记住上次选区：直接框好
    func restoreSelection(_ r: CGRect) {
        session?.selectionBegan(on: self)
        kind = .area
        label = ""
        selectedWindow = nil
        selection = r
        setHover(nil)
        updateLayers()
        session?.selectionSettled(on: self)
    }

    // MARK: 放大镜

    /// 颜色（放大镜开着、显示着时才有），按 C 拷贝
    var loupeHex: String? { loupe.isHidden ? nil : loupe.hex }

    /// 框选前、拖新框、拖手柄时显示在鼠标旁边。实时模式、窗口模式、在条上时不显示
    func updateLoupe(at point: CGPoint?) {
        let p = point ?? window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) } ?? .zero
        var show = (session?.loupeEnabled ?? false) && !isLive && bounds.contains(p) && mode != .window
            && !overBar(p) && !overBadge(p) && !overActionBar(p) && !badge.isEditing && !counting
        switch drag {
        case .none: show = show && selection == nil
        case .new, .resize: break
        case .move, .annotate, .moveAnnotation: show = false
        }
        guard show, let scale = window?.backingScaleFactor else { loupe.isHidden = true; return }
        loupe.update(image: frozen, at: p, viewSize: bounds.size, scale: scale)
        loupe.place(at: p, in: bounds)
        loupe.isHidden = false
    }

    func install(bar: SelectionBar) {
        self.bar = bar
        addSubview(bar)
        needsLayout = true
    }

    /// 自己加的线条图层（吸附线、滚动截图的虚线框、选区外框）默认按 1 倍画，Retina 屏上发虚：跟着屏幕的倍数
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let s = window?.backingScaleFactor, let l = layer { Self.applyLineScale(l, s) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let s = window?.backingScaleFactor, let l = layer { Self.applyLineScale(l, s) }
    }

    static func applyLineScale(_ l: CALayer, _ s: CGFloat) {
        if l is CAShapeLayer || l is CATextLayer, l.contentsScale != s { l.contentsScale = s }
        l.sublayers?.forEach { applyLineScale($0, s) }
    }

    override func layout() {
        super.layout()
        if let s = window?.backingScaleFactor, let l = layer { Self.applyLineScale(l, s) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [imageLayer, dim, outlineDark, outlineLight] { l.frame = bounds }
        guide.resize(bounds)
        CATransaction.commit()
        updateDim(animated: false)
        guard let bar, let screen = window?.screen else { return }
        // 和系统截图工具一样，放在屏幕底部偏右，避开程序坞
        let size = bar.fittingSize
        let visible = screen.visibleFrame
        let bottom = visible.minY - screen.frame.minY + 26
        let right = screen.frame.maxX - visible.maxX + 36
        bar.frame = CGRect(x: (bounds.width - right - size.width).rounded(), y: bottom.rounded(),
                           width: size.width, height: size.height)
    }

    private var mode: CaptureMode { session?.mode ?? .area }
    private func overBar(_ p: CGPoint) -> Bool { bar.map { !$0.isHidden && $0.frame.contains(p) } ?? false }
    private func overBadge(_ p: CGPoint) -> Bool { !badge.isHidden && !badgeFading && !badgeFollowsHover && badge.frame.contains(p) }
    private func overActionBar(_ p: CGPoint) -> Bool {
        (actionBar.map { !$0.isHidden && $0.superview === self && $0.frame.contains(p) } ?? false)
            || subviews.contains { ($0 is AnnotationStyleBar || $0 is BeautyBar) && !$0.isHidden && $0.frame.contains(p) }
            || (scanBar.map { !$0.isHidden && $0.frame.contains(p) } ?? false)
    }

    // MARK: 画画

    /// 换工具（nil：不画，回到挪选区、改大小）
    func setTool(_ t: AnnotationTool?) {
        commitText()
        annotator.select(nil)
        annotator.tool = t
        updateLayers()
        if let w = window { updateCursor(at: convert(w.mouseLocationOutsideOfEventStream, from: nil)) }
    }

    private func beginText(at p: CGPoint) {
        let e = TextAnnotationEditor(at: p, color: annotator.color, width: annotator.width)
        e.onCommit = { [weak self] text, origin, color, width in self?.annotator.addText(text, at: origin, color: color, width: width) }
        e.onFinish = { [weak self] in
            guard let self else { return }
            self.textEditor = nil
            if self.window?.firstResponder !== self { self.window?.makeFirstResponder(self) }
        }
        textEditor = e
        addSubview(e.field)
        window?.makeFirstResponder(e.field)
    }

    /// 改已经放好的字：输入框盖在原来那段字上，原来的先藏起来
    private func editText(_ i: Int) {
        let a = annotator.items[i]
        annotator.select(nil)
        annotator.setHidden(i, true)
        let e = TextAnnotationEditor(at: a.start, color: a.color, width: a.width, text: a.text, textOrigin: a.start)
        e.onCommit = { [weak self] text, _, color, width in self?.annotator.replaceText(i, with: text, color: color, width: width) }
        e.onFinish = { [weak self] in
            guard let self else { return }
            self.annotator.setHidden(i, false)
            self.textEditor = nil
            if self.window?.firstResponder !== self { self.window?.makeFirstResponder(self) }
        }
        textEditor = e
        addSubview(e.field)
        window?.makeFirstResponder(e.field)
        e.field.currentEditor()?.selectAll(nil)
    }

    /// 正在打字的话先交出去（换工具、截图、点别的地方之前）
    func commitText() { textEditor?.commit() }
    func restyleText(color: NSColor? = nil, width: CGFloat? = nil) { textEditor?.restyle(color: color, width: width) }
    func cancelText() { textEditor?.cancel() }
    var isEditingText: Bool { textEditor != nil }

    func attach(actionBar ab: ActionBar) {
        actionBar = ab
        addSubview(ab)
    }

    /// 操作条贴在选区右下角下面；下面放不下（程序坞、屏幕底）就放上面；上下都放不下就放进选区右下角
    func layoutActionBar() {
        guard let ab = actionBar, ab.superview === self, let s = outputFrame?.intersection(bounds), let screen = window?.screen else { return }
        let size = ab.fittingSize
        let visible = screen.visibleFrame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let gap: CGFloat = 10
        var x = s.maxX - size.width
        var y = s.minY - gap - size.height
        actionBarBelow = true
        if y < visible.minY + 8 {
            y = s.maxY + gap
            actionBarBelow = false
            if y + size.height > visible.maxY - 8 {
                y = max(s.minY, visible.minY) + 14
                x = min(s.maxX, visible.maxX) - size.width - 14
            }
        }
        x = min(max(x, 8), bounds.width - size.width - 8)
        ab.frame = CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    /// 颜色、粗细小条：对着选中的工具按钮，放在操作条离选区远的那一边（不挡着正在画的地方）
    func layoutStyleBar(_ sb: GlassBar, for tool: AnnotationTool?) {
        guard let ab = actionBar else { return }
        ab.layoutSubtreeIfNeeded()
        sb.layoutSubtreeIfNeeded()
        guard let bf = tool.map({ ab.toolButtonFrame($0) }) ?? ab.beautyButtonFrame else { return }
        let size = sb.fittingSize
        let gap: CGFloat = 8
        var x = ab.frame.minX + bf.midX - size.width / 2
        var y = actionBarBelow ? ab.frame.minY - gap - size.height : ab.frame.maxY + gap
        if y < 8 || y + size.height > bounds.height - 8 { y = actionBarBelow ? ab.frame.maxY + gap : ab.frame.minY - gap - size.height }
        x = min(max(x, 8), bounds.width - size.width - 8)
        sb.frame = CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    // MARK: 扫描（Scan 模式）

    /// 选区边上那圈光（和系统 Visual Intelligence 的一样）
    private var glow: ScanGlow?
    /// 认出码以后，暗层只空出码那一块
    private var scanHole: (rect: CGRect, corner: CGFloat)?
    private(set) weak var scanBar: ScanResultBar?

    /// 开始扫描：手柄、尺寸标签、虚线框、窗口的橙线收起来，选区边上亮起光
    func beginScan() {
        guard let s = selection, let root = canvas.layer else { return }
        fadeOutBadge()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        handleLayers.forEach { $0.isHidden = true }
        CATransaction.commit()
        Self.fade([outlineDark, outlineLight], to: 0, duration: 0.12)
        Motion.fade(ring, to: 0, duration: 0.12)
        Motion.fade(halo.layer, to: 0, duration: 0.12)
        let g = glow ?? makeGlow(in: root)
        g.move(to: s, corner: currentHole.corner, animated: false)
        g.show()
        glow = g
    }

    private func makeGlow(in root: CALayer, tint: ScanGlow.Tint = .iridescent) -> ScanGlow {
        let g = ScanGlow(bounds: bounds, screen: window?.screen, tint: tint)
        root.insertSublayer(g.layer, above: guide.layer)
        return g
    }

    /// 拖选区、选区定下来以后：选区的边就是那圈光（没有虚线框），跟着手走。
    /// Scan 是彩色流光，松手接着扫描、光不断；普通截图是橙色，画在选区外面一圈，截下来的区域里干干净净
    private func followGlow() {
        guard scanHole == nil, let root = canvas.layer else { return }
        let scan = session?.mode == .text
        let tint: ScanGlow.Tint = scan ? .iridescent : ScanGlow.Tint.selection
        guard let s = selection, s.width >= 1, s.height >= 1, scan || kind == .area else {
            if let g = glow, scanBar == nil, drag == nil { g.hide { g.layer.removeFromSuperlayer() }; glow = nil }
            return
        }
        if let g = glow, g.tint != tint { g.layer.removeFromSuperlayer(); glow = nil }
        let g = glow ?? makeGlow(in: root, tint: tint)
        if glow == nil { glow = g; g.show(duration: 0.12) } else if g.hidden, drag == nil || !scan { g.show(duration: 0.14) }
        g.move(to: s, corner: currentHole.corner, animated: false, outside: !scan, clamp: bounds)
    }

    /// 认出了码：光和暗层空出来的那块一起弹到码上（r 是这块屏幕的坐标）。换下一个码时也用这个
    func focusScan(on r: CGRect) {
        let corner = min(max(min(r.width, r.height) * 0.06, 6), 12)
        let fromModel = scanHole ?? currentHole
        let fromPath = (scanHole != nil ? dim.presentation()?.path : nil) ?? Self.holePath(bounds, fromModel.rect, fromModel.corner)
        let toPath = Self.holePath(bounds, r, corner)
        scanHole = (r, corner)
        // 暗层接手（窗口模式本来用 spotlight，整个屏幕本来不暗）：先换成和现在一样的样子，看不出换了，再弹过去
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [dim, spotlight] { l.removeAnimation(forKey: "fade") }
        dim.opacity = 1
        spotlight.opacity = 0
        dim.path = toPath
        CATransaction.commit()
        dim.add(Motion.spring("path", from: fromPath, to: toPath, duration: 0.42, bounce: 0.16), forKey: "scanHole")
        glow?.move(to: r, corner: corner, animated: true, outside: true)
    }

    /// 扫描结束，光淡掉、结果条收起。restore：回到平常的样子（选区的暗层、手柄、虚线框）
    func endScan(restore: Bool, keepGlow: Bool = false) {
        if let b = scanBar {
            b.animateOut(duration: 0.12, offsetY: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { b.removeFromSuperview() }
        }
        scanBar = nil
        if !keepGlow, let g = glow { g.hide { g.layer.removeFromSuperlayer() }; glow = nil }
        guard restore else { return }
        dim.removeAnimation(forKey: "scanHole")
        scanHole = nil
        updateLayers()
    }

    var isScanning: Bool { glow != nil }

    /// 结果条放在码下面（下面放不下就放上面），从码那边弹出来。换码时旧的收起、新的出来
    func show(scanBar b: ScanResultBar, for code: CGRect) {
        if let old = scanBar, old !== b {
            old.animateOut(duration: 0.1, offsetY: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { old.removeFromSuperview() }
        }
        addSubview(b)
        scanBar = b
        let size = b.fittingSize
        let visible = window?.screen.map { $0.visibleFrame.offsetBy(dx: -$0.frame.minX, dy: -$0.frame.minY) } ?? bounds
        let gap: CGFloat = 12
        var below = true
        var y = code.minY - gap - size.height
        if y < visible.minY + 8 {
            y = code.maxY + gap
            below = false
            if y + size.height > visible.maxY - 8 { y = max(code.minY, visible.minY) + gap; below = true }
        }
        let x = min(max(code.midX - size.width / 2, 8), bounds.width - size.width - 8)
        b.frame = CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
        b.animateIn(below: below)
    }

    /// 现在亮着的那块（选区，窗口的话带窗口的圆角）
    private var currentHole: (rect: CGRect, corner: CGFloat) {
        let s = selection ?? bounds
        let c = kind == .window ? min(selectedWindow?.corner ?? 0, s.width / 2, s.height / 2) : 0
        return (s, c)
    }

    /// 整块暗、中间挖一个圆角矩形。圆角至少给一点点，两个形状的点数一样，才能平滑地变过去
    private static func holePath(_ b: CGRect, _ r: CGRect, _ c: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.addRect(b)
        let cc = min(max(c, 0.01), r.width / 2 - 0.01, r.height / 2 - 0.01)
        p.addRoundedRect(in: r, cornerWidth: max(cc, 0.01), cornerHeight: max(cc, 0.01))
        return p
    }

    /// 调试用：换成一张假的 HDR 画面（中间一块比白色亮 4 倍），测 HDR 的判断和输出
    func debugUseFakeHDR(bright r: CGRect) {
        let scale = window?.backingScaleFactor ?? 2
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        let cs = CGColorSpace(name: CGColorSpace.extendedSRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        func make(_ peak: CGFloat) -> CGImage? {
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8, space: cs, bitmapInfo: info) else { return nil }
            ctx.scaleBy(x: scale, y: scale)
            ctx.setFillColor(CGColor(colorSpace: cs, components: [0.25, 0.45, 0.85, 1])!)
            ctx.fill(CGRect(origin: .zero, size: bounds.size))
            ctx.setFillColor(CGColor(colorSpace: cs, components: [peak, peak, peak, 1])!)
            ctx.fill(r)
            return ctx.makeImage()
        }
        guard let sdr = make(1), let hdr = make(1.9) else { return }
        setSnapshot(sdr, output: nil, hdr: hdr)
    }

    /// 调试用：冻结画面换成一张已知的图，测吸附：浅灰背景上，
    /// 一个没有边框的"太阳"（圆心 300,600，半径 60），一张白卡片（x 600…1000、y 300…700，1pt 灰边框），
    /// 卡片里一条横分隔线（y 500，x 600…1000）
    func debugUseSnapScene() {
        let scale = window?.backingScaleFactor ?? 2
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(NSColor(white: 0.93, alpha: 1).cgColor)
        ctx.fill(CGRect(origin: .zero, size: bounds.size))
        ctx.setFillColor(NSColor(calibratedRed: 1, green: 0.75, blue: 0.1, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: 240, y: 540, width: 120, height: 120))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 600, y: 300, width: 400, height: 400))
        ctx.setStrokeColor(NSColor(white: 0.7, alpha: 1).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: 600.5, y: 300.5, width: 399, height: 399))
        ctx.fill(CGRect(x: 600, y: 499.5, width: 400, height: 1))
        ctx.setFillColor(NSColor(white: 0.75, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 600, y: 499.5, width: 400, height: 1))
        // 一列短横线（像滚动条旁边的刻度）：x 120…136，y 200…440 每 16pt 一条
        ctx.setFillColor(NSColor(white: 0.8, alpha: 1).cgColor)
        for i in 0..<16 { ctx.fill(CGRect(x: 120, y: 200 + CGFloat(i) * 16, width: 16, height: 2)) }
        guard let img = ctx.makeImage() else { return }
        setSnapshot(img, output: nil, hdr: nil)
    }

    /// 调试用：不识别，只把扫描的光放出来（截图看样子）
    func debugScanDemo(_ r: CGRect) {
        selection = r
        kind = .area
        updateLayers()
        beginScan()
    }

    /// 调试用：冻结画面换成浅色背景上几个二维码（内容、左下角、边长），测扫描
    func debugUseFakeCodes(_ codes: [(String, CGPoint, CGFloat)]) {
        let scale = window?.backingScaleFactor ?? 2
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(NSColor(calibratedRed: 0.93, green: 0.94, blue: 0.96, alpha: 1).cgColor)
        ctx.fill(CGRect(origin: .zero, size: bounds.size))
        let ci = CIContext()
        for (text, at, side) in codes {
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: at.x - 16, y: at.y - 16, width: side + 32, height: side + 32))
            guard let f = CIFilter(name: "CIQRCodeGenerator") else { continue }
            f.setValue(Data(text.utf8), forKey: "inputMessage")
            f.setValue("M", forKey: "inputCorrectionLevel")
            guard let out = f.outputImage, let img = ci.createCGImage(out, from: out.extent) else { continue }
            ctx.interpolationQuality = .none
            ctx.draw(img, in: CGRect(x: at.x, y: at.y, width: side, height: side))
        }
        guard let img = ctx.makeImage() else { return }
        frozen = img
        imageLayer.contents = img
    }

    /// 调试用：把冻结的画面换成一张画着已知文字的图，测文字识别
    func debugUseFakeText(_ lines: [(String, CGFloat)]) {
        let scale = window?.backingScaleFactor ?? 2
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(origin: .zero, size: bounds.size))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for (text, y) in lines {
            text.draw(at: CGPoint(x: 200, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: 28, weight: .regular),
                                                                 .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let img = ctx.makeImage() else { return }
        frozen = img
        imageLayer.contents = img
    }

    /// 按了主按钮：选区闪一下白，尺寸标签和手柄收起
    func flashAndHideChrome(flash withFlash: Bool = true) {
        guard let s = selection, let root = canvas.layer else { return }
        glow?.hide(duration: 0.12)
        defer {
            badge.isHidden = true
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            handleLayers.forEach { $0.isHidden = true }
            CATransaction.commit()
        }
        guard withFlash else { return }
        // 沿选区边缘亮一下再散开：选区里面一圈很宽的、模糊的亮边（被选区裁住），不是整块白闪
        let clip = CALayer()
        clip.frame = s
        clip.masksToBounds = true
        clip.opacity = 0
        let edge = CALayer()
        edge.frame = CGRect(origin: .zero, size: s.size).insetBy(dx: -4, dy: -4)
        edge.borderWidth = 22
        edge.borderColor = NSColor(calibratedRed: 1, green: 0.93, blue: 0.82, alpha: 1).cgColor
        edge.filters = [CIFilter(name: "CIGaussianBlur", parameters: ["inputRadius": 11])!]
        clip.addSublayer(edge)
        root.addSublayer(clip)
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [0, 0.95, 0]
        a.keyTimes = [0, 0.18, 1]
        a.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
        // 调试：HS_FLASH_SLOW=倍数 把闪光放慢（截图看样子）
        a.duration = 0.42 * (ProcessInfo.processInfo.environment["HS_FLASH_SLOW"].flatMap(Double.init) ?? 1)
        clip.add(a, forKey: "flash")
    }

    /// 关掉截图界面：高亮、光晕、标签先很快淡掉（选择条同时往下收），然后整个界面淡出
    func fadeChromeForClose() {
        for l in [ring, halo.layer, outlineDark, outlineLight, guide.layer] { Motion.fade(l, to: 0, duration: 0.09) }
        glow?.hide(duration: 0.09)
        if let l = badge.layer { Motion.fade(l, to: 0, duration: 0.09) }
        loupe.isHidden = true
    }

    // MARK: 按下去的手感

    /// 按下去时橙线收紧一点、光晕亮一点、标签缩一点；松开弹回来（点中了就带一下回弹）
    private var pressed = false
    private static let pressInset: CGFloat = 2.5

    func pressHighlight() {
        guard !pressed, ring.opacity > 0 else { return }
        pressed = true
        let d = Self.pressInset
        for (key, from, to) in [("bounds", NSValue(rect: .zero), NSValue(rect: CGRect(x: 0, y: 0, width: -2 * d, height: -2 * d))),
                                ("cornerRadius", NSNumber(value: 0), NSNumber(value: -Double(d)))] as [(String, Any, Any)] {
            let a = CABasicAnimation(keyPath: key)
            a.isAdditive = true
            a.fromValue = from
            a.toValue = to
            a.duration = 0.09
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false
            ring.add(a, forKey: "press.\(key)")
        }
        halo.press(true)
        scaleBadge(0.95, duration: 0.09)
    }

    func releaseHighlight(bounce: Bool) {
        guard pressed else { return }
        pressed = false
        let d = Self.pressInset
        for (key, from, to) in [("bounds", NSValue(rect: CGRect(x: 0, y: 0, width: -2 * d, height: -2 * d)), NSValue(rect: .zero)),
                                ("cornerRadius", NSNumber(value: -Double(d)), NSNumber(value: 0))] as [(String, Any, Any)] {
            ring.removeAnimation(forKey: "press.\(key)")
            let a = Motion.spring(key, from: from, to: to, duration: bounce ? 0.32 : 0.16, bounce: bounce ? 0.32 : 0)
            a.isAdditive = true
            ring.add(a, forKey: "release.\(key)")
        }
        halo.press(false)
        scaleBadge(1, duration: bounce ? 0.32 : 0.16, bounce: bounce ? 0.32 : 0)
    }

    /// 标签以中心缩放（NSView 的图层原点在左下角，所以用 sublayerTransform 绕中心缩）
    private func scaleBadge(_ k: CGFloat, duration: CGFloat, bounce: CGFloat = 0) {
        guard let l = badge.layer, !badge.isHidden else { return }
        let c = CGPoint(x: l.bounds.midX, y: l.bounds.midY)
        var t = CATransform3DMakeTranslation(c.x, c.y, 0)
        t = CATransform3DScale(t, k, k, 1)
        t = CATransform3DTranslate(t, -c.x, -c.y, 0)
        let from = l.presentation()?.sublayerTransform ?? l.sublayerTransform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.sublayerTransform = t
        CATransaction.commit()
        let a = k < 1 ? { () -> CAAnimation in
            let b = CABasicAnimation(keyPath: "sublayerTransform")
            b.fromValue = NSValue(caTransform3D: from); b.toValue = NSValue(caTransform3D: t)
            b.duration = CFTimeInterval(duration); b.timingFunction = CAMediaTimingFunction(name: .easeOut)
            return b
        }() : Motion.spring("sublayerTransform", from: NSValue(caTransform3D: from), to: NSValue(caTransform3D: t), duration: duration, bounce: bounce)
        l.add(a, forKey: "press")
    }

    // MARK: 吸附的手感

    /// 上一次拖动时吸着的线。吸到新的线上时触控板轻震一下（和 Keynote 里对齐一样）
    private var lastGuideKeys: Set<String> = []
    private(set) var snapTaps = 0
    private func guideKeys() -> Set<String> { Set(guides.map { "\($0.vertical ? "v" : "h")\(Int(($0.seg.pos * 2).rounded()))" }) }
    private func snapFeedback() {
        let now = guideKeys()
        if !now.subtracting(lastGuideKeys).isEmpty, !now.isEmpty {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            snapTaps += 1
        }
        lastGuideKeys = now
    }

    // MARK: 鼠标

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // 选择条和尺寸标签空白处的点击也会传到这里，不当成框选
        if overBar(p) || overBadge(p) || overActionBar(p) { return }
        window?.makeFirstResponder(self) // 正在改尺寸的话，这里会先把数字提交
        moved = false
        dragStart = p
        lastGuideKeys = []
        if mode == .window, selection == nil, let h = hover, h.rect.contains(p) { pressHighlight() }
        guides = []
        originGuides = []
        // 选了画画的工具：在选区里点就是画，选区外面点没反应（不会把画好的东西连选区一起丢掉）
        if annotating, let s = selection {
            commitText()
            guard s.contains(p) else { annotator.select(nil); return }
            annotator.source = (frozen, bounds)
            annotator.sourceIsLive = isLive
            // 点到画好的东西：选中它、拖着挪；文字工具点到字（或者双击字）就改字
            if let i = annotator.hitForDrawing(p) {
                let a = annotator.items[i]
                if a.tool == .text && (annotator.tool == .text || event.clickCount == 2) { editText(i); return }
                annotator.beginMove(i, at: p)
                drag = .moveAnnotation
                setCursor(.closedHand, "closedHand")
                return
            }
            annotator.select(nil)
            if annotator.tool == .text { beginText(at: p); return }
            annotator.begin(at: p)
            if annotator.isDrawing { drag = .annotate }
            return
        }
        if let s = selection, kind == .area {
            if let h = handle(at: p, in: s) {
                let hp = h.point(in: s)
                drag = .resize(h, grab: CGPoint(x: hp.x - p.x, y: hp.y - p.y), start: s)
                return
            }
            if s.contains(p) {
                drag = .move(offset: CGPoint(x: p.x - s.minX, y: p.y - s.minY), start: s)
                setCursor(.closedHand, "closedHand")
                return
            }
        }
        if let s = selection, kind != .area, s.contains(p) {
            // 点在选中的窗口、屏幕里面：不动（拖动的话会变成新的框选）
        }
        // 新选区（窗口模式下也可以拖框）：起点也吸
        var o = clamp(p)
        if snapping(event) {
            if let g = SnapLines.snap(o.x, along: o.y...o.y, in: allVertical) { o.x = g.pos; originGuides.append((true, g)) }
            if let g = SnapLines.snap(o.y, along: o.x...o.x, in: allHorizontal) { o.y = g.pos; originGuides.append((false, g)) }
        }
        drag = .new(origin: o)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let p = convert(event.locationInWindow, from: nil)
        if case .annotate = drag {
            let q = CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
            annotator.move(to: q, shift: event.modifierFlags.contains(.shift))
            return
        }
        if case .moveAnnotation = drag { annotator.moveSelected(to: p); return }
        defer { updateLoupe(at: p) }
        if !moved {
            // 已经画了东西：拖新框要拖出 8 点才算（手抖 3–8 点的一下当成点击，不会把选区和画的东西换掉）
            var threshold: CGFloat = 3
            if case .new = drag, !annotator.items.isEmpty { threshold = 8 }
            guard hypot(p.x - dragStart.x, p.y - dragStart.y) >= threshold else { return }
            moved = true
            releaseHighlight(bounce: false)
            if case .new = drag {
                // 拖了一个新框：旧选区上画的东西不能留着（会被裁到新框里、存进图）
                resetAnnotations()
                setCursor(.crosshair, "crosshair")
                kind = .area
                label = ""
                selectedWindow = nil
                setHover(nil)
            }
            // 拖新框、移动、调整时操作条先收起来，松手再出来
            session?.selectionBegan(on: self)
        }
        guides = []
        switch drag {
        case .annotate, .moveAnnotation: break
        case .new(let o):
            guides = originGuides
            var q = clamp(p)
            if event.modifierFlags.contains(.shift) {
                // ⇧ 正方形
                let d = max(abs(q.x - o.x), abs(q.y - o.y))
                q = clamp(CGPoint(x: o.x + (q.x >= o.x ? d : -d), y: o.y + (q.y >= o.y ? d : -d)))
            } else {
                q.x = snapX(q.x, span: min(o.y, q.y)...max(o.y, q.y), event)
                q.y = snapY(q.y, span: min(o.x, q.x)...max(o.x, q.x), event)
            }
            selection = Self.rect(o, q)
        case .resize(let h, let grab, let s):
            let q = clamp(CGPoint(x: p.x + grab.x, y: p.y + grab.y))
            var x0 = s.minX, x1 = s.maxX, y0 = s.minY, y1 = s.maxY
            if h.movesLeft { x0 = snapX(q.x, span: y0...y1, event) }
            if h.movesRight { x1 = snapX(q.x, span: y0...y1, event) }
            if h.movesBottom { y0 = snapY(q.y, span: min(x0, x1)...max(x0, x1), event) }
            if h.movesTop { y1 = snapY(q.y, span: min(x0, x1)...max(x0, x1), event) }
            // 拖过对边就翻过去，但不能缩成一条线
            if abs(x1 - x0) < 4 { if h.movesLeft { x0 = x1 - 4 } else if h.movesRight { x1 = x0 + 4 } }
            if abs(y1 - y0) < 4 { if h.movesBottom { y0 = y1 - 4 } else if h.movesTop { y1 = y0 + 4 } }
            selection = Self.rect(CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y1)).intersection(bounds)
        case .move(let off, let s):
            var x = min(max(p.x - off.x, 0), bounds.width - s.width)
            var y = min(max(p.y - off.y, 0), bounds.height - s.height)
            if snapping(event) {
                let ys = y...(y + s.height)
                let l = nearestSnap(x, span: ys, vertical: true), r = nearestSnap(x + s.width, span: ys, vertical: true)
                if let l, abs(l.pos - x) <= (r.map { abs($0.pos - x - s.width) } ?? .infinity) { x = l.pos; guides.append((true, l)) }
                else if let r { x = r.pos - s.width; guides.append((true, r)) }
                let xs = x...(x + s.width)
                let b = nearestSnap(y, span: xs, vertical: false), t = nearestSnap(y + s.height, span: xs, vertical: false)
                if let b, abs(b.pos - y) <= (t.map { abs($0.pos - y - s.height) } ?? .infinity) { y = b.pos; guides.append((false, b)) }
                else if let t { y = t.pos - s.height; guides.append((false, t)) }
            }
            selection = CGRect(x: x.rounded(), y: y.rounded(), width: s.width, height: s.height)
        }
        snapFeedback()
        updateLayers()
    }

    override func mouseUp(with event: NSEvent) {
        guard let d = drag else { return }
        let p = convert(event.locationInWindow, from: nil)
        drag = nil
        if case .annotate = d { annotator.end(); updateCursor(at: p); return }
        if case .moveAnnotation = d { annotator.endMove(at: p); updateCursor(at: p); return }
        defer { updateLoupe(at: p) }
        guides = []
        originGuides = []
        lastGuideKeys = []
        if !moved {
            // 点了一下：点在选区里不动；窗口模式下点在窗口上就选中这个窗口；否则取消选区，回到选择条
            if case .new = d {
                if let s = selection, s.contains(p) {
                } else if selection != nil, !annotator.items.isEmpty {
                    // 已经画了东西：手滑在外面点一下不能把选区和画的全丢掉（撤销也回不来），要换就 Esc 或拖一个新框
                } else if mode == .window, let w = screenWindow(at: p) {
                    selectWindow(w)
                    releaseHighlight(bounce: true)
                } else {
                    session?.clearAllSelections()
                }
            }
            updateLayers()
            refreshHover(at: p)
            updateCursor(at: p)
            return
        }
        // 窗口模式：点的时候手抖了几点（触控板上很常见），会被当成拖了一个很小的框然后丢掉，像没点上。没拖出 8 点就当成点了那个窗口
        if case .new = d, mode == .window, hypot(p.x - dragStart.x, p.y - dragStart.y) < 8, let w = screenWindow(at: dragStart) {
            selectWindow(w)
            releaseHighlight(bounce: true)
            updateLayers()
            refreshHover(at: p)
            updateCursor(at: p)
            return
        }
        if case .new = d, let s = selection, s.width < 4 || s.height < 4 {
            session?.clearAllSelections()
            refreshHover(at: p)
            return
        }
        updateLayers()
        updateCursor(at: p)
        session?.selectionSettled(on: self)
    }

    // MARK: 选中窗口、整个屏幕

    func selectWindow(_ w: ScreenWindow) {
        if selectedWindow?.id != w.id { resetAnnotations() }
        session?.selectionBegan(on: self)
        kind = .window
        label = w.label
        selectedWindow = w
        selection = w.rect.intersection(bounds)
        setHover(nil)
        updateLayers()
        session?.selectionSettled(on: self)
    }

    func selectScreen() {
        if kind != .screen { resetAnnotations() }
        session?.selectionBegan(on: self)
        kind = .screen
        label = "Entire Screen"
        selectedWindow = nil
        selection = bounds
        setHover(nil)
        updateLayers()
        session?.selectionSettled(on: self)
    }

    /// 换了选区：上一个选区画的东西清掉
    private func resetAnnotations() {
        cancelText()
        if !annotator.items.isEmpty { annotator.removeAll() }
    }

    func clearSelection() {
        beautyOn = false
        cancelText()
        annotator.removeAll()
        annotator.tool = nil
        selection = nil
        kind = .area
        label = ""
        selectedWindow = nil
        drag = nil
        guides = []
        originGuides = []
        updateLayers()
        // 窗口模式退回去时，马上高亮鼠标现在停着的窗口（不用等鼠标动一下）
        refreshHover()
        if let w = window { updateCursor(at: convert(w.mouseLocationOutsideOfEventStream, from: nil)) }
    }

    // MARK: 吸附

    private func snapping(_ event: NSEvent) -> Bool {
        (session?.snapEnabled ?? true) && !event.modifierFlags.contains(.command) // 按住 ⌘ 不吸
    }

    /// 一条边附近最近的可以吸的地方：窗口边、画面里的直线，或者东西的边沿（贴着东西的哪一边都行）。
    /// vertical：竖着的边（左右边），v 是 x；span 是这条边在另一个方向上的范围
    private func nearestSnap(_ v: CGFloat, span: ClosedRange<CGFloat>, vertical: Bool) -> SnapLines.Segment? {
        let line = SnapLines.snap(v, along: span, in: vertical ? allVertical : allHorizontal)
        let t = SnapLines.threshold
        let fit = vertical ? contentEdges?.boundaryVertical(v, span: span, threshold: t) : contentEdges?.boundaryHorizontal(v, span: span, threshold: t)
        if let f = fit, abs(f - v) < (line.map { abs($0.pos - v) } ?? .infinity) {
            return SnapLines.Segment(pos: f, from: span.lowerBound, to: span.upperBound)
        }
        return line
    }

    private func snapX(_ x: CGFloat, span: ClosedRange<CGFloat>, _ event: NSEvent) -> CGFloat {
        guard snapping(event), let g = nearestSnap(x, span: span, vertical: true) else { return x }
        guides.append((true, g))
        return g.pos
    }

    private func snapY(_ y: CGFloat, span: ClosedRange<CGFloat>, _ event: NSEvent) -> CGFloat {
        guard snapping(event), let g = nearestSnap(y, span: span, vertical: false) else { return y }
        guides.append((false, g))
        return g.pos
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    /// 两个角拼成选区，四边取整到 pt
    private static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        let x0 = min(a.x, b.x).rounded(), x1 = max(a.x, b.x).rounded()
        let y0 = min(a.y, b.y).rounded(), y1 = max(a.y, b.y).rounded()
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    // MARK: 画

    private static func fade(_ layers: [CALayer], to v: Float, duration: CFTimeInterval) {
        for l in layers where l.opacity != v {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = l.presentation()?.opacity ?? l.opacity
            a.toValue = v
            a.duration = duration
            l.opacity = v
            l.add(a, forKey: "fade")
        }
    }

    private func updateLayers() {
        guard !counting else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let s = selection {
            outlineDark.path = CGPath(rect: s, transform: nil)
            outlineLight.path = CGPath(rect: s, transform: nil)
        }
        updateDim(animated: false)
        // 虚线框淡入淡出；窗口、整个屏幕不画虚线框
        let visible = selection != nil
        if visible != shownSelection { shownSelection = visible }
        let scanMode = session?.mode == .text
        // 选区的边是那圈光，不再画虚线框
        Self.fade([outlineDark, outlineLight], to: 0, duration: visible ? 0.12 : 0.16)
        // 新画框的时候不显示手柄，松手后才出现；窗口、整个屏幕没有手柄
        var showHandles = selection != nil && kind == .area && !scanMode && annotator.tool == nil
        if case .new = drag { showHandles = false }
        annotator.clip(to: selection)
        beautyPreview.update(selection: beautyOn ? selection : nil, corner: beautyCorner, style: beautyStyle, image: frozen,
                             // 只有开了背景、选的是壁纸才去拿（以前拖选区时每一下都去查一次桌面壁纸）
                             wallpaper: beautyOn && beautyStyle.background == .wallpaper ? wallpaper : nil)
        // 美化时不要选区那圈光、橙线：背景本身就是框
        for l in [ring, halo.layer] { l.isHidden = beautyOn }
        glow?.layer.isHidden = beautyOn
        for (h, l) in zip(Handle.allCases, handleLayers) {
            l.isHidden = !showHandles
            if let s = selection { l.position = h.point(in: s) }
        }
        let gp = CGMutablePath()
        if let s = selection {
            for (vertical, g) in guides {
                if vertical {
                    gp.move(to: CGPoint(x: g.pos, y: min(g.from, s.minY)))
                    gp.addLine(to: CGPoint(x: g.pos, y: max(g.to, s.maxY)))
                } else {
                    gp.move(to: CGPoint(x: min(g.from, s.minX), y: g.pos))
                    gp.addLine(to: CGPoint(x: max(g.to, s.maxX), y: g.pos))
                }
            }
        }
        // 参考线：出现时淡入，消失时淡出（留着原来的线淡出，不是一下没了）
        if !guides.isEmpty {
            guide.path = gp
            if guide.layer.opacity < 1 { Motion.fade(guide.layer, to: 1, duration: 0.08) }
        } else if guide.layer.opacity > 0 {
            Motion.fade(guide.layer, to: 0, duration: 0.14)
        }
        CATransaction.commit()
        if scanBar == nil { followGlow() }
        layoutBadge()
    }

    /// 尺寸标签放在选区左上角上方；上面放不下（贴着菜单栏）就放进选区里面。整个屏幕放在左上角菜单栏下面。
    /// 窗口模式下还没选中时，跟着鼠标停着的窗口走（名字加尺寸），和选中后一样，换窗口时跟着高亮一起滑过去
    private func layoutBadge(animated: Bool = false) {
        let s: CGRect
        let hoverBadge = selection == nil && mode == .window && hover != nil && drag == nil
        if let sel = selection {
            s = sel
            if kind == .area { badge.show(sel.size, editable: drag == nil) } else { badge.showLabel(label, size: sel.size) }
        } else if hoverBadge, let w = hover {
            s = w.rect.intersection(bounds)
            badge.showLabel(w.label, size: w.rect.size)
        } else { fadeOutBadge(); badgeFollowsHover = false; return }
        // 正在淡掉的也当作已经没了：在新位置直接淡出来，不从旧位置滑过去
        let wasHidden = badge.isHidden || badgeFading
        if badgeFading, let l = badge.layer {
            badgeFadeToken += 1
            badgeFading = false
            l.removeAnimation(forKey: "fade")
            CATransaction.begin(); CATransaction.setDisableActions(true); l.opacity = 1; CATransaction.commit()
        }
        badgeFollowsHover = hoverBadge
        badge.clickThrough = hoverBadge
        let w = badge.width, h = SelectionBadge.height
        let top = window?.screen.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 0
        let ceiling = bounds.height - top - 4
        var x: CGFloat, y: CGFloat
        let windowLike = hoverBadge || kind == .window
        // 窗口：放在窗口里面的左上角。离边的距离跟着窗口的圆角走（窗口圆角减标签自己的圆角），两个圆角是同心的，
        // 看起来就是贴着圆角放进去的；窗口太小放不下才放到外面
        let corner = hoverBadge ? (hover?.corner ?? 0) : (selectedWindow?.corner ?? 0)
        let inset = max(8, corner - SelectionBadge.cornerRadius + 2)
        let fitsInside = s.width >= w + inset * 2 && s.height >= h + inset * 2 + 12
        if windowLike && fitsInside {
            x = s.minX + inset; y = min(s.maxY, ceiling) - inset - h
        } else if kind == .screen {
            x = s.minX + 10; y = min(s.maxY, ceiling) - h - 10
        } else {
            x = s.minX; y = s.maxY + 8
            if y + h > ceiling { x = s.minX + 10; y = min(s.maxY, ceiling) - h - 10 }
        }
        x = min(max(x, 8), bounds.width - w - 8)
        y = max(y, 8)
        let f = CGRect(x: x.rounded(), y: y.rounded(), width: w, height: h)
        // 和高亮用同一条弹簧：只挪位置（图层直接动），宽度直接换，玻璃不用每一帧重新排版
        let from = badge.layer?.presentation()?.position ?? badge.layer?.position
        badge.frame = f
        if animated, !wasHidden, let l = badge.layer, let from, from != l.position {
            l.add(Motion.spring("position", from: NSValue(point: from), to: NSValue(point: l.position)), forKey: "glide")
        } else if wasHidden, let l = badge.layer {
            // 出现：淡入。刚打开截图界面时和高亮一起晚一点出来
            let a = Motion.spring("opacity", from: 0, to: 1)
            if opening { a.beginTime = CACurrentMediaTime() + 0.12; a.fillMode = .backwards }
            l.add(a, forKey: "appear")
        }
        badge.isHidden = false
        if drag == nil, selection != nil { layoutActionBar() }
    }
    /// 标签淡掉（鼠标离开窗口、换模式、取消选区）
    private var badgeFading = false
    private var badgeFadeToken = 0
    private func fadeOutBadge() {
        guard !badge.isHidden, !badgeFading, let l = badge.layer else { badge.isHidden = true; return }
        badgeFading = true
        badgeFadeToken += 1
        let token = badgeFadeToken
        Motion.fade(l, to: 0, duration: 0.12)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) { [weak self] in
            guard let self, self.badgeFadeToken == token else { return }
            self.badgeFading = false
            self.badge.isHidden = true
            CATransaction.begin(); CATransaction.setDisableActions(true); l.opacity = 1; CATransaction.commit()
        }
    }
    /// 标签现在是跟着鼠标停着的窗口（只是看看，点它等于点那个窗口）
    private var badgeFollowsHover = false

    /// 遮罩：整个屏幕暗一点，亮出选区。选中整个屏幕时不暗。
    /// 窗口模式（鼠标停着的、或者选中的窗口）用 spotlight，换窗口时整块一起滑过去；框选用挖洞的形状（拖的时候每次都变，不用动画）
    private func updateDim(animated: Bool) {
        // 扫描认出码后，暗层由 focusScan 管
        guard !counting, scanHole == nil else { return }
        let hole = usesSpotlight ? spotHole : nil
        // 整块暗的那层：框选时挖掉选区，其他时候整块都暗
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let p = CGMutablePath()
        p.addRect(bounds)
        if let s = selection, kind == .area { p.addPath(CGPath(rect: s, transform: nil)) }
        dim.path = p
        CATransaction.commit()
        // 窗口亮出来的那层：从一个窗口换到另一个时滑过去；鼠标离开窗口时就停在原地淡掉（窗口和外面一样暗），
        // 下次停到窗口上时直接在那个窗口上淡出来，不会从一个点张开、也不会缩回一个点
        if hole != nil { layoutSpotlight(glide: animated && holeShown) }
        holeShown = hole != nil
        let screenSelected = selection != nil && kind == .screen
        let spotTo: Float = hole != nil && !screenSelected ? 1 : 0
        let dimTo: Float = screenSelected || spotTo == 1 ? 0 : 1
        // 两层一样暗，交替时用同一条曲线，外面的暗度一直不变，只有窗口那块慢慢变亮或变暗
        Motion.fade(dim, to: dimTo, duration: 0.16, curve: .easeInEaseOut)
        Motion.fade(spotlight, to: spotTo, duration: 0.16, curve: .easeInEaseOut)
        let delay = spotTo == 1 && opening ? 0.12 : 0
        Motion.fade(ring, to: spotTo, duration: spotTo == 1 ? 0.12 : 0.14, delay: delay)
        Motion.fade(halo.layer, to: spotTo, duration: spotTo == 1 ? 0.18 : 0.14, delay: delay)
    }
    /// 现在亮着一个窗口（换窗口时才滑过去；从没有窗口到有窗口是直接在那里淡出来）
    private var holeShown = false

    /// 窗口模式：用 spotlight 和橙线
    private var usesSpotlight: Bool {
        if let _ = selection { return kind == .window }
        return mode == .window
    }

    /// spotlight 中间亮出来的那块：选中的窗口，或者鼠标停着的窗口
    private var spotHole: (rect: CGRect, corner: CGFloat)? {
        if let s = selection, kind == .window { return (s, min(selectedWindow?.corner ?? 0, s.width / 2, s.height / 2)) }
        guard selection == nil, let w = hover else { return nil }
        let r = w.rect.intersection(bounds)
        return (r, min(w.corner, r.width / 2, r.height / 2))
    }

    /// 放 spotlight、橙线、光晕到现在亮着的窗口上。glide：从上一个窗口滑过去；否则直接放到位
    private func layoutSpotlight(glide: Bool) {
        guard let hole = spotHole else { return }
        let r = hole.rect, c = hole.corner
        let pad = Self.spotPad
        Motion.move(spotlight, frame: r.insetBy(dx: -pad, dy: -pad), corner: c + pad, animated: glide)
        // 橙线贴在窗口外面，不压住窗口的边；贴着屏幕边的那几边收进来，不被屏幕边切掉
        let rw = Self.ringWidth
        let rr = r.insetBy(dx: -rw, dy: -rw).intersection(bounds.insetBy(dx: 0.5, dy: 0.5))
        Motion.move(ring, frame: rr.isNull ? r : rr, corner: c > 0 ? c + rw : 0, animated: glide)
        halo.move(to: r, corner: c, animated: glide, clamp: bounds)
    }

    /// 暗的程度（框选的遮罩和窗口模式的 spotlight 一样）
    static let dimColor = NSColor(white: 0, alpha: 0.28)
    /// spotlight 的边宽：比屏幕对角线还宽，外面那圈圆角才不会露出来
    static let spotPad: CGFloat = 6000
    static let ringWidth: CGFloat = 2


    /// 窗口模式下鼠标停着的窗口：外面变暗，窗口外面描一圈橙线，左上角写名字和尺寸。
    /// 换窗口时三样用同一条弹簧一起滑过去
    private func setHover(_ w: ScreenWindow?) {
        guard w?.id != hover?.id else { return }
        hover = w
        updateDim(animated: true)
        layoutBadge(animated: true)
    }

    /// 窗口模式、还没选中东西、鼠标不在选择条上时，高亮鼠标下面的窗口
    func refreshHover(at point: CGPoint? = nil) {
        let p = point ?? window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) } ?? .zero
        // 用键盘换过窗口：鼠标真的动了（超过几个点）才跟回鼠标
        if let k = keyboardHoverAt {
            if hypot(p.x - k.x, p.y - k.y) < 4, mode == .window, selection == nil { return }
            keyboardHoverAt = nil
        }
        guard mode == .window, selection == nil, drag == nil, bounds.contains(p) else { setHover(nil); return }
        // 在选择条、操作条上：保持刚才的高亮，不闪
        if overBar(p) || overActionBar(p) { return }
        setHover(screenWindow(at: p))
    }

    /// 用键盘换窗口时鼠标在哪（鼠标没动就一直用键盘选的）
    private var keyboardHoverAt: CGPoint?

    /// 窗口模式、还没选中：Tab / ⇧Tab 按从前到后换窗口，方向键跳到那个方向最近的窗口
    func keyboardHover(_ key: UInt16, backwards: Bool) -> Bool {
        guard mode == .window, selection == nil, drag == nil else { return false }
        let list = ScreenWindows.usable(windows).filter { $0.rect.intersects(bounds) }
        guard !list.isEmpty else { return false }
        let current = hover.flatMap { h in list.firstIndex { $0.id == h.id } }
        var next: ScreenWindow?
        if key == 48 { // Tab
            let i = current.map { ($0 + (backwards ? -1 : 1) + list.count) % list.count } ?? (backwards ? list.count - 1 : 0)
            next = list[i]
        } else {
            // 方向键：从现在高亮的窗口（没有就从鼠标）出发，找那个方向上最近的窗口中心。
            // 偏离方向的距离算得重一点，按"右"就真的往右，不会跳到右下角很远的那个
            let from = hover.map { CGPoint(x: $0.rect.intersection(bounds).midX, y: $0.rect.intersection(bounds).midY) }
                ?? window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) } ?? .zero
            let dir: CGVector = [123: CGVector(dx: -1, dy: 0), 124: CGVector(dx: 1, dy: 0), 125: CGVector(dx: 0, dy: -1), 126: CGVector(dx: 0, dy: 1)][key] ?? .zero
            var best: (ScreenWindow, CGFloat)?
            for w in list where w.id != hover?.id {
                let r = w.rect.intersection(bounds)
                let dx = r.midX - from.x, dy = r.midY - from.y
                let along = dx * dir.dx + dy * dir.dy
                guard along > 8 else { continue }
                let across = abs(dx * dir.dy - dy * dir.dx)
                let score = along + across * 2
                if best == nil || score < best!.1 { best = (w, score) }
            }
            next = best?.0
        }
        guard let next else { NSSound.beep(); return true }
        keyboardHoverAt = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
        setHover(next)
        setCursor(CaptureCursor.camera, "camera")
        return true
    }

    /// 选择条换了模式
    func modeChanged() {
        refreshHover()
        updateLoupe(at: nil)
        if let w = window { updateCursor(at: convert(w.mouseLocationOutsideOfEventStream, from: nil)) }
    }

    /// 鼠标下面最前面的那个窗口（只看量过的、或者普通窗口）
    private func screenWindow(at p: CGPoint) -> ScreenWindow? { ScreenWindows.usable(windows).first { $0.rect.contains(p) } }

    /// 在尺寸标签里改了数字：左上角不动
    private func resizeFromBadge(_ size: CGSize) {
        guard let s = selection else { return }
        let w = min(size.width, bounds.width), h = min(size.height, bounds.height)
        let x = min(s.minX, bounds.width - w)
        let y = max(0, s.maxY - h)
        selection = CGRect(x: x, y: y, width: w, height: h)
        updateLayers()
    }

    // MARK: 键盘

    override func keyDown(with event: NSEvent) {
        if session?.keyDown(event) != true { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { session?.cancel() }
    override func flagsChanged(with event: NSEvent) {
        session?.modifiersChanged(event.modifierFlags)
        // 画到一半按下或松开 Shift：马上换成吸 45°、正方形、直线（以前要再动一下鼠标才变）
        if case .annotate = drag, let w = window {
            let p = convert(w.mouseLocationOutsideOfEventStream, from: nil)
            annotator.move(to: CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height)),
                           shift: event.modifierFlags.contains(.shift))
        }
    }

    /// 方向键：移动选区（⇧ 一次 10pt）；按住 ⌥ 改大小（右边和下边动）。只对自由框选有用
    func nudge(_ event: NSEvent) -> Bool {
        guard var s = selection, kind == .area, drag == nil else { return false }
        let d: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        let resize = event.modifierFlags.contains(.option)
        switch event.keyCode {
        case 123: if resize { s.size.width = max(4, s.width - d) } else { s.origin.x -= d }
        case 124: if resize { s.size.width += d } else { s.origin.x += d }
        case 125: if resize { s.origin.y -= d; s.size.height += d } else { s.origin.y -= d }
        case 126: if resize { s.origin.y += d; s.size.height = max(4, s.height - d) } else { s.origin.y += d }
        default: return false
        }
        if resize {
            s = s.intersection(bounds)
        } else {
            s.origin.x = min(max(s.origin.x, 0), bounds.width - s.width)
            s.origin.y = min(max(s.origin.y, 0), bounds.height - s.height)
        }
        selection = s
        updateLayers()
        return true
    }

    // MARK: 光标

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        refreshHover(at: p)
        updateCursor(at: p)
        updateLoupe(at: p)
    }
    override func mouseExited(with event: NSEvent) { setHover(nil); loupe.isHidden = true }

    private func setCursor(_ c: NSCursor, _ name: String) {
        c.set()
        cursorName = name
    }

    private func updateCursor(at p: CGPoint) {
        if overBar(p) || overActionBar(p) { setCursor(.arrow, "arrow"); return }
        if overBadge(p) { cursorName = "badge"; return } // 数字框自己管光标
        if annotating, let s = selection {
            if !s.contains(p) { setCursor(.arrow, "arrow"); return }
            if let i = annotator.hit(p) {
                if annotator.items[i].tool == .text && annotator.tool == .text { setCursor(.iBeam, "iBeam") }
                else { setCursor(.openHand, "openHand") }
                return
            }
            if annotator.tool == .text { setCursor(.iBeam, "iBeam"); return }
            setCursor(.crosshair, "crosshair")
            return
        }
        if let s = selection, kind == .area {
            if let h = handle(at: p, in: s) {
                setCursor(NSCursor.frameResize(position: h.cursorPosition, directions: .all), "resize:\(h)")
                return
            }
            if s.contains(p) { setCursor(.openHand, "openHand"); return }
        }
        if mode == .window, selection == nil, hover != nil { setCursor(CaptureCursor.camera, "camera"); return }
        setCursor(.crosshair, "crosshair")
    }

    /// 鼠标在不在某个手柄上（角和边都算，留 8pt 余量）
    private func handle(at p: CGPoint, in s: CGRect) -> Handle? {
        // 很小的选区（不到 16 点）：里面全被把手占了，只能调大小、挪不动。在里面时把手只占边上四分之一
        let t: CGFloat = s.contains(p) ? min(8, max(2, min(s.width, s.height) / 4)) : 8
        guard s.insetBy(dx: -8, dy: -8).contains(p) else { return nil }
        let l = abs(p.x - s.minX) <= t, r = abs(p.x - s.maxX) <= t
        let b = abs(p.y - s.minY) <= t, top = abs(p.y - s.maxY) <= t
        if top && l { return .topLeft }
        if top && r { return .topRight }
        if b && l { return .bottomLeft }
        if b && r { return .bottomRight }
        if top { return .top }
        if b { return .bottom }
        if l { return .left }
        if r { return .right }
        return nil
    }

    // MARK: 调试

    var debugState: String {
        let sel = selection.map { "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width)),\(Int($0.height))" } ?? "none"
        let fr = window?.firstResponder.map { "\(type(of: $0))" } ?? "nil"
        return "sel=\(sel) kind=\(kind) hover=\(hover.map { "\($0.label)" } ?? "none")"
            + " handles=\(!(handleLayers.first?.isHidden ?? true)) badge=\(badge.isHidden ? "hidden" : badge.debugText)"
            + " dim=\(max(dim.opacity, spotlight.opacity)) outline=\(outlineLight.opacity) hoverRing=\(ring.opacity)"
            + " key=\(window?.isKeyWindow ?? false) fr=\(fr) cursor=\(cursorName) scanning=\(isScanning)"
            + " live=\(isLive) stale=\(snapshotStale) opaque=\(window?.isOpaque ?? false) passThrough=\(window?.ignoresMouseEvents ?? false)"
            + " countdown=\(debugCountdown) loupe=\(loupe.isHidden ? "hidden" : (loupe.hex ?? "?")) output=\(output != nil) snapTaps=\(snapTaps) pressed=\(pressed)"
            + " frozenHDR=\(frozenHDR != nil)"
            + " windows=\(ScreenWindows.usable(windows).count)/\(windows.count) verified=\(windows.filter(\.verified).count)"
    }

    func debugPoint(_ name: String) -> CGPoint? {
        if name.hasPrefix("handle:"), let s = selection {
            let n = String(name.dropFirst(7))
            return Handle.allCases.first { "\($0)" == n }?.point(in: s)
        }
        if name == "sel:center", let s = selection { return CGPoint(x: s.midX, y: s.midY) }
        if name == "badge:w" { return badge.fieldCenter(0, in: self) }
        if name == "badge:h" { return badge.fieldCenter(1, in: self) }
        if name.hasPrefix("bar:"), let bar, let c = bar.debugCenter(String(name.dropFirst(4))) {
            return bar.convert(c, to: self)
        }
        if name.hasPrefix("action:"), let ab = actionBar, ab.superview === self, let c = ab.debugCenter(String(name.dropFirst(7))) {
            return ab.convert(c, to: self)
        }
        return nil
    }

    /// 模拟一次拖动（这块屏幕上的坐标），release = false 时不松手，吸附线会留在屏幕上
    func debugDrag(from a: CGPoint, to b: CGPoint, release: Bool) {
        guard let w = window else { return }
        func ev(_ t: NSEvent.EventType, _ p: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: t, location: convert(p, to: nil), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: t == .leftMouseUp ? 0 : 1)
        }
        if let e = ev(.leftMouseDown, a) { mouseDown(with: e) }
        for i in 1...12 {
            let t = CGFloat(i) / 12
            if let e = ev(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)) { mouseDragged(with: e) }
        }
        if release, let e = ev(.leftMouseUp, b) { mouseUp(with: e) }
    }
}

extension CaptureOverlayView.Handle {
    func point(in r: CGRect) -> CGPoint {
        switch self {
        case .bottomLeft: return CGPoint(x: r.minX, y: r.minY)
        case .bottom: return CGPoint(x: r.midX, y: r.minY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.minY)
        case .right: return CGPoint(x: r.maxX, y: r.midY)
        case .topRight: return CGPoint(x: r.maxX, y: r.maxY)
        case .top: return CGPoint(x: r.midX, y: r.maxY)
        case .topLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .left: return CGPoint(x: r.minX, y: r.midY)
        }
    }
    var movesLeft: Bool { self == .bottomLeft || self == .topLeft || self == .left }
    var movesRight: Bool { self == .bottomRight || self == .topRight || self == .right }
    var movesBottom: Bool { self == .bottomLeft || self == .bottomRight || self == .bottom }
    var movesTop: Bool { self == .topLeft || self == .topRight || self == .top }
    var cursorPosition: NSCursor.FrameResizePosition {
        switch self {
        case .bottomLeft: return .bottomLeft
        case .bottom: return .bottom
        case .bottomRight: return .bottomRight
        case .right: return .right
        case .topRight: return .topRight
        case .top: return .top
        case .topLeft: return .topLeft
        case .left: return .left
        }
    }
}
