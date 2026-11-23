import Foundation

/// 在设置里换了"Save to"文件夹时，把旧文件夹里 QuickCap 自己存的截图搬到新文件夹。
/// 只认我们自己的文件名（"QuickCap 2026-11-20 at 07.40.12.png"，改名前的 "Hangshot …" 也算，重名带数字的也算）：
/// 旧文件夹是桌面、文档时，里面别的图片一张都不碰。
/// 只依赖 Foundation，方便单独测试
enum FolderMigration {
    /// 一次搬的结果：搬成功的（旧路径 → 新路径）、没搬成的张数
    struct Result {
        var moved: [(from: URL, to: URL)] = []
        var failed = 0
    }

    private static let namePattern = try! NSRegularExpression(
        pattern: #"^(QuickCap|Hangshot) \d{4}-\d{2}-\d{2} at \d{2}\.\d{2}\.\d{2}( \d+)?\.(png|heic|heif|jpg|jpeg)$"#)

    static func isOurs(_ name: String) -> Bool {
        namePattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    /// 旧文件夹里有哪些是我们的截图。同一个文件夹、旧文件夹不存在：空
    static func candidates(in old: URL, movingTo new: URL) -> [URL] {
        // 两个路径其实是同一个文件夹（符号链接，比如 /tmp 和 /private/tmp）：不搬，不然每张都会被改名加数字
        guard old.resolvingSymlinksInPath().standardizedFileURL.path
                != new.resolvingSymlinksInPath().standardizedFileURL.path else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(at: old, includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])) ?? []
        return urls.filter { isOurs($0.lastPathComponent) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 搬。不覆盖：新文件夹里已经有同名的，新搬来的加数字。同一个磁盘上是改名（瞬间）、不同磁盘是复制再删
    static func move(_ files: [URL], to new: URL) -> Result {
        let fm = FileManager.default
        try? fm.createDirectory(at: new, withIntermediateDirectories: true)
        var r = Result()
        for src in files {
            let dst = freeURL(for: src.lastPathComponent, in: new)
            do {
                try fm.moveItem(at: src, to: dst)
                r.moved.append((src, dst))
            } catch {
                r.failed += 1
            }
        }
        return r
    }

    /// 新文件夹里这个名字没被占：原名；被占了：在扩展名前加 " 2"、" 3"…
    private static func freeURL(for name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        let first = folder.appendingPathComponent(name)
        if !fm.fileExists(atPath: first.path) { return first }
        let ns = name as NSString
        let base = ns.deletingPathExtension, ext = ns.pathExtension
        var n = 2
        while true {
            let u = folder.appendingPathComponent("\(base) \(n).\(ext)")
            if !fm.fileExists(atPath: u.path) { return u }
            n += 1
        }
    }
}
