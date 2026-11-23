import AppKit
import ImageIO

/// 扫描截图文件夹。只读文件头拿尺寸，不解码图片，上千张也很快。
/// 尺寸按"路径 + 修改时间"缓存，重新扫描时没变的文件不用再读。
final class ShelfScanner: @unchecked Sendable {
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "webp"]

    private let lock = NSLock()
    private var sizeCache: [String: (modified: Date, size: CGSize)] = [:]

    /// 读文件头拿像素尺寸。只在这里读磁盘
    static func pixelSize(of url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat,
              w > 0, h > 0
        else { return nil }
        return CGSize(width: w, height: h)
    }

    /// 扫描文件夹，按时间从新到旧。会读磁盘，不要在主线程调用
    func scan(_ folder: URL) -> [ShelfItem] {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .isRegularFileKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var items: [ShelfItem] = []
        items.reserveCapacity(urls.count)
        for url in urls where Self.extensions.contains(url.pathExtension.lowercased()) {
            let v = try? url.resourceValues(forKeys: Set(keys))
            guard v?.isRegularFile ?? true else { continue }
            // 刚开始写、还是 0 字节的文件先跳过，下次文件夹变化时再扫
            if let bytes = v?.fileSize, bytes == 0 { continue }
            let modified = v?.contentModificationDate ?? .distantPast
            let std = url.standardizedFileURL
            guard let size = cachedSize(std, modified: modified) else { continue }
            items.append(ShelfItem(url: std, date: v?.creationDate ?? modified, modified: modified, pixelSize: size))
        }
        // 同一秒的按文件名倒序，顺序才稳定
        items.sort { $0.date != $1.date ? $0.date > $1.date : $0.url.lastPathComponent > $1.url.lastPathComponent }
        return items
    }

    private func cachedSize(_ url: URL, modified: Date) -> CGSize? {
        let key = url.path
        lock.lock()
        let hit = sizeCache[key]
        lock.unlock()
        if let hit, hit.modified == modified { return hit.size }
        guard let size = Self.pixelSize(of: url) else { return nil }
        lock.lock()
        sizeCache[key] = (modified, size)
        lock.unlock()
        return size
    }

    /// 文件没了就把缓存清掉，不然缓存会一直长
    func forget(paths: Set<String>) {
        lock.lock()
        for p in paths { sizeCache.removeValue(forKey: p) }
        lock.unlock()
    }

    func knownPaths() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(sizeCache.keys)
    }
}

/// 盯着截图文件夹：有变化就在后台重扫一遍，扫完回主线程通知。
@MainActor
final class ShelfLibrary {
    let folder: URL
    private(set) var items: [ShelfItem] = []
    /// 扫描完成（内容有变化时才调）
    var onChange: (([ShelfItem]) -> Void)?

    private let scanner = ShelfScanner()
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var scanning = false
    private var rescanPending = false
    private var debounce: DispatchWorkItem?

    init(folder: URL) {
        self.folder = folder
    }

    deinit {
        source?.cancel()
    }

    func start() {
        rescan()
        watch()
    }

    /// 立刻重扫一遍（展开悬挂架、截完图时调）
    func rescan() {
        guard !scanning else { rescanPending = true; return }
        scanning = true
        let folder = folder
        let scanner = scanner
        DispatchQueue.global(qos: .userInitiated).async {
            let items = scanner.scan(folder)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finish(items) }
            }
        }
    }

    private func finish(_ scanned: [ShelfItem]) {
        scanning = false
        if scanned != items {
            // 文件没了的，尺寸缓存也清掉
            let gone = scanner.knownPaths().subtracting(scanned.map(\.url.path))
            if !gone.isEmpty { scanner.forget(paths: gone) }
            items = scanned
            onChange?(scanned)
        }
        if rescanPending { rescanPending = false; rescan() }
    }

    /// 文件夹里增删文件会触发；同一个文件被覆盖不一定触发，所以展开时也会重扫一次
    private func watch() {
        source?.cancel()
        if descriptor >= 0 { close(descriptor) }
        descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .extend], queue: .main)
        s.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = s.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // 文件夹本身被删了或改名：等它被重新建出来再盯
                self.source?.cancel()
                self.source = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self else { return }
                    try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
                    self.watch()
                    self.rescan()
                }
                return
            }
            // 连续写入时合并成一次扫描
            self.debounce?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.rescan() }
            self.debounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        s.setCancelHandler { [descriptor = self.descriptor] in
            if descriptor >= 0 { close(descriptor) }
        }
        descriptor = -1 // 交给 cancelHandler 关
        s.resume()
        source = s
    }
}

/// 日期气泡和刻度条上的文字。
@MainActor
enum ShelfDates {
    private static let locale = Locale(identifier: "en_US")

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = format
        return f
    }

    private static let weekday = formatter("EEEE")
    private static let monthDay = formatter("MMM d")
    private static let yearMonthDay = formatter("MMM d, y")

    /// 今天 / 昨天 / 一周内写星期几 / 今年写"11月3日" / 往年带年份
    static func title(for day: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let diff = cal.dateComponents([.day], from: day, to: today).day ?? 0
        if diff == 0 { return "Today" }
        if diff == 1 { return "Yesterday" }
        if diff > 1 && diff < 7 { return weekday.string(from: day) }
        return cal.isDate(day, equalTo: now, toGranularity: .year)
            ? monthDay.string(from: day) : yearMonthDay.string(from: day)
    }

    /// 气泡里的文字："今天"这种相对日期后面补上具体日期
    static func bubble(for day: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let t = title(for: day, now: now)
        let full = cal.isDate(day, equalTo: now, toGranularity: .year)
            ? monthDay.string(from: day) : yearMonthDay.string(from: day)
        return t == full ? "\(weekday.string(from: day)), \(full)" : "\(t) · \(full)"
    }
}
