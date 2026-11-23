import Foundation

/// 让 QuickCap 不变成当前 app 也能管鼠标光标。
///
/// 系统截图（/usr/sbin/screencapture 和 screencaptureui）就是这样做的：打开截图界面时不抢焦点，
/// 只给自己的窗口服务器连接设一个 "SetsCursorInBackground"，光标由它来定。
/// 不抢焦点的好处是：通知中心、菜单、弹出框这些"别的 app 一变成当前 app 就自己收起来"的东西，
/// 截图时还留在屏幕上，可以单独截。
///
/// 这个接口没有公开（在 SkyLight 里），按名字找；找不到就返回 false，调用的地方改回"变成当前 app"的老办法
enum BackgroundCursor {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    /// 设一次就一直有效（整个进程）。成功返回 true
    static let enabled: Bool = {
        let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        let any = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let m = dlsym(sky, "SLSMainConnectionID") ?? dlsym(any, "CGSMainConnectionID"),
              let s = dlsym(sky, "SLSSetConnectionProperty") ?? dlsym(any, "CGSSetConnectionProperty") else { return false }
        let main = unsafeBitCast(m, to: MainConnection.self)
        let set = unsafeBitCast(s, to: SetProperty.self)
        let cid = main()
        return set(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == 0
    }()
}
