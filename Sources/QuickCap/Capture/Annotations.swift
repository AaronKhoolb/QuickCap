import AppKit
import QuartzCore

/// 框好以后直接在选区上画：箭头、框、笔、文字、荧光笔、打码、编号。
/// 屏幕上显示和最后存进图片的是同一套形状（同一个 path 函数），看到什么就存什么。
/// 坐标都是截图界面的坐标（pt，原点左下），贴在冻结的画面上：之后挪选区、改大小，画的东西留在原地
enum AnnotationTool: String, CaseIterable {
    case arrow, rectangle, pen, text, highlight, blur, counter

    var symbol: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .pen: return "scribble.variable"
        case .text: return "textformat"
        case .highlight: return "highlighter"
        case .blur: return "checkerboard.rectangle"
        case .counter: return "1.circle"
        }
    }

    var title: String {
        switch self {
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .pen: return "Pen"
        case .text: return "Text"
        case .highlight: return "Highlighter"
        case .blur: return "Pixelate"
        case .counter: return "Counter"
        }
    }

    /// 这个工具用不用颜色（打码不用）
    var usesColor: Bool { self != .blur }
}

/// 颜色和粗细（小条上选的）
enum AnnotationStyle {
    static let colors: [NSColor] = [
        NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1),     // 红
        NSColor(srgbRed: 1, green: 0.58, blue: 0, alpha: 1),        // 橙
        NSColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 1),         // 黄
        NSColor(srgbRed: 0.2, green: 0.78, blue: 0.35, alpha: 1),   // 绿
        NSColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1),     // 蓝
        NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1),  // 黑
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),           // 白
    ]
    /// 细、中、粗（线宽 pt）
    static let widths: [CGFloat] = [2, 4, 7]
    /// 文字大小跟着粗细走
    static func fontSize(_ w: CGFloat) -> CGFloat { w <= 2 ? 15 : w <= 4 ? 20 : 28 }
    /// 编号圆的半径
    static func counterRadius(_ w: CGFloat) -> CGFloat { w <= 2 ? 10 : w <= 4 ? 13 : 17 }
    /// 打码一格多大（pt）
    static let pixelBlock: CGFloat = 8
}

struct Annotation {
    let tool: AnnotationTool
    var color: NSColor
    var width: CGFloat
    /// 箭头、框、打码：起点和终点；笔、荧光笔：一串点；文字、编号：一个点（文字的左下角、编号的圆心）
    var points: [CGPoint]
    var text = ""
    var number = 0

    var start: CGPoint { points.first ?? .zero }
    var end: CGPoint { points.last ?? .zero }

    /// 画在哪一块（大概，包括阴影），用来判断有没有画到选区里
    var bounds: CGRect {
        var r = CGRect.null
        for p in points { r = r.union(CGRect(origin: p, size: .zero)) }
        if tool == .text {
            let s = Self.textAttributes(color: color, size: AnnotationStyle.fontSize(width))
            let size = NSAttributedString(string: text, attributes: s).size()
            r = CGRect(origin: start, size: size)
        }
        if tool == .counter { let rr = AnnotationStyle.counterRadius(width); r = r.insetBy(dx: -rr, dy: -rr) }
        return r.insetBy(dx: -width * 3 - 4, dy: -width * 3 - 4)
    }

    // MARK: 形状

    /// 箭头：一整块填出来的形状，尾巴细、头粗（像 CleanShot、Keynote 的箭头），转角是圆的
    static func arrowPath(from a: CGPoint, to b: CGPoint, width w: CGFloat) -> CGPath {
        let dx = b.x - a.x, dy = b.y - a.y, len = max(hypot(dx, dy), 0.001)
        let ux = dx / len, uy = dy / len, nx = -uy, ny = ux
        let headLen = min(len * 0.6, w * 3.4 + 9), headW = w * 2.4 + 7
        let shaftEnd = w * 1.1, shaftStart = w * 0.35
        let base = CGPoint(x: b.x - ux * headLen, y: b.y - uy * headLen)
        func p(_ c: CGPoint, _ s: CGFloat) -> CGPoint { CGPoint(x: c.x + nx * s, y: c.y + ny * s) }
        let path = CGMutablePath()
        path.move(to: p(a, shaftStart / 2))
        path.addLine(to: p(base, shaftEnd / 2))
        path.addLine(to: p(base, headW / 2))
        path.addLine(to: b)
        path.addLine(to: p(base, -headW / 2))
        path.addLine(to: p(base, -shaftEnd / 2))
        path.addLine(to: p(a, -shaftStart / 2))
        path.closeSubpath()
        return path
    }

