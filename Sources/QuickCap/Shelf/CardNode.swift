import AppKit
import QuartzCore

/// 卡片上的操作。trash 和 pin 是图片左上角、右上角的圆形按钮，其余在卡片下方的工具栏里。
enum ShelfAction: CaseIterable {
    case edit, copy, recognizeText, revealInFinder, trash, pin

    /// 工具栏里的按钮，从左到右
    static let toolbarActions: [ShelfAction] = [.edit, .copy, .recognizeText, .revealInFinder]

    var symbol: String {
        switch self {
        case .edit: return "pencil.tip"
        case .copy: return "doc.on.doc"
        case .recognizeText: return "text.viewfinder"
        case .revealInFinder: return "folder"
        case .trash: return "trash"
        case .pin: return "pin"
        }
    }

    /// 工具栏按钮的悬停提示
    var title: String {
        switch self {
        case .edit: return "Annotate  ⌥-click"
        case .copy: return "Copy Image"
        case .recognizeText: return "Copy Text"
        case .revealInFinder: return "Show in Finder"
        case .trash: return "Move to Trash"
        case .pin: return "Pin to Front"
        }
    }
}

/// 一张挂着的卡片：挂绳 + 缩略图。悬停时左上角出现移到废纸篓、右上角出现置顶按钮，下方出现工具栏。
/// 置顶后右上角一直显示一个橙色的小图钉。
/// container 的锚点在绳子穿过挂绳的位置，旋转就围绕这个点。
/// 工具栏不放在 container 里：卡片摆动时它保持水平，只跟着挂点上下左右移动。
@MainActor
final class CardNode {
    enum Phase { case flying, hanging, falling }

    let item: ShelfItem
    let size: CGSize
    /// 在整排里的位置（0 在最左边：置顶的，然后从新到旧）。ShelfView 重排时写进来
    var index = 0
    /// 缩略图。卡片先建出来（灰底），图在后台生成好再放进去
    var thumbnail: CGImage? {
        didSet {
            guard let thumbnail else { return }
            let first = !hasImage
            setCardImage(thumbnail)
            // 图到位时淡入，不会"啪"一下出现（已经有图顶着时直接换，不再从透明淡入）
            guard first else { return }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.duration = 0.18
            imageLayer.add(fade, forKey: "fade")
        }
    }
    /// 卡片上已经有图了（缩略图，或者换屏幕倍数时先顶着的旧图）
    private var hasImage = false

    /// 新的缩略图还没好时先用这张顶着（换屏幕倍数时用旧的那张）
    func showStopgap(_ t: CGImage) {
        guard !hasImage else { return }
        setCardImage(t)
    }

