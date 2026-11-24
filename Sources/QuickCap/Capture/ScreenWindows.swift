import AppKit
import ScreenCaptureKit

/// 打开截图时屏幕上的一个窗口。坐标是某块屏幕的覆盖窗口坐标（原点左下，pt）
struct ScreenWindow {
    let id: CGWindowID
    let owner: String
    let title: String
    /// 系统报告的窗口范围
    let frame: CGRect
    /// 实际画出来的范围（不透明的像素）。普通窗口就是 frame；程序坞、菜单栏这种盖满屏幕的窗口只有一小条
    var rect: CGRect
    /// 实际的圆角（量出来的）
    var corner: CGFloat
    /// 已经截过这个窗口、量过实际像素
    var verified: Bool
    /// 窗口在第几层（0 是普通窗口）
    let layer: Int

    /// 是不是普通 app（程序坞里有图标的那种）的窗口；系统进程画的（菜单栏这类）不是
    let ownerIsRegularApp: Bool

    /// 标签上写的名字：普通 app 写应用名；系统进程画的写窗口标题（比如 "Menubar"）。
    /// 标题是给程序看的标识（带 "::" 或者没有空格的 com.xxx.yyy）就不用它，还是写进程名
    var label: String {
        if ownerIsRegularApp, !owner.isEmpty { return owner }
        let readable = !title.isEmpty && !title.contains("::") && !(title.contains(".") && !title.contains(" "))
        return readable ? title : !owner.isEmpty ? owner : "Window"
    }
}

/// 窗口检测：不按应用、层数、名字去猜，而是把每个窗口单独截一张，看它实际画出了哪些像素。
/// 看不见的辅助窗口（比如 Grammarly 盖在别的 app 上的透明窗口）一个像素都没画，自然就不算；
/// 程序坞、菜单栏、通知、刘海工具这种窗口，算它们实际画出来的那一块；圆角也按实际量。
enum ScreenWindows {
    /// 有没有别的进程的窗口盖满了整块屏幕、而且排在截图界面前面。
    /// Mission Control、应用程序窗口、启动台这些系统界面都是这样出现的；不用认它们叫什么
    static func somethingCoversOverlay(_ overlayIDs: Set<CGWindowID>) -> Bool {
        // 只拿排在截图界面上面的窗口（平时是空的；以前每 0.25 秒拷贝一次全部窗口，拖选区时偶尔掉帧）
        let top = overlayIDs.max() ?? kCGNullWindowID
        let opts: CGWindowListOption = top == kCGNullWindowID ? [.optionOnScreenOnly] : [.optionOnScreenAboveWindow]
        guard let info = CGWindowListCopyWindowInfo(opts, top) as? [[String: Any]] else { return false }
        let pid = ProcessInfo.processInfo.processIdentifier
        let screens = NSScreen.screens.map(\.frame.size)
        for w in info {
            // 列表从前往后：碰到截图界面自己的窗口之前出现的，才是"在上面"的
            // （只拿上面的窗口时，碰到的是另一块屏幕的截图界面，跳过）
            if let id = w[kCGWindowNumber as String] as? CGWindowID, overlayIDs.contains(id) {
                if top == kCGNullWindowID { return false } else { continue }
            }
            guard (w[kCGWindowOwnerPID as String] as? Int32) != pid,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let g = CGRect(dictionaryRepresentation: dict) else { continue }
            if screens.contains(where: { g.width >= $0.width - 1 && g.height >= $0.height - 1 }) { return true }
        }
        return false
    }

    /// 每个进程是不是普通 app（有程序坞图标的）。实时模式下半秒查一次窗口列表，每次都为每个窗口
    /// 新建一个 NSRunningApplication 要多花一倍时间；进程在运行时这个不会变，记住就好
    @MainActor private static var regularByPID: [pid_t: Bool] = [:]
    @MainActor private static func isRegularApp(_ pid: pid_t) -> Bool {
        if let v = regularByPID[pid] { return v }
        let v = NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
        if regularByPID.count > 300 { regularByPID = [:] }
        regularByPID[pid] = v
        return v
    }

