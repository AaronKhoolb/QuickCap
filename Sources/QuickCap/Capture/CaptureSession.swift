import AppKit
import ScreenCaptureKit

/// 一次截图：先把每块屏幕截成静态图（冻结），再在每块屏幕上盖一个覆盖窗口。
/// 选择条只出现在鼠标所在的那块屏幕上。
/// 不冻结（Options 里关掉 Freeze Screen，或者开了计时）时，覆盖窗口是透明的，框好（计时结束）那一刻才截。
///
/// 同一时间只有一根条：框选前是屏幕右下的选择条；框好后选择条收起，操作条贴在选区旁边。
/// 主按钮（回车）按设置复制、保存或两样都做，截图同时挂上截图架。
/// Text 模式：松手马上识别文字并复制，不出操作条、不挂截图架；没识别到就留在原地重新框。
@MainActor
final class CaptureSession {
    private let settings: AppSettings
    private(set) var overlays: [CaptureOverlayWindow] = []
    private(set) var bar: SelectionBar?
    private(set) var actionBar: ActionBar?
    /// 选了画画的工具时，操作条旁边的颜色、粗细小条
    private(set) var styleBar: AnnotationStyleBar?
    /// 美化背景的小条
    private var beautyBar: BeautyBar?
    /// 已经按了主按钮，正在出图
    private var performing = false
    private var pending: (CapturedImage, ActionBar.Output)?
    /// "Scanning…" 的提示还挂着（关掉截图界面时一起收掉）
    private var scanningToastUp = false
    private var snapshotToken = 0
    private var ending = false
    /// 选择条上当前的模式（不会是 screen：点 Screen 直接选中整个屏幕）。
    /// Text 快捷键打开的是 text，不会改掉记住的模式
    private(set) var mode: CaptureMode
    /// 截图期间不让系统节能降频（App Nap），动画和按键要及时
    private var activity: NSObjectProtocol?
    /// 这次是冻结着框选，还是看着实时的屏幕框选
    /// 冻结着截：打开时按设置定；截图途中在 Options 里改了计时、冻结，当场换（见 applyOptionChanges）
    private var frozenMode: Bool
    /// 冻结那一刻的鼠标指针（图、热点、位置）：途中才打开"显示指针"时，画到冻结的画面上
    private var freezeCursor: (image: CGImage, hotSpot: CGPoint, location: CGPoint, size: CGSize)?
    /// 正在倒计时
    private var countdownTimer: Timer?
    private(set) var countingDown = false
    /// 截图前在用的 app，关掉截图界面后把焦点还给它
    private var previousApp: NSRunningApplication?
    private var liveTimer: Timer?

    /// 打开截图界面之前屏幕的亮度余量
    private var screenHeadroom: CGFloat = 1
    /// 按钮上写不写 "in HDR"：截出来的文件会不会是 HDR 的。
    /// 窗口：冻结时单独截的这个窗口有没有 HDR 内容（系统按窗口判断，菜单栏这种就没有）；
    /// 不冻结时还没截，按这块屏幕能不能 HDR 算。框选、整个屏幕：这块屏幕截到了 HDR 图
    private func showsHDR(_ v: CaptureOverlayView) -> Bool {
        guard v.hdrAvailable else { return false }
        if v.kind == .window, let w = v.selectedWindow, frozenMode {
            return frozenWindows[w.id]?.hdr != nil
        }
        return true
    }

    /// 截图界面拿键盘焦点的那个窗口（鼠标所在的屏幕）
    private var keyOverlay: CaptureOverlayWindow?
    private var tookKeyFocus = false
    /// 冻结时截下来的每个窗口
    private(set) var frozenWindows: [CGWindowID: WindowShot] = [:]

    private func takeKeyFocus() {
        guard !tookKeyFocus, !ending, let key = keyOverlay else { return }
        tookKeyFocus = true
        key.makeKeyAndOrderFront(nil)
        key.makeFirstResponder(key.overlayView)
        // 等焦点这段时间按的键：现在照原样补上（空格切换、方向键、字母快捷键）
        let pending = earlyKeys
        releaseEarlyKeys()
        for k in pending {
            guard let cg = CGEvent(keyboardEventSource: nil, virtualKey: k, keyDown: true), let ev = NSEvent(cgEvent: cg) else { continue }
            _ = keyDown(ev)
        }
    }

    /// 冻结时要先截每个窗口（最多 0.8 秒）才拿键盘焦点，这段时间按的键会漏给下面的应用
    /// （字打进文档、空格翻页、Esc 关掉别人的对话框）。临时把不带修饰键的这些键全局接住：Esc 马上取消，别的记下来，拿到焦点后补上
    private var earlyKeys: [CGKeyCode] = []
    private var catchingEarlyKeys = false
    /// 字母、数字、符号、回车、Tab、空格、删除、Esc（0…53），小键盘回车、向前删除、方向键
    private static let earlyKeyCodes: [CGKeyCode] = Array(0...53) + [76, 117, 123, 124, 125, 126]
    private static func earlyKeyID(_ k: CGKeyCode) -> UInt32 { 1000 + UInt32(k) }

    private func catchEarlyKeys() {
        catchingEarlyKeys = true
        for k in Self.earlyKeyCodes {
            HotKeyCenter.shared.register(id: Self.earlyKeyID(k), HotKey(keyCode: UInt32(k), modifiers: 0)) { [weak self] in
                guard let self, self.catchingEarlyKeys else { return }
                if k == 53 { self.cancel() } else { self.earlyKeys.append(k) }
            }
        }
    }

    private func releaseEarlyKeys() {
        earlyKeys = []
        guard catchingEarlyKeys else { return }
        catchingEarlyKeys = false
        for k in Self.earlyKeyCodes { HotKeyCenter.shared.register(id: Self.earlyKeyID(k), nil) {} }
    }

