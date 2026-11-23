import AppKit

/// 画卡片的挂绳：套在绳子上的小环、一段细线、卡片顶边的小扣。
/// 全部用代码画，不依赖图片素材，方便以后加别的样式。
enum ClipRenderer {
    static func image(scale: CGFloat) -> CGImage? {
        let size = Metrics.clipSize
        let pw = Int(size.width * scale), ph = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // 翻转成 y 向下，和图层坐标一致
        ctx.translateBy(x: 0, y: CGFloat(ph))
        ctx.scaleBy(x: scale, y: -scale)
        let g = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    private static func draw(in r: CGRect) {
        let cord = NSColor(calibratedRed: 0.40, green: 0.40, blue: 0.42, alpha: 1)
        let light = NSColor(white: 1, alpha: 0.55)
        let cx = r.midX

        // 套在绳子上的小环
        let ringR: CGFloat = 2.6
        let ring = NSBezierPath(ovalIn: CGRect(x: cx - ringR, y: Metrics.clipRopeY - ringR,
                                               width: ringR * 2, height: ringR * 2))
        ring.lineWidth = 1.4
        cord.setStroke()
        ring.stroke()

        // 细线
        let tabH: CGFloat = 4
        let line = NSBezierPath()
        line.move(to: CGPoint(x: cx, y: Metrics.clipRopeY + ringR))
        line.line(to: CGPoint(x: cx, y: Metrics.clipGripY - tabH + 0.5))
        line.lineWidth = 1.2
        line.lineCapStyle = .round
        line.stroke()

        // 卡片顶边的小扣
        let tab = CGRect(x: cx - 3.5, y: Metrics.clipGripY - tabH, width: 7, height: tabH + 1.5)
        let tabPath = NSBezierPath(roundedRect: tab, xRadius: 1.6, yRadius: 1.6)
        NSGradient(colors: [NSColor(white: 0.78, alpha: 1), NSColor(white: 0.56, alpha: 1)])!
            .draw(in: tabPath, angle: -90)
        NSColor(white: 0.30, alpha: 0.5).setStroke()
        tabPath.lineWidth = 0.5
        tabPath.stroke()

        // 小环和小扣上的一点高光
        light.setStroke()
        let shine = NSBezierPath()
        shine.move(to: CGPoint(x: tab.minX + 1.4, y: tab.minY + 1))
        shine.line(to: CGPoint(x: tab.maxX - 1.4, y: tab.minY + 1))
        shine.lineWidth = 0.5
        shine.stroke()
    }
}
