import CoreGraphics
import Foundation

/// 冻结画面里可以吸附的东西，按像素算，不认识任何 app：
/// 1. 长的直线：表格线、卡片和按钮的边框、分隔线（相邻两列/两行亮度差得多、而且连成一长条）
/// 2. 内容的外边：框的边拖到一个东西旁边时，贴着它的外沿吸住（没有边框的图标、一段文字、一个太阳都行），
///    条件是边外面那几列是空的（纯色背景），边里面就有东西
///
/// 都在 pt 坐标里算（截图按屏幕的像素倍数缩成 1 倍），原点在左下角，和截图界面一样
struct ContentEdges: Sendable {
    let width: Int
    let height: Int
    /// 长直线（和 SnapLines 的线一样用）
    var vertical: [SnapLines.Segment] = []
    var horizontal: [SnapLines.Segment] = []
    /// 亮度在哪里变了，记的是"两格之间"：
    /// hm[y][x]：第 x 格和第 x+1 格之间变了（左右方向）；vm[y][x]：第 y 行和第 y-1 行之间变了（上下方向）。
    /// 记在两格之间，东西的左沿和右沿才对称（���在某一格上的话，一边会差一格）。
    /// 下面四个是累计数，查一段范围里有没有变化只要一次减法：
    /// 按列累计（竖着的边用）：colH/colV[x * (height + 1) + y]；按行累计（横着的边用）：rowH/rowV[y * (width + 1) + x]
    private var colH: [UInt16] = [], colV: [UInt16] = []
    private var rowH: [UInt16] = [], rowV: [UInt16] = []

    /// 亮度差多少算"有东西"（0–255）。纯色背景、压缩噪点在这以下
    static let contentThreshold = 6
    /// 亮度差多少算直线上的一点。很淡的分隔线（差 5/255 左右）也要能找到；
    /// 不会把渐变当成线：渐变每一格只差 1–2，而且线上每一点的明暗方向要一致（一边亮一边暗）
    static let lineThreshold = 5
    /// 边外面要空多宽（pt），才算贴着东西的外沿。比字间距大一点，不会吸到字的中间
    static let clearance = 3

    // MARK: 计算

