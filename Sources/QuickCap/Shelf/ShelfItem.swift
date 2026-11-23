import AppKit
import ImageIO

/// 挂在绳子上的一张截图。缩略图不在这里：绳子上可能有上千张，只有屏幕附近那几张才会去加载（见 ShelfThumbnails）。
struct ShelfItem: Equatable {
    let url: URL
    /// 截图的时间（创建时间，取不到就用修改时间）。整排按它从新到旧排
    let date: Date
    /// 修改时间。文件被覆盖后缩略图要重新生成
    let modified: Date
    let pixelSize: CGSize

    /// 同一个文件就是同一张（路径已经标准化）
    static func == (a: ShelfItem, b: ShelfItem) -> Bool {
        a.url == b.url && a.modified == b.modified && a.pixelSize == b.pixelSize
    }

    /// 缩略图缓存的键
    var thumbnailKey: String { "\(url.path)|\(modified.timeIntervalSinceReferenceDate)" }

    /// 读文件头拿到尺寸和时间，不解码图片。读不出来返回 nil
    static func load(_ url: URL) -> ShelfItem? {
        let std = url.standardizedFileURL
        guard let size = ShelfScanner.pixelSize(of: std) else { return nil }
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey]
        let v = try? std.resourceValues(forKeys: keys)
        let modified = v?.contentModificationDate ?? Date()
        return ShelfItem(url: std, date: v?.creationDate ?? modified, modified: modified, pixelSize: size)
    }
}

/// 悬挂架从屏幕哪一边拉出来。最新的和置顶的卡片都排在靠这一边的地方
enum ShelfSide: String, Codable {
    case left, right
    /// 从这一边往屏幕里面走，屏幕横坐标的变化方向
    var inward: CGFloat { self == .right ? -1 : 1 }
}

/// 悬挂架的尺寸和物理参数，集中放在这里方便调手感。
enum Metrics {
    // 挂绳（绳子上的小环 + 细绳 + 卡片顶上的小扣）
    static let clipSize = CGSize(width: 12, height: 24)
    /// 绳子穿过挂绳的位置（离挂绳顶部的距离）
    static let clipRopeY: CGFloat = 3
    /// 卡片顶边的位置（离挂绳顶部的距离），和 clipRopeY 的差就是绳子到卡片的距离
    static let clipGripY: CGFloat = 21

    // 卡片
    static let cardMaxSize = CGSize(width: 156, height: 116)
    static let cardMinSize = CGSize(width: 72, height: 52)
    static let framePadding: CGFloat = 0
    static let cardCorner: CGFloat = 12
    static let slotSpacing: CGFloat = 172
    /// 屏幕外多远的卡片还留着（左右各一块，按屏宽的倍数）。只有这个范围里的截图才会建卡片、加载缩略图
    static let materializeMargin: CGFloat = 1.0
    /// 超出这个范围才回收，留一点余量，免得在边界上反复建和拆
    static let dematerializeMargin: CGFloat = 1.6
    /// 第一张卡片中心离屏幕边缘的距离；放不下时最远那张离另一边也留这么多
    static let edgeMargin: CGFloat = 120
    // 图片角上的圆形按钮（左上移到废纸篓，右上置顶）：直径、离卡片边缘的距离、图标字号
    static let cornerButtonSize: CGFloat = 20
    static let cornerButtonInset: CGFloat = 6
    static let cornerIconPointSize: CGFloat = 10.5
    /// 置顶后的小标记颜色（不悬停时也显示在右上角）
    static let pinColor = NSColor(calibratedRed: 1.0, green: 0.58, blue: 0.0, alpha: 1)
    /// 移到废纸篓按钮在鼠标停留时的颜色
    static let trashColor = NSColor(calibratedRed: 0.96, green: 0.26, blue: 0.24, alpha: 1)
    /// 按住置顶卡片横向拖多远开始调整顺序；竖着拖多远改成拖出到其他应用
    static let reorderThreshold: CGFloat = 6
    static let dragOutThreshold: CGFloat = 36

    // 悬停工具栏：离卡片底边的距离、高度、两端留白、每个按钮的点击区域和图标字号
    static let toolbarGap: CGFloat = 9
    static let toolbarHeight: CGFloat = 32
    static let toolbarPadding: CGFloat = 4
    static let toolbarButton = CGSize(width: 34, height: 26)
    /// SF Symbol 的字号。实际图形可能比字号高一点，按符号自己的尺寸居中，不会被裁
    static let toolbarIconPointSize: CGFloat = 13.5