    /// 量过的窗口（按窗口编号和范围记着），下次打开截图界面先用这个，后台再量一遍
    @MainActor private static var cache: [CGWindowID: (frame: CGRect, rect: CGRect, corner: CGFloat)] = [:]

    /// 这块屏幕上的窗口，从前到后排。马上返回：普通窗口（第 0 层）先当作整块都画了；
    /// 别的层没量过的先不算（看不见的辅助窗口大多在这里），等 verify 量完再加进来
    @MainActor
    static func list(for screen: NSScreen) -> [ScreenWindow] {
        let size = screen.frame.size
        // 窗口列表的坐标原点在主屏幕左上角、y 向下，要换成这块屏幕的左下角原点
        let primaryHeight = NSScreen.screens.first?.frame.height ?? size.height
        let pid = ProcessInfo.processInfo.processIdentifier
        let bounds = CGRect(origin: .zero, size: size)
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        var out: [ScreenWindow] = []
        for w in info {
            guard let layer = w[kCGWindowLayer as String] as? Int,
                  (w[kCGWindowOwnerPID as String] as? Int32) != pid,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let g = CGRect(dictionaryRepresentation: dict) else { continue }
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            let f = CGRect(x: g.minX - screen.frame.minX, y: primaryHeight - g.maxY - screen.frame.minY, width: g.width, height: g.height)
            guard f.width >= 8, f.height >= 8, f.intersects(bounds) else { continue }
            let title = w[kCGWindowName as String] as? String ?? ""
            let ownerPID = w[kCGWindowOwnerPID as String] as? Int32 ?? 0
            let regular = isRegularApp(ownerPID)
            if let c = cache[id], c.frame == f {
                out.append(ScreenWindow(id: id, owner: owner, title: title, frame: f, rect: c.rect, corner: c.corner, verified: true,
                                        layer: layer, ownerIsRegularApp: regular))
            } else {
                out.append(ScreenWindow(id: id, owner: owner, title: title, frame: f, rect: f, corner: 16, verified: false,
                                        layer: layer, ownerIsRegularApp: regular))
            }
        }
        return out
    }

    /// 能用来选的窗口：量过的；还没量完时，先用普通 app 的普通窗口（第 0 层）
    static func usable(_ ws: [ScreenWindow]) -> [ScreenWindow] {
        // 太小的（录屏、麦克风的小圆点这种指示灯）不算窗口
        ws.filter { ($0.verified || ($0.layer == 0 && $0.ownerIsRegularApp)) && $0.rect.width >= 16 && $0.rect.height >= 16 }
    }

