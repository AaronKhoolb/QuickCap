import SwiftUI

/// 欢迎窗口的内容：上面一块示意图，下面标题和一两句话，底部是翻页点和按钮
struct WelcomeView: View {
    @ObservedObject var model: WelcomeModel
    @ObservedObject var settings: AppSettings

    static let artSize = CGSize(width: 500, height: 264)

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                page(model.page)
                    .id(model.page)
                    .transition(.asymmetric(insertion: .slideFade(model.forward ? 40 : -40),
                                            removal: .slideFade(model.forward ? -40 : 40)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            bottomBar
        }
        .padding(.top, 30)
        .frame(width: 560, height: 512)
    }

    @ViewBuilder
    private func page(_ p: WelcomeModel.Page) -> some View {
        switch p {
        case .hello:
            layout(art: AnyView(WelcomeDemo()), title: "Welcome to QuickCap",
                   body: "Drag over anything on your screen to capture it. Every capture is saved and hangs on the Shelf at the edge of your screen, ready to drag into any app.")
        case .access:
            layout(art: AnyView(AccessArt(access: model.access, pulsing: model.access == .off)), title: "Allow Screen Recording",
                   body: "macOS asks for this before any app can capture the screen. QuickCap only looks at the screen when you take a capture, and nothing leaves your Mac.",
                   status: accessStatus)
        case .shortcuts:
            layout(art: AnyView(ShortcutsArt(settings: settings)), title: "Choose Your Shortcuts",
                   body: "Optional. Every capture also starts from the QuickCap menu in the menu bar, and you can change these anytime in Settings.")
        case .ready:
            layout(art: AnyView(MenuArt(settings: settings)), title: "You’re All Set",
                   body: readyText)
        }
    }

    private func layout(art: AnyView, title: String, body: String, status: AnyView? = nil) -> some View {
        VStack(spacing: 0) {
            art
                .frame(width: Self.artSize.width, height: Self.artSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .padding(.top, 26)
            Text(body)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2.5)
                .frame(width: 420)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            // 状态那一行的位置一直留着，文字变来变去时下面不跳
            ZStack { status }
                .frame(height: 34)
                .padding(.top, 6)
        }
    }

    private var readyText: String {
        let key = settings.captureKey?.display
        let start = key.map { "Press \($0) or choose All-In-One from its menu to capture" } ?? "Choose All-In-One from its menu to capture"
        return "QuickCap lives in the menu bar. \(start). Captures are saved to \(folderName) and hang on the Shelf."
    }

    private var folderName: String {
        let path = (settings.screenshotFolder as NSString).expandingTildeInPath
        let home = NSHomeDirectory()
        guard path.hasPrefix(home + "/") else { return FileManager.default.displayName(atPath: path) }
        return path.dropFirst(home.count + 1).split(separator: "/").map(String.init).joined(separator: " › ")
    }

    private var accessStatus: AnyView? {
        switch model.access {
        case .on:
            return AnyView(Label("Screen Recording is on", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.green)
                .transition(.opacity.combined(with: .scale(scale: 0.9))))
        case .needsReopen:
            return AnyView(Text("Screen Recording is on. Reopen QuickCap so the change takes effect.")
                .font(.system(size: 12)).foregroundStyle(.secondary).transition(.opacity))
        case .off where model.askedThisTime:
            return AnyView(Text("In System Settings, turn on QuickCap. Already on? Click Reopen QuickCap.")
                .font(.system(size: 12)).foregroundStyle(.secondary).transition(.opacity))
        case .off:
            return nil
        }
    }