    /// 从冻结的整屏截图算（几十毫秒，在后台做）。pointSize：屏幕大小（pt）
    static func build(from image: CGImage, pointSize: CGSize) -> ContentEdges? {
        let w = max(1, Int(pointSize.width.rounded())), h = max(1, Int(pointSize.height.rounded()))
        guard w > 2, h > 2 else { return nil }
        // 缩成 1 倍、灰度。内存里第 0 行是画面最上面一行
        var gray = [UInt8](repeating: 0, count: w * h)
        let ok = gray.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var e = ContentEdges(width: w, height: h)
        // 内存里的行 r 对应截图界面坐标的 y = h - 1 - r（原点左下）
        let ct = contentThreshold, lt = lineThreshold
        var hm = [Bool](repeating: false, count: w * h), vm = [Bool](repeating: false, count: w * h) // [y * w + x]
        // 竖线：第 x 列和第 x+1 列之间（截图界面坐标 x+1 处）亮度差大的地方，按 y 连起来
        var vRun = [Int](repeating: 0, count: w), vGap = [Int](repeating: 0, count: w)
        var vStart = [Int](repeating: 0, count: w)
        var vSign = [Int8](repeating: 0, count: w)
        var hRun = 0, hGap = 0, hStart = 0, hSign: Int8 = 0
        let minV = max(32, h * 6 / 100), minH = max(32, w * 6 / 100), maxGap = 2
        gray.withUnsafeBufferPointer { g in
            for y in 0..<h {
                let r = h - 1 - y
                let row = r * w
                let below = r + 1 < h ? (r + 1) * w : row // 截图界面里的下一行（y - 1）
                hRun = 0; hGap = 0; hSign = 0
                for x in 0..<w {
                    let v = Int(g[row + x])
                    let sdx = x + 1 < w ? Int(g[row + x + 1]) - v : 0
                    let sdy = Int(g[below + x]) - v
                    let dx = abs(sdx), dy = abs(sdy)
                    if x + 1 < w, dx >= ct { hm[y * w + x] = true }
                    if y > 0, dy >= ct { vm[y * w + x] = true }
                    // 竖线（在 x+1 处）
                    if x + 1 < w {
                        let sign: Int8 = sdx > 0 ? 1 : -1
                        if dx >= lt, vRun[x] > 0, sign != vSign[x] {
                            // 明暗方向反了：不是同一条线
                            if vRun[x] >= minV { e.vertical.append(.init(pos: CGFloat(x + 1), from: CGFloat(vStart[x]), to: CGFloat(vStart[x] + vRun[x]))) }
                            vRun[x] = 0; vGap[x] = 0
                        }
                        if dx >= lt {
                            if vRun[x] == 0 { vStart[x] = y; vSign[x] = sign }
                            vRun[x] = y - vStart[x] + 1; vGap[x] = 0
                        } else if vRun[x] > 0 {
                            vGap[x] += 1
                            if vGap[x] > maxGap {
                                if vRun[x] >= minV { e.vertical.append(.init(pos: CGFloat(x + 1), from: CGFloat(vStart[x]), to: CGFloat(vStart[x] + vRun[x]))) }
                                vRun[x] = 0; vGap[x] = 0
                            }
                        }
                    }
                    // 横线（在这一行和下一行之间，截图界面坐标 y 处）
                    if y > 0 {
                        let sign: Int8 = sdy > 0 ? 1 : -1
                        if dy >= lt, hRun > 0, sign != hSign {
                            if hRun >= minH { e.horizontal.append(.init(pos: CGFloat(y), from: CGFloat(hStart), to: CGFloat(hStart + hRun))) }
                            hRun = 0; hGap = 0
                        }
                        if dy >= lt {
                            if hRun == 0 { hStart = x; hSign = sign }
                            hRun = x - hStart + 1; hGap = 0
                        } else if hRun > 0 {
                            hGap += 1
                            if hGap > maxGap {
                                if hRun >= minH { e.horizontal.append(.init(pos: CGFloat(y), from: CGFloat(hStart), to: CGFloat(hStart + hRun))) }
                                hRun = 0; hGap = 0
                            }
                        }
                    }
                }
                if y > 0, hRun >= minH { e.horizontal.append(.init(pos: CGFloat(y), from: CGFloat(hStart), to: CGFloat(hStart + hRun))) }
            }
        }
        for x in 0..<w where vRun[x] >= minV {
            e.vertical.append(.init(pos: CGFloat(x + 1), from: CGFloat(vStart[x]), to: CGFloat(vStart[x] + vRun[x])))
        }
        // 太花的画面（照片）会有很多线：留最长的那些就够了
        for keyPath in [\ContentEdges.vertical, \ContentEdges.horizontal] {
            if e[keyPath: keyPath].count > 3000 {
                e[keyPath: keyPath] = Array(e[keyPath: keyPath].sorted { $0.to - $0.from > $1.to - $1.from }.prefix(3000))
            }
        }
        // 累计数
        func byColumn(_ m: [Bool]) -> [UInt16] {
            var out = [UInt16](repeating: 0, count: w * (h + 1))
            m.withUnsafeBufferPointer { c in
                for x in 0..<w {
                    var acc: UInt16 = 0
                    let base = x * (h + 1)
                    for y in 0..<h { if c[y * w + x] { acc &+= 1 }; out[base + y + 1] = acc }
                }
            }
            return out
        }
        func byRow(_ m: [Bool]) -> [UInt16] {
            var out = [UInt16](repeating: 0, count: h * (w + 1))
            m.withUnsafeBufferPointer { c in
                for y in 0..<h {
                    var acc: UInt16 = 0
                    let base = y * (w + 1)
                    for x in 0..<w { if c[y * w + x] { acc &+= 1 }; out[base + x + 1] = acc }
                }
            }
            return out
        }
        e.colH = byColumn(hm); e.colV = byColumn(vm)
        e.rowH = byRow(hm); e.rowV = byRow(vm)
        return e
    }

