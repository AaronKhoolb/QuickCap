import AppKit
import QuartzCore
import ScreenCaptureKit

/// 美化背景：截图外面铺一层背景（渐变、桌面壁纸、纯色、透明），加边距、圆角和影子。
/// 截图界面上看到的就是存下来的样子：预览和出图用同一套尺寸（BeautyLayout）
enum BeautyBackground: Int, CaseIterable {
    case sunset, ocean, mint, graphite, wallpaper, light, clear

    var title: String {
        switch self {
        case .sunset: return "Sunset"
        case .ocean: return "Ocean"
        case .mint: return "Mint"
        case .graphite: return "Graphite"
        case .wallpaper: return "Desktop Wallpaper"
        case .light: return "Light"
        case .clear: return "Transparent"
        }
    }

    /// 渐变的颜色（从左上到右下）
    var gradient: [CGColor]? {
        func c(_ h: UInt32) -> CGColor {
            CGColor(srgbRed: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255, blue: CGFloat(h & 0xFF) / 255, alpha: 1)
        }
        switch self {
        case .sunset: return [c(0xFF9A6B), c(0xFF6AA8), c(0x8A7BFF)]
        case .ocean: return [c(0x7AD3FF), c(0x4A6BFF)]
        case .mint: return [c(0xA8F0C6), c(0x3BB08F)]
        case .graphite: return [c(0x2B2E3A), c(0x565B6E)]
        default: return nil
        }
    }

    var solid: CGColor? { self == .light ? CGColor(srgbRed: 0.949, green: 0.949, blue: 0.957, alpha: 1) : nil }

    /// 这块屏幕的桌面壁纸。先用打开截图时从系统壁纸窗口截下的那一张（动态壁纸、Macintosh 这种
    /// 由系统扩展画出来的也有，而且是这一刻真的样子）；没有再读壁纸文件（读一次就记着）
    @MainActor static func wallpaper(for screen: NSScreen?) -> CGImage? {
        if let screen, let id = screen.displayID, let live = live[id] { return live }
        guard let screen, let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        // 读不出来的（动态壁纸等）也记住，不会每次都重新打开文件
        if let c = cache[url] { return c }
        let img = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap {
            CGImageSourceCreateThumbnailAtIndex($0, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                        kCGImageSourceThumbnailMaxPixelSize: 3200,
                                                        kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        }
        cache[url] = .some(img)
        return img
    }
    @MainActor private static var cache: [URL: CGImage?] = [:]
    /// 每块屏幕上系统壁纸窗口的样子（打开截图时截一次）
    @MainActor private static var live: [CGDirectDisplayID: CGImage] = [:]
    /// 截图界面关掉：这一刻的壁纸不要了（一块 5K 屏就是几十 MB，以前一直留在内存里）
    @MainActor static func clearLive() { live = [:] }

    /// 截下系统画壁纸的那个窗口（程序坞那个进程的 "Wallpaper"，在所有窗口最下面），不带桌面图标和别的窗口。
    /// 在后台截，不挡打开截图界面；截不到就用壁纸文件
    static func captureLive(_ content: SCShareableContent) async {
        let walls = content.windows.filter { $0.owningApplication?.bundleIdentifier == "com.apple.WindowManager" && $0.title == "Wallpaper" }
        let screens = await MainActor.run { NSScreen.screens.map { ($0.displayID, $0.frame, $0.backingScaleFactor) } }
        let mainH = screens.first?.1.height ?? 0
        var found: [CGDirectDisplayID: CGImage] = [:]
        for (id, frame, scale) in screens {
            guard let id else { continue }
            // 窗口坐标原点在主屏左上，NSScreen 的在主屏左下
            let top = CGRect(x: frame.minX, y: mainH - frame.maxY, width: frame.width, height: frame.height)
            guard let w = walls.first(where: { $0.frame.intersection(top).width * $0.frame.intersection(top).height > top.width * top.height * 0.9 }) else { continue }
            let cfg = SCStreamConfiguration()
            cfg.width = Int(w.frame.width * scale)
            cfg.height = Int(w.frame.height * scale)
            cfg.showsCursor = false
            if let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg) {
                found[id] = img
            }
        }
        let result = found
        await MainActor.run { live = result }
    }
}

/// 选了哪种背景、多大边距、什么比例（记在 UserDefaults，下次打开还是这样）
struct BeautyStyle: Equatable {
    var background: BeautyBackground = .sunset
    /// 0 小、1 中、2 大
    var padding = 1
    /// 0 跟着截图、1 16:9、2 4:3、3 1:1
    var ratio = 0