    /// 冻结时把所有窗口截下来，量范围和圆角；截完马上拿键盘焦点
    private func freezeWindows() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let hdr = wantsHDR
        let shadow = settings.windowShadow
        frozenShadow = shadow
        // 窗口在哪块屏幕就按那块屏幕的像素倍数截（全局坐标，原点在主屏左上角）
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let screens = NSScreen.screens.map { s in (CGRect(x: s.frame.minX, y: primaryHeight - s.frame.maxY, width: s.frame.width, height: s.frame.height), s.backingScaleFactor) }
        let start = Date()
        Task { @MainActor [weak self] in
            let frozen = await ScreenWindows.freezeAll(excluding: pid, hdr: hdr, shadow: shadow) { r in
                let c = CGPoint(x: r.midX, y: r.midY)
                return screens.first { $0.0.contains(c) }?.1 ?? screens.max { $0.0.intersection(r).width * $0.0.intersection(r).height < $1.0.intersection(r).width * $1.0.intersection(r).height }?.1 ?? 2
            }
            guard let self, !self.ending else { return }
            self.frozenWindows = frozen.shots
            self.freezeWindowsSeconds = Date().timeIntervalSince(start)
            self.takeKeyFocus()
            for w in self.overlays {
                let v = w.overlayView
                v.updateWindows(ScreenWindows.apply(frozen.pixels, to: v.windows))
            }
        }
    }
    /// 调试用：截所有窗口花了多久
    private(set) var freezeWindowsSeconds: Double = 0
    /// 冻结时截的窗口带没带阴影
    private var frozenShadow = false

    /// all：打开时全部重新量（记着的可能已经过时）；实时模式每半秒刷新列表时只量新出现的
    private func verifyWindows(on v: CaptureOverlayView, all: Bool = false) {
        let current = v.windows
        guard all || current.contains(where: { !$0.verified }) else { return }
        let scale = v.screenRef.backingScaleFactor
        Task { @MainActor [weak self, weak v] in
            let checked = await ScreenWindows.verify(current, scale: scale, all: all)
            guard let self, let v, !self.ending else { return }
            // 量的时候列表可能已经换过（实时模式），只更新还在的那些；一个像素都没画的去掉
            let byID = Dictionary(checked.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let gone = Set(current.map(\.id)).subtracting(byID.keys)
            v.updateWindows(v.windows.compactMap { w in gone.contains(w.id) ? nil : (byID[w.id].map { $0.frame == w.frame ? $0 : w } ?? w) })
        }
    }

    /// 盯着系统的各种情况（Mission Control、换桌面、切到别的 app、睡眠锁屏、插拔显示器），一出现就关掉截图界面
    private var guardObservers: [(NotificationCenter, Any)] = []
    private var guardTimer: Timer?
    private var shownAt = Date.distantFuture
    private var menuOpen = false
    /// 调试用：为什么关掉的
    private(set) var abortReason: String?
    /// 最近一次把焦点还给了哪个 app、什么时候
    private static var lastRestore: (pid: pid_t, at: Date)?

    var onOpenSettings: (() -> Void)?
    var onEnd: (() -> Void)?
    /// 截好了：图、要做的事（复制 / 保存 / 两样）。在 onEnd 之前调用
    var onCaptured: ((CapturedImage, ActionBar.Output) -> Void)?
    /// 截好的图飞向哪里（截图架挂绳那头，屏幕坐标）。nil：不飞（截图架在别的屏幕）
    var flightTarget: ((NSScreen) -> CGPoint?)?
    /// 已经交出去了（飞出去的时候不等截图界面淡完）
    private var delivered = false

    init(settings: AppSettings, mode: CaptureMode? = nil) {
        self.settings = settings
        // ⇧⌘2 打开时用记住的模式；Text 有自己的快捷键，所以不当作记住的模式
        let saved = settings.captureMode == .text || settings.captureMode == .screen ? .area : settings.captureMode
        self.mode = mode ?? saved
        frozenMode = settings.freezeScreen && settings.captureTimer == 0
    }

    func start() {
        // 截图界面还没出来时屏幕的亮度余量（截图界面显示 HDR 画面后会变）
        screenHeadroom = NSScreen.screens.map(\.maximumExtendedDynamicRangeColorComponentValue).max() ?? 1
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Capture")
        // 用户框选的这一两秒里，先把文字识别模型加载好（已经加载好的话只要零点几秒）
        TextRecognizer.warmUp()
        // 开关已经打开、只差重新打开的，也先试着截（有时不用重开就能截）；截不了再提示
        guard ScreenAccess.state == .needsReopen || ScreenAccess.request() else {
            // 第一次：系统自己会弹提示，再叠一个我们的就是两个框
            if !ScreenAccess.takePromptedNow() { showPermissionAlert() }
            finish()
            return
        }
        Task { await freezeAndShow() }
    }

    // MARK: 冻结屏幕

    /// 打开时读到的界面元素边框（全局坐标）。没开这个设置或没权限就是空的
    private var uiElementFrames: [CGRect] = []

    private func freezeAndShow() async {
        let frozen: [Shot]
        recordCursor()
        do {
            // 要显示鼠标指针的话，鼠标所在那块屏幕再截一张带指针的（只用来出图，界面上显示的不带指针）
            let pointerScreen = settings.showPointer ? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }?.displayID : nil
            // 界面元素的边框要在截图界面盖上去之前读（最多 0.15 秒）
            uiElementFrames = settings.snapToUIElements && settings.snapToEdges ? UIElementEdges.frames() : []
            frozen = try await Self.captureAllScreens(pointerOn: pointerScreen, hdr: wantsHDR)
        } catch {
            NSLog("QuickCap capture failed: \(error)")
            showPermissionAlert()
            finish()
            return
        }
        guard !ending else { return }
        show(frozen)
    }

    /// 一块屏幕截下来的图：普通的、带鼠标指针的（出图用），和它们各自的 HDR 版本（存文件时算增益图用）。
    /// 普通图和 HDR 图必须是同一次截的同一个画面，增益图才对得上
    struct Shot {
        let screen: NSScreen
        let image: CGImage
        var withPointer: CGImage?
        var hdr: CGImage?
        var withPointerHDR: CGImage?
    }

    /// 设置开了 HDR、而且有屏幕能显示 HDR 时才多截一张 HDR 的。Text 模式用不到
    private var wantsHDR: Bool {
        settings.captureHDR && mode != .text && NSScreen.screens.contains { $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1 }
    }

    /// 每块屏幕截一张原始分辨率的图，不包括 QuickCap 自己的窗口（悬挂架、把手、截图界面）。
    /// pointerOn 那块屏幕再截一张带鼠标指针的
    /// 调试用：上次冻结时排除了哪些窗口
    static var debugExcluded = "-"

    private static func captureAllScreens(pointerOn: CGDirectDisplayID? = nil, hdr: Bool) async throws -> [Shot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        var ours = content.windows.filter { $0.owningApplication?.processID == pid }
        // 设置里"截图时隐藏桌面图标"：把 Finder 画桌面图标的那几个窗口也排除掉（不用重启 Finder，桌面上的图标不动）
        if AppSettings.shared.hideDesktopIcons {
            let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
            ours += content.windows.filter {
                $0.owningApplication?.bundleIdentifier == "com.apple.finder" && $0.windowLayer == iconLevel
            }
        }
        debugExcluded = "ours=\(ours.filter { $0.owningApplication?.processID == pid }.count) finderIcons=\(ours.filter { $0.owningApplication?.bundleIdentifier == "com.apple.finder" }.count)"
        // 美化背景的 Desktop Wallpaper 用：顺便截下这一刻的系统壁纸（动态壁纸也行），不等它
        Task.detached(priority: .utility) { await BeautyBackground.captureLive(content) }
        var result: [Shot] = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let useHDR = hdr && screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1
            let (image, hdrImage) = try await shot(display, screen: screen, excluding: ours, cursor: false, hdr: useHDR)
            let p = id == pointerOn ? try? await shot(display, screen: screen, excluding: ours, cursor: true, hdr: useHDR) : nil
            result.append(Shot(screen: screen, image: image, withPointer: p?.0, hdr: hdrImage, withPointerHDR: p?.1))
        }
        return result
    }

    /// 截一块屏幕。hdr 时普通的和 HDR 的一次一起拿（只多几十毫秒）
    private static func shot(_ display: SCDisplay, screen: NSScreen, excluding: [SCWindow], cursor: Bool,
                             hdr: Bool) async throws -> (CGImage, CGImage?) {
        let filter = SCContentFilter(display: display, excludingWindows: excluding)
        let scale = screen.backingScaleFactor
        if hdr {
            let cfg = SCScreenshotConfiguration()
            cfg.width = Int(screen.frame.width * scale)
            cfg.height = Int(screen.frame.height * scale)
            cfg.showsCursor = cursor
            cfg.dynamicRange = .bothSDRAndHDR
            cfg.displayIntent = .local
            do {
                let out = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: cfg)
                if let sdr = out.sdrImage { return (sdr, out.hdrImage) }
                Self.lastHDRError = "no sdr image"
            } catch {
                // 截不到 HDR 就退回普通截图，记下原因（调试用）
                Self.lastHDRError = "\(error)"
            }
        }
        let config = SCStreamConfiguration()
        config.width = Int(screen.frame.width * scale)
        config.height = Int(screen.frame.height * scale)
        config.showsCursor = cursor
        config.captureResolution = .best
        return (try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config), nil)
    }

    /// 调试用：最近一次 HDR 截图为什么失败
    nonisolated(unsafe) static var lastHDRError: String?
    var hdrDebug: String { "wantsHDR=\(wantsHDR) lastHDRError=\(Self.lastHDRError ?? "none")" }

    /// 不冻结的时候：框好（或倒计时结束）这一刻截这块屏幕
    private static func snapshot(_ screen: NSScreen, pointer: Bool, hdr: Bool) async -> Shot? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let id = screen.displayID, let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
        let pid = ProcessInfo.processInfo.processIdentifier
        let ours = content.windows.filter { $0.owningApplication?.processID == pid }
        let useHDR = hdr && screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1
        guard let (plain, hdrImage) = try? await shot(display, screen: screen, excluding: ours, cursor: false, hdr: useHDR) else { return nil }
        let p = pointer ? try? await shot(display, screen: screen, excluding: ours, cursor: true, hdr: useHDR) : nil
        return Shot(screen: screen, image: plain, withPointer: p?.0, hdr: hdrImage, withPointerHDR: p?.1)
    }

    private func show(_ frozen: [Shot]) {
        let mouse = NSEvent.mouseLocation
        let home = frozen.first { $0.screen.frame.contains(mouse) }?.screen ?? frozen.first?.screen
        for shot in frozen {
            let screen = shot.screen
            let w = CaptureOverlayWindow(screen: screen, frozen: shot.image, session: self)
            w.overlayView.setSnapshot(shot.image, output: shot.withPointer, hdr: shot.hdr, outputHDR: shot.withPointerHDR)
            if !uiElementFrames.isEmpty { w.overlayView.setUIElements(UIElementEdges.local(uiElementFrames, on: screen)) }
            if !frozenMode { w.overlayView.setLive(true) }
            overlays.append(w)
            if screen == home {
                let b = SelectionBar(mode: mode)
                b.onMode = { [weak self] in self?.pick($0) }
                b.onClose = { [weak self] in self?.cancel() }
                b.onOptions = { [weak self] button in self?.showOptions(from: button) }
                w.overlayView.install(bar: b)
                bar = b
            }
        }
        let ab = ActionBar(settings: settings)
        ab.onCancel = { [weak self] in self?.clearAllSelections() }
        ab.onRun = { [weak self] in self?.perform($0) }
        ab.onResize = { [weak self] in self?.activeOverlay?.layoutActionBar() }
        ab.onTool = { [weak self] t in self?.selectTool(t) }
        ab.onUndo = { [weak self] in self?.activeOverlay?.annotator.undo() }
        ab.onPin = { [weak self] in self.map { $0.perform($0.settings.captureCopy ? .saveAndCopy : .save, pin: true) } }
        ab.onBeauty = { [weak self] in self?.toggleBeauty() }
        ab.onScroll = { [weak self] in self?.startScrolling() }
        actionBar = ab
        let sb = AnnotationStyleBar()
        sb.onColor = { [weak self] i in self?.setAnnotationColor(i) }
        sb.onWidth = { [weak self] i in self?.setAnnotationWidth(i) }
        styleBar = sb
        // 光标：和系统截图一样不抢焦点，让 QuickCap 在后台也能定光标（不然前面那个 app 一动鼠标就把光标改回箭头，来回闪）。
        // 不抢焦点，通知中心、菜单、弹出框这些"别的 app 变成当前 app 就收起来"的东西才会留在屏幕上，能单独截。
        // 万一系统不让设，才退回老办法：变成当前 app
        previousApp = NSWorkspace.shared.frontmostApplication
        if previousApp == NSRunningApplication.current { previousApp = nil }
        if !BackgroundCursor.enabled { NSApp.activate() }
        for w in overlays { w.orderFrontRegardless() }
        keyOverlay = overlays.first { $0.screen == home } ?? overlays.first
        bar?.animateIn()
        shownAt = Date()
        installGuards()
        if frozenMode {
            // 先把每个窗口当时的样子截下来，再拿键盘焦点：一拿焦点，通知中心、菜单、弹出框就会自己收起来。
            // 截窗口约 0.3 秒；万一太久，最多等 0.8 秒就先拿焦点（截到的照样用）
            catchEarlyKeys()
            freezeWindows()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.takeKeyFocus() }
        } else {
            // 不冻结：屏幕是实时的，选哪个窗口出图时再截。后台量一遍范围和圆角
            takeKeyFocus()
            for w in overlays { verifyWindows(on: w.overlayView, all: true) }
        }
        // 不冻结的话窗口会动、会开关：每 0.5 秒重新列一次
        if !frozenMode { startLiveTimer() }
        // 记住上次选区：直接框好上次那一块
        if settings.rememberSelection, mode != .text { restoreLastSelection() }
    }

    /// 上次的自由框选（屏幕坐标）。按 R 也能恢复
    @discardableResult
    func restoreLastSelection() -> Bool {
        guard let r = settings.lastCaptureRect,
              let w = overlays.first(where: { $0.frame.contains(CGPoint(x: r.midX, y: r.midY)) }) else { return false }
        let local = r.offsetBy(dx: -w.frame.minX, dy: -w.frame.minY).intersection(w.overlayView.bounds)
        guard local.width >= 4, local.height >= 4 else { return false }
        w.overlayView.restoreSelection(local)
        return true
    }

    // MARK: 选区

    /// 认字不是截图：框大一点小一点都认得出，吸附反而会把框拽来拽去，所以 Text 模式不吸
    var snapEnabled: Bool { settings.snapToEdges && mode != .text }
    var loupeEnabled: Bool { settings.showMagnifier }
    var hasSelection: Bool { overlays.contains { $0.overlayView.selection != nil } }

    /// 拿着键盘的那块屏幕（键盘换窗口用这块屏幕上的）
    private var keyOverlayView: CaptureOverlayView? {
        overlays.first { $0.isKeyWindow }?.overlayView ?? keyOverlay?.overlayView
    }
    var activeOverlay: CaptureOverlayView? { overlays.map(\.overlayView).first { $0.selection != nil } }

    /// 开始拖新选区、移动或调整选区：别的屏幕上的选区取消，两根条都先收起来
    func selectionBegan(on view: CaptureOverlayView) {
        // 扫描中或者正显示结果：重新框选就从头来（旧的结果不要了）
        if mode == .text, scanToken > 0 { endScan(restore: true, keepGlow: true) }
        for w in overlays where w.overlayView !== view { w.overlayView.clearSelection() }
        bar?.hideTooltip()
        bar?.animateOut()
        actionBar?.animateOut(duration: 0.1, offsetY: 0)
        hideStyleBar()
        hideBeautyBar()
    }

    /// 选区定下来了（松手、选中窗口或屏幕）：操作条贴到选区旁边弹出来。
    /// 不冻结的话先截这一刻（有计时就先倒计时）
    func selectionSettled(on view: CaptureOverlayView) {
        if view.kind == .area, let r = view.selection, let w = view.window {
            settings.lastCaptureRect = r.offsetBy(dx: w.frame.minX, dy: w.frame.minY)
        }
        guard !performing, !countingDown else { return }
        if view.isLive, view.snapshotStale {
            // 设了计时：和系统截图一样，先出操作条（按钮上写 ⏱ 5s），按 Capture 才开始倒数，数完直接截好。
            // Text 模式没有操作条，框好就开始倒数
            if settings.captureTimer > 0 {
                if mode == .text { startCountdown(on: view, then: nil) } else { showActionBar(on: view) }
            } else {
                takeSnapshot(on: view)
            }
            return
        }
        afterSnapshot(on: view)
    }

    /// 截好了（或者本来就冻结着）：Text 模式去识别，否则出操作条
    private func afterSnapshot(on view: CaptureOverlayView) {
        if mode == .text { scan(on: view); return }
        showActionBar(on: view)
    }

    /// 出操作条。还没截这一刻、设了计时的话，按钮上写计时
    private func showActionBar(on view: CaptureOverlayView) {
        guard let ab = actionBar, !performing else { return }
        ab.setTimer(view.isLive && view.snapshotStale ? settings.captureTimer : 0)
        if ab.superview !== view { ab.removeFromSuperview(); view.attach(actionBar: ab) }
        ab.refresh()
        ab.setHDR(settings.captureHDR && showsHDR(view))
        view.layoutActionBar()
        ab.animateIn(fromTopRight: view.actionBarBelow)
        ab.setTool(view.annotator.tool)
        ab.setBeauty(view.beautyOn)
        ab.setCanUndo(view.annotator.canUndo)
        view.annotator.onChange = { [weak self, weak view] in self?.actionBar?.setCanUndo(view?.annotator.canUndo ?? false) }
        view.annotator.onSelect = { [weak self, weak view] in self?.refreshStyleBar(for: view) }
        if view.annotator.tool != nil { showStyleBar(on: view) }
    }

    // MARK: 画画

    /// 选好区域以后，单个字母换画画的工具
    static let toolKeys: [String: AnnotationTool] = ["a": .arrow, "r": .rectangle, "p": .pen, "t": .text,
                                                     "h": .highlight, "b": .blur, "n": .counter]

    private static let colorKey = "annotationColor", widthKey = "annotationWidth"
    private var colorIndex: Int { min(max(UserDefaults.standard.object(forKey: Self.colorKey) as? Int ?? 0, 0), AnnotationStyle.colors.count - 1) }
    private var widthIndex: Int { min(max(UserDefaults.standard.object(forKey: Self.widthKey) as? Int ?? 1, 0), AnnotationStyle.widths.count - 1) }

    /// 点了操作条上的工具（nil：不画了，回到挪选区、改大小）
    func selectTool(_ t: AnnotationTool?) {
        guard let v = activeOverlay else { return }
        v.annotator.color = AnnotationStyle.colors[colorIndex]
        v.annotator.width = AnnotationStyle.widths[widthIndex]
        v.setTool(t)
        actionBar?.setTool(t)
        if t != nil { hideBeautyBar(); showStyleBar(on: v) } else { hideStyleBar() }
    }

    /// 背景按钮（G）：关着就打开并出小条；开着、小条没出来就只出小条；开着、小条在就关掉
    func toggleBeauty() {
        guard let v = activeOverlay, let ab = actionBar else { return }
        let barShown = beautyBar.map { $0.superview === v && !$0.isHidden } ?? false
        if v.beautyOn && barShown {
            v.setBeauty(false)
            ab.setBeauty(false)
            hideBeautyBar()
            return
        }
        if v.annotator.tool != nil { selectTool(nil) }
        if !v.beautyOn { v.setBeauty(true); ab.setBeauty(true) }
        showBeautyBar(on: v)
    }

    private func showBeautyBar(on view: CaptureOverlayView) {
        let bar = beautyBar ?? BeautyBar(style: view.beautyStyle, wallpaper: view.wallpaper)
        bar.onChange = { [weak self, weak view] style in
            guard let view else { return }
            view.setBeauty(true, style: style)
            if let self, let b = self.beautyBar { view.layoutStyleBar(b, for: nil) }
        }
        beautyBar = bar
        let wasShown = bar.superview === view && !bar.isHidden
        if bar.superview !== view { bar.removeFromSuperview(); view.addSubview(bar) }
        view.layoutStyleBar(bar, for: nil)
        if !wasShown { bar.animateIn(below: view.actionBarBelow) }
    }

    private func hideBeautyBar() {
        guard let b = beautyBar, b.superview != nil, !b.isHidden else { return }
        b.animateOut(duration: 0.1, offsetY: 0)
    }

    /// 选中了一个画好的：样式条上亮的是它的颜色、粗细（以前一直亮工具的默认值，看不出它现在是什么样）
    private func refreshStyleBar(for view: CaptureOverlayView?) {
        guard let sb = styleBar, let t = actionBar?.tool else { return }
        let s = view?.annotator.selectedStyleIndices
        sb.show(tool: t, color: s?.color ?? colorIndex, width: s?.width ?? widthIndex)
    }

    private func setAnnotationColor(_ i: Int) {
        UserDefaults.standard.set(i, forKey: Self.colorKey)
        activeOverlay?.annotator.color = AnnotationStyle.colors[i]
        activeOverlay?.annotator.restyleSelected(color: AnnotationStyle.colors[i])
        activeOverlay?.restyleText(color: AnnotationStyle.colors[i])
        refreshStyleBar(for: activeOverlay)
    }

    private func setAnnotationWidth(_ i: Int) {
        UserDefaults.standard.set(i, forKey: Self.widthKey)
        activeOverlay?.annotator.width = AnnotationStyle.widths[i]
        activeOverlay?.annotator.restyleSelected(width: AnnotationStyle.widths[i])
        activeOverlay?.restyleText(width: AnnotationStyle.widths[i])
        refreshStyleBar(for: activeOverlay)
    }

    private func showStyleBar(on view: CaptureOverlayView) {
        guard let sb = styleBar, let ab = actionBar, let t = ab.tool else { return }
        sb.show(tool: t, color: colorIndex, width: widthIndex)
        let wasShown = sb.superview === view && !sb.isHidden
        if sb.superview !== view { sb.removeFromSuperview(); view.addSubview(sb) }
        view.layoutStyleBar(sb, for: t)
        if !wasShown { sb.animateIn(below: view.actionBarBelow) }
    }

    private func hideStyleBar() {
        guard let sb = styleBar, sb.superview != nil, !sb.isHidden else { return }
        sb.animateOut(duration: 0.1, offsetY: 0)
    }

    // MARK: 不冻结：截这一刻、倒计时

    /// then：截好以后做什么（不给就出操作条或识别文字）
    /// 记下这一刻的鼠标指针（截下这一刻的画面时一起记，之后打开"显示指针"画上去的就是这一刻的）
    private func recordCursor() {
        let cursor = NSCursor.currentSystem ?? NSCursor.arrow
        if let cg = cursor.image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            freezeCursor = (cg, cursor.hotSpot, NSEvent.mouseLocation, cursor.image.size)
        }
    }

    private func takeSnapshot(on view: CaptureOverlayView, then: (() -> Void)? = nil) {
        guard let screen = view.window?.screen else { return }
        recordCursor()
        let pointer = settings.showPointer && mode != .text
        let hdr = wantsHDR
        // 截好回来时，用户可能已经在拖新的框了：只认最新的这一次、选区没变、没在拖，不然操作条会在拖到一半时弹出来
        snapshotToken += 1
        let token = snapshotToken, rect = view.selection
        Task { @MainActor in
            guard let shot = await Self.snapshot(screen, pointer: pointer, hdr: hdr), !self.ending,
                  view.selection != nil, token == self.snapshotToken, view.selection == rect, !view.isDragging else { return }
            view.setSnapshot(shot.image, output: shot.withPointer, hdr: shot.hdr, outputHDR: shot.withPointerHDR)
            view.setLive(false)
            if let then { then() } else { self.afterSnapshot(on: view) }
        }
    }

    /// 倒数，和系统截图一样：操作条收成一根小条（在原来 Capture 的位置），左边 Cancel、右边 ⏱ 3s；
    /// 截图界面整个让开（不暗、不显示框、点穿），可以去打开菜单、悬停出提示。数完截这一刻。
    /// out：数完截好直接存（按 Capture 开始的）；nil：Text 模式，数完识别文字
    private var countdownPanel: CountdownPanel?
    private var countdownOutput: ActionBar.Output?
    private var countdownLeft = 0

    private func startCountdown(on view: CaptureOverlayView, then out: ActionBar.Output?) {
        guard !countingDown, let screen = view.window?.screen else { return }
        countingDown = true
        countdownOutput = out
        let seconds = settings.captureTimer
        countdownLeft = seconds
        view.debugCountdown = seconds
        // 条出在 Capture 按钮那里；没有操作条（Text 模式）就出在选区下面
        let anchor = actionBar?.isShown == true ? actionBar?.primaryAnchor : nil
        let at = anchor ?? view.selection.flatMap { s -> (CGFloat, CGFloat)? in
            guard let w = view.window else { return nil }
            let r = s.offsetBy(dx: w.frame.minX, dy: w.frame.minY)
            return (r.midX + 80, r.minY - 34)
        } ?? (screen.frame.midX + 80, screen.frame.midY)
        bar?.animateOut()
        actionBar?.animateOut(duration: 0.12, offsetY: 0)
        hideStyleBar()
        hideBeautyBar()
        view.window?.ignoresMouseEvents = true
        view.setCounting(true)
        let panel = countdownPanel ?? CountdownPanel()
        countdownPanel = panel
        panel.bar.onCancel = { [weak self] in self?.cancelCountdown() }
        panel.show(rightX: at.0, midY: at.1, seconds: seconds, on: screen)
        // 鼠标点到别的 app 后截图界面就收不到键盘了，临时注册一个全局 Esc
        HotKeyCenter.shared.register(id: AppSettings.HotKeyID.captureEscape.rawValue,
                                     HotKey(keyCode: 53, modifiers: 0)) { [weak self] in self?.cancelCountdown() }
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self, weak view] t in
            MainActor.assumeIsolated {
                guard let self, let view else { t.invalidate(); return }
                self.countdownLeft -= 1
                view.debugCountdown = self.countdownLeft
                if self.countdownLeft > 0 { self.countdownPanel?.bar.setSeconds(self.countdownLeft, animated: true); return }
                t.invalidate()
                self.finishCountdown(on: view)
            }
        }
    }

    /// 数完：截这一刻。存图的话截图界面不用再出来（直接飞去截图架）；识别文字要出来放扫描的光
    private func finishCountdown(on view: CaptureOverlayView) {
        let out = countdownOutput
        endCountdown(on: view, restore: out == nil)
        // 倒数时可能点到了别的 app：把键盘拿回来（不抢焦点）
        if !BackgroundCursor.enabled { NSApp.activate() }
        view.window?.makeKeyAndOrderFront(nil)
        view.window?.makeFirstResponder(view)
        if let out {
            takeSnapshot(on: view) { [weak self] in self?.perform(out) }
        } else {
            takeSnapshot(on: view)
        }
    }

    /// restore：截图界面回来（取消时）
    private func endCountdown(on view: CaptureOverlayView?, restore: Bool = true) {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countingDown = false
        countdownOutput = nil
        view?.debugCountdown = 0
        HotKeyCenter.shared.register(id: AppSettings.HotKeyID.captureEscape.rawValue, nil) {}
        countdownPanel?.dismiss(animated: restore)
        view?.window?.ignoresMouseEvents = false
        view?.setCounting(false, restore: restore)
    }

    /// 倒数中按 Esc 或 Cancel：不截，回到框好的样子（操作条回来，可以改选区或者再按 Capture）
    /// 调试用：倒数条在屏幕上的位置（Cancel 按钮的中心，屏幕坐标、原点左下）和显示的秒数
    var debugCountdownBar: String {
        guard let p = countdownPanel, p.isVisible else { return "countdownBar=none" }
        let c = p.bar.debugCenter("cancel").map { p.bar.convert($0, to: nil) }.map { p.convertPoint(toScreen: $0) }
        return "countdownBar=\(p.bar.value)s cancelAt=\(c.map { "\(Int($0.x)),\(Int($0.y))" } ?? "?") panel=\(Int(p.frame.minX)),\(Int(p.frame.minY)),\(Int(p.frame.width))x\(Int(p.frame.height))"
    }

    func cancelCountdown() {
        guard countingDown, let view = activeOverlay else { return }
        endCountdown(on: view)
        view.window?.makeKeyAndOrderFront(nil)
        view.window?.makeFirstResponder(view)
        if mode == .text { clearAllSelections() } else { showActionBar(on: view) }
    }

    /// 取消所有选区，选择条回来
    func clearAllSelections() {
        if countingDown { endCountdown(on: activeOverlay) }
        if mode == .text { endScan(restore: true) }
        for w in overlays {
            w.overlayView.clearSelection()
            // 不冻结的话，回到实时画面
            if !frozenMode { w.overlayView.setLive(true) }
        }
        actionBar?.animateOut(duration: 0.1, offsetY: 0)
        hideStyleBar()
        hideBeautyBar()
        bar?.animateIn()
    }

    // MARK: 出图

    /// Capture、回车、⌘C 都到这里
    func perform(_ out: ActionBar.Output, pin: Bool = false) {
        guard !performing, !countingDown, let v = activeOverlay, let rect = v.selection, let win = v.window else { return }
        // 不冻结、还没截这一刻：设了计时就先倒数（数完再进来），没设就先截
        if v.isLive, v.snapshotStale {
            if settings.captureTimer > 0 { startCountdown(on: v, then: out) } else { takeSnapshot(on: v) { [weak self] in self?.perform(out) } }
            return
        }
        v.commitText()
        performing = true
        let scale = win.backingScaleFactor
        let selRect = rect.offsetBy(dx: win.frame.minX, dy: win.frame.minY)
        if settings.captureSound { NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif", byReference: true)?.play() }
        // 窗口单独截一张（带透明圆角、不被挡住）；截不到就从冻结的画面里裁。要显示鼠标指针就用带指针的那张。
        // HDR 图跟着普通图走：同一张画面的普通版和 HDR 版一起裁，存文件时按两张的差算增益图
        let kind = v.kind, win0 = v.selectedWindow
        let pointer = settings.showPointer, wantHDR = settings.captureHDR && v.hdrAvailable
        let usePointer = pointer && v.output != nil
        var source = usePointer ? v.output! : v.frozen
        var sourceHDR = wantHDR ? (usePointer ? v.outputHDR : v.frozenHDR) : nil
        // 冻结之后才在 Options 里打开"显示指针"：没有带指针的那张，把冻结那一刻的指针画上去
        if pointer, !usePointer, !v.isLive {
            source = compositeCursor(onto: source, in: v) ?? source
            sourceHDR = sourceHDR.flatMap { compositeCursor(onto: $0, in: v) }
        }
        let size = v.bounds.size
        let annotations = v.annotator.items
        // 美化背景：截好、画好以后铺到背景上
        let beauty = v.beautyOn ? (style: v.beautyStyle, corner: v.beautyCorner, wallpaper: v.wallpaper) : nil
        // 窗口截图后面铺壁纸（开了美化背景就不用：美化背景自己有背景）
        let underlay = kind == .window && beauty == nil && settings.windowWallpaper ? v.wallpaper : nil
        // 窗口阴影：按设置；按住 ⌥ 反过来（和系统截图一样）。阴影是系统画的，程序坞、菜单栏这种本来就没有
        let shadow = kind == .window && settings.windowShadow != NSEvent.modifierFlags.contains(.option)
        // 冻结时截的那张能不能用：带没带阴影要对得上（冻结时带了阴影、这个窗口本来就没阴影的也能用）
        let frozenShot = kind == .window ? win0.flatMap { frozenWindows[$0.id] }
            .flatMap { f in frozenShadow == shadow || (frozenShadow && f.shadow.isZero) ? f : nil } : nil
        // 冻结时截的窗口 + 冻结那一刻的指针（以前要显示指针就得现截窗口：指针在点 Capture 的地方，画面也可能已经变了）
        let frozenWithPointer: (CGImage, CGImage?, ShadowInsets)? = {
            guard pointer, let f = frozenShot else { return nil }
            // 冻结时截的窗口图是整个窗口（不按屏幕边裁），窗口有一部分在屏幕外时不能用裁过的选区
            let area = f.shadow.expand(win0?.rect ?? rect)
            // 指针不在这个窗口上：本来就看不见，直接用冻结时的窗口图
            guard let img = compositeCursor(onto: f.image, in: v, area: area) else { return (f.image, wantHDR ? f.hdr : nil, f.shadow) }
            return (img, wantHDR ? f.hdr.flatMap { compositeCursor(onto: $0, in: v, area: area) } : nil, f.shadow)
        }()
        let task = Task { @MainActor () -> (CGImage, CGImage?, ShadowInsets)? in
            if kind == .window, let w = win0 {
                // 冻结时截下的这个窗口：和冻结的屏幕是同一刻，而且通知中心、菜单这种一拿焦点就收起来的也在；
                // 前台窗口也还是前台的样子。要带鼠标指针的话才现截（冻结时截的窗口不带指针），现截不到再用冻结时的
                if let f = frozenShot, !pointer { return (f.image, wantHDR ? f.hdr : nil, f.shadow) }
                if let fp = frozenWithPointer { return fp }
                // 只留窗口实际画了东西的那块（窗口坐标，原点左上）。
                // 单独截窗口时系统自己判断这个窗口有没有 HDR 内容：有才给 HDR 图，没有就存普通的。
                // 不能拿整块屏幕的 HDR 图来凑：圆角外面、被挡住的地方两张图不一样，增益图会算错
                let vis = CGRect(x: w.rect.minX - w.frame.minX, y: w.frame.maxY - w.rect.maxY, width: w.rect.width, height: w.rect.height)
                if let shot = await CaptureOutput.captureWindow(id: w.id, scale: scale, cursor: pointer, visible: vis,
                                                                 hdr: wantHDR, shadow: shadow) {
                    return (shot.image, shot.hdr, shot.shadow)
                }
                if let f = frozenShot { return (f.image, wantHDR ? f.hdr : nil, f.shadow) }
            }
            if kind == .screen { return (source, sourceHDR, .zero) }
            guard let img = CaptureOutput.crop(source, rect: rect, viewSize: size) else { return nil }
            return (img, sourceHDR.flatMap { CaptureOutput.crop($0, rect: rect, viewSize: size) }, .zero)
        }
        // 截好的图从选区里拿起来飞向截图架（截图架在这块屏幕上、没开"减少动态效果"时）。
        // 闪光由飞出去的那张图自己闪；不飞的话在截图界面上闪
        let screen = win.screen
        let target = screen.flatMap { flightTarget?($0) }
        // 钉到桌面：不飞去截图架，图就停在原地变成一张浮着的
        let flies = target != nil && !ReduceMotion.isOn && !pin
        let windowCorner = kind == .window ? (win0?.corner ?? 0) : 0
        v.flashAndHideChrome(flash: !flies)
        actionBar?.animateOut(duration: 0.12, offsetY: 0)
        hideStyleBar()
        hideBeautyBar()
        lastActionBarCenter = actionBar.map { b in
            let r = b.convert(b.bounds, to: nil)
            return CGPoint(x: r.midX + win.frame.minX, y: r.midY + win.frame.minY)
        }
        let pressedAt = Date()
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard var (img, hdr, insets) = await task.value else { NSSound.beep(); self.finish(animated: true); return }
            // 出图途中按了 Esc（或者睡眠、换桌面把截图界面关了）：这张不要了。以前飞上截图架的那条路照样会存
            guard !self.ending else { return }
            // 画的东西画进图里（普通图和 HDR 图都画，增益图在那里是平的）。这张图在截图界面里占的那块：
            // 整个屏幕是整块，框选是选区，窗口是选区再加阴影
            if !annotations.isEmpty {
                // 窗口图是整个窗口（屏幕外那截也在），按没裁过的窗口范围对位置
                let r = kind == .screen ? CGRect(origin: .zero, size: size) : insets.expand(kind == .window ? (win0?.rect ?? rect) : rect)
                if let a = AnnotationRenderer.render(annotations, onto: img, imageRect: r, clip: rect) { img = a }
                hdr = hdr.flatMap { AnnotationRenderer.render(annotations, onto: $0, imageRect: r, clip: rect) }
            }
            var wallpaperBehind = false
            if let wp = underlay {
                let r = insets.expand(win0?.rect ?? rect)
                if let a = BeautyRenderer.underlay(img, imageRect: r, screenSize: size, wallpaper: wp) {
                    img = a
                    hdr = hdr.flatMap { BeautyRenderer.underlay($0, imageRect: r, screenSize: size, wallpaper: wp) }
                    wallpaperBehind = true
                }
            }
            var outRect = selRect
            if let b = beauty {
                let r = kind == .screen ? CGRect(origin: .zero, size: size) : insets.expand(rect)
                if let a = BeautyRenderer.compose(img, imageRect: r, selection: rect, corner: b.corner, style: b.style, wallpaper: b.wallpaper) {
                    img = a
                    hdr = hdr.flatMap { BeautyRenderer.compose($0, imageRect: r, selection: rect, corner: b.corner, style: b.style, wallpaper: b.wallpaper) }
                    // 飞出去的图从整张（背景）那块开始；窗口的系统阴影换成了我们的影子
                    outRect = BeautyLayout.frame(for: rect, style: b.style).offsetBy(dx: win.frame.minX, dy: win.frame.minY)
                    insets = .zero
                }
            }
            // 带阴影的图比窗口大一圈：飞出去的图要从窗口外面那一圈开始，窗口才在原地不动；圆角在透明的阴影里，不用再切
            let screenRect = insets.expand(outRect)
            let corner = beauty != nil || wallpaperBehind ? 0 : insets.isZero ? windowCorner : 0
            var c = CapturedImage(image: img, screenRect: screenRect, scale: scale, hdr: hdr, screenHeadroom: self.screenHeadroom)
            c.pinned = pin
            if pin {
                // 马上钉出来（截图界面在它下面淡掉），文件在后台照常存、挂上截图架
                self.delivered = true
                self.onCaptured?(c, out)
                self.finish(animated: true)
                return
            }
            if flies, let screen {
                // 图一好就拿起来（冻结时几乎马上），截图界面在它下面淡掉；同时开始存文件
                let f = CaptureFlight(image: img, hdr: hdr, rect: screenRect, corner: corner, screen: screen)
                f.lift(toward: target, pixelSize: CGSize(width: img.width, height: img.height))
                c.flight = f
                self.delivered = true
                self.onCaptured?(c, out)
                self.finish(animated: true)
                return
            }
            // 不飞：等闪光看得见（按下后 0.2 秒）再关
            let wait = max(0, 0.2 - Date().timeIntervalSince(pressedAt))
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            self.pending = (c, out)
            self.finish(animated: true)
        }
    }

    // MARK: 滚动截图

    private var stitcher: ScrollStitcher?
    private var scrollTimer: Timer?
    private var scrollBusy = false
    private var scrollBarPanel: FloatingPanel?
    private var scrollPreviewPanel: FloatingPanel?
    private var scrollView: CaptureOverlayView?
    private var lastPreviewAt = Date.distantPast
    /// 预览面板的上边、最长多高、左边（屏幕坐标）
    private var previewTop: CGFloat = 0, previewMax: CGFloat = 0, previewX: CGFloat = 0

    /// 第二条上的滚动按钮（S）：截图界面变成点得穿的，用户自己往下滚，一帧帧接上
    func startScrolling() {
        guard !performing, stitcher == nil, let v = activeOverlay, let sel = v.selection, let win = v.window,
              let screen = win.screen else { return }
        v.commitText()
        if actionBar?.tool != nil { selectTool(nil) }
        actionBar?.animateOut(duration: 0.12, offsetY: 0)
        hideStyleBar()
        hideBeautyBar()
        bar?.animateOut()
        v.setScrolling(true)
        win.ignoresMouseEvents = true
        stitcher = ScrollStitcher()
        scrollView = v
        let screenRect = sel.offsetBy(dx: win.frame.minX, dy: win.frame.minY)

        let sb = ScrollBar()
        sb.onCancel = { [weak self] in self?.cancelScrolling() }
        sb.onDone = { [weak self] in self?.finishScrolling() }
        sb.onAuto = { [weak self] in self?.toggleAutoScroll() }
        let bp = FloatingPanel(content: sb)
        let size = sb.fittingSize
        let vis = screen.visibleFrame
        // 条：选区下面；下面放不下就放进选区里面靠下（我们的面板不会被截进去）
        var y = screenRect.minY - 14 - size.height
        if y < vis.minY + 8 { y = max(screenRect.minY, vis.minY) + 16 }
        let x = min(max(screenRect.midX - size.width / 2, vis.minX + 8), vis.maxX - size.width - 8)
        bp.place(CGRect(x: x, y: y, width: size.width, height: size.height))
        bp.present()
        sb.isHidden = false
        sb.layer?.opacity = 1
        scrollBarPanel = bp

        // 预览：一直在右边。选区右边放得下就放在外面，放不下就贴着选区右边放在里面
        let pv = ScrollPreview()
        let pp = FloatingPanel(content: pv)
        var px = screenRect.maxX + 14
        if px + ScrollPreview.width > vis.maxX - 8 { px = min(screenRect.maxX, vis.maxX) - ScrollPreview.width - 14 }
        // 一开始只有一帧那么高（按比例缩），滚多少长多少，最长到选区那么高；上边一直对齐不动
        previewTop = min(screenRect.maxY - 12, vis.maxY - 8)
        previewMax = max(150, min(screenRect.height - 24, previewTop - vis.minY - 8))
        previewX = px
        let h0 = min(previewMax, ScrollPreview.height(forImageWidth: screenRect.width, imageHeight: screenRect.height))
        pp.place(CGRect(x: px, y: previewTop - h0, width: ScrollPreview.width, height: h0))
        pp.present()
        scrollPreviewPanel = pp

        // 点到别的 app 后截图界面收不到键盘：临时注册一个全局 Esc
        HotKeyCenter.shared.register(id: AppSettings.HotKeyID.captureEscape.rawValue,
                                     HotKey(keyCode: 53, modifiers: 0)) { [weak self] in self?.cancelScrolling() }
        let scale = win.backingScaleFactor
        scrollSource = nil
        scrollRect = screenRect
        scrollScale = scale
        lastPointerInSelection = nil
        let windowID = v.kind == .window ? v.selectedWindowID : nil
        Task { @MainActor [weak self] in
            // 先把要截的东西准备好（一次就好，之后每帧直接用）
            self?.scrollSource = await Self.scrollSource(screen: screen, rect: screenRect, windowID: windowID, scale: scale)
            guard let self, self.stitcher != nil else { return }
            // 每 0.08 秒截一下（截图界面和我们的面板不截进去）
            self.scrollTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.grabScrollFrame() }
            }
            self.grabScrollFrame()
        }
    }

    /// 滚动截图截什么：整块屏幕上的这一块，或者某一个窗口（只截它，前面有别的窗口挡着也不怕）再裁到选区
    private struct ScrollSource: @unchecked Sendable {
        let filter: SCContentFilter
        let config: SCStreamConfiguration
        /// 窗口模式：窗口图里要裁的那块（像素，原点左上）
        let crop: CGRect?
    }
    private var scrollSource: ScrollSource?

    private static func scrollSource(screen: NSScreen, rect: CGRect, windowID: CGWindowID?, scale: CGFloat) async -> ScrollSource? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return nil }
        guard let id = screen.displayID, let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
        // sourceRect 是这块屏幕里的点，原点左上
        let source = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        if let wid = windowID, let w = content.windows.first(where: { $0.windowID == wid }) {
            // 窗口模式：只截这个窗口（前面有别的窗口挡着也只截它），按屏幕上这一块截，比单独截整个窗口快很多
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = source
            cfg.width = Int((rect.width * scale).rounded())
            cfg.height = Int((rect.height * scale).rounded())
            cfg.showsCursor = false
            cfg.captureResolution = .best
            return ScrollSource(filter: SCContentFilter(display: display, including: [w]), config: cfg, crop: nil)
        }
        // 我们自己的窗口（截图界面、滚动条、预览）整个 app 排除：刚出来、还透明的面板不在窗口列表里，按窗口排除会漏掉
        let pid = ProcessInfo.processInfo.processIdentifier
        let ours = content.applications.filter { $0.processID == pid }
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = source
        cfg.width = Int((rect.width * scale).rounded())
        cfg.height = Int((rect.height * scale).rounded())
        cfg.showsCursor = false
        cfg.captureResolution = .best
        return ScrollSource(filter: SCContentFilter(display: display, excludingApplications: ours, exceptingWindows: []), config: cfg, crop: nil)
    }

    /// 拼图在后台一条线上做（每帧十几毫秒，出图时上百毫秒）：主线程只管截图、面板，滚的时候界面一点都不卡。
    /// 拼图的数据只在这条线上读写
    private let stitchQueue = DispatchQueue(label: "QuickCap.stitch", qos: .userInitiated)
    /// 截好了、还没拼完的帧有几张（太多就先不截：拼不过来时少截几帧，不让它越积越多）
    private var stitchInFlight = 0

    /// 拼完一帧后带回主线程的东西
    private struct StitchReport: @unchecked Sendable {
        var grew = false, rejected = 0, lost = false, frameCount = 0, moving = false, hasContent = false
        /// 自动滚动那一栏最远到过哪（像素）；nil：那里还没认出在滚
        var autoFarthest: Int?
        var preview: CGImage?, previewHeight = 0
    }

    private func grabScrollFrame() {
        guard !scrollBusy, stitchInFlight < 2, let st = stitcher, let src = scrollSource else { return }
        scrollBusy = true
        Task { @MainActor [weak self] in
            var img = try? await SCScreenshotManager.captureImage(contentFilter: src.filter, configuration: src.config)
            if let c = src.crop, let full = img { img = full.cropping(to: c.intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))) }
            guard let self else { return }
            self.scrollBusy = false
            guard let img, self.stitcher === st else { return }
            self.notePointer()
            self.stitchInFlight += 1
            let autoX: CGFloat? = self.autoScroller != nil ? self.autoX : nil
            let wantPreview = Date().timeIntervalSince(self.lastPreviewAt) > 0.25
            let width = (ScrollPreview.width - 14) * (self.scrollPreviewPanel?.backingScaleFactor ?? 2)
            self.stitchQueue.async {
                var r = StitchReport()
                r.grew = st.add(img)
                r.rejected = st.rejected
                r.lost = st.lost
                r.frameCount = st.frameCount
                r.moving = st.moving
                r.hasContent = st.hasContent
                if let x = autoX { r.autoFarthest = st.lane(atX: x)?.farthest }
                if (r.grew && wantPreview) || r.frameCount == 1, let full = st.image(preview: true) {
                    r.preview = Self.previewImage(full, width: width)
                    r.previewHeight = full.height
                }
                let report = r
                DispatchQueue.main.async { MainActor.assumeIsolated { self.stitched(report, st) } }
            }
        }
    }

    /// 后台拼完一帧：更新条上的字、预览，自动滚动看是不是到底了
    private func stitched(_ r: StitchReport, _ st: ScrollStitcher) {
        stitchInFlight -= 1
        guard stitcher === st else { return }
        let bar = scrollBarPanel?.content as? ScrollBar
        let rejected = r.rejected > lastRejected
        lastRejected = r.rejected
        if r.moving { lastMovedAt = CACurrentMediaTime() }
        if autoScroller != nil {
            autoScrollCheck(farthest: r.autoFarthest, rejected: rejected, grew: r.grew)
        } else if r.lost {
            // 对不上了：接下去会漏，提示往回滚一点（对上了马上恢复）
            bar?.setState(.warning("Too fast, scroll back a little"))
        } else if autoNote == nil || (r.moving && CACurrentMediaTime() - (autoEndedAt ?? 0) > 1.2) {
            // 自动滚动刚停：页面还在弹回来（也在挪），不算用户在滚，"到底了"留着
            autoNote = nil
            // 停下来一小会儿才算停（两帧之间没挪不算）
            let moving = CACurrentMediaTime() - lastMovedAt < 0.5
            bar?.setState(moving ? .scrolling : r.hasContent ? .paused : .waiting)
        }
        if let p = r.preview { showScrollPreview(p, pixelHeight: r.previewHeight) }
    }
    private var lastRejected = 0
    private var lastMovedAt: CFTimeInterval = 0
    /// 自动滚动停下时条上的话（"Reached the End"）：用户再自己滚之前一直显示
    private var autoNote: String?

    /// 预览：拼好的图缩成预览那么宽。面板跟着长（顺着弹簧长，不是一下跳）
    private func showScrollPreview(_ small: CGImage, pixelHeight: Int) {
        guard let pp = scrollPreviewPanel, let pv = pp.content as? ScrollPreview else { return }
        lastPreviewAt = Date()
        let scale = pp.backingScaleFactor
        pv.update(small, pixelHeight: pixelHeight, scale: scale)
        let w = CGFloat(small.width), h0 = CGFloat(small.height)
        let h = min(previewMax, ScrollPreview.height(forImageWidth: w, imageHeight: h0))
        let target = CGRect(x: previewX, y: previewTop - h, width: ScrollPreview.width, height: h).insetBy(dx: -FloatingPanel.margin, dy: -FloatingPanel.margin)
        if abs(target.height - pp.frame.height) > 0.5 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
                pp.animator().setFrame(target, display: true)
            }
        }
    }

    nonisolated private static func previewImage(_ img: CGImage, width: CGFloat) -> CGImage? {
        let k = width / CGFloat(img.width)
        let w = Int(width.rounded()), h = max(1, Int((CGFloat(img.height) * k).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// 从拼图那条线上带一张图回来
    private struct UnsafeImage: @unchecked Sendable {
        let image: CGImage?
        init(_ i: CGImage?) { image = i }
    }

    // MARK: 自动滚动

    private var scrollRect: CGRect = .zero
    private var scrollScale: CGFloat = 2
    private var autoScroller: AutoScroller?
    private var lastGrowth: CFTimeInterval = 0
    /// 到底检测：每帧记一下（时间、一共发了多少 pt、指针下面那一栏一共挪了多少 pt）
    private var autoSamples: [(t: CFTimeInterval, sent: CGFloat, moved: CGFloat)] = []
    /// 到底了、已经停了：等回弹弹完（画面一阵子不动）再说"到底了"
    private var autoEndedAt: CFTimeInterval?
    private var finishPending = false
    /// 指针最后一次停在选区里（不在我们的面板上）的位置：点条上的按钮时指针已经在条上了，滚的是之前指着的那一栏
    private var lastPointerInSelection: CGPoint?

    /// 每截一帧看一下指针在哪
    private func notePointer() {
        let p = NSEvent.mouseLocation
        guard scrollRect.contains(p) else { return }
        for panel in [scrollBarPanel, scrollPreviewPanel] {
            if let f = panel?.frame.insetBy(dx: FloatingPanel.margin, dy: FloatingPanel.margin), f.contains(p) { return }
        }
        lastPointerInSelection = p
    }

    /// 自动滚动滚哪里：系统把滚轮交给指针下面的那一栏，指针不挪：
    /// 指针在选区里（按 A、空格时）就在这里滚；点条上的按钮时回到点之前指针停过的地方；都没有就选区中间
    private func autoScrollPoint() -> CGPoint {
        notePointer()
        let now = NSEvent.mouseLocation
        if now == lastPointerInSelection { return now }
        if let p = lastPointerInSelection { return p }
        return CGPoint(x: scrollRect.midX, y: scrollRect.midY)
    }

    /// 自动滚动（A、空格，或者条上的按钮）：匀速往下滚，慢慢起步、慢慢停；到底了自己停。
    /// 系统只把滚轮交给指针下面的窗口，所以在指针下面滚；用户一动鼠标就停、指针交还。要"辅助功能"权限
    func toggleAutoScroll() {
        guard stitcher != nil else { return }
        let bar = scrollBarPanel?.content as? ScrollBar
        if let a = autoScroller { a.stop(); autoScroller = nil; bar?.setAuto(false); autoNote = nil; bar?.setState(.paused); return }
        guard CGPreflightPostEventAccess() else {
            _ = CGRequestPostEventAccess()
            autoNote = "Allow QuickCap in Accessibility"
            bar?.setState(.warning("Allow QuickCap in Accessibility"))
            return
        }
        // 速度：一秒滚过选区一半左右（看得清在滚什么、来得及停）
        let speed = min(max(scrollRect.height * 0.5, 200), 480)
        let p = autoScrollPoint()
        autoX = scrollRect.width > 0 ? (p.x - scrollRect.minX) / scrollRect.width : 0.5
        let a = AutoScroller(at: p, speed: speed)
        a.onUserMoved = { [weak self] in
            guard let self, self.autoScroller === a else { return }
            self.autoScroller = nil
            let bar = self.scrollBarPanel?.content as? ScrollBar
            bar?.setAuto(false)
            self.autoNote = nil
            bar?.setState(.paused)
        }
        lastGrowth = CACurrentMediaTime()
        autoSamples = []
        autoEndedAt = nil
        endChecks = 0
        autoBest = nil
        autoNormal = 1
        autoNote = nil
        holdUntil = nil
        a.start()
        autoScroller = a
        lastAuto = a
        autoStopNote = "-"
        bar?.setAuto(true)
        bar?.setState(.auto)
    }

    /// 在滚的地方（选区里从左往右的 0...1）
    private var autoX: CGFloat = 0.5
    /// 看起来到底了几次（到 3 次才真的停）
    private var endChecks = 0
    /// 停住看一下：到这个时间再接着滚（页面弹回来、可能在加载更多）
    private var holdUntil: CFTimeInterval?

    /// 截了一帧：看是不是到底了。
    /// 到底的样子：滚轮一直在发，画面却不怎么挪（停住了，或者被往上拉过头、有阻力地慢慢挪）。只看指针下面那一栏。
    /// 看起来到底了不马上停：先停住 0.6 秒（页面弹回来，网页可能在加载更多），再接着滚；连着 3 次都滚不动才真的停
    private func autoScrollCheck(farthest: Int?, rejected: Bool, grew: Bool) {
        guard let a = autoScroller else { return }
        let now = CACurrentMediaTime()
        if rejected { a.slowDown() }
        // 停住在看：到时间了接着滚
        if let h = holdUntil {
            guard now >= h else { return }
            holdUntil = nil
            autoSamples = []
            lastGrowth = now
            a.resume()
            return
        }
        // 指针下面那一栏：还没认出来就先不判断（还在看是不是在滚）
        guard let farthest else {
            autoStopNote = "noLane x=\(String(format: "%.2f", autoX))"
            if grew { lastGrowth = now }
            if now - lastGrowth > 2.5 { endAutoScroll(a, note: "Nothing to scroll here") }
            return
        }
        // 这一栏最远滚到过哪（只会变大）：往上拉过头、回弹、对不上的帧都不会让它乱跳
        let moved = CGFloat(farthest) / scrollScale
        if autoBest == nil { autoBest = moved }
        if moved > (autoBest ?? 0) + 1 { autoBest = moved; lastGrowth = now }
        // 兜底：这一栏好一阵子没再往下（一直对不上、到底了却判断不出来）
        if now - lastGrowth > 2 { autoStopNote = "stalled"; endAutoScroll(a, note: "Reached the end"); return }
        autoSamples.append((now, a.sentTotal, moved))
        // 拿离现在 0.45 秒以上的样本里最近的那个比（截图慢、两帧隔得远时也一定有得比）
        while autoSamples.count > 1, now - autoSamples[1].t >= 0.45 { autoSamples.removeFirst() }
        guard let old = autoSamples.first, now - old.t >= 0.45 else { return }
        let sent = a.sentTotal - old.sent, dm = moved - old.moved
        guard sent > 60 else { return }
        let ratio = dm / sent
        // 平常每发 1pt 画面挪多少（每个 app 不一样，有的会放大缩小）：滚得顺的时候慢慢学
        if ratio > 0.5 * autoNormal { autoNormal = autoNormal * 0.8 + min(ratio, 3) * 0.2 }
        // 到底：挪的不到平常的一半（停住了，或者被往上拉过头、有阻力地慢慢挪）
        if ratio < 0.5 * autoNormal {
            endChecks += 1
            autoStopNote = "end#\(endChecks) sent=\(Int(sent)) moved=\(Int(dm)) normal=\(String(format: "%.2f", autoNormal))"
            if endChecks >= 3 { endAutoScroll(a, note: "Reached the end"); return }
            // 先停住 0.6 秒（页面弹回来，网页可能在加载更多），再接着滚
            a.hold()
            holdUntil = now + 0.6
            autoSamples = []
        } else if ratio > 0.8 * autoNormal {
            // 又滚得动了（加载出了更多）：重新数
            endChecks = 0
        }
    }
    /// 这一栏最远到过哪（pt）、平常每发 1pt 画面挪多少
    private var autoBest: CGFloat?
    private var autoNormal: CGFloat = 1

    /// 自动滚动到头了：马上停，按钮、字变回来
    private func endAutoScroll(_ a: AutoScroller, note: String) {
        a.stop(immediately: true)
        autoScroller = nil
        autoEndedAt = CACurrentMediaTime()
        let bar = scrollBarPanel?.content as? ScrollBar
        bar?.setAuto(false)
        autoNote = note
        bar?.setState(.done(note))
    }

    private func stopAutoScroll() {
        autoScroller?.stop(immediately: true)
        autoScroller = nil
    }

    private func stopScrolling() {
        stopAutoScroll()
        scrollTimer?.invalidate()
        scrollTimer = nil
        HotKeyCenter.shared.register(id: AppSettings.HotKeyID.captureEscape.rawValue, nil) {}
        scrollBarPanel?.dismiss()
        scrollPreviewPanel?.dismiss()
        scrollBarPanel = nil
        scrollPreviewPanel = nil
    }

    /// Esc / Cancel：回到框好的样子
    func cancelScrolling() {
        guard stitcher != nil, let v = scrollView else { return }
        stopScrolling()
        stitcher = nil
        scrollView = nil
        v.window?.ignoresMouseEvents = false
        v.setScrolling(false)
        v.window?.makeKeyAndOrderFront(nil)
        v.window?.makeFirstResponder(v)
        // 滚过了，画面和开始时不一样：冻结的话重新截一次现在的样子（看到的就是会截到的），窗口那张也不能再用
        if let id = v.selectedWindowID { frozenWindows[id] = nil }
        if frozenMode { takeSnapshot(on: v) } else { showActionBar(on: v) }
    }

    /// Done / 回车：拼好的整张交出去（和普通截图一样挂上截图架）
    func finishScrolling() {
        guard let st = stitcher, let v = scrollView, let win = v.window, let sel = v.selection else { return }
        // 自动滚动还在滚（可能正往上拉过头）：先停下，等页面弹回来再出图
        if let a = autoScroller { endAutoScroll(a, note: "Finishing") }
        // 自动滚动刚到底：页面还在弹回来，再截几帧等它停稳（不然最后一帧是拉过头的样子，下面一片空白）
        if let e = autoEndedAt, CACurrentMediaTime() - e < 0.7 {
            guard !finishPending else { return }
            finishPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (0.7 - (CACurrentMediaTime() - e))) { [weak self] in
                guard let self else { return }
                self.finishPending = false
                self.autoEndedAt = nil
                self.finishScrolling()
            }
            return
        }
        stopScrolling()
        stitcher = nil
        scrollView = nil
        performing = true
        let scale = win.backingScaleFactor
        let screenRect = sel.offsetBy(dx: win.frame.minX, dy: win.frame.minY)
        let kind = v.kind, corner = v.selectedWindow?.corner ?? 0
        Task { @MainActor [weak self] in
            // 最后再等正在截的那一帧；出图排在拼图那条线上已经排着的帧后面（一帧都不漏）
            while self?.scrollBusy == true { try? await Task.sleep(nanoseconds: 20_000_000) }
            guard let self else { return }
            let q = self.stitchQueue
            let out: CGImage? = await withCheckedContinuation { c in q.async { c.resume(returning: UnsafeImage(st.image())) } }.image
            guard let img = out, let screen = win.screen else { NSSound.beep(); self.finish(animated: true); return }
            // 拼好的长图不直接交出去：在屏幕中间接着看、画、加背景，按 Capture 才存（Esc 不要）
            // 截的是窗口：出图和截窗口一样（窗口圆角、窗口影子，按设置，按住 ⌥ 反过来）
            let look = kind == .window ? ImageEditor.WindowLook(corner: corner,
                                                                 shadow: self.settings.windowShadow != NSEvent.modifierFlags.contains(.option)) : nil
            let editor = ImageEditor(mode: .review, image: img, hdr: nil, scale: scale, screen: screen,
                                     headroom: self.screenHeadroom, windowLook: look, settings: self.settings)
            let deliver = self.onCaptured, target = self.flightTarget, app = self.previousApp
            editor.flightTarget = target
            editor.onCapture = { c, o in deliver?(c, o) }
            // 关掉后焦点还给截图前的 app
            editor.returnApp = app
            self.delivered = true
            self.handedOff = true
            self.finish(animated: true)
            editor.present(from: screenRect)
        }
    }

    func debugScrollTip() { (scrollBarPanel?.content as? ScrollBar)?.debugShowAutoTip() }
    var debugScroll: String { (stitcher.map { st in stitchQueue.sync { st.debugText } } ?? "not scrolling") + " auto=[\(lastAuto?.debug ?? "-")] stopNote=\(autoStopNote) bar=\((scrollBarPanel?.content as? ScrollBar).map { "\($0.state)" } ?? "-")" }
    private weak var lastAuto: AutoScroller?
    private var autoStopNote = "-"

    // MARK: 扫描（Scan 模式）

    /// 认出来的码和现在显示的是第几个
    private var scanCodes: [ScannedCode] = []
    private var scanIndex = 0
    /// 每次扫描一个号：中途重新框选、取消的话，旧的结果回来了也不用
    private var scanToken = 0
    /// 交给别的 app 了（打开网页、通讯录）：关掉时不要把焦点抢回原来的 app
    private var handedOff = false
    private weak var scanView: CaptureOverlayView?
    var scanBar: ScanResultBar? { scanView?.scanBar }

    /// Scan 模式：同时找二维码（条形码）和认文字，都在本机、不用联网。
    /// 有码：光和亮的那块弹到码上，下面出一根小条，按了才打开。没有码：文字复制到剪贴板，关掉截图界面。
    /// 光至少亮 0.3 秒，太快认完不会一闪而过
    private func scan(on v: CaptureOverlayView) {
        guard !performing, let rect = v.selection, let win = v.window,
              let img = v.kind == .screen ? v.frozen : CaptureOutput.crop(v.frozen, rect: rect, viewSize: v.bounds.size) else { return }
        performing = true
        scanToken += 1
        let token = scanToken
        scanView = v
        let screenRect = rect.offsetBy(dx: win.frame.minX, dy: win.frame.minY)
        // 提示放在选区下面；下面放不下就放上面；整个屏幕放在屏幕中间
        let below = CGPoint(x: screenRect.midX, y: screenRect.minY - 30)
        let toastAt = v.kind == .screen ? CGPoint(x: screenRect.midX, y: screenRect.midY)
            : below.y > win.frame.minY + 40 ? below : CGPoint(x: screenRect.midX, y: screenRect.maxY + 30)
        v.beginScan()
        let started = Date()
        var finished = false
        // 系统偶尔要重新加载识别模型，会慢很多：超过 1.5 秒就说一声，Esc 可以取消
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !finished, !self.ending, self.scanToken == token else { return }
            CaptureToast.show("Scanning…", symbol: "qrcode.viewfinder", at: toastAt)
            self.scanningToastUp = true
        }
        let image = img
        let size = rect.size
        let text = Task { @MainActor () -> String in
            await withCheckedContinuation { cont in
                TextRecognizer.recognize(image: image) { cont.resume(returning: (try? $0.get()) ?? "") }
            }
        }
        Task { @MainActor [weak self, weak v] in
            let codes = await ScannedCode.detect(in: image, size: size)
            let recognized = codes.isEmpty ? await text.value : ""
            let hold = 0.3
            let wait = hold - Date().timeIntervalSince(started)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            finished = true
            self?.scanningToastUp = false
            guard let self, v != nil, !self.ending, self.scanToken == token else { return }
            self.lastRecognizeSeconds = Date().timeIntervalSince(started)
            if !codes.isEmpty {
                CaptureToast.dismiss()
                self.scanCodes = codes.map { var c = $0; c.rect = c.rect.offsetBy(dx: rect.minX, dy: rect.minY); return c }
                self.lastRecognized = codes.map(\.payload).joined(separator: "\n")
                self.performing = false
                self.showCode(0)
                return
            }
            let t = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
            self.lastRecognized = t
            guard !t.isEmpty else {
                // 什么都没有：留在截图界面，可以重新框
                CaptureToast.show("No text or code found", symbol: "exclamationmark.circle.fill", at: toastAt)
                self.performing = false
                self.clearAllSelections()
                return
            }
            ScanActions.copy(t)
            let n = t.split(separator: "\n").count
            // 设置成不保留换行时接成了一段，就不说几行了
            let msg = !self.settings.scanKeepLineBreaks ? "Copied text" : n == 1 ? "Copied 1 line of text" : "Copied \(n) lines of text"
            CaptureToast.show(msg, at: toastAt)
            self.finish(animated: true)
        }
    }

    /// 显示第 i 个码：光弹过去，小条换成这个码的
    private func showCode(_ i: Int) {
        guard let v = scanView, scanCodes.indices.contains(i) else { return }
        scanIndex = i
        let c = scanCodes[i]
        // 码外面留一点边，光不压在码上
        let pad = max(4, min(c.rect.width, c.rect.height) * 0.06)
        let r = c.rect.insetBy(dx: -pad, dy: -pad).intersection(v.bounds.insetBy(dx: 2, dy: 2))
        v.focusScan(on: r)
        let bar = ScanResultBar(code: c, index: i, count: scanCodes.count)
        bar.onCancel = { [weak self] in self?.clearAllSelections() }
        bar.onPrimary = { [weak self] in self?.runScanAction() }
        bar.onCopy = { ScanActions.copy($0) }
        bar.onNext = { [weak self] in self?.nextCode() }
        v.show(scanBar: bar, for: r)
    }

    private func nextCode() {
        guard scanCodes.count > 1 else { return }
        showCode((scanIndex + 1) % scanCodes.count)
    }

    /// 小条上的主按钮（和回车）
    private func runScanAction() {
        guard scanCodes.indices.contains(scanIndex), let bar = scanBar else { return }
        let c = scanCodes[scanIndex]
        let at = bar.window.map { $0.convertToScreen(bar.convert(bar.bounds, to: nil)) }.map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? NSEvent.mouseLocation
        switch c.kind {
        case .wifi(let ssid, let pw, _):
            CaptureToast.show("Joining \(ssid)…", symbol: "wifi", at: at, hold: 30)
            finish(animated: true)
            WiFiJoin.join(ssid: ssid, password: pw) { outcome in
                switch outcome {
                case .joined:
                    CaptureToast.show("Connected to \(ssid)", at: at)
                case .failed:
                    // 连不上（密码错、不在附近）：密码放进剪贴板，自己在 Wi‑Fi 菜单里连
                    if let pw { ScanActions.copy(pw) }
                    CaptureToast.show(pw == nil ? "Couldn’t join \(ssid)" : "Couldn’t join. Password copied.",
                                      symbol: "exclamationmark.circle.fill", at: at, hold: 2.4)
                }
            }
        case .text:
            ScanActions.copy(c.copyText)
            CaptureToast.show("Copied", at: at)
            finish(animated: true)
        default:
            guard c.action != nil else {
                ScanActions.copy(c.copyText)
                CaptureToast.show("Copied", at: at)
                finish(animated: true)
                return
            }
            handedOff = true
            finish(animated: true)
            if !ScanActions.perform(c) { handedOff = false; NSSound.beep() }
        }
    }

    /// 结果条收起、光淡掉（重新框选、Esc、点了 ⓧ）
    private func endScan(restore: Bool, keepGlow: Bool = false) {
        scanToken += 1
        scanCodes = []
        for w in overlays { w.overlayView.endScan(restore: restore, keepGlow: keepGlow && w.overlayView === scanView) }
        if mode == .text { performing = false }
    }

    /// 调试用：扫描的结果条
    var debugScan: String {
        guard let b = scanBar else { return "scan=none glow=\(scanView?.isScanning ?? false)" }
        let r = scanCodes[scanIndex].rect
        return "scan=\(scanIndex + 1)/\(scanCodes.count) code=\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width))x\(Int(r.height)) \(b.debugText) bar=\(Int(b.frame.minX)),\(Int(b.frame.minY)),\(Int(b.frame.width))x\(Int(b.frame.height))"
    }

    /// 调试用：最近一次识别出来的文字、花了多久
    private(set) var lastRecognized: String?
    private(set) var lastRecognizeSeconds: Double?

    /// 提示放在操作条原来的位置（屏幕坐标）
    private(set) var lastActionBarCenter: CGPoint?

    // MARK: 模式和按键

    func pick(_ m: CaptureMode) {
        if m == .screen { selectScreenUnderMouse(); return }
        mode = m
        if m != .text { settings.captureMode = m }
        bar?.setMode(m)
        for w in overlays { w.overlayView.modeChanged() }
    }

    /// 选中鼠标所在那块屏幕
    private func selectScreenUnderMouse() {
        let mouse = NSEvent.mouseLocation
        let w = overlays.first { $0.frame.contains(mouse) } ?? overlays.first { $0.overlayView.bar != nil } ?? overlays.first
        w?.overlayView.selectScreen()
    }

    /// 覆盖窗口收到的按键都交给这里
    func keyDown(_ event: NSEvent) -> Bool {
        // 正在出图或识别：只有 Esc 有用（直接关掉）
        // 扫描出了码：回车 = 小条上的主按钮，⌘C 复制，Tab 下一个码，Esc 退回去重新框
        if let bar = scanBar, !performing {
            let cmd = event.modifierFlags.contains(.command)
            switch event.keyCode {
            case 36 where !cmd, 76 where !cmd: runScanAction(); return true
            case 48: if scanCodes.count > 1 { nextCode() } else { NSSound.beep() }; return true
            case 53: clearAllSelections(); return true
            default:
                if cmd, event.charactersIgnoringModifiers?.lowercased() == "c" { bar.copyFromKeyboard(); return true }
            }
        }
        if stitcher != nil {
            if ["a", " "].contains(event.charactersIgnoringModifiers?.lowercased() ?? ""), event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                toggleAutoScroll()
                return true
            }
            if event.keyCode == 53 { cancelScrolling() }
            if event.keyCode == 36 || event.keyCode == 76 { finishScrolling() }
            return true
        }
        if performing { if event.keyCode == 53 { cancel() }; return true }
        if countingDown { if event.keyCode == 53 { cancelCountdown() }; return true }
        // Esc 一次退一步：正拿着画画的工具先放下；有选区先取消选区，没有就关掉
        if event.keyCode == 53 {
            if let a = activeOverlay?.annotator, a.selected != nil { a.select(nil); return true }
            if actionBar?.tool != nil { selectTool(nil); return true }
            if let b = beautyBar, b.superview != nil, !b.isHidden { hideBeautyBar(); return true }
            if hasSelection { clearAllSelections() } else { cancel() }
            return true
        }
        if hasSelection {
            let cmd = event.modifierFlags.contains(.command)
            if cmd, event.charactersIgnoringModifiers?.lowercased() == "z" {
                if event.modifierFlags.contains(.shift) { activeOverlay?.annotator.redo() } else { activeOverlay?.annotator.undo() }
                return true
            }
            // Delete：删掉选中的那个
            if (event.keyCode == 51 || event.keyCode == 117), let a = activeOverlay?.annotator, a.selected != nil {
                a.deleteSelected()
                return true
            }
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               event.charactersIgnoringModifiers?.lowercased() == "s", actionBar?.superview != nil, mode != .text {
                startScrolling()
                return true
            }
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               event.charactersIgnoringModifiers?.lowercased() == "g", actionBar?.superview != nil {
                toggleBeauty()
                return true
            }
            // 单个字母换工具（再按一次放下）：A 箭头、R 框、P 笔、T 文字、H 荧光笔、B 打码、N 编号
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               let ch = event.charactersIgnoringModifiers?.lowercased(), let t = Self.toolKeys[ch],
               actionBar?.superview != nil {
                selectTool(actionBar?.tool == t ? nil : t)
                return true
            }
            if (event.keyCode == 36 || event.keyCode == 76) && !cmd {
                if let ab = actionBar { perform(ab.primaryOutput) }
                return true
            }
            if cmd, event.charactersIgnoringModifiers?.lowercased() == "c" { perform(.saveAndCopy); return true }
            if (123...126).contains(event.keyCode) {
                // 窗口、整个屏幕不能微调，也不要发出提示音
                for w in overlays { _ = w.overlayView.nudge(event) }
                return true
            }
            return false
        }
        // 窗口模式、还没选中：回车直接截鼠标停着的窗口（不用先点）；Tab、方向键换窗口
        // 用鼠标所在那块屏幕（多屏时键盘焦点可能还在主屏上，以前在副屏按回车只会"咚"一声）
        let underMouse = overlays.first { $0.frame.contains(NSEvent.mouseLocation) }?.overlayView
        if mode == .window, let v = underMouse ?? keyOverlayView, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            if event.keyCode == 36 || event.keyCode == 76 {
                guard let w = v.hover else { NSSound.beep(); return true }
                v.selectWindow(w)
                // 冻结着的话马上截；不冻结的要先截这一刻，截好会出操作条，再按一次回车
                if frozenMode, let ab = actionBar { perform(ab.primaryOutput) }
                return true
            }
            if event.keyCode == 48 || (123...126).contains(event.keyCode) {
                return v.keyboardHover(event.keyCode, backwards: event.modifierFlags.contains(.shift))
            }
        }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let ch = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let map: [String: CaptureMode] = ["f": .screen, "w": .window, "a": .area, "s": .text, "t": .text]
        if let m = map[ch] { pick(m); return true }
        // R：恢复上次的选区
        if ch == "r" { if !restoreLastSelection() { NSSound.beep() }; return true }
        // C：放大镜开着时，拷贝鼠标下面那个像素的颜色
        if ch == "c", let v = overlays.map(\.overlayView).first(where: { $0.loupeHex != nil }), let hex = v.loupeHex {
            CaptureOutput.pasteboard.clearContents()
            CaptureOutput.pasteboard.setString(hex, forType: .string)
            let m = NSEvent.mouseLocation
            CaptureToast.show("Copied \(hex)", at: CGPoint(x: m.x, y: m.y - 70))
            return true
        }
        // 空格：在区域和窗口之间切换
        if event.keyCode == 49, mode == .area || mode == .window { pick(mode == .area ? .window : .area); return true }
        return false
    }

    // MARK: Options 菜单

    /// 把冻结那一刻的鼠标指针画到这块屏幕的图上（图和图一样的格式，HDR 图也能画）
    /// area：这张图在截图界面里占的那块（截图界面坐标）；默认整块屏幕
    private func compositeCursor(onto img: CGImage, in v: CaptureOverlayView, area: CGRect? = nil) -> CGImage? {
        let R = area ?? v.bounds
        guard let c = freezeCursor, let win = v.window, R.width > 0, let cs = img.colorSpace else { return nil }
        let k = CGFloat(img.width) / R.width
        let lx = c.location.x - win.frame.minX, ly = c.location.y - win.frame.minY
        guard R.contains(CGPoint(x: lx, y: ly)) else { return nil }
        let r = CGRect(x: (lx - R.minX - c.hotSpot.x) * k, y: (ly - R.minY - (c.size.height - c.hotSpot.y)) * k,
                       width: c.size.width * k, height: c.size.height * k)
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: img.bitsPerComponent,
                                  bytesPerRow: 0, space: cs, bitmapInfo: img.bitmapInfo.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        ctx.draw(c.image, in: r)
        return ctx.makeImage()
    }

    private func startLiveTimer() {
        guard liveTimer == nil else { return }
        liveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for w in self.overlays where w.overlayView.isLive && w.overlayView.selection == nil {
                    let v = w.overlayView
                    v.updateWindows(ScreenWindows.list(for: v.screenRef))
                    self.verifyWindows(on: v)
                }
            }
        }
    }

    /// 截图途中在 Options 里改了计时、冻结：当场换，不用等下一次（和系统 ⇧⌘5 一样）。
    /// 设了计时 → 解冻（计时是为了数完截那一刻，冻着的画面没法计时）；关掉计时、开着冻结 → 马上把现在的屏幕冻住
    private func applyOptionChanges() {
        let wantFrozen = settings.freezeScreen && settings.captureTimer == 0
        if wantFrozen != frozenMode, !performing, !countingDown {
            frozenMode = wantFrozen
            if wantFrozen {
                for w in overlays where w.overlayView.isLive { freezeNow(w.overlayView) }
            } else {
                // 解冻：冻结时截的窗口图不能再用（数完计时要截那一刻的），窗口列表也要接着按实时的更新
                frozenWindows = [:]
                for w in overlays { w.overlayView.setLive(true) }
                startLiveTimer()
            }
        }
        if let v = activeOverlay, let ab = actionBar, ab.isShown {
            ab.setTimer(v.isLive && v.snapshotStale ? settings.captureTimer : 0)
            ab.refresh()
            v.layoutActionBar()
        }
    }

    /// 把这块屏幕现在的样子冻住（不管有没有选区）
    private func freezeNow(_ view: CaptureOverlayView) {
        guard let screen = view.window?.screen else { return }
        let pointer = settings.showPointer && mode != .text
        let hdr = wantsHDR
        recordCursor()
        Task { @MainActor in
            guard let shot = await Self.snapshot(screen, pointer: pointer, hdr: hdr), !self.ending, self.frozenMode else { return }
            view.setSnapshot(shot.image, output: shot.withPointer, hdr: shot.hdr, outputHDR: shot.withPointerHDR)
            view.setLive(false)
        }
    }

    private func showOptions(from button: BarButton) {
        let menu = CaptureOptionsMenu(settings: settings) { [weak self] in
            self?.cancel()
            self?.onOpenSettings?()
        }.build()
        button.isSelected = true
        menuOpen = true
        // 菜单右边和按钮右边对齐，整体放在按钮上方
        let size = menu.size
        let origin = NSPoint(x: button.bounds.maxX - size.width + 6, y: button.bounds.maxY + size.height + 12)
        menu.popUp(positioning: nil, at: origin, in: button)
        menuOpen = false
        button.isSelected = false
        applyOptionChanges()
    }

    /// 修饰键变了（现在没有用到，留着给以后的标注工具）
    func modifiersChanged(_ flags: NSEvent.ModifierFlags) {}

    var debugState: String {
        let ab = actionBar.map { "action=\($0.isShown ? "shown" : "hidden") \($0.debugText) at=\($0.superview == nil ? "none" : "\(Int($0.frame.minX)),\(Int($0.frame.minY)),\(Int($0.frame.width))")" } ?? "action=none"
        let fw = "frozenWindows=\(frozenWindows.count)/\(frozenWindows.values.reduce(0) { $0 + $1.bytes } / 1_000_000)MB/\(Int(freezeWindowsSeconds * 1000))ms key=\(tookKeyFocus)"
        return "\(fw) abort=\(abortReason ?? "none") active=\(NSApp.isActive) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") mode=\(mode) frozenMode=\(frozenMode) countdown=\(countingDown) bar=\(bar?.isShown == true ? "shown" : "hidden") \(ab) "
            + overlays.map { $0.overlayView.debugState }.joined(separator: " | ")
    }

    // MARK: 意外情况

    /// 截图界面开着时，下面这些情况一出现画面就不对了（冻结的是旧的），或者截图界面会挡住用户，直接关掉：
    /// - Mission Control、应用程序窗口（四指上滑、下滑、F3）
    /// - 换了桌面（四指左右滑、⌃←→）
    /// - 用户切到了别的 app（⌘Tab、点程序坞、聚焦搜索）。倒计时中点到下面的 app 是正常的，不算
    /// - 睡眠、锁屏、合盖、插拔显示器、改分辨率
    /// 显示器的排布：哪几块、在哪、多大、几倍像素
    private static func displayLayout() -> [String] {
        NSScreen.screens.map { "\($0.displayID ?? 0)|\($0.frame)|\($0.backingScaleFactor)" }
    }

    private func installGuards() {
        let ws = NSWorkspace.shared.notificationCenter, nc = NotificationCenter.default
        func on(_ c: NotificationCenter, _ n: Notification.Name, _ why: String, when ok: @escaping @MainActor () -> Bool = { true }) {
            guardObservers.append((c, c.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if ok() { self?.abort(why) } }
            }))
        }
        on(ws, NSWorkspace.activeSpaceDidChangeNotification, "space changed")
        on(ws, NSWorkspace.willSleepNotification, "sleep")
        on(ws, NSWorkspace.screensDidSleepNotification, "screens slept")
        on(ws, NSWorkspace.sessionDidResignActiveNotification, "session locked")
        // 插拔显示器、改分辨率、改缩放才算。屏幕打开或关掉 HDR（亮度余量变了）也会发这个通知，那个不算：
        // 截图界面的 HDR 橙线一出来，屏幕就会把余量开大
        let layout = Self.displayLayout()
        on(nc, NSApplication.didChangeScreenParametersNotification, "displays changed", when: { Self.displayLayout() != layout })
        // 别的 app 变成当前 app（⌘Tab、点程序坞、聚焦搜索……）。不一定收得到"失去焦点"：QuickCap 可能本来就没变成当前 app
        guardObservers.append((ws, ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, app != NSRunningApplication.current else { return }
                // 上一次截图关掉时把焦点还给了这个 app，激活通知可能晚到，刚好落在这次打开之后：不算用户切换
                if let r = Self.lastRestore, r.pid == app?.processIdentifier, Date().timeIntervalSince(r.at) < 2 { return }
                // 刚打开时系统还在切换焦点；倒计时（可以点下面的 app）、Options 菜单、正在出图、
                // 滚动截图（截图界面点穿，用户会点下面那个 app、系统也会发滚轮）时都是正常的
                guard !self.countingDown, !self.menuOpen, !self.performing, self.stitcher == nil, Date().timeIntervalSince(self.shownAt) > 0.4 else { return }
                self.abort("switched to \(app?.localizedName ?? "another app")")
            }
        }))
        guardTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // 系统界面（Mission Control、启动台……）盖到了截图界面上面
                if ScreenWindows.somethingCoversOverlay(Set(self.overlays.map { CGWindowID($0.windowNumber) })) {
                    self.abort("covered by system ui")
                }
            }
        }
    }

    private func removeGuards() {
        for (c, o) in guardObservers { c.removeObserver(o) }
        guardObservers = []
        guardTimer?.invalidate()
        guardTimer = nil
    }

    /// 意外情况：不截，马上关掉（不做淡出，免得挡着用户）
    private func abort(_ why: String) {
        guard !ending else { return }
        abortReason = why
        pending = nil
        finish(animated: false)
    }

    // MARK: 结束

    func cancel() { finish(animated: true) }

    /// 截图界面开着时又按了快捷键：同一个就关掉；Text 和普通截图之间就换模式
    func hotkeyPressed(mode m: CaptureMode?) {
        let target = m ?? (mode == .text ? (settings.captureMode == .window ? .window : .area) : mode)
        if target == mode || performing || countingDown { cancel(); return }
        clearAllSelections()
        pick(target)
    }

    private func finish(animated: Bool = false) {
        guard !ending else { return }
        ending = true
        releaseEarlyKeys()
        removeGuards()
        liveTimer?.invalidate()
        liveTimer = nil
        let windows = overlays
        // 关掉：倒数时让开的暗色、框、光不用再淡回来（窗口正在淡出，淡回来会闪一下）
        if countingDown { endCountdown(on: activeOverlay, restore: false) }
        if scanningToastUp { CaptureToast.dismiss(); scanningToastUp = false }
        let done = { [weak self] in
            for w in windows { w.orderOut(nil) }
            guard let self else { return }
            self.overlays = []
            self.frozenWindows = [:]
            self.bar = nil
            self.actionBar = nil
            if let (img, out) = self.pending { self.pending = nil; self.onCaptured?(img, out) }
            if let a = self.activity { ProcessInfo.processInfo.endActivity(a) }
            self.activity = nil
            // 把焦点还给截图前的 app（倒计时时用户自己点到别的 app 了，就不抢回来）
            if NSApp.isActive, !self.handedOff, let app = self.previousApp, !app.isTerminated {
                Self.lastRestore = (app.processIdentifier, Date())
                app.activate()
            }
            self.onEnd?()
        }
        guard animated, !windows.isEmpty else { done(); return }
        // 和打开反过来：选择条往下收、高亮先淡掉，整个界面跟着淡出（比打开快一点）
        bar?.animateOut(duration: 0.14, offsetY: 12)
        for w in windows { w.overlayView.fadeChromeForClose() }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for w in windows { w.animator().alphaValue = 0 }
        }, completionHandler: { MainActor.assumeIsolated { done() } })
    }

    private func showPermissionAlert() {
        let a = NSAlert()
        let reopen = ScreenAccess.state == .needsReopen
        if reopen {
            a.messageText = "Reopen QuickCap to finish turning on Screen Recording"
            a.informativeText = "macOS applies the change the next time QuickCap opens."
            a.addButton(withTitle: "Reopen QuickCap")
        } else {
            a.messageText = "QuickCap needs Screen Recording access"
            a.informativeText = "Turn on QuickCap in System Settings → Privacy & Security → Screen & System Audio Recording, then try again."
            a.addButton(withTitle: "Open System Settings")
        }
        a.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if reopen { ScreenAccess.relaunch() } else { ScreenAccess.openSystemSettings() }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}

