import AppKit
import ScreenCaptureKit

/// 屏幕录制权限。
/// 系统的问法只会出一次：第一次调 CGRequestScreenCaptureAccess 会弹系统的提示，并把 QuickCap 列进系统设置；
/// 之后再调什么都不发生，只能打开系统设置让用户自己打开开关。
/// 打开开关后，系统常常要 QuickCap 重新打开才真正生效（CGPreflight 一直是 false），要分开处理
@MainActor
enum ScreenAccess {
    enum State: Equatable {
        case off
        /// 开关已经打开，但这次运行还没生效，要重新打开 QuickCap
        case needsReopen
        case on
    }

    /// 调试用：假装成某个状态
    static var forced: State?

    static var state: State {
        if let forced { return forced }
        if liveGranted || CGPreflightScreenCaptureAccess() { return .on }
        return canSeeOtherWindowTitles ? .needsReopen : .off
    }

    /// ScreenCaptureKit 每次都去问系统，开关一打开就能用，不像 CGPreflight 要重新打开才变。
    /// 问过一次成功就记住（这次运行里不会再变回去）
    private static var liveGranted = false
    private static var probing = false

    /// 实时问一下系统现在能不能截。不弹提示；没权限时 SCShareableContent 直接报错
    static func probe() async -> State {
        // 系统的提示还没出过时不问：没权限时 ScreenCaptureKit 自己会弹系统提示，要等用户点了按钮再出
        if forced == nil, asked, !liveGranted, !probing {
            probing = true
            defer { probing = false }
            if (try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)) != nil {
                liveGranted = true
            }
        }
        return state
    }

    /// 系统的提示出过没有（出过之后再请求不会有反应）
    static var asked: Bool { UserDefaults.standard.bool(forKey: askedKey) }
    private static let askedKey = "screenAccessAsked"

    /// 请求权限：第一次弹系统的提示；之后直接打开系统设置的那一页。返回现在能不能截
    @discardableResult
    static func request() -> Bool {
        promptedNow = false
        if CGPreflightScreenCaptureAccess() { return true }
        if !asked {
            UserDefaults.standard.set(true, forKey: askedKey)
            promptedNow = true
            return CGRequestScreenCaptureAccess()
        }
        openSystemSettings()
        return false
    }

    /// 截图时用：有权限返回 true；第一次会弹系统的提示，之后不打开系统设置（由我们的提示框里的按钮去开）
    static func requestQuietly() -> Bool {
        promptedNow = false
        if liveGranted || CGPreflightScreenCaptureAccess() { return true }
        guard !asked else { return false }
        UserDefaults.standard.set(true, forKey: askedKey)
        promptedNow = true
        return CGRequestScreenCaptureAccess()
    }

    /// 刚才那次 request() 弹出了系统自己的提示（这时不要再叠一个我们的提示框）。读一次就清掉
    private static var promptedNow = false
    static func takePromptedNow() -> Bool { defer { promptedNow = false }; return promptedNow }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 重新打开自己（等这一份退出后再开，免得系统把它当成同一个进程）
    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$2\"",
                       "sh", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    /// 能看到别的 app 窗口的标题，说明开关已经打开了（系统没给权限时，别人窗口的标题是拿不到的）。
    /// 这个是实时的，不像 CGPreflight 要重新打开才变
    private static var canSeeOtherWindowTitles: Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        return list.contains { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let name = w[kCGWindowName as String] as? String else { return false }
            return !name.isEmpty
        }
    }
}
