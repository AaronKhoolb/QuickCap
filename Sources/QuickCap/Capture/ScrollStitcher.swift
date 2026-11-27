import CoreGraphics
import Foundation

/// 滚动截图的拼接：一帧一帧喂进来（同一块区域，用户自己在滚），算出每帧比上一帧往下滚了几个像素，把新露出来的那几行接在下面。
/// 窗口里常常只有一部分在滚（中间的内容），旁边的侧栏、顶上的工具栏、浮在下面的输入框都不动。所以先看几次滚动：
/// - 哪几列真的在变：最宽的那一段就是滚动的那一栏。出来的图一直是整个宽度，一点都不裁：
///   左右不动的侧栏上半截、下半截照原样，中间接长的那段用侧栏自己的底色补（像窗口被拉高了），不会一节一节重复
/// - 那一栏里从上、从下数哪几行一直没变：顶上的留第一帧的，底下的（输入框、底栏）留最后一帧的，都只留一份
/// - 往回滚：跟着记位置（不接，再往下滚过了才接）；停着不动：不接；滚太快两帧对不上：这帧不要，等下一帧再对
/// - 到底时的"回弹"（触控板、自动滚动滚过头，内容被拉上去、下面露出一片底色，再弹回来）：
///   弹回来以后，最后看到的地方再往下那一截整行都是底色的，是露出来的空白，不是内容，去掉
/// - 每一行内容取它滚到画面中间时的那一帧（不取刚从底边露出来的那一刻）：浮在内容上的东西（半透明的输入框、
///   鼠标停在链接上时左下角的网址、贴在边上的条）多半在边上，这样就不会一节一节重复；最后一帧照原样接在最下面
/// 算位移用的是每帧缩小成 128 列的灰度（全高），先粗找、再在原来的行上精确到 1 像素
/// 一栏的拼接（喂的是整帧里这一栏那么宽的一块）。整个窗口里可能有好几栏能滚（左边标签栏、右边网页），每栏一个，见下面的 ScrollStitcher
final class ScrollLane {
    static let cols = 128

    /// 一帧的灰度：每行 128 个点
    struct Gray {
        let rows: Int
        var px: [UInt8]
    }

    private var first: CGImage?
    private var last: CGImage?
    /// 拿来对位移的那一帧（上一帧接上的）、上一帧（看哪里变了）
    private var refGray: Gray?
    private var prevGray: Gray?
    private var firstGray: Gray?
    /// 接在下面的那些（每块是某一帧滚动那一栏中线上下的几行，已经裁成那一栏的宽度；row：从内容的第几行开始）
    private var strips: [(row: Int, img: CGImage)] = []
    /// 滚到最下面的那一帧、它的位置和灰度（最后接在下面的那一截从它取：往回滚过也不会少）
    private var deepest: CGImage?
    private var deepestGray: Gray?
    private var maxPosition = 0
    /// 每一列按算出来的位移对齐以后还差多少（累加、次数）：跟着内容滚的列几乎是 0；
    /// 滚的时候才浮出来、自己慢慢挪的滚动条差很多，不接进长图
    private var colMis = [Double](repeating: 0, count: cols)
    private var colMisN = 0
    /// 每一列在所有帧里最亮和最暗差多少：一直是空白的列很小
    private var colRange = [Int](repeating: 0, count: cols)
    /// 上一帧接上的那帧和它的位置（滚得快的时候，这一帧看不到的那几行从它取）
    private var lastPosition = 0
    /// 内容接到第几行了（内容坐标：第一帧滚动那段的第 0 行是 0）。第一帧的上半段跟着顶上那块一起出
    private var committed = 0
    /// 滚动的那一栏：左右（在 128 列里的第几列到第几列）、顶上底下不动的行数（像素）
    private(set) var colLo = 0, colHi = cols - 1
    /// 往两边扩之前的范围（真的在变的那几列）
    private var coreLo = 0, coreHi = cols - 1
    private(set) var header = 0, footer = 0
    private var settled = false
    /// 看了几次滚动；每列变过几次；每次滚动哪些点变了
    private var motions = 0
    /// 定下来之前，一共有多少行变过（大概滚了多远）
    private var movedRows = 0
    private var colChanged = [Int](repeating: 0, count: cols)
    private var rowChangedMasks: [[Bool]] = []
    private var pending: [(CGImage, Gray)] = []
    /// 定下来时拿来和第一帧比的那一帧
    private var settleGray: Gray?
    private var settleRange: ClosedRange<Int>?
    /// 最近每帧挪多少（像素）、离拿来对位移的那一帧隔了几帧
    private var velocity: Double?, prevVelocity: Double?
    /// 回弹看过的停住位置
    private var bounceChecked: Int?
    private var framesSinceRef = 0
    private var covered = 0
    private var position = 0
    private(set) var frameCount = 0
    private(set) var rejected = 0
    /// 连着几帧对不上了
    private var rejectRun = 0
    /// 这一栏没挪、只有一块原地变了几次（自动滚动拿它看指针是不是压在一块自己能滚的小框上）
    private(set) var inPlaceChanges = 0
    /// 上一帧对不上、之后还没再对上：再往下滚就会漏掉内容（要提示用户往回滚一点）
    private(set) var lost = false

    /// 拼好的总高（像素，大约）
    var height: Int { (first?.height ?? 0) + maxPosition }
    /// 这一帧比上一帧挪了几行（像素，往下滚是正的）：nil = 还没定下来、对不上；0 = 没动。自动滚动拿它看是不是到底了
    private(set) var lastMove: Int?
    var isSettled: Bool { settled }
    /// 真的接上过内容（往下滚过）
    var hasContent: Bool { maxPosition > 0 }
    /// 现在滚到哪、最远滚到过哪（像素）
    var farthest: Int { maxPosition }
    /// 不看的列（别的栏已经在拼的那几列）：这些列变了不算，也一定不算进这一栏
    var ignore: [Bool]?

    /// 交图前：还在看的变化先确认是不是在滚（是才定下来、接上；鼠标经过的高亮之类不会被硬当成滚动）
    func finish() {
        guard !settled, motions > 0, let (img, g) = pending.last else { return }
        trySettle(img, g)
    }

    /// 这一栏边上的空白（页边）在 128 列里的哪一列：从边往里找（跳过最外面两列：滚动条、窗口边），
    /// 第一列从上到下都是一个颜色的。找不到（边上就是内容）返回 nil。right：从右边找，不然从左边
    func marginColumn(right: Bool) -> Int? {
        // 只在这一栏自己的范围里找（往两边扩进来的空白不算：那可能是两栏之间的缝，下面不是这一栏）
        let lo = coreLo, hi = coreHi
        guard let g = refGray ?? firstGray, hi - lo >= 8 else { return nil }
        let r0 = header, r1 = g.rows - footer
        guard r1 - r0 > 16 else { return nil }
        let limit = max(3, (hi - lo) / 6)
        for k in 2...limit {
            let c = right ? hi - k : lo + k
            var mn = 255, mx = 0
            for r in stride(from: r0, to: r1, by: 2) { let v = Int(g.px[r * Self.cols + c]); mn = min(mn, v); mx = max(mx, v) }
            if mx - mn <= 4 { return c }
        }
        return nil
    }

    /// 滚动那一栏在图里的左右（像素）
    func columnPixels(_ w: Int) -> (Int, Int) { columnRange(w) }
    /// 滚动那一栏（128 列里的第几到第几列）
    var columns: ClosedRange<Int> { colLo...colHi }
    /// 上一次出的图里内容最下面在第几行（再往下是底下不动的那条）：几栏拼在一起、这一栏短时从这里往下拉长
    private(set) var contentBottom = 0

    /// 喂一帧。返回 true：接上了新的行
    @discardableResult
    func add(_ img: CGImage) -> Bool {
        guard let g = Self.gray(img) else { return false }
        return add(img, g)
    }

    /// 这一帧这一栏有没有变（几栏里最近在动的是哪一栏）
    private(set) var changedNow = false

    fileprivate func add(_ img: CGImage, _ g: Gray) -> Bool {
        frameCount += 1
        changedNow = false
        lastMove = nil
        lastSize = "\(img.width)x\(img.height)"
        guard let first, let prev = prevGray, img.width == first.width, img.height == first.height else {
            reset(img, g)
            return false
        }
        let prevFrame = prevImg
        prevGray = g
        prevImg = img
        let diff = Self.changes(prev, g, ignore: ignore)
        changedNow = diff.any
        guard diff.any else { if settled { lastMove = 0 }; outsideMoves = 0; return false }
        // 定下来的"顶上、底下不动的部分"整块在动：刚才认出来在滚的是页面里一块自己能滚的小框（指针一开始压在它上面），
        // 现在滚的是外面整个页面。照小框拼下去全是错的：从页面开始动之前那一帧重新开始（那时页面还在最上面，一点都不少；
        // 只是小框停在被滚过一点的样子）
        // 只在"不动的部分"占了画面三成以上时这样看：小框外面的页面一大片。页面底部只有零星一点东西被误当成"底下不动的那条"时
        // （两成左右），它跟着页面一起动不说明认错了，重新开始反而丢掉页面最上面那段
        if settled, restarts < 2, let pf = prevFrame, header + footer >= g.rows * 30 / 100 {
            let n = Self.cols
            var out = 0
            for r in Array(0..<header) + Array((g.rows - footer)..<g.rows) {
                for c in colLo...colHi where diff.mask[r * n + c] { out += 1; break }
            }
            if out * 2 >= header + footer {
                if outsideMoves == 0 { beforeOutside = (pf, prev) }
                outsideMoves += 1
                if outsideMoves >= 2, let (bi, bg) = beforeOutside {
                    restarts += 1
                    outsideMoves = 0
                    beforeOutside = nil
                    reset(bi, bg)
                    prevImg = bi
                    return add(img, g)
                }
            } else {
                outsideMoves = 0
            }
        }
        if !settled {
            motions += 1
            for c in 0..<Self.cols where diff.cols[c] { colChanged[c] += 1 }
            rowChangedMasks.append(diff.mask)
            pending.append((img, g))
            movedRows += diff.rows
            // 滚得够多了再定（每次只滚一点点的话，有的列碰巧没变，会被当成不动的侧栏）
            if motions >= 3 && (movedRows >= g.rows / 4 || motions >= 8) { trySettle(img, g) }
            return settled
        }
        return stitch(img, g)
    }

    private(set) var resets = 0, lastSize = ""
    /// 认错了在滚的地方、从头再来过几次（见 add）
    private(set) var restarts = 0
    private var prevImg: CGImage?
    private var outsideMoves = 0
    private var beforeOutside: (CGImage, Gray)?
    private func reset(_ img: CGImage, _ g: Gray) {
        resets += 1
        first = img
        last = img
        refGray = g
        prevGray = g
        firstGray = g
        header = 0; footer = 0; covered = 0; position = 0; motions = 0; movedRows = 0
        lastPosition = 0; committed = 0; lost = false; lastMove = nil
        deepest = img; deepestGray = g; maxPosition = 0
        colMis = [Double](repeating: 0, count: Self.cols); colMisN = 0
        colRange = [Int](repeating: 0, count: Self.cols)
        colLo = 0; colHi = Self.cols - 1; coreLo = 0; coreHi = Self.cols - 1
        colChanged = [Int](repeating: 0, count: Self.cols)
        rowChangedMasks = []
        strips = []; pending = []; settled = false; settleGray = nil; settleRange = nil; velocity = nil; prevVelocity = nil; framesSinceRef = 0; bounceChecked = nil; rejectRun = 0
    }

