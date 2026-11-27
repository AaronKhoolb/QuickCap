import AppKit
import QuartzCore

@MainActor
protocol ShelfViewDelegate: AnyObject {
    func shelfView(_ view: ShelfView, didClick item: ShelfItem)
    func shelfView(_ view: ShelfView, didDoubleClick item: ShelfItem)
    func shelfView(_ view: ShelfView, menuFor item: ShelfItem) -> NSMenu?
    func shelfView(_ view: ShelfView, perform action: ShelfAction, on item: ShelfItem)
    func shelfViewDidInteract(_ view: ShelfView)
    func shelfViewDidFinishHiding(_ view: ShelfView)
    /// 挂着的卡片、顺序或置顶状态变了，需要保存
    func shelfViewDidChangeItems(_ view: ShelfView)
    /// 把卡片拖到别的应用的拖动结束了（不管放没放成功）
    func shelfViewDidEndDragOut(_ view: ShelfView)
    /// 要弹出不属于某张卡片的菜单（日期列表）
    func shelfViewWillShowMenu(_ view: ShelfView)
    /// 点了卡片之间的空处（没拖）：像弹出框一样，点外面就收起
    func shelfViewDidClickEmpty(_ view: ShelfView)
}

/// 悬挂架的绘制和物理。根图层 y 轴向下，原点在左上角。
/// 卡片的位置用内容坐标表示（CardNode.slide）：第 i 张在 i * slotSpacing，从左往右排。
/// 置顶的在最左边，然后是没置顶的，从新到旧。不管从哪边出来，屏幕上都是从左到右、新到旧。
@MainActor
final class ShelfView: NSView {
    weak var delegate: ShelfViewDelegate?

    let root = CALayer()
    private let ropeShadow = CAShapeLayer()
    private let ropeLayer = CAShapeLayer()
    private let ropeShine = CAShapeLayer()
    private let cardsLayer = CALayer()
    /// 所有卡片的工具栏放在卡片上面一层，不会被相邻卡片挡住，也不跟着卡片旋转
    private let toolbarsLayer = CALayer()

    let rope = Rope()
    /// 缩略图（后台生成 + 缓存）
    let thumbnails = ShelfThumbnails()
    /// 滑动时浮在绳子上的日期牌
    private(set) var dateBubble: DateBubble!
    /// 整排下面的时间刻度条
    /// 删掉一张后出现几秒的"撤销"
    private(set) var undoPill: UndoPill!
    /// 截图文件夹。不在里面的卡片角上是"取下"，不是"移到废纸篓"
    var ownedFolder: URL?
    private(set) var cards: [CardNode] = []
    private var displayLink: CADisplayLink?
    private var lastTime: CFTimeInterval = 0
    private var clipImage: CGImage?

    /// 绳子顶端离窗口顶部的距离（菜单栏高度 + 一点余量）
    var topInset: CGFloat = 30 { didSet { resetRope() } }
    /// 从屏幕哪一边拉出来
    var side: ShelfSide = .right { didSet { if side != oldValue { resetRope() } } }
    private(set) var isShown = false
    /// 绳子自己从边上伸出来的进度（0...1）。实际画出来的长度还会被卡片撑住，卡片没收回去之前绳子不会先缩走
    private var ropeReveal: CGFloat = 0
    private var ropeTween: (from: CGFloat, to: CGFloat, t: CGFloat, duration: CGFloat)?

    /// 整排卡片的滚动量（内容坐标），见 ShelfView+Scroll.swift
    var scroll = Spring(0)
    /// 触控板手势正在进行（包括惯性滑动）
    var isScrollGestureActive = false
    /// 这次手势认的方向、还没认出来时累计的横竖距离
    var gestureAxis: GestureAxis?
    var gestureAccum: CGPoint = .zero
    /// 滚动量直接跟着手指（不用弹簧）：手指在触控板上、惯性滑动时
    var scrollFollow = false
    /// 跟手时估出来的手指位置、速度（pt/秒）、上一个事件的时间（事件自己的时间戳、收到时的时钟）
    var followPos: CGFloat = 0
    var followVelocity: CGFloat = 0
    /// 松手后自己滑的惯性：从哪一刻（显示时刻，第一帧时填上）、哪个位置、多快（pt/秒）开始
    /// 惯性：v0 是开始时屏幕上实际的速度，vs 是系统给的惯性速度。两者不一样时，速度在 coastBlend 秒左右从 v0 顺过去到 vs，不会一下猛冲
    var coast: (start: CFTimeInterval?, from: CGFloat, v0: CGFloat, vs: CGFloat)?
    /// 惯性滑到头：越过边的那一截（raw 是没压缩的量，屏幕上显示的是压缩后的），弹簧拉回来
    var edgeBounce: (edge: CGFloat, sign: CGFloat, x: CGFloat, xv: CGFloat)?
    /// 这一帧每一小步挪多少（跟手时，一帧分成几小步算摆动，挪动均分）
    var followStep: CGFloat = 0
    var lastFollowEvent: TimeInterval?
    var lastFollowEventMedia: CFTimeInterval = 0
    /// 滚动或换位置停下后要用来重新判断悬停的鼠标位置
    var pendingHoverPoint: CGPoint?
    /// 上一次点卡片上的按钮（垃圾桶、图钉、工具栏）是什么时候：紧跟着在原地再点一下，不当成点卡片
    var lastActionClickAt: CFTimeInterval = 0
    /// 最后一个滚动事件什么时候来的（"正在滑"的标记好一阵没事件就自己清掉）
    var lastScrollEventAt: CFTimeInterval = 0
    /// 撤销条出来时被删那张的横坐标和当时的滚动量（滚动时撤销条跟着走）
    var undoBase: (x: CGFloat, scroll: CGFloat)?
    /// 在卡片之间的空处按下的位置（松手时没怎么动就收起截图架）
    var emptyPressPoint: CGPoint?

    // 鼠标交互状态（在 ShelfView+Mouse.swift 里用）
    var hovered: CardNode?
    /// 鼠标停在卡片上一会儿才在后台转 PNG（扫过去的不转）
    var prefetchWork: DispatchWorkItem?
    var pressed: CardNode?
    var pressedAction: ShelfAction?
    var pressPoint = CGPoint.zero
    var lastHoverPoint: CGPoint?
    var draggingCard: CardNode?
    /// 正在横向拖动调整顺序的置顶卡片，以及按下时鼠标离卡片中心的横向距离
    private(set) var reorderingCard: CardNode?
    var reorderGrabOffset: CGFloat = 0
    /// 调试用：锁定悬停状态，不受真实鼠标影响
    var hoverLocked = false
    /// 正在拖时间刻度条
    /// 这次滚动是用户自己滑的（只有这种情况才弹日期牌，加卡片、置顶不弹）
    var userScrolling = false

    /// 调试用：每帧打印日期牌和刻度条的状态
    var debugTraceTimeline = false

    /// 调试用：打印绳子露出来多少（收起后应该是 0、隐藏）
    func debugDumpRope() {
        let maxIn = cards.filter { $0.phase == .hanging }
            .map { ($0.x - edgeX) * side.inward + $0.size.width / 2 }.max() ?? -.infinity
        print(String(format: "rope reach=%.4f (%.1fpt) hidden=%d shown=%d card inner edge=%.1fpt",
                     ropeReach, ropeReach * (bounds.width + 4), ropeLayer.isHidden ? 1 : 0, isShown ? 1 : 0, maxIn))
    }

