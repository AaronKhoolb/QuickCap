import AppKit
import QuartzCore

/// 截好的图在屏幕中间接着画：滚动截图拼好以后（review），或者从截图架上把一张拿下来改（edit）。
/// 和截图时是同一根第二条（画画、背景、撤销），画的东西用图的坐标（pt），图和画的东西一起放大缩小、拖动。
/// 长图一开始缩到整张都看得见（太长的话按能看清的宽度，上下滚）；捏合、⌘ 滚轮放大，两指滑动、拖动挪
@MainActor
final class ImageEditor {
    enum Mode { case review, edit }

    /// 现在开着的那一个（同时只开一个）
    private(set) static var current: ImageEditor?

    let mode: Mode
    let image: CGImage
    let hdr: CGImage?
    /// 每 pt 几个像素（截图时屏幕的倍数）
    let scale: CGFloat
    let screen: NSScreen
    let headroom: CGFloat
    /// edit：改的是截图架上哪个文件
    let fileURL: URL?
    let settings: AppSettings

    /// review：按 Capture（出好的图、从屏幕上哪里飞出去）
    var onCapture: ((CapturedImage, ActionBar.Output) -> Void)?
    /// edit：存回原来那张（出好的图、HDR 图）
    var onReplace: ((CGImage, CGImage?) -> Void)?
    /// edit：另存一张新的（和截好的新图一样交出去）
    var onSaveAsNew: ((CapturedImage) -> Void)?
    /// 怎么关掉的
    enum Outcome { case cancelled, captured, replaced, savedAsNew(returned: Bool) }
    /// 关掉了（收起来的动画做完）
    var onClose: ((Outcome) -> Void)?
    /// edit：卡片现在在屏幕上的哪里（收回去时缩到那里）。给了像素大小：存回去以后卡片按新的大小算
    var cardFrame: ((CGSize?) -> CGRect?)?
    /// 截图架那边"截图飞到哪里"
    var flightTarget: ((NSScreen) -> CGPoint?)?
    /// 关掉后焦点还给它（打开前在前面的 app）
    var returnApp: NSRunningApplication?
    /// 收起来的动画做完后、窗口拿走之前等一下（存回去的图还在写，卡片换好了再拿走，中间不会空一下）
    var closeGate: ((@escaping () -> Void) -> Void)?
    /// 从哪里出来、回到哪里去的那块是圆角的（截图架上的卡片）
    var sourceCorner: CGFloat = 0

    private let window: EditorWindow
    let view: EditorView

    /// fromRect：从屏幕上哪里出来（滚动截图的选区、截图架上的卡片）
    /// 滚动截图截的是一个窗口：出图时和截窗口一样，圆角（窗口自己的）+ 窗口影子（按设置，⌥ 反过来）。
    /// 开了背景就用背景的影子，不再加窗口影子
    struct WindowLook { let corner: CGFloat; let shadow: Bool }
    let windowLook: WindowLook?

    init(mode: Mode, image: CGImage, hdr: CGImage?, scale: CGFloat, screen: NSScreen, headroom: CGFloat,
         fileURL: URL? = nil, windowLook: WindowLook? = nil, settings: AppSettings) {
        self.windowLook = windowLook
        self.mode = mode
        self.image = image
        self.hdr = hdr
        self.scale = scale
        self.screen = screen
        self.headroom = headroom
        self.fileURL = fileURL
        self.settings = settings
        window = EditorWindow(screen: screen)
        view = EditorView(frame: CGRect(origin: .zero, size: screen.frame.size), image: image, hdr: hdr, scale: scale,
                          screen: screen, settings: settings, kind: mode == .review ? .review : .edit, windowLook: windowLook)
        window.contentView = view
        view.editor = self
    }

    /// 出来：从 fromRect 放大到屏幕中间，背后慢慢变暗，条从下面弹出来
    func present(from fromRect: CGRect) {
        ImageEditor.current?.close(animated: false)
        ImageEditor.current = self
        if !BackgroundCursor.enabled { NSApp.activate() }
        window.alphaValue = 1
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        let local = fromRect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        view.appear(from: local, corner: sourceCorner)
    }