    /// 变了好几次：先看是不是真的在滚（变的那几列整体挪了几行）。
    /// 只是别的变化（鼠标划过侧栏时的高亮、提示、加载动画）、或者对不上（一开始就滚太快）：不定，接着看
    private func trySettle(_ img: CGImage, _ g: Gray) {
        guard let g0 = firstGray else { settle(); return }
        let n = Self.cols
        let changed = (0..<n).map { colChanged[$0] > 0 }
        guard changed.contains(true) else { settle(); return }
        // 变过的列里连成一片（中间空两列以内）、变过的列最多的那一段：别处零星变了一两列（另一栏的滚动条、分隔线旁边一闪的东西）
        // 不能把范围拉到那边去，不然算位移时把另一栏（滚的不一样）也算进来，永远对不上，这一栏一直定不下来
        var cMin = 0, cMax = 0, bestCount = -1
        var i0 = 0
        while i0 < n {
            guard changed[i0] else { i0 += 1; continue }
            var j = i0, cnt = 1, k = i0 + 1
            while k < n, k - j <= 3 { if changed[k] { j = k; cnt += 1 }; k += 1 }
            if cnt > bestCount { bestCount = cnt; cMin = i0; cMax = j }
            i0 = j + 1
        }
        colLo = cMin; colHi = cMax
        settleRange = cMin...cMax
        computeFixedRows(rows: g0.rows)
        let top = header, bottom = footer
        colLo = 0; colHi = n - 1; header = 0; footer = 0
        // 拿第一帧和存着的哪一帧比：最新那帧最好（挪得最多，最看得出是不是在滚）；一开始就滑得快的话，
        // 最新那帧和第一帧早就没有重叠了，往前找一帧还对得上的（以前一直拿最新那帧比，滑得快就永远定不下来，只剩第一帧）
        // 一样的卡片、一排排很像的行，隔得远的两帧可能挪错一整张卡片也"对得上"：先一帧接一帧算出每帧挪了多少、加起来，
        // 直接比出来的和加起来的一样才信它；都不一样就用第一帧和第一张存着的帧（挪得最少、最不会认错）
        var chain: [(Gray, Int)] = []
        var prevG = g0, total = 0
        for (_, pg) in pending {
            guard let v = Self.shift(prevG, pg, top: top, bottom: bottom, lo: cMin, hi: cMax) else { break }
            total += v
            chain.append((pg, total))
            prevG = pg
        }
        var g = g
        var sh: Int? = nil
        for (pg, tot) in chain.reversed() where abs(tot) >= 4 {
            if let v = Self.shift(g0, pg, top: top, bottom: bottom, lo: cMin, hi: cMax), abs(v - tot) <= 2 { g = pg; sh = v; break }
        }
        if sh == nil, let (pg, tot) = chain.first(where: { abs($0.1) >= 4 }) { g = pg; sh = tot }
        if sh == nil, chain.isEmpty { sh = Self.shift(g0, g, top: top, bottom: bottom, lo: cMin, hi: cMax) }
        settleGray = g
        // 真的在滚：变过的列里，大部分列都是"挪了以后对得上，不挪对不上"（每一列都跟着一起挪）。
        // 鼠标划过侧栏时一行行亮起来的高亮、提示、动画：只有一小块在变，挪了也只是碰巧像一点，大部分列不挪就对得上
        let scrolled = sh.map { v -> Bool in
            guard abs(v) >= 4 else { return false }
            var moving = 0, cols = 0
            for c in cMin...cMax where changed[c] {
                let a = Self.cost(g0, g, v, top: top, bottom: bottom, lo: c, hi: c)
                let b = Self.cost(g0, g, 0, top: top, bottom: bottom, lo: c, hi: c)
                // 整列一样（空白）的不算
                guard b > 0.5 else { continue }
                cols += 1
                if a * 3 < b { moving += 1 }
            }
            // 太窄的（只有一两列在动：滚动条、分隔线旁边一闪一闪的东西）不是能拼的一栏
            return moving >= Self.cols / 16 && moving * 10 >= cols * 6
        }
        if scrolled == true { settle(); return }
        settleGray = nil; settleRange = nil
        // 后来开的那几栏（看别的地方还有没有在滚）：之前看到的不是滚动（别处的滚动条、动画），拿现在这一帧重新开始看。
        // 第一帧要是一直留着，别的栏滚了好一阵后这一栏才开始滚，和第一帧早就对不上了
        if ignore != nil { reset(img, g); return }
        // 第一栏：之前看到的变化都不算，第一帧留着（从它开始拼，上面一点都不会少），接着看
        motions = 0; movedRows = 0; pending = []; rowChangedMasks = []
        colChanged = [Int](repeating: 0, count: n)
        if scrolled == nil { lost = true }
    }

    /// 看够了滚动：定下滚动的那一栏和顶上底下不动的部分，存着的帧按顺序接上
    private func settle() {
        guard !settled, let first, let g0 = firstGray else { settled = true; return }
        settled = true
        let n = Self.cols
        let changed = (0..<n).map { colChanged[$0] > 0 }
        guard let fMin = changed.firstIndex(of: true), let fMax = changed.lastIndex(of: true) else { return }
        // trySettle 挑好的那一段（别处零星变了的列不算进来）；没挑过才用全部变过的列
        let cMin = settleRange?.lowerBound ?? fMin, cMax = settleRange?.upperBound ?? fMax
        settleRange = nil
        // 第一遍：先按变过的列的范围算顶上、底下不动的行
        colLo = cMin; colHi = cMax
        computeFixedRows(rows: first.height)
        // 第二遍：每一列是不是跟着内容一起滚。拿第一帧和最后一帧，先用变过的列算出滚了几行（s），再看每一列：
        // 不挪的时候一样、挪 s 行就不一样 → 不动的东西（侧栏的字、分隔线）；别的（跟着滚的、或者整列一样的空白）都算这一栏的
        let r0 = header, r1 = first.height - footer
        var fixedCol = [Bool](repeating: false, count: n)
        var jitter = [Bool](repeating: false, count: n)
        // 这一列从上到下有多少不是底色（底色按变过的列里最多的那个灰度）：侧栏整列都是自己的底色、字；
        // 空白的列上只浮着一小块不动的东西（网址提示、输入框的一角）不算侧栏
        var hist0 = [Int](repeating: 0, count: 256)
        for r in stride(from: r0, to: r1, by: 2) { for c in 0..<n where changed[c] { hist0[Int(g0.px[r * n + c])] += 1 } }
        let bg0 = hist0.indices.max { hist0[$0] < hist0[$1] } ?? 255
        let solid: [Bool] = (0..<n).map { c in
            guard r1 > r0 else { return false }
            var off = 0
            for r in r0..<r1 where abs(Int(g0.px[r * n + c]) - bg0) > 6 { off += 1 }
            return off * 4 > r1 - r0
        }
        // 和第一帧比的那一帧：trySettle 挑好的（还和第一帧重叠的），没挑过就用最新那帧
        let ref = settleGray ?? pending.last?.1
        settleGray = nil
        let shDbg = ref.flatMap { Self.shift(g0, $0, top: header, bottom: footer, lo: cMin, hi: cMax) }
        debugShift = shDbg.map(String.init) ?? "nil"
        if let gl = ref, let sh = shDbg, sh > 4 {
            for c in 0..<n {
                var d0 = 0, ds = 0, cnt = 0
                var r = r0
                while r + sh < r1 {
                    let a0 = Int(g0.px[r * n + c])
                    d0 += abs(a0 - Int(gl.px[r * n + c]))
                    ds += abs(Int(g0.px[(r + sh) * n + c]) - Int(gl.px[r * n + c]))
                    cnt += 1
                    r += 1
                }
                guard cnt > 0 else { continue }
                let m0 = Double(d0) / Double(cnt), ms = Double(ds) / Double(cnt)
                fixedCol[c] = m0 < 1.5 && ms > 4 && solid[c]
                // 一直没动、底色和滚动那一栏不一样（侧栏、面板：鼠标停在上面时会变一点，所以"变过"）
                if m0 < 1.5 && abs(colMode(g0, c, r0, r1) - bg0) > 6 { fixedCol[c] = true }
                // 挪不挪都对不上：既不是跟着滚的内容，也不是不动的东西（滚的时候才出来的滚动条、跟着动画变的角标）
                jitter[c] = m0 > 3 && ms > 3
                // 挪了也不比不挪对得更好：这一列不是跟着内容滚的（侧栏里跟着页面段落移动的高亮条、自己在变的面板），
                // 不算这一栏。以前只去掉贴着边的几列，侧栏宽一点（十几列）就整个被算进来，之后侧栏不动、每帧都对不上
                if ms > 3 && ms >= m0 * 0.7 { fixedCol[c] = true }
            }
            // 贴着左右边的这种列（浮出来的滚动条）也当成不动的：不接进长图，用旁边的底色补
            let edge = max(2, n / 16)
            for c in 0..<edge { if jitter[c] || fixedCol[c] { fixedCol[c] = true } else { break } }
            for c in stride(from: n - 1, through: n - edge, by: -1) { if jitter[c] || fixedCol[c] { fixedCol[c] = true } else { break } }
        }
        // 没变过、底色和这一栏不一样的列（侧栏、面板的底色）也不算这一栏
        var hist = [Int](repeating: 0, count: 256)
        for r in stride(from: r0, to: r1, by: 2) { for c in 0..<n where changed[c] { hist[Int(g0.px[r * n + c])] += 1 } }
        let bg = hist.indices.max { hist[$0] < hist[$1] } ?? 255
        for c in 0..<n where !changed[c] && !fixedCol[c] && r1 > r0 {
            var off = 0
            for r in r0..<r1 where abs(Int(g0.px[r * n + c]) - bg) > 6 { off += 1 }
            if off * 2 > r1 - r0 { fixedCol[c] = true }
        }
        // 从上到下一个颜色的列（滚的那一栏两边的空白、渐变壁纸、竖的分隔线）：跟着滚和不动拼出来都一样，算进这一栏也不会错。
        // 不算进来的话，这一栏会被它们切断：靠边的内容（头像、行号）丢了，浮在上面横跨整栏的东西（输入框）两头露在外面，
        // 被当成不动的部分、照第一帧的样子留在长图中间
        let uniform: [Int?] = (0..<n).map { c in
            guard r1 - r0 > 8, let gl = ref else { return nil }
            // 九成的行都是同一个灰度（浮在下面的输入框、一闪而过的提示只占一小段）
            func mode(_ g: Gray) -> (Int, Bool) {
                var h = [Int](repeating: 0, count: 256)
                for r in r0..<r1 { h[Int(g.px[r * n + c])] += 1 }
                let m = h.indices.max { h[$0] < h[$1] } ?? 0
                let near = h[max(0, m - 4)...min(255, m + 4)].reduce(0, +)
                return (m, near * 100 >= (r1 - r0) * 88)
            }
            let a = mode(g0), b = mode(gl)
            return a.1 && b.1 && abs(a.0 - b.0) <= 3 ? a.0 : nil
        }
        if let ignore { for c in 0..<n where ignore[c] { fixedCol[c] = true } }
        let ok = (0..<n).map { !fixedCol[$0] }
        var best = (lo: cMin, hi: cMax, score: -1)
        var i = 0
        while i < n {
            guard ok[i] else { i += 1; continue }
            var j = i
            while j + 1 < n, ok[j + 1] { j += 1 }
            let score = (i...j).filter { changed[$0] }.count
            if score > best.score || (score == best.score && j - i > best.hi - best.lo) { best = (i, j, score) }
            i = j + 1
        }
        colLo = best.lo; colHi = best.hi
        // 往两边接着扩：一个颜色的空白列（和旁边空白的颜色差不多：同一块底色，到了另一块的分隔处就停），
        // 空白外面紧挨着的、算这一栏的列（靠边的头像、行号）也接上
        func grow(_ step: Int) {
            var c = (step < 0 ? colLo : colHi) + step
            var lastBlank: Int? = nil
            var reach = step < 0 ? colLo : colHi
            while c >= 0 && c < n, !(ignore?[c] ?? false), !jitter[c] {
                if let m = uniform[c] {
                    if let lb = lastBlank, abs(m - lb) > 6 { break }
                    lastBlank = m
                } else if fixedCol[c] {
                    break
                } else {
                    lastBlank = nil
                }
                reach = c
                c += step
            }
            // 最外面停在空白上就到空白为止（不算刚越过的分隔线）
            if step < 0 { colLo = reach } else { colHi = reach }
        }
        coreLo = colLo; coreHi = colHi
        grow(-1); grow(1)
        // 滚动那一栏两边贴着的、挪不挪都对不上的几列（滚的时候才浮出来的滚动条）：不接进长图，用旁边的底色补
        let trim = max(2, n / 16)
        var k = 0
        while k < trim, colHi - colLo > n / 12, jitter[colHi] { colHi -= 1; k += 1 }
        k = 0
        while k < trim, colHi - colLo > n / 12, jitter[colLo] { colLo += 1; k += 1 }
        // 太窄（不到十二分之一）多半是认错了：整块当成在滚（窄的侧栏、标签栏也能滚，所以不能卡太宽）
        if colHi - colLo < n / 12 { colLo = 0; colHi = n - 1 }
        computeFixedRows(rows: first.height)
        // 行也看"是不是跟着滚"：浮在内容上的输入框，两边露出来的内容在滚，按"变没变"会当成在动；
        // 但它本身不挪的时候一样、挪了就不一样 → 不动的。从下往上、从上往下把这种行都算进底下、顶上不动的部分
        if let gl = ref, let sh = Self.shift(g0, gl, top: header, bottom: footer, lo: colLo, hi: colHi), sh > 4 {
            let rows = first.height
            func fixedRow(_ r: Int, below: Bool) -> Bool {
                // 底下的行：第一帧的第 r 行和最后一帧的第 r - s 行比（内容往上挪了 s）；顶上的行：最后一帧的第 r 行和第一帧的第 r + s 行比
                let rs = below ? r - sh : r + sh
                guard rs >= 0, rs < rows else { return true }
                var d0 = 0, ds = 0
                for c in colLo...colHi {
                    let a = Int(g0.px[r * n + c]), b = Int(gl.px[r * n + c])
                    d0 += abs(a - b)
                    ds += below ? abs(Int(g0.px[r * n + c]) - Int(gl.px[rs * n + c])) : abs(Int(gl.px[r * n + c]) - Int(g0.px[rs * n + c]))
                }
                let w = Double(colHi - colLo + 1)
                // 不挪的时候一样、挪了就不一样：不动的东西。挪不挪都一样（空白）不算，空白在哪都一样，算进去只会让滚的那段变小
                return Double(d0) / w < 1.5 && Double(ds) / w > Double(d0) / w + 2
            }
            // 中间隔着几行在滚的也可以（输入框和窗口底边之间常露出一点内容），隔太多就停
            let maxFixed = rows * 4 / 10, gapAllowed = max(8, rows / 12)
            func extend(_ start: Int, _ row: (Int) -> Int, below: Bool) -> Int {
                var k = start, lastFixed = start, gap = 0
                while k < maxFixed {
                    if fixedRow(row(k), below: below) { k += 1; lastFixed = k; gap = 0 }
                    else { gap += 1; k += 1; if gap > gapAllowed { break } }
                }
                return lastFixed
            }
            footer = extend(footer, { rows - 1 - $0 }, below: true)
            header = extend(header, { $0 }, below: false)
        }
        rowChangedMasks = []
        chooseTakeLine()
        committed = mid
        let p = pending
        pending = []
        for (img, g) in p { _ = stitch(img, g) }
    }