    /// 调试用：打印整排状态
    func debugDump() {
        print("entries=\(entries.count) pinned=\(pinnedCount) days=\(dayGroups.count) nodes=\(cards.count)")
        print(String(format: "scroll=%.0f/%.0f content=%.0f viewport=%.0f",
                     scroll.value, maxScroll, contentLength, bounds.width))
        for g in dayGroups.prefix(14) {
            print("  day \(ShelfDates.title(for: g.day)) index=\(g.index) count=\(g.count)")
        }
        let visible = cards.filter { $0.x > 0 && $0.x < bounds.width }.sorted { $0.index < $1.index }
        print("visible cards:", visible.map { "\($0.index)@\(Int($0.x))" }.joined(separator: " "))
    }

    /// 调试用：展开进度（最远那张卡片的）和绳子正中间比两端低多少
    var debugReveal: CGFloat { live.map(\.reveal.value).max() ?? ropeReveal }
    var debugRopeSag: CGFloat { rope.point(at: bounds.midX).y - rope.leftAnchor.y }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // 视图自己的图层交给 AppKit 管，悬挂架放在子图层里。
        // 如果直接把 root 设成视图的图层，AppKit 会把 isGeometryFlipped 改回 false，整个画面上下颠倒。
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(root)
        root.isGeometryFlipped = true
        root.masksToBounds = false

        for l in [ropeShadow, ropeLayer, ropeShine] {
            l.fillColor = nil
            l.lineCap = .round
            l.lineJoin = .round
        }
        ropeShadow.strokeColor = NSColor(white: 0, alpha: 0.16).cgColor
        ropeShadow.lineWidth = 2.6
        ropeLayer.strokeColor = NSColor(calibratedRed: 0.44, green: 0.44, blue: 0.46, alpha: 0.95).cgColor
        ropeLayer.lineWidth = 1.8
        ropeShine.strokeColor = NSColor(white: 1, alpha: 0.45).cgColor
        ropeShine.lineWidth = 0.6

        root.addSublayer(ropeShadow)
        root.addSublayer(ropeLayer)
        root.addSublayer(ropeShine)
        root.addSublayer(cardsLayer)
        root.addSublayer(toolbarsLayer)
        // 滚动时卡片不停地建、拆（加减子图层）。系统默认每加减一次，父图层就整层交叉淡化 0.25 秒：
        // 旧画面定住慢慢变淡、新画面慢慢出来，快速滑时整排卡片一直是两份叠着，看起来又卡又有拖影
        let noFade: [String: CAAction] = ["sublayers": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull()]
        cardsLayer.actions = noFade
        toolbarsLayer.actions = noFade
        // 工具栏的提示要盖在别的卡片上面
        toolbarsLayer.zPosition = 5

