import AppKit
import ServiceManagement
import SwiftUI

/// 设置窗口：五页，用窗口顶上的工具栏切换，标题跟着换成那一页的名字。
/// 样子照 Finder、Safari 自己的设置：左边一列标签（右对齐、带冒号），右边是控件；勾选框；
/// 同一类放一起，类和类之间一条细线；说明字只在真的需要时写一行小字。
/// General：开机启动。Capture：存哪里、格式、截图时的开关（和截图界面 Options 菜单是同一份）。
/// Shortcuts：All-In-One 和可选的单独快捷键。Shelf：截图架。Scan：识别语言、换行
@MainActor
final class SettingsWindowController: NSObject, NSToolbarDelegate {
    enum Tab: Int, CaseIterable { case general, capture, shortcuts, shelf, scan }

    private struct PaneInfo {
        let id: NSToolbarItem.Identifier
        let title: String
        let symbol: String
        let host: NSHostingController<AnyView>
    }

    private var window: NSWindow?
    private var panes: [PaneInfo] = []
    private var current: Int?
    private let container = NSView()
    /// 当前这一页自己变高变矮时（比如出现一行红字），窗口跟着动
    private var sizeObserver: NSKeyValueObservation?

    func show(tab: Tab? = nil) {
        let firstTime = window == nil
        if firstTime { build() }
        let saved = UserDefaults.standard.object(forKey: "settingsTab") as? Int
        select(tab?.rawValue ?? current ?? saved ?? 0, animated: window?.isVisible == true)
        if firstTime { placeWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let s = AppSettings.shared
        let list: [(String, String, AnyView)] = [
            ("General", "gearshape", AnyView(GeneralPane(settings: s))),
            ("Capture", "viewfinder", AnyView(CapturePane(settings: s))),
            ("Shortcuts", "keyboard", AnyView(ShortcutsPane(settings: s))),
            ("Shelf", "rectangle.stack", AnyView(ShelfPane(settings: s))),
            ("Scan", "text.viewfinder", AnyView(ScanPane(settings: s))),
        ]
        panes = list.map { title, symbol, view in
            let host = NSHostingController(rootView: view)
            host.sizingOptions = .preferredContentSize
            return PaneInfo(id: NSToolbarItem.Identifier("settings." + title.lowercased()), title: title, symbol: symbol, host: host)
        }
        let w = SettingsWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 200), styleMask: [.titled, .closable],
                               backing: .buffered, defer: false)
        w.onMove = { [weak self] in self?.savePosition() }
        w.isReleasedWhenClosed = false
        w.toolbarStyle = .preference
        container.wantsLayer = true
        w.contentView = container
        let tb = NSToolbar(identifier: "QuickCapSettings")
        tb.delegate = self
        tb.displayMode = .iconAndLabel
        tb.allowsUserCustomization = false
        w.toolbar = tb
        window = w
    }

    /// 换页：窗口上边不动，高度顺着弹到新一页的高度；旧的一页淡出，新的一页淡入，同时进行
    private func select(_ i: Int, animated: Bool) {
        guard let w = window, panes.indices.contains(i) else { return }
        let pane = panes[i]
        w.toolbar?.selectedItemIdentifier = pane.id
        w.title = pane.title
        guard i != current else { return }
        let old = current.map { panes[$0].host.view }
        current = i
        UserDefaults.standard.set(i, forKey: "settingsTab")
        // 换页时正在录的快捷键停下
        KeyRecording.stopActive()

        let v = pane.host.view
        let size = paneSize(pane)
        // 贴着上边放：容器变高变矮时，这一页跟着上边走
        v.autoresizingMask = [.minYMargin]
        v.frame = CGRect(x: 0, y: container.bounds.height - size.height, width: size.width, height: size.height)
        v.alphaValue = old == nil || !animated ? 1 : 0
        container.addSubview(v)

        sizeObserver = pane.host.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.fitWindow(animated: true) }
        }

        let target = frame(for: size, in: w)
        let move = animated && !ReduceMotion.isOn && old != nil
        guard move else {
            old?.removeFromSuperview()
            w.setFrame(target, display: true)
            v.frame.origin.y = container.bounds.height - size.height
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
            ctx.allowsImplicitAnimation = true
            w.animator().setFrame(target, display: true)
            old?.animator().alphaValue = 0
            v.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                for sub in self.container.subviews where sub !== self.panes[self.current ?? 0].host.view { sub.removeFromSuperview() }
                old?.alphaValue = 1
            }
        })
    }

    /// 第一次打开：放回上次关掉时的位置（左上角）；那块屏幕不在了就放中间
    private func placeWindow() {
        guard let w = window else { return }
        if let s = UserDefaults.standard.string(forKey: "settingsTopLeft") {
            let p = NSPointFromString(s)
            if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(CGPoint(x: p.x + 40, y: p.y - 10)) }) {
                w.setFrameTopLeftPoint(p)
                return
            }
        }
        w.centerOnMouseScreen()
    }

    private func savePosition() {
        guard let w = window, w.isVisible else { return }
        UserDefaults.standard.set(NSStringFromPoint(CGPoint(x: w.frame.minX, y: w.frame.maxY)), forKey: "settingsTopLeft")
    }

    /// 这一页要多大（SwiftUI 自己算的高度，宽度每页一样）
    private func paneSize(_ p: PaneInfo) -> CGSize {
        let s = p.host.sizeThatFits(in: CGSize(width: 480, height: 4000))
        return CGSize(width: 480, height: ceil(s.height))
    }

    /// 内容区是 size 时的窗口位置：左上角不动
    private func frame(for size: CGSize, in w: NSWindow) -> CGRect {
        var f = w.frameRect(forContentRect: CGRect(origin: .zero, size: size))
        let old = w.frame
        f.origin = CGPoint(x: old.minX, y: old.maxY - f.height)
        return f
    }

    /// 当前这一页高度变了（多了一行提示、红字……）
    private func fitWindow(animated: Bool) {
        guard let w = window, let i = current else { return }
        let size = paneSize(panes[i])
        let target = frame(for: size, in: w)
        guard abs(target.height - w.frame.height) > 0.5 else { return }
        if animated && !ReduceMotion.isOn && w.isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
                w.animator().setFrame(target, display: true)
            }
        } else {
            w.setFrame(target, display: true)
        }
    }

    @objc private func toolbarClicked(_ sender: NSToolbarItem) {
        guard let i = panes.firstIndex(where: { $0.id == sender.itemIdentifier }) else { return }
        select(i, animated: true)
    }

    // MARK: 工具栏

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { panes.map(\.id) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { panes.map(\.id) }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { panes.map(\.id) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let p = panes.first(where: { $0.id == id }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = p.title
        item.image = NSImage(systemSymbolName: p.symbol, accessibilityDescription: p.title)
        item.target = self
        item.action = #selector(toolbarClicked(_:))
        return item
    }

    /// 调试用：窗口截图
    var debugWindowNumber: Int? { window?.windowNumber }
    /// 调试用：换到第几页
    func debugSelect(_ i: Int) { select(i, animated: true) }
    var debugFrame: CGRect { window?.frame ?? .zero }
}

extension NSWindow {
    /// QuickCap 是菜单栏应用，没有系统菜单，普通窗口里的 ⌘W、⌘Q、⌘M、⌘C/⌘V/⌘X/⌘A、⌘Z 要自己接。
    /// 只在设置、欢迎这种普通窗口里用（不放进全局菜单：那样会抢截图界面和编辑器自己的 ⌘C、⌘Z）
    func handleStandardKey(_ event: NSEvent) -> Bool {
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard f == .command || f == [.command, .shift], let ch = event.charactersIgnoringModifiers?.lowercased() else { return false }
        if f == [.command, .shift] {
            if ch == "z" { return NSApp.sendAction(Selector(("redo:")), to: nil, from: self) }
            return false
        }
        switch ch {
        case "w": performClose(nil); return true
        case "q": NSApp.terminate(nil); return true
        case "m": if styleMask.contains(.miniaturizable) { miniaturize(nil); return true }; return false
        case "c": return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
        case "v": return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
        case "x": return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
        case "a": return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
        case "z": return NSApp.sendAction(Selector(("undo:")), to: nil, from: self)
        default: return false
        }
    }

    /// 放在鼠标所在那块屏幕的中间偏上（多屏时开在用户正在用的屏幕上，不总是主屏）
    func centerOnMouseScreen() {
        guard let s = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { center(); return }
        let v = s.visibleFrame, f = frame
        setFrameOrigin(CGPoint(x: (v.midX - f.width / 2).rounded(), y: (v.minY + (v.height - f.height) * 0.62).rounded()))
    }
}

/// 设置窗口。QuickCap 是菜单栏 app，没有自己的菜单，⌘W 要自己接；挪动时记下位置
private final class SettingsWindow: NSWindow {
    var onMove: (() -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        return handleStandardKey(event)
    }
    // 换页时窗口高度每帧都在变：位置停下来 0.3 秒再记（以前每一帧都写一次设置）
    private var moveWork: DispatchWorkItem?
    private func movedSoon() {
        moveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.onMove?() }
        moveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        movedSoon()
    }
    override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(point)
        movedSoon()
    }
    override func close() {
        KeyRecording.stopActive()
        moveWork?.cancel()
        onMove?()
        super.close()
    }
}