    /// 把窗口都截一张（同时截几张，十几个窗口大约 0.1–0.2 秒），量实际画出来的范围和圆角。
    /// 记着的也重新量：通知中心、程序坞这种盖满屏幕的窗口，范围不变、里面画的东西会变（展开、收起、动画中），
    /// 记着的只是先用着，量完就换掉。一个像素都没画的窗口从列表里去掉；截不到的照原样留着
    @MainActor
    static func verify(_ ws: [ScreenWindow], scale: CGFloat, all: Bool = true) async -> [ScreenWindow] {
        let todo = Set(ws.filter { all || !$0.verified }.map(\.id))
        guard !todo.isEmpty,
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return ws }
        let scwins = content.windows.filter { todo.contains($0.windowID) }
        var found: [CGWindowID: WindowPixels] = [:]
        await withTaskGroup(of: (CGWindowID, WindowPixels?).self) { group in
            for w in scwins {
                let box = UncheckedWindow(w)
                // 大窗口 1 倍就够量了；小窗口用 2 倍，圆角量得准
                let k: CGFloat = w.frame.width * w.frame.height > 1_200_000 ? 1 : min(scale, 2)
                group.addTask { (box.w.windowID, await measure(box.w, scale: k)) }
            }
            for await (id, px) in group { if let px { found[id] = px } }
        }
        return apply(found, to: ws, only: todo)
    }

    /// 把量出来的范围、圆角用到窗口列表上。一个像素都没画的去掉；only 以外的、没量到的照原样留着
    @MainActor
    static func apply(_ found: [CGWindowID: WindowPixels], to ws: [ScreenWindow], only: Set<CGWindowID>? = nil) -> [ScreenWindow] {
        var out: [ScreenWindow] = []
        for var w in ws {
            if only?.contains(w.id) ?? true, let px = found[w.id] {
                guard let local = px.visible else { continue } // 一个像素都没画：不是能截的东西
                // 量出来的范围（窗口里，原点左上）换成覆盖窗口坐标（原点左下）
                w.rect = CGRect(x: w.frame.minX + local.minX, y: w.frame.maxY - local.maxY, width: local.width, height: local.height)
                w.corner = px.corner
                w.verified = true
                cache[w.id] = (w.frame, w.rect, w.corner)
            }
            out.append(w)
        }
        return out
    }

    struct UncheckedWindow: @unchecked Sendable {
        let w: SCWindow
        init(_ w: SCWindow) { self.w = w }
    }

    struct WindowPixels: Sendable {
        /// 实际画出来的范围（窗口坐标，pt，原点左上）。nil 表示一个像素都没画
        let visible: CGRect?
        let corner: CGFloat
    }

    /// 截这个窗口，量所有不完全透明的像素的范围；沿四个角的对角线量圆角
    nonisolated private static func measure(_ w: SCWindow, scale: CGFloat) async -> WindowPixels? {
        let cfg = SCStreamConfiguration()
        cfg.width = max(1, Int((w.frame.width * scale).rounded()))
        cfg.height = max(1, Int((w.frame.height * scale).rounded()))
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true
        cfg.shouldBeOpaque = false
        guard let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w),
                                                                   configuration: cfg) else { return nil }
        return pixels(of: img, scale: scale)
    }

    /// 量一张窗口图：所有不完全透明的像素的范围，和圆角。img 按 scale 倍画（每 pt 几个像素）
    nonisolated private static func pixels(of img: CGImage, scale: CGFloat) -> WindowPixels? {
        let pw = img.width, ph = img.height
        var a = [UInt8](repeating: 0, count: pw * ph)
        guard let ctx = CGContext(data: &a, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: pw, height: ph))
        // 内存里第 0 行是图的最上面一行
        var minX = pw, minY = ph, maxX = -1, maxY = -1
        for y in 0..<ph {
            let row = y * pw
            for x in 0..<pw where a[row + x] > 0 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return WindowPixels(visible: nil, corner: 0) }
        // 圆角：从可见范围的左上角沿 45° 往里走，到不透明度一半的地方停。
        // 圆角半径 r 的角，沿对角线走 d 个像素才碰到边：d = r(√2 − 1)，所以 r = d / 0.414
        func cornerAt(_ x0: Int, _ y0: Int, _ dx: Int, _ dy: Int) -> CGFloat {
            var prev: Float = 0
            for i in 0..<min(80, maxX - minX, maxY - minY) {
                let v = Float(a[(y0 + dy * i) * pw + (x0 + dx * i)]) / 255
                if v >= 0.5 {
                    // 在前一个像素和这个像素之间按不透明度插一下，量到小于一个像素
                    let t = i == 0 ? 0 : CGFloat((0.5 - prev) / max(v - prev, 0.001))
                    let d = (CGFloat(i) - 1 + t) * sqrt(2)
                    return max(0, d / (sqrt(2) - 1)) / scale
                }
                prev = v
            }
            return 0
        }
        let corners = [cornerAt(minX, minY, 1, 1), cornerAt(maxX, minY, -1, 1), cornerAt(minX, maxY, 1, -1), cornerAt(maxX, maxY, -1, -1)].sorted()
        let r = (corners[1] + corners[2]) / 2 // 四个角取中间两个的平均，不怕某个角上有按钮
        let visible = CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                             width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
        return WindowPixels(visible: visible, corner: (r * 2).rounded() / 2)
    }
}

/// 冻结屏幕那一刻截下来的一个窗口（只留实际画了东西的那块）。
/// 通知中心、菜单、弹出框、聚焦搜索这些，QuickCap 一拿到键盘焦点就会自己收起来，之后再截就没了，
/// 所以冻结时就把每个窗口当时的样子都截下来，之后选哪个就用哪个（和冻结的整块屏幕是同一刻）
struct WindowShot: @unchecked Sendable {
    let image: CGImage
    /// 这个窗口有 HDR 内容时的 HDR 版本（和 image 同一次截的）
    let hdr: CGImage?
    /// 带系统阴影时，图四边比窗口多出来的部分（pt）；不带阴影是 .zero
    var shadow: ShadowInsets = .zero
    var bytes: Int { image.bytesPerRow * image.height + (hdr.map { $0.bytesPerRow * $0.height } ?? 0) }
}