    /// 笔：按点画一条顺的线（相邻两点的中点之间用二次曲线接）
    static func smoothPath(_ pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count < 3 { for p in pts.dropFirst() { path.addLine(to: p) }; return path }
        for i in 1..<(pts.count - 1) {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: pts[i])
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }

    static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    static func textAttributes(color: NSColor, size: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: color]
    }

    /// 浅色的字、白色的编号用深的影子，别的用浅的影子，在什么底上都看得清
    static func shadowColor(for c: NSColor) -> CGColor {
        let l = (c.usingColorSpace(.sRGB)?.brightnessComponent ?? 0)
        return l > 0.85 ? NSColor(white: 0, alpha: 0.45).cgColor : NSColor(white: 0, alpha: 0.28).cgColor
    }

    // MARK: 画进图片（导出）

    /// 画进一个 CGContext。ctx 的坐标已经换成截图界面的坐标（pt，原点左下）。
    /// pixelSource：打码时取像素用（就是这张要存的图，和它在截图界面里占的那块）
    func draw(in ctx: CGContext, pixelSource: (image: CGImage, rect: CGRect)?) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let c = color.cgColor
        switch tool {
        case .arrow:
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: Self.shadowColor(for: color))
            ctx.addPath(Self.arrowPath(from: start, to: end, width: width))
            ctx.setFillColor(c)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(c)
            ctx.setLineWidth(1.2)
            ctx.drawPath(using: .fillStroke)
        case .rectangle:
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: Self.shadowColor(for: color))
            let r = Self.rect(start, end)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(4, r.width / 2), cornerHeight: min(4, r.height / 2), transform: nil))
            ctx.setStrokeColor(c)
            ctx.setLineWidth(width)
            ctx.setLineJoin(.round)
            ctx.strokePath()
        case .pen:
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: Self.shadowColor(for: color))
            ctx.addPath(Self.smoothPath(points))
            ctx.setStrokeColor(c)
            ctx.setLineWidth(width)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokePath()
        case .highlight:
            ctx.setBlendMode(.multiply)
            ctx.addPath(Self.smoothPath(points))
            ctx.setStrokeColor(color.withAlphaComponent(0.42).cgColor)
            ctx.setLineWidth(width * 4 + 8)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokePath()
        case .text:
            guard !text.isEmpty else { return }
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: Self.shadowColor(for: color))
            let s = NSAttributedString(string: text, attributes: Self.textAttributes(color: color, size: AnnotationStyle.fontSize(width)))
            Self.drawText(s, at: start, in: ctx)
        case .counter:
            let r = AnnotationStyle.counterRadius(width)
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: NSColor(white: 0, alpha: 0.3).cgColor)
            ctx.setFillColor(c)
            ctx.fillEllipse(in: CGRect(x: start.x - r, y: start.y - r, width: r * 2, height: r * 2))
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            let light = (color.usingColorSpace(.sRGB)?.brightnessComponent ?? 0) > 0.85 && (color.usingColorSpace(.sRGB)?.saturationComponent ?? 0) < 0.2
            let s = NSAttributedString(string: "\(number)", attributes: [
                .font: NSFont.systemFont(ofSize: r * 1.15, weight: .bold),
                .foregroundColor: light ? NSColor.black : NSColor.white])
            let sz = s.size()
            Self.drawText(s, at: CGPoint(x: start.x - sz.width / 2, y: start.y - sz.height / 2 + 0.5), in: ctx)
        case .blur:
            guard let src = pixelSource else { return }
            let r = Self.rect(start, end)
            guard let img = Self.pixelate(src.image, imageRect: src.rect, region: r) else { return }
            ctx.interpolationQuality = .none
            ctx.draw(img, in: r)
        }
    }

    /// 画一段字（左下角在 p）
    static func drawText(_ s: NSAttributedString, at p: CGPoint, in ctx: CGContext) {
        let line = CTLineCreateWithAttributedString(s)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: p.x, y: p.y + descent)
        CTLineDraw(line, ctx)
    }

    /// 打码：把 region 这块缩小成一格一格，再放大回去（不插值）。
    /// image 是在截图界面里占 imageRect 的那张图
    static func pixelate(_ image: CGImage, imageRect: CGRect, region: CGRect) -> CGImage? {
        let r = region.intersection(imageRect)
        guard r.width >= 1, r.height >= 1 else { return nil }
        let sx = CGFloat(image.width) / imageRect.width, sy = CGFloat(image.height) / imageRect.height
        // CGImage 的像素原点在左上
        let px = CGRect(x: (r.minX - imageRect.minX) * sx, y: (imageRect.maxY - r.maxY) * sy, width: r.width * sx, height: r.height * sy).integral
        guard let part = image.cropping(to: px) else { return nil }
        let block = AnnotationStyle.pixelBlock
        let w = max(1, Int((r.width / block).rounded())), h = max(1, Int((r.height / block).rounded()))
        let cs = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let info = image.bitsPerComponent > 8
            ? CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: image.bitsPerComponent > 8 ? 16 : 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(part, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

/// 把画好的东西画进存下来的那张图。imageRect：这张图在截图界面里占的那块（窗口截图带阴影时比选区大）。
/// clip：只画在这块里面（选区）
enum AnnotationRenderer {
    static func render(_ list: [Annotation], onto image: CGImage, imageRect: CGRect, clip: CGRect) -> CGImage? {
        guard !list.isEmpty else { return image }
        let w = image.width, h = image.height
        let cs = image.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)!
        let float = image.bitsPerComponent > 8
        let info: UInt32 = float
            ? CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: float ? 16 : 8, bytesPerRow: 0, space: cs, bitmapInfo: info)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // 换成截图界面的坐标
        let sx = CGFloat(w) / imageRect.width, sy = CGFloat(h) / imageRect.height
        ctx.scaleBy(x: sx, y: sy)
        ctx.translateBy(x: -imageRect.minX, y: -imageRect.minY)
        ctx.clip(to: clip)
        ctx.setShouldAntialias(true)
        for a in list { a.draw(in: ctx, pixelSource: (image, imageRect)) }
        guard let out = ctx.makeImage() else { return nil }
        return image.contentHeadroom >= 1 ? (CGImageCreateCopyWithContentHeadroom(image.contentHeadroom, out) ?? out) : out
    }
}

