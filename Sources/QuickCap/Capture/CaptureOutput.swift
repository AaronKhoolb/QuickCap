import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

/// 截好的一张图：像素、在哪块屏幕的哪里（屏幕坐标，pt）、像素倍数
struct CapturedImage {
    let image: CGImage
    let screenRect: CGRect
    let scale: CGFloat
    /// 这块有 HDR 内容时的 HDR 图（扩展 sRGB）。有的话文件存成带增益图的 HEIC
    var hdr: CGImage?
    /// 截图那一刻屏幕的亮度余量（普通白色的几倍），文件里记的亮度范围按它来
    var screenHeadroom: CGFloat = 1
    /// 正在飞向截图架的那张图（没有的话直接挂上去）
    var flight: CaptureFlight?
    /// 钉到桌面：存好、挂上截图架之外，在原地出一张浮着的图
    var pinned = false
}

/// 把截图变成文件、放进剪贴板、另存一份
@MainActor
enum CaptureOutput {
    /// 调试运行时不碰真的剪贴板
    static var pasteboard: NSPasteboard = .general

    /// 从冻结的画面里裁出一块。rect 是覆盖窗口坐标（原点左下，pt）
    static func crop(_ frozen: CGImage, rect: CGRect, viewSize: CGSize) -> CGImage? {
        let sx = CGFloat(frozen.width) / viewSize.width
        let sy = CGFloat(frozen.height) / viewSize.height
        let px = CGRect(x: rect.minX * sx, y: (viewSize.height - rect.maxY) * sy,
                        width: rect.width * sx, height: rect.height * sy).integral
        return frozen.cropping(to: px)
    }