        dateBubble = DateBubble(contentsScale: root.contentsScale)
        undoPill = UndoPill(contentsScale: root.contentsScale)
        root.addSublayer(dateBubble.layer)
        root.addSublayer(undoPill.layer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        withoutAnimation {
            root.frame = bounds
            cardsLayer.frame = root.bounds
            toolbarsLayer.frame = root.bounds
        }
        resetRope()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let s = window?.backingScaleFactor ?? 2
        let changed = root.contentsScale != s
        root.contentsScale = s
        for l in [ropeShadow, ropeLayer, ropeShine] { l.contentsScale = s }
        clipImage = ClipRenderer.image(scale: s)
        cards.forEach { $0.updateClip(clipImage, scale: s) }
        dateBubble?.setContentsScale(s)
        undoPill?.setContentsScale(s)
        // 换到倍数不一样的屏幕（1x ↔ 2x）：已经建好的卡片缩略图、图标都是按旧倍数画的，重建一遍才清楚
        if changed {
            // 用 entries 里最新的那份：卡片身上的可能是旧的（文件改过、卡片还没换），写回去会盖掉新数据
            for c in cards where c.phase == .hanging && !isBusy(c) { replaceCard(index(of: c.item.url).map { entries[$0] } ?? c.item, thumbnail: nil) }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { displayLink?.invalidate(); displayLink = nil; return }
        if clipImage == nil { viewDidChangeBackingProperties() }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        wake()
    }

    var debugLinkPaused: Bool { displayLink?.isPaused ?? true }
    /// 最后一次还在动的时间（停了以后再空转一会儿才停）
    private var lastActiveAt: CFTimeInterval = 0

    func wake() {
        // 已经在跑就什么都不动：以前每来一个滚动事件都把计时清零，下一帧一律按 8.3ms 算，
        // 那一帧真隔了 16ms 的话就少挪一半，看起来一顿
        guard let link = displayLink, link.isPaused else { return }
        lastTime = 0
        link.isPaused = false
    }

    // MARK: 公共接口
    //
    // entries 是真正的数据：整个截图文件夹，按位置排好（置顶的在最前，其余从新到旧）。
    // 卡片节点只给屏幕附近的那几条建（materialize），所以文件夹里有几千张也只有十几个节点。

    private(set) var entries: [ShelfItem] = []
    /// 前多少条是置顶的
    private(set) var pinnedCount = 0
    /// 已经建出卡片的，按 url 索引
    private var nodes: [URL: CardNode] = [:]
    /// 这一帧需要重新算一次"哪些该建、哪些该拆"
    private var needsMaterialize = true

    /// 还挂着的卡片（不含正在掉下去的），按位置排：0 在最左边
    var live: [CardNode] { cards.filter { $0.phase != .falling }.sorted { $0.index < $1.index } }
    /// 整个文件夹里的截图（不只是建了卡片的）
    var items: [ShelfItem] { entries }
    var count: Int { entries.count }

    func index(of url: URL) -> Int? { entries.firstIndex { $0.url == url.standardizedFileURL } }
    func isPinned(_ item: ShelfItem) -> Bool { (index(of: item.url) ?? Int.max) < pinnedCount }
    /// 置顶的文件，按顺序（保存用）
    var pinnedURLs: [URL] { entries.prefix(pinnedCount).map(\.url) }

    /// 启动时恢复：这几个是置顶的（按顺序）。文件夹扫完后其余的接在后面
    func setPinnedPrefix(_ urls: [URL]) {
        var pinned: [ShelfItem] = []
        var rest = entries
        for url in urls {
            guard let i = rest.firstIndex(where: { $0.url == url.standardizedFileURL }) else { continue }
            pinned.append(rest.remove(at: i))
        }
        applyEntries(pinned + rest, pinnedCount: pinned.count)
    }

    /// 文件夹扫完后把整排对一遍。置顶的顺序保持不变，其余按时间从新到旧。
    /// 屏幕上看着的那张尽量停在原地，不会因为前面插了新图而整排跳走。
    func sync(available: [ShelfItem]) {
        defer { thumbnails.prefetch(entries, scale: root.contentsScale) }
        var byURL: [URL: ShelfItem] = [:]
        for i in available { byURL[i.url] = i }

        // 置顶的保持原来的顺序，文件还在的才留下
        var pinned: [ShelfItem] = []
        for e in entries.prefix(pinnedCount) {
            if let fresh = byURL.removeValue(forKey: e.url) { pinned.append(fresh) }
        }
        let rest = byURL.values.sorted {
            $0.date != $1.date ? $0.date > $1.date : $0.url.lastPathComponent > $1.url.lastPathComponent
        }
        applyEntries(pinned + rest, pinnedCount: pinned.count)
    }

    /// 换数据：先记住屏幕中间那张是谁，排好之后把滚动量调回去，它还在原来的位置
    private func applyEntries(_ next: [ShelfItem], pinnedCount newPinned: Int) {
        let anchor = anchorURL()
        let oldIndex = anchor.flatMap { url in entries.firstIndex { $0.url == url } }
        let removed = Set(entries.map(\.url)).subtracting(next.map(\.url))

        let oldMin = minScroll
        entries = next
        pinnedCount = newPinned
        reindex()
        keepCardsInPlace(afterRangeChangeFrom: oldMin)

        // 文件没了：卡片掉下去（看得见的时候），数据已经不在 entries 里了
        for url in removed {
            guard let card = nodes.removeValue(forKey: url) else { continue }
            if isShown && card.phase == .hanging && card.x > -200 && card.x < bounds.width + 200 {
                drop(card)
            } else {
                discard(card)
            }
        }

        if canScroll, let oldIndex, let url = anchor, let newIndex = index(of: url), newIndex != oldIndex {
            let shift = CGFloat(newIndex - oldIndex) * Metrics.slotSpacing
            scroll.value += shift
            scroll.target += shift
            // 卡片的 slide 也跟着挪，不然它们会从旧位置滑到新位置
            for c in cards where c.phase == .hanging {
                c.slide.value += shift
                c.slide.target += shift
            }
        }
        layoutSlots()
        // 文件被别的应用改过（预览里改了、压缩工具覆盖了）：卡片重新建，换上新的图和比例。
        // 以前节点按路径对应，路径没变就一直显示旧图
        for c in cards where c.phase == .hanging && !isBusy(c) {
            guard let i = index(of: c.item.url), entries[i] != c.item else { continue }
            replaceCard(entries[i], thumbnail: nil)
        }
        // 张数变了，能滚动的范围也变了（从右边出来、一排放得下时，整排要继续靠右）。
        // 看得见的时候滑过去，收着的时候直接到位
        scroll.target = clampScroll(scroll.target)
        if isShown {
            settleScroll(to: scroll.target)
        } else {
            scroll.value = scroll.target
            scroll.velocity = 0
        }
        needsMaterialize = true
        wake()
    }

    /// 屏幕中间那张的 url，换数据时用它当锚点
    private func anchorURL() -> URL? {
        guard !entries.isEmpty else { return nil }
        let i = Int(((scroll.value + bounds.width / 2 - Metrics.edgeMargin) / Metrics.slotSpacing).rounded())
        return entries.indices.contains(i) ? entries[i].url : entries.last?.url
    }

    private func reindex() {
        for (i, e) in entries.enumerated() { nodes[e.url]?.index = i }
    }

    /// 从右边出来、一排放得下时，整排靠右：多一张、少一张，滚动范围会跟着挪一格。
    /// 滚动量和每张卡片的 slide 一起挪同样的距离，屏幕上的卡片先不动，
    /// 之后真正要换位置的卡片（新卡片前面的那几张）再用弹簧滑过去。
    /// 不然滚动量和卡片各用各的弹簧追，两边追得不一样快，整排会晃一下。
    private func keepCardsInPlace(afterRangeChangeFrom oldMin: CGFloat) {
        let shift = minScroll - oldMin
        guard shift != 0 else { return }
        scroll.value += shift
        scroll.target += shift
        for c in cards where c.phase == .hanging {
            c.slide.value += shift
            c.slide.target += shift
        }
    }

    /// 刚截的图：插到置顶后面、按时间排好的位置，然后从起飞点飞过去挂上。
    /// start 是根图层坐标里的起飞点。
    /// pinnedAt 不为 nil 时插到置顶那一组的这个位置（撤销删除时放回原处）
    /// thumbnail：已经有的小图（刚截的），卡片一出来就有图。startOpacity 1：一开始就完全显示（从截图那张接手）。
    /// onLanded：落到绳子上时调用
    func add(_ item: ShelfItem, from start: CGPoint, startScale: CGFloat, pinnedAt: Int? = nil,
             thumbnail: CGImage? = nil, startOpacity: Float = 0, onLanded: (() -> Void)? = nil) {
        if let thumbnail { thumbnails.storeCard(from: thumbnail, item: item, size: Metrics.cardSize(for: item.pixelSize), scale: root.contentsScale) }
        if let i = index(of: item.url) {
            // 已经在绳子上了：滑过去让它露出来
            revealEntry(at: i)
            return
        }
        var at = pinnedCount
        if let p = pinnedAt {
            at = min(max(p, 0), pinnedCount)
            pinnedCount += 1
        } else {
            while at < entries.count, entries[at].date > item.date { at += 1 }
        }
        let oldMin = minScroll
        entries.insert(item, at: at)
        reindex()
        keepCardsInPlace(afterRangeChangeFrom: oldMin)
        layoutSlots()
        // 还缩在边上（刚开始展开）：其他卡片和滚动量直接到新位置，跟着展开一起出来，见下面
        let revealing = cards.contains { $0.phase == .hanging && $0.reveal.value < 0.5 }

        let card = materialize(at: at, revealed: true)
        // start 是卡片中心，卡片的锚点在挂绳上，往上挪半张卡片的高度
        let anchor = CGPoint(x: start.x, y: start.y - card.length * startScale)
        // 整排正在展开：新卡片晚一点出发，等其他卡片先滑过它的落点，不会在落点上交叉
        card.beginFlight(from: anchor, startScale: startScale, targetX: card.slide.target,
                         delay: revealing ? Metrics.flightDelayWhileRevealing : 0, startOpacity: startOpacity)
        card.onLanded = onLanded
        // 起飞的样子马上画上去（不等下一帧）：截图那张一消失，这张就已经在同一个位置
        withoutAnimation { card.apply() }
        // 滚到能看见新卡片、又尽量露出前面置顶的位置
        settleScroll(to: card.slide.target + 2 * Metrics.edgeMargin - bounds.width)
        if revealing {
            // 不然它们一边从边上滑出来、一边又往旁边让位，两种动作叠在一起很乱。
            // 已经挂好的卡片才用弹簧滑开，给新卡片让出位置。
            scroll.value = scroll.target
            scroll.velocity = 0
            reach = revealReach
            for c in cards where c.phase == .hanging && c.reveal.value < 0.5 {
                c.slide.value = c.slide.target
                c.slide.velocity = 0
                updateX(c)
                c.hang = rope.point(at: c.x)
                c.resetSwing()
            }
        }
        card.x = targetX(of: card)
        withoutAnimation { card.apply() }
        // 悬停着的那张被挤走了：停下后按鼠标位置重新判断（不然它带着工具栏滑走）
        if let p = lastHoverPoint {
            clearHover()
            pendingHoverPoint = p
        }
        needsMaterialize = true
        wake()
        delegate?.shelfViewDidChangeItems(self)
    }

    /// 把第 i 张滑到看得见的地方
    func revealEntry(at i: Int) {
        let d = CGFloat(i) * Metrics.slotSpacing
        settleScroll(to: d + 2 * Metrics.edgeMargin - bounds.width)
        wake()
    }

    func remove(_ item: ShelfItem) { remove(url: item.url) }

    func remove(url: URL) {
        guard let i = index(of: url) else { return }
        let oldMin = minScroll
        let removed = entries.remove(at: i)
        if i < pinnedCount { pinnedCount -= 1 }
        reindex()
        keepCardsInPlace(afterRangeChangeFrom: oldMin)
        if let card = nodes.removeValue(forKey: removed.url) { drop(card) }
        let before = Dictionary(uniqueKeysWithValues: cards.map { (ObjectIdentifier($0), $0.slide.target) })
        layoutSlots()
        // 被删的那张刚开始是往上弹的，还停在原地。旁边的等它掉下去一点再补位，不然会从它底下穿过去
        for c in cards where c.phase == .hanging && before[ObjectIdentifier(c)] != c.slide.target {
            c.slideDelay = max(c.slideDelay, Metrics.removeReflowDelay)
        }
        settleScroll(to: scroll.target)
        // 后面的卡片补到鼠标下面了：停下后按鼠标位置重新判断悬停（以前要动一下鼠标才会更新，原地再点会点到下一张的图上）
        if let p = lastHoverPoint {
            clearHover()
            pendingHoverPoint = p
        }
        needsMaterialize = true
        wake()
        delegate?.shelfViewDidChangeItems(self)
    }

    /// 置顶：移到置顶那一组的最后。取消置顶：按时间放回去。
    func setPinned(_ pinned: Bool, for item: ShelfItem) {
        guard let i = index(of: item.url), (i < pinnedCount) != pinned else { return }
        let e = entries.remove(at: i)
        if i < pinnedCount { pinnedCount -= 1 }
        var to: Int
        if pinned {
            to = pinnedCount
            pinnedCount += 1
        } else {
            to = pinnedCount
            while to < entries.count, entries[to].date > e.date { to += 1 }
        }
        entries.insert(e, at: to)
        reindex()
        nodes[e.url]?.setPinned(pinned, animated: true)
        layoutSlots()
        settleScroll(to: scroll.target)
        // 卡片滑走了，停下后按鼠标位置重新判断悬停
        if let card = nodes[e.url], card.slide.target != card.slide.value, let p = lastHoverPoint {
            clearHover()
            pendingHoverPoint = p
        }
        needsMaterialize = true
        wake()
        delegate?.shelfViewDidChangeItems(self)
    }

    func showToast(_ text: String, for item: ShelfItem) {
        nodes[item.url.standardizedFileURL]?.showToast(text)
    }

    func ownsFile(_ url: URL) -> Bool {
        guard let ownedFolder else { return true }
        return url.standardizedFileURL.deletingLastPathComponent() == ownedFolder.standardizedFileURL
    }

    /// 卡片现在在屏幕上的横坐标（还没建出卡片的返回 nil）
    func screenX(of url: URL) -> CGFloat? { nodes[url.standardizedFileURL]?.x }

    /// 撤销条放在卡片下方、工具栏那一行，横坐标跟着被删的那张
    func undoAnchor(x: CGFloat) -> CGPoint {
        let y = rope.leftAnchor.y + Metrics.clipGripY + Metrics.cardMaxSize.height
            + Metrics.toolbarGap + Metrics.toolbarHeight / 2
        return CGPoint(x: x, y: y)
    }

    // MARK: 拿下来改

    /// 把这张拿下来（图藏起来，留一个虚线空位）。返回它现在在根图层里的位置（编辑窗口从这里放大出去）
    func liftCard(_ url: URL) -> CGRect? {
        guard let c = nodes[url.standardizedFileURL], c.phase == .hanging else { return nil }
        if hovered === c { clearHover() }
        let f = c.frame(in: root)
        c.setLifted(true)
        wake()
        return f
    }

    /// 拿下来的那张现在在根图层里的位置（挂点会跟着绳子动）
    func cardFrame(_ url: URL) -> CGRect? {
        guard let c = nodes[url.standardizedFileURL], c.phase == .hanging else { return nil }
        // 收回来的时候按摆正的样子算（缩回去的那张是正的）
        let saved = c.container.transform
        withoutAnimation { c.container.transform = CATransform3DIdentity }
        let f = c.frame(in: root)
        withoutAnimation { c.container.transform = saved }
        return f
    }

    /// 挂回去。fadeIn：慢慢出现（没有缩回来的动画时）；落回来时轻轻摆一下，像刚夹上
    func landCard(_ url: URL, fadeIn: Bool) {
        guard let c = nodes[url.standardizedFileURL] else { return }
        c.setLifted(false, fadeIn: fadeIn)
        if !fadeIn { c.push(angle: 0.035) }
        withoutAnimation { c.apply() }
        wake()
    }

    /// 文件被改了（存回原来那张）：数据换掉，卡片换成新的（大小可能变了，加了背景），还在原来的位置
    func replaceCard(_ item: ShelfItem, thumbnail: CGImage?) {
        guard let i = index(of: item.url) else { return }
        entries[i] = item
        if let thumbnail { thumbnails.storeCard(from: thumbnail, item: item, size: Metrics.cardSize(for: item.pixelSize), scale: root.contentsScale) }
        guard let old = nodes.removeValue(forKey: item.url) else { return }
        let lifted = old.lifted
        discard(old)
        let c = materialize(at: i, revealed: isShown)
        // 同一张图只是换了屏幕倍数：新的缩略图还没好之前先用旧的顶着，不会先闪一下灰色
        if c.thumbnail == nil, old.item == item, let t = old.thumbnail { c.showStopgap(t) }
        if lifted { c.setLifted(true, instant: true) }
        wake()
    }

    func showUndo(_ message: String, atX x: CGFloat, onUndo: @escaping () -> Void) {
        undoBase = (x, scroll.value)
        undoPill.show(message, at: undoAnchor(x: x), in: bounds, onUndo: onUndo)
        wake()
    }

    // MARK: 建卡片和回收
    //
    // 屏幕左右各留一块余量，这个范围里的截图才有卡片节点和缩略图。
    // 划出范围的节点拆掉、取消缩略图请求，内存不会随文件夹变大。

    /// 落在 [from, to] 这段距离里的位置区间
    private func indexRange(margin: CGFloat) -> ClosedRange<Int> {
        guard !entries.isEmpty else { return 0...0 }
        let slack = bounds.width * margin
        let from = scroll.value - Metrics.edgeMargin - slack
        let to = scroll.value + bounds.width - Metrics.edgeMargin + slack
        let lo = max(Int(floor(from / Metrics.slotSpacing)), 0)
        let hi = min(Int(ceil(to / Metrics.slotSpacing)), entries.count - 1)
        return lo...max(lo, hi)
    }

    /// 每帧算一次：该建的建出来，划远的拆掉
    private func updateMaterialization() {
        needsMaterialize = false
        guard !entries.isEmpty else {
            for c in cards where c.phase == .hanging { discard(c) }
            return
        }
        let keep = indexRange(margin: Metrics.dematerializeMargin)
        for c in cards where c.phase == .hanging {
            guard !keep.contains(c.index), !isBusy(c) else { continue }
            nodes.removeValue(forKey: c.item.url)
            discard(c)
        }
        let want = indexRange(margin: Metrics.materializeMargin)
        for i in want where nodes[entries[i].url] == nil {
            _ = materialize(at: i, revealed: isShown)
        }
    }

    /// 正在被用户操作的卡片不回收
    private func isBusy(_ c: CardNode) -> Bool {
        c === hovered || c === pressed || c === draggingCard || c === reorderingCard || c.phase == .flying || c.lifted
    }

    // MARK: 搜索

    /// 正在搜的字（nil：没在搜）
    private(set) var searchQuery: String?
    /// 对得上的（按整排的位置排）
    private(set) var searchMatches: [Int] = []

    /// 搜：对不上的卡片变淡，对上的字涂黄。match 返回 nil 表示这张对不上
    func setSearch(_ q: String?, match: (URL) -> [CGRect]?) {
        let query = q?.trimmingCharacters(in: .whitespaces)
        searchQuery = (query?.isEmpty ?? true) ? nil : query
        searchBoxes = [:]
        searchMatches = []
        if searchQuery != nil {
            for (i, e) in entries.enumerated() {
                if let boxes = match(e.url) { searchBoxes[e.url] = boxes; searchMatches.append(i) }
            }
        }
        for c in cards { applySearch(c) }
    }

    private var searchBoxes: [URL: [CGRect]] = [:]

    private func applySearch(_ c: CardNode) {
        guard searchQuery != nil else { c.setSearchDimmed(false); c.setSearch(nil); return }
        let boxes = searchBoxes[c.item.url]
        c.setSearchDimmed(boxes == nil)
        c.setSearch(boxes)
    }

    @discardableResult
    private func materialize(at i: Int, revealed: Bool) -> CardNode {
        let item = entries[i]
        let card = CardNode(item: item, ownsFile: ownsFile(item.url),
                            thumbnail: thumbnails.cached(ShelfThumbnails.cardKey(item, size: Metrics.cardSize(for: item.pixelSize), scale: root.contentsScale)),
                            clipImage: clipImage, contentsScale: root.contentsScale)
        card.index = i
        card.setPinned(i < pinnedCount, animated: false)
        card.reveal = RevealMotion(hidden: !revealed)
        card.slide.value = CGFloat(i) * Metrics.slotSpacing
        card.slide.target = card.slide.value
        cardsLayer.addSublayer(card.container)
        toolbarsLayer.addSublayer(card.toolbar)
        cards.append(card)
        nodes[item.url] = card
        updateX(card)
        card.hangImmediately(at: rope.point(at: card.x))
        if card.thumbnail == nil { loadThumbnail(card) }
        withoutAnimation { card.apply(); applySearch(card) }
        return card
    }

    private func loadThumbnail(_ card: CardNode) {
        card.thumbnailToken = thumbnails.loadCard(card.item, size: card.size, scale: root.contentsScale) { [weak self, weak card] image in
            guard let self, let card, card.phase != .falling else { return }
            card.thumbnailToken = nil
            card.thumbnail = image
            self.wake()
        }
    }

    /// 直接拆掉（不掉落动画）
    private func discard(_ card: CardNode) {
        thumbnails.cancel(card.thumbnailToken)
        card.thumbnailToken = nil
        if hovered === card { clearHover() }
        if pressed === card { pressed = nil }
        card.container.removeFromSuperlayer()
        card.toolbar.removeFromSuperlayer()
        cards.removeAll { $0 === card }
    }

    // MARK: 按天分组（日期气泡和刻度条用）

    struct DayGroup {
        let day: Date
        /// 这一天第一张在整排里的位置
        let index: Int
        let count: Int
    }

    private(set) var dayGroups: [DayGroup] = []

    /// 只给没置顶的那一段分组：置顶的是用户自己排的，不按时间
    private func rebuildDayGroups() {
        let cal = Calendar.current
        var groups: [DayGroup] = []
        for i in pinnedCount..<entries.count {
            let day = cal.startOfDay(for: entries[i].date)
            if let last = groups.last, last.day == day {
                groups[groups.count - 1] = DayGroup(day: day, index: last.index, count: last.count + 1)
            } else {
                groups.append(DayGroup(day: day, index: i, count: 1))
            }
        }
        dayGroups = groups
    }


    /// 展开：整排从出来的那条边平移出来，离边远的早一点出发，像一串被拉出来的卡片。
    /// 收起：反过来，靠边的先滑回去。绳子跟着伸出、收回。
    func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        // 一屏里看得见几张，只有这几张需要错开时间
        let visible = max(Int((bounds.width - 2 * Metrics.edgeMargin) / Metrics.slotSpacing) + 1, 1)
        if shown {
            // 收起到一半又展开：卡片还看得见，保留滚动位置，从当前位置直接滑回去
            let stillVisible = cards.contains { $0.phase == .hanging && $0.reveal.value > 0.05 }
            if !stillVisible {
                // 回到最新的那一头：最新的在最左边
                scroll.value = minScroll; scroll.target = minScroll; scroll.velocity = 0
            }
            // 滚动量可能变了，要重新算哪些卡片该建出来
            needsMaterialize = true
            updateMaterialization()
            layoutSlots()
            reach = revealReach
            // 缩在屏幕外的卡片按新的滚动量直接放到起点，摆动清零。
            // 不然滚动量一变，挂点瞬间跳几百 pt，卡片会被甩到很大的角度再滑出来
            for c in cards where c.phase == .hanging && c.reveal.value <= 0.05 {
                c.slide.value = c.slide.target
                c.slide.velocity = 0
                updateX(c)
                c.hang = rope.point(at: c.x)
                c.resetSwing()
            }
            // 看得见的卡片（正在补位、刚换完顺序）从当前位置接着滑，不瞬移；缩回去的上面已经放好了
            for c in cards where c.phase != .flying {
                let rank = edgeRank(c, visible: visible)
                let delay = rank < visible ? CGFloat(visible - 1 - rank) * Metrics.revealStagger : 0
                c.reveal.show(after: delay)
            }
        } else {
            if let r = reorderingCard { endReorder(r) }
            // 滑到一半被收起：手势结束的事件之后不会再进来（scrollWheel 只在显示时处理），
            // 这里把滚动的状态清掉。不然"正在滑"一直挂着：显示链接停不下来、截图架收不干净、下次打开悬停和点击都失灵
            isScrollGestureActive = false
            scrollFollow = false
            coast = nil
            edgeBounce = nil
            lastFollowEvent = nil
            scroll.target = clampScroll(scroll.value)
            // 按屏幕上离边的远近错开：最靠边那张先走
            for c in cards {
                c.reveal.hide(after: CGFloat(edgeRank(c, visible: visible)) * Metrics.hideStagger)
            }
            dateBubble.hide()
            undoPill.hide()
        }
        ropeTween = (ropeReveal, shown ? 1 : 0, 0, shown ? Metrics.ropeRevealDuration : Metrics.ropeHideDuration)
        wake()
    }