/// 截图界面上画画的那一层。挂在冻结画面上面、选区框下面，只露出选区里面的部分。
/// 拖的时候用 CAShapeLayer（显卡画，跟手）；松手后换成用导出同一段代码画的图层，看到的和存下来的一样
@MainActor
final class Annotator {
    let layer = CALayer()
    private let clipMask = CAShapeLayer()
    private(set) var items: [Annotation] = []
    private var itemLayers: [CALayer] = []
    private var drawers: [AnnotationDrawer] = []
    /// 正在画的这一笔
    private var live: Annotation?
    private let liveLayer = CAShapeLayer()
    /// 冻结的画面和它占的范围（打码取像素）
    var source: (image: CGImage, rect: CGRect)?
    /// 屏幕现在是实时的（source 是旧的冻结画面）
    var sourceIsLive = false
    var scale: CGFloat = 2

    /// 每个画好的东西是一张按自己外框大小画的位图。编辑器里放大看时按 4 倍画，长截图上一个大框要好几百 MB、
    /// 超过 16384 像素还会画不出来。按大小封顶：最长边不超过 8192 像素、总共不超过 2400 万像素
    private func layerScale(for r: CGRect) -> CGFloat {
        let w = max(r.width, 1), h = max(r.height, 1)
        return max(1, min(scale, 8192 / max(w, h), (24_000_000 / (w * h)).squareRoot()))
    }

    /// 换了一张画面（截了这一刻、重新冻住、解冻）：打码、荧光笔按新的画面重画
    func updateSource(_ s: (image: CGImage, rect: CGRect)?, live: Bool) {
        source = s
        sourceIsLive = live
        for i in items.indices where items[i].tool == .blur || items[i].tool == .highlight { redraw(i) }
    }

    var tool: AnnotationTool?
    var color: NSColor = AnnotationStyle.colors[0]
    var width: CGFloat = AnnotationStyle.widths[1]

    /// 画了东西、撤销了：外面更新撤销按钮
    var onChange: (() -> Void)?
    /// 选中的换了（样式条要显示选中那个的颜色、粗细）
    var onSelect: (() -> Void)?

    /// 选中那个的颜色、粗细在样式条上是第几个（没选中、或者不是样式条上的值：nil）
    var selectedStyleIndices: (color: Int?, width: Int?)? {
        guard let i = selected, items.indices.contains(i) else { return nil }
        let a = items[i]
        return (AnnotationStyle.colors.firstIndex { $0.isEqual(a.color) }, AnnotationStyle.widths.firstIndex(of: a.width))
    }