    static let ratios: [(title: String, value: CGFloat?)] = [("Auto", nil), ("16:9", 16.0 / 9), ("4:3", 4.0 / 3), ("1:1", 1)]

    static func load() -> BeautyStyle {
        let d = UserDefaults.standard
        var s = BeautyStyle()
        if let b = d.object(forKey: "beautyBackground") as? Int, let bg = BeautyBackground(rawValue: b) { s.background = bg }
        if let p = d.object(forKey: "beautyPadding") as? Int { s.padding = min(max(p, 0), 2) }
        if let r = d.object(forKey: "beautyRatio") as? Int { s.ratio = min(max(r, 0), ratios.count - 1) }
        return s
    }

    func save() {
        let d = UserDefaults.standard
        d.set(background.rawValue, forKey: "beautyBackground")
        d.set(padding, forKey: "beautyPadding")
        d.set(ratio, forKey: "beautyRatio")
    }
}

/// 尺寸：边距按截图长边的比例（小图也有一点、大图不显得挤），比例不够就把短的那边补长
enum BeautyLayout {
    /// 框选、整个屏幕的截图圆角（窗口用窗口自己的圆角）
    static let shotCorner: CGFloat = 10
    static let shadowBlur: CGFloat = 28, shadowOffset: CGFloat = 10, shadowAlpha: CGFloat = 0.32

    static func padding(for s: CGRect, _ i: Int) -> CGFloat {
        let factor: [CGFloat] = [0.05, 0.09, 0.14], minimum: [CGFloat] = [24, 44, 72]
        return max(max(s.width, s.height) * factor[i], minimum[i]).rounded()
    }

    /// 背景铺多大（截图界面坐标）：选区四边加边距，再按比例补齐，截图在正中间
    static func frame(for s: CGRect, style: BeautyStyle) -> CGRect {
        let p = padding(for: s, style.padding)
        var w = s.width + p * 2, h = s.height + p * 2
        if let r = BeautyStyle.ratios[style.ratio].value {
            if w / h < r { w = h * r } else { h = w / r }
        }
        return CGRect(x: s.midX - w / 2, y: s.midY - h / 2, width: w, height: h).integral
    }
}