    /// 这一列（r0..<r1 行）最多的那个灰度：它的底色
    private func colMode(_ g: Gray, _ c: Int, _ r0: Int, _ r1: Int) -> Int {
        var h = [Int](repeating: 0, count: 256)
        for r in r0..<r1 { h[Int(g.px[r * Self.cols + c])] += 1 }
        return h.indices.max { h[$0] < h[$1] } ?? 0
    }

    /// 滚动那段的中线（每一行从这里取）。指针停在中线附近时（自动滚动默认把指针放在选区中间）换一条线：
    /// 网页会把指针下面那一行高亮（表格行、链接），从指针那里取，长图里每一行都是高亮的
    private var mid: Int {
        let band = (first?.height ?? 0) - header - footer
        return max(0, min(band - 1, band / 2 + takeOffset))
    }
    private var takeOffset = 0
    /// 指针在哪一行（帧里的像素，原点在上面）：定下来时看一次，取行的线避开它
    var avoidRow: Int?
    private func chooseTakeLine() {
        takeOffset = 0
        guard let y = avoidRow, let first else { return }
        let band = first.height - header - footer
        let p = y - header, m = band / 2
        guard band > 200, abs(p - m) < band / 6 else { return }
        // 指针在中线上面就往下挪四分之一，在下面就往上挪
        takeOffset = p <= m ? band / 4 : -band / 4
    }

    /// 在现在这一栏里，从上、从下数哪几行在所有滚动里都没怎么变（变了的列不到变过的列的 15%）
    private func computeFixedRows(rows: Int) {
        let n = Self.cols
        // 按这一栏里变过的列算比例（内容只占左边一截、右边一大片空白时，空白的列永远不变，不能算进去）
        let span = max(1, (colLo...colHi).filter { colChanged[$0] > 0 }.count)
        var rowMoves = [Bool](repeating: false, count: rows)
        for m in rowChangedMasks {
            for r in 0..<rows where !rowMoves[r] {
                var c = 0
                for k in colLo...colHi where m[r * n + k] { c += 1 }
                if c * 100 >= span * 15 { rowMoves[r] = true }
            }
        }
        var top = 0
        while top < rows, !rowMoves[top] { top += 1 }
        var bottom = 0
        while bottom < rows - top, !rowMoves[rows - 1 - bottom] { bottom += 1 }
        let maxFixed = rows * 4 / 10
        header = min(top, maxFixed)
        footer = min(bottom, maxFixed)
    }

    /// 那一栏在图里的左右（像素）
    private func columnRange(_ w: Int) -> (Int, Int) {
        let x0 = Int((Double(colLo) / Double(Self.cols) * Double(w)).rounded(.down))
        let x1 = Int((Double(colHi + 1) / Double(Self.cols) * Double(w)).rounded(.up))
        return (max(0, x0), min(w, x1))
    }

    private func stitch(_ img: CGImage, _ g: Gray) -> Bool {
        framesSinceRef += 1
        // 手甩的惯性每帧按差不多一样的比例变慢：照最近两次的比例往下估（自动滚动比例是 1）
        let expect = velocity.map { v -> Int in
            let k = prevVelocity.map { p in p != 0 && (p > 0) == (v > 0) ? min(1.3, max(0.5, v / p)) : 1 } ?? 1
            var e = 0.0, x = v
            // 参照帧隔了很多帧（一直对不上）时 k 连乘会爆成无穷大，Int(无穷大) 会让整个程序崩掉：最多估 120 帧，结果夹在一个合理的范围里
            for _ in 0..<min(framesSinceRef, 120) { x *= k; e += x; if abs(e) > 1e7 { break } }
            return Int((e.isFinite ? max(-1e7, min(1e7, e)) : 0).rounded())
        }
        var forced: Int?
        // 连着好几帧哪都对不上、也不是原地变化：多半是页面重新排了版（表格各列挪了、字体换了），以后的帧都和参照那帧对不上了。
        // 照刚才的速度估这一帧挪了多少，拿它当新的参照接着拼（接缝那里可能差几行，但后面的内容不会丢）
        if rejectRun >= 4, let e = expect, e > 0, let f = first, e < (f.height - header - footer) * 3 / 4 { forced = e }
        // 整段对不上时只拿上半段再对一次：网页在画面下半截重新排了版（图片加载完撑开、"加载更多"插进来），下半截整个往下挪了，
        // 上下两半挪的不一样。接进长图的只是上半段（滚到中线以上的行），上半段对得上就能接；下半截等它滚上来再接
        // （以前整帧都不要，滚得慢时几乎每帧都赶上有图片撑开，一直对不上，被当成滚不动、截到一半就停了）
        let band0 = g.rows - header - footer
        guard let ref = refGray, let shift = forced ?? Self.shift(ref, g, top: header, bottom: footer, lo: colLo, hi: colHi, expect: expect)
                ?? (band0 > 200 ? Self.shift(ref, g, top: header, bottom: footer + band0 / 2, lo: colLo, hi: colHi, expect: expect) : nil) else {
            // 页面没挪，只是有一块原地变了（页面里一块自己能滚的小框被滚了、视频、动画）：拿这一帧当新的参照接着对。
            // 以前一直拿变之前那帧去对，之后页面再往下滚也永远对不上，后面的全丢了
            if let ref = refGray, Self.changedInPlace(ref, g, top: header, bottom: footer, lo: colLo, hi: colHi) {
                inPlaceChanges += 1
                rejectRun = 0
                refGray = g
                // 新的参照：估速度从它开始数帧，不然按很多帧累乘出一个偏大的位移、后面被强行接上
                framesSinceRef = 0
                last = img
                lost = false
                lastMove = 0
                return false
            }
            // 对不上（滚太快、内容整个变了）：这帧不要，还拿上一帧去对下一帧
            rejected += 1
            rejectRun += 1
            lost = true
            return false
        }
        rejectRun = 0
        lost = false
        lastMove = shift
        // 速度（每帧挪多少）：下一帧证据少时拿来估。没动的帧不更新 ref，所以按隔了几帧算
        if shift != 0 { prevVelocity = velocity; velocity = Double(shift) / Double(framesSinceRef) }
        guard shift != 0 else {
            // 停在最深的地方不动了：拿这一帧当最深那帧（最下面那截、底下不动的那条从它取）。
            // 刚滚到底那一刻系统的滚动条还浮着，停一会儿就淡出去了；以前一直用刚滚到底那一帧，长图底下总带着一截滚动条
            if position == maxPosition { deepest = img; deepestGray = g }
            // 滚到底时拉过头又弹回来（停的地方比最深那次浅一点）：最深那帧在停的地方以下要是全是露出来的空白，
            // 真正的底就是停的这里，改用这一帧（往回滚过、下面还有内容的不算）。每个停的位置只看一次（要算整栏的颜色，不便宜）
            else if position < maxPosition, position != bounceChecked, maxPosition - position < (first?.height ?? 0) / 3 {
                bounceChecked = position
                if let f = first, contentEnd() <= position + f.height - header - footer {
                    maxPosition = position; deepest = img; deepestGray = g
                }
            }
            return false
        }
        framesSinceRef = 0
        noteMismatch(ref, g, shift)
        let prev = last ?? img, prevPos = position
        last = img
        refGray = g
        lastPosition = position
        position += shift
        if position > maxPosition {
            maxPosition = position
            deepest = img
            deepestGray = g
        }
        // 内容滚到中线以上的行接上：这一帧看得到的从这一帧取（正好在中间），滚太快、这一帧已经看不到的从上一帧取
        let target = position + mid
        guard target > committed else { return false }
        let (x0, x1) = columnRange(img.width)
        let band = img.height - header - footer
        func take(_ from: CGImage, framePos: Int, _ a: Int, _ b: Int) {
            // 只取这一帧滚动那段里看得到的
            let y0 = max(a, framePos), y1 = min(b, framePos + band)
            guard y1 > y0, let s = from.cropping(to: CGRect(x: x0, y: header + y0 - framePos, width: x1 - x0, height: y1 - y0)) else { return }
            // 拷成自己的一小块：直接裁出来的还连着整帧的像素，几百帧下来会占好几 GB 内存
            strips.append((y0, Self.copy(s) ?? s))
        }
        if committed < position { take(prev, framePos: prevPos, committed, position) }
        take(img, framePos: position, max(committed, position), target)
        covered += target - committed
        committed = target
        return true
    }

    private func noteMismatch(_ a: Gray, _ b: Gray, _ s: Int) {
        let n = Self.cols, band = a.rows - header - footer, overlap = band - abs(s)
        guard overlap > 8 else { return }
        let ao = header + max(s, 0), bo = header + max(-s, 0)
        for c in colLo...colHi {
            var d = 0
            for r in 0..<overlap { d += abs(Int(a.px[(ao + r) * n + c]) - Int(b.px[(bo + r) * n + c])) }
            colMis[c] += Double(d) / Double(overlap)
            var lo = 255, hi = 0
            for r in header..<(b.rows - footer) { let v = Int(b.px[r * n + c]); lo = min(lo, v); hi = max(hi, v) }
            colRange[c] = max(colRange[c], hi - lo)
        }
        colMisN += 1
    }

    /// 接进长图的那几列（在 128 列里）：滚动那一栏，去掉两边贴着的、对齐了也对不上的列（浮出来的滚动条）
    private func stripCols() -> (Int, Int) {
        var lo = colLo, hi = colHi
        guard colMisN > 0 else { return (lo, hi) }
        let trim = max(2, Self.cols / 16)
        func bad(_ c: Int) -> Bool { colMis[c] / Double(colMisN) > 2.5 }
        // 滚动条和这一栏的边之间常隔着一两列空白（一直是一个颜色）：隔着空白也去掉，空白用底色补，什么都不会少
        func blank(_ c: Int) -> Bool { colRange[c] <= 8 }
        func cut(from edge: Int, step: Int) -> Int {
            var c = edge, innermost: Int?
            for _ in 0..<trim {
                guard c >= lo, c <= hi, abs(hi - lo) > Self.cols / 12 else { break }
                if bad(c) { innermost = c } else if !blank(c) { break }
                c += step
            }
            return innermost.map { $0 + step } ?? edge
        }
        hi = cut(from: hi, step: -1)
        lo = cut(from: lo, step: 1)
        return (lo, hi)
    }