/// 窗口截图带上系统阴影后，图四边比窗口多出来的部分（pt）。
/// 阴影是系统自己画的（和系统截图、screencapture -l 一模一样）：前台窗口约左右 56、上 38、下 74，后台窗口小一圈
struct ShadowInsets: Sendable, Equatable {
    var top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0
    static let zero = ShadowInsets()
    var isZero: Bool { top == 0 && left == 0 && bottom == 0 && right == 0 }
    /// 屏幕坐标（原点左下）里的窗口范围，加上阴影
    func expand(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX - left, y: r.minY - bottom, width: r.width + left + right, height: r.height + top + bottom)
    }
}

extension ScreenWindows {
    /// 冻结时截下的窗口和量出来的范围
    struct Frozen: Sendable {
        /// 窗口在全局坐标里实际画了东西的范围（窗口里，pt，原点左上），nil 表示一个像素都没画
        var pixels: [CGWindowID: WindowPixels] = [:]
        var shots: [CGWindowID: WindowShot] = [:]
    }

    /// 截下屏幕上所有窗口当时的样子（原始分辨率，同时截，十几个窗口约 0.3 秒），顺便量范围和圆角。
    /// scaleFor：窗口所在屏幕的像素倍数。hdr：有 HDR 内容的窗口顺便拿 HDR 版本。
    /// 内存：所有窗口加起来超过 budget 字节，就只量不留图（那些窗口出图时再现截）
    nonisolated static func freezeAll(excluding pid: pid_t, hdr: Bool, shadow: Bool = false, budget: Int = 700_000_000,
                                      scaleFor: @Sendable (CGRect) -> CGFloat) async -> Frozen {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return Frozen() }
        let ws = content.windows.filter { $0.isOnScreen && $0.owningApplication?.processID != pid && $0.frame.width >= 8 && $0.frame.height >= 8 }
        var out = Frozen()
        await withTaskGroup(of: (CGWindowID, WindowPixels?, WindowShot?).self) { group in
            for w in ws {
                let box = UncheckedWindow(w)
                let scale = scaleFor(w.frame)
                group.addTask {
                    let (px, shot) = await freeze(box.w, scale: scale, hdr: hdr, shadow: shadow)
                    return (box.w.windowID, px, shot)
                }
            }
            for await (id, px, shot) in group {
                if let px { out.pixels[id] = px }
                if let shot { out.shots[id] = shot }
            }
        }
        // 超出内存预算：从最大的开始丢（丢了的出图时再现截）
        var total = out.shots.values.reduce(0) { $0 + $1.bytes }
        for (id, shot) in out.shots.sorted(by: { $0.value.bytes > $1.value.bytes }) where total > budget {
            out.shots[id] = nil
            total -= shot.bytes
        }
        return out
    }

    /// 截一个窗口（原始分辨率，带透明圆角，不带阴影），量范围，裁到实际画了东西的那块。
    /// shadow：同时再截一张带系统阴影的，留下的是带阴影的那张（量范围、圆角还是用不带阴影的）。
    /// 要在拿键盘焦点之前截：前台窗口这时还是前台的样子（彩色红绿灯、大阴影）
    nonisolated private static func freeze(_ w: SCWindow, scale: CGFloat, hdr: Bool, shadow: Bool) async -> (WindowPixels?, WindowShot?) {
        let pw = max(1, Int((w.frame.width * scale).rounded())), ph = max(1, Int((w.frame.height * scale).rounded()))
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let box = UncheckedWindow(w)
        async let shadowed = shadow ? shadowShot(box, scale: scale, hdr: hdr) : nil
        var image: CGImage?, hdrImage: CGImage?
        if hdr {
            let cfg = SCScreenshotConfiguration()
            cfg.width = pw; cfg.height = ph
            cfg.showsCursor = false
            cfg.ignoreShadows = true
            cfg.dynamicRange = .bothSDRAndHDR
            cfg.displayIntent = .local
            if let o = try? await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: cfg) {
                image = o.sdrImage; hdrImage = o.hdrImage
            }
        }
        if image == nil {
            let cfg = SCStreamConfiguration()
            cfg.width = pw; cfg.height = ph
            cfg.showsCursor = false
            cfg.ignoreShadowsSingleWindow = true
            cfg.shouldBeOpaque = false
            cfg.captureResolution = .best
            image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        }
        guard let img = image else { _ = await shadowed; return (nil, nil) }
        // 量的时候大窗口按 1 倍、小窗口按 2 倍缩下来量就够准了
        let k: CGFloat = w.frame.width * w.frame.height > 1_200_000 ? 1 : min(scale, 2)
        guard let small = downscale(img, to: CGSize(width: w.frame.width * k, height: w.frame.height * k)),
              let px = pixels(of: small, scale: k) else { return (nil, nil) }
        guard let v = px.visible else { _ = await shadowed; return (px, nil) }
        if let sh = await shadowed, let shot = shadowCrop(sh, plain: img, visible: v, scale: scale) { return (px, shot) }
        // 只留实际画了东西的那块。程序坞、菜单栏、通知中心这种盖满屏幕的窗口大部分是空的，裁完小很多；
        // 裁的时候复制一份，原来那张整屏的才会释放
        let crop = CGRect(x: v.minX * scale, y: v.minY * scale, width: v.width * scale, height: v.height * scale).integral
            .intersection(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let full = crop.width * crop.height > CGFloat(img.width * img.height) * 0.9
        let keep = full ? img : (compactCrop(img, crop) ?? img)
        let keepHDR = hdrImage.flatMap { full ? $0 : compactCrop($0, crop) }
        return (px, WindowShot(image: keep, hdr: keepHDR))
    }

    // MARK: 系统阴影

    /// 带系统阴影截一个窗口。不指定大小：系统按窗口自己的像素倍数出图，比窗口大出一圈阴影
    /// （指定成窗口的大小的话，阴影会被硬塞进去、窗口被压扁）。像素倍数和屏幕对不上就不要
    nonisolated static func shadowShot(_ box: UncheckedWindow, scale: CGFloat, hdr: Bool, cursor: Bool = false) async -> (CGImage, CGImage?)? {
        let w = box.w
        let cfg = SCScreenshotConfiguration()
        cfg.showsCursor = cursor
        cfg.ignoreShadows = false
        cfg.dynamicRange = hdr ? .bothSDRAndHDR : .sdr
        cfg.displayIntent = .local
        guard let o = try? await SCScreenshotManager.captureScreenshot(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg),
              let img = o.sdrImage,
              img.width >= Int((w.frame.width * scale).rounded()), img.height >= Int((w.frame.height * scale).rounded()) else { return nil }
        return (img, o.hdrImage)
    }

    /// 带阴影的图里窗口在哪：左右的阴影一样宽；上下不一样（阴影往下偏），拿几列像素和不带阴影的图对一下，
    /// 看窗口的上边在带阴影的图里往下挪了几行。返回四边多出来的像素
    nonisolated static func shadowMargins(_ sh: CGImage, plain: CGImage) -> (top: Int, left: Int, bottom: Int, right: Int)? {
        let extraW = sh.width - plain.width, extraH = sh.height - plain.height
        // 没有阴影的窗口（程序坞、菜单栏这种）：两张一样大
        guard extraW >= 4, extraH >= 4 else { return nil }
        let left = extraW / 2
        var tops: [Int] = []
        for f in [0.25, 0.4, 0.5, 0.6, 0.75] {
            let x = Int(Double(plain.width) * f)
            guard let r0 = firstOpaqueRow(plain, x: x), let r1 = firstOpaqueRow(sh, x: x + left) else { continue }
            let d = r1 - r0
            if d >= 0 && d <= extraH { tops.append(d) }
        }
        // 对不出来（窗口上边是半透明的）：按系统阴影的比例分，上面约占三分之一
        let top = tops.isEmpty ? Int((Double(extraH) * 0.34).rounded()) : tops.sorted()[tops.count / 2]
        return (top, left, extraH - top, extraW - left)
    }

    /// 这一列从上往下第一个不透明的像素在第几行（第 0 行是最上面）
    nonisolated private static func firstOpaqueRow(_ img: CGImage, x: Int) -> Int? {
        guard x >= 0, x < img.width, let col = img.cropping(to: CGRect(x: x, y: 0, width: 1, height: img.height)) else { return nil }
        let h = col.height
        var a = [UInt8](repeating: 0, count: h)
        guard let ctx = CGContext(data: &a, width: 1, height: h, bitsPerComponent: 8, bytesPerRow: 1,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }
        ctx.draw(col, in: CGRect(x: 0, y: 0, width: 1, height: h))
        return a.firstIndex { $0 >= 250 }
    }

    /// 带阴影的图裁到"实际画了东西的那块 + 一圈阴影"。visible：窗口里实际画了东西的范围（pt，原点左上）。
    /// 没有阴影返回 nil（用不带阴影的那张）
    nonisolated static func shadowCrop(_ sh: (CGImage, CGImage?), plain: CGImage, visible v: CGRect, scale: CGFloat) -> WindowShot? {
        guard let m = shadowMargins(sh.0, plain: plain) else { return nil }
        let img = sh.0
        let crop = CGRect(x: v.minX * scale, y: v.minY * scale,
                          width: v.width * scale + CGFloat(m.left + m.right), height: v.height * scale + CGFloat(m.top + m.bottom))
            .integral.intersection(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let full = crop.width * crop.height > CGFloat(img.width * img.height) * 0.9
        let keep = full ? img : (compactCrop(img, crop) ?? img)
        let keepHDR = sh.1.flatMap { full ? $0 : compactCrop($0, crop) }
        let insets = ShadowInsets(top: CGFloat(m.top) / scale, left: CGFloat(m.left) / scale,
                                  bottom: CGFloat(m.bottom) / scale, right: CGFloat(m.right) / scale)
        return WindowShot(image: keep, hdr: keepHDR, shadow: insets)
    }

    /// 缩小画一遍（只用来量透明度）
    nonisolated private static func downscale(_ img: CGImage, to size: CGSize) -> CGImage? {
        let w = max(1, Int(size.width.rounded())), h = max(1, Int(size.height.rounded()))
        if w == img.width && h == img.height { return img }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// 裁一块并复制出来（cropping 只是引用原图，原图不会释放）。颜色、位深、HDR 亮度标记都保留
    nonisolated private static func compactCrop(_ img: CGImage, _ r: CGRect) -> CGImage? {
        guard let part = img.cropping(to: r), let cs = img.colorSpace,
              let ctx = CGContext(data: nil, width: part.width, height: part.height, bitsPerComponent: img.bitsPerComponent,
                                  bytesPerRow: 0, space: cs, bitmapInfo: img.bitmapInfo.rawValue) else { return img.cropping(to: r) }
        ctx.draw(part, in: CGRect(x: 0, y: 0, width: part.width, height: part.height))
        guard let copy = ctx.makeImage() else { return part }
        return img.contentHeadroom >= 1 ? (CGImageCreateCopyWithContentHeadroom(img.contentHeadroom, copy) ?? copy) : copy
    }
}

/// 截图界面用的光标
@MainActor
enum CaptureCursor {
    /// 窗口模式下停在窗口上：黑色相机加白边，和系统截图一样
    static let camera: NSCursor = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.black]))
        let sym = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) ?? NSImage()
        let s = NSSize(width: sym.size.width + 6, height: sym.size.height + 6)
        let img = NSImage(size: s, flipped: false) { _ in
            let shadow = NSShadow()
            shadow.shadowColor = .white
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = .zero
            shadow.set()
            // 叠几次让白边更实
            for _ in 0..<3 { sym.draw(in: CGRect(x: 3, y: 3, width: sym.size.width, height: sym.size.height)) }
            return true
        }
        return NSCursor(image: img, hotSpot: NSPoint(x: s.width / 2, y: s.height / 2))
    }()
}