    /// 选中的那个（点一下画好的东西：可以拖着挪、Delete 删掉、点颜色改颜色）
    private(set) var selected: Int?
    private let selectionLayer = CAShapeLayer()
    private let selectionUnder = CAShapeLayer()
    /// 撤销用：每一步怎么退回去
    private enum Edit { case add, remove(Int, Annotation), replace(Int, Annotation) }
    private var history: [Edit] = []
    /// 重做用：撤销掉的那几步怎么再做一遍。画了新的东西就清掉
    private enum Redo { case add(Annotation), remove(Int), replace(Int, Annotation) }
    private var redoStack: [Redo] = []
    /// 正在拖着挪的那个：起点和原来的位置
    private var moving: (index: Int, from: CGPoint, layerPos: CGPoint)?

    init(bounds: CGRect) {
        // 加减标注图层时不要整层交叉淡化（清掉选区时标注会慢半拍才消失）
        layer.actions = ["sublayers": NSNull()]
        layer.frame = bounds
        layer.name = "annotations"
        clipMask.fillColor = NSColor.black.cgColor
        layer.mask = clipMask
        liveLayer.frame = bounds
        liveLayer.lineCap = .round
        liveLayer.lineJoin = .round
        layer.addSublayer(liveLayer)
        selectionLayer.frame = bounds
        // 选中的外框：底下一圈白、上面一圈深色虚线（像"预览"里选中的样子），白底黑底都看得清
        selectionUnder.frame = bounds
        selectionUnder.fillColor = nil
        selectionUnder.strokeColor = NSColor(white: 1, alpha: 0.9).cgColor
        selectionUnder.lineWidth = 2
        layer.addSublayer(selectionUnder)
        selectionLayer.fillColor = nil
        selectionLayer.strokeColor = NSColor(white: 0, alpha: 0.7).cgColor
        selectionLayer.lineWidth = 1
        selectionLayer.lineDashPattern = [4, 3]
        layer.addSublayer(selectionLayer)
    }

    var canUndo: Bool { !history.isEmpty }

    var isEmpty: Bool { items.isEmpty }
    var isDrawing: Bool { live != nil }

    /// 只露出选区里面（选区挪了、改了大小时外面调）
    func clip(to r: CGRect?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        clipMask.path = r.map { CGPath(rect: $0, transform: nil) }
        layer.isHidden = r == nil
        CATransaction.commit()
    }

    // MARK: 画

    func begin(at p: CGPoint) {
        guard let tool else { return }
        let n = tool == .counter ? (items.filter { $0.tool == .counter }.map(\.number).max() ?? 0) + 1 : 0
        live = Annotation(tool: tool, color: color, width: width, points: [p, p], number: n)
        if tool == .counter { commit(); return }
        updateLive()
    }