    /// 内容到第几行为止（不含）：滚到最下面那一帧看得到的最后一行。
    /// 回弹过（最后停的地方比最下面那次高，之后一直没再往下）：最后停的地方再往下、整行都是底色的那一截是露出来的空白，去掉
    /// （只去最下面连着的空白行，有一点东西就停：内容不会少）
    private func contentEnd() -> Int {
        guard let first, let deep = deepest else { return committed }
        let band = first.height - header - footer
        let end = maxPosition + band
        let back = maxPosition - position
        // 停在最下面那次的上面（弹回来了）才去：一直停在最下面的话，下面那截空白是真的页面底
        // "底下不动的那条"其实也在跟着滚（页面底部是大片空白、只有一点点东西，被当成了不动的）：拉过头露出来的空白在它里面，
        // 不在滚动那段里。这时内容只接到弹回来停住的地方（见 bouncedWithMovingFooter）
        if bouncedWithMovingFooter() { return position + band }
        guard back > 0, let (x0, x1) = Optional(columnRange(first.width)),
              let p = Self.plane(deep, CGRect(x: x0, y: header, width: x1 - x0, height: band)) else { return end }
        // 每列按自己的底色看（花纹壁纸上的细线不算东西）：从最下面往上，干净的行都是拉过头露出来的
        let clean = Self.cleanRows(p)
        var e = end
        while e > position + band {
            let r = e - 1 - maxPosition
            guard r >= 0, r < band, clean[r] else { break }
            e -= 1
        }
        return e
    }

    /// 滚到最下面那帧和最后一帧的"底下不动的那条"不一样：那条其实在跟着滚
    private func footerMoves() -> Bool {
        guard footer > 0, let d = deepestGray, let l = prevGray, d.rows == l.rows else { return false }
        let n = Self.cols
        // 有一列差得多就算（那条里只有零星一点东西时，平均下来几乎是 0）
        for c in colLo...colHi {
            var diff = 0
            for r in (d.rows - footer)..<d.rows { diff += abs(Int(d.px[r * n + c]) - Int(l.px[r * n + c])) }
            if Double(diff) / Double(footer) > 6 { return true }
        }
        return false
    }
    /// 到底时拉过头又弹回来，而"底下不动的那条"其实在跟着滚：拉过头露出来的空白一部分在那条里。
    /// 这时弹回来停住的那帧就是真的底：内容接到它滚动那段的最下面，底下那条也从它取（滚到最下面那帧的那条里有露出来的空白）。
    /// 只在拉过头的那一截在滚到最下面那帧里大部分是空白时才这样（不是回弹、是往回滚了的不算）
    private func bouncedWithMovingFooter() -> Bool {
        guard let first, let deep = deepest, maxPosition > position, footerMoves() else { return false }
        let back = maxPosition - position
        guard back < first.height / 3 else { return false }
        let (x0, x1) = columnRange(first.width)
        let corner = Self.cornerRows(deep, x0: x0, x1: x1)
        let h = min(back, first.height - header - corner)
        guard h > 0, let p = Self.plane(deep, CGRect(x: x0, y: first.height - corner - h, width: x1 - x0, height: h)) else { return false }
        let clean = Self.cleanRows(p)
        return clean.filter { $0 }.count * 10 >= h * 7
    }

    /// 拼好的整张图：滚动那一栏的宽度。顶上（第一帧）+ 一节节接上的 + 底下（最后一帧）。
    /// preview：拼的时候给预览用——还没看够滚动时不能定下来（定早了会把整块当成在滚），先给第一帧
    func image(preview: Bool = false) -> CGImage? {
        if preview && !settled { contentBottom = (first?.height ?? 0); return first }
        settle()
        guard let first else { return nil }
        // 还没滚过：就是第一帧
        guard maxPosition > 0, let deep = deepest else { contentBottom = first.height - footer; return first }
        let W = first.width, Hf = first.height
        let (x0, x1) = columnRange(W)
        let (sl, sh) = stripCols()
        let sx0 = max(x0, Int((Double(sl) / Double(Self.cols) * Double(W)).rounded(.down)))
        let sx1 = min(x1, Int((Double(sh + 1) / Double(Self.cols) * Double(W)).rounded(.up)))
        // 顶上：第一帧到中线（整个宽度）；中间：一节节（滚动那一栏）；
        // 再往下：最下面那一帧从接到的地方到内容的最后（整个宽度）；最底下不动的那条（输入框、底栏）：最后一帧的
        let topH = header + mid
        // 预览（拼的时候每 0.3 秒一次）不做费时的细活（去回弹空白、找侧栏切开的地方）：主线程要接着截图
        let end = preview ? maxPosition + Hf - header - footer : contentEnd()
        let cut = min(committed, end)
        var parts: [(top: Int, img: CGImage)] = []
        var y = topH
        for p in strips where p.row < cut {
            let h = min(p.img.height, cut - p.row)
            guard h > 0, let im = h == p.img.height ? p.img : p.img.cropping(to: CGRect(x: 0, y: 0, width: p.img.width, height: h)) else { continue }
            parts.append((y, im))
            y += h
        }
        let midH = y - topH
        let tailRows = max(0, end - committed)
        let tailY = header + committed - maxPosition
        let restBottom = !preview && bouncedWithMovingFooter()
        let H = topH + midH + tailRows + footer
        contentBottom = topH + midH + tailRows
        let cs = first.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // CGContext 原点在左下：y 从上往下数要翻过来
        func put(_ img: CGImage?, x: Int, top: Int, w: Int? = nil, h: Int? = nil) {
            guard let img else { return }
            let ww = w ?? img.width, hh = h ?? img.height
            ctx.draw(img, in: CGRect(x: x, y: H - top - hh, width: ww, height: hh))
        }
        put(first.cropping(to: CGRect(x: 0, y: 0, width: W, height: topH)), x: 0, top: 0)
        for p in parts {
            put(p.img.cropping(to: CGRect(x: sx0 - x0, y: 0, width: sx1 - sx0, height: p.img.height)), x: sx0, top: p.top)
        }
        if tailRows > 0 { put(deep.cropping(to: CGRect(x: 0, y: tailY, width: W, height: tailRows)), x: 0, top: y) }
        // 底下不动的那条也从滚到最下面那一帧取：和上面接着的那截是同一帧，接缝一定对得上
        // （"不动"的判断会把不动的壁纸也算进去，那条里可能有滚到一半的气泡；回弹后的最后一帧里它们位置不一样，会重复半截）
        if footer > 0 && restBottom, let rest = last {
            // 回弹：底下那条从弹回来停住的那帧取（和接到的内容是同一帧的接续）
            put(rest.cropping(to: CGRect(x: 0, y: Hf - footer, width: W, height: footer)), x: 0, top: y + tailRows)
        } else if footer > 0 { put(deep.cropping(to: CGRect(x: 0, y: Hf - footer, width: W, height: footer)), x: 0, top: y + tailRows) }
        // 不动的侧栏、面板（没在滚的那几列）：按底色分成几段，每段整块照原样放（上面一点都不切开），
        // 在它最底下那块东西上面的空白里切开，中间接长的那段用每列自己的底色补，底下那块放在最下面。像窗口被拉高了
        let gap = H - Hf
        if gap > 0 && preview {
            ctx.interpolationQuality = .none
            for (a, b) in [(0, sx0), (sx1, W)] where b > a {
                put(first.cropping(to: CGRect(x: a, y: 0, width: b - a, height: Hf)), x: a, top: 0)
                put(first.cropping(to: CGRect(x: a, y: Hf - 1, width: b - a, height: 1)), x: a, top: Hf, w: b - a, h: gap)
            }
        } else if gap > 0 {
            ctx.interpolationQuality = .none
            for (a, b) in [(0, sx0), (sx1, W)] where b > a {
                // 按底色分段（每段各自的底色算"干净"），但切开的那一行几段一起定：横着整条都不碰到东西
                let parts = Self.segments(deep, x0: a, x1: b)
                let together = Self.sideSplit(deep, parts)
                // 整块侧边一起算背景（按段算的话，聊天里一整列气泡会自成一段、"底色"是白的）
                let backdrop = Self.backdropRow(first, x0: a, x1: b, y1: Hf - Self.cornerRows(deep, x0: a, x1: b))
                for (s0, s1) in parts {
                    // 一起切不了（左边是一行行列表、一直排到底）：每段自己看（最左边那条窄栏底下的头像也能挪到最下面）
                    var split = together < Hf ? together : Self.sideSplit(deep, [(s0, s1)])
                    // 窗口的圆角（最底下几行里有透明的点）总要放在最下面：不然没挪的时候圆角留在图中间，侧边缺一个小口
                    split = min(split, Hf - Self.cornerRows(deep, x0: s0, x1: s1))
                    // 最底下那块被窗口底边切掉了一截（一直排到底的网页、列表），又不是一条自己颜色的底栏：它不是贴在底下的东西，
                    // 放到长图最下面会多出半截内容。改成从它上面切开，下面整段用底色补到底（像窗口被拉高、那里本来就空着）
                    let corner = Self.cornerRows(deep, x0: s0, x1: s1)
                    // 没找到能切的地方（最底下那块碰到了窗口底边）：在它上面最近的一条空白切开
                    if split >= Hf - corner, let g = Self.gapAboveBottom(deep, x0: s0, x1: s1, corner: corner) { split = g }
                    // 连空白都找不到（一直排到底的列表）也算被切掉的：整段照原样放到底边，下面补背景
                    let cutOff = split >= Hf - corner || Self.cutAtBottom(deep, x0: s0, x1: s1, split: split, corner: corner)
                    if cutOff { split = min(split, Hf - corner) }
                    if split > 0 { put(first.cropping(to: CGRect(x: s0, y: 0, width: s1 - s0, height: split)), x: s0, top: 0) }
                    // 拿切开的地方上面 160 行里每列最常见的颜色拉长（侧栏、面板的底色照原样，竖的分隔线接着往下）。
                    // 不能只拿切开那一行：几栏一起切的那一行可能正好穿过某一栏的卡片，拉出来一整条白
                    if cutOff {
                        put(backdrop?.cropping(to: CGRect(x: s0 - a, y: 0, width: s1 - s0, height: 1)), x: s0, top: split, w: s1 - s0, h: H - split)
                        continue
                    }
                    let fill = Self.modeRow(first, x0: s0, x1: s1, y0: split - 160, y1: split)
                    put(fill, x: s0, top: split, w: s1 - s0, h: gap)
                    if split < Hf { put(deep.cropping(to: CGRect(x: s0, y: split, width: s1 - s0, height: Hf - split)), x: s0, top: split + gap) }
                }
            }
        }
        return ctx.makeImage()
    }

