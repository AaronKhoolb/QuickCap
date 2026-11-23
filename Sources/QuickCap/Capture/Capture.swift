import AppKit

/// 截图保存位置：设置里的 Save to，默认 ~/Pictures/QuickCap
enum CaptureStore {
    @MainActor static var folder: URL {
        let dir = AppSettings.shared.screenshotFolderURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// 生成测试用的假截图，不需要屏幕录制权限也能试悬挂架。
enum SampleImage {
    private static let palettes: [(NSColor, NSColor)] = [
        (NSColor(calibratedRed: 0.36, green: 0.55, blue: 0.98, alpha: 1), NSColor(calibratedRed: 0.62, green: 0.40, blue: 0.95, alpha: 1)),
        (NSColor(calibratedRed: 0.98, green: 0.62, blue: 0.36, alpha: 1), NSColor(calibratedRed: 0.95, green: 0.38, blue: 0.52, alpha: 1)),
        (NSColor(calibratedRed: 0.20, green: 0.75, blue: 0.62, alpha: 1), NSColor(calibratedRed: 0.22, green: 0.52, blue: 0.85, alpha: 1)),
        (NSColor(calibratedWhite: 0.96, alpha: 1), NSColor(calibratedWhite: 0.86, alpha: 1)),
    ]
    private static let sizes = [CGSize(width: 1440, height: 900), CGSize(width: 900, height: 1100),
                                CGSize(width: 1600, height: 700), CGSize(width: 1200, height: 900)]

    static func write(index: Int) -> URL? {
        let size = sizes[index % sizes.count]
        let (a, b) = palettes[index % palettes.count]
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGradient(starting: a, ending: b)!.draw(in: CGRect(origin: .zero, size: size), angle: -35)

        let dark = index % palettes.count == 3
        let ink = dark ? NSColor(white: 0.15, alpha: 1) : NSColor.white
        let panel = CGRect(x: size.width * 0.08, y: size.height * 0.12, width: size.width * 0.84, height: size.height * 0.62)
        (dark ? NSColor.white : NSColor(white: 1, alpha: 0.18)).setFill()
        NSBezierPath(roundedRect: panel, xRadius: 36, yRadius: 36).fill()

        let title = "QuickCap Sample \(index + 1)"
        title.draw(at: CGPoint(x: size.width * 0.08, y: size.height * 0.80),
                   withAttributes: [.font: NSFont.systemFont(ofSize: size.height * 0.08, weight: .bold), .foregroundColor: ink])
        let lines = ["Screenshots hang on a line. Drag them anywhere.", "Hover a card to copy it or show it in Finder.", "OCR test: The quick brown fox 2026"]
        let bodyInk = dark ? NSColor(white: 0.25, alpha: 1) : NSColor(white: 1, alpha: 0.95)
        for (i, line) in lines.enumerated() {
            line.draw(at: CGPoint(x: panel.minX + 48, y: panel.maxY - 90 - CGFloat(i) * size.height * 0.11),
                      withAttributes: [.font: NSFont.systemFont(ofSize: size.height * 0.045, weight: .medium), .foregroundColor: bodyInk])
        }
        NSGraphicsContext.restoreGraphicsState()

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("quickcap-sample-\(index).png")
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        try? data.write(to: url)
        return url
    }
}