/// 出图：截好的图铺到背景上（普通图和 HDR 图都这样做一遍，背景在两张里一样，增益图在那里是平的）
enum BeautyRenderer {
    /// image 在截图界面里占 imageRect；selection 是截图本身（窗口不带系统阴影，换成我们的影子）
    static func compose(_ image: CGImage, imageRect: CGRect, selection: CGRect, corner: CGFloat, style: BeautyStyle,
                        wallpaper: CGImage?) -> CGImage? {
        let frame = BeautyLayout.frame(for: selection, style: style)
        let k = CGFloat(image.width) / imageRect.width
        let W = Int((frame.width * k).rounded()), H = Int((frame.height * k).rounded())
        let cs = image.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)!
        let float = image.bitsPerComponent > 8
        let info: UInt32 = float
            ? CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            : CGImageAlphaInfo.premultipliedLast.rawValue
        guard W > 0, H > 0, let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: float ? 16 : 8, bytesPerRow: 0,
                                                space: cs, bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: k, y: k)
        ctx.translateBy(x: -frame.minX, y: -frame.minY)
        drawBackground(in: ctx, frame: frame, style: style, wallpaper: wallpaper)
        // 截图：圆角里面画，外面一圈柔和的影子（影子的大小按像素算，不跟着 CTM 缩放）
        let shot = CGPath(roundedRect: selection, cornerWidth: corner, cornerHeight: corner, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -BeautyLayout.shadowOffset * k), blur: BeautyLayout.shadowBlur * k,
                      color: CGColor(gray: 0, alpha: BeautyLayout.shadowAlpha))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addPath(shot)
        ctx.clip()
        ctx.draw(image, in: imageRect)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
        guard let out = ctx.makeImage() else { return nil }
        return image.contentHeadroom >= 1 ? (CGImageCreateCopyWithContentHeadroom(image.contentHeadroom, out) ?? out) : out
    }

    /// 窗口截图后面垫上壁纸：imageRect 是这张图在屏幕上的范围（截图界面坐标，原点左下），
    /// 壁纸铺满整块屏幕（screenSize），只留图后面那一块。窗口在屏幕外的那截后面是透明的
    static func underlay(_ image: CGImage, imageRect: CGRect, screenSize: CGSize, wallpaper: CGImage) -> CGImage? {
        let k = CGFloat(image.width) / imageRect.width
        let cs = image.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)!
        let float = image.bitsPerComponent > 8
        let info: UInt32 = float
            ? CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: float ? 16 : 8,
                                  bytesPerRow: 0, space: cs, bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: k, y: k)
        ctx.translateBy(x: -imageRect.minX, y: -imageRect.minY)
        // 壁纸按屏幕比例铺满（和桌面上看到的一样），截下来的壁纸本来就是这块屏幕大小
        let screen = CGRect(origin: .zero, size: screenSize)
        let iw = CGFloat(wallpaper.width), ih = CGFloat(wallpaper.height)
        let s = max(screen.width / iw, screen.height / ih)
        ctx.saveGState()
        ctx.clip(to: screen)
        ctx.draw(wallpaper, in: CGRect(x: screen.midX - iw * s / 2, y: screen.midY - ih * s / 2, width: iw * s, height: ih * s))
        ctx.restoreGState()
        ctx.draw(image, in: imageRect)
        guard let out = ctx.makeImage() else { return nil }
        return image.contentHeadroom >= 1 ? (CGImageCreateCopyWithContentHeadroom(image.contentHeadroom, out) ?? out) : out
    }

    static func drawBackground(in ctx: CGContext, frame: CGRect, style: BeautyStyle, wallpaper: CGImage?) {
        let bg = style.background
        if let colors = bg.gradient, let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil) {
            ctx.saveGState()
            ctx.clip(to: frame)
            ctx.drawLinearGradient(g, start: CGPoint(x: frame.minX, y: frame.maxY), end: CGPoint(x: frame.maxX, y: frame.minY), options: [])
            ctx.restoreGState()
        } else if bg == .wallpaper, let w = wallpaper {
            ctx.saveGState()
            ctx.clip(to: frame)
            let iw = CGFloat(w.width), ih = CGFloat(w.height)
            let s = max(frame.width / iw, frame.height / ih)
            ctx.draw(w, in: CGRect(x: frame.midX - iw * s / 2, y: frame.midY - ih * s / 2, width: iw * s, height: ih * s))
            ctx.restoreGState()
        } else if let c = bg.solid ?? (bg == .wallpaper ? BeautyBackground.sunset.gradient?.first : nil) {
            ctx.setFillColor(c)
            ctx.fill(frame)
        }
        // .clear：什么都不画（透明）
    }
}

/// 截图界面上的预览：背景、影子、圆角的截图。挂在暗的那层上面、画的东西下面
@MainActor
final class BeautyPreview {
    let layer = CALayer()
    private let bg = CALayer()
    private let grad = CAGradientLayer()
    private let shadow = CALayer()
    private let shot = CALayer()
    private let shotMask = CAShapeLayer()

    init(bounds: CGRect) {
        layer.frame = bounds
        layer.isHidden = true
        bg.masksToBounds = true
        bg.contentsGravity = .resizeAspectFill
        bg.addSublayer(grad)
        grad.startPoint = CGPoint(x: 0, y: 1)
        grad.endPoint = CGPoint(x: 1, y: 0)
        shadow.frame = bounds
        shadow.shadowColor = NSColor.black.cgColor
        shadow.shadowOpacity = Float(BeautyLayout.shadowAlpha)
        shadow.shadowRadius = BeautyLayout.shadowBlur / 2
        shadow.shadowOffset = CGSize(width: 0, height: -BeautyLayout.shadowOffset)
        shot.frame = bounds
        shot.contentsGravity = .resize
        shotMask.frame = bounds
        shot.mask = shotMask
        for l in [bg, shadow, shot] { layer.addSublayer(l) }
    }

    /// selection nil：不显示
    func update(selection: CGRect?, corner: CGFloat, style: BeautyStyle, image: CGImage, wallpaper: CGImage?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let s = selection else { layer.isHidden = true; return }
        layer.isHidden = false
        let f = BeautyLayout.frame(for: s, style: style)
        bg.frame = f
        grad.frame = bg.bounds
        let b = style.background
        grad.isHidden = b.gradient == nil
        grad.colors = b.gradient
        bg.contents = b == .wallpaper ? wallpaper : nil
        bg.backgroundColor = b.solid ?? (b == .clear ? Self.checker : (b == .wallpaper && wallpaper == nil ? b.gradient?.first : nil))
        let path = CGPath(roundedRect: s, cornerWidth: corner, cornerHeight: corner, transform: nil)
        shadow.shadowPath = path
        shotMask.path = path
        if shot.contents as! CGImage? !== image { shot.contents = image }
    }