    /// 一块图的颜色（全分辨率，RGBA，第 0 行是最上面）。用颜色不用灰度：浅绿的气泡和米色的壁纸灰度几乎一样
    fileprivate struct Plane {
        let w: Int, h: Int
        var px: [UInt8]
        func dist(_ x: Int, _ y: Int, _ c: (Int, Int, Int)) -> Int {
            let o = (y * w + x) * 4
            return max(abs(Int(px[o]) - c.0), abs(Int(px[o + 1]) - c.1), abs(Int(px[o + 2]) - c.2))
        }
        /// 每一列最常见的颜色（rows 里，默认全部）
        func columnModes(rows: [Int]? = nil) -> [(Int, Int, Int)] {
            let ys = rows ?? Array(stride(from: 0, to: h, by: 2))
            var count = [Int: (n: Int, r: Int, g: Int, b: Int)]()
            return (0..<w).map { x in
                count.removeAll(keepingCapacity: true)
                for y in ys {
                    let o = (y * w + x) * 4
                    let r = Int(px[o]), g = Int(px[o + 1]), b = Int(px[o + 2])
                    let k = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
                    let e = count[k] ?? (0, 0, 0, 0)
                    count[k] = (e.n + 1, e.r + r, e.g + g, e.b + b)
                }
                guard let m = count.values.max(by: { $0.n < $1.n }), m.n > 0 else { return (255, 255, 255) }
                return (m.r / m.n, m.g / m.n, m.b / m.n)
            }
        }
    }
    fileprivate static func plane(_ img: CGImage, _ r: CGRect) -> Plane? {
        guard r.width >= 1, r.height >= 1, let band = img.cropping(to: r) else { return nil }
        var p = Plane(w: band.width, h: band.height, px: [UInt8](repeating: 0, count: band.width * band.height * 4))
        let cs = img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let ok = p.px.withUnsafeMutableBytes { buf -> Bool in
            guard let c = CGContext(data: buf.baseAddress, width: p.w, height: p.h, bitsPerComponent: 8, bytesPerRow: p.w * 4,
                                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            c.draw(band, in: CGRect(x: 0, y: 0, width: p.w, height: p.h))
            return true
        }
        return ok ? p : nil
    }

    /// 每一行是不是"干净"（几乎都是底色）。底色：这一块里最多的那个颜色（壁纸、列表的底色）；
    /// 一列从上到下九成都是同一个颜色的话（竖的分隔线、边框），那个颜色在这一列也算底色。
    /// （不能每列各用各的：一列里气泡比壁纸多的时候，气泡的白色会被当成底色，输入框就"看不见"了）
    /// 花纹壁纸的细线会让每行都有一些点不一样，按这一块里最干净的那些行来算多少算"一点点"
    fileprivate static func cleanRows(_ p: Plane) -> [Bool] {
        guard p.w > 0, p.h > 0 else { return [] }
        typealias Acc = (n: Int, r: Int, g: Int, b: Int)
        func key(_ o: Int) -> Int { (Int(p.px[o]) >> 3) << 10 | (Int(p.px[o + 1]) >> 3) << 5 | (Int(p.px[o + 2]) >> 3) }
        var all = [Int: Acc]()
        var colBest: [(c: (Int, Int, Int), share: Double)] = []
        var count = [Int: Acc]()
        for x in 0..<p.w {
            count.removeAll(keepingCapacity: true)
            var n = 0
            for y in stride(from: 0, to: p.h, by: 2) {
                let o = (y * p.w + x) * 4, k = key(o)
                let r = Int(p.px[o]), g = Int(p.px[o + 1]), b = Int(p.px[o + 2])
                let e = count[k] ?? (0, 0, 0, 0); count[k] = (e.n + 1, e.r + r, e.g + g, e.b + b)
                let a = all[k] ?? (0, 0, 0, 0); all[k] = (a.n + 1, a.r + r, a.g + g, a.b + b)
                n += 1
            }
            let m = count.values.max { $0.n < $1.n } ?? (1, 255, 255, 255)
            colBest.append(((m.r / max(1, m.n), m.g / max(1, m.n), m.b / max(1, m.n)), Double(m.n) / Double(max(1, n))))
        }
        let a = all.values.max { $0.n < $1.n } ?? (1, 255, 255, 255)
        let bg = (a.r / max(1, a.n), a.g / max(1, a.n), a.b / max(1, a.n))
        let off: [Double] = (0..<p.h).map { y in
            var n = 0
            for x in 0..<p.w where p.dist(x, y, bg) > 10 && !(colBest[x].share >= 0.9 && p.dist(x, y, colBest[x].c) <= 10) { n += 1 }
            return Double(n) / Double(p.w)
        }
        let floor = off.sorted()[off.count / 5]
        return off.map { $0 <= floor + max(0.04, floor * 0.5) }
    }

    fileprivate static func bottomBlockSplit(_ cleanIn: [Bool]) -> Int {
        let H = cleanIn.count
        var clean = cleanIn
        // 一两行的小缝、一两行的小东西（花纹的细线）不算：抹平
        var r = 0
        while r < H {
            var e = r
            while e < H, clean[e] == clean[r] { e += 1 }
            if e - r <= 3, r > 0, e < H { for k in r..<e { clean[k] = !clean[k] } }
            r = e
        }
        var runs: [(clean: Bool, top: Int, bottom: Int)] = []
        r = H - 1
        while r >= 0 {
            let c = clean[r], b = r
            while r >= 0, clean[r] == c { r -= 1 }
            runs.append((c, r + 1, b))
        }
        let gaps = runs.filter(\.clean).map { $0.bottom - $0.top + 1 }.sorted()
        let typical = gaps.isEmpty ? 0 : gaps[gaps.count / 2]
        var k = 0
        // 贴着窗口底边很矮的几截（窗口的圆角、边框、下面露出的一点点）：当成底边，跳过
        while k < runs.count, H - runs[k].top < H / 40 { k += 1 }
        if k < runs.count, runs[k].clean { k += 1 }
        // 最底下那块东西贴着窗口底边（被切到一半）：不挪
        guard k > 0, k + 1 < runs.count else { return H }
        // 最底下那块东西常常是好几行（主题开关、头像、名字、邮箱、版本号），中间隔着行距那么大的小缝：
        // 不能在第一条缝就切（只挪走最后一行），往上看到底下那块总高不超过 H/6 为止，在其中最宽的那条空白里切。
        // 空白至少 40 像素（20pt）：网页正文两行之间的行距也有 20 多像素，不能把一段话的最后两行挪到最下面
        let blockBottom = runs[k].bottom
        var best: (top: Int, bottom: Int)? = nil
        var i = k + 1
        while i < runs.count, blockBottom - runs[i - 1].top < H / 6 {
            let g = runs[i]
            if g.clean, i + 1 < runs.count, g.bottom - g.top + 1 > max(40, typical),
               best.map({ g.bottom - g.top > $0.bottom - $0.top }) ?? true { best = (g.top, g.bottom) }
            i += 1
        }
        guard let g = best else { return H }
        return (g.top + g.bottom + 1) / 2
    }

    /// 最底下有几行带透明的点（窗口的圆角），最多 40 行
    fileprivate static func cornerRows(_ img: CGImage, x0: Int, x1: Int) -> Int {
        let h = min(40, img.height)
        guard x1 > x0, let p = plane(img, CGRect(x: x0, y: img.height - h, width: x1 - x0, height: h)) else { return 0 }
        var n = 0
        for y in stride(from: h - 1, through: 0, by: -1) {
            var clear = false
            for x in 0..<p.w where p.px[(y * p.w + x) * 4 + 3] < 255 { clear = true; break }
            if !clear { break }
            n += 1
        }
        return n
    }

    /// 最底下那块（碰到窗口底边的）上面最近的一条空白（至少 12 行）的中间，只在下半截里找；找不到 nil
    fileprivate static func gapAboveBottom(_ img: CGImage, x0: Int, x1: Int, corner: Int) -> Int? {
        let bottom = img.height - corner
        guard let p = plane(img, CGRect(x: x0, y: 0, width: x1 - x0, height: bottom)) else { return nil }
        var clean = cleanRows(p)
        // 一两行的小缝、小东西不算
        var r = 0
        while r < bottom {
            var e = r
            while e < bottom, clean[e] == clean[r] { e += 1 }
            if e - r <= 3, r > 0, e < bottom { for k in r..<e { clean[k] = !clean[k] } }
            r = e
        }
        var y = bottom - 1
        while y >= bottom / 2, clean[y] { y -= 1 }      // 底边上的空白（没有的话直接是那块东西）
        while y >= bottom / 2, !clean[y] { y -= 1 }     // 那块东西
        let gb = y
        while y >= bottom / 2, clean[y] { y -= 1 }
        guard gb - y >= 12 else { return nil }
        return (y + 1 + gb + 1) / 2
    }

    /// 一段不动的侧边：切开的地方往下那块一直碰到窗口底边（圆角上面几行还有东西：被切掉了一截），
    /// 而且那块的主色就是这一段的底色（不是一条自己颜色的底栏、状态栏）
    fileprivate static func cutAtBottom(_ img: CGImage, x0: Int, x1: Int, split: Int, corner: Int) -> Bool {
        let bottom = img.height - corner
        guard bottom - split >= 6, let p = plane(img, CGRect(x: x0, y: 0, width: x1 - x0, height: bottom)) else { return false }
        let clean = cleanRows(p)
        // 底边上面那几行都干净：最底下那块上下都留着空，是贴在底下的东西（按钮、头像），照原来的放
        guard ((bottom - 4)..<bottom).contains(where: { !clean[$0] }) else { return false }
        func dominant(_ y0: Int, _ y1: Int) -> ((Int, Int, Int), Double) {
            var count = [Int: (n: Int, r: Int, g: Int, b: Int)]()
            var total = 0
            for y in stride(from: max(0, y0), to: y1, by: 2) {
                for x in stride(from: 0, to: p.w, by: 2) {
                    let o = (y * p.w + x) * 4
                    let r = Int(p.px[o]), g = Int(p.px[o + 1]), b = Int(p.px[o + 2])
                    let k = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
                    let e = count[k] ?? (0, 0, 0, 0)
                    count[k] = (e.n + 1, e.r + r, e.g + g, e.b + b)
                    total += 1
                }
            }
            guard let m = count.values.max(by: { $0.n < $1.n }), m.n > 0 else { return ((255, 255, 255), 0) }
            return ((m.r / m.n, m.g / m.n, m.b / m.n), Double(m.n) / Double(max(1, total)))
        }
        let above = dominant(split - 400, split), below = dominant(split, bottom)
        let d = max(abs(above.0.0 - below.0.0), abs(above.0.1 - below.0.1), abs(above.0.2 - below.0.2))
        // 下面那块大部分是另一个颜色：一条底栏
        if d > 12 && below.1 > 0.5 { return false }
        return true
    }

    /// 这几段一起：每一行在每一段里都只有底色才算干净（这样切开的那一行横着整条都不会碰到东西：输入框横跨好几段也不会被切开）
    fileprivate static func sideSplit(_ img: CGImage, _ segs: [(Int, Int)]) -> Int {
        let H = img.height
        var all = [Bool](repeating: true, count: H)
        for (a, b) in segs {
            guard let p = plane(img, CGRect(x: a, y: 0, width: b - a, height: H)) else { return H }
            let c = cleanRows(p)
            for y in 0..<H where !c[y] { all[y] = false }
        }
        return bottomBlockSplit(all)
    }

    /// 按底色把一块分成几段（侧栏、列表、壁纸各一段）：每段各自找切开的地方。
    /// 每列的底色用干净的行里最多的颜色；相邻的列底色差不多就是同一段；太窄的段（一条分隔线、一列花纹）并进旁边
    fileprivate static func segments(_ img: CGImage, x0: Int, x1: Int) -> [(Int, Int)] {
        guard x1 > x0, let p = plane(img, CGRect(x: x0, y: 0, width: x1 - x0, height: img.height)) else { return [] }
        let clean = cleanRows(p)
        let rows = clean.indices.filter { clean[$0] }
        let mode = p.columnModes(rows: rows.count >= 8 ? rows : nil)
        func far(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Bool { max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2)) > 6 }
        var segs: [(lo: Int, hi: Int, v: (Int, Int, Int))] = []
        for x in 0..<p.w {
            if let last = segs.last, !far(last.v, mode[x]) { segs[segs.count - 1].hi = x + 1 }
            else { segs.append((x, x + 1, mode[x])) }
        }
        let minW = max(24, p.w / 20)
        var merged: [(lo: Int, hi: Int, v: (Int, Int, Int))] = []
        for sg in segs {
            if let last = merged.last, sg.hi - sg.lo < minW || last.hi - last.lo < minW {
                merged[merged.count - 1].hi = sg.hi
                if sg.hi - sg.lo > last.hi - last.lo { merged[merged.count - 1].v = sg.v }
            } else { merged.append(sg) }
        }
        return merged.map { (x0 + $0.lo, x0 + $0.hi) }
    }

