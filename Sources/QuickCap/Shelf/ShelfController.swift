import AppKit
import Carbon.HIToolbox

/// 覆盖整块屏幕的透明面板。只有鼠标在卡片上时才接收点击，其余区域点穿。
final class ShelfWindow: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // 比所有 app 的浮窗都高（有的 app 把浮窗放在 1000 层，会挡住绳子和卡片），只比截图界面低两层：
        // 截图时截图架是藏起来的，截好的图飞过来时要在截图架上面
        level = NSWindow.Level(rawValue: CaptureOverlayWindow.captureLevel.rawValue - 2)
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ShelfController: NSObject, ShelfViewDelegate {
    private var window: ShelfWindow?
    private var view: ShelfView?
    private let handle = ShelfHandle()
    private var monitors: [Any] = []
    private var hideTimer: Timer?
    private var lastInteraction = Date()
    private var shownByHover = false
    /// 碰把手唤出后鼠标离开绳子区域：0.6 秒后再看一眼要不要收起
    private var leaveHideWork: DispatchWorkItem?
    /// 展开时改了方向：等收起完再换边、重新展开
    private var pendingSide: ShelfSide?

    /// 展开后多久没操作就自动收起（秒）。nil 表示一直显示。
    var displayDuration: TimeInterval? = 3
    /// 鼠标离开卡片后，至少再停留这么久才收起
    var hoverGrace: TimeInterval = 1
    /// 收起后鼠标碰到把手就展开，还是要点一下
    var revealTrigger: RevealTrigger = .hover { didSet { handle.trigger = revealTrigger } }
    /// 从屏幕哪一边拉出来
    var side: ShelfSide { view?.side ?? .right }
    /// 整排变了（增减、置顶、换顺序）时调用
    var onItemsChanged: (() -> Void)?
    /// 用户把把手拖到了另一边。由外面写进设置，设置再通过 setSide 改回来，这里不直接写设置
    var onSideChanged: ((ShelfSide) -> Void)?
    /// 扫哪个文件夹
    let folder: URL
    private var library: ShelfLibrary!
    /// 不在这个文件夹里、但挂着的（置顶的旧文件，或从别处挂上来的示例图）
    private var extras: [URL: ShelfItem] = [:]
    /// 刚挂上、文件夹还没扫到的；扫到之后再从这里去掉
    private var pendingAdds: Set<URL> = []
    /// 刚移到废纸篓的：扫描可能还带着它，先挡掉
    private var recentlyRemoved: Set<URL> = []

    var onActivate: ((ShelfItem) -> Void)?
    /// 双击卡片（或者工具栏上的铅笔）：拿下来改
    var onEdit: ((ShelfItem) -> Void)?
    var menuProvider: ((ShelfItem) -> NSMenu?)?
    var onAction: ((ShelfAction, ShelfItem) -> Void)?

    var isShown: Bool { view?.isShown == true && window?.isVisible == true }
    var debugView: ShelfView? { view }
    var items: [ShelfItem] { view?.items ?? [] }

    init(side: ShelfSide, revealTrigger: RevealTrigger, folder: URL) {
        self.revealTrigger = revealTrigger
        self.folder = folder
        super.init()
        // 开机时还没有屏幕（合着盖子、没接显示器）：等屏幕出来再建
        if let screen = NSScreen.main ?? NSScreen.screens.first { build(on: screen) }
        // 改分辨率、插拔显示器、菜单栏高度变了：截图架开着时也要跟着换大小、挪把手
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        view?.side = side
        handle.trigger = revealTrigger
        handle.onReveal = { [weak self] byHover in self?.show(byHover: byHover) }
        handle.onSideChange = { [weak self] side in
            guard let self else { return }
            if let onSideChanged = self.onSideChanged { onSideChanged(side) } else { self.setSide(side) }
        }
        library = ShelfLibrary(folder: folder)
        library.onChange = { [weak self] items in self?.libraryChanged(items) }
        restoreSaved()
        library.start()
        placeHandle()
        // 把手平时藏着，鼠标碰到屏幕边上才滑出来
        handle.setArmed(true)
        installMonitors()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAutoHide() }
        }
    }

    /// 换截图文件夹时：把这个截图架整个关掉（窗口、把手、鼠标监听、计时器），换一个新的
    private var isShutDown = false

    func shutDown() {
        isShutDown = true
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        hideTimer?.invalidate()
        hideTimer = nil
        leaveHideWork?.cancel()
        setEscapeArmed(false)
        handle.setArmed(false)
        handle.close()
        window?.orderOut(nil)
        // 把视图拿下来：它的显示链接在 viewDidMoveToWindow(nil) 里停掉，不然旧截图架带着缩略图一直留在内存
        window?.contentView = nil
        library = nil
        window = nil
        view = nil
    }

    private func build(on screen: NSScreen) {
        let w = ShelfWindow(screen: screen)
        let v = ShelfView(frame: NSRect(origin: .zero, size: screen.frame.size))
        v.delegate = self
        v.ownedFolder = folder
        v.topInset = menuBarHeight(of: screen)
        w.contentView = v
        window = w
        view = v
    }

    private func menuBarHeight(of screen: NSScreen) -> CGFloat {
        let h = screen.frame.maxY - screen.visibleFrame.maxY
        return h > 0 ? h : (screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 24)
    }

    /// 把窗口移到鼠标所在的屏幕。
    private func followMouseScreen() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }),
              let window, let view, window.frame != screen.frame else { return }
        window.setFrame(screen.frame, display: false)
        view.setFrameSize(screen.frame.size)
        view.topInset = menuBarHeight(of: screen)
        placeHandle()
    }

    @objc private func screensChanged() {
        if window == nil, !isShutDown, let s = NSScreen.main ?? NSScreen.screens.first { build(on: s); return }
        guard let window, let view else { return }
        let screen = window.screen ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        if window.frame != screen.frame {
            window.setFrame(screen.frame, display: false)
            view.setFrameSize(screen.frame.size)
        }
        view.topInset = menuBarHeight(of: screen)
        placeHandle()
    }

    private func placeHandle() {
        guard let view, let screen = window?.screen ?? NSScreen.main else { return }
        handle.place(on: screen, topInset: view.topInset, side: view.side)
        handle.setCount(view.count)
        updateHandleCards()
    }

    /// 把手上挂最新的两张（不算置顶的：置顶的是用户留着的旧图，最新截的才是"刚收起来的"）。图从截图架的缓存里拿
    private func updateHandleCards() {
        guard let view else { return }
        let items = Array(view.entries.dropFirst(view.pinnedCount).prefix(2))
        let fallback = items.isEmpty ? Array(view.entries.prefix(2)) : items
        handleCardItems = fallback.map(\.url)
        let scale = window?.backingScaleFactor ?? 2
        var images = [CGImage?](repeating: nil, count: fallback.count)
        func push() { handle.setCards(images.compactMap { $0 }) }
        for (i, item) in fallback.enumerated() {
            let size = Metrics.cardSize(for: item.pixelSize)
            _ = view.thumbnails.loadCard(item, size: size, scale: scale) { [weak self] img in
                guard let self, self.handleCardItems.indices.contains(i), self.handleCardItems[i] == item.url else { return }
                images[i] = img
                push()
            }
        }
        push()
    }
    private var handleCardItems: [URL] = []

    /// 启动时恢复置顶的顺序。置顶的文件可能不在截图文件夹里，单独读一遍
    private func restoreSaved() {
        let pinned = ShelfStore.loadPinned().compactMap { ShelfItem.load($0) }
        for item in pinned where item.url.deletingLastPathComponent() != folder {
            extras[item.url] = item
        }
        // 先把置顶的排好，文件夹扫完后其余的接在后面
        view?.sync(available: pinned)
        view?.setPinnedPrefix(pinned.map(\.url))
    }

    /// 文件夹扫完了：和置顶的、额外挂着的合起来对一遍
    private func libraryChanged(_ scanned: [ShelfItem]) {
        var available = scanned.filter { !recentlyRemoved.contains($0.url) }
        let scannedURLs = Set(scanned.map(\.url))
        // 扫到了就不用再特殊照顾
        pendingAdds.subtract(scannedURLs)
        for url in scannedURLs { extras.removeValue(forKey: url) }
        // 文件没了的额外项也清掉
        extras = extras.filter { FileManager.default.fileExists(atPath: $0.key.path) }
        available.append(contentsOf: extras.values)
        for url in pendingAdds {
            guard extras[url] == nil, let item = ShelfItem.load(url) else { continue }
            available.append(item)
        }
        view?.sync(available: available)
        placeHandle()
        // 截图里的字在后台慢慢认（搜索用）
        ShelfTextIndex.shared.enqueue(view?.items ?? [])
        if searchBar != nil { refreshSearch(jump: false) }
    }

    // MARK: 搜索

    private var searchBar: ShelfSearchBar?
    private var searchCursor: Int?
    /// 打开搜索前在前面的 app（收起时还给它）
    private var appBeforeSearch: NSRunningApplication?

    /// ⌘F：截图架上方出搜索框
    func openSearch() {
        if !isShown { show() }
        guard let view, let window else { return }
        if let bar = searchBar { bar.makeKey(); return }
        // 搜索框要打字：空格、删除键、⌘C 不能再被卡片的快捷键拿走（不然退格会把鼠标下面那张删掉）
        setCardKeysArmed(false)
        let bar = ShelfSearchBar()
        bar.onChange = { [weak self] _ in self?.refreshSearch(jump: true) }
        bar.onNext = { [weak self] forward in self?.stepSearch(forward) }
        bar.onClose = { [weak self] in self?.closeSearch() }
        searchBar = bar
        searchCursor = nil
        let front = NSWorkspace.shared.frontmostApplication
        appBeforeSearch = front == NSRunningApplication.current ? nil : front
        NSApp.activate()
        // 放在卡片下面
        let screen = window.screen?.frame ?? window.frame
        bar.present(centeredIn: screen, top: view.topInset + Metrics.cardMaxSize.height + 44)
        ShelfTextIndex.shared.onIndexed = { [weak self] in self?.refreshSearch(jump: false) }
        refreshSearch(jump: false)
        lastInteraction = Date()
    }

    func debugSetQuery(_ q: String) { searchBar?.setQuery(q) }
    var debugSearch: String {
        "open=\(searchBar != nil) query=\"\(searchBar?.query ?? "")\" matches=\(view?.searchMatches ?? []) cursor=\(searchCursor.map(String.init) ?? "-") shown=\(isShown)"
    }

    func closeSearch() {
        guard let bar = searchBar else { return }
        searchBar = nil
        bar.dismiss()
        view?.setSearch(nil) { _ in nil }
        ShelfTextIndex.shared.onIndexed = nil
        lastInteraction = Date()
        appBeforeSearch?.activate()
        appBeforeSearch = nil
    }

    private func refreshSearch(jump: Bool) {
        guard let bar = searchBar, let view else { return }
        let q = bar.query
        view.setSearch(q) { ShelfTextIndex.shared.match($0, query: q) }
        let total = view.searchMatches.count
        if jump {
            searchCursor = total > 0 ? 0 : nil
            if let i = view.searchMatches.first { view.jump(toIndex: i) }
        } else if let c = searchCursor, c >= total {
            searchCursor = total > 0 ? total - 1 : nil
        }
        bar.setCount(current: searchCursor, total: total, pending: ShelfTextIndex.shared.pending)
        lastInteraction = Date()
    }

    /// 回车：下一张对上的（⇧回车：上一张）
    private func stepSearch(_ forward: Bool) {
        guard let view, let bar = searchBar else { return }
        let m = view.searchMatches
        guard !m.isEmpty else { NSSound.beep(); return }
        let c = searchCursor.map { ($0 + (forward ? 1 : m.count - 1)) % m.count } ?? 0
        searchCursor = c
        view.jump(toIndex: m[c])
        bar.setCount(current: c, total: m.count, pending: ShelfTextIndex.shared.pending)
        lastInteraction = Date()
    }

    /// 鼠标停在截图架上时占用 ⌘F（悬挂架不抢焦点，只能用全局快捷键），移开就还回去
    private func setFindArmed(_ on: Bool) {
        let id = AppSettings.HotKeyID.shelfFind.rawValue
        let center = HotKeyCenter.shared
        guard on != center.isRegistered(id) else { return }
        if on {
            center.register(id: id, HotKey(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(cmdKey))) { [weak self] in
                guard let self, self.isShown else { return }
                self.openSearch()
            }
        } else {
            center.register(id: id, nil) {}
        }
    }

    /// 换边。展开着的话先收起，换好再展开。
    /// 这里不能写 AppSettings：设置的 @Published 在值真正写入之前就通知订阅者，
    /// 订阅者回调到这里时读到的还是旧值，再写一次就会无限递归（之前切到左边闪退就是这个）。
    func setSide(_ side: ShelfSide) {
        guard let view else { return }
        if pendingSide != nil {
            // 为了换边正在收起，又改了一次：以最新的为准，改回原来那边就不换了
            pendingSide = side == view.side ? nil : side
            return
        }
        guard view.side != side else { return }
        if isShown {
            pendingSide = side
            hide()
        } else {
            view.side = side
            placeHandle()
        }
    }

    // MARK: 公共接口

    /// fromScreenPoint 是屏幕坐标（y 向上），卡片中心从这里飞到绳子上。
    /// selectionCorner 为 true 时，这个点是框选松手的位置（选区的右下角），会按截图尺寸推算出选区中心。
    /// startScale 不给的话按截图在屏幕上的大小算：卡片从差不多原图大小缩到卡片大小。
    /// thumbnail、startOpacity、onLanded 见 ShelfView.add。返回 false 表示没挂上（文件读不出来）
    @discardableResult
    func add(fileURL: URL, fromScreenPoint point: NSPoint, selectionCorner: Bool = false, startScale: CGFloat? = nil,
             thumbnail: CGImage? = nil, startOpacity: Float = 0, onLanded: ((ShelfItem) -> Void)? = nil) -> Bool {
        // 已经挂着的就不再挂一张，展开让它晃一下
        if let existing = items.first(where: { $0.url.standardizedFileURL == fileURL.standardizedFileURL }) {
            show()
            view?.showToast("Already on the shelf", for: existing)
            return true
        }
        guard let item = ShelfItem.load(fileURL) else { NSSound.beep(); return false }
        track(item)
        if !isShown { followMouseScreen() }
        show()
        guard let view, let window else { return false }
        let screen = window.screen ?? NSScreen.main
        let pointScale = screen?.backingScaleFactor ?? 2
        // 截图在屏幕上的大小（pt）
        let shot = CGSize(width: item.pixelSize.width / pointScale, height: item.pixelSize.height / pointScale)
        var start = point
        if selectionCorner {
            // screencapture 不告诉我们选区在哪，只知道松手的位置。一般是从左上往右下拖，松手在右下角
            start = NSPoint(x: point.x - shot.width / 2, y: point.y + shot.height / 2)
        }
        if let f = screen?.frame, startOpacity < 1 {
            start.x = min(max(start.x, f.minX + 40), f.maxX - 40)
            start.y = min(max(start.y, f.minY + 40), f.maxY - 40)
        }
        let card = Metrics.cardSize(for: item.pixelSize)
        let scale = startScale ?? min(max(shot.width / card.width, 1), 2.2)
        let local = window.convertPoint(fromScreen: start)
        view.add(item, from: view.layerPoint(local), startScale: scale, thumbnail: thumbnail, startOpacity: startOpacity,
                 onLanded: onLanded.map { f in { f(item) } })
        return true
    }

    /// 截好的图要飞向哪里（屏幕坐标，挂绳靠这一边的那头）。截图在别的屏幕上（截图架会在另一块屏幕打开）就返回 nil
    func flightTarget(on screen: NSScreen) -> CGPoint? {
        let shelfScreen = isShown ? window?.screen : NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        guard let s = shelfScreen ?? NSScreen.main, s.frame == screen.frame else { return nil }
        let f = s.frame
        let top = f.maxY - (f.maxY - s.visibleFrame.maxY) - 90
        return CGPoint(x: side == .right ? f.maxX - 180 : f.minX + 180, y: top)
    }

    /// 挂上之前记下来：文件夹里的等扫描捡到，文件夹外的单独记着
    private func track(_ item: ShelfItem) {
        let std = item.url
        recentlyRemoved.remove(std)
        if ownsFile(std) {
            pendingAdds.insert(std)
        } else {
            extras[std] = item
        }
    }

    /// 文件在截图文件夹里。不在的话"删除"只是从绳子上取下，不碰文件
    func ownsFile(_ url: URL) -> Bool { url.standardizedFileURL.deletingLastPathComponent() == folder }

    /// 撤销删除：文件已经放回原处，从撤销条的位置飞回绳子上。置顶的放回置顶那一组原来的位置
    func restore(fileURL: URL, from layerPoint: CGPoint, pinnedIndex: Int?) {
        guard let item = ShelfItem.load(fileURL), let view else { NSSound.beep(); return }
        track(item)
        show()
        view.add(item, from: layerPoint, startScale: 1, pinnedAt: pinnedIndex)
    }

    /// 从绳子上拿下来，并在原来的位置下面显示几秒"撤销"
    func removeWithUndo(url: URL, message: String, onUndo: @escaping (_ from: CGPoint, _ pinnedIndex: Int?) -> Void) {
        guard let view else { remove(url: url); return }
        let std = url.standardizedFileURL
        let i = view.index(of: std)
        let pinnedIndex = i.flatMap { $0 < view.pinnedCount ? $0 : nil }
        let x = view.screenX(of: std) ?? view.bounds.midX
        remove(url: std)
        let anchor = view.undoAnchor(x: x)
        view.showUndo(message, atX: x) { onUndo(anchor, pinnedIndex) }
        lastInteraction = Date()
    }

    func show(byHover: Bool = false) {
        guard let view, let window else { return }
        shownByHover = byHover
        lastInteraction = Date()
        pendingSide = nil
        if !window.isVisible { window.orderFrontRegardless() }
        handle.setArmed(false)
        // 在访达里加了、删了图，展开时也对一遍（文件被原地覆盖不一定有通知）
        library?.rescan()
        view.setShown(true)
    }

    func hide() {
        closeSearch()
        setEscapeArmed(false)
        shownByHover = false
        leaveHideWork?.cancel()
        leaveHideWork = nil
        view?.clearHover()
        window?.ignoresMouseEvents = true
        view?.setShown(false)
    }

    func toggle() { isShown ? hide() : show() }

    func remove(_ item: ShelfItem) { remove(url: item.url) }

    func remove(url: URL) {
        let std = url.standardizedFileURL
        extras.removeValue(forKey: std)
        pendingAdds.remove(std)
        // 扫描可能还没反应过来，先挡一会儿
        recentlyRemoved.insert(std)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.recentlyRemoved.remove(std)
        }
        view?.remove(url: std)
    }
    func isPinned(_ item: ShelfItem) -> Bool { view?.isPinned(item) == true }
    func togglePin(_ item: ShelfItem) {
        guard let view else { return }
        view.setPinned(!view.isPinned(item), for: item)
    }
    func toast(_ text: String, for item: ShelfItem) { view?.showToast(text, for: item); lastInteraction = Date() }

    // MARK: 调试


    func debugScroll(to d: CGFloat) {
        guard let view else { return }
        show()
        view.userScrolling = true
        view.settleScroll(to: d)
    }

    func debugPin(index i: Int) {
        guard let view, view.entries.indices.contains(i) else { print("pin: no card at index \(i)"); return }
        show()
        let item = view.entries[i]
        view.setPinned(true, for: item)
        print("pin \(i) → \(item.url.lastPathComponent) pinnedCount=\(view.pinnedCount)")
    }

    func debugDump() {
        guard let view else { print("no shelf view"); return }
        show()
        // 等展开动画把卡片摆好
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { view.debugDump() }
    }

    /// 截图时临时隐藏，避免被截进去。
    /// 截图界面打开时：悬挂架不显示，也不响应鼠标和 Esc，免得和截图界面抢
    private var captureActive = false
    func setCaptureHidden(_ hidden: Bool) {
        captureActive = hidden
        window?.alphaValue = hidden ? 0 : 1
        if hidden { setEscapeArmed(false) }
    }

    // MARK: 鼠标

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.mouseMoved() }
            return e
        }) { monitors.append(l) }
    }

    private func mouseMoved() {
        // 拿下来改着：编辑窗口盖在上面，截图架不跟着鼠标晃、不收
        guard !captureActive, editingURL == nil, let window, let view else { return }
        guard isShown else {
            // 收起着：鼠标碰到某块屏幕的边上时，把手滑出来
            if !view.isShown { pointerMovedWhileHidden() }
            return
        }
        let p = view.layerPoint(window.convertPoint(fromScreen: NSEvent.mouseLocation))
        let over = view.updateHover(at: p)
        // 拖动卡片（拖出或调整顺序）时不能让窗口变成点穿，否则松手事件会丢
        if view.draggingCard == nil, view.reorderingCard == nil, NSEvent.pressedMouseButtons == 0 {
            // 一样就不设（每动一下鼠标都会来，设一次就要和 WindowServer 说一次）
            if window.ignoresMouseEvents == over { window.ignoresMouseEvents = !over }
        }
        if over { lastInteraction = Date() }
        setEscapeArmed(over)
        // 碰把手唤出的，离开绳子区域就收起。鼠标一直在动，只排一次，到时间再看一眼
        if shownByHover, searchBar == nil, p.y > view.topInset + Metrics.cardMaxSize.height + 90, leaveHideWork == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.leaveHideWork = nil
                // 正把卡片往下拖到别的应用里时不收起，否则拖动的来源窗口没了
                guard self.shownByHover, !self.pointerNearShelf(),
                      self.view?.draggingCard == nil else { return }
                self.hide()
            }
            leaveHideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
    }

    /// 多块屏幕时：鼠标推到了另一块屏幕的边上，悬挂架和把手先搬过去
    private func pointerMovedWhileHidden() {
        guard let view, view.count > 0 else { return }
        let mouse = NSEvent.mouseLocation
        if !handle.isPeeking,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }),
           screen.frame != window?.frame,
           handle.wouldTrigger(at: mouse, on: screen, side: view.side, topInset: menuBarHeight(of: screen)) {
            followMouseScreen()
        }
        handle.pointerMoved()
    }

    /// 鼠标停在悬挂架上时才占用 Esc（按一下收起），移开就还给别的应用。
    /// 悬挂架窗口不抢焦点，收不到普通按键，只能用全局快捷键
    /// 截图架临时拿走的键（Esc、⌘F、卡片上的空格/Delete/⌘C）：鼠标停在截图架上不动 5 秒就全部还回去，
    /// 鼠标放在那里、人去别的应用打字时不会被吞掉。一动鼠标又拿回来
    private var tempKeysIdle: DispatchWorkItem?

    private func setEscapeArmed(_ on: Bool) {
        tempKeysIdle?.cancel()
        tempKeysIdle = nil
        if on {
            let idle = DispatchWorkItem { [weak self] in self?.setEscapeArmed(false) }
            tempKeysIdle = idle
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: idle)
        }
        setFindArmed(on)
        setCardKeysArmed(on && view?.hovered != nil && searchBar == nil && view?.draggingCard == nil)
        // 搜索框开着时 Esc 给搜索框（它自己收）
        if searchBar != nil && on { return }
        let id = AppSettings.HotKeyID.escape.rawValue
        let center = HotKeyCenter.shared
        guard on != center.isRegistered(id) else { return }
        if on {
            center.register(id: id, HotKey(keyCode: UInt32(kVK_Escape), modifiers: 0)) { [weak self] in
                guard let self, self.isShown, self.view?.draggingCard == nil else { return }
                self.hide()
            }
        } else {
            center.register(id: id, nil) {}
        }
    }

    /// 鼠标停在一张卡片上：空格快速查看、Delete 删掉、⌘C 复制（和访达一样）。
    /// 这几个键是全局拿走的，所以只在鼠标停在卡片上、而且最近动过时才拿（5 秒不动就还回去，见 setEscapeArmed）
    private func setCardKeysArmed(_ on: Bool) {
        let center = HotKeyCenter.shared
        let ids: [(AppSettings.HotKeyID, HotKey, ShelfAction?)] = [
            (.cardQuickLook, HotKey(keyCode: UInt32(kVK_Space), modifiers: 0), nil),
            (.cardTrash, HotKey(keyCode: UInt32(kVK_Delete), modifiers: 0), .trash),
            (.cardCopy, HotKey(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey)), .copy),
        ]
        guard on else {
            // 三个都看：哪一个注册上了都要还回去（其中一个被别的应用占着时，以前会漏掉另外两个）
            for (id, _, _) in ids where center.isRegistered(id.rawValue) { center.register(id: id.rawValue, nil) {} }
            return
        }
        for (id, key, action) in ids where !center.isRegistered(id.rawValue) {
            center.register(id: id.rawValue, key) { [weak self] in
                guard let self, self.isShown, self.searchBar == nil, let item = self.view?.hovered?.item else { return }
                self.lastInteraction = Date()
                if let action { self.onAction?(action, item) } else { ShelfQuickLook.shared.show(item.url) }
            }
        }
    }

    private func pointerNearShelf() -> Bool {
        guard let window, let view else { return false }
        let p = view.layerPoint(window.convertPoint(fromScreen: NSEvent.mouseLocation))
        return p.y <= view.topInset + Metrics.cardMaxSize.height + 90
    }

    private func checkAutoHide() {
        guard isShown, !shownByHover, editingURL == nil, searchBar == nil, let duration = displayDuration,
              view?.hovered == nil, view?.draggingCard == nil, view?.reorderingCard == nil,
              view?.undoPill.isVisible != true else { return }
        if Date().timeIntervalSince(lastInteraction) > max(duration, hoverGrace) { hide() }
    }

    // MARK: ShelfViewDelegate

    func shelfViewDidClickEmpty(_ view: ShelfView) { hide() }

    func shelfView(_ view: ShelfView, didClick item: ShelfItem) {
        lastInteraction = Date()
        onActivate?(item)
    }

    func shelfView(_ view: ShelfView, didDoubleClick item: ShelfItem) {
        lastInteraction = Date()
        onEdit?(item)
    }

    // MARK: 拿下来改

    /// 正拿着的那张：截图架一直开着（不自动收），鼠标不在上面也不收
    private(set) var editingURL: URL?

    /// 把卡片拿下来：返回它在屏幕上的位置和屏幕（编辑窗口从这里放大出去）
    func lift(_ item: ShelfItem) -> (CGRect, NSScreen)? {
        guard let view, let window, let screen = window.screen, let r = view.liftCard(item.url) else { return nil }
        editingURL = item.url.standardizedFileURL
        shownByHover = false
        leaveHideWork?.cancel()
        leaveHideWork = nil
        setEscapeArmed(false)
        return (screenRect(r), screen)
    }

    /// 那张卡片现在在屏幕上的位置（缩回去时对着它）。截图架收起来了就没有
    /// pixelSize：存回去以后图的大小变了（加了背景），卡片按新的比例算（顶边、中线不变）
    func editingCardFrame(pixelSize: CGSize? = nil) -> CGRect? {
        guard let url = editingURL, isShown, let view, var r = view.cardFrame(url) else { return nil }
        if let px = pixelSize {
            let s = Metrics.cardSize(for: px)
            r = CGRect(x: r.midX - s.width / 2, y: r.minY, width: s.width, height: s.height)
        }
        return screenRect(r)
    }

    /// 卡片下面出"撤销"（存回去以后几秒内可以退回原来的）
    func showUndo(_ message: String, for url: URL, onUndo: @escaping () -> Void) {
        guard let view, let x = view.screenX(of: url) else { return }
        view.showUndo(message, atX: x, onUndo: onUndo)
        lastInteraction = Date()
    }

    /// 挂回去（不管存没存）
    func endEdit(fadeIn: Bool) {
        guard let url = editingURL else { return }
        editingURL = nil
        view?.landCard(url, fadeIn: fadeIn)
        lastInteraction = Date()
    }

    /// 原来的文件改好了：卡片换成新的样子（还在原来的位置）
    func replaced(_ url: URL, thumbnail: CGImage?) {
        guard let item = ShelfItem.load(url) else { return }
        view?.replaceCard(item, thumbnail: thumbnail)
        ShelfTextIndex.shared.prioritize(item)
    }

    /// 根图层坐标（y 向下）→ 屏幕坐标
    private func screenRect(_ r: CGRect) -> CGRect {
        guard let view, let window else { return r }
        let v = CGRect(x: r.minX, y: view.bounds.height - r.maxY, width: r.width, height: r.height)
        return window.convertToScreen(view.convert(v, to: nil))
    }

    func shelfView(_ view: ShelfView, menuFor item: ShelfItem) -> NSMenu? {
        // 右键菜单开着时 Esc 要留给菜单自己关
        setEscapeArmed(false)
        return menuProvider?(item)
    }
    func shelfView(_ view: ShelfView, perform action: ShelfAction, on item: ShelfItem) {
        lastInteraction = Date()
        onAction?(action, item)
    }
    func shelfViewDidInteract(_ view: ShelfView) { lastInteraction = Date() }

    func shelfViewWillShowMenu(_ view: ShelfView) {
        // 菜单开着时 Esc 要留给菜单自己关
        setEscapeArmed(false)
    }

    /// 拖出去的过程中窗口一直点穿，松手后按鼠标现在的位置重新决定接不接收点击
    func shelfViewDidEndDragOut(_ view: ShelfView) {
        lastInteraction = Date()
        mouseMoved()
    }

    func shelfViewDidFinishHiding(_ view: ShelfView) {
        guard !view.isShown else { return }
        if let side = pendingSide {
            // 展开时在设置里换了边：换好后从新的那边再展开
            pendingSide = nil
            view.side = side
            placeHandle()
            show()
            return
        }
        window?.orderOut(nil)
        handle.setArmed(true)
    }

    func shelfViewDidChangeItems(_ view: ShelfView) {
        ShelfStore.savePinned(view.pinnedURLs)
        handle.setCount(view.count)
        updateHandleCards()
        onItemsChanged?()
    }
}