/// Options 菜单：只放每次截图可能会改的选项。保存位置、格式、HDR 在设置里。
@MainActor
struct CaptureOptionsMenu {
    let settings: AppSettings
    let openSettings: () -> Void

    func build() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(.sectionHeader(title: "Timer"))
        for (v, t) in [(0, "None"), (3, "3 Seconds"), (5, "5 Seconds"), (10, "10 Seconds")] {
            m.addItem(item(t, on: settings.captureTimer == v) { settings.captureTimer = v })
        }
        m.addItem(.separator())
        m.addItem(item("Snap to Edges", on: settings.snapToEdges) { settings.snapToEdges.toggle() })
        m.addItem(item("Show Magnifier", on: settings.showMagnifier) { settings.showMagnifier.toggle() })
        // 计时的时候屏幕要保持实时，不能冻结
        let freeze = item("Freeze Screen", on: settings.freezeScreen && settings.captureTimer == 0) { settings.freezeScreen.toggle() }
        freeze.isEnabled = settings.captureTimer == 0
        m.addItem(freeze)
        m.addItem(.separator())
        m.addItem(item("Show Mouse Pointer", on: settings.showPointer) { settings.showPointer.toggle() })
        m.addItem(item("Remember Last Selection", on: settings.rememberSelection) { settings.rememberSelection.toggle() })
        m.addItem(item("Wallpaper Behind Windows", on: settings.windowWallpaper) { settings.windowWallpaper.toggle() })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("Capture Settings…", handler: openSettings))
        return m
    }

    private func item(_ title: String, on: Bool, _ action: @escaping () -> Void) -> NSMenuItem {
        let i = ClosureMenuItem(title, handler: action)
        i.state = on ? .on : .off
        return i
    }
}