    /// 一行：每一列的底色。拉长它来补：侧栏、列表的底色照原样，竖的分隔线接着往下，花纹壁纸变成它的底色（拉一行花纹会变成一条条竖线）。
    /// 每一列看 y0..<y1 里干净的行（整列按全高算的底色：没有字、气泡）里最常见的颜色；要占到七成才算这一列自己的（一条竖线、边框），
    /// 不到七成（花纹）就用整块最常见的颜色（底色）
    /// exact：y0..<y1 这几行就是底色（切开的地方挑在空白里，上下几行都是空白），直接用它们，不再按"干净"挑。
    /// 不这样的话，卡片多的一栏里最常见的颜色是卡片的浅灰，补出来的那一大块像一张空卡片，不像背景
    fileprivate static func modeRow(_ img: CGImage, x0: Int, x1: Int, y0: Int, y1: Int, exact: Bool = false) -> CGImage? {
        let y0 = max(0, y0), y1 = min(img.height, y1)
        guard x1 > x0, y1 > y0, let p = plane(img, CGRect(x: x0, y: 0, width: x1 - x0, height: img.height)) else { return nil }
        var rows: [Int]
        if exact {
            rows = Array(y0..<y1)
        } else {
            let clean = cleanRows(p)
            rows = (y0..<y1).filter { clean[$0] }
            if rows.count < 4 { rows = clean.indices.filter { clean[$0] } }
            if rows.isEmpty { rows = Array(y0..<y1) }
        }
        typealias Acc = (n: Int, r: Int, g: Int, b: Int)
        var all = [Int: Acc]()
        var cols: [Acc] = []
        for x in 0..<p.w {
            var count = [Int: Acc]()
            for y in rows {
                let o = (y * p.w + x) * 4
                let r = Int(p.px[o]), g = Int(p.px[o + 1]), b = Int(p.px[o + 2])
                let k = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
                let e = count[k] ?? (0, 0, 0, 0)
                count[k] = (e.n + 1, e.r + r, e.g + g, e.b + b)
                let a = all[k] ?? (0, 0, 0, 0)
                all[k] = (a.n + 1, a.r + r, a.g + g, a.b + b)
            }
            cols.append(count.values.max { $0.n < $1.n } ?? (0, 0, 0, 0))
        }
        let bg = all.values.max { $0.n < $1.n } ?? (1, 255, 255, 255)
        var row = [UInt8](repeating: 255, count: p.w * 4)
        var blurred = [(Double, Double, Double)?](repeating: nil, count: p.w)
        for x in 0..<p.w {
            if cols[x].n * 10 >= rows.count * 7 {
                let n = max(1, cols[x].n)
                row[x * 4] = UInt8(cols[x].r / n); row[x * 4 + 1] = UInt8(cols[x].g / n); row[x * 4 + 2] = UInt8(cols[x].b / n)
                continue
            }
            // 没有占七成的颜色：这一列上下差得不多（侧栏边上的渐变、阴影）就用它自己的中间值；
            // 差得多（花纹壁纸）才用整块的底色，不然拉长后会变成一条条竖线（以前一律用整块的底色，侧栏边上会缺一小块，接缝处像个台阶）
            var rs: [Int] = [], gs: [Int] = [], bs: [Int] = []
            for y in rows { let o = (y * p.w + x) * 4; rs.append(Int(p.px[o])); gs.append(Int(p.px[o + 1])); bs.append(Int(p.px[o + 2])) }
            let spread = max(rs.max()! - rs.min()!, gs.max()! - gs.min()!, bs.max()! - bs.min()!)
            if spread <= 24 {
                rs.sort(); gs.sort(); bs.sort()
                let m = rs.count / 2
                row[x * 4] = UInt8(rs[m]); row[x * 4 + 1] = UInt8(gs[m]); row[x * 4 + 2] = UInt8(bs[m])
            } else {
                // 花纹、照片、满是头像的列表：这一列每行都不一样，拉长一行会变成一条条竖线。
                // 以前一律用整块最常见的颜色，整块是照片时补出来一大块纯白或纯黑。
                // 现在用这一列的平均色，再和旁边同样情况的列一起横着抹平（下面）：补出来的是和周围差不多的柔和底色
                // 整块大半是一个底色（网页的白底上一张照片、一个缩略图）：这一列用底色，不然照片的颜色会拉成一条竖的色带
                if bg.n * 2 >= rows.count * p.w {
                    let n = max(1, bg.n)
                    row[x * 4] = UInt8(bg.r / n); row[x * 4 + 1] = UInt8(bg.g / n); row[x * 4 + 2] = UInt8(bg.b / n)
                    continue
                }
                var sr = 0, sg = 0, sb = 0
                for i in 0..<rs.count { sr += rs[i]; sg += gs[i]; sb += bs[i] }
                let c = max(1, rs.count)
                blurred[x] = (Double(sr) / Double(c), Double(sg) / Double(c), Double(sb) / Double(c))
            }
        }
        if blurred.contains(where: { $0 != nil }) {
            let r = 48
            var pc = [Int](repeating: 0, count: p.w + 1)
            var pr = [Double](repeating: 0, count: p.w + 1), pg = pr, pb = pr
            for x in 0..<p.w {
                pc[x + 1] = pc[x] + (blurred[x] == nil ? 0 : 1)
                pr[x + 1] = pr[x] + (blurred[x]?.0 ?? 0); pg[x + 1] = pg[x] + (blurred[x]?.1 ?? 0); pb[x + 1] = pb[x] + (blurred[x]?.2 ?? 0)
            }
            for x in 0..<p.w where blurred[x] != nil {
                let lo = max(0, x - r), hi = min(p.w, x + r + 1)
                let cnt = Double(max(1, pc[hi] - pc[lo]))
                row[x * 4] = UInt8(max(0, min(255, (pr[hi] - pr[lo]) / cnt)))
                row[x * 4 + 1] = UInt8(max(0, min(255, (pg[hi] - pg[lo]) / cnt)))
                row[x * 4 + 2] = UInt8(max(0, min(255, (pb[hi] - pb[lo]) / cnt)))
            }
        }
        let cs = img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let rc = CGContext(data: &row, width: p.w, height: 1, bitsPerComponent: 8, bytesPerRow: p.w * 4, space: cs,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return rc.makeImage()
    }

    /// 一段不动的侧边被切开后，下面补的那一行：这一段的"背景"（网页的底色、聊天的壁纸）。
    /// 每列先取 0..<y1 里最常见的颜色；气泡、卡片、头像也可能是一列里最常见的，所以拿这一段左右两边（很少被内容盖住）
    /// 的颜色连成一条（渐变的壁纸也对）当参照：和参照差得多的列用参照的颜色。一列从上到下九成都是一个颜色的（竖的分隔线、边框）照留
    fileprivate static func backdropRow(_ img: CGImage, x0: Int, x1: Int, y1: Int) -> CGImage? {
        let h = max(1, min(img.height, y1))
        guard x1 > x0, let p = plane(img, CGRect(x: x0, y: 0, width: x1 - x0, height: h)) else { return nil }
        var mode = [(Int, Int, Int)](repeating: (255, 255, 255), count: p.w)
        var share = [Double](repeating: 0, count: p.w)
        var count = [Int: (n: Int, r: Int, g: Int, b: Int)]()
        let ys = Array(stride(from: 0, to: h, by: 2))
        for x in 0..<p.w {
            count.removeAll(keepingCapacity: true)
            for y in ys {
                let o = (y * p.w + x) * 4
                let r = Int(p.px[o]), g = Int(p.px[o + 1]), b = Int(p.px[o + 2])
                let k = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
                let e = count[k] ?? (0, 0, 0, 0)
                count[k] = (e.n + 1, e.r + r, e.g + g, e.b + b)
            }
            if let m = count.values.max(by: { $0.n < $1.n }), m.n > 0 {
                mode[x] = (m.r / m.n, m.g / m.n, m.b / m.n)
                share[x] = Double(m.n) / Double(ys.count)
            }
        }
        // 先按"实心的分界"分成几块：两边各自大部分是一个颜色、颜色又差很多（竖的标签栏和网页、侧栏和正文）。
        // 气泡和花纹壁纸之间不算（壁纸那边没有一个占大半的颜色）：一整片聊天还是一块，参照两边的壁纸
        func far(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Bool { max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2)) > 24 }
        let win = 8
        var cuts = [0]
        var x = win
        while x < p.w - win {
            if far(mode[x - 1], mode[x]) {
                let l = (x - win)..<x, r = x..<(x + win)
                let ls = l.map { share[$0] }.reduce(0, +) / Double(win), rs = r.map { share[$0] }.reduce(0, +) / Double(win)
                let lsame = l.allSatisfy { !far(mode[$0], mode[x - 1]) }, rsame = r.allSatisfy { !far(mode[$0], mode[x]) }
                if ls >= 0.6 && rs >= 0.6 && lsame && rsame { cuts.append(x); x += win; continue }
            }
            x += 1
        }
        cuts.append(p.w)
        var row = [UInt8](repeating: 255, count: p.w * 4)
        for z in 0..<(cuts.count - 1) {
            let z0 = cuts[z], z1 = cuts[z + 1], zw = z1 - z0
            // 两边各取一小段（最外面几列常常是边框，往里一点）的中间值
            func edge(_ range: Range<Int>) -> (Int, Int, Int) {
                let cs = range.map { mode[$0] }
                func med(_ f: ((Int, Int, Int)) -> Int) -> Int { let v = cs.map(f).sorted(); return v[v.count / 2] }
                return (med { $0.0 }, med { $0.1 }, med { $0.2 })
            }
            let k = max(2, zw / 30), skip = min(zw / 10, 8)
            let L = edge((z0 + min(skip, zw - 1))..<(z0 + min(zw, skip + k)))
            let R = edge((z1 - min(zw, skip + k))..<max(z1 - min(skip, zw - 1), z1 - min(zw, skip + k) + 1))
            for x in z0..<z1 {
                let t = zw > 1 ? Double(x - z0) / Double(zw - 1) : 0
                let e = (Int(Double(L.0) + Double(R.0 - L.0) * t), Int(Double(L.1) + Double(R.1 - L.1) * t), Int(Double(L.2) + Double(R.2 - L.2) * t))
                let m = mode[x]
                let c = !far(m, e) || share[x] >= 0.9 ? m : e
                row[x * 4] = UInt8(c.0); row[x * 4 + 1] = UInt8(c.1); row[x * 4 + 2] = UInt8(c.2)
            }
        }
        let cs = img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let rc = CGContext(data: &row, width: p.w, height: 1, bitsPerComponent: 8, bytesPerRow: p.w * 4, space: cs,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return rc.makeImage()
    }

    /// 在 near 附近挑一行切开：这一行和上下几行都是底色（每列自己的底色），离 near 越近越好
    fileprivate static func cleanSplit(_ img: CGImage, x0: Int, x1: Int, near: Int) -> Int {
        let lo = max(0, near - 600), hi = img.height
        guard hi - lo > 16, let p = plane(img, CGRect(x: x0, y: lo, width: x1 - x0, height: hi - lo)) else { return near }
        let clean = cleanRows(p)
        let k = 4
        var best = (d: Int.max, row: near)
        for r in k..<(p.h - k) where clean[(r - k)...(r + k)].allSatisfy({ $0 }) {
            let d = abs(lo + r - near)
            if d < best.d { best = (d, lo + r) }
        }
        return best.row
    }

    /// 拷一份（自己的像素，不再连着原来那一整帧）
    fileprivate static func copy(_ img: CGImage) -> CGImage? {
        let cs = img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: img.bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue == CGImageAlphaInfo.none.rawValue
                                  ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage()
    }

    // MARK: 算

    /// 缩成 128 列灰度（高度不变）
    fileprivate static func gray(_ img: CGImage) -> Gray? {
        let rows = img.height
        guard rows > 8 else { return nil }
        var g = Gray(rows: rows, px: [UInt8](repeating: 0, count: rows * cols))
        let ok = g.px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: cols, height: rows, bitsPerComponent: 8, bytesPerRow: cols,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: cols, height: rows))
            return true
        }
        return ok ? g : nil
    }

    /// 两帧哪里变了：每个点、每一列（变了的行超过 2%）
    fileprivate static func changes(_ a: Gray, _ b: Gray, ignore: [Bool]? = nil) -> (mask: [Bool], cols: [Bool], any: Bool, rows: Int) {
        var mask = [Bool](repeating: false, count: a.px.count)
        var colCount = [Int](repeating: 0, count: cols)
        var rowHit = [Bool](repeating: false, count: a.rows)
        var total = 0
        for i in 0..<a.px.count where abs(Int(a.px[i]) - Int(b.px[i])) > 6 && !(ignore?[i % cols] ?? false) {
            mask[i] = true
            colCount[i % cols] += 1
            rowHit[i / cols] = true
            total += 1
        }
        let need = max(2, a.rows / 50)
        return (mask, colCount.map { $0 >= need }, total > a.rows / 8, rowHit.filter { $0 }.count)
    }

    private static func rowDiff(_ a: Gray, _ ra: Int, _ b: Gray, _ rb: Int, _ lo: Int, _ hi: Int) -> Int {
        var d = 0
        let oa = ra * cols, ob = rb * cols
        for c in lo...hi { d += abs(Int(a.px[oa + c]) - Int(b.px[ob + c])) }
        return d
    }

    /// 不挪的话，变了的行是不是都挤在一块里、外面有东西的行都一模一样（页面没滚，是里面一块小框自己在滚、视频在播放）。
    /// 小框里是一行行图文夹着空白，变了的行会分成好多段，所以看的是变了的行从哪到哪，不是有几段。
    /// 页面真的滚了的话，从上到下哪里都有对不上的行，那块外面剩不下有东西的行，不会被当成这种
    fileprivate static func changedInPlace(_ a: Gray, _ b: Gray, top: Int, bottom: Int, lo: Int, hi: Int) -> Bool {
        let band = a.rows - top - bottom
        guard band >= 24 else { return false }
        let w = hi - lo + 1
        var first = -1, last = -1
        var ok = [Bool](repeating: true, count: band), tex = [Bool](repeating: false, count: band)
        for i in 0..<band {
            let r = top + i
            var mn = 255, mx = 0
            for c in lo...hi { let v = Int(a.px[r * cols + c]); mn = min(mn, v); mx = max(mx, v) }
            tex[i] = mx - mn > 3
            if !rowMatches(a, r, b, r, lo, hi, limit: 5 * w, big: 12, allowed: 1) {
                ok[i] = false
                if first < 0 { first = i }
                last = i
            }
        }
        guard first >= 0 else { return true }
        // 那块外面一模一样的有东西的行
        var outside = 0
        for i in 0..<band where (i < first || i > last) && tex[i] && ok[i] { outside += 1 }
        return outside >= max(24, band / 20) && last - first < band * 9 / 10
    }

    /// 两行对不对得上：平均差得少，而且没有几个点差得很多。一排排很像的菜单、表格（"Menu item 12""Menu item 13"）挪错一行，
    /// 平均只差一点点，但字不一样的那几个点差很多
    private static func rowMatches(_ a: Gray, _ ra: Int, _ b: Gray, _ rb: Int, _ lo: Int, _ hi: Int, limit: Int, big bigDiff: Int, allowed: Int) -> Bool {
        var d = 0, big = 0
        let oa = ra * cols, ob = rb * cols
        for c in lo...hi {
            let v = abs(Int(a.px[oa + c]) - Int(b.px[ob + c]))
            d += v
            if v > bigDiff { big += 1; if big > allowed { return false } }
        }
        return d <= limit
    }

    /// 挪 s 行时两帧重叠那段平均每个点差多少
    private static func cost(_ a: Gray, _ b: Gray, _ s: Int, top: Int, bottom: Int, lo: Int, hi: Int) -> Double {
        let band = a.rows - top - bottom, n = band - abs(s)
        guard n > 0 else { return .infinity }
        let ao = top + max(s, 0), bo = top + max(-s, 0)
        var d = 0
        for r in 0..<n { d += rowDiff(a, ao + r, b, bo + r, lo, hi) }
        return Double(d) / (Double(n) * Double(hi - lo + 1))
    }

    /// 滚动那一栏里，中间那段往上挪了几行（内容往下滚了几行；往回滚是负的）。对不上返回 nil；没动返回 0。
    ///
    /// 不按"重叠那段平均差多少"挑：页面上有大片空白时，挪很远、只剩空白重叠的位置平均差几乎是 0，
    /// 比真的位移还像（真的位移那里，鼠标停着的那一行高亮换了一行、浮出来的滚动条挪了，总有一点不一样），会一下跳几百行。
    /// 改成按证据打分：重叠那段里每一行，有东西（字、边框）又对得上的 +1，对不上的 -3，两边都是空白的不算。
    /// 只剩空白重叠的位移没有证据（0 分）；真的位移几乎每行有东西的都对得上，只扣那一两行高亮
    /// expect：照刚才的速度这一帧大概挪了多少。重叠那段几乎都是空白时（好几个位移都一样对得上）挑离它最近的
    private static func shift(_ a: Gray, _ b: Gray, top: Int, bottom: Int, lo: Int, hi: Int, expect: Int? = nil) -> Int? {
        // 先按"对上了就一模一样"找（Chrome 这些按整像素滚的，挪对了像素完全一样）；
        // 对不上再放宽一点试一次（有的 app 滚的时候按小数像素重画，挪对了也会差一点点）
        if let s = shift(a, b, top: top, bottom: bottom, lo: lo, hi: hi, expect: expect, tolerant: false)
            ?? shift(a, b, top: top, bottom: bottom, lo: lo, hi: hi, expect: expect, tolerant: true) { return s }
        // 整栏对不上：可能是页面重新排了版（表格各列左右挪了），只有一部分列还在原来的地方（靠左对齐的第一列）。
        // 分成四段各自对，有一段在速度附近对得上、而且那段里有足够多的字，就用它
        guard let e = expect, hi - lo >= 16 else { return nil }
        let w = (hi - lo + 1) / 4
        var best: (s: Int, ev: Int)?
        for k in 0..<4 {
            let l = lo + k * w, h = k == 3 ? hi : l + w - 1
            guard let s = shift(a, b, top: top, bottom: bottom, lo: l, hi: h, expect: e, tolerant: false),
                  abs(s - e) <= max(48, abs(e) / 2 + 24) else { continue }
            // 这一段的证据：有东西又对得上的行（空白的一段在哪都对得上，不算）
            let ev = matchedRows(a, b, s, top: top, bottom: bottom, lo: l, hi: h)
            if ev >= max(32, (a.rows - top - bottom - abs(s)) / 6), ev > (best?.ev ?? 0) { best = (s, ev) }
        }
        return best?.s
    }

    /// 挪 s 行时，这几列里有东西、又对得上的行有几行
    private static func matchedRows(_ a: Gray, _ b: Gray, _ s: Int, top: Int, bottom: Int, lo: Int, hi: Int) -> Int {
        let band = a.rows - top - bottom, n = band - abs(s)
        guard n > 0 else { return 0 }
        let ao = top + max(s, 0), bo = top + max(-s, 0), w = hi - lo + 1
        var count = 0
        for r in 0..<n {
            var mn = 255, mx = 0
            for c in lo...hi { let v = Int(a.px[(ao + r) * cols + c]); mn = min(mn, v); mx = max(mx, v) }
            if mx - mn > 3, rowMatches(a, ao + r, b, bo + r, lo, hi, limit: 5 * w, big: 12, allowed: 1) { count += 1 }
        }
        return count
    }

    private static func shift(_ a: Gray, _ b: Gray, top: Int, bottom: Int, lo: Int, hi: Int, expect: Int?, tolerant: Bool) -> Int? {
        let band = a.rows - top - bottom
        guard band >= 24 else { return nil }
        let w = hi - lo + 1
        let minOverlap = max(16, band / 5)
        let maxS = band - minOverlap
        // 每一行有没有东西：这一栏里最亮最暗差一点就算（字、图标、边框；白卡片和浅灰底色只差 9 级灰度，也是东西：
        // 屏幕截图的像素是准的，没有噪点）。整行一个颜色的（空白、色块）不算，它们在哪都一样像
        func texture(_ g: Gray) -> [Bool] {
            (0..<g.rows).map { r in
                var mn = 255, mx = 0
                let o = r * cols
                for c in lo...hi { let v = Int(g.px[o + c]); mn = min(mn, v); mx = max(mx, v) }
                return mx - mn > 3
            }
        }
        let ta = texture(a), tb = texture(b)
        // 这一栏两帧都几乎全是空白：看不出挪没挪，当没动（不接，等有东西了再对）
        let texRows = (top..<(top + band)).filter { ta[$0] || tb[$0] }.count
        if texRows < max(4, band / 100) { return 0 }
        // 一行算对得上：平均每个点差不到 5（灰度），差很多的点不超过一个（放宽时：平均 7、差很多的点不超过三个）
        let rowLimit = (tolerant ? 7 : 5) * w
        let bigDiff = tolerant ? 40 : 12, bigAllowed = tolerant ? 3 : 1
        /// 挪 s 行的分数（每隔 step 行看一次）、看了几行有东西的、几行对不上
        func score(_ s: Int, step: Int) -> (Int, Int, Int) {
            let n = band - abs(s), ao = top + max(s, 0), bo = top + max(-s, 0)
            var sc = 0, ev = 0, bad = 0, r = 0
            while r < n {
                let ok = rowMatches(a, ao + r, b, bo + r, lo, hi, limit: rowLimit, big: bigDiff, allowed: bigAllowed)
                if !ok { sc -= 3; bad += 1 } else if ta[ao + r] || tb[bo + r] { sc += 1; ev += 1 }
                r += step
            }
            return (sc, ev, bad)
        }
        // 粗找：每隔几行比一次，每个 s 都试
        let step = max(1, band / 240)
        // 每个位移各算各的，分到几个核上同时算（结果和一个个算完全一样；以前长页面、几栏一起滚时一帧要比几千万次，容易丢帧）
        let count = 2 * maxS + 1
        var scores = [Int](repeating: .min, count: count)
        var bads = [Int](repeating: 0, count: count)
        scores.withUnsafeMutableBufferPointer { buf in
            bads.withUnsafeMutableBufferPointer { bb in
                let out = buf.baseAddress!, ob = bb.baseAddress!
                let chunks = min(8, max(1, count / 64))
                DispatchQueue.concurrentPerform(iterations: chunks) { k in
                    var i = k * count / chunks
                    let end = (k + 1) * count / chunks
                    while i < end { let r = score(i - maxS, step: step); out[i] = r.0; ob[i] = r.2; i += 1 }
                }
            }
        }
        // 分最高的；一样高的取挪得最少的（一样少取往下的）
        var s0 = 0, best = Int.min
        for i in 0..<count {
            let s = i - maxS, v = scores[i]
            if v > best || (v == best && (abs(s), -s) < (abs(s0), -s0)) { best = v; s0 = s }
        }
        // 精确：附近每一行都看
        var fine = (sc: Int.min, ev: 0, bad: 0, s: s0)
        for c in max(-maxS, s0 - step)...min(maxS, s0 + step) {
            let (v, e, x) = score(c, step: 1)
            if v > fine.sc || (v == fine.sc && abs(c) < abs(fine.s)) { fine = (v, e, x, c) }
        }
        // 证据很少（重叠那段几乎都是空白，快速滑过卡片和表格之间的一大片空白时）：好几个位移都一样"对得上"，分最高的不一定是真的。
        // 在一行都没对不上的位移里挑离"照刚才的速度该挪多少"最近的（以前挑分最高的，会少掉一两百行）
        if let e = expect, fine.ev < max(8, band / 12) {
            var pick: Int?
            for i in 0..<count where bads[i] == 0 && scores[i] >= 0 {
                let s = i - maxS
                if pick == nil || abs(s - e) < abs(pick! - e) { pick = s }
            }
            if let p = pick {
                var f = (sc: Int.min, d: Int.max, s: p)
                for c in max(-maxS, p - step)...min(maxS, p + step) {
                    let (v, _, x) = score(c, step: 1)
                    guard x == 0 else { continue }
                    if abs(c - e) < f.d || (abs(c - e) == f.d && v > f.sc) { f = (v, abs(c - e), c) }
                }
                if f.sc != Int.min { return f.s }
            }
        }
        /// 这个位移能不能接受
        func evaluate(_ cand: (sc: Int, ev: Int, bad: Int, s: Int)) -> Int? {
            // 对得上的有东西的行够多、对不上的行不到重叠那段的 12%：就是它（鼠标停着的那一行高亮、浮在上面的按钮会有几十行对不上，
            // 真的位移照样认得出）。挪错了的话对不上的多得多；一样的卡片、一行行很像的表格挪错了也能"对上"一大半，所以要卡比例
            var fine = cand
            var overlap = band - abs(fine.s)
            // 对不上的行挤成一两块：是局部的变化，不是挪错了（挪错了的话对不上的行会散在整个画面）。
            // 比如指针下面那几行的悬停高亮、淡入淡出的按钮，滚了一段才吸顶的表头、吸底的工具条。这一两块不算进对不上的比例，
            // 只要别的地方对得上（以前一张表里指针下面三行在高亮，刚好超过比例被拒，之后一直跟丢，自动滚动以为到底了）
            // 只在位移和刚才的速度对得上时这样放宽（离得远的本来就要更强的证据，见下面）
            let far = expect.map { abs(fine.s - $0) > max(48, abs($0) / 2 + 24) } ?? false
            if fine.bad > 0 && !far {
                let ao = top + max(fine.s, 0), bo = top + max(-fine.s, 0)
                var runs: [(lo: Int, hi: Int, n: Int)] = []
                for r in 0..<overlap where !rowMatches(a, ao + r, b, bo + r, lo, hi, limit: rowLimit, big: bigDiff, allowed: bigAllowed) {
                    // 中间夹着几行碰巧一样的（空白）也算同一块
                    if let l = runs.last, r - l.hi <= 6 { runs[runs.count - 1].hi = r; runs[runs.count - 1].n += 1 } else { runs.append((r, r, 1)) }
                }
                let blocks = runs.sorted { $0.n > $1.n }.prefix(2)
                let span = blocks.reduce(0) { $0 + $1.hi - $1.lo + 1 }
                let inBlocks = blocks.reduce(0) { $0 + $1.n }
                let rest = overlap - span, restBad = fine.bad - inBlocks
                if span <= overlap / 4, rest > 0, fine.ev >= 8 + inBlocks, restBad * 100 <= rest * 12 { overlap = rest; fine.bad = restBad }
            }
            // 和刚才的速度差很远（一直往下滚，忽然算出往回跳了几百行）：多半是认错了，要证据强得多才信
            let ratio = far ? 6 : 2
            // 放宽了的那一遍不接受离速度很远的（它是给按小数像素滚的 app 用的，那种滚动是连着的，不会突然跳）。
            // 页面重新排版（表格加载了新的几行、各列挪了）时，真的位移哪都对不上，放宽以后反而在很远的地方凑得出"对得上"
            if tolerant && far { return nil }
            if fine.ev >= 8 && fine.ev >= fine.bad * ratio && fine.bad * 100 <= overlap * 12 { return fine.s }
            // 重叠那段几乎都是空白（卡片和表格之间的一大片空白滚过去时）：证据少，但一行都没对不上、别的位移都有对不上的，也是它
            if fine.bad == 0 && fine.sc >= 0 { return fine.s }
            return nil
        }
        // 分最高的那个先看；它离刚才的速度很远又通不过时，再看速度附近分最高的那个：指针下面的行在悬停高亮、高亮还换了一行时，
        // 真的位移那里会有一两大块对不上，扣分扣得多，总分可能比很远处碰巧凑上的还低（以前直接拿了很远的那个，又通不过，就跟丢了）。
        // 先看分最高的：手指又甩了一下、一下快了很多时，真的位移本来就离速度很远
        if let r = evaluate(fine) { return r }
        if let e = expect {
            let win = max(48, abs(e) / 2 + 24)
            let farBest = abs(fine.s - e) > win
            if farBest {
                var bi = -1, bv = Int.min
                let i0 = max(0, e - win + maxS), i1 = min(count - 1, e + win + maxS)
                if i0 <= i1 { for i in i0...i1 where scores[i] > bv { bv = scores[i]; bi = i } }
                if bi >= 0 {
                    let c0 = bi - maxS
                    var near = (sc: Int.min, ev: 0, bad: 0, s: c0)
                    for c in max(-maxS, c0 - step)...min(maxS, c0 + step) {
                        let (v, ev, x) = score(c, step: 1)
                        if v > near.sc { near = (v, ev, x, c) }
                    }
                    if let r = evaluate(near) { return r }
                }
            }
        }
        return nil
    }

    private(set) var debugShift = ""
    var debugText: String {
        "frames=\(frameCount) rejected=\(rejected) strips=\(strips.count) cols=\(colLo)-\(colHi) header=\(header) footer=\(footer) height=\(height) pos=\(position) max=\(maxPosition) end=\(contentEnd()) shift0=\(debugShift) restarts=\(restarts) resets=\(resets)"
    }
}