    /// shift：箭头按 45° 吸、框变正方形、笔和荧光笔画直线
    func move(to p: CGPoint, shift: Bool) {
        guard var a = live else { return }
        var q = p
        switch a.tool {
        case .arrow where shift:
            let dx = p.x - a.start.x, dy = p.y - a.start.y
            let ang = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4), len = hypot(dx, dy)
            q = CGPoint(x: a.start.x + cos(ang) * len, y: a.start.y + sin(ang) * len)
        case .rectangle where shift, .blur where shift:
            let d = max(abs(p.x - a.start.x), abs(p.y - a.start.y))
            q = CGPoint(x: a.start.x + (p.x >= a.start.x ? d : -d), y: a.start.y + (p.y >= a.start.y ? d : -d))
        default: break
        }
        if a.tool == .pen || a.tool == .highlight {
            if shift { a.points = [a.start, q] }
            else if let last = a.points.last, hypot(last.x - q.x, last.y - q.y) >= 1.2 { a.points.append(q) }
        } else {
            a.points = [a.start, q]
        }
        live = a
        updateLive()
    }

    /// 松手：太小的（点了一下）不要
    func end() {
        guard let a = live else { return }
        var size = CGRect.null
        for p in a.points { size = size.union(CGRect(origin: p, size: .zero)) }
        let tiny: Bool
        switch a.tool {
        case .arrow: tiny = hypot(a.end.x - a.start.x, a.end.y - a.start.y) < 6
        case .rectangle, .blur: tiny = abs(a.end.x - a.start.x) < 4 || abs(a.end.y - a.start.y) < 4
        case .pen, .highlight: tiny = a.points.count < 2 || (size.width < 2 && size.height < 2)
        default: tiny = false
        }
        if tiny { cancelLive(); return }
        commit()
    }

    func cancelLive() {
        live = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        liveLayer.path = nil
        CATransaction.commit()
    }

    /// 文字：外面的输入框打完字后交进来
    func addText(_ s: String, at p: CGPoint, color: NSColor, width: CGFloat) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        live = Annotation(tool: .text, color: color, width: width, points: [p], text: t)
        commit()
    }

    func undo() {
        guard let e = history.popLast() else { NSSound.beep(); return }
        select(nil)
        switch e {
        case .add:
            guard let a = items.last else { break }
            items.removeLast()
            drawers.removeLast()
            let l = itemLayers.removeLast()
            fadeOut(l)
            redoStack.append(.add(a))
        case .remove(let i, let a):
            insert(a, at: i)
            redoStack.append(.remove(i))
        case .replace(let i, let a):
            guard items.indices.contains(i) else { break }
            redoStack.append(.replace(i, items[i]))
            items[i] = a
            redraw(i)
        }
        onChange?()
    }

    /// ⇧⌘Z：把撤销掉的再做一遍
    func redo() {
        guard let r = redoStack.popLast() else { NSSound.beep(); return }
        select(nil)
        switch r {
        case .add(let a):
            insert(a, at: items.count)
            history.append(.add)
        case .remove(let i):
            guard items.indices.contains(i) else { break }
            history.append(.remove(i, items[i]))
            items.remove(at: i)
            drawers.remove(at: i)
            fadeOut(itemLayers.remove(at: i))
        case .replace(let i, let a):
            guard items.indices.contains(i) else { break }
            history.append(.replace(i, items[i]))
            items[i] = a
            redraw(i)
        }
        onChange?()
    }

    func removeAll() {
        cancelLive()
        select(nil)
        items = []
        drawers = []
        history = []
        redoStack = []
        itemLayers.forEach { $0.removeFromSuperlayer() }
        itemLayers = []
        onChange?()
    }

    private func fadeOut(_ l: CALayer) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1
        a.toValue = 0
        a.duration = 0.14
        CATransaction.begin()
        CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
        l.opacity = 0
        l.add(a, forKey: "fade")
        CATransaction.commit()
    }

    // MARK: 选中、挪、删、改

    /// 点到的是哪个画好的东西（最上面的先）
    /// 拿着画画工具点下去时：打码、荧光笔这种按面积算点中的不抢（不然想在打码块上放编号、画箭头，会把打码块拖走），
    /// 除非手上拿的就是同一种工具
    func hitForDrawing(_ p: CGPoint) -> Int? {
        guard let i = hit(p) else { return nil }
        let t = items[i].tool
        if let tool, (t == .blur || t == .highlight), t != tool { return nil }
        return i
    }

    func hit(_ p: CGPoint) -> Int? {
        for i in items.indices.reversed() where Self.hits(items[i], p) { return i }
        return nil
    }

    private static func hits(_ a: Annotation, _ p: CGPoint) -> Bool {
        let tol = max(6, a.width / 2 + 4)
        func near(_ path: CGPath, _ w: CGFloat) -> Bool {
            path.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 10).contains(p)
        }
        switch a.tool {
        case .arrow:
            let path = Annotation.arrowPath(from: a.start, to: a.end, width: a.width)
            return path.contains(p) || near(path, tol * 2)
        case .rectangle:
            return near(CGPath(rect: Annotation.rect(a.start, a.end), transform: nil), a.width + tol * 2)
        case .pen:
            return near(Annotation.smoothPath(a.points), a.width + tol * 2)
        case .highlight:
            return near(Annotation.smoothPath(a.points), a.width * 4 + 8)
        case .blur:
            return Annotation.rect(a.start, a.end).insetBy(dx: -3, dy: -3).contains(p)
        case .text:
            return a.bounds.insetBy(dx: a.width * 3 + 2, dy: a.width * 3 + 2).contains(p)
        case .counter:
            return hypot(p.x - a.start.x, p.y - a.start.y) <= AnnotationStyle.counterRadius(a.width) + 3
        }
    }

    /// 选中（nil：不选）。选中的外面一圈白色虚线
    func select(_ i: Int?) {
        let before = selected
        selected = i.flatMap { items.indices.contains($0) ? $0 : nil }
        defer { if selected != before { onSelect?() } }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let i = selected {
            let r = selectionRect(items[i])
            selectionLayer.path = CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil)
        } else {
            selectionLayer.path = nil
        }
        selectionUnder.path = selectionLayer.path
        CATransaction.commit()
    }

    private func selectionRect(_ a: Annotation) -> CGRect {
        let pad = a.width * 3 + 4
        return a.bounds.insetBy(dx: pad - 5, dy: pad - 5)
    }

    func beginMove(_ i: Int, at p: CGPoint) {
        guard items.indices.contains(i) else { return }
        select(i)
        moving = (i, p, itemLayers[i].position)
    }

    /// 拖着挪：只挪图层（快），松手时才真的改位置
    func moveSelected(to p: CGPoint) {
        guard let m = moving else { return }
        let d = CGPoint(x: p.x - m.from.x, y: p.y - m.from.y)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        itemLayers[m.index].position = CGPoint(x: m.layerPos.x + d.x, y: m.layerPos.y + d.y)
        var a = items[m.index]
        a.points = a.points.map { CGPoint(x: $0.x + d.x, y: $0.y + d.y) }
        let r = selectionRect(a)
        selectionLayer.path = CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil)
        selectionUnder.path = selectionLayer.path
        // 马赛克：拖的时候按新位置重新打码（最多 50ms 一次）。以前拖着的是旧位置的马赛克，松手才"啪"一下换掉
        if a.tool == .blur, source != nil, CACurrentMediaTime() - lastBlurRefresh > 0.05 {
            lastBlurRefresh = CACurrentMediaTime()
            let (l, dr) = makeLayer(a)
            layer.replaceSublayer(itemLayers[m.index], with: l)
            itemLayers[m.index] = l
            drawers[m.index] = dr
            moving = (m.index, m.from, CGPoint(x: l.position.x - d.x, y: l.position.y - d.y))
        }
        CATransaction.commit()
    }
    private var lastBlurRefresh: CFTimeInterval = 0

    func endMove(at p: CGPoint) {
        guard let m = moving else { return }
        moving = nil
        let d = CGPoint(x: p.x - m.from.x, y: p.y - m.from.y)
        guard abs(d.x) >= 0.5 || abs(d.y) >= 0.5 else {
            if items[m.index].tool == .blur { redraw(m.index); return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            itemLayers[m.index].position = m.layerPos
            CATransaction.commit()
            return
        }
        var a = items[m.index]
        a.points = a.points.map { CGPoint(x: $0.x + d.x, y: $0.y + d.y) }
        change(m.index, to: a)
        select(m.index)
    }


    func deleteSelected() {
        guard let i = selected else { NSSound.beep(); return }
        select(nil)
        history.append(.remove(i, items[i]))
        redoStack = []
        items.remove(at: i)
        drawers.remove(at: i)
        fadeOut(itemLayers.remove(at: i))
        onChange?()
    }

    /// 选中的改颜色、粗细（小条上点的）
    func restyleSelected(color: NSColor? = nil, width: CGFloat? = nil) {
        guard let i = selected else { return }
        var a = items[i]
        if let color, a.tool.usesColor { a.color = color }
        if let width { a.width = width }
        // 点的就是现在的颜色、粗细：什么都没变，不多记一步撤销
        if a.color.isEqual(items[i].color), a.width == items[i].width { return }
        change(i, to: a)
        select(i)
    }

    /// 改了第 i 个（记下原来的样子，撤销时退回去）
    func change(_ i: Int, to a: Annotation) {
        guard items.indices.contains(i) else { return }
        history.append(.replace(i, items[i]))
        redoStack = []
        items[i] = a
        redraw(i)
        onChange?()
    }

    /// 文字改完：空的就删掉
    /// 改字时也可能点了颜色、字号：三样一起换（以前只换字，改的颜色字号交出去就丢了）
    func replaceText(_ i: Int, with s: String, color: NSColor? = nil, width: CGFloat? = nil) {
        guard items.indices.contains(i) else { return }
        itemLayers[i].isHidden = false
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { select(i); deleteSelected(); return }
        var a = items[i]
        a.text = t
        if let color { a.color = color }
        if let width { a.width = width }
        guard a.text != items[i].text || !a.color.isEqual(items[i].color) || a.width != items[i].width else { return }
        change(i, to: a)
    }

    /// 正在改的文字先藏起来（输入框在它上面）
    func setHidden(_ i: Int, _ hidden: Bool) {
        guard itemLayers.indices.contains(i) else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        itemLayers[i].isHidden = hidden
        CATransaction.commit()
    }

    private func makeLayer(_ a: Annotation) -> (CALayer, AnnotationDrawer) {
        let r = a.bounds.integral
        let l = CALayer()
        l.frame = r
        l.contentsScale = layerScale(for: r)
        l.needsDisplayOnBoundsChange = false
        let d = AnnotationDrawer(annotation: a, origin: r.origin, source: source, backdrop: !sourceIsLive)
        l.delegate = d
        l.setNeedsDisplay()
        l.displayIfNeeded()
        return (l, d)
    }

    /// 第 i 个重新画一张图层（形状、颜色、位置变了）
    private func redraw(_ i: Int) {
        let (l, d) = makeLayer(items[i])
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.replaceSublayer(itemLayers[i], with: l)
        CATransaction.commit()
        itemLayers[i] = l
        drawers[i] = d
    }

    private func insert(_ a: Annotation, at i: Int) {
        let idx = min(max(i, 0), items.count)
        let (l, d) = makeLayer(a)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if idx < itemLayers.count { layer.insertSublayer(l, below: itemLayers[idx]) } else { layer.insertSublayer(l, below: liveLayer) }
        CATransaction.commit()
        items.insert(a, at: idx)
        itemLayers.insert(l, at: idx)
        drawers.insert(d, at: idx)
    }

    private func commit() {
        guard let a = live else { return }
        live = nil
        let r = a.bounds.integral
        let l = CALayer()
        l.frame = r
        l.contentsScale = layerScale(for: r)
        l.needsDisplayOnBoundsChange = false
        let d = AnnotationDrawer(annotation: a, origin: r.origin, source: source, backdrop: !sourceIsLive)
        l.delegate = d
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.insertSublayer(l, below: liveLayer)
        l.setNeedsDisplay()
        l.displayIfNeeded()
        liveLayer.path = nil
        CATransaction.commit()
        items.append(a)
        itemLayers.append(l)
        drawers.append(d)
        history.append(.add)
        redoStack = []
        onChange?()
    }

    /// 拖的时候：形状直接交给显卡画
    private func updateLive() {
        guard let a = live else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let l = liveLayer
        l.lineDashPattern = nil
        l.compositingFilter = nil
        l.shadowOpacity = 0
        l.lineCap = .round
        switch a.tool {
        case .arrow:
            l.path = Annotation.arrowPath(from: a.start, to: a.end, width: a.width)
            l.fillColor = a.color.cgColor
            l.strokeColor = a.color.cgColor
            l.lineWidth = 1.2
            shadow(l, a.color)
        case .rectangle:
            let r = Annotation.rect(a.start, a.end)
            l.path = CGPath(roundedRect: r, cornerWidth: min(4, r.width / 2), cornerHeight: min(4, r.height / 2), transform: nil)
            l.fillColor = nil
            l.strokeColor = a.color.cgColor
            l.lineWidth = a.width
            shadow(l, a.color)
        case .pen:
            l.path = Annotation.smoothPath(a.points)
            l.fillColor = nil
            l.strokeColor = a.color.cgColor
            l.lineWidth = a.width
            shadow(l, a.color)
        case .highlight:
            l.path = Annotation.smoothPath(a.points)
            l.fillColor = nil
            l.strokeColor = a.color.withAlphaComponent(0.42).cgColor
            l.lineWidth = a.width * 4 + 8
            l.compositingFilter = "multiplyBlendMode"
        case .blur:
            l.path = CGPath(rect: Annotation.rect(a.start, a.end), transform: nil)
            l.fillColor = NSColor(white: 0.5, alpha: 0.25).cgColor
            l.strokeColor = NSColor(white: 1, alpha: 0.9).cgColor
            l.lineWidth = 1
            l.lineDashPattern = [4, 3]
        case .text, .counter:
            l.path = nil
        }
        CATransaction.commit()
    }

    private func shadow(_ l: CALayer, _ c: NSColor) {
        l.shadowColor = Annotation.shadowColor(for: c)
        l.shadowOpacity = 1
        l.shadowRadius = 1.5
        l.shadowOffset = CGSize(width: 0, height: -1)
    }

    /// 存图时：把画的东西画进这张图
    func render(onto image: CGImage, imageRect: CGRect, clip: CGRect) -> CGImage? {
        AnnotationRenderer.render(items, onto: image, imageRect: imageRect, clip: clip)
    }

    // 调试用
    var debugText: String {
        "tool=\(tool?.rawValue ?? "none") items=\(items.count)[\(items.map(\.tool.rawValue).joined(separator: ","))] selected=\(selected.map(String.init) ?? "-")"
            + " first=\(items.first.map { "\(Int($0.start.x)),\(Int($0.start.y))" } ?? "-") texts=\(items.filter { $0.tool == .text }.map(\.text))"
    }
}