/// 同一时间只有一个快捷键框在录：点另一个、换页、关窗口时，正在录的那个停下
@MainActor
private enum KeyRecording {
    static var stop: (() -> Void)?
    static func stopActive() { let s = stop; stop = nil; s?() }
}

// MARK: 排版

/// 一页：左边一列标签（右对齐），右边控件。每页一样宽，左边那列一样宽，换页时控件不跳
private enum Look {
    /// QuickCap 的橙色（勾选框、录快捷键时的边）
    static let accent = Color(nsColor: NSColor(calibratedRed: 1, green: 0.54, blue: 0, alpha: 1))
    /// 左边标签那一列的宽度
    static let labelWidth: CGFloat = 112
}

private struct Page<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) { content }
            .padding(.leading, 20)
            .padding(.trailing, 28)
            .padding(.top, 22)
            .padding(.bottom, 24)
            .frame(width: 480, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 一行：左边标签，右边一列控件
private struct Row<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }
    var body: some View {
        GridRow {
            Text(label.isEmpty ? "" : label + ":")
                .frame(width: Look.labelWidth, alignment: .trailing)
                .gridColumnAlignment(.trailing)
            VStack(alignment: .leading, spacing: 7) { content }
        }
    }
}

/// 类和类之间的细线
private struct Rule: View {
    var body: some View {
        GridRow {
            Divider().gridCellColumns(2).padding(.vertical, 4)
        }
    }
}

