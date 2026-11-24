import AppKit

/// 开发时用的启动参数：
///   --demo[=张数]       启动后依次挂几张示例图（默认 4 张）
///   --snapshot=路径     几秒后把悬挂架渲染成 PNG（不需要屏幕录制权限）
///   --quit-after=秒     到时间自动退出
///   --capture           打开截图界面；加 --capture-options 再打开 Options 菜单
///   --capture-snapshot=路径  截图界面出现后，把整块主屏幕（包括截图界面本身）存成 PNG
///   --hover=序号[,按钮]  快照前让第几张卡片（从 0 开始）处于悬停状态，按钮是工具栏第几个按钮（显示提示）
///   --trash=秒,序号     到时间对第几张（按排列位置）点删除按钮
///   --undo=秒           到时间点撤销条
///   --copy=秒,序号      到时间复制第几张，打印剪贴板里的类型
///   --reduce-motion     这次运行当成打开了"减少动态效果"
///   --dark              这次运行用深色外观
///   --ocr=路径          识别图片里的文字，打印到标准输出后退出
///   --trace-swing       每 0.05 秒打印上下偏移、透明度和各卡片摆角（度），调手感用
///   --sweep=秒          到时间模拟鼠标以 600pt/秒 横扫第 0 张卡片，再快速来回 3 次
///   --replay-reveal=秒  到时间收起悬挂架，0.8 秒后再展开，用来看展开时的摆动
///   --swipe=秒[,距离]   到时间模拟触控板横着滑，距离是手指移动的 pt（默认 600，正数向右、负数向左），带惯性
///   --side=left|right   这次运行从哪边出来（不写入设置）
///   --shelf-folder=路径 这次运行悬挂架看哪个文件夹（默认空的临时文件夹）
///   --scroll=秒,距离    到时间把整排滑到某个位置
///   --dump-shelf=秒     到时间打印整排的状态
///   --dump-rope=秒,...  到这些时间打印绳子露出来多少（不会展开悬挂架）
///   --pin=秒,序号...    到时间把第几张置顶
///   --trace-timeline    每帧打印日期牌的状态
///   --day-menu=秒[,第几项]  到时间打印右键的日期列表，给了第几项就选它
///   --demo-at=秒,...    到这些时间各挂一张示例图
///   --hide-at=秒,... / --show-at=秒,...  到时间收起 / 展开
///   --film=开始,时长,帧数[,高度] --film-out=路径  把这段动画按时间拼成一张竖长图
/// 带任何一个调试参数时，不读写真正的悬挂架和设置。
@MainActor
enum DebugOptions {
    /// 正式版（release 编译）里调试参数一律不认，不会因为带了参数就换到临时文件夹、不存设置
    nonisolated static var isDebugRun: Bool {
        #if DEBUG
        CommandLine.arguments.dropFirst().contains { $0.hasPrefix("--") }
        #else
        false
        #endif
    }
    /// 调试运行时悬挂架看的文件夹
    static var debugShelfFolder: URL?
    static var signalSource: DispatchSourceSignal?