/// 滚动截图的拼接：一个窗口里可能有好几栏能滚（左边标签栏、右边网页）。每栏各拼各的（ScrollLane），出图时拼在一起：
/// - 一开始只有一栏在看。它认出了在滚的那一栏，就定下来；再开一栏接着看剩下的地方（已经有人拼的那几列不看）
/// - 出图：最长的那栏当底图；别的栏在自己那几列里盖上去，比它短的地方用它自己的底色拉长，最底下不动的那条放在最下面
/// - 每栏的内容都完整留着：先滚左边、再滚右边，两边滚过的都在
final class ScrollStitcher: @unchecked Sendable {
    private var lanes: [ScrollLane] = [ScrollLane()]
    private static let maxLanes = 4
    private(set) var frameCount = 0

    /// 正在看、还没定下来的那一栏（最后一个）
    private var watching: ScrollLane? { lanes.last.flatMap { $0.isSettled ? nil : $0 } }
    private var settledLanes: [ScrollLane] { lanes.filter(\.isSettled) }

    var height: Int { lanes.map(\.height).max() ?? 0 }
    var rejected: Int { lanes.reduce(0) { $0 + $1.rejected } }
    /// 正在滚的那一栏对不上了（滚太快）：再往下滚会漏
    var lost: Bool { active?.lost ?? false }

