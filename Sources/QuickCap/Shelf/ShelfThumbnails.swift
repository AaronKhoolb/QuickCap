import AppKit
import ImageIO
import QuickLookThumbnailing

final class LockedInt: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func get() -> Int { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Int) { lock.lock(); value = v; lock.unlock() }
}

private struct UnsafeSend<T>: @unchecked Sendable {
    let value: T
    init(_ v: T) { value = v }
}

/// 卡片缩略图：后台用 ImageIO 直接生成小图，不解码原图，按文件路径 + 修改时间缓存。
/// 绳子上可能有上千张截图，只有屏幕附近的卡片才会来要图，划过去的会取消。
@MainActor
final class ShelfThumbnails {
    /// 卡片最宽 156pt，Retina 下按 2 倍再留点余量
    nonisolated static let maxPixel = 400

    final class Token {
        fileprivate let key: String
        fileprivate var cancelled = false
        fileprivate let completion: (CGImage) -> Void
        fileprivate init(key: String, completion: @escaping (CGImage) -> Void) {
            self.key = key
            self.completion = completion
        }
    }

    private final class Job {
        let operation: BlockOperation
        var waiters: [Token] = []
        init(operation: BlockOperation) { self.operation = operation }
    }

    private let cache = NSCache<NSString, CGImage>()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "QuickCap.ShelfThumbnails"
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .userInitiated
        return q
    }()
    private var jobs: [String: Job] = [:]

    init() {
        // 约 120MB：每张 400px 的图大约 0.5MB，够缓存两三百张
        cache.totalCostLimit = 120 * 1024 * 1024
    }

    func cached(_ key: String) -> CGImage? { cache.object(forKey: key as NSString) }

    // MARK: 卡片图（用系统的缩略图，和访达共用一份缓存）
    //
    // 系统 QuickLook 给每个文件做的缩略图本来就存着（访达、"预览"都用这一份），第二次拿只要 0–2ms，
    // 换个 app 来拿也一样快，我们自己不用再存一份。拿到后在后台按卡片大小裁好、切圆角（约 1ms），放在内存里

    /// 卡片图的键：文件 + 修改时间 + 卡片多大（像素）
    nonisolated static func cardKey(_ item: ShelfItem, size: CGSize, scale: CGFloat) -> String {
        "\(item.thumbnailKey)|\(Int((size.width * scale).rounded()))x\(Int((size.height * scale).rounded()))"
    }

    /// 以前自己存在磁盘上的卡片图（现在不用了）：删掉
    nonisolated static func removeOldDiskCache() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "QuickCap", isDirectory: true)
            .appendingPathComponent("CardThumbnails", isDirectory: true)
        try? FileManager.default.removeItem(at: base)
    }

    /// 向系统要缩略图（铺满卡片要裁掉一部分，所以要的比卡片大一点）。系统给不了就自己用 ImageIO 做
    nonisolated static func systemThumbnail(_ url: URL, size: CGSize, scale: CGFloat, completion: @escaping @Sendable (CGImage?) -> Void) {
        let long = max(size.width, size.height) * 1.6
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: long, height: long), scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            completion(rep?.cgImage ?? makeThumbnail(url))
        }
    }

    /// 截图架里的图提前做好卡片图放进内存（从最新的开始，一张接一张，在后台、低优先级）：
    /// 滚到哪里卡片都马上有图，不会一边滑一边解码 HEIC、一张张淡入（第一次滑过时会卡、像拖影）。
    /// 内存里放得下的那些（最前面 warmLimit 张）做成卡片图；再往后的只让系统先做好缩略图（存在系统自己的缓存里）
    private var prefetched = Set<String>()
    private var warmGeneration = 0
    /// 后台线程看的"现在是第几轮"（加锁，不用回主线程问）
    private let warmGenerationBox = LockedInt()
    nonisolated static let warmLimit = 150
    func prefetch(_ items: [ShelfItem], scale: CGFloat) {
        warmGeneration += 1
        let gen = warmGeneration
        let jobs: [(item: ShelfItem, size: CGSize, key: String, warm: Bool)] = items.enumerated().compactMap { i, it in
            let size = Metrics.cardSize(for: it.pixelSize)
            let key = Self.cardKey(it, size: size, scale: scale)
            let warm = i < Self.warmLimit
            if warm ? cached(key) != nil : !prefetched.insert(it.thumbnailKey).inserted { return nil }
            return (it, size, key, warm)
        }
        guard !jobs.isEmpty else { return }
        let generation = warmGenerationBox
        generation.set(gen)
        nonisolated(unsafe) let cache = self.cache
        DispatchQueue.global(qos: .utility).async {
            for j in jobs {
                // 截图架又换了一批（文件夹又扫了一次）：这一轮不做了，新的那轮接着做。
                // 不回主线程问（以前每张都同步问一次主线程：滑动时主线程被打断，偶尔晚一帧）
                if generation.get() != gen { return }
                if j.warm && cache.object(forKey: j.key as NSString) != nil { continue }
                let sem = DispatchSemaphore(value: 0)
                nonisolated(unsafe) var result: CGImage?
                Self.systemThumbnail(j.item.url, size: j.size, scale: scale) { t in
                    if j.warm { result = t.flatMap { Self.cardImage($0, size: j.size, corner: max(Metrics.cardCorner - Metrics.framePadding, 0), scale: scale) } }
                    sem.signal()
                }
                sem.wait()
                if let img = result {
                    let box = UnsafeSend(img)
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.finish(j.key, image: box.value) } }
                }
            }
        }
    }

    /// 卡片要的图（已经是卡片大小、圆角）。内存里有就马上给；没有就向系统要缩略图、在后台裁好
    func loadCard(_ item: ShelfItem, size: CGSize, scale: CGFloat, completion: @escaping (CGImage) -> Void) -> Token? {
        let key = Self.cardKey(item, size: size, scale: scale)
        if let image = cached(key) { completion(image); return nil }
        let token = Token(key: key, completion: completion)
        if let job = jobs[key] { job.waiters.append(token); return token }
        let op = BlockOperation()
        let url = item.url
        op.addExecutionBlock { [weak op] in
            guard op?.isCancelled == false else { return }
            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var result: CGImage?
            Self.systemThumbnail(url, size: size, scale: scale) { t in
                result = t.flatMap { Self.cardImage($0, size: size, corner: max(Metrics.cardCorner - Metrics.framePadding, 0), scale: scale) }
                sem.signal()
            }
            sem.wait()
            let image = result
            DispatchQueue.main.async { MainActor.assumeIsolated { self.finish(key, image: image) } }
        }
        let job = Job(operation: op)
        job.waiters.append(token)
        jobs[key] = job
        queue.addOperation(op)
        return token
    }

    /// 刚截好的图：直接做成卡片图放进内存（卡片不用等）
    func storeCard(from image: CGImage, item: ShelfItem, size: CGSize, scale: CGFloat) {
        let key = Self.cardKey(item, size: size, scale: scale)
        guard let img = Self.cardImage(image, size: size, corner: max(Metrics.cardCorner - Metrics.framePadding, 0), scale: scale) else { return }
        store(img, key: key)
    }

    /// 没有缓存时在后台生成，完成后在主线程回调。返回的 token 用来在格子复用时取消。
    func load(_ url: URL, key: String, completion: @escaping (CGImage) -> Void) -> Token? {
        if let image = cached(key) {
            completion(image)
            return nil
        }
        let token = Token(key: key, completion: completion)
        if let job = jobs[key] {
            job.waiters.append(token)
            return token
        }
        let op = BlockOperation()
        op.addExecutionBlock { [weak op] in
            guard op?.isCancelled == false else { return }
            let image = ShelfThumbnails.makeThumbnail(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finish(key, image: image) }
            }
        }
        let job = Job(operation: op)
        job.waiters.append(token)
        jobs[key] = job
        queue.addOperation(op)
        return token
    }

    func cancel(_ token: Token?) {
        guard let token, !token.cancelled else { return }
        token.cancelled = true
        guard let job = jobs[token.key] else { return }
        job.waiters.removeAll { $0 === token }
        // 快速滚动时，划过去的格子不再占着队列
        if job.waiters.isEmpty {
            job.operation.cancel()
            jobs[token.key] = nil
        }
    }

    private func finish(_ key: String, image: CGImage?) {
        guard let job = jobs.removeValue(forKey: key) else {
            if let image { store(image, key: key) }
            return
        }
        guard let image else { return }
        store(image, key: key)
        for t in job.waiters where !t.cancelled { t.completion(image) }
    }

    /// 也给刚截的图用：内存里已经有图，直接放进缓存，卡片不用等后台生成
    func store(_ image: CGImage, key: String) {
        cache.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
    }

    /// 卡片上直接用的那张：按卡片大小裁好（铺满）、四个角切成圆角、外面一圈细边，都画进同一张图。
    /// 这样图层不用 masksToBounds + cornerRadius 去切（那样每一帧系统都要多画一遍，滚动时 WindowServer 很忙、会卡）
    nonisolated static func cardImage(_ img: CGImage, size: CGSize, corner: CGFloat, scale: CGFloat) -> CGImage? {
        let w = max(1, Int((size.width * scale).rounded())), h = max(1, Int((size.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let r = CGRect(x: 0, y: 0, width: w, height: h)
        let c = corner * scale
        let path = CGPath(roundedRect: r, cornerWidth: c, cornerHeight: c, transform: nil)
        ctx.interpolationQuality = .high
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        let k = max(CGFloat(w) / iw, CGFloat(h) / ih)
        ctx.draw(img, in: CGRect(x: (CGFloat(w) - iw * k) / 2, y: (CGFloat(h) - ih * k) / 2, width: iw * k, height: ih * k))
        ctx.restoreGState()
        // 一圈很细的内描边，图片边缘颜色和背景接近时也有清楚的轮廓
        let line = 0.5 * scale
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: line / 2, dy: line / 2), cornerWidth: c - line / 2, cornerHeight: c - line / 2, transform: nil))
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.10))
        ctx.setLineWidth(line)
        ctx.strokePath()
        return ctx.makeImage()
    }

    nonisolated private static func makeThumbnail(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // 在后台线程就解码好，主线程显示时不卡
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