    func drop(_ card: CardNode) {
        if hovered === card { hovered = nil }
        if pressed === card { pressed = nil }
        if reorderingCard === card { reorderingCard = nil }
        card.beginFall()
    }

    // MARK: 调整置顶顺序

    func beginReorder(_ card: CardNode) {
        reorderingCard = card
        clearHover()
        card.container.zPosition = 5
        // 拖动时卡片紧跟鼠标
        card.slide.stiffness = 900
        card.slide.damping = 60
        wake()
    }

    /// x 是卡片中心应该在的屏幕横坐标。只能在置顶的那几张之间移动。
    func updateReorder(screenX x: CGFloat) {
        guard let card = reorderingCard, pinnedCount > 1 else { return }
        let spacing = Metrics.slotSpacing
        let d = min(max(distance(atScreenX: x), 0), CGFloat(pinnedCount - 1) * spacing)
        card.slide.target = d
        let newIndex = Int((d / spacing).rounded())
        if let old = index(of: card.item.url), old != newIndex {
            let e = entries.remove(at: old)
            entries.insert(e, at: newIndex)
            reindex()
            layoutSlots()
        }
        wake()
    }

    func endReorder(_ card: CardNode) {
        guard reorderingCard === card else { return }
        reorderingCard = nil
        card.container.zPosition = 0
        card.slide.stiffness = 170
        card.slide.damping = 22
        layoutSlots()
        wake()
        delegate?.shelfViewDidChangeItems(self)
    }