/// 一个画好的东西的图层怎么画：和导出用同一个 draw
private final class AnnotationDrawer: NSObject, CALayerDelegate {
    let annotation: Annotation
    let origin: CGPoint
    let source: (image: CGImage, rect: CGRect)?
    /// 荧光笔下面垫不垫截图：屏幕是实时的（还没截这一刻）时不垫，垫上去的是旧画面
    let backdrop: Bool
    init(annotation: Annotation, origin: CGPoint, source: (image: CGImage, rect: CGRect)?, backdrop: Bool = true) {
        self.annotation = annotation
        self.origin = origin
        self.source = source
        self.backdrop = backdrop
    }
    func draw(_ layer: CALayer, in ctx: CGContext) {
        ctx.translateBy(x: -origin.x, y: -origin.y)
        let a = annotation
        if a.tool == .highlight, backdrop, let src = source {
            // 荧光笔是正片叠底：自己这张图层是透明的，叠在透明上就只是一层半透明的黄（屏幕上发白），
            // 存下来的却是叠在截图上（黑字还是黑的）。所以笔画下面先垫上同一块截图，再叠，屏幕和存下来的一样
            let stroke = Annotation.smoothPath(a.points).copy(strokingWithWidth: a.width * 4 + 8, lineCap: .round,
                                                              lineJoin: .round, miterLimit: 10)
            ctx.saveGState()
            ctx.addPath(stroke)
            ctx.clip()
            ctx.draw(src.image, in: src.rect)
            ctx.restoreGState()
        }
        a.draw(in: ctx, pixelSource: source)
    }
    func action(for layer: CALayer, forKey event: String) -> CAAction? { NSNull() }
}