    // 绳子：两端从屏幕边缘拉出，离菜单栏底部 ropeTopInset，中间下垂约为屏宽的 ropeSagRatio
    static let ropeTopInset: CGFloat = 10
    static let ropeSagRatio: CGFloat = 0.009

    /// 拖出去没放下、弹回来时的摆幅（弧度）
    static let dragCancelSwing: CGFloat = 0.16
    /// 删掉一张后，旁边的等多久再补位（秒）
    static let removeReflowDelay: CGFloat = 0.16

    // 物理
    /// 卡片摆动的固有频率（Hz），和卡片大小无关，大小卡片摆得一样快
    static let swingFrequency: CGFloat = 0.85
    /// 阻尼比：越接近 1 越不晃。0.4 大约来回两三次停下
    static let swingDampingRatio: CGFloat = 0.4
    /// 最大摆角（弧度，约 15°）。鼠标连续划过时推力会累加，这里限住速度，卡片不会被甩飞
    static let swingMaxAngle: CGFloat = 0.26
    /// 无论什么情况摆角都不超过这个值（弧度，约 26°）
    static let swingHardLimit: CGFloat = 0.45
    /// 挂点移动时卡片保留多少惯性（0 = 完全跟着走不摆，1 = 完全靠物理）
    static let swingInertia: CGFloat = 0.09
    /// 整排横向滚动时卡片保留的惯性，比换位置小：滑得很快时也只摆几度
    static let scrollSwingInertia: CGFloat = 0.04
    /// 鼠标划过卡片时顺手推一下：每移动 1pt 给的推力（pt/秒），以及这样推出来的最大摆角（弧度，约 4°）。
    /// 划得再快、来回再多次，也只会轻轻晃到这个角度。
    static let hoverPushGain: CGFloat = 0.8
    static let hoverMaxAngle: CGFloat = 0.07
    /// 飞入：最后从挂点上方多高落下来（pt）。太高会冲进菜单栏
    static let flightLift: CGFloat = 26
    /// 收起着的时候截图：先展开，新卡片晚这么久再飞（秒）
    static let flightDelayWhileRevealing: CGFloat = 0.14
    /// 飞入落到绳子上后顺着惯性荡出去的幅度（弧度）
    static let landingSwing: CGFloat = 0.11
    /// 悬停抬起和放下的速度（1/秒），抬起快、放下慢一点
    static let hoverRiseRate: CGFloat = 22
    static let hoverFallRate: CGFloat = 11
    static let cardRopeMass: CGFloat = 2.5
    /// 展开：整排从屏幕边上平移出来。弹簧阻尼比约 0.82，0.4 秒左右到位，最后略冲过一点再回来
    static let revealSpring = (stiffness: CGFloat(150), damping: CGFloat(20))
    /// 展开时离边缘越远的卡片越早出发（每张提前多少秒），整排像被拉出来时稍微拉开再收拢
    static let revealStagger: CGFloat = 0.018
    /// 收起：0.36 秒加速滑出屏幕（离边缘近的先走）
    static let hideDuration: CGFloat = 0.36
    static let hideStagger: CGFloat = 0.012
    /// 展开收起时卡片保留的惯性，比换位置小，滑进来停下时只往前荡几度
    static let revealSwingInertia: CGFloat = 0.012
    /// 绳子从边上伸出来/收回去用的时间（秒）
    static let ropeRevealDuration: CGFloat = 0.32
    static let ropeHideDuration: CGFloat = 0.42

    /// 卡片（含白边）的显示尺寸，按原图比例缩放到上下限之间。
    static func cardSize(for pixel: CGSize) -> CGSize {
        let aspect = max(pixel.width, 1) / max(pixel.height, 1)
        var w = cardMaxSize.width
        var h = w / aspect
        if h > cardMaxSize.height { h = cardMaxSize.height; w = h * aspect }
        w = max(w, cardMinSize.width)
        h = max(h, cardMinSize.height)
        return CGSize(width: w.rounded(), height: h.rounded())
    }
}

/// 系统设置里的"减少动态效果"。开着时卡片不摆、不晃、掉落不转，飞入和展开照常（那是位置变化，不是装饰）
@MainActor
enum ReduceMotion {
    /// 调试用：不管系统设置，强制打开
    static var forced = false
    private static var cached: Bool?
    private static var observer: NSObjectProtocol?

    static var isOn: Bool {
        if forced { return true }
        if let cached { return cached }
        if observer == nil {
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated { cached = nil } }
        }
        let v = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        cached = v
        return v
    }
}
