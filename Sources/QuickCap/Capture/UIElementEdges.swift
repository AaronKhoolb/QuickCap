import AppKit
import ApplicationServices

/// 吸附界面元素（按钮、文本框、列表、侧栏……）：用辅助功能读最前面那个 app 窗口里的元素边框，
/// 变成和窗口边一样的吸附线。要辅助功能权限，没有权限就什么都不加（吸附照旧只吸窗口边和画面里的线）。
///
/// 只读一次，在截图界面打开前读（读的时候 app 的界面还没被截图界面盖住）。
/// 有上限：最多看 1500 个元素、最深 25 层、0.15 秒，读不完就用读到的那些，不会让截图界面打开变慢。
enum UIElementEdges {
    /// 有没有辅助功能权限（不弹提示）
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 请求权限：系统会把 QuickCap 列进 隐私与安全性 > 辅助功能，用户只要打开开关
    static func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// 屏幕坐标（左上原点，全局）的元素边框
    static func frames(maxElements: Int = 1500, maxDepth: Int = 25, budget: TimeInterval = 0.15) -> [CGRect] {
        guard isTrusted, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return [] }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.05)
        guard let win: AXUIElement = attribute(root, kAXFocusedWindowAttribute) ?? attribute(root, kAXMainWindowAttribute) else { return [] }
        // 超时只管设过的那个元素：窗口和子元素也要设，不然前台 app 卡住时每问一次等好几秒
        AXUIElementSetMessagingTimeout(win, 0.05)
        let deadline = Date().addingTimeInterval(budget)
        var out: [CGRect] = []
        var stack: [(AXUIElement, Int)] = [(win, 0)]
        var seen = 0
        while let (el, depth) = stack.popLast(), seen < maxElements, Date() < deadline {
            seen += 1
            if let r = frame(el), r.width >= 8, r.height >= 8 { out.append(r) }
            guard depth < maxDepth, let kids: [AXUIElement] = attribute(el, kAXChildrenAttribute) else { continue }
            for k in kids.reversed() { AXUIElementSetMessagingTimeout(k, 0.05); stack.append((k, depth + 1)) }
        }
        return out
    }

    /// 换成某块屏幕上截图界面的坐标（左下原点，pt），并去掉和这块屏幕不相交的
    @MainActor
    static func local(_ frames: [CGRect], on screen: NSScreen) -> [CGRect] {
        // 全局坐标的左上原点在主屏左上角
        guard let primaryTop = NSScreen.screens.first?.frame.maxY else { return [] }
        let s = screen.frame
        return frames.compactMap { r in
            let flipped = CGRect(x: r.minX, y: primaryTop - r.maxY, width: r.width, height: r.height)
            let local = flipped.offsetBy(dx: -s.minX, dy: -s.minY)
            let clipped = local.intersection(CGRect(origin: .zero, size: s.size))
            return clipped.width >= 8 && clipped.height >= 8 ? clipped : nil
        }
    }

    /// 元素边框变成吸附线（四条边）。太大的（几乎整个窗口）不加，窗口边已经有了
    static func segments(_ rects: [CGRect], screenSize: CGSize) -> (vertical: [SnapLines.Segment], horizontal: [SnapLines.Segment]) {
        var v: [SnapLines.Segment] = [], h: [SnapLines.Segment] = []
        for r in rects where !(r.width > screenSize.width * 0.9 && r.height > screenSize.height * 0.9) {
            v.append(.init(pos: r.minX, from: r.minY, to: r.maxY))
            v.append(.init(pos: r.maxX, from: r.minY, to: r.maxY))
            h.append(.init(pos: r.minY, from: r.minX, to: r.maxX))
            h.append(.init(pos: r.maxY, from: r.minX, to: r.maxX))
        }
        return (v, h)
    }

    private static func attribute<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v else { return nil }
        return v as? T
    }

    private static func frame(_ el: AXUIElement) -> CGRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success,
              let pv, let sv, CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }
}
