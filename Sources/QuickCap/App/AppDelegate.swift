import AppKit
import ScreenCaptureKit
import Combine
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var captureItem: NSMenuItem!
    private var captureTextItem: NSMenuItem!
    private var shelf: ShelfController!
    private let settingsWindow = SettingsWindowController()
    private let welcome = WelcomeWindowController()
    /// 悬挂架显示哪个文件夹的截图（调试时可以换成测试文件夹）
    lazy var shelfFolder = CaptureStore.folder
    /// 设置里正在把截图搬到新文件夹
    private var movingFolder = false
    private var subscriptions: Set<AnyCancellable> = []
    private var sampleIndex = 0
    private let settings = AppSettings.shared
    private var capture: CaptureSession?

    /// 已经有一个 QuickCap 在跑时，新开的通知它打开设置，自己退出（两个一起跑会抢快捷键、两个截图架）
    private static let reopenNote = Notification.Name("io.github.aaronkhoolb.QuickCap.reopen")

    private func handOffToRunningInstance() -> Bool {
        guard !DebugOptions.isDebugRun, let id = Bundle.main.bundleIdentifier else { return false }
        let me = NSRunningApplication.current.processIdentifier
        guard NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .contains(where: { $0.processIdentifier != me && !$0.isTerminated }) else { return false }
        DistributedNotificationCenter.default().postNotificationName(Self.reopenNote, object: nil, userInfo: nil, deliverImmediately: true)
        NSApp.terminate(nil)
        return true
    }

    /// 在访达里再双击一次（已经在跑）：打开设置，不然什么都看不到
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openSettings() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        WelcomeWindowController.appTerminating = true
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        PinWindow.flushState()
        ShelfTextIndex.shared.flush()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if handOffToRunningInstance() { return }
        DistributedNotificationCenter.default().addObserver(forName: Self.reopenNote, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.openSettings() }
        }
        // 以前自己存的卡片缩略图不要了（现在用系统的，和访达共用）
        DispatchQueue.global(qos: .utility).async { ShelfThumbnails.removeOldDiskCache() }
        DebugOptions.configureBeforeLaunch()
        if let folder = DebugOptions.debugShelfFolder { shelfFolder = folder }
        makeShelf()
        buildStatusItem()
        observeSettings()
        TextRecognizer.warmUp()
        ShelfDragWriter.clearCache()
        DebugOptions.apply(to: self)
        welcome.onOpenSettings = { [weak self] in self?.openSettings() }
        // 欢迎页走完之前截图架不出来（鼠标碰到屏幕边也不出来）
        welcome.onVisibleChange = { [weak self] showing in self?.shelf.setCaptureHidden(showing) }
        PinWindow.onAnnotate = { [weak self] in self?.annotate($0) }
        // 上次钉着的图放回原处（调试运行不放，免得测试时满屏钉图）
        if !DebugOptions.isDebugRun { PinWindow.restore() }
        // 第一次打开（或者上次看到一半、为了权限重新打开了）
        // 欢迎页看过了但权限没了（新版本系统要重新给、用户自己关掉）：只放权限那几页
        if !DebugOptions.isDebugRun {
            if WelcomeWindowController.shouldShow { welcome.show() }
            else if WelcomeWindowController.missingPermissions { welcome.showPermissions() }
        }
        // 第一次打开：默认开机启动（只设一次，之后用户在设置里关掉就不再动）
        if !DebugOptions.isDebugRun, !UserDefaults.standard.bool(forKey: "loginItemDefaulted") {
            // 从 DMG、下载文件夹直接打开时（系统挪到随机路径运行）先不注册，挪进“应用程序”后再来
            let inApps = Bundle.main.bundlePath.hasPrefix("/Applications/")
                || Bundle.main.bundlePath.hasPrefix(NSHomeDirectory() + "/Applications/")
            if inApps {
                // 注册成功（或本来就开着）才记下，失败下次启动再试
                if SMAppService.mainApp.status == .enabled || (try? SMAppService.mainApp.register()) != nil
                    || SMAppService.mainApp.status == .requiresApproval {
                    UserDefaults.standard.set(true, forKey: "loginItemDefaulted")
                }
            }
        }
    }

    /// 调试用：打开欢迎窗口的某一页
    func showWelcome(page: WelcomeModel.Page?) { welcome.show(page: page) }
    var welcomeForDebug: WelcomeWindowController { welcome }

    private func makeShelf() {
        shelf = ShelfController(side: settings.side, revealTrigger: settings.revealTrigger, folder: shelfFolder)
        shelf.onActivate = { NSWorkspace.shared.open($0.url) }
        // 欢迎页开着时换了截图架的设置（比如在设置里换了边）：新的截图架也先藏着
        if welcome.isShowing { shelf.setCaptureHidden(true) }
        shelf.onEdit = { [weak self] in self?.edit($0) }
        shelf.menuProvider = { [weak self] in self?.menu(for: $0) }
        shelf.onAction = { [weak self] action, item in self?.perform(action, on: item) }
        // 拖把手换边：只改设置，悬挂架由下面 observeSettings 的订阅去换
        shelf.onSideChanged = { [weak self] side in self?.settings.side = side }
        shelf.displayDuration = settings.autoHideDelay > 0 ? settings.autoHideDelay : nil
    }

    /// 调试用：换成显示另一个文件夹（不动设置）
    func debugSwitchShelf(to url: URL) {
        shelf.shutDown()
        shelfFolder = url
        makeShelf()
    }

    /// 设置里换文件夹并把旧截图搬过去。先停掉旧截图架：不然文件一搬走它就重扫，
    /// 把置顶记录里搬走的那几张当成"文件没了"清掉，搬完再改路径就来不及了。
    /// 搬完：置顶、认过的字换成新路径，切到新文件夹，截图架重建。done 拿到没搬成的张数
    func moveScreenshots(_ files: [URL], to new: URL, folder value: String, done: @escaping (Int) -> Void) {
        shelf.shutDown()
        movingFolder = true
        DispatchQueue.global(qos: .userInitiated).async {
            let r = FolderMigration.move(files, to: new)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    ShelfStore.remapPinned(r.moved)
                    ShelfTextIndex.shared.remap(r.moved)
                    PinWindow.remap(r.moved)
                    self.settings.screenshotFolder = value
                    // 直接重建（上面的订阅随后看到文件夹已经对上，不会再建一次）
                    if DebugOptions.debugShelfFolder == nil { self.shelfFolder = CaptureStore.folder }
                    self.makeShelf()
                    self.movingFolder = false
                    done(r.failed)
                }
            }
        }
    }

    /// 设置里换了截图文件夹：截图架换成显示新文件夹（要搬旧截图的走上面的 moveScreenshots）
    private func screenshotFolderChanged() {
        guard DebugOptions.debugShelfFolder == nil else { return }
        let url = CaptureStore.folder
        guard url.standardizedFileURL != shelfFolder.standardizedFileURL else { return }
        shelf.shutDown()
        shelfFolder = url
        makeShelf()
    }

    private func observeSettings() {
        settings.$screenshotFolder.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.screenshotFolderChanged() } }
            .store(in: &subscriptions)
        settings.$revealTrigger.dropFirst().sink { [weak self] in self?.shelf.revealTrigger = $0 }.store(in: &subscriptions)
        settings.$side.dropFirst().sink { [weak self] in self?.shelf.setSide($0) }.store(in: &subscriptions)
        settings.$autoHideDelay.sink { [weak self] in self?.shelf.displayDuration = $0 > 0 ? $0 : nil }
            .store(in: &subscriptions)
        settings.$toggleShelfKey.sink { [weak self] _ in DispatchQueue.main.async { self?.registerHotKeys() } }.store(in: &subscriptions)
        settings.$captureKey.sink { [weak self] _ in DispatchQueue.main.async { self?.registerHotKeys() } }.store(in: &subscriptions)
        settings.$captureTextKey.sink { [weak self] _ in DispatchQueue.main.async { self?.registerHotKeys() } }.store(in: &subscriptions)
        for p in [settings.$captureAreaKey, settings.$captureWindowKey, settings.$captureScreenKey] {
            p.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.registerHotKeys() } }.store(in: &subscriptions)
        }
        NotificationCenter.default.publisher(for: .hotKeysNeedRegistration)
            .sink { [weak self] _ in self?.registerHotKeys() }.store(in: &subscriptions)
    }

    private func registerHotKeys() {
        // 调试运行（带参数启动的另一份）不抢全局快捷键，免得和正在用的 QuickCap 一起响应
        guard !DebugOptions.isDebugRun else { return }
        let center = HotKeyCenter.shared
        var conflicts: Set<AppSettings.HotKeyID> = [], reserved: Set<AppSettings.HotKeyID> = []
        let keys: [(AppSettings.HotKeyID, HotKey?, () -> Void)] = [
            (.toggleShelf, settings.toggleShelfKey, { [weak self] in self?.toggleShelf() }),
            (.capture, settings.captureKey, { [weak self] in self?.startCapture() }),
            (.captureText, settings.captureTextKey, { [weak self] in self?.startTextCapture() }),
            (.captureArea, settings.captureAreaKey, { [weak self] in self?.captureArea() }),
            (.captureWindow, settings.captureWindowKey, { [weak self] in self?.captureWindow() }),
            (.captureScreen, settings.captureScreenKey, { [weak self] in self?.captureScreen() }),
        ]
        for (id, key, handler) in keys {
            // 和 macOS 自己的快捷键重复的不注册，系统的功能保持原样
            if let key, SystemHotKeys.isReserved(key) {
                reserved.insert(id)
                center.register(id: id.rawValue, nil, handler: handler)
                continue
            }
            if !center.register(id: id.rawValue, key, handler: handler) { conflicts.insert(id) }
        }
        if settings.conflictingKeys != conflicts { settings.conflictingKeys = conflicts }
        if settings.reservedKeys != reserved { settings.reservedKeys = reserved }
        updateMenuShortcuts()
    }

    /// 菜单栏图标：和 app 图标一样，取景框四个角加中间一条线（18pt，单色，跟着菜单栏变黑变白）
    /// 菜单栏图标：取景框（大圆角，和系统的 viewfinder 一样圆）+ 中间一条收在框里的线，和 app 图标同一个样子
    static let menuBarIcon: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setStroke()
            let c = NSBezierPath()
            c.lineWidth = 1.5; c.lineCapStyle = .round; c.lineJoinStyle = .round
            // 四个角（原点左上）：离边 2.5，每条臂 4.4，转角半径 3.6
            let lo: CGFloat = 2.5, hi: CGFloat = 15.5, arm: CGFloat = 4.4, r: CGFloat = 3.6
            for (a, m, b) in [((lo, lo + arm), (lo, lo), (lo + arm, lo)), ((hi - arm, lo), (hi, lo), (hi, lo + arm)),
                              ((hi, hi - arm), (hi, hi), (hi - arm, hi)), ((lo + arm, hi), (lo, hi), (lo, hi - arm))] {
                let p0 = NSPoint(x: a.0, y: a.1), pm = NSPoint(x: m.0, y: m.1), p1 = NSPoint(x: b.0, y: b.1)
                func toward(_ from: NSPoint, _ to: NSPoint, _ d: CGFloat) -> NSPoint {
                    let len = hypot(to.x - from.x, to.y - from.y)
                    return NSPoint(x: from.x + (to.x - from.x) / len * d, y: from.y + (to.y - from.y) / len * d)
                }
                c.move(to: p0)
                c.line(to: toward(pm, p0, r))
                c.curve(to: toward(pm, p1, r), controlPoint1: pm, controlPoint2: pm)
                c.line(to: p1)
            }
            c.stroke()
            let line = NSBezierPath()
            line.lineWidth = 1.6; line.lineCapStyle = .round
            line.move(to: NSPoint(x: 5.2, y: 9)); line.line(to: NSPoint(x: 12.8, y: 9))
            line.stroke()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "QuickCap"
        return img
    }()

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.menuBarIcon

        let menu = NSMenu()
        menu.delegate = self
        // All-In-One（⇧⌘2）：打开截图界面，用上次的模式，在条上换区域、窗口、整个屏幕。下面三个直接进某一种
        captureItem = item("All-In-One", #selector(startCapture), symbol: "plus.viewfinder")
        menu.addItem(captureItem)
        let area = item("Capture Area", #selector(captureArea), symbol: "rectangle.dashed")
        let win = item("Capture Window", #selector(captureWindow), symbol: "macwindow")
        let scr = item("Capture Screen", #selector(captureScreen), symbol: "rectangle.inset.filled")
        for i in [area, win, scr] { menu.addItem(i) }
        (areaItem, windowItem, screenItem) = (area, win, scr)
        captureTextItem = item("Scan Text & QR", #selector(startTextCapture), symbol: "text.viewfinder")
        menu.addItem(captureTextItem)
        let timer = NSMenuItem(title: "Timer", action: nil, keyEquivalent: "")
        timer.image = Self.menuSymbol("timer")
        Self.showImage(timer)
        let sub = NSMenu()
        for (v, t) in [(0, "None"), (3, "3 Seconds"), (5, "5 Seconds"), (10, "10 Seconds")] {
            let i = item(t, #selector(setTimer(_:)))
            i.tag = v
            sub.addItem(i)
        }
        timer.submenu = sub
        timerMenu = sub
        menu.addItem(timer)
        menu.addItem(.separator())
        menu.addItem(item("Search Captures…", #selector(searchCaptures), symbol: "magnifyingglass"))
        toggleItem = item("Show Shelf", #selector(toggleShelf), symbol: "rectangle.stack")
        menu.addItem(toggleItem)
        menu.addItem(item("Open Screenshots Folder", #selector(openFolder), symbol: "folder"))
        // 钉图：有钉着的才出现（锁住的钉图点不到，只能从这里解开）
        let fromClip = item("Pin from Clipboard", #selector(pinFromClipboard), symbol: "pin")
        menu.addItem(fromClip)
        pinClipboardItem = fromClip
        let unlock = item("Unlock Pins", #selector(unlockPins), symbol: "lock.open")
        let closePins = item("Close All Pins", #selector(closeAllPins), symbol: "pin.slash")
        menu.addItem(unlock)
        menu.addItem(closePins)
        (unlockPinsItem, closePinsItem) = (unlock, closePins)
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ",", modifiers: [.command], symbol: "gearshape"))
        menu.addItem(item("Quit QuickCap", #selector(NSApplication.terminate(_:)), key: "q", modifiers: [.command], target: NSApp,
                          symbol: "power"))
        statusItem.menu = menu
        updateMenuShortcuts()
    }

    private var timerMenu: NSMenu?
    private var areaItem: NSMenuItem?, windowItem: NSMenuItem?, screenItem: NSMenuItem?
    private var unlockPinsItem: NSMenuItem?, closePinsItem: NSMenuItem?, pinClipboardItem: NSMenuItem?

    @objc private func pinFromClipboard() { if !PinWindow.pinFromClipboard() { NSSound.beep() } }

    /// 剪贴板里有没有图：菜单打开时查一次。validateMenuItem 在鼠标移动时会被反复调用，每次都读剪贴板会让菜单卡
    private var clipboardHasImage = false

    /// 菜单会自动启用有 action 的项：这里决定"Pin from Clipboard"灰不灰
    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === pinClipboardItem { return clipboardHasImage }
        return true
    }

    @objc private func unlockPins() { PinWindow.unlockAll() }
    @objc private func closeAllPins() { PinWindow.closeAll() }

    /// 菜单项前面的线条图标（和系统菜单里的一样大小）
    private static func menuSymbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
    }

    private func item(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = [],
                      target: AnyObject? = nil, symbol: String? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = target ?? self
        i.keyEquivalentModifierMask = modifiers
        if let symbol { i.image = Self.menuSymbol(symbol); Self.showImage(i) }
        return i
    }

    /// macOS 27 起菜单默认把图标藏起来，要明确说"要显示"
    private static func showImage(_ i: NSMenuItem) {
        if #available(macOS 27.0, *) { i.preferredImageVisibility = .visible }
    }

    /// 菜单里显示当前的全局快捷键
    private func updateMenuShortcuts() {
        guard let toggleItem, let captureItem, let captureTextItem else { return }
        var rows: [(NSMenuItem, HotKey?, AppSettings.HotKeyID)] = [(toggleItem, settings.toggleShelfKey, .toggleShelf),
                                                                 (captureItem, settings.captureKey, .capture),
                                                                 (captureTextItem, settings.captureTextKey, .captureText)]
        if let areaItem { rows.append((areaItem, settings.captureAreaKey, .captureArea)) }
        if let windowItem { rows.append((windowItem, settings.captureWindowKey, .captureWindow)) }
        if let screenItem { rows.append((screenItem, settings.captureScreenKey, .captureScreen)) }
        for (menuItem, key, id) in rows {
            let usable = !settings.reservedKeys.contains(id) && !settings.conflictingKeys.contains(id)
            let (k, m) = usable ? (key?.menuKeyEquivalent ?? ("", [])) : ("", [])
            menuItem.keyEquivalent = k
            menuItem.keyEquivalentModifierMask = m
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === statusItem.menu { clipboardHasImage = PinWindow.clipboardHasImage }
        toggleItem.title = shelf.isShown ? "Hide Shelf" : "Show Shelf"
        for i in timerMenu?.items ?? [] { i.state = i.tag == settings.captureTimer ? .on : .off }
        unlockPinsItem?.isHidden = !PinWindow.anyLocked
        closePinsItem?.isHidden = PinWindow.debugCount == 0
    }

    @objc private func setTimer(_ sender: NSMenuItem) { settings.captureTimer = sender.tag }

    @objc private func searchCaptures() {
        if welcome.blocksApp() { return }
        shelf.openSearch()
    }


    // MARK: 动作

    var shelfForDebug: ShelfController? { shelf }

    /// 打开自己的截图界面（第一步：冻结屏幕 + 选择条，还不能真正截图）
    @objc func startCapture() { openCapture(mode: nil) }
    /// 直接进 Text 模式
    @objc func startTextCapture() { openCapture(mode: .text) }
    /// 菜单栏菜单：直接进某个模式
    @objc func captureArea() { openCapture(mode: .area) }
    @objc func captureWindow() { openCapture(mode: .window) }
    @objc func captureScreen() { openCapture(mode: .screen) }

    private func openCapture(mode: CaptureMode?) {
        // 欢迎页还没走完：先把它走完
        if welcome.blocksApp() { return }
        // 权限没了：回到欢迎页的权限那几页，不在截图时一个个弹
        if !DebugOptions.isDebugRun, WelcomeWindowController.missingPermissions { welcome.showPermissions(); return }
        // 正在编辑一张截图：先把编辑器叫回前面（截图界面会抢走键盘，编辑完 Esc、⌘Z 都没反应）
        if let editor = ImageEditor.current { editor.bringToFront(); NSSound.beep(); return }
        // 正在搬截图文件夹：截了也不知道该放哪边，等搬完
        if movingFolder {
            CaptureToast.show("Moving your screenshots. Try again in a moment.", symbol: "hourglass",
                              at: CGPoint(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y - 40), hold: 2)
            return
        }
        // 已经开着：同一个快捷键再按一次就关掉；按另一个（⇧⌘1 / ⇧⌘2）就换模式
        if let capture { capture.hotkeyPressed(mode: mode); return }
        let session = CaptureSession(settings: settings, mode: mode)
        session.onOpenSettings = { [weak self] in self?.settingsWindow.show(tab: .capture) }
        session.flightTarget = { [weak self] screen in self?.shelf.flightTarget(on: screen) }
        session.onCaptured = { [weak self, weak session] img, out in
            self?.deliver(img, out, toastAt: session?.lastActionBarCenter)
        }
        session.onEnd = { [weak self, weak session] in
            self?.lastAbortReason = session?.abortReason
            self?.capture = nil
            self?.shelf.setCaptureHidden(false)
            BeautyBackground.clearLive()
        }
        capture = session
        shelf.setCaptureHidden(true)
        session.start()
    }

    var captureForDebug: CaptureSession? { capture }
    /// 调试用：上一次截图界面为什么被关掉
    var lastAbortReason: String?

    /// 截好的图：写进截图文件夹，按设置复制、另存，挂上截图架，出提示
    private func deliver(_ c: CapturedImage, _ out: ActionBar.Output, toastAt: CGPoint?) {
        // 钉到桌面：图先浮出来，文件写好后把位置告诉它（右键"在 Finder 里显示"）
        let pin = c.pinned ? PinWindow.pin(image: c.image, hdr: c.hdr, rect: c.screenRect, fileURL: nil) : nil
        // 文件：最高质量的 HEIC（有 HDR 内容时带增益图）；写不了 HEIC 就退回 PNG。剪贴板放普通的 PNG，贴到哪里都能用。
        // 编码在后台做（大的 HDR 截图要零点几秒），截好的图飞出去的动画不等它
        let box = EncodeInput(image: c.image, hdr: c.hdr, scale: c.scale, headroom: c.screenHeadroom, copy: out == .saveAndCopy,
                              format: settings.captureFormat, toStandard: settings.scaleToStandard, toSRGB: settings.convertToSRGB)
        let date = Date()
        let folder = shelfFolder
        Task.detached(priority: .userInitiated) {
            // 设置里的缩到 1 倍、存成 sRGB：文件和剪贴板都按改过的；钉图、截图架的动画还用原来的
            let p = CaptureOutput.prepared(box.image, hdr: box.hdr, scale: box.scale, toStandard: box.toStandard, toSRGB: box.toSRGB)
            let made = CaptureOutput.fileData(p.image, hdr: p.hdr, scale: p.scale, screenHeadroom: box.headroom,
                                              format: box.format)
            let png = box.copy ? CaptureOutput.pngData(p.image, scale: p.scale) : nil
            let thumb = CaptureOutput.thumbnail(p.image, maxPixel: ShelfThumbnails.maxPixel)
            let result = EncodeOutput(file: made?.0, ext: made?.1 ?? "png", png: png, thumbnail: thumb)
            await MainActor.run { self.finishDelivery(c, out, result, pin: pin, date: date, folder: folder, toastAt: toastAt) }
        }
    }

    private struct EncodeInput: @unchecked Sendable {
        let image: CGImage, hdr: CGImage?, scale: CGFloat, headroom: CGFloat, copy: Bool
        let format: CaptureOutput.Format
        var toStandard = false, toSRGB = false
    }
    private struct EncodeOutput: @unchecked Sendable {
        let file: Data?, ext: String, png: Data?, thumbnail: CGImage?
    }

    /// 编好了：等飞出去的图停稳，同一刻写文件、挂上截图架（卡片从那张图的位置接着飞），落到绳子上时提示
    private func finishDelivery(_ c: CapturedImage, _ out: ActionBar.Output, _ r: EncodeOutput, pin: PinWindow?, date: Date, folder: URL, toastAt: CGPoint?) {
        let fallbackToast = toastAt ?? CGPoint(x: c.screenRect.midX, y: c.screenRect.minY - 30)
        // 存不下来（编码失败、文件夹不能写、硬盘满）：图不能丢，至少放进剪贴板
        let rescue = { (reason: String) in
            c.flight?.cancel()
            let png = r.png ?? CaptureOutput.pngData(c.image, scale: c.scale)
            if let png { CaptureOutput.copy(png: png) }
            CaptureToast.show(png != nil ? "\(reason). Copied to clipboard instead." : reason,
                              symbol: "exclamationmark.circle.fill", at: fallbackToast, hold: 3)
        }
        guard let file = r.file else { rescue("Couldn’t encode the screenshot"); return }
        let handWritten = { [weak self] (url: URL) in
            guard let self else { return }
            if let png = r.png { CaptureOutput.copy(png: png) }
            if let item = ShelfItem.load(url) { ShelfTextIndex.shared.prioritize(item) }
            let message = c.pinned ? (out == .saveAndCopy ? "Pinned, saved and copied" : "Pinned and saved")
                : out == .saveAndCopy ? "Saved and copied" : "Saved"
            // 用这一次自己的钉图：连着钉两张时，前一张写好不会填到后一张上
            pin?.fileURL = url
            // 写好时可能已经又开了一次截图：那时截图架要继续藏着
            if self.capture == nil { self.shelf.setCaptureHidden(false) }
            if let flight = c.flight {
                let h = flight.holdRect
                let ok = self.shelf.add(fileURL: url, fromScreenPoint: CGPoint(x: h.midX, y: h.midY), startScale: flight.holdScale,
                                        thumbnail: r.thumbnail, startOpacity: 1) { [weak self] item in
                    // 落到绳子上：提示出在卡片上（眼睛正跟着它）
                    self?.shelf.toast(message, for: item)
                    CaptureToast.lastText = message
                    self?.landedAt = Date()
                }
                if ok { flight.handedOff() } else { flight.cancel() }
            } else if c.pinned {
                // 钉住的图挡在原地，截图架那张悄悄挂上去，提示出在截图架上
                self.shelf.add(fileURL: url, fromScreenPoint: CGPoint(x: c.screenRect.midX, y: c.screenRect.midY), thumbnail: r.thumbnail)
                CaptureToast.show(message, at: CGPoint(x: c.screenRect.midX, y: c.screenRect.minY - 24))
            } else {
                self.shelf.add(fileURL: url, fromScreenPoint: CGPoint(x: c.screenRect.midX, y: c.screenRect.midY), thumbnail: r.thumbnail)
                CaptureToast.show(message, at: fallbackToast)
            }
            self.lastDelivery = "file=\(url.lastPathComponent) px=\(c.image.width)x\(c.image.height) out=\(out) hdr=\(c.hdr != nil) flight=\(c.flight != nil) screenHeadroom=\(c.screenHeadroom) imageHeadroom=\(c.hdr?.contentHeadroom ?? 0)"
        }
        // 写文件放到后台（大的 HDR 截图、慢的硬盘要零点几秒，以前在主线程上写，飞上截图架的动画会顿一下）。
        // 写成临时文件再改名（atomic）：文件夹扫描要等改名后 0.3 秒才看，写好马上回主线程挂上去，还是不会被扫描抢先
        let hand = { [weak self] in
            guard self != nil else { return }
            let url = CaptureOutput.newURL(in: folder, date: date, ext: r.ext)
            CaptureOutput.reserved.insert(url.path)
            let top = NSScreen.screens.first?.frame.maxY ?? c.screenRect.maxY
            let globalRect = CGRect(x: c.screenRect.minX, y: top - c.screenRect.maxY, width: c.screenRect.width, height: c.screenRect.height)
            let captureType = c.captureType
            let data = file
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = (try? data.write(to: url, options: .atomic)) != nil
                // 标成截图：访达"按种类分组"时和系统截图、CleanShot 放在同一堆 Screenshots
                // （位置记成主屏左上原点的 pt，和系统截图一样）
                if ok { CaptureOutput.markAsScreenshot(url, rect: globalRect, type: captureType) }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        CaptureOutput.reserved.remove(url.path)
                        if ok { handWritten(url) } else { rescue("Couldn’t save to \(FileManager.default.displayName(atPath: folder.path))") }
                    }
                }
            }
        }
        // 飞出去的图还在缩：等它停稳再接手，两样一模一样
        if let f = c.flight, f.secondsUntilHeld > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + f.secondsUntilHeld) { hand() }
        } else {
            hand()
        }
    }

    /// 截图架卡片右键：钉到桌面（屏幕中间，按截图的像素倍数显示）
    private func pinToDesktop(_ item: ShelfItem) {
        guard let src = CGImageSourceCreateWithURL(item.url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { NSSound.beep(); return }
        let hdr = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens.first
        else { NSSound.beep(); return }
        let k = screen.backingScaleFactor
        var size = CGSize(width: CGFloat(img.width) / k, height: CGFloat(img.height) / k)
        let maxS = screen.visibleFrame.insetBy(dx: 60, dy: 60).size
        let fit = min(1, maxS.width / size.width, maxS.height / size.height)
        size = CGSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())
        let v = screen.visibleFrame
        let rect = CGRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2, width: size.width, height: size.height)
        let gm = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
        _ = PinWindow.pin(image: img, hdr: gm ? hdr : nil, rect: rect, fileURL: item.url)
    }

    // MARK: 拿下来改

    /// 双击卡片：卡片从绳子上拿下来、放大到屏幕中间，用截图时那根第二条画。
    /// Replace：存回原来的文件（几秒内可以撤销），缩回去挂在原来的位置；Save as New：新的一张飞上截图架，原来那张不动
    func edit(_ item: ShelfItem) {
        guard ImageEditor.current == nil, capture == nil else { NSSound.beep(); return }
        guard let src = CGImageSourceCreateWithURL(item.url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { shelf.toast("Couldn’t open", for: item); return }
        let gm = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
        let hdr = gm ? CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary) : nil
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let typeID = CGImageSourceGetType(src) as String?
        // 文件里记的 DPI（144 = 2 倍屏截的）决定图有多大（pt）；没有就按屏幕
        let returnApp = NSWorkspace.shared.frontmostApplication
        // 美化背景的 Desktop Wallpaper：从截图架打开时也截一下现在的系统壁纸（动态壁纸读不到文件）
        Task.detached(priority: .utility) {
            if let c = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) {
                await BeautyBackground.captureLive(c)
            }
        }
        guard let (from, screen) = shelf.lift(item) else { return }
        let dpi = (props?[kCGImagePropertyDPIWidth] as? NSNumber).map { CGFloat(truncating: $0) } ?? 0
        let scale = dpi >= 72 ? dpi / 72 : screen.backingScaleFactor
        let headroom = max(1, CGFloat(hdr?.contentHeadroom ?? 1))
        let e = ImageEditor(mode: .edit, image: img, hdr: hdr, scale: scale, screen: screen, headroom: headroom,
                            fileURL: item.url, settings: settings)
        e.sourceCorner = Metrics.cardCorner
        e.returnApp = returnApp?.processIdentifier == NSRunningApplication.current.processIdentifier ? nil : returnApp
        e.cardFrame = { [weak self] px in self?.shelf.editingCardFrame(pixelSize: px) }
        e.flightTarget = { [weak self] s in self?.shelf.flightTarget(on: s) }
        e.onSaveAsNew = { [weak self] c in
            guard let self else { return }
            self.deliver(c, self.settings.captureCopy ? .saveAndCopy : .save, toastAt: nil)
        }
        // 存回去：后台编码、写文件；收起来的动画做完时等它写好，卡片换成新的那一刻再拿走编辑窗口（中间不会闪）
        var written: ((Bool) -> Void)?
        var result: Bool?
        e.onReplace = { [weak self] out, outHDR in
            self?.writeBack(item, image: out, hdr: outHDR, scale: scale, headroom: headroom, typeID: typeID) { ok in
                result = ok
                written?(ok)
            }
        }
        e.onClose = { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .replaced:
                e.closeGate = { [weak self] finish in
                    let land = { (ok: Bool) in
                        self?.shelf.endEdit(fadeIn: !ok)
                        finish()
                    }
                    if let r = result { land(r) } else { written = land }
                }
            case .savedAsNew(let returned):
                self.shelf.endEdit(fadeIn: !returned)
            default:
                self.shelf.endEdit(fadeIn: false)
            }
        }
        e.present(from: from)
    }

    /// 钉图右键 Annotate…：用截图架那个编辑器，从钉图的位置放大出去。
    /// Replace：写回文件，钉图换成新图（截图架上那张也跟着换）；Save as New：新的一张飞上截图架，钉图不变
    func annotate(_ pin: PinWindow) {
        guard ImageEditor.current == nil, capture == nil, let url = pin.fileURL, let item = ShelfItem.load(url) else { NSSound.beep(); return }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { NSSound.beep(); return }
        let gm = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
        let hdr = gm ? CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary) : nil
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let typeID = CGImageSourceGetType(src) as String?
        guard let screen = pin.screen ?? NSScreen.main ?? NSScreen.screens.first else { NSSound.beep(); return }
        let dpi = (props?[kCGImagePropertyDPIWidth] as? NSNumber).map { CGFloat(truncating: $0) } ?? 0
        let scale = dpi >= 72 ? dpi / 72 : screen.backingScaleFactor
        let headroom = max(1, CGFloat(hdr?.contentHeadroom ?? 1))
        let from = pin.frame
        let e = ImageEditor(mode: .edit, image: img, hdr: hdr, scale: scale, screen: screen, headroom: headroom,
                            fileURL: url, settings: settings)
        e.sourceCorner = 6
        // 收回去：回到钉图现在的位置（换了图就按新图的比例）
        e.cardFrame = { [weak pin] px in
            guard let pin else { return nil }
            let f = pin.frame
            guard let px, px.width > 0, px.height > 0 else { return f }
            let h = f.width * px.height / px.width
            return CGRect(x: f.minX, y: f.maxY - h, width: f.width, height: h)
        }
        e.flightTarget = { [weak self] s in self?.shelf.flightTarget(on: s) }
        e.onSaveAsNew = { [weak self] c in
            guard let self else { return }
            self.deliver(c, self.settings.captureCopy ? .saveAndCopy : .save, toastAt: nil)
        }
        var written: ((Bool) -> Void)?
        var result: Bool?
        e.onReplace = { [weak self, weak pin] out, outHDR in
            pin?.replaceImage(out, hdr: outHDR, pointSize: CGSize(width: CGFloat(out.width) / scale, height: CGFloat(out.height) / scale))
            self?.writeBack(item, image: out, hdr: outHDR, scale: scale, headroom: headroom, typeID: typeID) { ok in
                result = ok
                written?(ok)
            }
        }
        e.onClose = { [weak pin] outcome in
            if case .replaced = outcome {
                e.closeGate = { finish in
                    let land = { (_: Bool) in pin?.setHiddenForEditing(false); finish() }
                    if let r = result { land(r) } else { written = land }
                }
            } else {
                pin?.setHiddenForEditing(false)
            }
        }
        pin.setHiddenForEditing(true)
        e.present(from: from)
    }

    /// 改好的图写回原来的文件：格式和原来一样（HEIC 带 HDR 的还是带增益图），创建时间不变（截图架上的顺序不变）。
    /// 写之前把原来的留一份，卡片下面出"撤销"
    private func writeBack(_ item: ShelfItem, image: CGImage, hdr: CGImage?, scale: CGFloat, headroom: CGFloat, typeID: String?,
                           done: @escaping (Bool) -> Void) {
        let url = item.url
        let box = EncodeInput(image: image, hdr: hdr, scale: scale, headroom: headroom, copy: false, format: .png)
        Task.detached(priority: .userInitiated) {
            let ext = url.pathExtension.lowercased()
            let data: Data?
            switch ext {
            case "heic", "heif": data = CaptureOutput.heicData(box.image, hdr: box.hdr, scale: box.scale, screenHeadroom: box.headroom)
            case "jpg", "jpeg": data = CaptureOutput.jpegData(box.image, scale: box.scale)
            case "png": data = CaptureOutput.pngData(box.image, scale: box.scale)
            default: data = CaptureOutput.encode(box.image, typeID: typeID, scale: box.scale)
            }
            let thumb = CaptureOutput.thumbnail(box.image, maxPixel: ShelfThumbnails.maxPixel)
            let saved = data.flatMap { CaptureOutput.replaceKeepingDates(url, with: $0) }
            let out = EncodeOutput(file: nil, ext: ext, png: nil, thumbnail: thumb)
            await MainActor.run {
                guard let backup = saved else {
                    self.shelf.toast("Couldn’t save", for: item)
                    done(false)
                    return
                }
                self.shelf.replaced(url, thumbnail: out.thumbnail)
                done(true)
                // 几秒内可以退回原来的（原来那份放在临时文件夹，撤销就搬回来）
                self.shelf.showUndo("Replaced", for: url) { [weak self = self] in
                    guard CaptureOutput.restore(url, from: backup) else { NSSound.beep(); return }
                    self?.shelf.replaced(url, thumbnail: nil)
                }
                // 撤销条收起后原来那份就没用了
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(UndoPill.duration) + 2) {
                    try? FileManager.default.removeItem(at: backup)
                }
            }
        }
    }

    /// 调试用：最近一次卡片落到绳子上的时间
    var landedAt: Date?
    /// 调试用：最近一次出图
    var lastDelivery = "none"

    @objc func hangSample() {
        guard let url = SampleImage.write(index: sampleIndex) else { return }
        sampleIndex += 1
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let start = NSPoint(x: screen.frame.midX + CGFloat.random(in: -300...300), y: screen.frame.midY)
        shelf.add(fileURL: url, fromScreenPoint: start)
    }

    @objc func toggleShelf() {
        if welcome.blocksApp() { return }
        shelf.toggle()
    }
    @objc func openFolder() { NSWorkspace.shared.open(shelfFolder) }
    @objc func openSettings() {
        // 欢迎页浮在最上面：开设置时让开，不然设置窗口被挡在下面
        welcome.yield()
        settingsWindow.show()
    }
    var settingsForDebug: SettingsWindowController { settingsWindow }
    var statusItemForDebug: NSStatusItem? { statusItem }

    // MARK: 卡片右键菜单

    private func menu(for item: ShelfItem) -> NSMenu {
        let m = NSMenu()
        m.addItem(ClosureMenuItem("Copy Text") { [weak self] in self?.perform(.recognizeText, on: item) })
        m.addItem(ClosureMenuItem("Copy Image") { [weak self] in self?.perform(.copy, on: item) })
        m.addItem(ClosureMenuItem("Show in Finder") { [weak self] in self?.perform(.revealInFinder, on: item) })
        m.addItem(ClosureMenuItem("Pin to Desktop") { [weak self] in self?.pinToDesktop(item) })
        m.addItem(ClosureMenuItem(shelf.isPinned(item) ? "Unpin" : "Pin to Front") { [weak self] in self?.perform(.pin, on: item) })
        m.addItem(.separator())
        let removeTitle = shelf.ownsFile(item.url) ? "Move to Trash" : "Remove from Shelf"
        m.addItem(ClosureMenuItem(removeTitle) { [weak self] in self?.perform(.trash, on: item) })
        return m
    }

    /// 工具栏按钮、角上按钮和右键菜单共用。
    func perform(_ action: ShelfAction, on item: ShelfItem) {
        switch action {
        case .edit:
            edit(item)
        case .copy:
            // 只放图片数据：同时放文件的话，有的应用会贴成附件或路径，各家不一样
            // HEIC 转 PNG 放到后台（大图要零点几秒，以前在主线程，按 ⌘C 截图架会顿一下）
            let url = item.url
            Task { [weak self] in
                let png = await Task.detached(priority: .userInitiated) { ShelfDragWriter.pngData(of: url) }.value
                guard let self else { return }
                guard let png else { self.shelf.toast("Couldn’t copy", for: item); return }
                CaptureOutput.copy(png: png)
                self.shelf.toast("Image copied", for: item)
            }
        case .recognizeText:
            recognize(item)
        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        case .pin:
            shelf.togglePin(item)
        case .trash:
            if shelf.ownsFile(item.url) {
                trashWithUndo(item)
            } else {
                // 不是截图文件夹里的（置顶的旧文件、从别处挂上来的）：只取下，不删用户的文件
                shelf.removeWithUndo(url: item.url, message: "Removed") { [weak self] from, pinned in
                    self?.shelf.restore(fileURL: item.url, from: from, pinnedIndex: pinned)
                }
            }
        }
    }

    /// 移到废纸篓，几秒内可以撤销（从废纸篓挪回原处，再挂回去）
    private func trashWithUndo(_ item: ShelfItem) {
        let url = item.url
        var trashed: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        } catch {
            // 文件已经不在了：直接取下，免得卡片一直挂着
            if !FileManager.default.fileExists(atPath: url.path) { shelf.remove(url: url) }
            else { shelf.toast("Couldn’t move to Trash", for: item) }
            return
        }
        guard let inTrash = trashed as URL? else { shelf.remove(url: url); return }
        shelf.removeWithUndo(url: url, message: "Moved to Trash") { [weak self] from, pinned in
            do {
                try FileManager.default.moveItem(at: inTrash, to: url)
            } catch {
                // 原来的位置被占了，或者废纸篓已经清空
                NSSound.beep()
                return
            }
            self?.shelf.restore(fileURL: url, from: from, pinnedIndex: pinned)
        }
    }

    /// 移到废纸篓，同时从悬挂架上取下。返回成功移走的文件
    @discardableResult
    func trash(_ urls: [URL]) -> [URL] {
        var done: [URL] = []
        for url in urls {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                done.append(url)
            } catch {
                // 文件已经不在了也当成成功，免得卡片一直挂着
                if !FileManager.default.fileExists(atPath: url.path) { done.append(url) }
            }
        }
        done.forEach { shelf.remove(url: $0) }
        if done.count < urls.count { NSSound.beep() }
        return done
    }

    func recognize(_ item: ShelfItem) {
        shelf.toast("Recognizing text…", for: item)
        TextRecognizer.recognize(url: item.url) { [weak self] result in
            switch result {
            case .success(let text) where !text.isEmpty:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                let n = text.split(separator: "\n").count
                let msg = !AppSettings.shared.scanKeepLineBreaks ? "Copied text" : n == 1 ? "Copied 1 line" : "Copied \(n) lines"
                self?.shelf.toast(msg, for: item)
            case .success:
                self?.shelf.toast("No text found", for: item)
            case .failure:
                self?.shelf.toast("Couldn’t recognize text", for: item)
            }
        }
    }

    // 调试用
    var debugShelf: ShelfController { shelf }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