/// 文字工具：在选区里点一下，就地出一个输入框（没边框、没底，字就是最后的样子）。
/// 回车或点别的地方：交出去；Esc：不要了
@MainActor
final class TextAnnotationEditor: NSObject, NSTextFieldDelegate {
    let field = NSTextField()
    private var color: NSColor
    private var width: CGFloat
    private let zoom: CGFloat
    /// 文字左下角（截图界面坐标）
    private let origin: CGPoint
    private var done = false
    var onCommit: ((String, CGPoint, NSColor, CGFloat) -> Void)?
    var onFinish: (() -> Void)?

    /// p：点的地方（新的字）；textOrigin：改已有的字时，那段字的左下角（输入框正好盖在上面）
    /// zoom、toView：编辑窗口里图放大缩小了（画的东西用图的坐标，输入框放在屏幕上，字跟着缩放）
    init(at p: CGPoint, color: NSColor, width: CGFloat, text: String = "", textOrigin: CGPoint? = nil,
         zoom: CGFloat = 1, toView: (CGPoint) -> CGPoint = { $0 }) {
        self.color = color
        self.width = width
        self.zoom = zoom
        let size = AnnotationStyle.fontSize(width)
        let font = NSFont.systemFont(ofSize: size * zoom, weight: .semibold)
        // 字的基线落在点的地方附近：框往下挪半个字高
        let h = ceil(font.ascender - font.descender + 4 * zoom)
        origin = textOrigin.map { CGPoint(x: $0.x, y: $0.y - 1) } ?? CGPoint(x: p.x, y: p.y - h / zoom / 2)
        super.init()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = color
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        let o = toView(origin)
        field.frame = CGRect(x: o.x - 2 * zoom, y: o.y, width: 60, height: h)
        field.stringValue = text
        if !text.isEmpty { controlTextDidChange(Notification(name: NSControl.textDidChangeNotification)) }
        field.wantsLayer = true
        field.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor(cgColor: Annotation.shadowColor(for: color))
            s.shadowBlurRadius = 3
            s.shadowOffset = CGSize(width: 0, height: -1)
            return s
        }()
    }

    /// 打字时点了颜色、字号：正在打的字马上换样子，交出去时也用新的
    func restyle(color c: NSColor? = nil, width w: CGFloat? = nil) {
        guard !done else { return }
        if let c {
            color = c
            field.textColor = c
            let s = NSShadow()
            s.shadowColor = NSColor(cgColor: Annotation.shadowColor(for: c))
            s.shadowBlurRadius = 3
            s.shadowOffset = CGSize(width: 0, height: -1)
            field.shadow = s
        }
        if let w {
            width = w
            let font = NSFont.systemFont(ofSize: AnnotationStyle.fontSize(w) * zoom, weight: .semibold)
            field.font = font
            field.frame.size.height = ceil(font.ascender - font.descender + 4 * zoom)
            controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        let w = NSAttributedString(string: field.stringValue + "  ", attributes: [.font: field.font as Any]).size().width
        field.frame.size.width = max(60, ceil(w) + 6)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { commit(); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { cancel(); return true }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) { commit() }

    func commit() {
        guard !done else { return }
        done = true
        // 输入框里的字左边有 2pt 的内边距
        onCommit?(field.stringValue, CGPoint(x: origin.x, y: origin.y + 1), color, width)
        finish()
    }

    func cancel() {
        guard !done else { return }
        done = true
        finish()
    }

    private func finish() {
        field.delegate = nil
        field.removeFromSuperview()
        onFinish?()
    }
}
