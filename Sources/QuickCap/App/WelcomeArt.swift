import SwiftUI

/// 权限页的图：系统设置"屏幕与系统录音"那一页的样子，QuickCap 那一行的开关跟着真实状态变。
/// 用户在系统设置里要找的就是这一行
struct AccessArt: View {
    enum Pane { case screen, accessibility }
    let access: ScreenAccess.State
    let pulsing: Bool
    var pane: Pane = .screen

    var body: some View {
        ZStack(alignment: .topLeading) {
            Wallpaper()
            HStack(spacing: 0) {
                sidebar
                Divider()
                detail
            }
            .frame(width: 452, height: 236)
            .background(Color.dyn(0xFFFFFF, 0x1E1E20))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
            .offset(x: 24, y: 28)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            TrafficLights().padding(.leading, 12).padding(.top, 11)
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06))
                .frame(height: 20).padding(.horizontal, 10).padding(.top, 12)
                .overlay(alignment: .leading) {
                    Image(systemName: "magnifyingglass").font(.system(size: 9)).foregroundStyle(.tertiary).padding(.leading, 16).padding(.top, 12)
                }
            VStack(alignment: .leading, spacing: 2) {
                row("General", "gearshape.fill", 0x8E8E93)
                row("Appearance", "circle.lefthalf.filled", 0x1C1C1E)
                row("Desktop & Dock", "menubar.dock.rectangle", 0x1C1C1E)
                row("Displays", "sun.max.fill", 0x2F7BF6)
                row("Privacy & Security", "hand.raised.fill", 0x2F7BF6, selected: true)
                row("Keyboard", "keyboard.fill", 0x8E8E93)
            }
            .padding(.top, 10)
            Spacer(minLength: 0)
        }
        .frame(width: 150)
        .background(Color.dyn(0xF2F2F4, 0x262628))
    }

    private func row(_ title: String, _ symbol: String, _ tint: UInt32, selected: Bool = false) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(rgb: tint))
                .frame(width: 15, height: 15)
                .overlay(Image(systemName: symbol).font(.system(size: 8, weight: .semibold)).foregroundStyle(.white))
            Text(title).font(.system(size: 10.5)).lineLimit(1)
                .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.85))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Color.accentColor : .clear))
        .padding(.horizontal, 8)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                Text(pane == .screen ? "Screen & System Audio Recording" : "Accessibility").font(.system(size: 12.5, weight: .bold))
            }
            .padding(.top, 12)
            Text(pane == .screen ? "Allow the applications below to record the content of your screen and audio."
                 : "Allow the applications below to control your computer.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            VStack(spacing: 0) {
                appRow
                Divider().padding(.leading, 38)
                otherRow
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
            .padding(.top, 10)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    private var appRow: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 22, height: 22)
            Text("QuickCap").font(.system(size: 11, weight: .medium))
            Spacer()
            MiniToggle(on: access != .off)
                .background { if pulsing { Pulse() } }
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
    }

    /// 下面一行别的 app（灰掉的占位），让人认出这是一个列表
    private var otherRow: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.1)).frame(width: 22, height: 22)
            Capsule().fill(Color.primary.opacity(0.1)).frame(width: 70, height: 6)
            Spacer()
            MiniToggle(on: true).opacity(0.35)
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
    }
}

/// 系统样式的小开关
private struct MiniToggle: View {
    let on: Bool
    var body: some View {
        Capsule()
            .fill(on ? Color.accentColor : Color.primary.opacity(0.14))
            .frame(width: 30, height: 17)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(.white).shadow(color: .black.opacity(0.22), radius: 1, y: 0.5).padding(1.5)
            }
    }
}