    /// 透明背景：灰白格子
    private static let checker: CGColor = {
        let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in
            NSColor.white.setFill(); r.fill()
            NSColor(white: 0.86, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 8, height: 8).fill()
            NSRect(x: 8, y: 8, width: 8, height: 8).fill()
            return true
        }
        return NSColor(patternImage: img).cgColor
    }()
}

/// 背景的小条：七个背景、边距 S M L、比例
@MainActor
final class BeautyBar: GlassBar {
    var onChange: ((BeautyStyle) -> Void)?
    private var style: BeautyStyle
    private var swatches: [BeautySwatch] = []
    private var paddingButtons: [BarButton] = []
    private var ratioButtons: [BarButton] = []

    override var barHeight: CGFloat { 36 }

    init(style: BeautyStyle, wallpaper: CGImage?) {
        self.style = style
        super.init(frame: .zero)
        for b in BeautyBackground.allCases {
            let s = BeautySwatch(background: b, wallpaper: wallpaper)
            s.toolTip = b.title
            s.onClick = { [weak self] in self?.set { $0.background = b } }
            swatches.append(s)
            stack.addArrangedSubview(s)
        }
        stack.addArrangedSubview(BarSeparator(height: 16))
        for (i, t) in ["S", "M", "L"].enumerated() {
            let b = Self.segment(t)
            b.onClick = { [weak self] _ in self?.set { $0.padding = i } }
            paddingButtons.append(b)
            stack.addArrangedSubview(b)
        }
        stack.addArrangedSubview(BarSeparator(height: 16))
        for (i, r) in BeautyStyle.ratios.enumerated() {
            let b = Self.segment(r.title)
            b.onClick = { [weak self] _ in self?.set { $0.ratio = i } }
            ratioButtons.append(b)
            stack.addArrangedSubview(b)
        }
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 7, bottom: 0, right: 6)
        setupGlass()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func segment(_ t: String) -> BarButton {
        let b = BarButton(title: t, trailingSymbol: nil, padding: 7)
        b.label?.font = .systemFont(ofSize: 12, weight: .medium)
        return b
    }

    private func set(_ f: (inout BeautyStyle) -> Void) {
        f(&style)
        style.save()
        refresh()
        onChange?(style)
    }

    private func refresh() {
        for (i, s) in swatches.enumerated() { s.isSelected = i == style.background.rawValue }
        for (i, b) in paddingButtons.enumerated() { b.isSelected = i == style.padding }
        for (i, b) in ratioButtons.enumerated() { b.isSelected = i == style.ratio }
    }

    func animateIn(below: Bool) {
        animateIn(anchor: CGPoint(x: 0.5, y: below ? 1 : 0), scale: 0.94, offsetY: below ? -4 : 4)
    }
}

/// 一个背景小方块：渐变、壁纸缩略图、纯色、透明格子。选中时外面一圈环
@MainActor
final class BeautySwatch: NSView {
    var onClick: (() -> Void)?
    let background: BeautyBackground
    private let wallpaper: CGImage?
    var isSelected = false { didSet { needsDisplay = true } }

    init(background: BeautyBackground, wallpaper: CGImage?) {
        self.background = background
        self.wallpaper = wallpaper
        super.init(frame: CGRect(x: 0, y: 0, width: 27, height: 28))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 27).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = CGRect(x: bounds.midX - 10, y: bounds.midY - 10, width: 20, height: 20)
        if isSelected {
            let ring = NSBezierPath(roundedRect: r.insetBy(dx: -3, dy: -3), xRadius: 8.5, yRadius: 8.5)
            NSColor(white: 0, alpha: 0.78).setStroke()
            ring.lineWidth = 1.5
            ring.stroke()
        }
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.clip()
        if background == .clear {
            NSColor.white.setFill(); r.fill()
            NSColor(white: 0.84, alpha: 1).setFill()
            for y in 0..<4 { for x in 0..<4 where (x + y) % 2 == 0 { CGRect(x: r.minX + CGFloat(x) * 5, y: r.minY + CGFloat(y) * 5, width: 5, height: 5).fill() } }
        } else {
            BeautyRenderer.drawBackground(in: ctx, frame: r, style: BeautyStyle(background: background), wallpaper: wallpaper)
        }
        ctx.restoreGState()
        let edge = NSBezierPath(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), xRadius: 6, yRadius: 6)
        NSColor(white: 0, alpha: 0.16).setStroke()
        edge.lineWidth = 0.5
        edge.stroke()
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
}