/// 勾选框，下面可以带一行小字（和勾选框的字对齐）
private struct Check: View {
    let title: String
    var hint: String?
    @Binding var isOn: Bool
    init(_ title: String, hint: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.hint = hint
        _isOn = isOn
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: $isOn).toggleStyle(.checkbox).tint(Look.accent)
            if let hint { Hint(hint).padding(.leading, 20) }
        }
    }
}

/// 灰色小字
private struct Hint: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: General

/// 开机启动：系统的登录项（SMAppService），状态以系统那边为准
@MainActor
private final class LoginItem: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var problem: String?

    init() {
        refresh()
        // 用户去系统设置里批准了、回到这个窗口：重新看一下状态（红字该消失就消失）
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// 要等用户在系统设置里批准的也算开着（勾着、下面一行提示），不然刚勾上马上自己取消，像没点上
    func refresh() {
        let s = SMAppService.mainApp.status
        enabled = s == .enabled || s == .requiresApproval
        if s == .requiresApproval {
            problem = "Allow QuickCap in System Settings → General → Login Items."
        } else if problem?.hasPrefix("Allow") == true {
            problem = nil
        }
    }

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            problem = nil
        } catch {
            problem = "Couldn't change this. Try again in System Settings → General → Login Items."
        }
        refresh()
    }
}

private struct GeneralPane: View {
    @ObservedObject var settings: AppSettings
    @StateObject private var login = LoginItem()

