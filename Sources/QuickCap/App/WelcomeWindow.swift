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

    static let doneKey = "welcomeDone"
    /// 中途重新打开 QuickCap（打开权限后系统要求的）时，接着上次那一页
    static let pageKey = "welcomePage"

    static var shouldShow: Bool { !UserDefaults.standard.bool(forKey: doneKey) }

    func show(page: WelcomeModel.Page? = nil) {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let saved = UserDefaults.standard.string(forKey: Self.pageKey).flatMap(WelcomeModel.Page.init(rawValue:))
        let m = WelcomeModel(start: page ?? saved ?? .hello)
        m.onFinish = { [weak self] openSettings in self?.finish(openSettings: openSettings) }
        model = m
        let host = NSHostingController(rootView: WelcomeView(model: m, settings: .shared))
        host.sizingOptions = [.preferredContentSize]
        let w = WelcomeNSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "Welcome to QuickCap"
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.centerOnMouseScreen()
        window = w
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
        markDone()
        model?.stop()
        model = nil
        window = nil
    }

    /// 调试用
    var debugWindow: NSWindow? { window }
    var debugModel: WelcomeModel? { model }
}

@MainActor
final class WelcomeModel: ObservableObject {
    enum Page: String { case hello, access, shortcuts, ready }

    @Published private(set) var page: Page
    @Published private(set) var access: ScreenAccess.State
    /// 点过"打开系统设置"：说明文字换成下一步怎么做
    @Published private(set) var askedThisTime = false
    /// 往后翻还是往前翻（页面从哪边滑进来）
    @Published private(set) var forward = true
    let pages: [Page]
    var onFinish: ((_ openSettings: Bool) -> Void)?
    private var timer: Timer?
    private var activeObserver: NSObjectProtocol?

    init(start: Page) {
        let a = ScreenAccess.state
        access = a
        // 一开始就有权限：不用这一页（中途重新打开回到这一页的除外）
        pages = a == .on && start != .access ? [.hello, .shortcuts, .ready] : [.hello, .access, .shortcuts, .ready]
        page = pages.contains(start) ? start : .hello
        watch()
    }

    var index: Int { pages.firstIndex(of: page) ?? 0 }

    func next() {
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
        watch()
    }

    /// 权限页的主按钮
    func primaryOnAccess() {
        switch access {
        case .on: next()
        case .needsReopen:
            if AppSettings.shared.persist { UserDefaults.standard.set(Page.ready.rawValue, forKey: WelcomeWindowController.pageKey) }
            ScreenAccess.relaunch()
        case .off:
            askedThisTime = true
            if ScreenAccess.request() { refresh() }
        }
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
        guard page == .access, access != .on else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        let a = ScreenAccess.state
        guard a != access else { return }
        withAnimation(.spring(duration: 0.4, bounce: 0.2)) { access = a }
        if a == .on {
            stop()
            // 开关拨过去的动画看完再翻页
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self, self.page == .access else { return }
                self.next()
            }
        }
    }

    /// 调试用：换一个权限状态看界面
    func debugSet(access a: ScreenAccess.State, asked: Bool) {
        access = a
        askedThisTime = asked
    }
}


/// 欢迎窗口：⌘W、Esc 关掉，⌘Q 退出（菜单栏应用没有系统菜单，要自己接）
final class WelcomeNSWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        return handleStandardKey(event)
    }
    override func cancelOperation(_ sender: Any?) { performClose(nil) }
}