    // MARK: 布局

    /// 悬挂架出来的那条屏幕边的横坐标
    private var edgeX: CGFloat { side == .right ? bounds.width : 0 }

    /// 内容坐标 p 的卡片落定时在屏幕上的横坐标。从左往右排，第 0 张在最左边
    private func shownX(_ p: CGFloat) -> CGFloat { Metrics.edgeMargin + p - scroll.value }

    /// 卡片离出来那条边的远近次序（只算屏幕上的：0 最靠边），展开收起错开时间用
    private func edgeRank(_ c: CardNode, visible: Int) -> Int {
        let fromEdge = (shownX(c.slide.target) - edgeX) * side.inward - Metrics.edgeMargin
        return min(max(Int((fromEdge / Metrics.slotSpacing).rounded()), 0), visible)
    }

    /// 内容坐标 d 的卡片在屏幕上的横坐标。reveal 是展开进度：1 在绳子上，0 缩在屏幕边外面。
    ///
    /// 展开收起是整排一起平移（像抽屉），不是每张从同一个点散开：
    /// 收起时屏幕上的每张都往边上挪同样的距离 revealReach，刚好让最远那张也出了屏幕。
    /// 这样卡片间距不变，不会在屏幕边上挤成一堆，离边近的也不会走得特别慢。
    /// 落在屏幕另一头外面的卡片（滚动时提前建好的）不跟着动，否则平移时会从屏幕上划过去。
    private func screenX(distance d: CGFloat, reveal p: CGFloat, halfWidth: CGFloat) -> CGFloat {
        let shown = shownX(d)
        guard !isBeyondFarEdge(shownX: shown, halfWidth: halfWidth) else { return shown }
        let hidden = shown - side.inward * reach
        return hidden + (shown - hidden) * p
    }

