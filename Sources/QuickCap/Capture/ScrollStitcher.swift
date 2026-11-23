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
    fileprivate static let cols = 128

    /// 一帧的灰度：每行 128 个点
    fileprivate struct Gray {
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
    private(set) var header = 0, footer = 0
    private var settled = false
    /// 看了几次滚动；每列变过几次；每次滚动哪些点变了
    private var motions = 0
    /// 定下来之前，一共有多少行变过（大概滚了多远）
    private var movedRows = 0
    private var colChanged = [Int](repeating: 0, count: cols)
    private var rowChangedMasks: [[Bool]] = []
    private var pending: [(CGImage, Gray)] = []
    private var covered = 0
    private var position = 0
    private(set) var frameCount = 0
    private(set) var rejected = 0
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
        prevGray = g
        let diff = Self.changes(prev, g, ignore: ignore)
        changedNow = diff.any
        guard diff.any else { if settled { lastMove = 0 }; return false }
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
        colLo = 0; colHi = Self.cols - 1
        colChanged = [Int](repeating: 0, count: Self.cols)
        rowChangedMasks = []
        strips = []; pending = []; settled = false
    }

    /// 变了好几次：先看是不是真的在滚（变的那几列整体挪了几行）。
    /// 只是别的变化（鼠标划过侧栏时的高亮、提示、加载动画）、或者对不上（一开始就滚太快）：不定，接着看
    private func trySettle(_ img: CGImage, _ g: Gray) {
        guard let g0 = firstGray else { settle(); return }
        let n = Self.cols
        let changed = (0..<n).map { colChanged[$0] > 0 }
        guard let cMin = changed.firstIndex(of: true), let cMax = changed.lastIndex(of: true) else { settle(); return }
        colLo = cMin; colHi = cMax
        computeFixedRows(rows: g0.rows)
        let top = header, bottom = footer
        colLo = 0; colHi = n - 1; header = 0; footer = 0
        let sh = Self.shift(g0, g, top: top, bottom: bottom, lo: cMin, hi: cMax)
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
        guard let cMin = changed.firstIndex(of: true), let cMax = changed.lastIndex(of: true) else { return }
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
        let shDbg = pending.last.flatMap { Self.shift(g0, $0.1, top: header, bottom: footer, lo: cMin, hi: cMax) }
        debugShift = shDbg.map(String.init) ?? "nil"
        if let (_, gl) = pending.last, let sh = shDbg, sh > 4 {
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
        if let (_, gl) = pending.last, let sh = Self.shift(g0, gl, top: header, bottom: footer, lo: colLo, hi: colHi), sh > 4 {
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

    /// 滚动那段的中线（每一行从这里取）
    private var mid: Int { max(0, ((first?.height ?? 0) - header - footer) / 2) }

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
        guard let ref = refGray, let shift = Self.shift(ref, g, top: header, bottom: footer, lo: colLo, hi: colHi) else {
            // 对不上（滚太快、内容整个变了）：这帧不要，还拿上一帧去对下一帧
            rejected += 1
            lost = true
            return false
        }
        lost = false
        lastMove = shift
        guard shift != 0 else { return false }
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
        if footer > 0 { put(deep.cropping(to: CGRect(x: 0, y: Hf - footer, width: W, height: footer)), x: 0, top: y + tailRows) }
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
                for (s0, s1) in parts {
                    // 一起切不了（左边是一行行列表、一直排到底）：每段自己看（最左边那条窄栏底下的头像也能挪到最下面）
                    let split = together < Hf ? together : Self.sideSplit(deep, [(s0, s1)])
                    if split > 0 { put(first.cropping(to: CGRect(x: s0, y: 0, width: s1 - s0, height: split)), x: s0, top: 0) }
                    put(Self.modeRow(first, x0: s0, x1: s1, y0: split - 160, y1: split), x: s0, top: split, w: s1 - s0, h: gap)
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
        let block = runs[k], g = runs[k + 1]
        guard block.bottom - block.top < H / 6, g.clean, g.bottom - g.top + 1 > max(16, typical) else { return H }
        return (g.top + g.bottom + 1) / 2
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
    fileprivate static func modeRow(_ img: CGImage, x0: Int, x1: Int, y0: Int, y1: Int) -> CGImage? {
        let y0 = max(0, y0), y1 = min(img.height, y1)
        guard x1 > x0, y1 > y0, let p = plane(img, CGRect(x: x0, y: 0, width: x1 - x0, height: img.height)) else { return nil }
        let clean = cleanRows(p)
        var rows = (y0..<y1).filter { clean[$0] }
        if rows.count < 4 { rows = clean.indices.filter { clean[$0] } }
        if rows.isEmpty { rows = Array(y0..<y1) }
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
        for x in 0..<p.w {
            let use = cols[x].n * 10 >= rows.count * 7 ? cols[x] : bg
            let n = max(1, use.n)
            row[x * 4] = UInt8(use.r / n); row[x * 4 + 1] = UInt8(use.g / n); row[x * 4 + 2] = UInt8(use.b / n)
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

    /// 挪 s 行时两帧重叠那段平均每个点差多少
    private static func cost(_ a: Gray, _ b: Gray, _ s: Int, top: Int, bottom: Int, lo: Int, hi: Int) -> Double {
        let band = a.rows - top - bottom, n = band - abs(s)
        guard n > 0 else { return .infinity }
        let ao = top + max(s, 0), bo = top + max(-s, 0)
        var d = 0
        for r in 0..<n { d += rowDiff(a, ao + r, b, bo + r, lo, hi) }
        return Double(d) / (Double(n) * Double(hi - lo + 1))
    }

    /// 滚动那一栏里，中间那段往上挪了几行（内容往下滚了几行；往回滚是负的）。对不上返回 nil；没动返回 0
    private static func shift(_ a: Gray, _ b: Gray, top: Int, bottom: Int, lo: Int, hi: Int) -> Int? {
        let band = a.rows - top - bottom
        guard band >= 24 else { return nil }
        let w = Double(hi - lo + 1)
        let minOverlap = max(16, band / 5)
        let maxS = band - minOverlap
        // 挪 s 行时两帧重叠那段平均差多少（每隔 step 行比一次）
        func cost(_ s: Int, step: Int) -> Double {
            let n = band - abs(s), ao = top + max(s, 0), bo = top + max(-s, 0)
            var d = 0, count = 0, r = 0
            while r < n { d += rowDiff(a, ao + r, b, bo + r, lo, hi); count += 1; r += step }
            return Double(d) / (Double(count) * w)
        }
        // 粗找：每隔几行比一次，s 隔一个试一个（后面再在附近一行行精确找）
        let step = max(1, band / 160)
        // 每个位移各算各的，分到几个核上同时算（结果和一个个算完全一样；以前长页面、几栏一起滚时一帧要比几千万次，容易丢帧）
        let count = 2 * maxS + 1
        var costs = [Double](repeating: .infinity, count: count)
        costs.withUnsafeMutableBufferPointer { buf in
            let out = buf.baseAddress!
            let chunks = min(8, max(1, count / 64))
            DispatchQueue.concurrentPerform(iterations: chunks) { k in
                var i = k * count / chunks
                let end = (k + 1) * count / chunks
                while i < end { out[i] = cost(i - maxS, step: step); i += 1 }
            }
        }
        var best = (score: Double.infinity, s: 0)
        var scores: [(Int, Double)] = []
        scores.reserveCapacity(count)
        for i in 0..<count {
            let s = i - maxS, c = costs[i]
            scores.append((s, c))
            if c < best.score { best = (c, s) }
        }
        // 太不像：对不上
        guard best.score < 6 else { return nil }
        // 几乎一样好的里面取挪得最少的那个（空白处好几个位移都一样像；一样少的取往下的）。
        // "几乎一样"要卡得很紧：一行行很像的列表（"Result 12""Result 13"、一排"Google 搜索"），挪一行也挺像，但没有对准的那个像
        let near = scores.filter { $0.1 <= best.score + 0.08 + best.score * 0.1 }.map(\.0)
        let s0 = near.min { (abs($0), -$0) < (abs($1), -$1) } ?? best.s
        // 精确：在附近每一行都比
        var bestFine = (Double.infinity, s0)
        for c in max(-maxS, s0 - 2)...min(maxS, s0 + 2) {
            let v = cost(c, step: 1)
            if v < bestFine.0 { bestFine = (v, c) }
        }
        return bestFine.1
    }

    private(set) var debugShift = ""
    var debugText: String {
        "frames=\(frameCount) rejected=\(rejected) strips=\(strips.count) cols=\(colLo)-\(colHi) header=\(header) footer=\(footer) height=\(height) pos=\(position) max=\(maxPosition) end=\(contentEnd()) shift0=\(debugShift)"
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

    @discardableResult
    func add(_ img: CGImage) -> Bool {
        guard let g = ScrollLane.gray(img) else { return false }
        frameCount += 1
        var grew = false
        for l in lanes {
            if l.add(img, g) { grew = true }
            if l.changedNow && (l.isSettled || active == nil) { active = l }
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
        for (l, img) in imgs where l !== base.0 && img.width == W {
            let (x0, x1) = l.columnPixels(W)
            guard x1 > x0 else { continue }
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
                    : ScrollLane.modeRow(img, x0: x0, x1: x1, y0: bottom - 160, y1: bottom)
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
