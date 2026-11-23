import AppKit

/// 放大镜：鼠标旁边一个圆，里面是放大的像素（每个像素 8pt，带格子），中间那个像素描橙边；
/// 下面一行写坐标和颜色。按 C 拷贝颜色
@MainActor
final class LoupeView: NSView {
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // 网格和中间的小方框是自己加的线条图层，默认 1 倍，Retina 上发虚
        if let sc = window?.backingScaleFactor { for l in [grid, center] { l.contentsScale = sc } }
    }
    static let diameter: CGFloat = 120
    static let zoom: CGFloat = 8
    private static let pillHeight: CGFloat = 24
    private static let gap: CGFloat = 8

    private let circle = CALayer()
    private let zoomLayer = CALayer()
    private let grid = CAShapeLayer()
    private let center = CAShapeLayer()
    private let ring = CALayer()
    private let pill = NSGlassEffectView()
    private let label = NSTextField(labelWithString: "")
    private let swatch = NSView()

    private var image: CGImage?
    private(set) var hex: String?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 180, height: Self.diameter + Self.gap + Self.pillHeight))
        wantsLayer = true
        appearance = NSAppearance(named: .aqua)
        isHidden = true
        let d = Self.diameter
        let cr = CGRect(x: (bounds.width - d) / 2, y: bounds.height - d, width: d, height: d)

        // 阴影单独一层（圆形遮罩会把阴影切掉）
        ring.frame = cr
        ring.cornerRadius = d / 2
        ring.backgroundColor = NSColor.white.cgColor
        ring.shadowColor = NSColor.black.cgColor
        ring.shadowOpacity = 0.3
        ring.shadowRadius = 10
        ring.shadowOffset = CGSize(width: 0, height: -4)
        layer?.addSublayer(ring)

        circle.frame = cr.insetBy(dx: 3, dy: 3)
        circle.cornerRadius = circle.bounds.width / 2
        circle.masksToBounds = true
        circle.backgroundColor = NSColor.white.cgColor
        zoomLayer.magnificationFilter = .nearest
        zoomLayer.contentsGravity = .resize
        circle.addSublayer(zoomLayer)
        grid.strokeColor = NSColor(white: 0, alpha: 0.08).cgColor
        grid.lineWidth = 0.5
        grid.fillColor = nil
        circle.addSublayer(grid)
        center.fillColor = nil
        center.strokeColor = NSColor(calibratedRed: 1, green: 0.58, blue: 0, alpha: 1).cgColor
        center.lineWidth = 1.5
        center.shadowColor = NSColor.white.cgColor
        center.shadowOpacity = 1
        center.shadowRadius = 0.5
        center.shadowOffset = .zero
        circle.addSublayer(center)
        layer?.addSublayer(circle)
        let edge = CALayer()
        edge.frame = cr
        edge.cornerRadius = d / 2
        edge.borderWidth = 0.5
        edge.borderColor = NSColor(white: 0, alpha: 0.18).cgColor
        layer?.addSublayer(edge)

        pill.style = .regular
        pill.cornerRadius = Self.pillHeight / 2
        label.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        label.textColor = NSColor(white: 0, alpha: 0.8)
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 3
        swatch.layer?.borderWidth = 0.5
        swatch.layer?.borderColor = NSColor(white: 0, alpha: 0.25).cgColor
        swatch.translatesAutoresizingMaskIntoConstraints = false
        swatch.widthAnchor.constraint(equalToConstant: 10).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: 10).isActive = true
        let row = NSStackView(views: [label, swatch])
        row.spacing = 6
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        pill.contentView = content
        addSubview(pill)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// p：鼠标在覆盖窗口里的位置（pt，原点左下）；scale：像素倍数
    func update(image img: CGImage, at p: CGPoint, viewSize: CGSize, scale: CGFloat) {
        if img !== image { image = img }
        let inner = circle.bounds.width
        // 像素坐标：原点左上
        let px = Int((p.x * scale).rounded(.down)), py = Int(((viewSize.height - p.y) * scale).rounded(.down))
        let n = Int((inner / Self.zoom).rounded(.up)) | 1 // 奇数个，正中间是鼠标下面那个像素
        let half = n / 2
        let x0 = min(max(px - half, 0), max(img.width - n, 0)), y0 = min(max(py - half, 0), max(img.height - n, 0))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        zoomLayer.contents = img.cropping(to: CGRect(x: x0, y: y0, width: n, height: n))
        let side = CGFloat(n) * Self.zoom
        // 裁出来的图贴到边上时，中间那格不一定是鼠标下的像素，偏移补回来
        let dx = CGFloat(px - x0 - half) * Self.zoom, dy = CGFloat(py - y0 - half) * Self.zoom
        zoomLayer.frame = CGRect(x: (inner - side) / 2 - dx, y: (inner - side) / 2 + dy, width: side, height: side)
        let c0 = (inner - Self.zoom) / 2
        if grid.path == nil {
            let g = CGMutablePath()
            var v = c0.truncatingRemainder(dividingBy: Self.zoom)
            while v < inner { g.move(to: CGPoint(x: v, y: 0)); g.addLine(to: CGPoint(x: v, y: inner))
                g.move(to: CGPoint(x: 0, y: v)); g.addLine(to: CGPoint(x: inner, y: v)); v += Self.zoom }
            grid.path = g
            center.path = CGPath(rect: CGRect(x: c0, y: c0, width: Self.zoom, height: Self.zoom), transform: nil)
        }
        CATransaction.commit()

        let rgb = sample(img, px, py)
        hex = rgb.map { String(format: "#%02X%02X%02X", $0.0, $0.1, $0.2) }
        swatch.layer?.backgroundColor = rgb.map { NSColor(srgbRed: CGFloat($0.0) / 255, green: CGFloat($0.1) / 255,
                                                         blue: CGFloat($0.2) / 255, alpha: 1).cgColor }
        // 坐标和系统一样从左上角算，单位 pt
        label.stringValue = "\(Int(p.x)), \(Int(viewSize.height - p.y))   \(hex ?? "")"
        let w = (label.fittingSize.width + 34).rounded(.up)
        pill.frame = CGRect(x: ((bounds.width - w) / 2).rounded(), y: 0, width: w, height: Self.pillHeight)
    }

    /// 放在鼠标右下方；靠近屏幕边就翻到另一边
    func place(at p: CGPoint, in bounds: CGRect) {
        let off: CGFloat = 26
        var x = p.x + off - (frame.width - Self.diameter) / 2
        var y = p.y - off - frame.height
        if x + frame.width > bounds.maxX - 4 { x = p.x - off - Self.diameter - (frame.width - Self.diameter) / 2 }
        if y < bounds.minY + 4 { y = p.y + off }
        frame.origin = CGPoint(x: x.rounded(), y: y.rounded())
    }

    /// 颜色（sRGB）：只取鼠标下面这一个像素换成 sRGB。
    /// 以前第一次用时把整张截图转成 sRGB 的像素表（5K 屏约 60MB，在主线程上），鼠标第一下一动就卡；指针用法也不安全
    private func sample(_ img: CGImage, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8)? {
        guard x >= 0, y >= 0, x < img.width, y < img.height,
              let px = img.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var out = [UInt8](repeating: 0, count: 4)
        let ok = out.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(px, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return ok ? (out[0], out[1], out[2]) : nil
    }
}