    // MARK: 底部

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if model.pages.count > 1 { PageDots(count: model.pages.count, index: model.index) }
            Spacer()
            secondaryButton
            Button(action: primary) {
                Text(primaryTitle)
                    .frame(minWidth: 88)
                    .contentTransition(.opacity)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.bottom, 22)
    }

    @ViewBuilder
    private var secondaryButton: some View {
        switch model.page {
        case .hello:
            EmptyView()
        case .shortcuts:
            if settings.captureKey == nil && settings.captureTextKey == nil && settings.toggleShelfKey == nil {
                Button("Skip") { model.next() }.buttonStyle(.bordered)
            }
        case .access:
            if model.access != .on {
                Button("Not Now") { model.next() }.buttonStyle(.bordered)
            }
            // 系统设置里已经打开了，这边却一直测不出来（签名变过之类）：给一个手动重开的出口
            if model.access == .off && model.askedThisTime {
                Button("Reopen QuickCap") { model.reopen() }.buttonStyle(.bordered)
            }
        case .ready:
            Button("Settings…") { model.finish(openSettings: true) }.buttonStyle(.bordered)
        }
    }

    private var primaryTitle: String {
        switch model.page {
        case .hello, .shortcuts: return "Continue"
        case .access:
            switch model.access {
            case .off: return "Open System Settings"
            case .needsReopen: return "Reopen QuickCap"
            case .on: return "Continue"
            }
        case .ready: return "Done"
        }
    }

    private func primary() {
        switch model.page {
        case .hello, .shortcuts: model.next()
        case .access: model.primaryOnAccess()
        case .ready: model.finish(openSettings: false)
        }
    }
}

/// 翻页点：当前页是一小段胶囊，其它是圆点
private struct PageDots: View {
    let count: Int
    let index: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == index ? Color.primary.opacity(0.7) : Color.primary.opacity(0.18))
                    .frame(width: i == index ? 16 : 6, height: 6)
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.15), value: index)
        .accessibilityElement()
        .accessibilityLabel("Page \(index + 1) of \(count)")
    }
}

/// 翻页：新的一页从旁边稍微滑进来、淡入
private struct SlideFade: ViewModifier {
    let x: CGFloat
    let opacity: Double
    func body(content: Content) -> some View { content.offset(x: x).opacity(opacity) }
}

extension AnyTransition {
    static func slideFade(_ x: CGFloat) -> AnyTransition {
        .modifier(active: SlideFade(x: x, opacity: 0), identity: SlideFade(x: 0, opacity: 1))
    }
}

/// 欢迎页第三页：三个最常用的快捷键，默认都空着，点一下录
private struct ShortcutsArt: View {
    @ObservedObject var settings: AppSettings
    /// 刚才按的组合不收（比如 ⌥⇧S）：在名字下面说为什么，不然只有一声提示音
    @State private var rejected: PartialKeyPath<AppSettings>?

    var body: some View {
        VStack(spacing: 0) {
            row("plus.viewfinder", "All-In-One", "Area, window or screen", \.captureKey, hero: true)
            Divider().padding(.leading, 50)
            row("text.viewfinder", "Scan Text & QR", "Copy text or open a link", \.captureTextKey)
            Divider().padding(.leading, 50)
            row("rectangle.stack", "Show or Hide Shelf", "Your recent captures", \.toggleShelfKey)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 34)
        .frame(width: WelcomeView.artSize.width, height: WelcomeView.artSize.height)
        .background(Color.primary.opacity(0.03))
    }

    private func row(_ symbol: String, _ title: String, _ sub: String,
                     _ kp: ReferenceWritableKeyPath<AppSettings, HotKey?>, hero: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(hero ? Color.orange : Color.primary.opacity(0.75))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if rejected == kp {
                    Text("Use ⌃, ⌥⇧, or ⌘ with ⇧ or ⌥").font(.system(size: 11)).foregroundStyle(.red)
                } else {
                    Text(sub).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            KeyRecorder(key: Binding(get: { settings[keyPath: kp] }, set: { settings[keyPath: kp] = $0 }), onReject: {
                rejected = kp
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if rejected == kp { rejected = nil } }
            }, onRecord: { rejected = nil })
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
