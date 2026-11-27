import AppKit

/// 钉到桌面（Pin to Desktop）：截图变成一张浮在所有窗口上面的小图，就停在原来截的地方。
/// - 拖着挪；双指捏合、滚轮缩放（左下角短暂显示百分比）；双击回到 100%
/// - 鼠标移上去右上角出现 ✕；Esc 或 ⌘W 关掉；⌘C 复制；右键：复制、在 Finder 里显示、关掉
/// - 阴影和圆角跟系统的浮动小窗一样；有 HDR 的图在 HDR 屏上照样亮
/// - 透明度：数字键 1–9 是 10%–90%，0 是 100%；⌥ 加滚轮慢慢调；右键 Opacity
/// - 锁定（点穿）：鼠标直接点到下面的窗口，角上一个小锁；从菜单栏 Unlock Pins 解开
/// - 方向键挪 1pt，⇧ 加方向键挪 10pt
@MainActor
final class PinWindow: NSPanel {
    private static var open: [PinWindow] = []
    /// 调试用：现在钉着几张、各在哪
    static var debugText: String { "pins=\(open.count) " + open.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height)) opacity=\(Int(($0.opacity * 100).rounded())) locked=\($0.locked) file=\($0.fileURL?.lastPathComponent ?? "-")" }.joined(separator: "; ") }
    static var debugCount: Int { open.count }
    static var anyLocked: Bool { open.contains { $0.locked } }
    /// 调试用：最上面那张
    static var debugLast: PinWindow? { open.last }
    /// 调试用：给最上面那张送一个键（left right up down 或一个字符；mods: shift cmd）
    static func debugKey(_ name: String, mods: String) {
        guard let w = open.last else { return }
        let codes: [String: UInt16] = ["left": 123, "right": 124, "down": 125, "up": 126, "esc": 53]
        var f: NSEvent.ModifierFlags = []
        if mods.contains("shift") { f.insert(.shift) }
        if mods.contains("cmd") { f.insert(.command) }
        let isArrow = (123...126).contains(codes[name] ?? 0)
        if isArrow { f.insert([.numericPad, .function]) }
        let chars = codes[name] == nil ? name : ""
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: f, timestamp: 0, windowNumber: w.windowNumber,
                                       context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
                                       keyCode: codes[name] ?? 0) else { return }
        w.keyDown(with: e)
    }

    /// 菜单栏：全部关掉
    static func closeAll() { for w in open { w.closePin() } }
    /// 菜单栏：全部解锁（锁住的钉图点不到，只能从这里解开）
    static func unlockAll() { for w in open where w.locked { w.setLocked(false) } }

    private let imageView: PinImageView
    private var image: CGImage
    /// 右键 Annotate…：交给 AppDelegate 用截图架那个编辑器打开
    static var onAnnotate: ((PinWindow) -> Void)?
    var currentImage: CGImage { image }
    /// 存下来的文件（写好以后才有）。有了文件才记进 pins.json
    var fileURL: URL? { didSet { PinWindow.saveState() } }
    private var baseSize: CGSize
    private var moveObserver: NSObjectProtocol?
    private var zoom: CGFloat = 1
    private let closeButton = NSButton()
    private let zoomLabel = NSTextField(labelWithString: "")
    private var zoomHide: DispatchWorkItem?
    private let lockBadge = NSImageView()
    /// 图的透明度（0.1–1）。窗口本身的 alphaValue 留给出现、消失的动画
    private(set) var opacity: CGFloat = 1
    private(set) var locked = false

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

    /// rect：放在屏幕的哪里（pt，原点左下）。image 按 rect 的大小显示（截的是几倍像素就是几倍）
    @discardableResult
    static func pin(image: CGImage, hdr: CGImage?, rect: CGRect, fileURL: URL?, baseSize: CGSize? = nil) -> PinWindow {
        let w = PinWindow(image: image, hdr: hdr, rect: rect, fileURL: fileURL, baseSize: baseSize)
        open.append(w)
        w.appear()
        saveState()
        return w
    }

    // MARK: 重启后还在

    /// 钉图记在 ~/Library/Application Support/QuickCap/pins.json：文件、位置、缩放前大小、透明度、锁定。
    /// 只记有文件的（截图写好之前那一小会儿没有文件，写好就补上）
    private struct Saved: Codable {
        var path: String, x: Double, y: Double, w: Double, h: Double, baseW: Double, baseH: Double
        var opacity: Double, locked: Bool
    }

    static var supportFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("QuickCap", isDirectory: true)
    }
    /// 调试运行用另一个文件，不碰用户真的钉图
    static var stateURL: URL { supportFolder.appendingPathComponent(DebugOptions.isDebugRun ? "pins-debug.json" : "pins.json") }
    /// 从剪贴板钉的图存在这里（截图文件夹里没有它），关掉钉图就删
    static var clipboardFolder: URL { supportFolder.appendingPathComponent("Pins", isDirectory: true) }

    private static var saveWork: DispatchWorkItem?
    /// 退出时马上写（不等那 0.3 秒）
    static func flushState() {
        guard let w = saveWork else { return }
        saveWork = nil
        w.cancel()
        writeState()
    }

    /// 截图文件夹搬了位置：钉着的图跟着换成新路径（不然重启后找不到文件、钉图就没了）
    static func remap(_ moved: [(from: URL, to: URL)]) {
        guard !moved.isEmpty else { return }
        var map: [String: URL] = [:]
        for m in moved { map[m.from.standardizedFileURL.path] = m.to }
        for p in open { if let u = p.fileURL, let to = map[u.standardizedFileURL.path] { p.fileURL = to } }
    }

    /// 稍微等一下再写（拖动、缩放时一秒会改很多次）
    static func saveState() {
        saveWork?.cancel()
        let w = DispatchWorkItem { MainActor.assumeIsolated { writeState() } }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    private static func writeState() {
        let rows = open.compactMap { p -> Saved? in
            guard let url = p.fileURL else { return nil }
            let f = p.frame
            return Saved(path: url.path, x: f.minX, y: f.minY, w: f.width, h: f.height,
                         baseW: p.baseSize.width, baseH: p.baseSize.height, opacity: p.opacity, locked: p.locked)
        }
        try? FileManager.default.createDirectory(at: supportFolder, withIntermediateDirectories: true)
        do { try JSONEncoder().encode(rows).write(to: stateURL, options: .atomic) }
        catch { NSLog("QuickCap: couldn't save pins: \(error)") }
    }

    // MARK: 从剪贴板钉

    /// 剪贴板里有图（别处复制的图片，或者 Finder 里复制的图片文件）就钉到鼠标所在屏幕的中间。
    /// 图（包括 Finder 里复制的文件）都存一份到 Application Support/QuickCap/Pins：重启后还在，标注不会改到原文件；关掉钉图就删掉这份
    @discardableResult
    static func pinFromClipboard() -> Bool {
        let pb = NSPasteboard.general
        var url: URL?
        try? FileManager.default.createDirectory(at: clipboardFolder, withIntermediateDirectories: true)
        if let files = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let f = files.first(where: { loadImage($0) != nil }) {
            // 复制一份再钉：钉图上标注后 Replace 只改这份，不会改到用户自己的文件
            let copy = clipboardFolder.appendingPathComponent("Pin \(UUID().uuidString.prefix(8)).\(f.pathExtension)")
            if (try? FileManager.default.copyItem(at: f, to: copy)) != nil { url = copy }
        } else if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) ?? NSImage(pasteboard: pb)?.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) {
            let f = clipboardFolder.appendingPathComponent("Pin \(UUID().uuidString.prefix(8)).png")
            if (try? png.write(to: f, options: .atomic)) != nil { url = f }
        }
        guard let url, let (img, hdr) = loadImage(url), let rect = centeredRect(for: img) else { return false }
        pin(image: img, hdr: hdr, rect: rect, fileURL: url)
        return true
    }

    /// 钉在鼠标所在屏幕的中间：按屏幕的像素倍数显示，太大就缩到四周各留 60pt
    static func centeredRect(for img: CGImage) -> CGRect? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens.first
        else { return nil }
        let k = screen.backingScaleFactor
        var size = CGSize(width: CGFloat(img.width) / k, height: CGFloat(img.height) / k)
        let maxS = screen.visibleFrame.insetBy(dx: 60, dy: 60).size
        let fit = min(1, maxS.width / size.width, maxS.height / size.height)
        size = CGSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())
        let v = screen.visibleFrame
        return CGRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// 剪贴板里有能钉的图吗（菜单项灰不灰）
    static var clipboardHasImage: Bool {
        let pb = NSPasteboard.general
        if NSImage.canInit(with: pb) { return true }
        let files = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return files.contains { ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "webp", "bmp"].contains($0.pathExtension.lowercased()) }
    }

    /// 打开一个图片文件：普通的图，和有增益图时的 HDR 图
    static func loadImage(_ url: URL) -> (CGImage, CGImage?)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let gm = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
        let hdr = gm ? CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary) : nil
        return (img, hdr)
    }

    /// 启动时：上次钉着的图放回原处。文件已经删了的跳过；原来的屏幕不在了就挪到主屏中间
    static func restore() {
        guard let data = try? Data(contentsOf: stateURL),
              let rows = try? JSONDecoder().decode([Saved].self, from: data) else { return }
        for r in rows {
            let url = URL(fileURLWithPath: r.path)
            guard let (img, hdr) = loadImage(url) else { continue }
            var rect = CGRect(x: r.x, y: r.y, width: r.w, height: r.h)
            let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersection(rect).width >= 24 && $0.visibleFrame.intersection(rect).height >= 24 }
            if !onScreen, let v = NSScreen.main?.visibleFrame {
                rect.origin = CGPoint(x: v.midX - rect.width / 2, y: v.midY - rect.height / 2)
            }
            let w = pin(image: img, hdr: hdr, rect: rect, fileURL: url, baseSize: CGSize(width: r.baseW, height: r.baseH))
            w.setOpacity(r.opacity, announce: false)
            if r.locked { w.locked = true; w.ignoresMouseEvents = true; w.lockBadge.isHidden = false }
        }
        saveState()
    }

    private init(image: CGImage, hdr: CGImage?, rect: CGRect, fileURL: URL?, baseSize: CGSize? = nil) {
        self.image = image
        self.fileURL = fileURL
        self.baseSize = baseSize ?? rect.size
        if let b = baseSize, b.width > 0 { zoom = rect.width / b.width }
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
        zoomLabel.layer?.backgroundColor = ReduceTransparency.chip(0.55)
        zoomLabel.layer?.cornerRadius = 6
        zoomLabel.frame = CGRect(x: 6, y: 6, width: 46, height: 18)
        zoomLabel.alphaValue = 0
        root.addSubview(zoomLabel)

        // 锁住时右上角一个小锁，提醒"这张点不到，要从菜单栏解开"
        lockBadge.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Locked")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold).applying(.init(paletteColors: [.white])))
        lockBadge.wantsLayer = true
        lockBadge.layer?.backgroundColor = ReduceTransparency.chip(0.55)
        lockBadge.layer?.cornerRadius = 9
        lockBadge.frame = CGRect(x: rect.width - 24, y: rect.height - 24, width: 18, height: 18)
        lockBadge.autoresizingMask = [.minXMargin, .minYMargin]
        lockBadge.isHidden = true
        root.addSubview(lockBadge)

        // 拖动后记下新位置
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: .main) { _ in
            MainActor.assumeIsolated { PinWindow.saveState() }
        }
    }

    // MARK: 标注后换图

    /// 编辑器开着时钉图先藏起来（编辑器从这里放大出去，收回这里）
    func setHiddenForEditing(_ on: Bool) { alphaValue = on ? 0 : 1 }

    /// 改好的图换上去：左上角不动，按新图的大小（加了美化背景会变大）乘现在的缩放
    func replaceImage(_ img: CGImage, hdr: CGImage?, pointSize: CGSize) {
        image = img
        imageView.set(image: hdr ?? img, hdr: hdr != nil)
        baseSize = pointSize
        let f = frame
        let size = CGSize(width: (pointSize.width * zoom).rounded(), height: (pointSize.height * zoom).rounded())
        setFrame(CGRect(x: f.minX, y: f.maxY - size.height, width: size.width, height: size.height), display: true)
        invalidateShadow()
        PinWindow.saveState()
    }

    // MARK: 透明度、锁定、挪动

    /// 调透明度：只调图，锁和 ✕ 不跟着变淡
    func setOpacity(_ v: CGFloat, announce: Bool = true) {
        let nv = min(max(v, 0.1), 1)
        guard abs(nv - opacity) > 0.001 else { return }
        opacity = nv
        imageView.alphaValue = nv
        PinWindow.saveState()
        if announce { showLabel("\(Int((nv * 100).rounded()))%") }
    }

    /// 锁定 = 点穿：鼠标、滚轮全给下面的窗口。解锁只能从菜单栏
    func setLocked(_ on: Bool) {
        locked = on
        ignoresMouseEvents = on
        PinWindow.saveState()
        lockBadge.isHidden = !on
        if on {
            closeButton.alphaValue = 0
            // 锁住了就不该再抢键盘：把键盘还给下面的应用
            if isKeyWindow { resignKey() }
            CaptureToast.show("Locked. Unlock from the menu bar.", symbol: "lock.fill", at: CGPoint(x: frame.midX, y: frame.minY - 24))
        }
    }

    /// 方向键挪（不出屏幕外太多：至少留 24pt 在屏幕里，免得找不回来）
    private func nudge(dx: CGFloat, dy: CGFloat) {
        var f = frame.offsetBy(dx: dx, dy: dy)
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        f.origin.x = min(max(f.origin.x, union.minX - f.width + 24), union.maxX - 24)
        f.origin.y = min(max(f.origin.y, union.minY - f.height + 24), union.maxY - 24)
        setFrameOrigin(f.origin)
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

    @objc fileprivate func closePin() {
        PinWindow.open.removeAll { $0 === self }
        if let o = moveObserver { NotificationCenter.default.removeObserver(o); moveObserver = nil }
        // 从剪贴板钉的图只为钉图存了一份，关掉就不要了
        if let url = fileURL, url.deletingLastPathComponent().standardizedFileURL == PinWindow.clipboardFolder.standardizedFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        PinWindow.saveState()
        guard !ReduceMotion.isOn else { close(); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in MainActor.assumeIsolated { self?.close() } })
    }

    private func setChromeVisible(_ on: Bool) {
        if locked { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = on ? 0.12 : 0.2
            closeButton.animator().alphaValue = on ? 1 : 0
        }
    }

    // MARK: 缩放

    private func scrolled(_ e: NSEvent) {
        // ⌥ 加滚动（滚轮或触控板都行）：调透明度，往上更实
        if e.modifierFlags.contains(.option) {
            let d = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / 300 : (e.scrollingDeltaY > 0 ? 0.05 : -0.05)
            if d != 0 { setOpacity(opacity + d) }
            return
        }
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
        PinWindow.saveState()
    }

    private func showZoomLabel() { showLabel("\(Int((zoom * 100).rounded()))%") }

    /// 左下角短暂显示一个数（缩放、透明度共用）
    private func showLabel(_ text: String) {
        zoomLabel.stringValue = text
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
        // 方向键挪动：1pt，⇧ 10pt（方向键自带 .numericPad/.function，只看 ⇧）
        let arrows: [UInt16: (CGFloat, CGFloat)] = [123: (-1, 0), 124: (1, 0), 125: (0, -1), 126: (0, 1)]
        if let (dx, dy) = arrows[event.keyCode], f.subtracting([.numericPad, .function, .shift]).isEmpty {
            let k: CGFloat = f.contains(.shift) ? 10 : 1
            nudge(dx: dx * k, dy: dy * k)
            return
        }
        // 数字键：1–9 = 10%–90%，0 = 100%（没有修饰键时）
        if f.isEmpty, let c = event.charactersIgnoringModifiers, c.count == 1, let n = Int(c) {
            setOpacity(n == 0 ? 1 : CGFloat(n) / 10)
            return
        }
        if f == .command, let c = event.charactersIgnoringModifiers?.lowercased() {
            if c == "w" { closePin(); return }
            if c == "c" { copyImage(); return }
            // ⌘0、⌘1 都是原大小（钉图本来就是原大小，⌘1 和编辑器一样）
            if c == "0" || c == "1" { setZoom(1, around: nil); return }
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
        if fileURL != nil, PinWindow.onAnnotate != nil {
            m.addItem(ClosureMenuItem("Annotate…") { [weak self] in if let self { PinWindow.onAnnotate?(self) } })
        }
        if let url = fileURL {
            m.addItem(ClosureMenuItem("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        }
        m.addItem(ClosureMenuItem("Actual Size") { [weak self] in self?.setZoom(1, around: nil) })
        let op = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for v in [100, 75, 50, 25] {
            let i = ClosureMenuItem("\(v)%") { [weak self] in self?.setOpacity(CGFloat(v) / 100) }
            i.state = Int((opacity * 100).rounded()) == v ? .on : .off
            sub.addItem(i)
        }
        op.submenu = sub
        m.addItem(op)
        m.addItem(ClosureMenuItem("Lock (Click Through)") { [weak self] in self?.setLocked(true) })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("Close") { [weak self] in self?.closePin() })
        if PinWindow.open.count > 1 {
            m.addItem(ClosureMenuItem("Close All Pins") { PinWindow.closeAll() })
        }
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
        layer?.contentsGravity = .resize
        layer?.minificationFilter = .trilinear
        set(image: image, hdr: hdr)
    }
    func set(image: CGImage, hdr: Bool) {
        layer?.contents = image
        layer?.preferredDynamicRange = hdr ? .high : .standard
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