    // MARK: 查

    /// 第 x 列在 y 范围 [a, b) 里有没有变化（sums 是按列累计的那一个）
    private func inColumn(_ sums: [UInt16], _ x: Int, _ a: Int, _ b: Int) -> Bool {
        guard x >= 0, x < width else { return false }
        let a = max(0, a), b = min(height, b)
        guard b > a else { return false }
        let base = x * (height + 1)
        return sums[base + b] > sums[base + a]
    }

    private func inRow(_ sums: [UInt16], _ y: Int, _ a: Int, _ b: Int) -> Bool {
        guard y >= 0, y < height else { return false }
        let a = max(0, a), b = min(width, b)
        guard b > a else { return false }
        let base = y * (width + 1)
        return sums[base + b] > sums[base + a]
    }

    /// 竖着的边在 x 附近有没有东西的边沿（span：这条边的 y 范围）。返回吸到的 x。
    /// 两边都算：贴着东西的左沿或右沿都吸，东西框进来、留在外面都可以
    func boundaryVertical(_ x: CGFloat, span: ClosedRange<CGFloat>, threshold: CGFloat) -> CGFloat? {
        let a = Int(span.lowerBound.rounded(.down)), b = Int(span.upperBound.rounded(.up))
        // 边界 c 在第 c-1 列和第 c 列之间：这里左右变了
        let gap = { (c: Int) in self.inColumn(self.colH, c - 1, a, b) }
        // 第 from…to 列都是空的：列里上下没变化，列和列之间左右也没变化
        let flat = { (from: Int, to: Int) -> Bool in
            for x in from...to where self.inColumn(self.colV, x, a, b) { return false }
            if to > from { for x in from..<to where self.inColumn(self.colH, x, a, b) { return false } }
            return true
        }
        return boundary(x, size: b - a, limit: width, threshold: threshold, gap: gap, flat: flat)
    }

    func boundaryHorizontal(_ y: CGFloat, span: ClosedRange<CGFloat>, threshold: CGFloat) -> CGFloat? {
        let a = Int(span.lowerBound.rounded(.down)), b = Int(span.upperBound.rounded(.up))
        // 边界 c 在第 c-1 行和第 c 行之间
        let gap = { (c: Int) in self.inRow(self.rowV, c, a, b) }
        let flat = { (from: Int, to: Int) -> Bool in
            for y in from...to where self.inRow(self.rowH, y, a, b) { return false }
            if to > from { for y in (from + 1)...to where self.inRow(self.rowV, y, a, b) { return false } }
            return true
        }
        return boundary(y, size: b - a, limit: height, threshold: threshold, gap: gap, flat: flat)
    }

    /// 在 v 附近找东西的边沿，离 v 最近的那个：这里亮度变了，而且有一边空够 clearance 格
    /// （东西的左沿：左边空；右沿：右边空）。空够几格才不会吸到字的中间、图案的缝里
    private func boundary(_ v: CGFloat, size: Int, limit: Int, threshold: CGFloat,
                          gap: (Int) -> Bool, flat: (Int, Int) -> Bool) -> CGFloat? {
        guard size >= 2 else { return nil }
        let k = Self.clearance
        let lo = max(k, Int((v - threshold).rounded(.down))), hi = min(limit - k, Int((v + threshold).rounded(.up)))
        guard lo <= hi else { return nil }
        var best: (c: Int, d: CGFloat)?
        for c in lo...hi {
            let d = abs(CGFloat(c) - v)
            guard d <= threshold, best == nil || d < best!.d, gap(c) else { continue }
            if flat(c - k, c - 1) || flat(c, c + k - 1) { best = (c, d) }
        }
        return best.map { CGFloat($0.c) }
    }
}