    var body: some View {
        Page {
            Row("Startup") {
                Check("Open QuickCap at login", isOn: Binding(get: { login.enabled }, set: { login.set($0) }))
                if let p = login.problem { Text(p).font(.callout).foregroundStyle(.red).padding(.leading, 20) }
            }
            Rule()
            Row("Version") {
                Text(Self.version).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .onAppear { login.refresh() }
    }

    private static var version: String {
        let i = Bundle.main.infoDictionary
        let v = i?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = i?["CFBundleVersion"] as? String
        return b.map { "\(v) (\($0))" } ?? v
    }
}

// MARK: Capture

private struct CapturePane: View {
    @ObservedObject var settings: AppSettings
    /// 正在搬旧截图：搬完前不能再换文件夹
    @State private var moving = false
    /// 权限状态变了让提示刷新（打开设置页、点开关时）
    @State private var axTick = 0

    var body: some View {
        Page {
            Row("Save to") {
                HStack(spacing: 6) {
                    Picker("", selection: folderBinding) {
                        ForEach(Self.folders, id: \.path) { f in
                            Label(f.name, systemImage: "folder").tag(f.path)
                        }
                        if !Self.folders.contains(where: { $0.path == settings.screenshotFolder }) {
                            Label(folderName, systemImage: "folder").tag(settings.screenshotFolder)
                        }
                        Divider()
                        Text("Other…").tag("__choose__")
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(moving)
                    Button {
                        NSWorkspace.shared.open(settings.screenshotFolderURL)
                    } label: { Image(systemName: "arrow.up.forward.square") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Show in Finder")
                }
            }
            Row("Format") {
                Picker("", selection: $settings.captureFormat) {
                    ForEach(CaptureOutput.Format.allCases, id: \.self) { f in Text(f.title).tag(f) }
                }
                .labelsHidden()
                .fixedSize()
                Check("Keep HDR when the display shows it",
                      hint: hdrHint,
                      isOn: $settings.captureHDR)
                    .disabled(!settings.captureFormat.keepsHDR || settings.scaleToStandard || settings.convertToSRGB)
                Check("Scale Retina captures to 1×", hint: "Half the pixels; looks the same size in documents and on the web.",
                      isOn: $settings.scaleToStandard)
                Check("Convert to sRGB", hint: "More consistent colors on other computers and browsers.", isOn: $settings.convertToSRGB)
            }
            Row("After capture") {
                Check("Copy to clipboard", isOn: $settings.captureCopy)
                Check("Play sound", isOn: $settings.captureSound)
            }
            Rule()
            Row("Windows") {
                Check("Include shadow", hint: "Hold ⌥ while clicking to switch", isOn: $settings.windowShadow)
                Check("Show desktop wallpaper behind", isOn: $settings.windowWallpaper)
            }
            Row("While selecting") {
                Check("Freeze the screen", hint: settings.captureTimer > 0 ? "Off while a timer is set" : nil,
                      isOn: $settings.freezeScreen)
                    .disabled(settings.captureTimer > 0)
                Check("Snap to edges", isOn: $settings.snapToEdges)
                Check("Also snap to buttons and fields", hint: elementHint, isOn: elementBinding)
                    .disabled(!settings.snapToEdges)
                Check("Show magnifier", isOn: $settings.showMagnifier)
                Check("Remember last selection", isOn: $settings.rememberSelection)
            }
            Row("Include") {
                Check("Mouse pointer", isOn: $settings.showPointer)
                Check("Hide desktop icons while capturing", isOn: $settings.hideDesktopIcons)
            }
        }
    }

    private static let folders: [(name: String, path: String)] = [
        ("QuickCap", AppSettings.defaultScreenshotFolder), ("Desktop", "~/Desktop"), ("Documents", "~/Documents"),
    ]

    /// 打开时要辅助功能权限：没有就由 app 发起请求（系统把 QuickCap 列进去，用户只开开关）
    private var elementBinding: Binding<Bool> {
        Binding(get: { settings.snapToUIElements }, set: { on in
            settings.snapToUIElements = on
            if on, !UIElementEdges.isTrusted { UIElementEdges.requestAccess() }
            axTick += 1
        })
    }
    private var elementHint: String? {
        _ = axTick
        guard settings.snapToUIElements else { return nil }
        return UIElementEdges.isTrusted ? nil : "Needs Accessibility. Turn on QuickCap in System Settings."
    }

    private var hdrHint: String? {
        if !settings.captureFormat.keepsHDR { return "Only HEIC can keep HDR." }
        if settings.scaleToStandard || settings.convertToSRGB { return "Off while scaling to 1× or converting to sRGB." }
        return nil
    }

    private var folderName: String {
        FileManager.default.displayName(atPath: (settings.screenshotFolder as NSString).expandingTildeInPath)
    }

    private var folderBinding: Binding<String> {
        Binding(get: { settings.screenshotFolder }, set: { v in
            if v == "__choose__" { chooseFolder() } else { changeFolder(to: v) }
        })
    }

    /// 换"Save to"：旧文件夹里有 QuickCap 自己存的截图时先问一下搬不搬。
    /// 搬：文件挪到新文件夹（重名的加数字，别的文件一张不碰），置顶记录里的路径跟着换，再切到新文件夹
    private func changeFolder(to value: String) {
        let old = settings.screenshotFolderURL
        let new = URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
        let files = FolderMigration.candidates(in: old, movingTo: new)
        guard !files.isEmpty else { settings.screenshotFolder = value; return }
        let name = { (u: URL) in FileManager.default.displayName(atPath: u.path) }
        let a = NSAlert()
        a.messageText = "Move your screenshots to “\(name(new))”?"
        a.informativeText = "QuickCap will move \(files.count) screenshot\(files.count == 1 ? "" : "s") from “\(name(old))” so the shelf keeps showing them. Other files in that folder stay where they are."
        a.addButton(withTitle: "Move Screenshots")
        a.addButton(withTitle: "Don’t Move")
        a.addButton(withTitle: "Cancel")
        NSApp.activate()
        switch a.runModal() {
        case .alertFirstButtonReturn:
            guard let app = NSApp.delegate as? AppDelegate else { settings.screenshotFolder = value; return }
            moving = true
            app.moveScreenshots(files, to: new, folder: value) { [self] failed in
                moving = false
                guard failed > 0 else { return }
                let f = NSAlert()
                f.messageText = "\(failed) screenshot\(failed == 1 ? "" : "s") couldn’t be moved"
                f.informativeText = "They are still in “\(name(old))”."
                f.runModal()
            }
        case .alertSecondButtonReturn:
            settings.screenshotFolder = value
        default:
            // 取消：设置没变，但弹出菜单已经显示成刚点的那项了，让它按设置重新显示
            settings.objectWillChange.send()
        }
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Choose"
        p.directoryURL = URL(fileURLWithPath: (settings.screenshotFolder as NSString).expandingTildeInPath)
        // 弹出菜单点了"Other…"：不管选没选，都让它按设置重新显示（不然停在"Other…"上）
        defer { settings.objectWillChange.send() }
        if p.runModal() == .OK, let url = p.url {
            // 写不进去的文件夹（只读的共享盘、没权限）不收：不然每次截图都存不下来
            guard FileManager.default.isWritableFile(atPath: url.path) else {
                let a = NSAlert()
                a.messageText = "QuickCap can’t save to “\(FileManager.default.displayName(atPath: url.path))”"
                a.informativeText = "Choose a folder you can write to."
                a.runModal()
                return
            }
            changeFolder(to: (url.path as NSString).abbreviatingWithTildeInPath)
        }
    }
}

// MARK: Shelf

private struct ShelfPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Page {
            Row("Open by") {
                Picker("", selection: $settings.revealTrigger) {
                    Text("Point at the handle").tag(RevealTrigger.hover)
                    Text("Click the handle").tag(RevealTrigger.click)
                }
                .labelsHidden()
                .fixedSize()
            }
            Row("Side") {
                Picker("", selection: $settings.side) {
                    Text("Left").tag(ShelfSide.left)
                    Text("Right").tag(ShelfSide.right)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            Row("Hide") {
                Picker("", selection: $settings.autoHideDelay) {
                    ForEach(AppSettings.autoHideChoices, id: \.self) { s in
                        Text(s > 0 ? "After \(Int(s)) seconds idle" : "Never").tag(s)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Hint("To bring it back, rest the pointer at the screen edge just below the menu bar. Drag the handle across to switch sides.")
                    .frame(width: 280, alignment: .leading)
            }
        }
    }
}

// MARK: Scan

private struct ScanPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Page {
            Row("Language") {
                Picker("", selection: $settings.scanLanguage) {
                    Text("Automatic").tag("auto")
                    Divider()
                    ForEach(TextRecognizer.languages, id: \.code) { l in Text(l.name).tag(l.code) }
                }
                .labelsHidden()
                .fixedSize()
                Hint(settings.scanLanguage == "auto" ? "Works for mixed Chinese and English" : "Use when the text is all in this language")
            }
            Row("Copied text") {
                Check("Keep line breaks",
                      hint: settings.scanKeepLineBreaks ? nil : "Lines are joined into one paragraph",
                      isOn: $settings.scanKeepLineBreaks)
            }
            Rule()
            Row("Privacy") {
                Text("Read on this Mac. Nothing is sent anywhere.").foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Shortcuts

/// 一个快捷键怎么显示：图标、名字、哪个设置、默认是什么
private struct ShortcutSpec: Identifiable {
    let id: AppSettings.HotKeyID
    let symbol: String
    let title: String
    var subtitle: String?
    let key: ReferenceWritableKeyPath<AppSettings, HotKey?>
    var defaultKey: HotKey?
    var hero = false
}

private struct ShortcutsPane: View {
    @ObservedObject var settings: AppSettings
    /// 刚才按的组合不收（比如 ⌘C）：在这一行下面说为什么，几秒后消失
    @State private var rejected: AppSettings.HotKeyID?

    private let capture: [ShortcutSpec] = [
        ShortcutSpec(id: .capture, symbol: "plus.viewfinder", title: "All-In-One", subtitle: "Area, window or screen",
                     key: \.captureKey, hero: true),
        ShortcutSpec(id: .captureArea, symbol: "rectangle.dashed", title: "Capture Area", key: \.captureAreaKey),
        ShortcutSpec(id: .captureWindow, symbol: "macwindow", title: "Capture Window", key: \.captureWindowKey),
        ShortcutSpec(id: .captureScreen, symbol: "rectangle.inset.filled", title: "Capture Screen", key: \.captureScreenKey),
        ShortcutSpec(id: .captureText, symbol: "text.viewfinder", title: "Scan Text & QR", key: \.captureTextKey),
    ]
    private let shelf: [ShortcutSpec] = [
        ShortcutSpec(id: .toggleShelf, symbol: "rectangle.stack", title: "Show or Hide Shelf", key: \.toggleShelfKey),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            group("Capture", capture)
            group("Shelf", shelf).padding(.top, 18)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 22)
        .frame(width: 480, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func group(_ title: String, _ rows: [ShortcutSpec]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 2)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, spec in
                    if i > 0 { Divider().padding(.leading, 44) }
                    row(spec)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func row(_ spec: ShortcutSpec) -> some View {
        HStack(spacing: 12) {
            Image(systemName: spec.symbol)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(spec.hero ? Look.accent : Color.primary.opacity(0.75))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(spec.title)
                if rejected == spec.id {
                    Text("Use ⌃, or ⌘ with ⇧ or ⌥, so other apps keep their shortcuts")
                        .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                } else if let p = problem(spec) {
                    Text(p).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                } else if let s = spec.subtitle {
                    Text(s).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            KeyRecorder(key: binding(spec.key), defaultKey: spec.defaultKey, onReject: {
                rejected = spec.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if rejected == spec.id { rejected = nil } }
            }, onRecord: { rejected = nil })
        }
        .padding(.horizontal, 12)
        .padding(.vertical, spec.subtitle == nil ? 9 : 8)
        .background(spec.hero ? Look.accent.opacity(0.06) : Color.clear)
    }

    private func binding(_ kp: ReferenceWritableKeyPath<AppSettings, HotKey?>) -> Binding<HotKey?> {
        Binding(get: { settings[keyPath: kp] }, set: { settings[keyPath: kp] = $0 })
    }

    /// 和系统、别的 app、这里另一行重复时写在名字下面
    private func problem(_ spec: ShortcutSpec) -> String? {
        if settings.reservedKeys.contains(spec.id) { return "macOS already uses this shortcut" }
        // 两行用同一个：先说是哪一行（注册失败多半就是因为这个，以前会写成"别的应用在用"）
        if let k = settings[keyPath: spec.key],
           let other = (capture + shelf).first(where: { $0.id != spec.id && settings[keyPath: $0.key] == k }) {
            return "Also used by \(other.title)"
        }
        if settings.conflictingKeys.contains(spec.id) { return "Couldn’t turn on this shortcut. Try another one." }
        return nil
    }
}

/// 录快捷键的小框：设了就是一颗颗键帽，没设是灰字 Record。点一下开始录，再按 Esc 取消；
/// 鼠标移上去右边出现 ⊗ 清除；右键可以恢复默认
struct KeyRecorder: View {
    @Binding var key: HotKey?
    var defaultKey: HotKey? = nil
    var onReject: () -> Void = {}
    var onRecord: () -> Void = {}
    @State private var recording = false
    @State private var hover = false
    @State private var monitor: Any?
    @State private var flagsMonitor: Any?
    /// 录的时候已经按着的 ⌃⌥⇧⌘
    @State private var held: [String] = []
    @State private var resignObserver: Any?
    @State private var clickMonitor: Any?
    /// 点了框外面停下的时刻：这一下要是正好点在框上，不再马上重新开始录
    @State private var stoppedByClickAt: Date = .distantPast

    var body: some View {
        HStack(spacing: 3) {
            if recording {
                if held.isEmpty {
                    Text("Type Shortcut").foregroundStyle(Look.accent)
                } else {
                    ForEach(held, id: \.self) { g in Keycap(text: g) }
                    Text("…").foregroundStyle(.tertiary)
                }
            } else if let key {
                ForEach(Array(key.glyphs.enumerated()), id: \.offset) { _, g in Keycap(text: g) }
            } else {
                Text("Record").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .frame(minWidth: 92, minHeight: 22)
        .padding(.horizontal, 6)
        .padding(.trailing, key != nil && hover && !recording ? 14 : 0)
        .background(RoundedRectangle(cornerRadius: 6).fill(recording ? Look.accent.opacity(0.08) : Color.primary.opacity(key == nil ? 0 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(recording ? Look.accent.opacity(0.7) : Color.primary.opacity(0.14),
                                                               lineWidth: recording ? 1 : 0.5))
        .overlay(alignment: .trailing) {
            if key != nil && hover && !recording {
                Button { stop(); key = nil } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 5)
                .help("Clear")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if recording { stop() } else if Date().timeIntervalSince(stoppedByClickAt) > 0.6 { start() }
        }
        .onHover { hover = $0 }
        .contextMenu {
            if let d = defaultKey { Button("Restore Default (\(d.display))") { stop(); key = d } }
            Button("Clear") { stop(); key = nil }.disabled(key == nil)
        }
        .animation(.easeOut(duration: 0.12), value: hover)
        .animation(.easeOut(duration: 0.12), value: recording)
        .onDisappear(perform: stop)
    }

    private func start() {
        KeyRecording.stopActive()
        recording = true
        held = []
        KeyRecording.stop = { stop() }
        HotKeyCenter.shared.setPaused(true)
        // 录的时候所有全局快捷键是关着的：切到别的应用、点了别的地方就停下，不然 ⇧⌘2 一直没反应
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { stop() }
        }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated {
                stoppedByClickAt = Date()
                stop()
            }
            return event
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var g: [String] = []
            if f.contains(.control) { g.append("⌃") }
            if f.contains(.option) { g.append("⌥") }
            if f.contains(.shift) { g.append("⇧") }
            if f.contains(.command) { g.append("⌘") }
            MainActor.assumeIsolated { held = g }
            return event
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 录制期间吞掉所有按键；返回值放在闭包外面，避免把 NSEvent 跨隔离域传出去
            let code = event.keyCode
            let k = HotKey(event: event)
            MainActor.assumeIsolated {
                if code == 53 { stop(); return } // Esc 取消
                if let k { key = k; onRecord(); stop() } else { NSSound.beep(); onReject() }
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        monitor = nil
        flagsMonitor = nil
        clickMonitor = nil
        resignObserver = nil
        held = []
        if recording { HotKeyCenter.shared.setPaused(false) }
        recording = false
    }
}

/// 一颗键帽
private struct Keycap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .frame(minWidth: 16, minHeight: 17)
            .padding(.horizontal, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.13), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 0, y: 0.5)
    }
}
