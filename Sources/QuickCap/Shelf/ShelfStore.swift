import Foundation

/// 保存置顶的文件和它们的顺序。绳子上挂哪些截图由文件夹决定，不用存。
/// 置顶的文件被删掉或移走时，恢复时直接跳过。
enum ShelfStore {
    private struct File: Codable {
        var version = 2
        /// 置顶的文件路径，按用户排的顺序
        var pinned: [String]
    }

    /// 旧版本（version 1）存的是整排卡片，只把置顶的拿出来
    private struct LegacyFile: Codable {
        struct Entry: Codable {
            var path: String
            var pinned: Bool
            var addedAt: Date
        }
        var version: Int
        var entries: [Entry]
    }

    /// nil 表示不保存（调试运行时用，免得把示例图存进真正的悬挂架）
    nonisolated(unsafe) static var url: URL? = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("QuickCap", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("shelf.json")
    }()

    /// 置顶的文件，按顺序
    static func loadPinned() -> [URL] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let f = try? decoder.decode(File.self, from: data), f.version >= 2 {
            return f.pinned.map { URL(fileURLWithPath: $0).standardizedFileURL }
        }
        if let old = try? decoder.decode(LegacyFile.self, from: data) {
            return old.entries.filter(\.pinned).map { URL(fileURLWithPath: $0.path).standardizedFileURL }
        }
        return []
    }

    /// 文件搬了位置（换截图文件夹时）：置顶记录里的路径跟着换成新的
    static func remapPinned(_ moved: [(from: URL, to: URL)]) {
        guard !moved.isEmpty else { return }
        var map: [String: URL] = [:]
        for m in moved { map[m.from.standardizedFileURL.path] = m.to.standardizedFileURL }
        let pinned = loadPinned()
        let fixed = pinned.map { map[$0.path] ?? $0 }
        if fixed != pinned { savePinned(fixed) }
    }

    static func savePinned(_ urls: [URL]) {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(File(pinned: urls.map(\.path))) else { return }
        do { try data.write(to: url, options: .atomic) } catch { NSLog("QuickCap: couldn't save pinned order: \(error)") }
    }
}
