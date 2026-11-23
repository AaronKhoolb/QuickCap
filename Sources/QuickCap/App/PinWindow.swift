import AppKit

/// 钉到桌面（Pin to Desktop）：截图变成一张浮在所有窗口上面的小图，就停在原来截的地方。
/// - 拖着挪；双指捏合、滚轮缩放（左下角短暂显示百分比）；双击回到 100%
/// - 鼠标移上去右上角出现 ✕；Esc 或 ⌘W 关掉；⌘C 复制；右键：复制、在 Finder 里显示、关掉
/// - 阴影和圆角跟系统的浮动小窗一样；有 HDR 的图在 HDR 屏上照样亮
@MainActor
final class PinWindow: NSPanel {
    private static var open: [PinWindow] = []
    /// 调试用：现在钉着几张、各在哪
    static var debugText: String { "pins=\(open.count) " + open.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height)) file=\($0.fileURL?.lastPathComponent ?? "-")" }.joined(separator: "; ") }
    static var debugCount: Int { open.count }

    private let imageView: PinImageView
    private let image: CGImage
    /// 存下来的文件（写好以后才有）
    var fileURL: URL?
    private let baseSize: CGSize
    private var zoom: CGFloat = 1
    private let closeButton = NSButton()
    private let zoomLabel = NSTextField(labelWithString: "")
    private var zoomHide: DispatchWorkItem?

    /// rect：放在屏幕的哪里（pt，原点左下）。image 按 rect 的大小显示（截的是几倍像素就是几倍）
    @discardableResult
    /// 左上角那个像素是透明的：图自己带了影子或透明的外圈
    private static func hasTransparentEdge(_ img: CGImage) -> Bool {
        switch img.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        guard let px = img.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1)) else { return false }
        // 只有 alpha 的灰度上下文系统不支持（会建不出来），用普通的 RGBA 一个像素
        var out = [UInt8](repeating: 255, count: 4)
        let ok = out.withUnsafeMutableBytes { buf -> Bool in
            guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
            ctx.draw(px, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return ok && out[3] < 128
    }

    static func pin(image: CGImage, hdr: CGImage?, rect: CGRect, fileURL: URL?) -> PinWindow {
        let w = PinWindow(image: image, hdr: hdr, rect: rect, fileURL: fileURL)
        open.append(w)
        w.appear()
        return w
    }

    private init(image: CGImage, hdr: CGImage?, rect: CGRect, fileURL: URL?) {
        self.image = image
        self.fileURL = fileURL
        baseSize = rect.size
        imageView = PinImageView(image: hdr ?? image, hdr: hdr != nil)
        super.init(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        animationBehavior = .none

        let root = PinRootView(frame: CGRect(origin: .zero, size: rect.size))
        root.onHover = { [weak self] on in self?.setChromeVisible(on) }
        root.onDoubleClick = { [weak self] in self?.setZoom(1, around: nil) }
        root.onScroll = { [weak self] e in self?.scrolled(e) }
        root.onMagnify = { [weak self] e in self?.magnified(e) }
        root.menuProvider = { [weak self] in self?.contextMenu() }
        contentView = root
        // 图自己带透明的边（窗口截图的影子、背景外圈）：不再加圆角、细边和窗口影子，不然透明的影子外面多一圈细框、影子叠两层
        if Self.hasTransparentEdge(image) {
            hasShadow = false
            root.layer?.cornerRadius = 0
            root.layer?.borderWidth = 0
        }
        imageView.frame = root.bounds
        imageView.autoresizingMask = [.width, .height]
        root.addSubview(imageView)

        closeButton.bezelStyle = .circular
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .regular).applying(.init(paletteColors: [.white, NSColor(white: 0, alpha: 0.55)])))
        closeButton.target = self
        closeButton.action = #selector(closePin)
        closeButton.frame = CGRect(x: rect.width - 26, y: rect.height - 26, width: 22, height: 22)
        closeButton.autoresizingMask = [.minXMargin, .minYMargin]
        closeButton.alphaValue = 0
        closeButton.toolTip = "Close (Esc)"
        root.addSubview(closeButton)

        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        zoomLabel.textColor = .white
        zoomLabel.alignment = .center
        zoomLabel.wantsLayer = true
        zoomLabel.layer?.backgroundColor = NSColor(white: 0, alpha: 0.55).cgColor
        zoomLabel.layer?.cornerRadius = 6
        zoomLabel.frame = CGRect(x: 6, y: 6, width: 46, height: 18)
        zoomLabel.alphaValue = 0
        root.addSubview(zoomLabel)
    }

    override var canBecomeKey: Bool { true }

    /// 出现：从原地稍微浮起来一点
    private func appear() {
        alphaValue = 0
        // 不抢键盘：刚钉出来时用户多半还在原来的应用里打字（点一下钉图它才成为键盘窗口，Esc、⌘C 才给它）
        orderFrontRegardless()
        invalidateShadow()
        guard let l = contentView?.layer, !ReduceMotion.isOn else { alphaValue = 1; return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
        let s = CASpringAnimation(keyPath: "transform.scale")
        s.fromValue = 0.97
        s.toValue = 1
        s.damping = 18
        s.stiffness = 260
        s.duration = s.settlingDuration
        l.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        l.position = CGPoint(x: l.bounds.midX, y: l.bounds.midY)
        l.add(s, forKey: "lift")
    }

    @objc private func closePin() {
        PinWindow.open.removeAll { $0 === self }
        guard !ReduceMotion.isOn else { close(); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in MainActor.assumeIsolated { self?.close() } })
    }

    private func setChromeVisible(_ on: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = on ? 0.12 : 0.2
            closeButton.animator().alphaValue = on ? 1 : 0
        }
    }

    // MARK: 缩放

    private func scrolled(_ e: NSEvent) {
        // 触控板两指滑动不缩放（容易误碰），滚轮才缩放
        guard !e.hasPreciseScrollingDeltas, e.scrollingDeltaY != 0 else { return }
        let k: CGFloat = e.scrollingDeltaY > 0 ? 1.1 : 1 / 1.1
        setZoom(zoom * k, around: NSEvent.mouseLocation)
    }

    private func magnified(_ e: NSEvent) {
        setZoom(zoom * (1 + e.magnification), around: NSEvent.mouseLocation)
    }

    /// 以鼠标为中心缩放（around nil：以窗口中心）
    private func setZoom(_ z: CGFloat, around p: CGPoint?) {
        var nz = min(max(z, 0.2), 6)
        // 最大放到差不多一块屏幕大（以前能放到 600%，窗口好几块屏幕宽，图层要几百 MB）
        if let vis = (screen ?? NSScreen.main)?.visibleFrame, baseSize.width > 0, baseSize.height > 0 {
            nz = min(nz, max(1, min(vis.width / baseSize.width, vis.height / baseSize.height)))
        }
        guard abs(nz - zoom) > 0.001 else { return }
        let f = frame
        let anchor = p ?? CGPoint(x: f.midX, y: f.midY)
        let fx = (anchor.x - f.minX) / f.width, fy = (anchor.y - f.minY) / f.height
        let size = CGSize(width: (baseSize.width * nz).rounded(), height: (baseSize.height * nz).rounded())
        let nf = CGRect(x: anchor.x - size.width * fx, y: anchor.y - size.height * fy, width: size.width, height: size.height)
        zoom = nz
        setFrame(nf, display: true)
        invalidateShadow()
        showZoomLabel()
    }

    private func showZoomLabel() {
        zoomLabel.stringValue = "\(Int((zoom * 100).rounded()))%"
        zoomLabel.alphaValue = 1
        zoomHide?.cancel()
        let w = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                self?.zoomLabel.animator().alphaValue = 0
            }
        }
        zoomHide = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
    }

    // MARK: 键盘、菜单

    override func keyDown(with event: NSEvent) {
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 { closePin(); return }
        if f == .command, let c = event.charactersIgnoringModifiers?.lowercased() {
            if c == "w" { closePin(); return }
            if c == "c" { copyImage(); return }
            if c == "0" { setZoom(1, around: nil); return }
            if c == "=" || c == "+" { setZoom(zoom * 1.25, around: nil); return }
            if c == "-" { setZoom(zoom / 1.25, around: nil); return }
        }
        super.keyDown(with: event)
    }

    @objc private func copyImage() {
        guard let png = CaptureOutput.pngData(image, scale: CGFloat(image.width) / baseSize.width) else { return }
        CaptureOutput.copy(png: png)
        CaptureToast.show("Copied", at: CGPoint(x: frame.midX, y: frame.midY))
    }

    private func contextMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(ClosureMenuItem("Copy") { [weak self] in self?.copyImage() })
        if let url = fileURL {
            m.addItem(ClosureMenuItem("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        }
        m.addItem(ClosureMenuItem("Actual Size") { [weak self] in self?.setZoom(1, around: nil) })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("Close") { [weak self] in self?.closePin() })
        return m
    }
}

/// 钉住的图的底：接鼠标进出、双击、缩放、右键
private final class PinRootView: NSView {
    var onHover: ((Bool) -> Void)?
    var onDoubleClick: (() -> Void)?
    var onScroll: ((NSEvent) -> Void)?
    var onMagnify: ((NSEvent) -> Void)?
    var menuProvider: (() -> NSMenu?)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        // 一圈很细的边：白底的截图放在白色的东西上面也分得清
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 0, alpha: 0.18).cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?(); return }
        window?.performDrag(with: event)
    }
    override func scrollWheel(with event: NSEvent) { onScroll?(event) }
    override func magnify(with event: NSEvent) { onMagnify?(event) }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
    override var acceptsFirstResponder: Bool { true }
}

/// 显示图（HDR 的图开着 HDR，在 HDR 屏上一样亮）
private final class PinImageView: NSView {
    init(image: CGImage, hdr: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resize
        layer?.minificationFilter = .trilinear
        if hdr { layer?.preferredDynamicRange = .high }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
