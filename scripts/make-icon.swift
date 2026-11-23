// 画 QuickCap 的图标，生成 Resources/AppIcon.icns。
// 用法：swift scripts/make-icon.swift（在项目根目录）
//
// 样子：深石墨色的圆角方块（macOS 图标的形状和网格：1024 画布里 824 的本体），
// 取景框四个角（转角半径跟着图标外形一起圆，白色上亮下暗像金属），中间一条收在框里的橙色线带一圈光。
// 菜单栏图标（AppDelegate.menuBarIcon）是同一个样子
import AppKit
import CoreGraphics

/// macOS 图标的形状：超椭圆（比普通圆角更顺），n = 5
func squircle(_ r: CGRect, n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath()
    let a = r.width / 2, b = r.height / 2, cx = r.midX, cy = r.midY
    for i in 0...360 {
        let t = CGFloat(i) / 360 * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    p.closeSubpath()
    return p
}

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func draw(size px: Int) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.displayP3)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let k = CGFloat(px) / 1024
    ctx.scaleBy(x: k, y: k)
    // 下面按 1024 的画布、原点左上来画（和设计稿一样）
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)
    let body = CGRect(x: 100, y: 92, width: 824, height: 824)
    let shape = squircle(body)

    // 阴影（系统图标都带一点）
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.32))
    ctx.addPath(shape); ctx.setFillColor(color(0x26262A)); ctx.fillPath()
    ctx.restoreGState()

    // 底：上浅下深的石墨色，左上一点反光
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [color(0x3C3C42), color(0x141417)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: body.minY), end: CGPoint(x: 512, y: body.maxY), options: [])
    let sheen = CGGradient(colorsSpace: cs, colors: [color(0xFFFFFF, 0.14), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(sheen, startCenter: CGPoint(x: 340, y: body.minY), startRadius: 0,
                           endCenter: CGPoint(x: 340, y: body.minY), endRadius: 760, options: [])
    ctx.restoreGState()

    // 取景框的四个角（设计稿里本体是 0…1024，这里缩到 824 的本体上）：离边 220，每条臂 190，转角半径 150
    let s: CGFloat = 824 / 1024
    let inset: CGFloat = 220, arm: CGFloat = 190, radius: CGFloat = 150, width: CGFloat = 52
    ctx.saveGState()
    ctx.translateBy(x: body.minX, y: body.minY); ctx.scaleBy(x: s, y: s)
    ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.setLineWidth(width)
    let lo = inset, hi = 1024 - inset
    func corner(_ a: CGPoint, _ m: CGPoint, _ b: CGPoint) {
        func toward(_ f: CGPoint, _ t: CGPoint, _ d: CGFloat) -> CGPoint {
            let l = hypot(t.x - f.x, t.y - f.y); return CGPoint(x: f.x + (t.x - f.x) / l * d, y: f.y + (t.y - f.y) / l * d)
        }
        ctx.move(to: a); ctx.addLine(to: toward(m, a, radius)); ctx.addQuadCurve(to: toward(m, b, radius), control: m); ctx.addLine(to: b)
    }
    corner(CGPoint(x: lo, y: lo + arm), CGPoint(x: lo, y: lo), CGPoint(x: lo + arm, y: lo))
    corner(CGPoint(x: hi - arm, y: lo), CGPoint(x: hi, y: lo), CGPoint(x: hi, y: lo + arm))
    corner(CGPoint(x: hi, y: hi - arm), CGPoint(x: hi, y: hi), CGPoint(x: hi - arm, y: hi))
    corner(CGPoint(x: lo + arm, y: hi), CGPoint(x: lo, y: hi), CGPoint(x: lo, y: hi - arm))
    // 白色上亮下暗：先把线变成形状再裁出来涂渐变（渐变要包住线的粗细，不然两头被切平）
    ctx.replacePathWithStrokedPath(); ctx.clip()
    let metal = CGGradient(colorsSpace: cs, colors: [color(0xFFFFFF), color(0xC9CAD1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(metal, start: CGPoint(x: 0, y: lo - width), end: CGPoint(x: 0, y: hi + width),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    // 橙色的线：一圈光、实线、中间一条亮芯（收在框里）
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: body.minX + x * s, y: body.minY + y * s) }
    let from: CGFloat = 300, to: CGFloat = 724, lw: CGFloat = 34
    ctx.setLineCap(.round)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 70 * s, color: color(0xFF9500, 0.9))
    ctx.setStrokeColor(color(0xFFA61E)); ctx.setLineWidth(lw * s)
    ctx.move(to: pt(from, 512)); ctx.addLine(to: pt(to, 512)); ctx.strokePath()
    ctx.restoreGState()
    ctx.setStrokeColor(color(0xFFA61E)); ctx.setLineWidth(lw * s)
    ctx.move(to: pt(from, 512)); ctx.addLine(to: pt(to, 512)); ctx.strokePath()
    ctx.setStrokeColor(color(0xFFE9C7)); ctx.setLineWidth(lw * 0.3 * s)
    ctx.move(to: pt(from + lw, 512)); ctx.addLine(to: pt(to - lw, 512)); ctx.strokePath()

    // 边：一圈很细的暗线，里面一圈很淡的亮线（玻璃的边）
    ctx.addPath(shape); ctx.setStrokeColor(color(0x000000, 0.35)); ctx.setLineWidth(3); ctx.strokePath()
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    ctx.addPath(squircle(body.insetBy(dx: 2, dy: 2))); ctx.setStrokeColor(color(0xFFFFFF, 0.12)); ctx.setLineWidth(2.5); ctx.strokePath()
    ctx.restoreGState()
    return ctx.makeImage()!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let set = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let img = draw(size: base * scale)
        let dst = CGImageDestinationCreateWithURL(set.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, img, nil)
        CGImageDestinationFinalize(dst)
    }
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out.path]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote \(out.path)" : "iconutil failed")