    static func configureBeforeLaunch() {
        guard isDebugRun else { return }
        ShelfStore.url = nil
        AppSettings.shared.persist = false
        CaptureOutput.pasteboard = NSPasteboard(name: NSPasteboard.Name("QuickCap.debug"))
        let args = CommandLine.arguments
        // 调试运行默认看一个空的临时文件夹，不动真正的截图文件夹
        if let s = args.first(where: { $0.hasPrefix("--shelf-folder=") }) {
            debugShelfFolder = URL(fileURLWithPath: String(s.dropFirst(15)))
        } else {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("quickcap-debug-shelf", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            debugShelfFolder = dir
        }
        if let s = args.first(where: { $0.hasPrefix("--side=") }), let side = ShelfSide(rawValue: String(s.dropFirst(7))) {
            AppSettings.shared.side = side
        }
    }

    static func apply(to app: AppDelegate) {
        guard isDebugRun else { return }
        let args = CommandLine.arguments
        func value(_ name: String) -> String? {
            args.first { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) }
        }
        // --format=heic|png|jpeg：这次运行存成哪种格式
        if let v = value("format"), let f = CaptureOutput.Format(rawValue: v) { AppSettings.shared.captureFormat = f }

        let demoCount = args.contains("--demo") ? 4 : Int(value("demo") ?? "") ?? 0
        if demoCount > 0 {
            for i in 0..<demoCount {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 + Double(i) * 0.9) { app.hangSample() }
            }
        }
        if args.contains("--reduce-motion") { ReduceMotion.forced = true }
        if args.contains("--dark") { NSApplication.shared.appearance = NSAppearance(named: .darkAqua) }
        if let s = value("hover") {
            let p = s.split(separator: ",").compactMap { Int($0) }
            if let i = p.first {
                let delay = (Double(value("snapshot-delay") ?? "") ?? 6) - 1.2
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    app.debugShelf.debugHover(index: i)
                    if p.count > 1, ShelfAction.toolbarActions.indices.contains(p[1]),
                       let card = app.debugShelf.debugView?.hovered {
                        card.hoveredAction = ShelfAction.toolbarActions[p[1]]
                        app.debugShelf.debugView?.wake()
                    }
                }
            }
        }
        func card(at slot: Int) -> CardNode? { app.debugShelf.debugView?.cards.first { $0.index == slot } }
        if let s = value("trash") {
            let p = s.split(separator: ",").compactMap { Double($0) }
            if p.count == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + p[0]) {
                    guard let c = card(at: Int(p[1])) else { print("trash: no card \(Int(p[1]))"); return }
                    print("trash: \(c.item.url.lastPathComponent) owns=\(c.ownsFile)")
                    app.perform(.trash, on: c.item)
                }
            }
        }
        if let s = value("undo"), let t = Double(s) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                guard let v = app.debugShelf.debugView else { return }
                print("undo: pill visible=\(v.undoPill.isVisible)")
                v.undoPill.fire()
            }
        }
        if let s = value("copy") {
            let p = s.split(separator: ",").compactMap { Double($0) }
            if p.count == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + p[0]) {
                    guard let c = card(at: Int(p[1])) else { return }
                    app.perform(.copy, on: c.item)
                    let types = NSPasteboard.general.pasteboardItems?.first?.types.map(\.rawValue) ?? []
                    print("copy: items=\(NSPasteboard.general.pasteboardItems?.count ?? 0) types=\(types)")
                }
            }
        }
        if let path = value("snapshot") {
            let delay = Double(value("snapshot-delay") ?? "") ?? 6
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                app.debugShelf.writeSnapshot(to: URL(fileURLWithPath: path))
            }
        }
        if let path = value("ocr") {
            TextRecognizer.recognize(url: URL(fileURLWithPath: path)) { result in
                switch result {
                case .success(let text): print(text)
                case .failure(let error): print("OCR error: \(error)")
                }
                NSApp.terminate(nil)
            }
        }
        if args.contains("--trace-swing") {
            let start = Date()
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard let view = app.debugShelf.debugView else { return }
                    let angles = view.cards.prefix(6).map { String(format: "%6.1f", $0.angle * 180 / .pi) }
                        + [String(format: " scroll=%6.0f/%4.0f", view.scroll.value, view.maxScroll)]
                    print(String(format: "t=%5.2f reveal=%.2f sag=%5.1f ", Date().timeIntervalSince(start), view.debugReveal, view.debugRopeSag)
                          + angles.joined(separator: " "))
                }
            }
        }
        // --trace-motion=开始秒,时长：按真实时间每 1/30 秒打印每张卡片的状态（阶段、挂点或位置、展开进度、角度、缩放）
        if let s = value("trace-motion") {
            let p = s.split(separator: ",").compactMap { Double($0) }
            if p.count == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + p[0]) {
                    let t0 = CACurrentMediaTime()
                    let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { timer in
                        MainActor.assumeIsolated {
                            let t = CACurrentMediaTime() - t0
                            guard t <= p[1], let v = app.debugShelf.debugView else { timer.invalidate(); return }
                            let cards = v.cards.sorted { $0.index < $1.index }.map { c -> String in
                                let pos = c.phase == .hanging ? c.hang : c.position
                                let ph = c.phase == .flying ? "F" : c.phase == .falling ? "X" : "H"
                                return String(format: "%d%@(%.0f,%.0f r%.2f a%.0f s%.2f)", c.index, ph, pos.x, pos.y,
                                              c.reveal.value, c.angle * 180 / .pi, c.scale)
                            }
                            print(String(format: "t=%.2f ticks=%d ", t, v.debugTickCount) + cards.joined(separator: " "))
                        }
                    }
                    RunLoop.main.add(timer, forMode: .common)
                }
            }
        }
        if let s = value("sweep"), let t = Double(s) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { app.debugShelf.debugSweep() }
        }
        if let s = value("replay-reveal"), let t = Double(s) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { app.debugShelf.hide() }
            DispatchQueue.main.asyncAfter(deadline: .now() + t + 0.8) { app.debugShelf.show() }
        }
        if let s = value("swipe") {
            let parts = s.split(separator: ",").compactMap { Double($0) }
            if let t = parts.first {
                let distance = CGFloat(parts.count > 1 ? parts[1] : 600)
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { app.debugShelf.debugSwipe(distance) }
            }
        }
        // --shelf-folder=路径：这次运行看哪个文件夹（默认一个空的临时文件夹，不碰真正的截图）
        // --scroll=秒,距离：到时间把整排滑到某个位置（内容坐标）
        if let s = value("scroll") {
            let p = s.split(separator: ",").compactMap { Double($0) }
            if p.count == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + p[0]) {
                    app.shelfForDebug?.debugScroll(to: CGFloat(p[1]))
                }
            }
        }
        if let s = value("day-menu") {
            let p = s.split(separator: ",").compactMap { Double($0) }
            if let t = p.first {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                    guard let view = app.debugShelf.debugView else { return }
                    guard let menu = view.dayMenu() else { print("day menu: none"); return }
                    for (i, item) in menu.items.enumerated() {
                        print("day menu \(i): \(item.title)\(item.state == .on ? " ✓" : "")")
                    }
                    if p.count > 1, menu.items.indices.contains(Int(p[1])) {
                        let item = menu.items[Int(p[1])]
                        _ = item.target?.perform(item.action, with: item)
                        print("picked \(item.title) → scroll target \(view.scroll.target)")
                    }
                }
            }
        }
        if args.contains("--trace-timeline") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                app.shelfForDebug?.debugView?.debugTraceTimeline = true
            }
        }
        // --pin=秒,序号[,序号...]：到时间把第几张置顶（从 0 开始，按置顶前的位置）
        if let s = value("pin") {
            let p = s.split(separator: ",").compactMap { Double($0) }
            if p.count >= 2 {
                for (n, idx) in p.dropFirst().enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + p[0] + Double(n) * 0.5) {
                        app.shelfForDebug?.debugPin(index: Int(idx))
                    }
                }
            }
        }
        // --watch-count=秒：每 0.5 秒打印一次总张数，持续这么多秒（看文件夹变化有没有被捡到）
        if let s = value("watch-count"), let dur = Double(s) {
            for n in 0..<Int(dur / 0.5) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + Double(n) * 0.5) {
                    guard let v = app.shelfForDebug?.debugView else { return }
                    print(String(format: "t=%.1f count=%d days=%d", 0.5 + Double(n) * 0.5, v.count, v.dayGroups.count))
                }
            }
        }
        // --dump-shelf=秒：打印整排的状态（有几张、分几天、刻度条位置、卡片节点数）
        if let s = value("dump-rope") {
            for t in s.split(separator: ",").compactMap({ Double($0) }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { app.debugShelf.debugView?.debugDumpRope() }
            }
        }
        if let s = value("dump-shelf"), let t = Double(s) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { app.shelfForDebug?.debugDump() }
        }
        // --demo-at=秒,秒...：到这些时间各挂一张示例图（看收起时、展开时挂上去的动画）
        if let s = value("demo-at") {
            for t in s.split(separator: ",").compactMap({ Double($0) }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { app.hangSample() }
            }
        }
        if let s = value("hide-at") {
            for t in s.split(separator: ",").compactMap({ Double($0) }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { app.debugShelf.hide() }
            }
        }
        if let s = value("show-at") {
            for t in s.split(separator: ",").compactMap({ Double($0) }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { app.debugShelf.show() }
            }
        }
        // --film=开始秒,时长,帧数 --film-out=路径：把这段时间的画面按时间顺序拼成一张竖长图
        if let s = value("film"), let out = value("film-out") {
            let p = s.split(separator: ",").compactMap { Double($0) }
            if p.count >= 2 {
                let frames = p.count > 2 ? Int(p[2]) : 12
                let band = p.count > 3 ? CGFloat(p[3]) : 250
                DispatchQueue.main.asyncAfter(deadline: .now() + p[0]) {
                    app.debugShelf.film(duration: p[1], frames: frames, band: band, to: URL(fileURLWithPath: out))
                }
            }
        }
        // --capture-on-signal：收到 SIGUSR1 才打开截图界面（模拟 app 在后台时按快捷键），1.5 秒后截屏并写状态
        if args.contains("--capture-on-signal") {
            signal(SIGUSR1, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
            src.setEventHandler {
                MainActor.assumeIsolated {
                    let before = NSApp.isActive
                    app.startCapture()
                    let out = value("capture-snapshot")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        let key = NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "nil"
                        let line = "activeBefore=\(before) activeNow=\(NSApp.isActive) keyWindow=\(key)\n"
                        try? line.write(toFile: "/tmp/hs-diag.txt", atomically: true, encoding: .utf8)
                        if let out {
                            let id = (NSScreen.main ?? NSScreen.screens[0]).displayID ?? CGMainDisplayID()
                            Task.detached { await CaptureDebug.snapshot(display: id, to: URL(fileURLWithPath: out)) }
                        }
                    }
                }
            }
            src.resume()
            DebugOptions.signalSource = src
        }
        // --capture-test=脚本：按脚本模拟鼠标键盘操作截图界面，每步把状态写进日志（见 CaptureTest.swift）
        if let script = value("capture-test") {
            CaptureTest.run(script: script, log: value("capture-test-log") ?? "/tmp/hs-test.log", app: app)
        }
        // 截图界面：--capture 打开；--capture-options 再打开 Options 菜单；--capture-snapshot=路径 截下整块主屏幕
        if !args.contains("--capture-on-signal"), value("capture-test") == nil,
           args.contains("--capture") || value("capture-snapshot") != nil {
            let start = Double(value("capture-delay") ?? "") ?? 0.8
            DispatchQueue.main.asyncAfter(deadline: .now() + start) {
                app.startCapture()
                print("capture started: active=\(NSApp.isActive)")
            }
            // --capture-drag=x0,y0,x1,y1[,hold]：打开后模拟拖一个框（主屏幕坐标，原点左下），hold 表示不松手
            if let s = value("capture-drag") {
                let p = s.split(separator: ",")
                let n = p.compactMap { Double($0) }.map { CGFloat($0) }
                if n.count >= 4 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                        guard let v = app.captureForDebug?.overlays.first?.overlayView else { return }
                        v.debugDrag(from: CGPoint(x: n[0], y: n[1]), to: CGPoint(x: n[2], y: n[3]), release: !p.contains("hold"))
                        let r = v.selection.map { "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width)),\(Int($0.height))" } ?? "none"
                        try? r.write(toFile: "/tmp/hs-selection.txt", atomically: true, encoding: .utf8)
                    }
                }
            }
            if args.contains("--capture-options") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    if let b = app.captureForDebug?.bar?.optionsButton { b.onClick?(b) }
                }
            }
            if let out = value("capture-snapshot") {
                let delay = Double(value("snapshot-delay") ?? "") ?? 2.6
                // 菜单打开时主线程在跑菜单自己的循环，用 common 模式的计时器才能按时触发
                let id = (NSScreen.main ?? NSScreen.screens[0]).displayID ?? CGMainDisplayID()
                let t = Timer(timeInterval: delay, repeats: false) { _ in
                    Task.detached { await CaptureDebug.snapshot(display: id, to: URL(fileURLWithPath: out)) }
                }
                RunLoop.main.add(t, forMode: .common)
            }
        }
        // --welcome[=hello|access|ready]：打开欢迎窗口；--welcome-access=off|asked|reopen|on 假装权限状态；
        // --welcome-time=秒 演示动画停在那一刻。打开后打印窗口号，方便用 screencapture -l 截下来
        if args.contains("--welcome") || value("welcome") != nil {
            let access: (ScreenAccess.State, Bool)? = switch value("welcome-access") {
            case "off": (.off, false)
            case "asked": (.off, true)
            case "reopen": (.needsReopen, true)
            case "on": (.on, true)
            default: nil
            }
            if let access { ScreenAccess.forced = access.0 }
            if let s = value("welcome-time"), let t = Double(s) { WelcomeDemo.debugTime = t }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                app.showWelcome(page: value("welcome").flatMap(WelcomeModel.Page.init(rawValue:)))
                if let access { app.welcomeForDebug.debugModel?.debugSet(access: access.0, asked: access.1) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    print("welcome window=\(app.welcomeForDebug.debugWindow?.windowNumber ?? 0)")
                    fflush(stdout)
                }
            }
        }
        // --status-menu：点开菜单栏图标的菜单（截图看样子用）
        if args.contains("--status-menu") {
            // 图标可能被刘海挡住，直接在屏幕中间弹出同一个菜单
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard let m = app.statusItemForDebug?.menu else { return }
                m.delegate?.menuWillOpen?(m)
                let f = NSScreen.main?.frame ?? .zero
                m.popUp(positioning: nil, at: CGPoint(x: f.midX - 120, y: f.midY + 160), in: nil)
            }
        }
        // --settings=general|capture|shelf|scan：打开设置窗口的那一页，打印窗口号
        if let v = value("settings") {
            let tab: SettingsWindowController.Tab = ["general": .general, "capture": .capture, "shortcuts": .shortcuts, "shelf": .shelf, "scan": .scan][v] ?? .general
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                app.settingsForDebug.show(tab: tab)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    print("settings window=\(app.settingsForDebug.debugWindowNumber ?? 0)")
                    fflush(stdout)
                }
            }
        }
        // --settings-switch=from,to：开设置在 from 页，1 秒后换到 to 页，每 8ms 打一行窗口的上边和高度
        if let v = value("settings-switch") {
            let p = v.split(separator: ",").compactMap { Int($0) }
            if p.count == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    app.settingsForDebug.show(tab: SettingsWindowController.Tab(rawValue: p[0]))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        let start = CACurrentMediaTime()
                        app.settingsForDebug.debugSelect(p[1])
                        let t = Timer(timeInterval: 0.008, repeats: true) { timer in
                            MainActor.assumeIsolated {
                                let f = app.settingsForDebug.debugFrame
                                print(String(format: "t=%.3f top=%.1f h=%.1f", CACurrentMediaTime() - start, f.maxY, f.height))
                                fflush(stdout)
                                if CACurrentMediaTime() - start > 0.4 { timer.invalidate() }
                            }
                        }
                        RunLoop.main.add(t, forMode: .common)
                    }
                }
            }
        }
        if let s = value("quit-after"), let t = Double(s) {
            let timer = Timer(timeInterval: t, repeats: false) { _ in MainActor.assumeIsolated { NSApp.terminate(nil) } }
            RunLoop.main.add(timer, forMode: .common)
        }
    }
}

