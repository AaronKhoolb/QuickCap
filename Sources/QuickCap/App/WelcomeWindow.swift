import AppKit
import SwiftUI

/// 第一次打开时的欢迎窗口：认识一下 → 屏幕录制权限（已经有了就跳过）→ 自己选快捷键（可以不选）→ 好了。
/// 不强迫试用、不问偏好：偏好都用默认值，最后一页可以打开设置。
/// 关掉窗口也算看过了，之后不再出现
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: WelcomeModel?
    var onOpenSettings: (() -> Void)?
    /// 欢迎窗口出现、关掉（截图架跟着藏起来、放出来）
    var onVisibleChange: ((Bool) -> Void)?

    static let doneKey = "welcomeDone"
    /// 中途重新打开 QuickCap（打开权限后系统要求的）时，接着上次那一页
    static let pageKey = "welcomePage"

    static var shouldShow: Bool { !UserDefaults.standard.bool(forKey: doneKey) }

    /// 欢迎页看过了，但权限后来没了（换了版本系统要重新给、用户自己关掉）：只放权限那几页
    static var missingPermissions: Bool { ScreenAccess.state == .off || !UIElementEdges.isTrusted }

    /// 截图、截图架、搜索之前先问一下：欢迎页还没走完就把它叫出来，返回 true（这次操作不做）
    func blocksApp() -> Bool {
        if window != nil { show(); return true }
        if Self.shouldShow, !DebugOptions.isDebugRun { show(); return true }
        return false
    }

    /// 截图时发现没有权限：只放权限那几页
    func showPermissions() {
        if window != nil { show(); return }
        show(permissionsOnly: true)
    }

    /// 欢迎窗口开着：截图、截图架先不能用，按快捷键只把欢迎窗口叫到前面
    var isShowing: Bool { window != nil }

    /// QuickCap 正在退出（系统的"退出并重新打开"、⌘Q）：窗口跟着关掉不算看完，下次接着上次那一页
    static var appTerminating = false

    /// 开设置窗口时：欢迎页暂时不浮在最上面（再叫回来时又浮上去）
    func yield() { window?.level = .normal }

    func show(page: WelcomeModel.Page? = nil, permissionsOnly: Bool = false) {
        if let window { window.level = .floating; window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let saved = UserDefaults.standard.string(forKey: Self.pageKey).flatMap(WelcomeModel.Page.init(rawValue:))
        let m = WelcomeModel(start: page ?? saved ?? .hello, permissionsOnly: permissionsOnly && !Self.shouldShow)
        m.onFinish = { [weak self] openSettings in self?.finish(openSettings: openSettings) }
        // 去系统设置打开权限时让开（不然浮在最上面挡住开关），其它时候一直在最上面
        m.onYield = { [weak self] yield in self?.window?.level = yield ? .normal : .floating }
        model = m
        // 第一下点击就算数：窗口不在最前面时点快捷键框，不能只把窗口叫到前面（不然接着按的键进了别的 app）
        let host = FirstClickHostingView(rootView: WelcomeView(model: m, settings: .shared))
        let w = WelcomeNSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                                styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.contentView = host
        // 欢迎页没走完之前一直在最上面
        w.level = .floating
        // 不要左上角的红绿灯；权限没给完不能关（⌘Q 可以退出）
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { w.standardWindowButton(b)?.isHidden = true }
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "Welcome to QuickCap"
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.centerOnMouseScreen()
        window = w
        onVisibleChange?(true)
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    private func finish(openSettings: Bool) {
        markDone()
        window?.close()
        if openSettings { onOpenSettings?() }
    }

    private func markDone() {
        guard AppSettings.shared.persist else { return }
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        UserDefaults.standard.removeObject(forKey: Self.pageKey)
    }

    func windowWillClose(_ notification: Notification) {
        model?.stop()
        model = nil
        window = nil
        onVisibleChange?(false)
    }

    /// 调试用
    var debugWindow: NSWindow? { window }
    var debugModel: WelcomeModel? { model }
}

@MainActor
final class WelcomeModel: ObservableObject {
    enum Page: String { case hello, access, accessibility, shortcuts, ready }

    @Published private(set) var page: Page
    @Published private(set) var access: ScreenAccess.State
    /// 辅助功能（自动滚动、吸附按钮和文本框要用）
    @Published private(set) var axTrusted: Bool
    /// 只放权限那几页（欢迎页看过了，权限后来没了）
    let permissionsOnly: Bool
    /// 点过"打开系统设置"：说明文字换成下一步怎么做
    @Published private(set) var askedThisTime = false
    /// 往后翻还是往前翻（页面从哪边滑进来）
    @Published private(set) var forward = true
    let pages: [Page]
    var onFinish: ((_ openSettings: Bool) -> Void)?
    var onYield: ((Bool) -> Void)?
    private var timer: Timer?
    private var activeObserver: NSObjectProtocol?

    init(start: Page, permissionsOnly: Bool = false) {
        let a = ScreenAccess.state
        let ax = UIElementEdges.isTrusted
        access = a
        axTrusted = ax
        self.permissionsOnly = permissionsOnly
        // 一开始就有的权限不用那一页（中途重新打开回到那一页的除外，让人看到开关已经打开再自己翻过去）
        var perms: [Page] = []
        if a != .on || start == .access { perms.append(.access) }
        if !ax || start == .accessibility { perms.append(.accessibility) }
        pages = permissionsOnly ? (perms.isEmpty ? [.access] : perms) : [.hello] + perms + [.shortcuts, .ready]
        page = pages.contains(start) ? start : pages[0]
        watch()
    }

    /// 这一页的权限给了没有（没给不能往下翻）
    var canContinue: Bool {
        switch page {
        case .access: return access == .on
        case .accessibility: return axTrusted
        default: return true
        }
    }

    var index: Int { pages.firstIndex(of: page) ?? 0 }

    func next() {
        guard canContinue else { return }
        guard index + 1 < pages.count else { onFinish?(false); return }
        go(to: pages[index + 1], forward: true)
    }

    func back() {
        guard index > 0 else { return }
        go(to: pages[index - 1], forward: false)
    }

    private func go(to p: Page, forward f: Bool) {
        forward = f
        withAnimation(.spring(duration: 0.5, bounce: 0.12)) { page = p }
        if AppSettings.shared.persist { UserDefaults.standard.set(p.rawValue, forKey: WelcomeWindowController.pageKey) }
        onYield?(false)
        watch()
    }

    /// 权限页的主按钮
    func primaryOnAccess() {
        switch access {
        case .on: next()
        case .needsReopen: reopen()
        case .off:
            askedThisTime = true
            onYield?(true)
            if ScreenAccess.request() { refresh() }
        }
    }

    /// 辅助功能页的主按钮：第一次由 app 发起（系统把 QuickCap 列进去、弹系统的提示），之后直接打开系统设置那一页
    func primaryOnAccessibility() {
        if axTrusted { next(); return }
        askedThisTime = true
        onYield?(true)
        if !UserDefaults.standard.bool(forKey: Self.axAskedKey) {
            UserDefaults.standard.set(true, forKey: Self.axAskedKey)
            UIElementEdges.requestAccess()
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    private static let axAskedKey = "accessibilityAsked-" + ScreenAccess.versionTag

    /// 重新打开后回到权限页：真的生效了会自己翻到下一页，没生效还能看到提示
    func reopen() {
        if AppSettings.shared.persist { UserDefaults.standard.set(Page.access.rawValue, forKey: WelcomeWindowController.pageKey) }
        ScreenAccess.relaunch()
    }

    func finish(openSettings: Bool) { onFinish?(openSettings) }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
    }

    /// 在权限页时盯着开关：用户在系统设置里打开后，这边马上跟着变
    private func watch() {
        stop()
        guard (page == .access && access != .on) || (page == .accessibility && !axTrusted) else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        if page == .accessibility {
            let t = UIElementEdges.isTrusted
            guard t != axTrusted else { return }
            withAnimation(.spring(duration: 0.4, bounce: 0.2)) { axTrusted = t }
            if t { stop(); advanceSoon(from: .accessibility) }
            return
        }
        Task { [weak self] in
            let a = await ScreenAccess.probe()
            self?.apply(a)
        }
    }

    private func apply(_ a: ScreenAccess.State) {
        guard a != access else { return }
        withAnimation(.spring(duration: 0.4, bounce: 0.2)) { access = a }
        if a == .on { stop(); advanceSoon(from: .access) }
    }

    /// 开关拨过去的动画看完再翻页
    private func advanceSoon(from p: Page) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, self.page == p else { return }
            self.askedThisTime = false
            self.next()
        }
    }

    /// 调试用：换一个权限状态看界面
    func debugSet(access a: ScreenAccess.State, asked: Bool) {
        access = a
        askedThisTime = asked
    }
}


/// 窗口不在最前面时，第一下点击也直接交给按钮、快捷键框
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 欢迎窗口：⌘W、Esc 关掉，⌘Q 退出（菜单栏应用没有系统菜单，要自己接）
final class WelcomeNSWindow: NSWindow {
    /// 点到窗口时 QuickCap 不是当前 app：先切过来，后面按的键才会进这个窗口
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !NSApp.isActive { NSApp.activate(); makeKey() }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if f == .command, event.charactersIgnoringModifiers?.lowercased() == "w" { return true }
        return handleStandardKey(event)
    }
    /// 欢迎页走完才能用 QuickCap：Esc、⌘W 不关
    override func cancelOperation(_ sender: Any?) {}
}