    /// 最近在动的那一栏（"滚太快"的提示看它）
    private weak var active: ScrollLane?

    /// 指针在哪一行（帧里的像素，原点在上面；不在选区里是 nil）：取行的线避开它（见 ScrollLane.avoidRow）
    var avoidRow: Int?

    @discardableResult
    func add(_ img: CGImage) -> Bool {
        guard let g = ScrollLane.gray(img) else { return false }
        frameCount += 1
        lastGray = g
        var grew = false
        var i = 0
        while i < lanes.count {
            let l = lanes[i]
            if !l.isSettled { l.avoidRow = avoidRow }
            let before = l.restarts
            if l.add(img, g) { grew = true }
            if l.changedNow && (l.isSettled || active == nil) { active = l }
            // 这一栏认错了、从头再来：后面那几栏是照它原来的范围开的（不看它的列），一起不要了，等它重新定下来再开
            if l.restarts != before, i + 1 < lanes.count {
                lanes.removeSubrange((i + 1)...)
                if let a = active, !lanes.contains(where: { $0 === a }) { active = l }
            }
            i += 1
        }
        // 最后那栏刚定下来：再开一栏，看别的地方还有没有在滚的
        if let last = lanes.last, last.isSettled, lanes.count < Self.maxLanes {
            let n = ScrollLane.cols
            var ignore = [Bool](repeating: false, count: n)
            // 只不看那一栏自己的列（多不看一两列的话，紧挨着的另一栏最左边的字会被切掉）
            for l in lanes { for c in l.columns { ignore[c] = true } }
            // 整个宽度都有人拼了：不用再看
            if ignore.contains(false) {
                let w = ScrollLane()
                w.ignore = ignore
                _ = w.add(img, g)
                lanes.append(w)
            }
        }
        return grew
    }

    /// 这一帧有没有在滚（定下来的栏里有一栏挪了）：条上的"Scrolling"看它
    var moving: Bool { settledLanes.contains { ($0.lastMove ?? 0) != 0 } }
    /// 真的接上过内容
    var hasContent: Bool { lanes.contains { $0.hasContent } }

    /// 在这里（选区里从左往右的 0...1）滚的那一栏：定下来了才有
    func lane(atX x: CGFloat) -> ScrollLane? {
        let c = Int(x * CGFloat(ScrollLane.cols))
        return settledLanes.first { $0.columns.contains(c) }
    }

    /// 定下来的栏里最宽的有几列（没有就是全部）
    var widestSettledLane: Int { settledLanes.map { $0.columns.count }.max() ?? ScrollLane.cols }

    /// 还没有哪一栏在拼的列（128 列里），至少 minWidth 列宽的几段：自动滚动滚完一栏后，去这些地方看还有没有能滚的（左边的 nav）
    func unclaimedSpans(minWidth: Int) -> [ClosedRange<Int>] {
        var used = [Bool](repeating: false, count: ScrollLane.cols)
        for l in settledLanes { for c in l.columns { used[c] = true } }
        var out: [ClosedRange<Int>] = []
        var i = 0
        while i < used.count {
            guard !used[i] else { i += 1; continue }
            var j = i
            while j + 1 < used.count, !used[j + 1] { j += 1 }
            if j - i + 1 >= minWidth { out.append(i...j) }
            i = j + 1
        }
        return out
    }

    private var lastGray: ScrollLane.Gray?

    /// 离 x（选区里从左往右的 0...1）最近的、从上到下都是空白的一段（至少三列宽）的中间：自动滚动从这里开始。
    /// 指针压在内容上时，下面常常是页面里一块自己能滚的小框（预览框、声明框、代码块），浏览器把滚轮交给它，
    /// 外面的页面一动不动；页边的空白下面只有页面本身。找不到（附近都是内容）返回 nil
    func blankColumn(near x: CGFloat, within: Int = 48) -> CGFloat? {
        guard let g = lastGray else { return nil }
        let n = ScrollLane.cols
        let r0 = g.rows * 15 / 100, r1 = g.rows * 97 / 100
        guard r1 - r0 > 20 else { return nil }
        let blank: [Bool] = (0..<n).map { c in
            var h = [Int](repeating: 0, count: 256)
            for r in r0..<r1 { h[Int(g.px[r * n + c])] += 1 }
            let m = h.indices.max { h[$0] < h[$1] } ?? 0
            // 九成的行都是一个颜色（浮在下面的输入框、底栏只占一小段）
            return h[max(0, m - 4)...min(255, m + 4)].reduce(0, +) * 100 >= (r1 - r0) * 90
        }
        let pc = min(n - 1, max(0, Int(x * CGFloat(n))))
        // 最外面两列（窗口边、滚动条）不要
        func ok(_ c: Int) -> Bool { c >= 3 && c <= n - 4 && blank[c - 1] && blank[c] && blank[c + 1] }
        for d in 0...within {
            for c in [pc - d, pc + d] where ok(c) { return (CGFloat(c) + 0.5) / CGFloat(n) }
        }
        return nil
    }

    /// 调试用：某一栏单独出的图
    func debugLaneImage(_ i: Int) -> CGImage? { i < lanes.count ? lanes[i].image() : nil }

    func image(preview: Bool = false) -> CGImage? {
        if !preview { lanes.forEach { $0.finish() } }
        let used = lanes.filter { $0.isSettled && $0.hasContent }
        guard !used.isEmpty else { return lanes.first?.image(preview: preview) }
        let imgs = used.compactMap { l in l.image(preview: preview).map { (l, $0) } }
        guard let base = imgs.max(by: { $0.1.height < $1.1.height }) else { return nil }
        guard imgs.count > 1 else { return base.1 }
        let W = base.1.width, H = base.1.height
        let cs = base.1.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        func put(_ img: CGImage?, x: Int, top: Int, w: Int? = nil, h: Int? = nil) {
            guard let img else { return }
            ctx.draw(img, in: CGRect(x: x, y: H - top - (h ?? img.height), width: w ?? img.width, height: h ?? img.height))
        }
        put(base.1, x: 0, top: 0)
        ctx.interpolationQuality = .none
        let ranges = imgs.map { $0.0.columnPixels(W) }
        for (l, img) in imgs where l !== base.0 && img.width == W {
            var (x0, x1) = l.columnPixels(W)
            guard x1 > x0 else { continue }
            // 连着它和左右相邻那栏之间的空隙一起放（不属于哪一栏的那几列是不动的底色）。不然那几列露出底图那栏的样子：
            // 底图那栏（最长的，可能是 nav）把这里当它旁边不动的部分拉长，和这一栏的位置对不上，中间一条白、卡片的边断掉
            let left = ranges.filter { $0.1 <= x0 }.map(\.1).max() ?? x0
            let right = ranges.filter { $0.0 >= x1 }.map(\.0).min() ?? x1
            x0 = left; x1 = right
            // 从哪一行切开、中间补长：内容和底下那条交界的地方附近，挑一行两边都只有底色（不切到气泡、字）的
            let near = min(l.contentBottom, img.height)
            let bottom = preview ? near : ScrollLane.cleanSplit(img, x0: x0, x1: x1, near: near), footer = img.height - bottom
            debugCompose = "contentBottom=\(l.contentBottom) split=\(bottom) h=\(img.height) H=\(H)"
            // 上面：这一栏自己的（到内容最下面）
            put(img.cropping(to: CGRect(x: x0, y: 0, width: x1 - x0, height: bottom)), x: x0, top: 0)
            // 中间：比底图短的那段，用这一栏最下面附近一行底色拉长
            let gap = H - bottom - footer
            if gap > 0 {
                // 每列自己的底色拉长（这一栏的内容到这里就完了）
                let row = preview ? img.cropping(to: CGRect(x: x0, y: max(0, bottom - 1), width: x1 - x0, height: 1))
                    : ScrollLane.modeRow(img, x0: x0, x1: x1, y0: bottom - 4, y1: min(bottom + 4, img.height - footer), exact: true)
                put(row, x: x0, top: bottom, w: x1 - x0, h: gap)
            }
            // 最下面：这一栏底下不动的那条
            if footer > 0 { put(img.cropping(to: CGRect(x: x0, y: bottom, width: x1 - x0, height: footer)), x: x0, top: H - footer) }
        }
        return ctx.makeImage()
    }

    private(set) var debugCompose = ""
    var debugText: String {
        "frames=\(frameCount) lanes=\(lanes.count) " + lanes.enumerated().map { "#\($0.offset)[\($0.element.isSettled ? "S" : "w") \($0.element.columns) \($0.element.debugText)]" }.joined(separator: " ")
    }
}