    /// 卡片上显示的图：圆角、细边都画在图里（见 ShelfThumbnails.cardImage），图层本身不裁
    private func setCardImage(_ t: CGImage) {
        // 一般已经是做好的卡片图（大小对得上）；不是的话（别处给的原图）在这里切
        let scale = imageLayer.contentsScale
        let b = imageLayer.bounds.size
        let ready = abs(CGFloat(t.width) - b.width * scale) <= 1 && abs(CGFloat(t.height) - b.height * scale) <= 1
        let img = ready ? t : (ShelfThumbnails.cardImage(t, size: b, corner: max(Metrics.cardCorner - Metrics.framePadding, 0), scale: scale) ?? t)
        imageLayer.contents = img
        imageLayer.backgroundColor = nil
        hasImage = true
    }
    /// 搜索：对不上的变淡；对上的那几行字涂一层黄（boxes 是 0…1、原点左下，和 Vision 一样）。nil：没在搜
    /// 上一次画的高亮（一样就不重画：后台认好一张字、搜索结果刷新时，看得见的卡片不用全部拆了重建）
    private var shownSearchBoxes: [CGRect]?? = .none
    func setSearch(_ boxes: [CGRect]?) {
        if case .some(let old) = shownSearchBoxes, old == boxes { return }
        shownSearchBoxes = .some(boxes)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        highlightLayers.forEach { $0.removeFromSuperlayer() }
        highlightLayers = []
        if let boxes {
            let b = imageLayer.bounds
            let px = item.pixelSize
            let k = max(b.width / max(px.width, 1), b.height / max(px.height, 1))
            let dw = px.width * k, dh = px.height * k
            let ox = (b.width - dw) / 2, oy = (b.height - dh) / 2
            for r in boxes {
                let l = CALayer()
                // 图层是 y 向下的：Vision 的 y 要翻过来
                l.frame = CGRect(x: ox + r.minX * dw - 1, y: oy + (1 - r.maxY) * dh - 1, width: r.width * dw + 2, height: r.height * dh + 2)
                l.backgroundColor = NSColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 0.5).cgColor
                l.cornerRadius = 1.5
                l.compositingFilter = "multiplyBlendMode"
                imageLayer.addSublayer(l)
                highlightLayers.append(l)
            }
        }
        CATransaction.commit()
    }
    private var highlightLayers: [CALayer] = []
    private var searchDimmed = false
    var isSearchDimmed: Bool { searchDimmed }

    /// 搜索时对不上：整张变淡、去色
    func setSearchDimmed(_ on: Bool) {
        guard on != searchDimmed else { return }
        searchDimmed = on
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        body.opacity = on ? 0.32 : 1
        clip.opacity = on ? 0.32 : 1
        CATransaction.commit()
    }

    /// 正在后台生成缩略图的请求，卡片被回收时取消
    var thumbnailToken: ShelfThumbnails.Token?
    let container = CALayer()
    let body = CALayer()
    let imageLayer = CALayer()
    let clip = CALayer()
    /// 悬停时盖在图片上的一层很淡的暗色，上边略深，让角上的按钮在浅色图片上也看得清
    let shade = CAGradientLayer()
    /// 文件在截图文件夹里（悬挂架管着它）。不在的话角上是"取下"，只从绳子上拿下来，不删文件
    let ownsFile: Bool
    /// 图片左上角：移到废纸篓（鼠标停在上面时变红），或者取下
    let trashButton = CALayer()
    private let trashIcon = CALayer(), trashIconHot = CALayer()
    /// 图片右上角：置顶。置顶后变成橙色的实心图钉，不悬停也显示
    let pinButton = CALayer()
    private let pinIcon = CALayer(), pinIconOn = CALayer()
    /// 是否置顶
    var isPinned = false
    /// 悬停时出现在卡片下方的工具栏（放在 ShelfView 的工具栏图层里，坐标是根图层坐标）
    let toolbar = CALayer()
    private var buttonLayers: [CALayer] = []
    /// 鼠标正停在哪个按钮上
    var hoveredAction: ShelfAction? {
        didSet { if oldValue != hoveredAction { updateButtonHighlight(); updateTip() } }
    }
    /// 工具栏按钮的提示：鼠标停一会儿后出现在工具栏下面
    private let tip = CALayer()
    private let tipText = CATextLayer()
    private var tipDwell: CGFloat = 0
    private var tipShown = false
    private var tipLevel: CGFloat = 0
    private static let tipDelay: CGFloat = 0.45
    private static let tipFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    var phase: Phase = .flying

    /// 在绳子上的位置：离屏幕边缘的距离（内容坐标）。换位置时弹簧滑过去
    var slide = Spring(0)
    /// 还要等多久才开始滑（秒）。删掉旁边一张时，先让那张掉下去再补位
    var slideDelay: CGFloat = 0
    /// 展开收起的进度，见 RevealMotion
    var reveal = RevealMotion()
    /// 屏幕上的横坐标，由 ShelfView 按 slide、滚动量和展开进度算好写进来
    var x: CGFloat = 0

    // 挂点和摆动。bob 是卡片重心，用 Verlet 积分，和挂点之间是定长约束。
    var hang = CGPoint.zero
    var bob = CGPoint.zero
    var bobPrev = CGPoint.zero
    var angle: CGFloat = 0
    /// 上一次摆动积分的步长，用来把推力（pt/秒）换算成 Verlet 的位移
    var lastSwingStep: CGFloat = 1.0 / 240
    /// 上一步挂点的横向位移，和这一步相减得到挂点加速度
    var lastHangDelta: CGFloat = 0
    /// 等待触发的摆动：剩余延迟（秒）和幅度（弧度）
    var pendingSway: (delay: CGFloat, angle: CGFloat)?
    var length: CGFloat { bodyTop + size.height / 2 }

    // 飞入
    var flightFrom = CGPoint.zero
    var flightScale: CGFloat = 1.4
    var flightT: CGFloat = 0
    /// 出发前在起点停多久（悬挂架刚从收起展开时，等整排先滑出来）
    var flightDelay: CGFloat = 0
    /// 落到绳子上时调用一次
    var onLanded: (() -> Void)?
    /// 挂绳的不透明度：从截图里接手飞出来的卡片一开始没有挂绳，飞的路上才出现
    var clipOpacity: Float = 1
    let flightDuration: CGFloat = 0.55

    // 掉落
    var position = CGPoint.zero
    var velocity = CGPoint.zero
    var spin: CGFloat = 0
    var fallAge: CGFloat = 0

    // 显示
    var scale: CGFloat = 1
    var opacity: Float = 1
    var hover: CGFloat = 0
    var hoverTarget: CGFloat = 0
    /// 鼠标停在角上按钮上时的高亮进度，0...1
    private var trashHover: CGFloat = 0
    private var pinHover: CGFloat = 0
    /// 置顶标记的显示进度，0...1（置顶/取消时淡入淡出）
    private var pinnedLevel: CGFloat = 0

    /// 卡片顶边离挂点的距离
    var bodyTop: CGFloat { Metrics.clipGripY - Metrics.clipRopeY }

    init(item: ShelfItem, ownsFile: Bool = true, thumbnail: CGImage?, clipImage: CGImage?, contentsScale: CGFloat) {
        self.thumbnail = thumbnail
        self.item = item
        self.ownsFile = ownsFile
        self.size = Metrics.cardSize(for: item.pixelSize)

        // 卡片里加减子图层（拿下来改时的虚线空位、提示气泡、搜索高亮）时，系统默认整张卡片交叉淡化 0.25 秒：
        // 卡片在摆、在滑时就是两份叠着；拿下来改时原图慢慢淡掉，和放大出去的编辑窗口重成两张
        container.actions = ["sublayers": NSNull()]
        imageLayer.actions = ["sublayers": NSNull()]
        container.bounds = CGRect(x: 0, y: 0, width: size.width, height: bodyTop + size.height)
        container.anchorPoint = CGPoint(x: 0.5, y: 0)
        container.contentsScale = contentsScale

        let corner = Metrics.cardCorner
        body.frame = CGRect(x: 0, y: bodyTop, width: size.width, height: size.height)
        body.backgroundColor = NSColor(white: 0.97, alpha: 1).cgColor
        body.cornerRadius = corner
        body.cornerCurve = .continuous
        body.shadowColor = NSColor.black.cgColor
        body.shadowPath = CGPath(roundedRect: body.bounds, cornerWidth: corner, cornerHeight: corner, transform: nil)

        let p = Metrics.framePadding
        imageLayer.frame = body.bounds.insetBy(dx: p, dy: p)
        // 图还没好时先显示浅灰底（只是圆角的底色，不裁内容，不多画一遍）
        imageLayer.backgroundColor = NSColor(white: 0.90, alpha: 1).cgColor
        imageLayer.cornerRadius = max(corner - p, 0)
        imageLayer.cornerCurve = .continuous
        imageLayer.contentsScale = contentsScale
        imageLayer.contentsGravity = .resize
        if let thumbnail { setCardImage(thumbnail) }
        body.addSublayer(imageLayer)

        shade.frame = imageLayer.frame
        shade.cornerRadius = imageLayer.cornerRadius
        shade.cornerCurve = .continuous
        shade.colors = [NSColor(white: 0, alpha: 0.20).cgColor, NSColor(white: 0, alpha: 0.05).cgColor]
        // 根图层 y 轴向下：startPoint (0.5,0) 是上边中间
        shade.startPoint = CGPoint(x: 0.5, y: 0)
        shade.endPoint = CGPoint(x: 0.5, y: 0.75)
        shade.opacity = 0
        body.addSublayer(shade)

        buildCornerButtons(contentsScale: contentsScale)
        body.addSublayer(trashButton)
        body.addSublayer(pinButton)

        let cs = Metrics.clipSize
        clip.frame = CGRect(x: size.width / 2 - cs.width / 2, y: -Metrics.clipRopeY,
                            width: cs.width, height: cs.height)
        clip.contents = clipImage
        clip.contentsScale = contentsScale
        clip.shadowColor = NSColor.black.cgColor
        clip.shadowOpacity = 0.18
        clip.shadowRadius = 1
        clip.shadowOffset = CGSize(width: 0, height: 1)
        clip.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: cs).insetBy(dx: cs.width * 0.18, dy: 0), cornerWidth: 2, cornerHeight: 2, transform: nil)

        container.addSublayer(body)
        container.addSublayer(clip)
        buildToolbar(contentsScale: contentsScale)
    }

    // MARK: 角上的按钮

    /// 角上按钮在卡片 body 坐标里的位置
    private var trashFrame: CGRect {
        let d = Metrics.cornerButtonSize, m = Metrics.cornerButtonInset
        return CGRect(x: m, y: m, width: d, height: d)
    }
    private var pinFrame: CGRect {
        let d = Metrics.cornerButtonSize, m = Metrics.cornerButtonInset
        return CGRect(x: size.width - m - d, y: m, width: d, height: d)
    }

    private func styleCornerButton(_ b: CALayer, frame f: CGRect) {
        b.frame = f
        b.cornerRadius = f.width / 2
        b.backgroundColor = NSColor(white: 0.96, alpha: 0.92).cgColor
        b.borderWidth = 0.5
        b.borderColor = NSColor(white: 0, alpha: 0.08).cgColor
        b.shadowColor = NSColor.black.cgColor
        b.shadowOpacity = 0.2
        b.shadowRadius = 2
        b.shadowOffset = CGSize(width: 0, height: 1)
        b.shadowPath = CGPath(ellipseIn: CGRect(origin: .zero, size: f.size), transform: nil)
        b.opacity = 0
    }

    private func buildCornerButtons(contentsScale s: CGFloat) {
        let dark = NSColor(white: 0.2, alpha: 1)
        let pt = Metrics.cornerIconPointSize
        styleCornerButton(trashButton, frame: trashFrame)
        styleCornerButton(pinButton, frame: pinFrame)
        let box = trashFrame.size
        // 每个按钮两层图标交叉淡入淡出：平时深灰，鼠标停留（垃圾桶）或置顶后（图钉）变白
        let trashSymbol = ownsFile ? "trash" : "xmark"
        for (layer, name, color, host) in [(trashIcon, trashSymbol, dark, trashButton), (trashIconHot, trashSymbol, NSColor.white, trashButton),
                                           (pinIcon, "pin", dark, pinButton), (pinIconOn, "pin.fill", NSColor.white, pinButton)] {
            let icon = Self.iconLayer(name, in: box, pointSize: pt, weight: .semibold, color: color, scale: s)
            layer.frame = icon.frame
            layer.contents = icon.contents
            layer.contentsScale = s
            host.addSublayer(layer)
        }
        trashIconHot.opacity = 0
        pinIconOn.opacity = 0
    }

    // MARK: 工具栏

    private var toolbarSize: CGSize {
        let b = Metrics.toolbarButton
        let n = CGFloat(ShelfAction.toolbarActions.count)
        return CGSize(width: n * b.width + 2 * Metrics.toolbarPadding, height: Metrics.toolbarHeight)
    }

    /// 工具栏在根图层坐标里的位置：挂点正下方，和卡片底边隔一段距离，不跟着卡片旋转
    private var toolbarFrame: CGRect {
        let s = toolbarSize
        let top = hang.y + bodyTop + size.height + Metrics.toolbarGap
        return CGRect(x: hang.x - s.width / 2, y: top, width: s.width, height: s.height)
    }

    private func buildToolbar(contentsScale: CGFloat) {
        let s = toolbarSize
        toolbar.bounds = CGRect(origin: .zero, size: s)
        toolbar.backgroundColor = NSColor(white: 0.985, alpha: 0.96).cgColor
        toolbar.cornerRadius = s.height / 2
        toolbar.cornerCurve = .continuous
        toolbar.borderWidth = 0.5
        toolbar.borderColor = NSColor(white: 0, alpha: 0.07).cgColor
        toolbar.shadowColor = NSColor.black.cgColor
        toolbar.shadowOpacity = 0.14
        toolbar.shadowRadius = 7
        toolbar.shadowOffset = CGSize(width: 0, height: 2.5)
        toolbar.shadowPath = CGPath(roundedRect: toolbar.bounds, cornerWidth: s.height / 2,
                                    cornerHeight: s.height / 2, transform: nil)
        toolbar.opacity = 0
        toolbar.contentsScale = contentsScale

        let b = Metrics.toolbarButton
        for (i, action) in ShelfAction.toolbarActions.enumerated() {
            let button = CALayer()
            button.frame = CGRect(x: Metrics.toolbarPadding + CGFloat(i) * b.width, y: (s.height - b.height) / 2,
                                  width: b.width, height: b.height)
            button.cornerRadius = b.height / 2
            button.cornerCurve = .continuous
            button.addSublayer(Self.iconLayer(action.symbol, in: b, pointSize: Metrics.toolbarIconPointSize,
                                              weight: .semibold, color: NSColor(white: 0.14, alpha: 1), scale: contentsScale))
            toolbar.addSublayer(button)
            buttonLayers.append(button)
        }

        tip.backgroundColor = NSColor(white: 0.12, alpha: 0.88).cgColor
        tip.cornerRadius = 6
        tip.cornerCurve = .continuous
        tip.opacity = 0
        tipText.font = Self.tipFont
        tipText.fontSize = Self.tipFont.pointSize
        tipText.foregroundColor = NSColor.white.cgColor
        tipText.alignmentMode = .center
        tipText.contentsScale = contentsScale
        tip.addSublayer(tipText)
        toolbar.addSublayer(tip)
    }

    private var hoveringToolbarButton: Bool {
        hoveredAction.map { ShelfAction.toolbarActions.contains($0) } ?? false
    }

    /// 换了按钮：提示已经显示着就马上换字，没显示就重新计时
    private func updateTip() {
        guard let a = hoveredAction, let i = ShelfAction.toolbarActions.firstIndex(of: a) else {
            tipShown = false
            tipDwell = 0
            return
        }
        if tipLevel < 0.5 { tipShown = false; tipDwell = 0 }
        let w = (a.title as NSString).size(withAttributes: [.font: Self.tipFont]).width.rounded(.up) + 14
        let b = Metrics.toolbarButton
        let cx = Metrics.toolbarPadding + (CGFloat(i) + 0.5) * b.width
        withoutAnimation {
            tip.frame = CGRect(x: (cx - w / 2).rounded(), y: toolbarSize.height + 6, width: w, height: 20)
            tipText.frame = CGRect(x: 0, y: 3, width: w, height: 14)
            tipText.string = a.title
        }
    }

    /// 按钮的浅灰底色淡入淡出：进入 0.1 秒，离开稍慢一点 0.15 秒。
    /// 从当前显示的颜色开始过渡，鼠标在按钮间快速移动时不会跳。
    private func updateButtonHighlight() {
        let on = NSColor(white: 0, alpha: 0.07).cgColor
        let off = NSColor(white: 0, alpha: 0).cgColor
        for (i, action) in ShelfAction.toolbarActions.enumerated() {
            let layer = buttonLayers[i]
            let lit = action == hoveredAction
            let target = lit ? on : off
            let current = layer.backgroundColor ?? off
            guard current.alpha != target.alpha else { continue }
            let from = layer.presentation()?.backgroundColor ?? current
            withoutAnimation { layer.backgroundColor = target }
            let fade = CABasicAnimation(keyPath: "backgroundColor")
            fade.fromValue = from
            fade.toValue = target
            fade.duration = lit ? 0.1 : 0.15
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "highlight")
        }
    }

    /// 按 SF Symbol 自己的尺寸渲染成位图，返回图片、显示尺寸（pt）和实际笔画的中心（pt，图片左上角为原点）。
    /// 不能塞进固定的正方形：很多符号比字号高（doc.on.doc 是 14×16），会被裁掉上下。
    /// 符号图片四周的留白也不对称，按图片框居中时笔画会偏，所以另外量出笔画的位置。
    static func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight,
                       color: NSColor, scale: CGFloat) -> (image: CGImage, size: CGSize, inkCenter: CGPoint)? {
        // 每张卡片都有同样的十来个图标：画一次存着（快速滑动时一下要建好几张卡片，不用每张都重画）
        let key = "\(name)|\(pointSize)|\(weight.rawValue)|\(color.description)|\(scale)"
        if let hit = symbolCache[key] { return hit }
        let made = renderSymbol(name, pointSize: pointSize, weight: weight, color: color, scale: scale)
        symbolCache[key] = made
        return made
    }
    private static var symbolCache: [String: (image: CGImage, size: CGSize, inkCenter: CGPoint)?] = [:]

    private static func renderSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight,
                                     color: NSColor, scale: CGFloat) -> (image: CGImage, size: CGSize, inkCenter: CGPoint)? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight, scale: .medium)
            .applying(.init(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        let size = image.size
        let w = Int((size.width * scale).rounded(.up)), h = Int((size.height * scale).rounded(.up))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return nil }
        let shown = CGSize(width: CGFloat(w) / scale, height: CGFloat(h) / scale)
        return (cg, shown, inkCenter(of: ctx, width: w, height: h, scale: scale) ?? CGPoint(x: shown.width / 2, y: shown.height / 2))
    }

    /// 位图里不透明像素的外接框中心。CGContext 的内存第一行是图片最上面一行。
    private static func inkCenter(of ctx: CGContext, width w: Int, height h: Int, scale: CGFloat) -> CGPoint? {
        guard let data = ctx.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self), row = ctx.bytesPerRow
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h { for x in 0..<w where bytes[y * row + x * 4 + 3] > 40 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= minX else { return nil }
        return CGPoint(x: CGFloat(minX + maxX + 1) / 2 / scale, y: CGFloat(minY + maxY + 1) / 2 / scale)
    }

    /// 把符号放进 box 里居中的图层
    /// 把符号放进 box 里，按笔画居中，对齐到像素
    static func iconLayer(_ name: String, in box: CGSize, pointSize: CGFloat, weight: NSFont.Weight,
                          color: NSColor, scale: CGFloat) -> CALayer {
        let l = CALayer()
        l.contentsScale = scale
        guard let s = symbol(name, pointSize: pointSize, weight: weight, color: color, scale: scale) else { return l }
        l.contents = s.image
        // 根图层 y 轴向下，和位图的行顺序一致
        let snap = { (v: CGFloat) in (v * scale).rounded() / scale }
        l.frame = CGRect(x: snap(box.width / 2 - s.inkCenter.x), y: snap(box.height / 2 - s.inkCenter.y),
                         width: s.size.width, height: s.size.height)
        return l
    }

    /// point 是根图层坐标。悬停时返回落在哪个按钮上（关闭按钮或工具栏按钮）。
    func action(at point: CGPoint, in root: CALayer) -> ShelfAction? {
        guard hover > 0.5, phase == .hanging else { return nil }
        let local = body.convert(point, from: root)
        if trashFrame.insetBy(dx: -4, dy: -4).contains(local) { return .trash }
        if pinFrame.insetBy(dx: -4, dy: -4).contains(local) { return .pin }
        let f = toolbarFrame
        guard f.insetBy(dx: -2, dy: -2).contains(point) else { return nil }
        let i = Int((point.x - f.minX - Metrics.toolbarPadding) / Metrics.toolbarButton.width)
        let actions = ShelfAction.toolbarActions
        return actions.indices.contains(i) ? actions[i] : nil
    }

    func updateClip(_ image: CGImage?, scale: CGFloat) {
        clip.contents = image
        for l in [container, imageLayer, clip, toolbar, tipText] { l.contentsScale = scale }
    }

    func stepHoverDetail(_ dt: CGFloat) {
        func approach(_ v: inout CGFloat, _ target: CGFloat, rate: CGFloat) {
            v += (target - v) * (1 - exp(-rate * dt))
            if abs(target - v) < 0.002 { v = target }
        }
        approach(&trashHover, hoveredAction == .trash ? 1 : 0, rate: 24)
        approach(&pinHover, hoveredAction == .pin ? 1 : 0, rate: 24)
        approach(&pinnedLevel, isPinned ? 1 : 0, rate: 16)
        if hoveringToolbarButton && !tipShown {
            tipDwell += dt
            if tipDwell >= Self.tipDelay { tipShown = true }
        }
        approach(&tipLevel, tipShown && hoveringToolbarButton ? 1 : 0, rate: 22)
    }

    func snapPinnedLevel() { pinnedLevel = isPinned ? 1 : 0 }

    var hoverDetailSettled: Bool {
        trashHover == (hoveredAction == .trash ? 1 : 0) && pinHover == (hoveredAction == .pin ? 1 : 0)
            && pinnedLevel == (isPinned ? 1 : 0)
            && tipLevel == (tipShown && hoveringToolbarButton ? 1 : 0)
            // 还在等提示出来，动画循环不能停
            && !(hoveringToolbarButton && !tipShown)
    }

    /// 把当前状态写进图层（调用方负责关闭隐式动画）。
    func apply() {
        // 停稳了：摆正、落到整像素上。不然停下时还带着零点几度的角度、半个像素的位置，缩略图里的字和图标会略糊
        let resting = phase == .hanging && scale == 1 && isSettled
        var pos = phase == .hanging ? hang : position
        if resting {
            let s = max(container.contentsScale, 1), w = container.bounds.width
            pos = CGPoint(x: ((pos.x - w / 2) * s).rounded() / s + w / 2, y: (pos.y * s).rounded() / s)
        }
        container.position = pos
        container.transform = CATransform3DConcat(CATransform3DMakeScale(scale, scale, 1),
                                                  CATransform3DMakeRotation(resting ? 0 : angle, 0, 0, 1))
        container.opacity = opacity
        clip.opacity = clipOpacity
        // 悬停时不放大，阴影变深变散，看起来稍微离开了背景
        let e = hover * hover * (3 - 2 * hover)
        body.shadowOpacity = Float(0.20 + 0.10 * e)
        body.shadowRadius = 6 + 6 * e
        body.shadowOffset = CGSize(width: 0, height: 3 + 4 * e)
        shade.opacity = Float(e)
        shade.isHidden = e < 0.001

        // 角上的按钮：比暗色层稍晚一点淡入，不缩放
        let ct = min(max((hover - 0.15) / 0.85, 0), 1)
        let buttons = Float(1 - pow(1 - ct, 3))
        let white = NSColor(white: 0.96, alpha: 0.92)
        // 垃圾桶：鼠标停在上面时底色变红、图标变白
        trashButton.opacity = buttons
        // 看不见的就藏起来，不参与合成（每张卡片都有影子，十几张一起滚时系统要画很多）
        trashButton.isHidden = buttons < 0.001
        // 取下不删文件，不用红色吓人
        let hot = ownsFile ? Metrics.trashColor : NSColor(white: 0.32, alpha: 1)
        trashButton.backgroundColor = Self.mix(white, hot, trashHover).cgColor
        trashButton.shadowOpacity = Float(0.2 + 0.12 * trashHover)
        trashIconHot.opacity = Float(trashHover)
        trashIcon.opacity = Float(1 - trashHover)
        // 图钉：没置顶时和垃圾桶一样跟着悬停出现；置顶后一直显示橙色实心图钉
        let p = pinnedLevel
        pinButton.opacity = max(buttons, Float(p))
        pinButton.isHidden = pinButton.opacity < 0.001
        let pinBase = Self.mix(white, Metrics.pinColor, p)
        pinButton.backgroundColor = Self.mix(pinBase, p > 0.5 ? NSColor(white: 0, alpha: 1) : NSColor.white, pinHover * 0.12).cgColor
        pinButton.shadowOpacity = Float(0.2 + 0.12 * max(pinHover, p))
        pinIconOn.opacity = Float(p)
        pinIcon.opacity = Float(1 - p)

        // 工具栏比卡片晚一点出现，从上方轻轻落下，不缩放。保持水平，不跟着摆
        let visible = phase == .hanging
        let t = visible ? min(max((hover - 0.3) / 0.7, 0), 1) : 0
        let te = 1 - pow(1 - t, 3)
        let f = toolbarFrame
        let ts = max(toolbar.contentsScale, 1)
        toolbar.position = CGPoint(x: (f.minX * ts).rounded() / ts + f.width / 2, y: (f.minY * ts).rounded() / ts + f.height / 2)
        toolbar.opacity = Float(te) * opacity
        toolbar.isHidden = toolbar.opacity < 0.001
        toolbar.transform = CATransform3DMakeTranslation(0, -5 * (1 - te), 0)
        tip.opacity = Float(tipLevel)
    }

    /// 两个颜色按 t 线性混合（包括透明度）
    static func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        guard let a = a.usingColorSpace(.deviceRGB), let b = b.usingColorSpace(.deviceRGB) else { return a }
        let k = min(max(t, 0), 1)
        return NSColor(deviceRed: a.redComponent + (b.redComponent - a.redComponent) * k,
                       green: a.greenComponent + (b.greenComponent - a.greenComponent) * k,
                       blue: a.blueComponent + (b.blueComponent - a.blueComponent) * k,
                       alpha: a.alphaComponent + (b.alphaComponent - a.alphaComponent) * k)
    }

    /// point 是根图层坐标，判断是否落在卡片（含挂绳，工具栏可见时也算）上。
    func contains(_ point: CGPoint, in root: CALayer) -> Bool {
        let local = container.convert(point, from: root)
        if body.frame.insetBy(dx: -2, dy: -2).union(clip.frame).contains(local) { return true }
        guard hover > 0.3, phase == .hanging else { return false }
        // 卡片和工具栏之间的空隙也算，鼠标往下移到工具栏时不会丢掉悬停
        let f = toolbarFrame
        let bottom = container.convert(CGPoint(x: body.frame.midX, y: body.frame.maxY), to: root).y
        let bridge = CGRect(x: f.minX, y: min(bottom, f.minY) - 2, width: f.width, height: f.maxY - min(bottom, f.minY) + 2)
        return f.insetBy(dx: -4, dy: -4).contains(point) || bridge.contains(point)
    }

    // MARK: 拿下来改

    /// 被拿下来改着：图不在绳子上，原来的位置留一个虚线空位（夹子还夹在绳子上）
    private(set) var lifted = false
    private lazy var ghost: CAShapeLayer = {
        let g = CAShapeLayer()
        g.contentsScale = container.contentsScale
        g.frame = body.frame
        let c = Metrics.cardCorner
        g.path = CGPath(roundedRect: body.bounds.insetBy(dx: 0.75, dy: 0.75), cornerWidth: c, cornerHeight: c, transform: nil)
        g.fillColor = NSColor(white: 1, alpha: 0.10).cgColor
        g.strokeColor = NSColor(white: 1, alpha: 0.85).cgColor
        g.lineWidth = 1.5
        g.lineDashPattern = [5, 4]
        g.shadowColor = NSColor.black.cgColor
        g.shadowOpacity = 0.25
        g.shadowRadius = 1.5
        g.shadowOffset = .zero
        g.opacity = 0
        container.insertSublayer(g, below: body)
        return g
    }()

    /// on：图拿走（编辑窗口那张正从这里放大出去），空位晚一点淡出来。
    /// off：图回来。fadeIn：慢慢出现（另存了一张新的，这张没有缩回来的动画）；不然是缩回来的那张正好落在这里，马上出现
    func setLifted(_ on: Bool, fadeIn: Bool = false, instant: Bool = false) {
        lifted = on
        withoutAnimation { body.isHidden = on }
        if on {
            if instant { ghost.removeAnimation(forKey: "fade"); withoutAnimation { ghost.opacity = 1 } }
            else { Motion.fade(ghost, to: 1, duration: 0.3, delay: 0.22) }
        } else {
            ghost.removeAnimation(forKey: "fade")
            withoutAnimation { ghost.opacity = 0 }
            if fadeIn {
                let a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = 0
                a.duration = 0.28
                a.timingFunction = CAMediaTimingFunction(name: .easeOut)
                body.add(a, forKey: "return")
            }
        }
    }

    /// 卡片在根图层坐标里的外接矩形（拖拽时用）。
    func frame(in root: CALayer) -> CGRect {
        container.convert(body.frame, to: root)
    }

    func showToast(_ text: String) {
        container.sublayers?.filter { $0.name == "toast" }.forEach { $0.removeFromSuperlayer() }
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let w = (text as NSString).size(withAttributes: [.font: font]).width + 22
        let bubble = CALayer()
        bubble.name = "toast"
        bubble.frame = CGRect(x: (size.width - w) / 2, y: bodyTop + (size.height - 24) / 2, width: w, height: 24)
        // 和截图完成时的提示一样：白底、深色字（以前这里是黑底，同一句 "Saved" 两种样子）
        bubble.backgroundColor = NSColor(white: 1, alpha: 0.94).cgColor
        bubble.cornerRadius = 12
        bubble.borderWidth = 0.5
        bubble.borderColor = NSColor(white: 0, alpha: 0.1).cgColor
        bubble.shadowColor = NSColor.black.cgColor
        bubble.shadowOpacity = 0.18
        bubble.shadowRadius = 6
        bubble.shadowOffset = CGSize(width: 0, height: -2)
        let t = CATextLayer()
        t.string = text
        t.font = font
        t.fontSize = 12
        t.foregroundColor = NSColor(white: 0, alpha: 0.85).cgColor
        t.alignmentMode = .center
        t.contentsScale = container.contentsScale
        t.frame = CGRect(x: 0, y: 4, width: w, height: 18)
        bubble.addSublayer(t)
        container.addSublayer(bubble)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + 1.6
        fade.duration = 0.4
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        bubble.add(fade, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) { [weak bubble] in bubble?.removeFromSuperlayer() }
    }
}