/// 开关外面一圈慢慢扩开的光，告诉用户点哪里
private struct Pulse: View {
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        TimelineView(.animation(paused: reduce || ReduceMotion.forced || WelcomeDemo.debugTime != nil)) { ctx in
            let k = (reduce || ReduceMotion.forced || WelcomeDemo.debugTime != nil) ? 0.35 : ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            Capsule().strokeBorder(Color.accentColor, lineWidth: 2)
                .frame(width: 30 + 14 * k, height: 17 + 14 * k)
                .opacity(0.7 * (1 - k))
        }
        .frame(width: 44, height: 31)
        .allowsHitTesting(false)
    }
}

/// 最后一页的图：菜单栏上 QuickCap 的图标和它的菜单（和真的菜单一样，快捷键是现在设置的）
struct MenuArt: View {
    @ObservedObject var settings: AppSettings
    private static let iconX: CGFloat = 330
    private static let menuWidth: CGFloat = 238

    var body: some View {
        ZStack(alignment: .topLeading) {
            Wallpaper()
            menuBar
            // 菜单放不下时像系统一样往左挪，贴着右边
            menu.offset(x: min(Self.iconX - 13, WelcomeView.artSize.width - Self.menuWidth - 6), y: 27)
        }
        .frame(width: WelcomeView.artSize.width, height: WelcomeView.artSize.height, alignment: .topLeading)
        .clipped()
    }

    private var menuBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "apple.logo").font(.system(size: 12))
            Text("Finder").font(.system(size: 12, weight: .bold))
            ForEach(["File", "Edit", "View", "Go"], id: \.self) { Text($0).font(.system(size: 12)) }
            Spacer()
        }
        .padding(.leading, 16)
        .frame(width: WelcomeView.artSize.width, height: 24)
        .background(Color.dyn(0xFFFFFF, 0x1C1C1E, opacity: 0.55))
        .overlay(alignment: .topLeading) { rightItems }
        .foregroundStyle(Color.dyn(0x1D1D1F, 0xF5F5F7))
    }

    private var rightItems: some View {
        HStack(spacing: 13) {
            Image(nsImage: AppDelegate.menuBarIcon).renderingMode(.template)
                .padding(.horizontal, 6).frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.14)))
            Image(systemName: "wifi").font(.system(size: 12, weight: .medium))
            Image(systemName: "battery.75percent").font(.system(size: 13))
            Image(systemName: "switch.2").font(.system(size: 11, weight: .medium))
            Text("Sat 9:41").font(.system(size: 12))
        }
        .frame(height: 24)
        .offset(x: Self.iconX - 15)
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 和菜单栏里真的菜单一样的项、一样的顺序和图标；图里放不下的下面几项被图的下边裁掉（像菜单还在往下）
            item("All-In-One", "plus.viewfinder", settings.captureKey?.display, highlighted: true)
            item("Capture Area", "rectangle.dashed", settings.captureAreaKey?.display)
            item("Capture Window", "macwindow", settings.captureWindowKey?.display)
            item("Capture Screen", "rectangle.inset.filled", settings.captureScreenKey?.display)
            item("Scan Text & QR", "text.viewfinder", settings.captureTextKey?.display)
            item("Timer", "timer", nil, submenu: true)
            separator
            item("Search Captures…", "magnifyingglass", nil)
            item("Show Shelf", "rectangle.stack", settings.toggleShelfKey?.display)
            item("Open Screenshots Folder", "folder", nil)
            separator
            item("Settings…", "gearshape", "⌘,")
            item("Quit QuickCap", "power", "⌘Q")
        }
        .padding(5)
        .frame(width: Self.menuWidth)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.dyn(0xF6F6F8, 0x2A2A2D, opacity: 0.97)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
    }

    private func item(_ title: String, _ symbol: String, _ key: String?, highlighted: Bool = false, submenu: Bool = false) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 16)
            Text(title)
            Spacer()
            if let key { Text(key).foregroundStyle(highlighted ? Color.white.opacity(0.85) : .secondary) }
            if submenu { Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary) }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(highlighted ? Color.white : .primary)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(highlighted ? Color.accentColor : .clear))
    }

    private var separator: some View {
        Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5).padding(.horizontal, 9).padding(.vertical, 5)
    }
}