    /// 卡片落定的位置在屏幕另一头外面
    private func isBeyondFarEdge(shownX x: CGFloat, halfWidth: CGFloat) -> Bool {
        (x - edgeX) * side.inward - halfWidth > bounds.width
    }

    /// revealReach 的值，每一步物理开始时算一次（卡片多时不用每张都重算一遍）
    private var reach: CGFloat = Metrics.edgeMargin + Metrics.cardMaxSize.width

    /// 收起时整排要往边上挪多远：屏幕上最远那张的外侧离边缘的距离，再多一点余量
    private var revealReach: CGFloat {
        var reach = Metrics.edgeMargin + Metrics.cardMaxSize.width / 2
        for c in cards where c.phase == .hanging {
            let half = c.size.width / 2
            let shown = shownX(c.slide.value)
            let outer = (shown - edgeX) * side.inward + half
            if outer - 2 * half <= bounds.width { reach = max(reach, outer) }
        }
        return min(reach, bounds.width + Metrics.cardMaxSize.width) + 24
    }

    /// 屏幕横坐标对应的内容坐标（拖动调整顺序时用）
    func distance(atScreenX x: CGFloat) -> CGFloat {
        x - Metrics.edgeMargin + scroll.value
    }

    private func updateX(_ c: CardNode) {
        c.x = screenX(distance: c.slide.value, reveal: c.reveal.value, halfWidth: c.size.width / 2)
    }

    /// 卡片落定后在屏幕上的横坐标
    func targetX(of c: CardNode) -> CGFloat {
        screenX(distance: c.slide.target, reveal: 1, halfWidth: c.size.width / 2)
    }

    /// 滚动量的范围。放不下时是 0...超出的长度：0 是最新的那头（最左边），越大越旧。
    /// 放得下时只有一个值：从左边出来是 0（整排靠左）；从右边出来是负数，整排靠右。
    var scrollRange: ClosedRange<CGFloat> {
        let over = contentLength - bounds.width
        if over > 0 { return 0...over }
        return side == .right ? over...over : 0...0
    }
    var minScroll: CGFloat { scrollRange.lowerBound }
    var maxScroll: CGFloat { scrollRange.upperBound }
    /// 一排放不下，可以滚动
    var canScroll: Bool { contentLength > bounds.width }
    func clampScroll(_ v: CGFloat) -> CGFloat { min(max(v, minScroll), maxScroll) }

    /// 整排内容的总长度（刻度条用）
    var contentLength: CGFloat {
        2 * Metrics.edgeMargin + Metrics.slotSpacing * CGFloat(max(entries.count - 1, 0))
    }

    private func layoutSlots() {
        for c in cards where c.phase == .hanging && c !== reorderingCard {
            c.slide.target = CGFloat(c.index) * Metrics.slotSpacing
        }
        rebuildDayGroups()
    }

    func resetRope() {
        // 两端略微伸出屏幕，看起来是从屏幕边缘拉过来的
        let inset: CGFloat = -2
        let y = topInset + Metrics.ropeTopInset
        let sag = min(max(bounds.width * Metrics.ropeSagRatio, 8), 22)
        rope.reset(left: CGPoint(x: inset, y: y), right: CGPoint(x: bounds.width - inset, y: y), sag: sag)
        layoutSlots()
        // 换边、换屏幕：放得下时整排要贴到新的那一边
        scroll.value = clampScroll(scroll.value)
        scroll.target = clampScroll(scroll.target)
        scroll.velocity = 0
        for c in cards where c.phase == .hanging {
            c.slide.value = c.slide.target
            updateX(c)
            c.hang = rope.point(at: c.x)
            c.resetSwing()
        }
        wake()
    }

    // MARK: 时间刻度条和日期牌

    private var timelineAnimating = false

    /// 屏幕中间那张在整排里的位置（滑动时日期牌按它显示）
    var centerEntryIndex: Int {
        guard !entries.isEmpty else { return 0 }
        let i = Int(((scroll.value + bounds.width / 2 - Metrics.edgeMargin) / Metrics.slotSpacing).rounded())
        return min(max(i, 0), entries.count - 1)
    }

    /// 最靠前（靠左）那张在整排里的位置。从日期列表跳过去时那一天的第一张就停在这里
    var leadingEntryIndex: Int {
        guard !entries.isEmpty else { return 0 }
        return min(max(Int((scroll.target / Metrics.slotSpacing).rounded()), 0), entries.count - 1)
    }

    /// 从日期列表跳过去时，日期牌显示选的那一天，而不是途中经过的、或者到了尽头停在中间的那一天
    var jumpLabelIndex: Int?