    /// 又按了截图快捷键：把编辑器叫回前面，键盘还给它
    func bringToFront() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    /// 收起来。toRect 给了就缩回那里（截图架上的卡片），没给就原地淡掉
    func close(animated: Bool, to toRect: CGRect? = nil, outcome: Outcome = .cancelled) {
        guard ImageEditor.current === self else { return }
        ImageEditor.current = nil
        // 收起来的动画做完之前不能放掉（current 已经清了）：这里先拿着
        let finish = {
            self.window.orderOut(nil)
            self.window.contentView = nil
            if NSApp.isActive, let app = self.returnApp, !app.isTerminated { app.activate() }
            self.onCapture = nil
            self.onReplace = nil
            self.onSaveAsNew = nil
            self.closeGate = nil
        }
        // 先告诉外面（卡片挂回去），再看要不要等，最后拿走窗口
        let done = {
            self.onClose?(outcome)
            self.onClose = nil
            if let gate = self.closeGate { gate { finish() } } else { finish() }
        }
        guard animated else { done(); return }
        let local = toRect.map { $0.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) }
        view.disappear(to: local, corner: sourceCorner) { done() }
    }

    // MARK: 出图

    /// 画的东西、背景都画进去（普通图和 HDR 图一样做）
    func render() -> (CGImage, CGImage?) {
        let page = CGRect(origin: .zero, size: view.pageSize)
        let items = view.annotator.items
        let corner = windowLook?.corner ?? BeautyLayout.shotCorner
        func one(_ img: CGImage) -> CGImage {
            var out = items.isEmpty ? img : (AnnotationRenderer.render(items, onto: img, imageRect: page, clip: page) ?? img)
            if view.beautyOn {
                out = BeautyRenderer.compose(out, imageRect: page, selection: page, corner: corner,
                                             style: view.beautyStyle, wallpaper: view.wallpaper) ?? out
            } else if let w = windowLook {
                out = WindowLookRenderer.render(out, corner: w.corner, shadow: w.shadow, scale: scale) ?? out
            }
            return out
        }
        return (one(image), hdr.map(one))
    }

    /// 出好的图现在在屏幕上的哪里（开着背景的话是整块背景）
    func outputScreenRect() -> CGRect {
        let page = CGRect(origin: .zero, size: view.pageSize)
        var r = view.beautyOn ? BeautyLayout.frame(for: page, style: view.beautyStyle) : page
        if !view.beautyOn, let w = windowLook, w.shadow { r = WindowLookRenderer.insets.expand(r) }
        return view.pageToView(r).offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
    }

    /// 主按钮
    func primary(_ out: ActionBar.Output? = nil, save: ActionBar.EditSave? = nil, pin: Bool = false) {
        view.commitText()
        let (img, h) = render()
        switch mode {
        case .review:
            var c = CapturedImage(image: img, screenRect: outputScreenRect(), scale: scale, hdr: h, screenHeadroom: headroom)
            c.pinned = pin
            if let target = flightTarget?(screen), !ReduceMotion.isOn {
                let f = CaptureFlight(image: img, hdr: h, rect: outputScreenRect(), corner: 0, screen: screen)
                f.lift(toward: target, pixelSize: CGSize(width: img.width, height: img.height))
                c.flight = f
            }
            onCapture?(c, out ?? (settings.captureCopy ? .saveAndCopy : .save))
            close(animated: true, to: nil, outcome: .captured)
        case .edit:
            let how = save ?? ActionBar.EditSave.last
            if how == .replace {
                onReplace?(img, h)
                close(animated: true, to: cardFrame?(CGSize(width: img.width, height: img.height)), outcome: .replaced)
            } else {
                var c = CapturedImage(image: img, screenRect: outputScreenRect(), scale: scale, hdr: h, screenHeadroom: headroom)
                if let target = flightTarget?(screen), !ReduceMotion.isOn {
                    let f = CaptureFlight(image: img, hdr: h, rect: outputScreenRect(), corner: 0, screen: screen)
                    f.lift(toward: target, pixelSize: CGSize(width: img.width, height: img.height))
                    c.flight = f
                }
                onSaveAsNew?(c)
                // 新的那张从这里飞上截图架，原来那张不动、在原来的位置慢慢出现；不飞的话就缩回原来的位置
                let back = c.flight == nil
                close(animated: true, to: back ? cardFrame?(nil) : nil, outcome: .savedAsNew(returned: back))
            }
        }
    }

    /// 编辑时按 ⌘C：把现在画好的样子复制到剪贴板，不存、不关（以前会走"保存"那条路，默认直接覆盖原图）
    func copyRendered() {
        view.commitText()
        let (img, _) = render()
        let k = scale
        let r = outputScreenRect()
        let image = img
        Task.detached(priority: .userInitiated) {
            let png = CaptureOutput.pngData(image, scale: k)
            await MainActor.run {
                guard let png else { NSSound.beep(); return }
                CaptureOutput.copy(png: png)
                CaptureToast.show("Copied", at: CGPoint(x: r.midX, y: r.midY))
            }
        }
    }

    /// 不要了（review：这张长图不要了；edit：不改，挂回去）
    func cancel() {
        close(animated: true, to: mode == .edit ? cardFrame?(nil) : nil)
    }
}

/// 编辑时的窗口：盖满这块屏幕，在截图架上面
final class EditorWindow: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: CaptureOverlayWindow.captureLevel.rawValue)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        animationBehavior = .none
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        setFrame(screen.frame, display: false)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 编辑的画布：背后一层暗的；中间是图（和画的东西、背景一起放在 content 里，一起缩放、挪动）；下面是第二条
@MainActor
final class EditorView: NSView {
    weak var editor: ImageEditor?
    let pageSize: CGSize
    let annotator: Annotator
    private let settings: AppSettings
    private let screenRef: NSScreen
    private let dim = CALayer()
    /// 装着图和影子：长图超出屏幕可见范围时，上下边缘渐隐（像系统里内容从玻璃条下面滚过去）
    private let stage = CALayer()
    private let stageMask = CAGradientLayer()
    private let shadowLayer = CALayer()
    private let content = CALayer()
    private let imageLayer = CALayer()
    private let preview: BeautyPreview
    private(set) var beautyOn = false
    private(set) var beautyStyle = BeautyStyle.load()
    var wallpaper: CGImage? { BeautyBackground.wallpaper(for: screenRef) }

    let actionBar: ActionBar
    private let styleBar = AnnotationStyleBar()
    private var beautyBar: BeautyBar?
    private var textEditor: TextAnnotationEditor?
    private let zoomPill = NSTextField(labelWithString: "")
    private let scrollKnob = CALayer()
    private var pillHide: DispatchWorkItem?

    /// 现在放多大、图的左下角在哪（视图坐标）
    private(set) var zoom: CGFloat = 1
    private var origin = CGPoint.zero

    private enum Drag { case draw, move, pan(start: CGPoint, origin: CGPoint) }
    private var drag: Drag?

    private let windowLook: ImageEditor.WindowLook?
    /// 不开背景时图的圆角（窗口自己的圆角；别的是直角）
    private var plainCorner: CGFloat { windowLook?.corner ?? 0 }
    private var shotCorner: CGFloat { windowLook?.corner ?? BeautyLayout.shotCorner }