extension ShelfController {
    func debugHover(index: Int) {
        guard let view = debugView, view.cards.indices.contains(index) else { return }
        let card = view.cards[index]
        view.clearHover()
        card.hoverTarget = 1
        view.hovered = card
        view.hoverLocked = true
        view.wake()
    }

    /// 模拟触控板横着滑：fingerDX 是手指（也就是内容）横向移动的距离，正数向右。
    /// 手指 0.2 秒滑过 40%，松手后惯性滑完其余部分（指数衰减）。和真的滚动事件走同一个换算。
    func debugSwipe(_ fingerDX: CGFloat) {
        guard let view = debugView else { return }
        let distance = view.scrollDelta(dx: fingerDX, dy: 0)
        view.isScrollGestureActive = true
        let fingerSteps = 24, rate = 120.0
        for i in 0..<fingerSteps {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) / rate) {
                // 跟真的触控板一样：标成用户在滑，日期牌才会出来
                view.userScrolling = true
                view.trackScroll(by: distance * 0.4 / CGFloat(fingerSteps))
                view.delegate?.shelfViewDidInteract(view)
            }
        }
        // 惯性：每帧乘 0.95，总和约等于剩下的 60%
        var v = distance * 0.6 * 0.05
        var i = 0
        while abs(v) > 0.2 {
            let d = v
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(fingerSteps + i) / rate) {
                let outOfRange = view.scroll.target < view.minScroll || view.scroll.target > view.maxScroll
                view.trackScroll(by: outOfRange ? d * 0.35 : d)
                view.delegate?.shelfViewDidInteract(view)
            }
            v *= 0.95; i += 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(fingerSteps + i) / rate) {
            view.isScrollGestureActive = false
            view.settleScroll(to: view.scroll.target)
        }
    }

    /// 模拟鼠标在第 0 张卡片中部横向移动：先单程扫过，再快速来回 3 次。
    func debugSweep() {
        guard let view = debugView, let card = view.cards.first else { return }
        let f = card.frame(in: view.root)
        let y = f.midY
        var xs: [CGFloat] = []
        // 600pt/秒，按 120Hz 鼠标事件取点
        let step: CGFloat = 5
        xs += stride(from: f.minX + 4, through: f.maxX - 4, by: step).map { $0 }
        for _ in 0..<3 {
            xs += stride(from: f.maxX - 4, through: f.minX + 4, by: -step * 2).map { $0 }
            xs += stride(from: f.minX + 4, through: f.maxX - 4, by: step * 2).map { $0 }
        }
        for (i, x) in xs.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) / 120) {
                view.updateHover(at: CGPoint(x: x, y: y))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(xs.count) / 120 + 0.02) { view.clearHover() }
    }

    /// 每隔 duration/(frames-1) 秒截一帧屏幕顶部那一条，竖着拼成一张图，左上角标上时间。
    /// 渲染在主线程上做，会拖慢一点帧率，看的是形状和顺序，不是流畅度。
    func film(duration: Double, frames: Int, band: CGFloat = 250, to url: URL) {
        guard let view = debugView, frames > 1 else { return }
        let bandH: CGFloat = min(view.bounds.height, view.topInset + band)
        let w = view.bounds.width
        let start = CACurrentMediaTime()
        var shots: [(CGFloat, CGImage)] = []
        func shoot() {
            guard let ctx = CGContext(data: nil, width: Int(w), height: Int(bandH), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(NSColor(calibratedRed: 0.86, green: 0.87, blue: 0.90, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: bandH))
            ctx.translateBy(x: 0, y: bandH - view.bounds.height)
            view.layer?.render(in: ctx)
            if let img = ctx.makeImage() { shots.append((CGFloat(CACurrentMediaTime() - start), img)) }
        }
        shoot()
        var n = 1
        Timer.scheduledTimer(withTimeInterval: duration / Double(frames - 1), repeats: true) { timer in
            MainActor.assumeIsolated {
                shoot()
                n += 1
                guard n >= frames else { return }
                timer.invalidate()
                Self.writeFilm(shots, width: w, bandHeight: bandH, to: url)
            }
        }
    }

    private static func writeFilm(_ shots: [(CGFloat, CGImage)], width w: CGFloat, bandHeight h: CGFloat, to url: URL) {
        let total = CGFloat(shots.count) * (h + 2)
        guard let ctx = CGContext(data: nil, width: Int(w), height: Int(total), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(NSColor.red.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: total))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for (i, (t, img)) in shots.enumerated() {
            let y = total - CGFloat(i + 1) * (h + 2)
            ctx.draw(img, in: CGRect(x: 0, y: y, width: w, height: h))
            (String(format: "t=%.2f", t) as NSString).draw(at: CGPoint(x: 8, y: y + h - 22), withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .bold), .foregroundColor: NSColor.black,
            ])
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = ctx.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        print("film written: \(url.path) frames=\(shots.count)")
    }

    func writeSnapshot(to url: URL) {
        guard let view = debugView else { return }
        print("root.isGeometryFlipped=\(view.root.isGeometryFlipped) rope0=\(view.rope.points.first ?? .zero)")
        if let win = view.window, let screen = win.screen, let r0 = view.rope.points.first {
            // 根图层坐标 → 视图图层坐标 → 窗口 → 屏幕（屏幕坐标 y 向上）
            let inView = view.root.convert(r0, to: view.layer)
            let onScreen = win.convertPoint(toScreen: view.convert(inView, to: nil))
            print(String(format: "rope left end on screen: y=%.0f, screen top=%.0f (%.0fpt below screen top)",
                         onScreen.y, screen.frame.maxY, screen.frame.maxY - onScreen.y))
        }
        for (i, c) in view.cards.enumerated() {
            let f = c.frame(in: view.root)
            let tb = c.toolbar.frame
            print(String(format: "card %d %@ body=(%.0f,%.0f %.0fx%.0f) angle=%.3f hover=%.2f toolbar=%.2f at (%.0f,%.0f %.0fx%.0f)",
                         i, "\(c.phase)", f.minX, f.minY, f.width, f.height, c.angle, c.hover,
                         c.toolbar.opacity, tb.minX, tb.minY, tb.width, tb.height))
        }
        let scale = view.window?.backingScaleFactor ?? 2
        let size = CGSize(width: view.bounds.width, height: min(view.bounds.height, 360))
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        // --snapshot-clear：背景留透明（拿去合成 README 的图）
        if !CommandLine.arguments.contains("--snapshot-clear") {
            ctx.setFillColor(NSColor(calibratedRed: 0.86, green: 0.87, blue: 0.90, alpha: 1).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        // 视图图层和 CGContext 都是 y 向上，平移后只取窗口顶部 size.height 这一段，不做翻转，
        // 这样截图里的上下方向就是屏幕上的真实方向。
        ctx.translateBy(x: 0, y: size.height - view.bounds.height)
        view.layer?.presentation()?.render(in: ctx) ?? view.layer?.render(in: ctx)
        guard let image = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("snapshot written: \(url.path)")
    }
}

import ScreenCaptureKit

/// 调试用：截下整块屏幕，包括 QuickCap 自己的窗口。不在主线程上等，菜单打开时也能截
enum CaptureDebug {
    /// 调试用：连截图界面一起截一张 HDR 的（看橙光在 HDR 屏上真的多亮、什么颜色）。
    /// 存 HEIC（预览里打开是真的 HDR），并记下 probe 那一行像素里最亮的颜色（线性 sRGB，>1 就是比白还亮）
    static func snapshotHDR(display id: CGDirectDisplayID, to url: URL, probe: CGRect?) async -> String {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let d = content.displays.first(where: { $0.displayID == id }) else { return "no display" }
            let cfg = SCScreenshotConfiguration()
            cfg.width = d.width * 2
            cfg.height = d.height * 2
            cfg.showsCursor = false
            cfg.dynamicRange = .bothSDRAndHDR
            cfg.displayIntent = .local
            let out = try await SCScreenshotManager.captureScreenshot(contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg)
            guard let img = out.hdrImage else { return "no hdr image" }
            if let dst = CGImageDestinationCreateWithURL(url as CFURL, "public.heic" as CFString, 1, nil) {
                CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
                CGImageDestinationFinalize(dst)
            }
            guard let probe else { return "saved" }
            // probe 是屏幕 pt（左下原点）：换成像素（左上原点），在那块里找最亮的
            let w = img.width, h = img.height, sx = CGFloat(w) / CGFloat(d.width), sy = CGFloat(h) / CGFloat(d.height)
            let r = CGRect(x: probe.minX * sx, y: CGFloat(h) - probe.maxY * sy, width: probe.width * sx, height: probe.height * sy).integral
            guard let crop = img.cropping(to: r) else { return "bad probe" }
            let cw = crop.width, ch = crop.height
            var buf = [Float](repeating: 0, count: cw * ch * 4)
            let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            let ctx = CGContext(data: &buf, width: cw, height: ch, bitsPerComponent: 32, bytesPerRow: cw * 16,
                                space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, bitmapInfo: info)!
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: cw, height: ch))
            var best: (Float, Float, Float) = (0, 0, 0)
            for i in stride(from: 0, to: buf.count, by: 4) where buf[i] > best.0 { best = (buf[i], buf[i+1], buf[i+2]) }
            let ratio = best.0 > 0 ? best.1 / best.0 : 0
            return String(format: "peak r=%.2f g=%.2f b=%.2f g/r=%.2f headroom=%.2f", best.0, best.1, best.2, ratio, out.hdrImage.map { $0.contentHeadroom } ?? 0)
        } catch { return "failed \(error)" }
    }

    static func snapshot(display id: CGDirectDisplayID, to url: URL) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let d = content.displays.first(where: { $0.displayID == id }) else { print("capture snapshot: no display"); return }
            let config = SCStreamConfiguration()
            config.width = d.width * 2
            config.height = d.height * 2
            config.showsCursor = false
            let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: config)
            try NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: url)
            print("capture snapshot written: \(url.path)")
        } catch {
            print("capture snapshot failed: \(error)")
        }
    }
}