    private func updateTimeline(_ dt: CGFloat) {
        guard let dateBubble else { return }
        let scrolling = isScrollGestureActive || !scroll.isSettled
        if !scrolling { userScrolling = false }

        // 滑动时显示当前这一天
        if !scrolling { jumpLabelIndex = nil }
        if userScrolling && scrolling && !entries.isEmpty {
            let clamped = min(jumpLabelIndex ?? centerEntryIndex, entries.count - 1)
            let day = clamped < pinnedCount ? nil : Calendar.current.startOfDay(for: entries[clamped].date)
            let y = rope.point(at: bounds.midX).y - 2
            dateBubble.show(day: day, at: CGPoint(x: bounds.midX, y: y))
        } else if !scrolling {
            dateBubble.hide()
        }
        let a = dateBubble.step(dt)
        if let b = undoBase { undoPill.move(toX: b.x - (scroll.value - b.scroll)) }
        let c = undoPill.step(dt)
        timelineAnimating = a || c
        if debugTraceTimeline {
            print(String(format: "bubble op=%.2f pos=(%.0f,%.0f) \"%@\" scrolling=%d user=%d",
                         dateBubble.layer.opacity, dateBubble.layer.position.x, dateBubble.layer.position.y,
                         dateBubble.label, scrolling ? 1 : 0, userScrolling ? 1 : 0))
        }
    }

    // MARK: 动画循环

    /// 调试用：动画循环跑了多少帧
    var debugTickCount = 0

    /// 调试：每一帧花了多久、两帧之间隔了多久（量卡不卡）
    var debugTickMs: [Double] = []
    /// 调试：滚的时候同一时刻屏幕上最多有几张还是灰的（没图）
    var debugGrayMax = 0
    var debugFrameGaps: [Double] = []
    /// 调试：一帧里建卡片最多花了多久（ms）
    var debugMaterializeMax = 0.0
    private var debugLastTick: CFTimeInterval = 0

    @objc private func tick(_ link: CADisplayLink) {
        debugTickCount += 1
        let t0 = CACurrentMediaTime()
        defer {
            if DebugOptions.isDebugRun {
                let gray = cards.filter { $0.x > 0 && $0.x < bounds.width && $0.thumbnail == nil }.count
                debugGrayMax = max(debugGrayMax, gray)
                debugTickMs.append((CACurrentMediaTime() - t0) * 1000)
                if debugLastTick > 0 { debugFrameGaps.append((t0 - debugLastTick) * 1000) }
                debugLastTick = t0
            }
        }
        // 算到"这一帧显示出来的那一刻"（targetTimestamp），不是现在：两次回调之间隔得不均匀（主线程忙一点就晚到）时，
        // 按现在的时间算，这一帧挪得多、下一帧挪得少，看起来一顿一顿；按显示的时刻算，每帧挪的一样多
        let now = link.targetTimestamp
        let dt = lastTime == 0 ? link.targetTimestamp - link.timestamp : min(max(now - lastTime, 1.0 / 240), 1.0 / 30)
        lastTime = now
        let steps = max(Int((dt * 240).rounded()), 1)
        let h = CGFloat(dt) / CGFloat(steps)
        if needsMaterialize || !scroll.isSettled {
            let m0 = CACurrentMediaTime()
            updateMaterialization()
            if DebugOptions.isDebugRun { debugMaterializeMax = max(debugMaterializeMax, (CACurrentMediaTime() - m0) * 1000) }
        }
        if var e = edgeBounce {
            // 惯性滑到头：越过的那一截按弹簧拉回来，显示时压缩（越往外越拉不动），最多显示 edgeLimit
            for _ in 0..<steps {
                let a = -Self.edgeSpring.stiffness * e.x - Self.edgeSpring.damping * e.xv
                e.xv += a * h
                e.x += e.xv * h
            }
            let x = max(e.x, 0)
            let goal = e.edge + e.sign * Self.edgeLimit * x / (Self.edgeLimit + x)
            if e.x <= 0.3 && e.xv <= 0 {
                edgeBounce = nil
                scroll.value = e.edge
                scroll.target = e.edge
                scroll.velocity = 0
                scrollFollow = false
                followStep = 0
            } else {
                edgeBounce = e
                scroll.target = goal
                followStep = (goal - scroll.value) / CGFloat(steps)
            }
        } else if var c = coast {
            // 惯性：按减速曲线算这一帧显示那一刻在哪（和帧的时间对齐，每帧挪的距离一定是匀的）。
            // 速度 = vs·e^(-kt) + (v0 - vs)·e^(-t/τ)：开头接着屏幕上原来的速度，τ 左右顺到系统给的惯性
            if c.start == nil { c.start = now - dt; c.from = scroll.value; coast = c }
            let k = -log(Self.coastDecay) * 1000
            let tau = Self.coastBlend
            let a = CGFloat(now - (c.start ?? now))
            let v = c.vs * exp(-k * a) + (c.v0 - c.vs) * exp(-a / tau)
            let goal = c.from + c.vs * (1 - exp(-k * a)) / k + (c.v0 - c.vs) * tau * (1 - exp(-a / tau))
            if goal < minScroll || goal > maxScroll {
                // 滑到头：越过的那一截接着冲出去、越来越拉不动，再弹回来。
                // 以前是把速度一下限到 2000pt/s 交给弹簧：快速甩到头时一帧里从 150 多点降到 10 点，像撞墙
                coast = nil
                let edge = goal < minScroll ? minScroll : maxScroll
                let L = Self.edgeLimit
                let over = min(abs(goal - edge), L * 0.9)
                let x = L * over / (L - over)
                edgeBounce = (edge: edge, sign: goal < minScroll ? -1 : 1, x: x, xv: abs(v) * (L + x) * (L + x) / (L * L))
                let shown = edge + (goal < minScroll ? -over : over)
                scroll.target = shown
                followStep = (shown - scroll.value) / CGFloat(steps)
            } else if abs(v) < 12 {
                coast = nil
                scroll.value = goal
                scroll.target = goal
                scroll.velocity = 0
                scrollFollow = false
            } else {
                scroll.target = goal
                followStep = (goal - scroll.value) / CGFloat(steps)
            }
        } else if scrollFollow {
            // 这一帧显示出来那一刻，手指应该在哪：从最后一个事件按速度往前推（最多推 followAhead）。
            // 好一阵没来事件（手指停住不动、惯性结束）：停在手指真正的位置，不再往前推
            var goal = scroll.target
            if let last = lastFollowEvent, CACurrentMediaTime() - lastFollowEventMedia < 0.03 {
                let ahead = CGFloat(min(max(now - last, 0), Self.followAhead))
                goal = followPos + followVelocity * ahead
            } else {
                // 不跳过去：顺着靠过去（往前推多了一点点的那一截，几帧里收回来）
                followVelocity = 0
                followPos = scroll.target
                goal = scroll.value + (scroll.target - scroll.value) * CGFloat(1 - exp(-dt / 0.03))
                if abs(scroll.target - scroll.value) < 0.3 { goal = scroll.target }
            }
            followStep = (goal - scroll.value) / CGFloat(steps)
        }
        for _ in 0..<steps { simulate(h) }
        advanceTransients(CGFloat(dt))
        for c in cards { c.stepHover(CGFloat(dt)); c.stepHoverDetail(CGFloat(dt)) }
        updateTimeline(CGFloat(dt))
        render()

        // 保险：惯性结束的事件有时送到了别的窗口（鼠标已经离开、窗口变成点穿），"正在滑"会一直挂着，悬停和暂停都卡住
        if isScrollGestureActive, coast == nil, edgeBounce == nil, CACurrentMediaTime() - lastScrollEventAt > 0.5 {
            isScrollGestureActive = false
        }
        if let p = pendingHoverPoint, !isScrollGestureActive, scroll.isSettled,
           live.allSatisfy({ $0.slide.isSettled }) {
            pendingHoverPoint = nil
            updateHover(at: p)
        }
        let settled = rope.maxMotion < 0.01 && ropeTween == nil && scroll.isSettled && !isScrollGestureActive
            && coast == nil && edgeBounce == nil
            && !timelineAnimating
            && cards.allSatisfy { $0.isSettled && $0.hoverDetailSettled && $0.reveal.isSettled }
        if settled {
            // 停了以后再空转一小会儿才真的停（显示器的节拍不断）：用户经常停一下马上又滑，
            // 停掉再重新开始，第一帧要等下一次节拍、常常晚一帧，第一下就像顿了一下。空转一帧不到 0.1ms
            if isShown && CACurrentMediaTime() - lastActiveAt < 1.0 { return }
            link.isPaused = true
            if !isShown { delegate?.shelfViewDidFinishHiding(self) }
        } else {
            lastActiveAt = CACurrentMediaTime()
        }
    }