    /// 单独截一个窗口：带透明圆角，不会被前面的窗口挡住。
    /// visible 是窗口里实际画了东西的那块（pt，原点左上），只留这一块（程序坞、菜单栏这种窗口很大、大部分是空的）。
    /// hdr 时普通的和 HDR 的一起截。shadow：带上系统的窗口阴影（同时截一张不带的，用来对出窗口在哪）
    nonisolated static func captureWindow(id: CGWindowID, scale: CGFloat, cursor: Bool = false, visible: CGRect? = nil,
                                          hdr: Bool = false, shadow: Bool = false) async -> WindowShot? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let w = content.windows.first(where: { $0.windowID == id }) else { return nil }
        let pw = Int((w.frame.width * scale).rounded()), ph = Int((w.frame.height * scale).rounded())
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let box = ScreenWindows.UncheckedWindow(w)
        async let shadowed = shadow ? ScreenWindows.shadowShot(box, scale: scale, hdr: hdr, cursor: cursor) : nil
        var sdr: CGImage?, hdrImage: CGImage?
        if hdr {
            let cfg = SCScreenshotConfiguration()
            cfg.width = pw; cfg.height = ph
            cfg.showsCursor = cursor
            cfg.ignoreShadows = true
            cfg.dynamicRange = .bothSDRAndHDR
            cfg.displayIntent = .local
            if let out = try? await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: cfg) {
                sdr = out.sdrImage; hdrImage = out.hdrImage
            }
        }
        if sdr == nil {
            let config = SCStreamConfiguration()
            config.width = pw; config.height = ph
            config.showsCursor = cursor
            config.ignoreShadowsSingleWindow = true
            config.shouldBeOpaque = false
            config.captureResolution = .best
            sdr = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
        guard var img = sdr else { _ = await shadowed; return nil }
        if let sh = await shadowed,
           let shot = ScreenWindows.shadowCrop(sh, plain: img, visible: visible ?? CGRect(origin: .zero, size: w.frame.size), scale: scale) {
            return shot
        }
        if let v = visible {
            let px = CGRect(x: v.minX * scale, y: v.minY * scale, width: v.width * scale, height: v.height * scale).integral
            if px.width < CGFloat(img.width) || px.height < CGFloat(img.height) {
                img = img.cropping(to: px) ?? img
                hdrImage = hdrImage.flatMap { $0.cropping(to: px) }
            }
        }
        return WindowShot(image: img, hdr: hdrImage)
    }

    /// 一张 HDR 图里：最亮的像素亮度 Y、最大的通道值（都在线性 BT.2020 里，普通白色是 1.0）。全分辨率
    nonisolated static func hdrStats(_ img: CGImage) -> (maxY: Float, maxC: Float) {
        guard let cs = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) else { return (1, 1) }
        let w = img.width, h = img.height
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        var maxY: Float = 0, maxC: Float = 0
        let tileH = 256
        var buf = [Float](repeating: 0, count: w * tileH * 4)
        var y0 = 0
        while y0 < h {
            let th = min(tileH, h - y0)
            if let tile = img.cropping(to: CGRect(x: 0, y: y0, width: w, height: th)),
               let ctx = CGContext(data: &buf, width: w, height: th, bitsPerComponent: 32, bytesPerRow: w * 16, space: cs, bitmapInfo: info) {
                ctx.draw(tile, in: CGRect(x: 0, y: 0, width: w, height: th))
                for i in stride(from: 0, to: w * th * 4, by: 4) {
                    let r = buf[i], g = buf[i + 1], b = buf[i + 2]
                    maxC = max(maxC, r, g, b)
                    maxY = max(maxY, 0.2627 * r + 0.6780 * g + 0.0593 * b)
                }
            }
            y0 += th
        }
        return (maxY, maxC)
    }

    nonisolated static func peakBrightness(_ img: CGImage) -> Float { hdrStats(img).maxC }

    /// 比普通白色亮多少才算"有比白色亮的内容"：在 EDR 里普通白色就是 1.0（系统的定义）。
    /// 截图是 16 位浮点，1.0 附近相邻两个值差 2⁻¹⁰，转色域的舍入不会超过两格，所以容差是 2⁻⁹
    nonisolated static let hdrWhiteTolerance: Float = 1 + 1.0 / 512

    /// 文件里写的"这是截图"：和系统截图（/usr/sbin/screencapture）写的一样，EXIF 的 UserComment = Screenshot
    /// 加上像素尺寸。聚焦搜索的"是截图"那个标记是系统的索引器读这个 EXIF 自己加的，app 写不了
    nonisolated static func screenshotTags(_ image: CGImage) -> [CFString: Any] {
        [kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifUserComment: "Screenshot",
            kCGImagePropertyExifPixelXDimension: image.width,
            kCGImagePropertyExifPixelYDimension: image.height,
        ] as [CFString: Any]]
    }

    /// 存成哪种格式
    enum Format: String, CaseIterable {
        case heic, png, jpeg
        var ext: String { self == .jpeg ? "jpg" : rawValue }
        var title: String { self == .heic ? "HEIC" : self == .png ? "PNG" : "JPEG" }
        var type: UTType { self == .heic ? .heic : self == .png ? .png : .jpeg }
        /// HDR 只有 HEIC 存得了（带增益图）
        var keepsHDR: Bool { self == .heic }
        var detail: String {
            switch self {
            case .heic: return "Smallest files, keeps HDR. Best for Apple apps."
            case .png: return "Lossless, no HDR. Opens anywhere."
            case .jpeg: return "Smaller, lossy, no HDR, no transparency."
            }
        }
    }

    /// 存之前按设置改一下图：缩到 1 倍、换成 sRGB（这两样都不保留 HDR 那张）。
    /// 返回改好的图和新的倍数；都没开就原样返回
    nonisolated static func prepared(_ image: CGImage, hdr: CGImage?, scale: CGFloat, toStandard: Bool, toSRGB: Bool)
        -> (image: CGImage, hdr: CGImage?, scale: CGFloat) {
        guard toStandard || toSRGB else { return (image, hdr, scale) }
        let k = toStandard && scale > 1 ? 1 / scale : 1
        let w = max(1, Int((CGFloat(image.width) * k).rounded())), h = max(1, Int((CGFloat(image.height) * k).rounded()))
        let space = toSRGB ? CGColorSpace(name: CGColorSpace.sRGB) : (image.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3))
        guard let space,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (image, hdr, scale) }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return (image, hdr, scale) }
        // 缩小后 HDR 那张对不上了；sRGB 本来就放不下 HDR
        return (out, nil, k < 1 ? 1 : scale)
    }

    /// 按设置的格式出文件。HDR 的图只有 HEIC 留得住
    nonisolated static func fileData(_ image: CGImage, hdr: CGImage?, scale: CGFloat, screenHeadroom: CGFloat,
                                     format: Format) -> (Data, String)? {
        switch format {
        case .heic:
            if let d = heicData(image, hdr: hdr, scale: scale, screenHeadroom: screenHeadroom) { return (d, "heic") }
            return pngData(image, scale: scale).map { ($0, "png") }
        case .png:
            return pngData(image, scale: scale).map { ($0, "png") }
        case .jpeg:
            if let d = jpegData(image, scale: scale) { return (d, "jpg") }
            return pngData(image, scale: scale).map { ($0, "png") }
        }
    }

    /// 别的格式（从别处挂上截图架的 TIFF、GIF……）：按原来的类型存，存不了返回 nil
    nonisolated static func encode(_ image: CGImage, typeID: String?, scale: CGFloat) -> Data? {
        guard let typeID else { return nil }
        let data = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(data, typeID as CFString, 1, nil) else { return nil }
        let dpi = 72 * scale
        CGImageDestinationAddImage(dst, displayP3(image), [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? data as Data : nil
    }

    /// 改好的图换掉原来的文件：原来那份先挪到临时文件夹（撤销用），新的写进去，创建时间改回原来的。返回原来那份在哪
    nonisolated static func replaceKeepingDates(_ url: URL, with data: Data) -> URL? {
        let fm = FileManager.default
        let created = (try? fm.attributesOfItem(atPath: url.path))?[.creationDate] as? Date
        let dir = fm.temporaryDirectory.appendingPathComponent("QuickCap Originals", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let backup = dir.appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
        do {
            try fm.copyItem(at: url, to: backup)
            try data.write(to: url, options: .atomic)
        } catch {
            try? fm.removeItem(at: backup)
            return nil
        }
        if let created { try? fm.setAttributes([.creationDate: created], ofItemAtPath: url.path) }
        return backup
    }

    /// 撤销：原来那份搬回去
    nonisolated static func restore(_ url: URL, from backup: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: backup.path) else { return false }
        let created = (try? fm.attributesOfItem(atPath: url.path))?[.creationDate] as? Date
        do { _ = try fm.replaceItemAt(url, withItemAt: backup) } catch { return false }
        if let created { try? fm.setAttributes([.creationDate: created], ofItemAtPath: url.path) }
        // 内容变了：修改时间更新一下（缩略图按它认）
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return true
    }

    /// JPEG：质量 0.92（再高文件大很多、肉眼看不出），不透明
    nonisolated static func jpegData(_ image: CGImage, scale: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let dpi = 72 * scale
        var opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92,
                                     kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        opts.merge(screenshotTags(image)) { a, _ in a }
        CGImageDestinationAddImage(dst, displayP3(image), opts as CFDictionary)
        return CGImageDestinationFinalize(dst) ? data as Data : nil
    }

    /// 10 位、4:4:4（颜色不降采样，彩色文字边缘不糊）的 YCbCr，系统截图存 HEIC 用的就是这个
    nonisolated private static let pixelFormat10Bit444: UInt32 = 0x7866_3434 // 'xf44'

    /// 截图文件：最高质量的 HEIC，做法和系统截图（/usr/sbin/screencapture）一样：
    /// - 图像 10 位、4:4:4，Display P3
    /// - HDR 时：底图用截图工具给的普通（SDR）图——也就是屏幕上实际显示的样子，不支持 HDR 的地方看到的就是它；
    ///   再把 HDR 图交给编码器，按两张图的差算出全分辨率、10 位彩色的增益图。HDR 图自带截图那一刻屏幕的亮度余量，
    ///   所以文件里记的亮度范围就是当时屏幕的范围。
    /// 质量用 1.0（系统用 0.95，大约小 15%，但 1.0 平均误差小一半；还是比 PNG 小一半多）
    /// 编码不在主线程做（大的 HDR 截图要零点几秒），截图飞出去的动画不会等它
    nonisolated static func heicData(_ image: CGImage, hdr: CGImage?, scale: CGFloat, screenHeadroom: CGFloat) -> Data? {
        let dpi = 72 * scale
        let data = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else { return nil }
        var opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 1.0,
                                     kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        opts.merge(screenshotTags(image)) { a, _ in a }
        if let hdr, hdr.width == image.width, hdr.height == image.height {
            // 两个键没写进公开头文件，但就是同名的字符串；系统截图也这样传。编码器不认识的话只是忽略
            opts[kCGImageDestinationEncodeRequestOptions] = [
                kCGImageDestinationEncodeIsBaseImage: true,
                kCGImageDestinationEncodeBaseColorSpace: CGColorSpace.displayP3,
                kCGImageDestinationEncodeBasePixelFormatRequest: pixelFormat10Bit444,
                "kCGGenerateAdaptiveSoftClipCurve" as CFString: true,
            ] as [CFString: Any]
            CGImageDestinationAddImage(dst, image, opts as CFDictionary)
            let gainMap: [CFString: Any] = [
                kCGImageDestinationEncodeRequest: kCGImageDestinationEncodeToISOGainmap,
                kCGImageDestinationLossyCompressionQuality: 1.0,
                kCGImageDestinationEncodeRequestOptions: [
                    kCGImageDestinationEncodeGenerateGainMapWithBaseImage: true,
                    kCGImageDestinationEncodeGainMapPixelFormatRequest: pixelFormat10Bit444,
                    kCGImageDestinationEncodeGainMapSubsampleFactor: 1,
                    kCGImageDestinationEncodeAlternateColorSpace: CGColorSpace.displayP3_PQ,
                ] as [CFString: Any],
            ]
            // 文件里记的亮度范围 = 截图那一刻屏幕的亮度余量（和系统一样）。截整块屏幕时截图工具给的就是这个值。
            // 单独截窗口时，有的窗口（Chrome、Electron 这类）报的是"最多能多亮"（XDR 屏幕上 16 倍），不是屏幕现在的；
            // 照它存，看图的软件会以为整张图很亮、把普通内容压暗。所以不超过屏幕现在的余量；没标（0）就按量出来的最亮值
            // 不能在这里读屏幕现在的：截图界面显示着 HDR 的冻结画面时，屏幕会把余量开到最大（XDR 是 16 倍）
            let screenNow = screenHeadroom
            let headroom = hdr.contentHeadroom >= 1 ? min(hdr.contentHeadroom, Float(max(1, screenNow))) : max(1, hdrStats(hdr).maxC)
            let tagged = headroom == hdr.contentHeadroom ? hdr : (CGImageCreateCopyWithContentHeadroom(headroom, hdr) ?? hdr)
            CGImageDestinationAddImage(dst, tagged, gainMap as CFDictionary)
        } else {
            opts["kCGImageSurfaceFormatRequest" as CFString] = pixelFormat10Bit444
            CGImageDestinationAddImage(dst, displayP3(image), opts as CFDictionary)
        }
        return CGImageDestinationFinalize(dst) ? data as Data : nil
    }

    /// 普通（SDR）的图统一转成 Display P3：屏幕是广色域的，转成 sRGB 会把鲜艳的颜色截掉。
    /// 截图工具给的是扩展 sRGB 的浮点数据，按 16 位 P3 画一遍（和系统截图一样是 P3）
    nonisolated static func displayP3(_ image: CGImage) -> CGImage {
        guard let p3 = CGColorSpace(name: CGColorSpace.displayP3) else { return image }
        if image.colorSpace?.name == CGColorSpace.displayP3 { return image }
        // 用户选了存 sRGB：别再换回 P3
        if image.colorSpace?.name == CGColorSpace.sRGB { return image }
        let bpc = image.bitsPerComponent > 8 ? 16 : 8
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | (bpc == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0)
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: bpc,
                                  bytesPerRow: 0, space: p3, bitmapInfo: info) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    /// PNG，记下像素倍数（2x 的图在预览里按原大小显示）
    nonisolated static func pngData(_ image: CGImage, scale: CGFloat) -> Data? {
        let image = displayP3(image)
        let data = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let dpi = 72 * scale
        var opts: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        opts.merge(screenshotTags(image)) { a, _ in a }
        CGImageDestinationAddImage(dst, image, opts as CFDictionary)
        return CGImageDestinationFinalize(dst) ? data as Data : nil
    }

    /// 文件名：QuickCap 2026-11-20 at 07.40.12.png，重名就加数字
    /// 截图架卡片用的小图（和截图架自己生成的一样大），卡片一出来就有图，不会先闪一下灰底
    nonisolated static func thumbnail(_ image: CGImage, maxPixel: Int) -> CGImage? {
        let k = min(1, CGFloat(maxPixel) / CGFloat(max(image.width, image.height)))
        let w = max(1, Int((CGFloat(image.width) * k).rounded())), h = max(1, Int((CGFloat(image.height) * k).rounded()))
        guard let cs = CGColorSpace(name: CGColorSpace.displayP3),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// 已经起好名字、还在后台写的文件（同一秒截两张时不会起成同一个名字，后一张把前一张盖掉）
    nonisolated(unsafe) static var reserved: Set<String> = []

    static func newURL(in folder: URL, prefix: String = "QuickCap", date: Date = Date(), ext: String = "png") -> URL {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "\(prefix) \(f.string(from: date))"
        var url = folder.appendingPathComponent(base + "." + ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) || reserved.contains(url.path) {
            url = folder.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    /// 只放图片数据：同时放文件的话，有的应用会贴成附件或路径
    /// TIFF 只在别的 app 真要时才转（以前每次复制都在主线程编一份几十 MB 的 TIFF，复制时卡一下）
    static func copy(png: Data) {
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setDataProvider(LazyTIFF(png: png), forTypes: [.tiff])
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }
}

/// 剪贴板上的 TIFF：被要的时候才从 PNG 转
final class LazyTIFF: NSObject, NSPasteboardItemDataProvider {
    private let png: Data
    init(png: Data) { self.png = png }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        if type == .tiff, let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
    }
}

/// 截图完成后在操作条原来的位置出现的小提示，1 秒多后淡出
@MainActor
final class CaptureToast {
    private static var current: NSPanel?

    /// 收起正在显示的提示
    static func dismiss() {
        current?.orderOut(nil)
        current = nil
    }

    /// hold：显示多久（秒）。连 Wi‑Fi 这种要等的，先显示很久，结果出来时换掉
    static func show(_ text: String, symbol: String = "checkmark.circle.fill", at center: CGPoint, hold: Double = 1.5) {
        current?.orderOut(nil)
        lastText = text
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = NSWindow.Level(rawValue: CaptureOverlayWindow.captureLevel.rawValue + 1)
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.appearance = NSAppearance(named: .aqua)
        p.animationBehavior = .none

        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = 17
        let icon = BarButton.symbolView(symbol, pointSize: 15, weight: .regular,
                                        tint: NSColor(calibratedRed: 1, green: 0.58, blue: 0, alpha: 1))
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor(white: 0, alpha: 0.85)
        let row = NSStackView(views: [icon, label])
        row.spacing = 7
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(row)
        glass.contentView = content
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 11),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -15),
            row.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            content.heightAnchor.constraint(equalToConstant: 34),
        ])
        let w = (row.fittingSize.width + 26).rounded(.up), h: CGFloat = 34
        var f = CGRect(x: (center.x - w / 2).rounded(), y: (center.y - h / 2).rounded(), width: w, height: h)
        // 不跑出屏幕（选区贴着屏幕边、多块屏幕时）
        if let vis = (NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main)?.visibleFrame.insetBy(dx: 8, dy: 8) {
            f.origin.x = min(max(f.minX, vis.minX), vis.maxX - w)
            f.origin.y = min(max(f.minY, vis.minY), vis.maxY - h)
        }
        p.setFrame(f, display: false)
        glass.frame = CGRect(x: 0, y: 0, width: w, height: h)
        p.contentView = glass
        p.alphaValue = 0
        p.orderFrontRegardless()
        current = p
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            p.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
            guard current === p else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.24
                p.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    p.orderOut(nil)
                    if current === p { current = nil }
                }
            })
        }
    }

    /// 最近一次提示的文字（调试用；卡片上的提示也记在这里）
    static var lastText: String?
}
