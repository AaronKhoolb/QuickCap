import AppKit

/// 调试用：按脚本模拟鼠标和键盘操作截图界面，每一步之后把状态写进日志。
/// 事件用 NSApp.postEvent 送进来，和真的鼠标键盘走同一条路（命中测试、第一响应者、输入框）。
///
/// 脚本一行一条：
///   open | open text          打开截图界面（Text 快捷键那种）
///   wait 秒
///   move P                    鼠标移动
///   click P [mods]            点一下
///   drag P P [mods]           按下、拖、松开
///   down P / to P [mods] / up P   分开的按下、拖到、松开
///   key 名字 [mods]           esc return tab space left right up down 或一个字母、数字
///   type 文字                 逐个字符输入
///   log 名字                  写一行状态
///   snap 文件名               截整块主屏幕（包括截图界面）
/// P：x,y（主屏幕覆盖窗口坐标，原点左下）或 handle:bottomRight、sel:center、badge:w、badge:h、bar:window 这类名字，
///    名字后面可以加 @dx,dy 偏移。mods：shift cmd opt ctrl 的组合，比如 shift+opt
@MainActor
enum CaptureTest {
    static func run(script: String, log: String, app: AppDelegate) {
        guard let text = try? String(contentsOfFile: script, encoding: .utf8) else {
            write(log, "cannot read \(script)\n", append: false); return
        }
        write(log, "", append: false)
        listenForSignal()
        let steps = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        var i = 0
        func next() {
            guard i < steps.count else { write(log, "done\n"); return }
            let line = steps[i]; i += 1
            let delay = perform(line, log: log, app: app)
            if repeatLine { repeatLine = false; i -= 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { next() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { next() }
    }

    private static func write(_ path: String, _ s: String, append: Bool = true) {
        if append, let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data(s.utf8)); try? h.close()
        } else {
            try? s.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private static var view: CaptureOverlayView? { app?.captureForDebug?.overlays.first?.overlayView }
    private static weak var app: AppDelegate?

    /// 执行一行，返回等多久再执行下一行
    private static func perform(_ line: String, log: String, app a: AppDelegate) -> Double {
        app = a
        let parts = line.split(separator: " ").map(String.init)
        let cmd = parts[0]
        let args = Array(parts.dropFirst())
        func mods(_ s: String?) -> NSEvent.ModifierFlags {
            guard let s else { return [] }
            var f: NSEvent.ModifierFlags = []
            for m in s.split(separator: "+") {
                switch m {
                case "shift": f.insert(.shift)
                case "cmd": f.insert(.command)
                case "opt": f.insert(.option)
                case "ctrl": f.insert(.control)
                default: break
                }
            }
            return f
        }
        switch cmd {
        case "open":
            if args.first == "text" { a.startTextCapture() } else { a.startCapture() }
            return 1.2
        case "alt":
            a.captureForDebug?.modifiersChanged(args.first == "on" ? .option : [])
            return 0.2
        case "tool":
            // tool arrow|rectangle|pen|text|highlight|blur|counter|none
            a.captureForDebug?.selectTool(args.first.flatMap(AnnotationTool.init(rawValue:)))
            return 0.15
        case "search":
            // search <字>：打开截图架搜索，输入这些字；search off：收起
            if args.first == "off" { a.shelfForDebug?.closeSearch(); return 0.2 }
            a.shelfForDebug?.openSearch()
            a.shelfForDebug?.debugSetQuery(args.joined(separator: " "))
            return 0.4
        case "search-state":
            write(log, "[search-state \(args.joined(separator: " "))] \(a.shelfForDebug?.debugSearch ?? "-") \(ShelfTextIndex.shared.debugText)\n")
            return 0.05
        case "beauty":
            // beauty：按一下背景按钮；beauty bg=0..6 pad=0..2 ratio=0..3：直接设
            if args.isEmpty { a.captureForDebug?.toggleBeauty(); return 0.3 }
            var st = BeautyStyle.load()
            for kv in args {
                let p = kv.split(separator: "=")
                guard p.count == 2, let n = Int(p[1]) else { continue }
                if p[0] == "bg", let b = BeautyBackground(rawValue: n) { st.background = b }
                if p[0] == "pad" { st.padding = n }
                if p[0] == "ratio" { st.ratio = n }
            }
            st.save()
            a.captureForDebug?.activeOverlay?.setBeauty(true, style: st)
            return 0.3
        case "shelf-edit":
            // shelf-edit 第几张：双击那张（拿下来改）
            let items = a.shelfForDebug?.items ?? []
            if let i = Int(args.first ?? ""), items.indices.contains(i) {
                write(log, "[shelf-edit] \(items[i].url.lastPathComponent) \(Int(items[i].pixelSize.width))x\(Int(items[i].pixelSize.height))\n")
                a.debugShelf.show()
                // 等截图架展开、卡片挂好再拿
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { a.edit(items[i]) }
            }
            return 2.2
        case "edit-save":
            // edit-save replace / saveAsNew：下次主按钮做什么
            ActionBar.EditSave.last = args.first == "saveAsNew" ? .saveAsNew : .replace
            return 0.05
        case "undo-pill":
            a.debugShelf.debugView?.undoPill.fire()
            return 0.8
        case "file":
            // file 路径：大小、修改时间（存回去以后看）
            let path = args.joined(separator: " ")
            let attr = try? FileManager.default.attributesOfItem(atPath: path)
            let px = ShelfItem.load(URL(fileURLWithPath: path))?.pixelSize ?? .zero
            write(log, "[file] \(URL(fileURLWithPath: path).lastPathComponent) px=\(Int(px.width))x\(Int(px.height)) bytes=\(attr?[.size] ?? 0) created=\(attr?[.creationDate] ?? "-") modified=\(attr?[.modificationDate] ?? "-")\n")
            return 0.05
        case "editor":
            // editor open 图片路径 [edit]：拿一张图开编辑画布；editor state：写下现在的样子
            if args.first == "open", args.count > 1, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
               let img = CGImageSourceCreateImageAtIndex(src, 0, nil), let screen = NSScreen.main {
                let e = ImageEditor(mode: args.count > 2 && args[2] == "edit" ? .edit : .review, image: img, hdr: nil,
                                    scale: screen.backingScaleFactor, screen: screen, headroom: 1, settings: AppSettings.shared)
                e.onCapture = { c, _ in write(log, "[editor captured] \(c.image.width)x\(c.image.height) pinned=\(c.pinned)\n") }
                e.onReplace = { i, _ in write(log, "[editor replaced] \(i.width)x\(i.height)\n") }
                e.onSaveAsNew = { c in write(log, "[editor saved-new] \(c.image.width)x\(c.image.height)\n") }
                e.onClose = { r in write(log, "[editor closed] \(r)\n") }
                let f = screen.frame
                e.present(from: CGRect(x: f.midX - 150, y: f.midY - 100, width: 300, height: 200))
                return 0.8
            }
            if args.first == "dump", args.count > 1, let e = ImageEditor.current {
                try? NSBitmapImageRep(cgImage: e.render().0).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[1]))
            }
            write(log, "[editor \(args.joined(separator: " "))] \(ImageEditor.current?.view.debugText ?? "closed")\n")
            return 0.05
        case "scroll-tip":
            a.captureForDebug?.debugScrollTip(); return 0.3
        case "scroll-state":
            write(log, "[scroll-state \(args.joined(separator: " "))] \(a.captureForDebug?.debugScroll ?? "no session")\n")
            return 0.05
        case "pin-clip":
            // 剪贴板里的图钉出来（先用 copy-newest 或 pbcopy 放一张）
            write(log, "pin-clip ok=\(PinWindow.pinFromClipboard()) \(PinWindow.debugText)\n"); return 0.4
        case "pin-key":
            // pin-key <名字> [mods]：给最上面那张钉图送一个键（不用真的点它）
            PinWindow.debugKey(args.first ?? "", mods: args.dropFirst().first ?? ""); return 0.2
        case "pin-lock":
            PinWindow.debugLast?.setLocked(args.first != "off"); if args.first == "off" { PinWindow.unlockAll() }; return 0.2
        case "pin-save":
            PinWindow.flushState()
            let s = (try? String(contentsOf: PinWindow.stateURL, encoding: .utf8)) ?? "-"
            write(log, "pin-save \(s)\n"); return 0.1
        case "pin-closeall":
            PinWindow.closeAll(); return 0.4
        case "pin-restore":
            PinWindow.restore(); write(log, "pin-restore \(PinWindow.debugText)\n"); return 0.4
        case "ax-probe":
            // 辅助功能读得到几个元素（不开截图界面）、截图界面里有几条元素吸附线
            let f = UIElementEdges.frames()
            let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "-"
            write(log, "[ax-probe] trusted=\(UIElementEdges.isTrusted) front=\(app) elements=\(f.count) overlayLines=\(a.captureForDebug?.overlays.first?.overlayView.elementSnapCount ?? -1)\n")
            return 0.05
        case "excluded":
            write(log, "[excluded] \(CaptureSession.debugExcluded)\n"); return 0.05
        case "pin-annotate":
            // 最上面那张钉图打开编辑器（Replace 后看钉图和文件有没有换）
            if let p = PinWindow.debugLast { a.annotate(p) }
            write(log, "[pin-annotate] editor=\(ImageEditor.current != nil) \(PinWindow.debugText)\n"); return 1.0
        case "editor-replace":
            // 编辑器直接按"存回去"（不用找按钮），并且加一圈 G 键那种美化背景让尺寸变
            if args.first == "beauty" { ImageEditor.current?.view.toggleBeauty() }
            ImageEditor.current?.primary(nil, save: .replace); return 2.0
        case "pin-file":
            if let p = PinWindow.debugLast, let url = p.fileURL, let (img, _) = PinWindow.loadImage(url) {
                write(log, "[pin-file] file=\(img.width)x\(img.height) shown=\(p.currentImage.width)x\(p.currentImage.height) \(PinWindow.debugText)\n")
            } else { write(log, "[pin-file] none\n") }
            return 0.05
        case "pins":
            write(log, "[pins \(args.joined(separator: " "))] \(PinWindow.debugText)\n")
            return 0.05
        case "annot":
            let v = a.captureForDebug?.activeOverlay
            write(log, "[annot \(args.joined(separator: " "))] \(v?.annotator.debugText ?? "no overlay") editingText=\(v?.isEditingText ?? false) bar=\(a.captureForDebug?.actionBar?.debugText ?? "-")\n")
            return 0.05
        case "activate-self":
            // 模拟"QuickCap 自己是当前 app"（刚用过设置、截图架）时开截图
            NSApp.activate()
            return 0.4
        case "prefs":
            for kv in args {
                let p = kv.split(separator: "=")
                guard p.count == 2 else { continue }
                if p[0] == "copy" { AppSettings.shared.captureCopy = p[1] == "1" }
                if p[0] == "snap" { AppSettings.shared.snapToEdges = p[1] == "1" }
                if p[0] == "freeze" { AppSettings.shared.freezeScreen = p[1] == "1" }
                if p[0] == "timer" { AppSettings.shared.captureTimer = Int(p[1]) ?? 0 }
                if p[0] == "loupe" { AppSettings.shared.showMagnifier = p[1] == "1" }
                if p[0] == "pointer" { AppSettings.shared.showPointer = p[1] == "1" }
                if p[0] == "remember" { AppSettings.shared.rememberSelection = p[1] == "1" }
                if p[0] == "hdr" { AppSettings.shared.captureHDR = p[1] == "1" }
                if p[0] == "wallpaper" { AppSettings.shared.windowWallpaper = p[1] == "1" }
                if p[0] == "onex" { AppSettings.shared.scaleToStandard = p[1] == "1" }
                if p[0] == "srgb" { AppSettings.shared.convertToSRGB = p[1] == "1" }
                if p[0] == "icons" { AppSettings.shared.hideDesktopIcons = p[1] == "1" }
                if p[0] == "ax" { AppSettings.shared.snapToUIElements = p[1] == "1" }
                if p[0] == "format", let f = CaptureOutput.Format(rawValue: String(p[1])) { AppSettings.shared.captureFormat = f }
            }
            a.captureForDebug?.actionBar?.refresh()
            return 0.1
        case "outputs":
            let fm = FileManager.default
            let shelf = (try? fm.contentsOfDirectory(atPath: a.shelfFolder.path))?.filter { $0.hasSuffix(".png") || $0.hasSuffix(".heic") }.count ?? -1
            let pb = CaptureOutput.pasteboard.data(forType: .png).flatMap { NSBitmapImageRep(data: $0) }
                .map { "\($0.pixelsWide)x\($0.pixelsHigh)" } ?? "empty"
            let cards = a.debugShelf.debugView?.cards.count ?? -1
            write(log, "[outputs \(args.joined(separator: " "))] shelfFiles=\(shelf) pasteboard=\(pb) cards=\(cards) toast=\(CaptureToast.lastText ?? "none") last=\(a.lastDelivery)\n")
            return 0.05
        case "wait-signal":
            // 等 SIGUSR1（模拟 app 在后台时按快捷键）：先让别的 app 到前面，再发信号
            if !signalled, waited < 60 { waited += 0.1; repeatLine = true; return 0.1 }
            waited = 0
            signalled = false
            write(log, "[signal] front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") active=\(NSApp.isActive)\n")
            return 0.05
        case "abort-reason":
            write(log, "[abort-reason] session=\(a.captureForDebug == nil ? "closed" : "open") reason=\(a.lastAbortReason ?? "none")\n")
            return 0.05
        case "overlay-visible":
            let w = a.captureForDebug?.overlays.first
            write(log, "[overlay-visible] session=\(a.captureForDebug == nil ? "closed" : "open") onActiveSpace=\(w?.isOnActiveSpace ?? false) visible=\(w?.occlusionState.contains(.visible) ?? false) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") abort=\(a.lastAbortReason ?? "none")\n")
            return 0.05
        case "front":
            write(log, "[front] \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") active=\(NSApp.isActive)\n")
            return 0.05
        case "watch-events":
            // 记下截图期间发生的系统事件（换桌面、app 失去焦点、窗口被挡住……），看 Mission Control 时到底发生了什么
            let nc = NotificationCenter.default, wc = NSWorkspace.shared.notificationCenter
            for n in [NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification,
                      NSWindow.didChangeOcclusionStateNotification, NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification] {
                eventObservers.append(nc.addObserver(forName: n, object: nil, queue: .main) { note in
                    let occl = (note.object as? NSWindow).map { $0.occlusionState.contains(.visible) ? " visible" : " hidden" } ?? ""
                    let who = (note.object as? NSWindow).map { " \(type(of: $0))" } ?? ""
                    MainActor.assumeIsolated { events.append(note.name.rawValue.replacingOccurrences(of: "Notification", with: "") + who + occl) }
                })
            }
            for n in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
                eventObservers.append(wc.addObserver(forName: n, object: nil, queue: .main) { note in
                    let app = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.localizedName ?? ""
                    MainActor.assumeIsolated { events.append(note.name.rawValue.replacingOccurrences(of: "NSWorkspace", with: "") + " " + app) }
                })
            }
            return 0.05
        case "events":
            write(log, "[events \(args.joined(separator: " "))] " + (events.isEmpty ? "none" : events.joined(separator: " | ")) + "\n")
            events = []
            return 0.05
        case "until-closed":
            // 等截图界面关掉（最多 N 秒），用来等文字识别
            let limit = Double(args.first ?? "") ?? 15
            if a.captureForDebug != nil, waited < limit { waited += 0.1; repeatLine = true; return 0.1 }
            write(log, "[waited \(String(format: "%.1f", waited))s] warmUp=\(TextRecognizer.warmUpSeconds.map { String(format: "%.2fs", $0) } ?? "not done")\n")
            waited = 0
            return 0.05
        case "fake-text":
            // 冻结画面换成三行已知文字（基线 y = 640、580、520）
            a.captureForDebug?.overlays.first?.overlayView.debugUseFakeText([
                ("QuickCap reads this first line", 640), ("Second line 2026 OK", 580), ("截图识别中文测试", 520)])
            return 0.2
        case "cursor-probe":
            // 在一个点上持续发真的鼠标移动事件（走 NSApp），每 8ms 看一次当前光标，记下光标换了几次
            guard let pt = point(args.first) else { return 0.05 }
            let secs = Double(args.count > 1 ? args[1] : "") ?? 1.5
            let names: [(NSCursor, String)] = [(.arrow, "arrow"), (.crosshair, "crosshair"), (.openHand, "openHand"),
                                               (.closedHand, "closedHand"), (.iBeam, "iBeam"), (CaptureCursor.camera, "camera")]
            func name(_ c: NSCursor) -> String { names.first { $0.0 === c }?.1 ?? "other" }
            var seq: [String] = [], tick = 0
            let start = Date()
            let t = Timer(timeInterval: 0.008, repeats: true) { timer in
                MainActor.assumeIsolated {
                    if tick % 5 == 0 { mouse(.mouseMoved, pt, [], viaApp: true) }
                    tick += 1
                    let n = name(NSCursor.current)
                    if seq.last != n { seq.append(n) }
                    if Date().timeIntervalSince(start) > secs {
                        timer.invalidate()
                        write(log, "[cursor-probe \(args.first ?? "")] changes=\(seq.count - 1) sequence=\(seq.prefix(12).joined(separator: ">"))\n")
                    }
                }
            }
            RunLoop.main.add(t, forMode: .common)
            return secs + 0.2
        case "mouse-where":
            let m = NSEvent.mouseLocation, h = NSScreen.screens.first?.frame.height ?? 0
            write(log, "[mouse] screen=\(Int(m.x)),\(Int(m.y)) pixelTopLeft=\(Int(m.x * 2)),\(Int((h - m.y) * 2))\n")
            return 0.05
        case "pointer-diff":
            // 带指针的图和不带指针的图哪里不一样（应该只有鼠标指针那一小块）
            guard let v = a.captureForDebug?.overlays.first?.overlayView else { write(log, "[pointer-diff] no session\n"); return 0.05 }
            guard let o = v.output else { write(log, "[pointer-diff] no pointer image\n"); return 0.05 }
            let m = NSEvent.mouseLocation, s = v.window?.backingScaleFactor ?? 2
            let near = CGPoint(x: (m.x - (v.window?.frame.minX ?? 0)) * s, y: (v.bounds.height - (m.y - (v.window?.frame.minY ?? 0))) * s)
            write(log, "[pointer-diff] " + diff(v.frozen, o, near: near) + "\n")
            return 0.05
        case "hdr-probe":
            // 真的 HDR 截图里：整块屏幕和选区里最亮多少、最亮的点在哪里（pt，原点左下），现在屏幕的 HDR 余量
            guard let v = a.captureForDebug?.overlays.first?.overlayView, let h = v.frozenHDR else {
                write(log, "[hdr-probe] no hdr image " + (a.captureForDebug?.hdrDebug ?? "") + "\n"); return 0.05 }
            let scr = v.window?.screen
            let w = h.width, hh = h.height
            var buf = [Float](repeating: 0, count: w * hh * 4)
            let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            let ctx = CGContext(data: &buf, width: w, height: hh, bitsPerComponent: 32, bytesPerRow: w * 16,
                                space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, bitmapInfo: info)!
            ctx.draw(h, in: CGRect(x: 0, y: 0, width: w, height: hh))
            var m: Float = 0, mi = 0, over = 0
            for i in stride(from: 0, to: buf.count, by: 4) {
                let c = max(buf[i], buf[i+1], buf[i+2]); if c > m { m = c; mi = i / 4 }; if c > 1.1 { over += 1 }
            }
            let sc = CGFloat(w) / v.bounds.width
            let px = CGFloat(mi % w) / sc, py = v.bounds.height - CGFloat(mi / w) / sc
            write(log, "[hdr-probe] headroomNow=\(scr?.maximumExtendedDynamicRangeColorComponentValue ?? -1) screenMax=\(m) at=\(Int(px)),\(Int(py)) pixelsOver1.1=\(over) hdrCS=\(h.colorSpace?.name as String? ?? "-") headroomTag=\(h.contentHeadroom)\n")
            return 0.05
        case "windows":
            // 现在认得的窗口：名字、实际范围、圆角、量过没有
            guard let v = a.captureForDebug?.overlays.first?.overlayView else { return 0.05 }
            let list = v.windows.map { w in "\(w.label)[L\(w.layer) \(Int(w.rect.minX)),\(Int(w.rect.minY)) \(Int(w.rect.width))x\(Int(w.rect.height)) r=\(w.corner)\(w.verified ? "" : " unverified")]" }
            write(log, "[windows \(args.joined(separator: " "))] usable=\(ScreenWindows.usable(v.windows).count) all=\(v.windows.count): " + list.joined(separator: " ") + "\n")
            return 0.05
        case "hdr-sel":
            // 选区里 HDR 那张最亮的像素亮度、最大通道
            guard let v = a.captureForDebug?.overlays.first?.overlayView, let sel = v.selection else { return 0.05 }
            let st = v.frozenHDR.flatMap { CaptureOutput.crop($0, rect: sel, viewSize: v.bounds.size) }.map { CaptureOutput.hdrStats($0) }
            write(log, "[hdr-sel \(args.joined(separator: " "))] maxY=\(st?.maxY ?? -1) maxC=\(st?.maxC ?? -1) hdrAvailable=\(v.hdrAvailable) brighterThanWhite=\((st?.maxY ?? 0) > CaptureOutput.hdrWhiteTolerance)\n")
            return 0.05
        case "hdr-map":
            // 把 HDR 图里亮于 1.1 的地方涂成红色，其余灰掉，存成 PNG 看分布
            guard let h = a.captureForDebug?.overlays.first?.overlayView.frozenHDR else { return 0.05 }
            let k = 4, w = h.width / k, hh = h.height / k
            var buf = [Float](repeating: 0, count: w * hh * 4)
            let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            let ctx = CGContext(data: &buf, width: w, height: hh, bitsPerComponent: 32, bytesPerRow: w * 16,
                                space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, bitmapInfo: info)!
            ctx.draw(h, in: CGRect(x: 0, y: 0, width: w, height: hh))
            var out = [UInt8](repeating: 0, count: w * hh * 4)
            for i in 0..<(w * hh) {
                let c = max(buf[i*4], buf[i*4+1], buf[i*4+2])
                let g = UInt8(min(255, max(0, 255 * min(c, 1) * 0.5)))
                if c > 1.1 { out[i*4] = 255; out[i*4+1] = 0; out[i*4+2] = 0 } else { out[i*4] = g; out[i*4+1] = g; out[i*4+2] = g }
                out[i*4+3] = 255
            }
            let oc = CGContext(data: &out, width: w, height: hh, bitsPerComponent: 8, bytesPerRow: w * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            if let img = oc.makeImage(), let d = CaptureOutput.pngData(img, scale: 1) { try? d.write(to: URL(fileURLWithPath: "/tmp/hs-hdrmap.png")) }
            return 0.2
        case "countdown-bar":
            write(log, "[countdown-bar \(args.joined(separator: " "))] \(a.captureForDebug?.debugCountdownBar ?? "no session") overlayIgnoresMouse=\(a.captureForDebug?.overlays.first?.ignoresMouseEvents ?? false)\n")
            return 0.05
        case "access":
            write(log, "[access] preflight=\(CGPreflightScreenCaptureAccess()) state=\(ScreenAccess.state) asked=\(ScreenAccess.asked) editor=\(ImageEditor.current != nil) session=\(a.captureForDebug != nil) abort=\(a.lastAbortReason ?? "-")\n"); return 0.05
        case "scroll-start":
            a.captureForDebug?.startScrolling(); return 1.0
        case "cancel":
            a.captureForDebug?.cancel(); return 1.0
        case "hotkeys":
            write(log, "[hotkeys \(args.joined(separator: " "))] ids=\(HotKeyCenter.shared.debugIDs) escape=\(AppSettings.HotKeyID.captureEscape.rawValue) session=\(a.captureForDebug != nil)\n"); return 0.05
        case "accept":
            // accept opt+shift s：录快捷键时按这个组合收不收
            let code: UInt16 = ["s": 1, "a": 0, "c": 8, "v": 9, "z": 6, "1": 18][args.last ?? ""] ?? 1
            let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods(args.first), timestamp: 0, windowNumber: 0,
                                      context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)
            write(log, "[accept \(args.joined(separator: " "))] \(ev.flatMap(HotKey.init(event:))?.display ?? "rejected")\n"); return 0.05
        case "countdown-cancel":
            a.captureForDebug?.cancelCountdown()
            return 0.3
        case "fake-screen":
            // fake-screen 图片路径：冻结画面换成这张图（做宣传图用：真的截图界面盖在设计好的桌面上）
            if let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args.joined(separator: " ")) as CFURL, nil),
               let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                a.captureForDebug?.overlays.first?.overlayView.setSnapshot(img, output: nil, hdr: nil)
            }
            return 0.4
        case "snap-scene":
            a.captureForDebug?.overlays.first?.overlayView.debugUseSnapScene()
            return 0.4
        case "dump-lines":
            a.captureForDebug?.overlays.first?.overlayView.debugDumpContentLines(to: URL(fileURLWithPath: "/tmp/" + (args.first ?? "hs-lines.png")))
            return 0.1
        case "content-lines":
            let n = a.captureForDebug?.overlays.first?.overlayView.contentLineCount ?? (-1, -1)
            let ms = Int((a.captureForDebug?.overlays.first?.overlayView.contentEdgesSeconds ?? 0) * 1000)
            write(log, "[content-lines] vertical=\(n.0) horizontal=\(n.1) ms=\(ms)\n")
            return 0.05
        case "fake-hdr":
            // 冻结画面换成一张假的 HDR 图：x 400…800、y 300…600 这一块比白色亮 4 倍
            a.captureForDebug?.overlays.first?.overlayView.debugUseFakeHDR(bright: CGRect(x: 400, y: 300, width: 400, height: 300))
            return 0.2
        case "file-info":
            // 截图架里最新那张：格式、有没有增益图、按 HDR 解码最亮多少
            let fm = FileManager.default
            let files = ((try? fm.contentsOfDirectory(at: a.shelfFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { ["png", "heic"].contains($0.pathExtension) }
                .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            guard let f = files.first, let src = CGImageSourceCreateWithURL(f as CFURL, nil) else { write(log, "[file-info] none\n"); return 0.05 }
            let gmInfo = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap) as? [String: Any]
            let gm = gmInfo != nil
            // 文件里存的亮度范围：AlternateHeadroom 是 log2，2^它 就是最亮是白色的几倍（和当前屏幕无关）
            var stored = "-"
            if let md = gmInfo?[kCGImageAuxiliaryDataInfoMetadata as String] {
                let m = md as! CGImageMetadata
                for t in (CGImageMetadataCopyTags(m) as? [CGImageMetadataTag]) ?? [] where (CGImageMetadataTagCopyName(t) as String?) == "AlternateHeadroom" {
                    if let v = CGImageMetadataTagCopyValue(t) as? String, let d = Double(v) { stored = String(format: "%.3f", pow(2, d)) }
                    if let v = CGImageMetadataTagCopyValue(t) as? NSNumber { stored = String(format: "%.3f", pow(2, v.doubleValue)) }
                }
            }
            let plain = CGImageSourceCreateImageAtIndex(src, 0, nil)
            let hdr = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary)
            let pb = CaptureOutput.pasteboard.types?.map(\.rawValue).joined(separator: ",") ?? "-"
            write(log, "[file-info \(args.joined(separator: " "))] \(f.pathExtension) \(plain.map { "\($0.width)x\($0.height)" } ?? "?") gainMap=\(gm) storedPeak=\(stored)"
                + " normalMax=\(plain.map { CaptureOutput.peakBrightness($0) } ?? -1) hdrMax=\(hdr.map { CaptureOutput.peakBrightness($0) } ?? -1) pasteboardTypes=\(pb) path=\(f.path)\n")
            return 0.05
        case "dump-crop":
            // 把冻结画面里当前选区那块存成 PNG（和出来的文件比画质）
            if let v = a.captureForDebug?.overlays.first?.overlayView, let s = v.selection,
               let c = CaptureOutput.crop(v.frozen, rect: s, viewSize: v.bounds.size), let d = CaptureOutput.pngData(c, scale: 2) {
                try? d.write(to: URL(fileURLWithPath: "/tmp/" + (args.first ?? "hs-crop.png")))
            }
            return 0.1
        case "copy-newest":
            // 截图架里最新那张拷贝到 /tmp（给外面比画质）
            let fm = FileManager.default
            let newest = ((try? fm.contentsOfDirectory(at: a.shelfFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { ["png", "heic"].contains($0.pathExtension) }
                .max { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            if let n = newest {
                let dst = URL(fileURLWithPath: "/tmp/" + (args.first ?? "hs-newest") + "." + n.pathExtension)
                try? fm.removeItem(at: dst); try? fm.copyItem(at: n, to: dst)
            }
            return 0.05
        case "switch-shelf":
            let dir = URL(fileURLWithPath: args.first ?? "/tmp/hs-shelf-b", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            a.debugSwitchShelf(to: dir)
            return 1.0
        case "shelf-scroll":
            // 打开截图架，像触控板一样连续滑 2 秒（每 8ms 一下），量每帧多久
            guard let v = a.debugShelf.debugView else { return 0.05 }
            a.debugShelf.show()
            let per = Double(args.first ?? "") ?? 9
            v.debugTickMs = []; v.debugFrameGaps = []; v.debugGrayMax = 0; v.debugMaterializeMax = 0
            var n = 0
            let t = Timer(timeInterval: 0.008, repeats: true) { timer in
                MainActor.assumeIsolated {
                    v.trackScroll(by: CGFloat(n < 125 ? per : -per))
                    n += 1
                    if n >= 250 { timer.invalidate() }
                }
            }
            RunLoop.main.add(t, forMode: .common)
            return 2.6
        case "shelf-perf":
            guard let v = a.debugShelf.debugView else { return 0.05 }
            let ms = v.debugTickMs.sorted(), gaps = v.debugFrameGaps.sorted()
            func p(_ a: [Double], _ q: Double) -> String { a.isEmpty ? "-" : String(format: "%.1f", a[min(a.count - 1, Int(Double(a.count) * q))]) }
            let long = gaps.filter { $0 > 12 }.count
            let w = v.bounds.width
            let onScreen = v.cards.filter { $0.x > 0 && $0.x < w }
            let gray = onScreen.filter { $0.thumbnail == nil }.count
            write(log, "[shelf-perf \(args.joined(separator: " "))] ticks=\(ms.count) tick p50=\(p(ms, 0.5)) p90=\(p(ms, 0.9)) p99=\(p(ms, 0.99)) max=\(p(ms, 1)) | gaps p50=\(p(gaps, 0.5)) p90=\(p(gaps, 0.9)) max=\(p(gaps, 1)) over12ms=\(long) cards=\(v.cards.count) onScreen=\(onScreen.count) grayNow=\(gray) grayDuring=\(v.debugGrayMax) materializeMax=\(String(format: "%.1f", v.debugMaterializeMax))\n")
            return 0.05
        case "shelf-state":
            let cards = a.debugShelf.debugView?.cards.count ?? -1
            let files = (try? FileManager.default.contentsOfDirectory(atPath: a.shelfFolder.path))?.filter { !$0.hasPrefix(".") }.count ?? -1
            write(log, "[shelf-state \(args.joined(separator: " "))] folder=\(a.shelfFolder.lastPathComponent) files=\(files) cards=\(cards)\n")
            return 0.05
        case "drag-all":
            // 截图架里每张都转一次拖出去用的 PNG，看临时文件夹最多留几张
            let fm = FileManager.default
            let all = ((try? fm.contentsOfDirectory(at: a.shelfFolder, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "heic" }
            for u in all { _ = ShelfDragWriter.pngFile(for: u) }
            let dir = fm.temporaryDirectory.appendingPathComponent("QuickCap Drag")
            write(log, "[drag-all] converted=\(all.count) kept=\((try? fm.contentsOfDirectory(atPath: dir.path))?.count ?? -1)\n")
            return 0.1
        case "drag-file":
            // 截图架里最新那张拖出去时给的文件是什么
            let fm = FileManager.default
            let newest = ((try? fm.contentsOfDirectory(at: a.shelfFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { ["png", "heic"].contains($0.pathExtension) }
                .max { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            guard let src = newest else { write(log, "[drag-file] none\n"); return 0.05 }
            let pb = NSPasteboard(name: NSPasteboard.Name("QuickCap.debug.drag"))
            pb.clearContents()
            pb.writeObjects([ShelfDragWriter(url: src)])
            let fileURL = pb.readObjects(forClasses: [NSURL.self])?.first as? URL
            let img = fileURL.flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            let png = pb.data(forType: .png).flatMap { NSBitmapImageRep(data: $0) }
            write(log, "[drag-file] source=\(src.pathExtension) dragged=\(fileURL?.lastPathComponent ?? "nil") \(img.map { "\($0.width)x\($0.height)" } ?? "?")"
                + " sameName=\(fileURL?.deletingPathExtension().lastPathComponent == src.deletingPathExtension().lastPathComponent) pngData=\(png.map { "\($0.pixelsWide)x\($0.pixelsHigh)" } ?? "nil")\n")
            return 0.1
        case "dump-frozen":
            if let img = a.captureForDebug?.overlays.first?.overlayView.frozen,
               let data = CaptureOutput.pngData(img, scale: 2) {
                try? data.write(to: URL(fileURLWithPath: "/tmp/" + (args.first ?? "hs-frozen.png")))
            }
            return 0.2
        case "fake-codes":
            // 冻结画面换成二维码：一个链接（左边，x 300…500），一个 Wi‑Fi（右边，x 800…1000），y 400…600
            a.captureForDebug?.overlays.first?.overlayView.debugUseFakeCodes([
                (args.first ?? "https://docs.google.com/forms/d/e/1FAIpQLSf3kq9vZ0x7Yw2mPq/viewform?usp=sf_link", CGPoint(x: 300, y: 400), 200),
                (args.count > 1 ? args[1] : "WIFI:T:WPA;S:Cafe Lumen Guest;P:lumen-2026-latte;;", CGPoint(x: 800, y: 400), 200)])
            return 0.2
        case "scan":
            write(log, "[scan \(args.joined(separator: " "))] \(a.captureForDebug?.debugScan ?? "no session") pasteboard=\((CaptureOutput.pasteboard.string(forType: .string) ?? "nil").prefix(60)) toast=\(CaptureToast.lastText ?? "none")\n")
            return 0.05
        case "flash":
            a.captureForDebug?.overlays.first?.overlayView.flashAndHideChrome()
            return 0.05
        case "scan-demo":
            // scan-demo [x,y,w,h]：在这块地方放扫描的光（不给就用默认位置）
            let n = (args.first ?? "").split(separator: ",").compactMap { Double($0) }
            let r = n.count == 4 ? CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) : CGRect(x: 180, y: 505, width: 620, height: 185)
            a.captureForDebug?.overlays.first?.overlayView.debugScanDemo(r)
            return 0.1
        case "ocr":
            let pb = CaptureOutput.pasteboard.string(forType: .string) ?? "nil"
            func esc(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: "⏎") }
            write(log, "[ocr \(args.joined(separator: " "))] recognize=\(TextRecognizer.lastRun ?? "-") chars=\(pb.count) pasteboard=\(esc(pb)) toast=\(CaptureToast.lastText ?? "none") session=\(a.captureForDebug == nil ? "closed" : "open")\n")
            return 0.05
        case "reset-outputs":
            let fm = FileManager.default
            for dir in [a.shelfFolder] {
                for f in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".png") || f.hasSuffix(".heic") {
                    try? fm.removeItem(at: dir.appendingPathComponent(f))
                }
            }
            CaptureOutput.pasteboard.clearContents()
            return 0.1
        case "wait":
            return Double(args.first ?? "") ?? 0.3
        case "log":
            write(log, "[\(args.joined(separator: " "))] " + (a.captureForDebug?.debugState ?? "no session") + "\n")
            return 0.05
        case "headroom":
            // 屏幕现在的 HDR 余量（系统打开 HDR 时是慢慢升上去的）
            let scr = NSScreen.main
            write(log, "[headroom \(args.first ?? "")] now=\(scr?.maximumExtendedDynamicRangeColorComponentValue ?? -1) potential=\(scr?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? -1)\n")
            return 0.0
        case "snap-hdr":
            // snap-hdr 文件名 x,y,w,h（pt，左下原点）：截一张 HDR 的，并量这块里最亮的颜色
            let id = (NSScreen.main ?? NSScreen.screens[0]).displayID ?? CGMainDisplayID()
            let url = URL(fileURLWithPath: "/tmp/" + (args.first ?? "hs-hdr.heic"))
            let n = args.count > 1 ? args[1].split(separator: ",").compactMap { Double($0) } : []
            let probe = n.count == 4 ? CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) : nil
            let name = args.first ?? ""
            Task.detached { let r = await CaptureDebug.snapshotHDR(display: id, to: url, probe: probe)
                await MainActor.run { write(log, "[snap-hdr \(name)] \(r)\n") } }
            return 1.2
        case "snap":
            let id = (NSScreen.main ?? NSScreen.screens[0]).displayID ?? CGMainDisplayID()
            let url = URL(fileURLWithPath: "/tmp/" + (args.first ?? "hs-test.png"))
            Task.detached { await CaptureDebug.snapshot(display: id, to: url) }
            return 0.8
        case "move":
            if let p = point(args.first) { mouse(.mouseMoved, p, []) }
            return 0.15
        case "click":
            if let p = point(args.first) {
                let m = mods(args.count > 1 ? args[1] : nil)
                mouse(.leftMouseDown, p, m); mouse(.leftMouseUp, p, m)
            }
            return 0.3
        case "drag":
            guard args.count >= 2, let p0 = point(args[0]) else { return 0.1 }
            let m = mods(args.count > 2 ? args[2] : nil)
            mouse(.leftMouseDown, p0, m)
            guard let p1 = point(args[1], base: p0) else { return 0.1 }
            for k in 1...14 {
                let t = CGFloat(k) / 14
                mouse(.leftMouseDragged, CGPoint(x: p0.x + (p1.x - p0.x) * t, y: p0.y + (p1.y - p0.y) * t), m)
            }
            mouse(.leftMouseUp, p1, m)
            return 0.35
        case "down":
            if let p = point(args.first) { lastDown = p; mouse(.leftMouseDown, p, []) }
            return 0.1
        case "to":
            if let p = point(args.first, base: lastDown) {
                let m = mods(args.count > 1 ? args[1] : nil)
                for k in 1...10 {
                    let t = CGFloat(k) / 10
                    mouse(.leftMouseDragged, CGPoint(x: lastDown.x + (p.x - lastDown.x) * t, y: lastDown.y + (p.y - lastDown.y) * t), m)
                }
                lastDown = p
            }
            return 0.25
        case "up":
            mouse(.leftMouseUp, point(args.first) ?? lastDown, [])
            return 0.3
        case "keyinfo":
            let k = NSApp.keyWindow
            write(log, "[keyinfo] key=\(k.map { String(describing: type(of: $0)) } ?? "nil") level=\(k?.level.rawValue ?? -1) overlayKey=\(a.captureForDebug?.overlays.contains { $0.isKeyWindow } ?? false) windows=\(NSApp.windows.filter(\.isVisible).map { "\(type(of: $0))@\($0.level.rawValue)" }.joined(separator: ","))\n")
            return 0.05
        case "key":
            key(args.first ?? "", mods(args.count > 1 ? args[1] : nil))
            return 0.25
        case "type":
            for ch in args.joined(separator: " ") { key(String(ch), []) }
            return 0.3
        default:
            write(log, "unknown: \(line)\n")
            return 0.05
        }
    }

    private static var lastDown = CGPoint.zero
    private static var eventObservers: [Any] = []
    private static var events: [String] = []

    /// 两张图不同的像素有多少、在哪里（像素坐标，原点左上）
    private static func diff(_ a: CGImage, _ b: CGImage, near: CGPoint? = nil) -> String {
        guard a.width == b.width, a.height == b.height else { return "size differs \(a.width)x\(a.height) vs \(b.width)x\(b.height)" }
        func rgba(_ img: CGImage) -> [UInt8] {
            var buf = [UInt8](repeating: 0, count: img.width * img.height * 4)
            let ctx = CGContext(data: &buf, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            return buf
        }
        let x = rgba(a), y = rgba(b)
        var n = 0, minX = Int.max, minY = Int.max, maxX = -1, maxY = -1, close = 0
        for i in stride(from: 0, to: x.count, by: 4) where abs(Int(x[i]) - Int(y[i])) + abs(Int(x[i+1]) - Int(y[i+1])) + abs(Int(x[i+2]) - Int(y[i+2])) > 24 {
            n += 1
            let p = i / 4, px = p % a.width, py = p / a.width
            minX = min(minX, px); maxX = max(maxX, px); minY = min(minY, py); maxY = max(maxY, py)
            if let near, abs(CGFloat(px) - near.x) < 80, abs(CGFloat(py) - near.y) < 80 { close += 1 }
        }
        return n == 0 ? "identical" : "differs=\(n)px nearMouse=\(close)px box=\(minX),\(minY) \(maxX - minX + 1)x\(maxY - minY + 1)"
    }
    /// until-closed：这一行再执行一次
    private static var repeatLine = false
    private static var waited: Double = 0
    static var signalled = false
    private static var signalSource: DispatchSourceSignal?

    /// 收到 SIGUSR1 时把 signalled 设成 true（wait-signal 用）
    static func listenForSignal() {
        signal(SIGUSR1, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        src.setEventHandler { MainActor.assumeIsolated { signalled = true } }
        src.resume()
        signalSource = src
    }

    /// "x,y"、"名字"、"名字@dx,dy"、"+dx,+dy"（相对 base）
    private static func point(_ s: String?, base: CGPoint? = nil) -> CGPoint? {
        guard let s else { return nil }
        var name = s, off = CGPoint.zero
        if let at = s.firstIndex(of: "@") {
            name = String(s[..<at])
            let n = s[s.index(after: at)...].split(separator: ",").compactMap { Double($0) }
            if n.count == 2 { off = CGPoint(x: n[0], y: n[1]) }
        }
        let nums = name.split(separator: ",")
        if nums.count == 2, let x = Double(nums[0]), let y = Double(nums[1]) {
            if name.hasPrefix("+") || name.hasPrefix("-"), let base { return CGPoint(x: base.x + x, y: base.y + y) }
            return CGPoint(x: x + off.x, y: y + off.y)
        }
        guard let p = view?.debugPoint(name) else { return nil }
        return CGPoint(x: p.x + off.x, y: p.y + off.y)
    }

    private static func mouse(_ type: NSEvent.EventType, _ p: CGPoint, _ m: NSEvent.ModifierFlags, viaApp: Bool = false) {
        guard let w = ImageEditor.current.map({ $0.view.window }) ?? view?.window else { return }
        guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: m,
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                         context: nil, eventNumber: 0, clickCount: 1,
                                         pressure: type == .leftMouseUp || type == .mouseMoved ? 0 : 1) else { return }
        // 鼠标移动事件不一定会送到跟踪区域，直接交给截图界面
        if type == .mouseMoved && !viaApp { (ImageEditor.current?.view as NSView?)?.mouseMoved(with: e) ?? view?.mouseMoved(with: e); return }
        NSApp.postEvent(e, atStart: false)
    }

    private static let keyCodes: [String: UInt16] = [
        "esc": 53, "return": 36, "tab": 48, "delete": 51, "space": 49, "left": 123, "right": 124, "down": 125, "up": 126,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
    ]

    private static func key(_ name: String, _ m: NSEvent.ModifierFlags) {
        guard let code = keyCodes[name.lowercased()], let w = NSApp.keyWindow ?? view?.window else { return }
        let chars: String
        switch name {
        case "esc": chars = "\u{1b}"
        case "return": chars = "\r"
        case "tab": chars = "\t"
        case "delete": chars = "\u{7f}"
        case "space": chars = " "
        case "left": chars = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case "right": chars = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case "down": chars = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case "up": chars = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        default: chars = name
        }
        var flags = m
        if code >= 123 && code <= 126 { flags.formUnion([.function, .numericPad]) }
        for t in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: flags,
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                        context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                        isARepeat: false, keyCode: code) {
                NSApp.postEvent(e, atStart: false)
            }
        }
    }
}