    init(frame: CGRect, image: CGImage, hdr: CGImage?, scale: CGFloat, screen: NSScreen, settings: AppSettings, kind: ActionBar.Kind,
         windowLook: ImageEditor.WindowLook? = nil) {
        self.windowLook = windowLook
        pageSize = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let page = CGRect(origin: .zero, size: pageSize)
        annotator = Annotator(bounds: page)
        preview = BeautyPreview(bounds: page)
        self.settings = settings
        screenRef = screen
        actionBar = ActionBar(settings: settings, kind: kind)
        super.init(frame: frame)
        wantsLayer = true
        let root = layer!
        dim.frame = bounds
        dim.backgroundColor = NSColor(white: 0, alpha: 0.42).cgColor
        dim.opacity = 0
        root.addSublayer(dim)
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0
        shadowLayer.shadowRadius = 26
        shadowLayer.shadowOffset = CGSize(width: 0, height: -12)
        stage.frame = bounds
        root.addSublayer(stage)
        stageMask.frame = bounds
        stage.addSublayer(shadowLayer)
        content.anchorPoint = .zero
        content.bounds = page
        stage.addSublayer(content)
        imageLayer.frame = page
        imageLayer.contents = hdr ?? image
        if hdr != nil { imageLayer.preferredDynamicRange = .high }
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        imageLayer.cornerCurve = .continuous
        if let w = windowLook, w.corner > 0 { imageLayer.cornerRadius = w.corner; imageLayer.masksToBounds = true }
        // 背景开着时：预览铺背景和影子，图还是这一层（圆角裁好），HDR 也照样亮
        content.addSublayer(preview.layer)
        content.addSublayer(imageLayer)
        // 画的东西按 2 倍画（放大一点也清楚）
        annotator.scale = screen.backingScaleFactor * 2
        annotator.clip(to: page)
        content.addSublayer(annotator.layer)
        annotator.onChange = { [weak self] in self.map { $0.actionBar.setCanUndo($0.annotator.canUndo) } }
        annotator.onSelect = { [weak self] in self?.refreshStyleBar() }
        // 长图滚动时右边一条细的位置条
        scrollKnob.backgroundColor = NSColor(white: 1, alpha: 0.7).cgColor
        scrollKnob.cornerRadius = 2.5
        scrollKnob.opacity = 0
        scrollKnob.shadowColor = NSColor.black.cgColor
        scrollKnob.shadowOpacity = 0.3
        scrollKnob.shadowRadius = 2
        scrollKnob.shadowOffset = .zero
        root.addSublayer(scrollKnob)
        updateStageMask()
        zoomPill.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        zoomPill.textColor = .white
        zoomPill.alignment = .center
        zoomPill.wantsLayer = true
        zoomPill.layer?.backgroundColor = ReduceTransparency.chip(0.5)
        zoomPill.layer?.cornerRadius = 9
        zoomPill.alphaValue = 0
        addSubview(zoomPill)

        actionBar.onCancel = { [weak self] in self?.editor?.cancel() }
        actionBar.onRun = { [weak self] out in self?.editor?.primary(out) }
        actionBar.onEditSave = { [weak self] how in self?.editor?.primary(save: how) }
        actionBar.onTool = { [weak self] t in self?.selectTool(t) }
        // 正在打字时先收尾：撤销会挪动标注的序号，打字框按旧序号写回会写到别的标注上
        actionBar.onUndo = { [weak self] in self?.commitText(); self?.annotator.undo() }
        actionBar.onBeauty = { [weak self] in self?.toggleBeauty() }
        actionBar.onPin = { [weak self] in self?.editor?.primary(pin: true) }
        actionBar.onResize = { [weak self] in self?.layoutBars() }
        addSubview(actionBar)
        styleBar.onColor = { [weak self] i in self?.setColor(i) }
        styleBar.onWidth = { [weak self] i in self?.setWidth(i) }
        addSubview(styleBar)
        let (z, o) = initialLayout()
        zoom = z; origin = o
        apply(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    // MARK: 位置、缩放

    /// 图能放的地方：屏幕可见范围，四边留白，下面留给条
    private var avail: CGRect {
        let v = screenRef.visibleFrame.offsetBy(dx: -screenRef.frame.minX, dy: -screenRef.frame.minY)
        return CGRect(x: v.minX + 48, y: v.minY + Self.barSpace, width: v.width - 96, height: v.height - Self.barSpace - 40)
    }

    /// 屏幕底下留给条的高度：第二条（离底 24）+ 上面颜色、背景小条
    private static let barSpace: CGFloat = 132

    /// 要放进来的那块（图的坐标）：开着背景就是整块背景
    private var extent: CGRect {
        if beautyOn { return BeautyLayout.frame(for: pageRect, style: beautyStyle) }
        // 窗口带影子：影子也是出图的一部分，留出位置
        if let w = windowLook, w.shadow { return WindowLookRenderer.insets.expand(pageRect) }
        return pageRect
    }
    /// 影子贴着的那块：背景（开着的话）或者图本身
    private var shadowRect: CGRect { beautyOn ? BeautyLayout.frame(for: pageRect, style: beautyStyle) : pageRect }
    /// 窗口影子（和出图一样）还是"拿起来"的影子
    private var windowShadowOn: Bool { !beautyOn && windowLook?.shadow == true }

    /// 一开始：整块缩进来看得见；长图缩得太小的话按能看清的宽度放，顶对齐，上下滚
    private func initialLayout() -> (CGFloat, CGPoint) {
        let a = avail, e = extent
        let fit = min(a.width / e.width, a.height / e.height, 1)
        // 缩到整块看得见以后太窄（看不清字）：按一个能看清的宽度放，上下滚
        let minWidth = min(e.width, max(360, a.width * 0.45))
        let z = e.width * fit < minWidth - 1 ? min(minWidth / e.width, a.width / e.width, 1) : fit
        let o = clampOrigin(CGPoint(x: a.midX - e.midX * z, y: a.maxY - e.maxY * z), zoom: z)
        return (z, o)
    }

    private var fitZoom: CGFloat { let a = avail, e = extent; return min(a.width / e.width, a.height / e.height, 1) }

    /// 小于能放的地方：居中；大于：不让拖出空白
    private func clampOrigin(_ o: CGPoint, zoom z: CGFloat) -> CGPoint {
        let a = avail, e = extent, w = e.width * z, h = e.height * z
        var vx = o.x + e.minX * z, vy = o.y + e.minY * z
        vx = w <= a.width ? a.midX - w / 2 : min(max(vx, a.maxX - w), a.minX)
        vy = h <= a.height ? a.midY - h / 2 : min(max(vy, a.maxY - h), a.minY)
        return CGPoint(x: (vx - e.minX * z).rounded(), y: (vy - e.minY * z).rounded())
    }

    func pageToView(_ r: CGRect) -> CGRect {
        CGRect(x: origin.x + r.minX * zoom, y: origin.y + r.minY * zoom, width: r.width * zoom, height: r.height * zoom)
    }
    private func pageToView(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x * zoom, y: origin.y + p.y * zoom) }
    private func viewToPage(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - origin.x) / zoom, y: (p.y - origin.y) / zoom) }
    private var pageRect: CGRect { CGRect(origin: .zero, size: pageSize) }
    private var canPan: Bool { extent.width * zoom > avail.width + 1 || extent.height * zoom > avail.height + 1 }

    private func apply(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated {
            CATransaction.setAnimationDuration(0.28)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1))
        }
        content.position = origin
        content.transform = CATransform3DMakeScale(zoom, zoom, 1)
        let r = pageToView(shadowRect)
        shadowLayer.frame = r
        // 窗口影子：和出图时一样的样子（大的散开、往下偏）
        shadowLayer.shadowRadius = windowShadowOn ? 25 * zoom : 26
        shadowLayer.shadowOffset = CGSize(width: 0, height: windowShadowOn ? -22 * zoom : -12)
        // 窗口：影子贴着窗口的圆角；开了背景：背景是直角
        let c = beautyOn ? 0 : plainCorner * zoom
        shadowLayer.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: r.size), cornerWidth: c, cornerHeight: c, transform: nil)
        CATransaction.commit()
        updateScrollKnob()
        updateStageMask()
    }

    /// 可见范围：屏幕可见的地方（菜单栏下面、程序坞上面）上下各留一点
    private var viewport: CGRect {
        let v = screenRef.visibleFrame.offsetBy(dx: -screenRef.frame.minX, dy: -screenRef.frame.minY)
        return CGRect(x: 0, y: v.minY + 10, width: bounds.width, height: v.height - 20)
    }

    /// 超出可见范围的那一边才渐隐（没超出就不遮，影子完整）
    private func updateStageMask() {
        let r = pageToView(extent), vp = viewport
        let overTop = r.maxY > vp.maxY + 0.5, overBottom = r.minY < vp.minY - 0.5
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard overTop || overBottom else { stage.mask = nil; return }
        let H = bounds.height, fade: CGFloat = 28
        func at(_ y: CGFloat) -> NSNumber { NSNumber(value: Double(min(max(y / H, 0), 1))) }
        // 渐变从下往上：0 在底边
        let clear = NSColor.clear.cgColor, solid = NSColor.black.cgColor
        stageMask.startPoint = CGPoint(x: 0.5, y: 0)
        stageMask.endPoint = CGPoint(x: 0.5, y: 1)
        stageMask.colors = [overBottom ? clear : solid, solid, solid, overTop ? clear : solid]
        stageMask.locations = [at(vp.minY), at(vp.minY + fade), at(vp.maxY - fade), at(vp.maxY)]
        if !overBottom { stageMask.locations![0] = 0 }
        if !overTop { stageMask.locations![3] = 1 }
        stage.mask = stageMask
    }

    private func setZoom(_ z: CGFloat, around p: CGPoint, animated: Bool = false) {
        let nz = min(max(z, min(fitZoom, 0.1)), 8)
        let q = viewToPage(p)
        zoom = nz
        origin = clampOrigin(CGPoint(x: p.x - q.x * nz, y: p.y - q.y * nz), zoom: nz)
        apply(animated: animated)
        showPill("\(Int((nz * 100).rounded()))%")
    }

    private func panBy(_ dx: CGFloat, _ dy: CGFloat) {
        origin = clampOrigin(CGPoint(x: origin.x + dx, y: origin.y + dy), zoom: zoom)
        apply(animated: false)
        flashKnob()
    }

    /// 双击空白处：整张看得见 ↔ 100%
    private func toggleZoom(at p: CGPoint) {
        let fit = fitZoom
        setZoom(abs(zoom - fit) < 0.01 ? 1 : fit, around: p, animated: true)
    }

    private func showPill(_ s: String) {
        zoomPill.stringValue = s
        let w: CGFloat = 54, h: CGFloat = 20
        let a = avail
        zoomPill.frame = CGRect(x: a.maxX - w, y: a.maxY - h, width: w, height: h)
        zoomPill.alphaValue = 1
        pillHide?.cancel()
        let job = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.25; self?.zoomPill.animator().alphaValue = 0 }
        }
        pillHide = job
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: job)
    }

    /// 长图：右边一条细的位置条，滚的时候出来，停了淡掉
    private func updateScrollKnob() {
        let v = pageToView(extent), a = avail
        guard v.height > a.height + 1 else { scrollKnob.opacity = 0; return }
        let h = max(28, a.height * a.height / v.height)
        // 0 在顶上，1 在底下
        let t = min(max((v.maxY - a.maxY) / (v.height - a.height), 0), 1)
        let x = min(v.maxX + 8, bounds.width - 10)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        scrollKnob.frame = CGRect(x: x, y: a.maxY - h - (a.height - h) * t, width: 5, height: h)
        CATransaction.commit()
    }

    private var knobHide: DispatchWorkItem?
    private func flashKnob() {
        guard extent.height * zoom > avail.height + 1 else { return }
        scrollKnob.opacity = 1
        knobHide?.cancel()
        let job = DispatchWorkItem { [weak self] in self.map { Motion.fade($0.scrollKnob, to: 0, duration: 0.3) } }
        knobHide = job
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: job)
    }

    // MARK: 出来、收起来

    /// 从 r 放大出来（卡片、选区）：r 比例和图不一样时（长图的卡片、选区）对齐 r 的顶上
    func appear(from r: CGRect, corner: CGFloat = 0) {
        let finalZoom = zoom, finalOrigin = origin
        let z0 = max(0.02, max(r.width / pageSize.width, r.height / pageSize.height) > 0 ? min(r.width / pageSize.width, r.height / pageSize.height) : 1)
        let h0 = pageSize.height * z0
        let start = CGPoint(x: r.midX - pageSize.width * z0 / 2, y: h0 < r.height ? r.midY - h0 / 2 : r.maxY - h0)
        let reduce = ReduceMotion.isOn
        CATransaction.begin(); CATransaction.setDisableActions(true)
        content.position = finalOrigin
        content.transform = CATransform3DMakeScale(finalZoom, finalZoom, 1)
        CATransaction.commit()
        if !reduce {
            content.add(Motion.spring("position", from: NSValue(point: start), to: NSValue(point: finalOrigin), duration: 0.52, bounce: 0.1), forKey: "lift.p")
            content.add(Motion.spring("transform.scale", from: z0, to: finalZoom, duration: 0.52, bounce: 0.1), forKey: "lift.s")
            // 卡片是圆角的：出来的时候圆角跟着变成直角（圆角按图的坐标算，所以除以缩放）
            if corner > 0 { animateCorner(from: corner / z0, to: 0, duration: 0.4, keep: false) }
        }
        Motion.fade(dim, to: 1, duration: 0.3, curve: .easeOut)
        let so = CABasicAnimation(keyPath: "shadowOpacity")
        so.fromValue = 0; so.toValue = 0.42; so.duration = 0.4
        shadowLayer.shadowOpacity = 0.42
        shadowLayer.add(so, forKey: "lift")
        layoutBars()
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduce ? 0 : 0.2)) { [weak self] in
            self?.actionBar.animateIn(anchor: CGPoint(x: 0.5, y: 0), scale: 0.94, offsetY: -10)
        }
    }

    /// to nil：原地淡掉（飞走的图另有一张）；给了 rect：缩回那里（挂回截图架）
    func disappear(to r: CGRect?, corner: CGFloat = 0, done: @escaping () -> Void) {
        commitText()
        actionBar.animateOut(duration: 0.12, offsetY: -8)
        if styleBar.isShown { styleBar.animateOut(duration: 0.1, offsetY: 0) }
        if beautyBar?.isShown == true { beautyBar?.animateOut(duration: 0.1, offsetY: 0) }
        Motion.fade(dim, to: 0, duration: 0.26, curve: .easeIn)
        Motion.fade(shadowLayer, to: 0, duration: 0.22)
        Motion.fade(scrollKnob, to: 0, duration: 0.1)
        if let r, !ReduceMotion.isOn {
            // 整块（开着背景就是背景）缩进 r：卡片就是按整块的比例做的，正好盖住
            let e = extent
            let z1 = max(0.02, min(r.width / e.width, r.height / e.height))
            let end = CGPoint(x: r.midX - e.midX * z1, y: r.midY - e.midY * z1)
            let fromPos = content.presentation()?.position ?? origin
            let fromScale = (content.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? zoom
            for k in ["lift.p", "lift.s", "fit.p", "fit.s"] { content.removeAnimation(forKey: k) }
            content.add(Motion.spring("position", from: NSValue(point: fromPos), to: NSValue(point: end), duration: 0.42, bounce: 0.04), forKey: "drop.p")
            content.add(Motion.spring("transform.scale", from: fromScale, to: z1, duration: 0.42, bounce: 0.04), forKey: "drop.s")
            if corner > 0 { animateCorner(from: 0, to: corner / z1, duration: 0.36, keep: true) }
            // 长图超出屏幕时的渐隐：缩回去的时候不要
            stage.mask = nil
            CATransaction.begin(); CATransaction.setDisableActions(true)
            content.position = end
            content.transform = CATransform3DMakeScale(z1, z1, 1)
            CATransaction.commit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { done() }
        } else {
            Motion.fade(content, to: 0, duration: r == nil ? 0.08 : 0.18)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { done() }
        }
    }

    /// 整块的圆角（只在出来、收回去的时候有）。图、背景、画的东西一起裁
    private func animateCorner(from a: CGFloat, to b: CGFloat, duration: CFTimeInterval, keep: Bool) {
        let e = extent
        let mask = CAShapeLayer()
        mask.frame = content.bounds
        func path(_ c: CGFloat) -> CGPath { CGPath(roundedRect: e, cornerWidth: min(c, e.width / 2, e.height / 2), cornerHeight: min(c, e.width / 2, e.height / 2), transform: nil) }
        mask.path = path(b)
        let anim = CABasicAnimation(keyPath: "path")
        anim.fromValue = path(a)
        anim.toValue = path(b)
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
        mask.add(anim, forKey: "corner")
        content.mask = mask
        if !keep {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                guard let self, self.content.mask === mask else { return }
                self.content.mask = nil
            }
        }
    }

    // MARK: 条

    /// 第二条在屏幕下面正中间；颜色、背景小条在它上面，对着按钮
    func layoutBars() {
        let a = avail
        let size = actionBar.fittingSize
        actionBar.frame = CGRect(x: (bounds.midX - size.width / 2).rounded(), y: (a.minY - Self.barSpace + 24).rounded(),
                                 width: size.width, height: size.height)
        if styleBar.isShown, let t = annotator.tool { place(styleBar, over: actionBar.toolButtonFrame(t)) }
        if let b = beautyBar, b.isShown { place(b, over: actionBar.beautyButtonFrame) }
    }

    private func place(_ sb: GlassBar, over bf: CGRect?) {
        guard let bf else { return }
        actionBar.layoutSubtreeIfNeeded()
        sb.layoutSubtreeIfNeeded()
        let size = sb.fittingSize
        var x = actionBar.frame.minX + bf.midX - size.width / 2
        x = min(max(x, 8), bounds.width - size.width - 8)
        sb.frame = CGRect(x: x.rounded(), y: (actionBar.frame.maxY + 8).rounded(), width: size.width, height: size.height)
    }

    private static let colorKey = "annotationColor", widthKey = "annotationWidth"
    private var colorIndex: Int { min(max(UserDefaults.standard.object(forKey: Self.colorKey) as? Int ?? 0, 0), AnnotationStyle.colors.count - 1) }
    private var widthIndex: Int { min(max(UserDefaults.standard.object(forKey: Self.widthKey) as? Int ?? 1, 0), AnnotationStyle.widths.count - 1) }

    func selectTool(_ t: AnnotationTool?) {
        commitText()
        annotator.select(nil)
        annotator.color = AnnotationStyle.colors[colorIndex]
        annotator.width = AnnotationStyle.widths[widthIndex]
        annotator.tool = t
        actionBar.setTool(t)
        if let t {
            if let b = beautyBar, b.isShown { b.animateOut(duration: 0.1, offsetY: 0) }
            styleBar.show(tool: t, color: colorIndex, width: widthIndex)
            let was = styleBar.isShown
            place(styleBar, over: actionBar.toolButtonFrame(t))
            if !was { styleBar.animateIn(below: false) }
        } else if styleBar.isShown {
            styleBar.animateOut(duration: 0.1, offsetY: 0)
        }
        window?.invalidateCursorRects(for: self)
        updateCursor()
    }

    /// 选中了一个画好的：样式条上亮的是它的颜色、粗细
    private func refreshStyleBar() {
        guard let t = actionBar.tool else { return }
        let s = annotator.selectedStyleIndices
        styleBar.show(tool: t, color: s?.color ?? colorIndex, width: s?.width ?? widthIndex)
    }

    private func setColor(_ i: Int) {
        UserDefaults.standard.set(i, forKey: Self.colorKey)
        annotator.color = AnnotationStyle.colors[i]
        annotator.restyleSelected(color: AnnotationStyle.colors[i])
        restyleText(color: AnnotationStyle.colors[i])
        refreshStyleBar()
    }

    private func setWidth(_ i: Int) {
        UserDefaults.standard.set(i, forKey: Self.widthKey)
        annotator.width = AnnotationStyle.widths[i]
        annotator.restyleSelected(width: AnnotationStyle.widths[i])
        restyleText(width: AnnotationStyle.widths[i])
        refreshStyleBar()
    }

    /// 背景（G）：关着就打开并出小条；开着、小条没出来就只出小条；开着、小条在就关掉
    func toggleBeauty() {
        let barShown = beautyBar?.isShown ?? false
        if beautyOn && barShown {
            setBeauty(false, style: nil)
            beautyBar?.animateOut(duration: 0.1, offsetY: 0)
            return
        }
        if annotator.tool != nil { selectTool(nil) }
        if !beautyOn { setBeauty(true, style: nil) }
        let bar = beautyBar ?? BeautyBar(style: beautyStyle, wallpaper: wallpaper)
        if beautyBar == nil {
            bar.onChange = { [weak self] s in self?.setBeauty(true, style: s) }
            beautyBar = bar
            addSubview(bar)
        }
        place(bar, over: actionBar.beautyButtonFrame)
        if !barShown { bar.animateIn(below: false) }
    }

    /// 背景开、关、换样式：整块（背景加图）重新缩进来，弹簧过去
    private func setBeauty(_ on: Bool, style: BeautyStyle?) {
        let wasFit = abs(zoom - fitZoom) < 0.01
        if let style { beautyStyle = style }
        beautyOn = on
        actionBar.setBeauty(on)
        preview.update(selection: on ? pageRect : nil, corner: shotCorner, style: beautyStyle, image: image, wallpaper: wallpaper)
        // 图本身也裁成圆角（背景上的截图是圆角的），关掉时还原（窗口还是窗口自己的圆角）
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.cornerRadius = on ? shotCorner : plainCorner
        imageLayer.masksToBounds = imageLayer.cornerRadius > 0
        CATransaction.commit()
        let fromPos = content.presentation()?.position ?? origin
        let fromScale = (content.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? zoom
        // 本来是整块看得见的：开关背景后还是整块看得见；放大着看的：大小不变
        if wasFit { zoom = fitZoom }
        origin = clampOrigin(origin, zoom: zoom)
        apply(animated: false)
        if !ReduceMotion.isOn {
            content.add(Motion.spring("position", from: NSValue(point: fromPos), to: NSValue(point: origin), duration: 0.34), forKey: "fit.p")
            content.add(Motion.spring("transform.scale", from: fromScale, to: zoom, duration: 0.34), forKey: "fit.s")
        }
    }
    private var image: CGImage { editor?.image ?? (imageLayer.contents as! CGImage) }

    // MARK: 字

    private func beginText(at p: CGPoint) {
        let e = TextAnnotationEditor(at: p, color: annotator.color, width: annotator.width, zoom: zoom,
                                     toView: { [unowned self] in self.pageToView($0) })
        e.onCommit = { [weak self] text, o, color, width in self?.annotator.addText(text, at: o, color: color, width: width) }
        e.onFinish = { [weak self] in self?.textFinished() }
        textEditor = e
        addSubview(e.field)
        window?.makeFirstResponder(e.field)
    }

    private func editText(_ i: Int) {
        let a = annotator.items[i]
        annotator.select(nil)
        annotator.setHidden(i, true)
        let e = TextAnnotationEditor(at: a.start, color: a.color, width: a.width, text: a.text, textOrigin: a.start, zoom: zoom,
                                     toView: { [unowned self] in self.pageToView($0) })
        e.onCommit = { [weak self] text, _, color, width in self?.annotator.replaceText(i, with: text, color: color, width: width) }
        e.onFinish = { [weak self] in self?.annotator.setHidden(i, false); self?.textFinished() }
        textEditor = e
        addSubview(e.field)
        window?.makeFirstResponder(e.field)
        e.field.currentEditor()?.selectAll(nil)
    }

    private func textFinished() {
        textEditor = nil
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
    }

    func commitText() { textEditor?.commit() }
    func restyleText(color: NSColor? = nil, width: CGFloat? = nil) { textEditor?.restyle(color: color, width: width) }

    // MARK: 鼠标

    private func inBars(_ p: CGPoint) -> Bool {
        [actionBar, styleBar, beautyBar].compactMap { $0 }.contains { !$0.isHidden && $0.frame.contains(p) }
    }

    override func mouseDown(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        if inBars(v) { return }
        window?.makeFirstResponder(self)
        commitText()
        let p = viewToPage(v)
        let onPage = pageRect.contains(p)
        if annotator.tool != nil || annotator.hit(p) != nil {
            annotator.source = (image, pageRect)
            if let i = annotator.hitForDrawing(p) {
                let a = annotator.items[i]
                if a.tool == .text && (annotator.tool == .text || event.clickCount == 2) { editText(i); return }
                annotator.beginMove(i, at: p)
                drag = .move
                NSCursor.closedHand.set()
                return
            }
            annotator.select(nil)
            if annotator.tool != nil, onPage {
                if annotator.tool == .text { beginText(at: p); return }
                annotator.begin(at: p)
                if annotator.isDrawing { drag = .draw }
                return
            }
        }
        annotator.select(nil)
        // 没拿工具：双击切换整张 / 100%；按住拖动挪（放大了才能挪）
        if event.clickCount == 2 { toggleZoom(at: v); return }
        if canPan {
            drag = .pan(start: v, origin: origin)
            NSCursor.closedHand.set()
        }
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        // 画到一半按下或松开 Shift：马上换样子，不用再动一下鼠标
        if case .draw = drag, let w = window {
            let q = viewToPage(convert(w.mouseLocationOutsideOfEventStream, from: nil))
            annotator.move(to: CGPoint(x: min(max(q.x, 0), pageSize.width), y: min(max(q.y, 0), pageSize.height)),
                           shift: event.modifierFlags.contains(.shift))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let v = convert(event.locationInWindow, from: nil)
        switch drag {
        case .draw:
            let q = viewToPage(v)
            annotator.move(to: CGPoint(x: min(max(q.x, 0), pageSize.width), y: min(max(q.y, 0), pageSize.height)),
                           shift: event.modifierFlags.contains(.shift))
        case .move:
            annotator.moveSelected(to: viewToPage(v))
        case .pan(let s, let o):
            origin = clampOrigin(CGPoint(x: o.x + v.x - s.x, y: o.y + v.y - s.y), zoom: zoom)
            apply(animated: false)
            flashKnob()
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let d = drag else { return }
        drag = nil
        let p = viewToPage(convert(event.locationInWindow, from: nil))
        switch d {
        case .draw: annotator.end()
        case .move: annotator.endMove(at: p)
        case .pan: break
        }
        updateCursor()
    }

    override func mouseMoved(with event: NSEvent) { updateCursor() }

    private func updateCursor() {
        guard drag == nil, let w = window else { return }
        let v = convert(w.mouseLocationOutsideOfEventStream, from: nil)
        if inBars(v) { NSCursor.arrow.set(); return }
        let p = viewToPage(v)
        if let i = annotator.hit(p) {
            (annotator.items[i].tool == .text && annotator.tool == .text ? NSCursor.iBeam : NSCursor.openHand).set()
            return
        }
        if annotator.tool == .text, pageRect.contains(p) { NSCursor.iBeam.set(); return }
        if annotator.tool != nil, pageRect.contains(p) { NSCursor.crosshair.set(); return }
        (canPan ? NSCursor.openHand : NSCursor.arrow).set()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    /// 两指滑动挪；⌘ 加滚轮放大缩小（对着鼠标）
    override func scrollWheel(with event: NSEvent) {
        // 正在打字时缩放、挪动：先把字交出去（输入框是固定在屏幕上的，图动了它不跟着，会和图对不上）
        commitText()
        let v = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command) {
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
            setZoom(zoom * exp(dy / 300), around: v)
            return
        }
        // scrollingDelta 已经按系统设置（自然滚动）换好方向：正的 y 是往文档顶上看（图往下走），和访达、预览一样
        var dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { dx *= 12; dy *= 12 }
        panBy(dx, -dy)
    }

    override func magnify(with event: NSEvent) {
        commitText()
        setZoom(zoom * (1 + event.magnification), around: convert(event.locationInWindow, from: nil))
    }

    override func smartMagnify(with event: NSEvent) { commitText(); toggleZoom(at: convert(event.locationInWindow, from: nil)) }

    // MARK: 键盘

    override func keyDown(with event: NSEvent) { if !handleKey(event) { super.keyDown(with: event) } }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.contains(.command), textEditor == nil else { return false }
        return handleKey(event)
    }

    override func cancelOperation(_ sender: Any?) { _ = escape() }

    /// Esc 一次退一步：选中的 → 工具 → 背景小条 → 不要了
    private func escape() -> Bool {
        if annotator.selected != nil { annotator.select(nil); return true }
        if annotator.tool != nil { selectTool(nil); return true }
        if let b = beautyBar, b.isShown { b.animateOut(duration: 0.1, offsetY: 0); return true }
        editor?.cancel()
        return true
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        let cmd = mods == .command
        let ch = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let center = CGPoint(x: avail.midX, y: avail.midY)
        if event.keyCode == 53 { return escape() }
        if cmd {
            switch ch {
            case "z":
                // ⇧⌘Z 重做（cmd 只看 ⌘⌃⌥，Shift 要单独看）
                commitText()
                if event.modifierFlags.contains(.shift) { annotator.redo() } else { annotator.undo() }
                return true
            case "c":
                if editor?.mode == .edit { editor?.copyRendered() } else { editor?.primary(.saveAndCopy) }
                return true
            case "0": setZoom(fitZoom, around: center, animated: true); return true
            case "1": setZoom(1, around: center, animated: true); return true
            case "=", "+": setZoom(zoom * 1.25, around: center, animated: true); return true
            case "-": setZoom(zoom / 1.25, around: center, animated: true); return true
            default: return false
            }
        }
        guard mods.isEmpty else { return false }
        switch event.keyCode {
        case 36, 76: actionBar.performPrimary(); return true
        case 51, 117:
            if annotator.selected != nil { annotator.deleteSelected() }
            return true
        case 123...126:
            // 方向键：长图上下翻（一次一屏的八分之一）
            let step = avail.height / 8
            switch event.keyCode {
            case 125: panBy(0, step)
            case 126: panBy(0, -step)
            case 123: panBy(step, 0)
            default: panBy(-step, 0)
            }
            return true
        case 49:
            // 空格：往下翻一屏（和看网页一样），⇧ 往上
            let s = avail.height * 0.85
            origin = clampOrigin(CGPoint(x: origin.x, y: origin.y + (event.modifierFlags.contains(.shift) ? -s : s)), zoom: zoom)
            apply(animated: true)
            flashKnob()
            return true
        default: break
        }
        if ch == "g" { toggleBeauty(); return true }
        if let t = CaptureSession.toolKeys[ch] { selectTool(actionBar.tool == t ? nil : t); return true }
        return false
    }

    // 调试用
    var debugText: String {
        let v = pageToView(extent)
        return "zoom=\(String(format: "%.3f", zoom)) fit=\(String(format: "%.3f", fitZoom)) view=\(Int(v.minX)),\(Int(v.minY)) \(Int(v.width))x\(Int(v.height)) "
            + "beauty=\(beautyOn) tool=\(annotator.tool.map { "\($0)" } ?? "-") items=\(annotator.items.count) selected=\(annotator.selected.map(String.init) ?? "-") "
            + "text=\(textEditor != nil) bar=\(Int(actionBar.frame.minX)),\(Int(actionBar.frame.minY)) \(Int(actionBar.frame.width))x\(Int(actionBar.frame.height)) shown=\(actionBar.isShown) key=\(window?.isKeyWindow ?? false) dim=\(dim.opacity)/\(dim.presentation()?.opacity ?? -1) dimFrame=\(dim.frame) dimSuper=\(dim.superlayer === layer) rootSubs=\(layer?.sublayers?.count ?? -1) win=\(window.map { "\($0.alphaValue) \($0.isVisible) \($0.occlusionState.contains(.visible))" } ?? "-")"
    }
}

/// 滚动截图截的是窗口时：出图和截窗口一样，窗口自己的圆角，外面一圈和系统一样的窗口影子
/// （系统的窗口影子只能截真的窗口，长图截不了，按系统前台窗口影子的样子画：大的柔和一层 + 贴边的一圈）
enum WindowLookRenderer {
    /// 影子多出来的边（pt），和系统前台窗口的差不多
    static let insets = ShadowInsets(top: 38, left: 56, bottom: 74, right: 56)

    static func render(_ img: CGImage, corner: CGFloat, shadow: Bool, scale k: CGFloat) -> CGImage? {
        let w = CGFloat(img.width) / k, h = CGFloat(img.height) / k
        let m = shadow ? insets : .zero
        let W = Int(((w + m.left + m.right) * k).rounded()), H = Int(((h + m.top + m.bottom) * k).rounded())
        let cs = img.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)!
        let float = img.bitsPerComponent > 8
        let info: UInt32 = float
            ? CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: float ? 16 : 8, bytesPerRow: 0, space: cs, bitmapInfo: info)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: k, y: k)
        let r = CGRect(x: m.left, y: m.bottom, width: w, height: h)
        let path = CGPath(roundedRect: r, cornerWidth: corner, cornerHeight: corner, transform: nil)
        if shadow {
            // 两层：大的散开的（往下偏），贴边的一圈细的（看得出窗口的边）
            for (blur, dy, a) in [(CGFloat(50), CGFloat(-22), CGFloat(0.40)), (CGFloat(3), CGFloat(-1), CGFloat(0.28))] {
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: dy * k), blur: blur * k, color: CGColor(gray: 0, alpha: a))
                ctx.addPath(path)
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                ctx.fillPath()
                ctx.restoreGState()
            }
            // 影子画好后把窗口那块挖空，再画图（图有透明的地方也不会透出黑底）
            ctx.saveGState()
            ctx.addPath(path)
            ctx.setBlendMode(.clear)
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(img, in: r)
        ctx.restoreGState()
        // 窗口边上一圈很淡的线（系统窗口也有）
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), cornerWidth: corner, cornerHeight: corner, transform: nil))
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.12))
        ctx.setLineWidth(0.5)
        ctx.strokePath()
        guard let out = ctx.makeImage() else { return nil }
        return img.contentHeadroom >= 1 ? (CGImageCreateCopyWithContentHeadroom(img.contentHeadroom, out) ?? out) : out
    }
}