    private func stepRopeTween(_ h: CGFloat) {
        guard var tw = ropeTween else { return }
        tw.t = min(tw.t + h / tw.duration, 1)
        // 伸出来先快后慢；收回去先慢后快
        let e = tw.to > tw.from ? 1 - pow(1 - tw.t, 3) : tw.t * tw.t * tw.t
        ropeReveal = tw.from + (tw.to - tw.from) * e
        ropeTween = tw.t >= 1 ? nil : tw
    }

    private func simulate(_ h: CGFloat) {
        stepRopeTween(h)
        reach = revealReach
        let scrollBefore = scroll.value
        if scrollFollow {
            // 跟手：这一帧要到的地方在 tick 里算好了，几小步均分
            scroll.value += followStep
            scroll.velocity = (scroll.value - scrollBefore) / h
        } else {
            scroll.step(h)
        }
        let ds = scroll.value - scrollBefore
        var loads: [Rope.Load] = []
        var shifts: [(scroll: CGFloat, reveal: CGFloat)] = []
        let hanging = cards.filter { $0.phase == .hanging }
        for c in hanging {
            let p0 = c.reveal.value
            c.reveal.step(h)
            if c.slideDelay > 0 { c.slideDelay -= h } else { c.slide.step(h) }
            let half = c.size.width / 2
            let shown = screenX(distance: c.slide.value, reveal: 1, halfWidth: half)
            let hidden = screenX(distance: c.slide.value, reveal: 0, halfWidth: half)
            updateX(c)
            // 整排滚动和展开收起带来的那部分位移单独记下，摆动时按各自的惯性算
            // 滚动量变大，卡片往左走
            shifts.append((-ds * c.reveal.value, (shown - hidden) * (c.reveal.value - p0)))
            // 滑到屏幕外的卡片不再压着绳子
            if c.x > 0 && c.x < bounds.width { loads.append(.init(x: c.x, mass: Metrics.cardRopeMass)) }
        }
        rope.step(dt: h, loads: loads)
        for (c, s) in zip(hanging, shifts) {
            c.stepSwing(dt: h, hangPoint: rope.point(at: c.x), scrollDelta: s.scroll, revealDelta: s.reveal)
        }
    }

    private func advanceTransients(_ dt: CGFloat) {
        for c in cards where c.phase == .flying {
            c.slide.value = c.slide.target
            c.x = targetX(of: c)
            if c.stepFlight(dt: dt, hangPoint: rope.point(at: c.x)), !ReduceMotion.isOn {
                rope.kick(at: c.x, dy: 3)
            }
        }
        var gone: [CardNode] = []
        for c in cards where c.phase == .falling {
            if c.stepFall(dt: dt, floor: bounds.height + 200) { gone.append(c) }
        }
        for c in gone { c.container.removeFromSuperlayer(); c.toolbar.removeFromSuperlayer() }
        cards.removeAll { c in gone.contains { $0 === c } }
    }

    /// 绳子从边上伸出来的长度：绳子自己的进度和最远那张卡片，取更长的
    private var ropeReach: CGFloat {
        var reach = ropeReveal * (bounds.width + 4)
        for c in cards where c.phase != .falling {
            let d = (c.x - edgeX) * side.inward
            guard d - c.size.width / 2 <= bounds.width else { continue }
            // 绳子要比最远那张再多伸出一点，但只在卡片露出来以后才多伸：
            // 收好的卡片在边外 24pt，多伸的 30pt 会让边上留一截线头
            let inner = d + c.size.width / 2
            reach = max(reach, inner + min(max(inner, 0), 30))
        }
        return min(max(reach / (bounds.width + 4), 0), 1)
    }

    private func render() {
        let path = CGMutablePath()
        let p = rope.points
        if let first = p.first {
            path.move(to: first)
            for i in 1..<max(p.count - 1, 1) {
                let mid = CGPoint(x: (p[i].x + p[i + 1].x) / 2, y: (p[i].y + p[i + 1].y) / 2)
                path.addQuadCurve(to: mid, control: p[i])
            }
            if let last = p.last { path.addLine(to: last) }
        }
        // 绳子的路径从左往右，只画靠边的那一段
        let f = ropeReach
        let (start, end) = side == .right ? (1 - f, CGFloat(1)) : (CGFloat(0), f)
        withoutAnimation {
            ropeLayer.path = path
            var down = CGAffineTransform(translationX: 0, y: 1.6)
            ropeShadow.path = path.copy(using: &down)
            var up = CGAffineTransform(translationX: 0, y: -0.5)
            ropeShine.path = path.copy(using: &up)
            for l in [ropeShadow, ropeLayer, ropeShine] {
                l.strokeStart = start
                l.strokeEnd = end
                l.isHidden = f < 0.002
            }
            cards.forEach { $0.apply() }
        }
    }
}

/// 展开收起的进度：1 是在绳子上的位置，0 是完全缩在屏幕边外面。
/// 展开用弹簧（最后略冲过一点再回来），收起用固定时长的缓动。
struct RevealMotion {
    private var spring: Spring
    private var delay: CGFloat = 0
    private var tween: (from: CGFloat, t: CGFloat)?

    init(hidden: Bool = false) {
        spring = Spring(hidden ? 0 : 1)
        spring.stiffness = Metrics.revealSpring.stiffness
        spring.damping = Metrics.revealSpring.damping
    }

    var value: CGFloat { spring.value }

    mutating func show(after d: CGFloat) {
        tween = nil
        delay = d
        spring.target = 1
    }

    mutating func hide(after d: CGFloat) {
        delay = d
        tween = (spring.value, 0)
        spring.target = 0
    }

    mutating func step(_ h: CGFloat) {
        if delay > 0 { delay -= h; return }
        if var tw = tween {
            tw.t = min(tw.t + h / Metrics.hideDuration, 1)
            // 起步稍慢、越走越快地滑出屏幕。出了屏幕看不见，末端不用减速；
            // 之前用的是先慢后快再慢，卡片快到边上时反而慢下来，看着拖沓
            let t = tw.t
            let e = t * t * (1.6 - 0.6 * t)
            spring.value = tw.from * (1 - e)
            spring.velocity = 0
            tween = t >= 1 ? nil : tw
        } else {
            spring.step(h)
        }
    }

    var isSettled: Bool {
        delay <= 0 && tween == nil && abs(spring.target - spring.value) < 0.0005 && abs(spring.velocity) < 0.003
    }
}

func withoutAnimation(_ body: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    body()
    CATransaction.commit()
}
