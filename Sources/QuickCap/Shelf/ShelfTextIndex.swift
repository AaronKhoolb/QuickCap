import AppKit
import Vision

/// 截图里的字（截图架搜索用）。在本机认，不联网；认过的存起来（按"路径 + 修改时间"），下次不用再认。
/// 新截的图存好后马上认；文件夹里以前的图在后台慢慢认（一次一张，优先级很低，不影响截图）
@MainActor
final class ShelfTextIndex {
    static let shared = ShelfTextIndex()

    /// 一张图里认出来的一行字，和它在图里的位置（0…1，原点左下，和 Vision 一样）
    struct Line: Codable { let text: String; let box: CGRect }
    private struct Entry: Codable { let modified: Double; let lines: [Line] }

    private var entries: [String: Entry] = [:]
    private var queue: [ShelfItem] = []
    private var running = false
    private var saveWork: DispatchWorkItem?
    /// 认好了一张（搜索结果要更新）
    var onIndexed: (() -> Void)?

    private let file: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuickCap", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("text-index.json")
    }()

    private init() {
        if let d = try? Data(contentsOf: file), let e = try? JSONDecoder().decode([String: Entry].self, from: d) { entries = e }
    }

    /// 还有几张没认
    var pending: Int { queue.count + (running ? 1 : 0) }

    /// 这些图里没认过的排进去认（新的在前面）
    func enqueue(_ items: [ShelfItem]) {
        let known = Set(queue.map(\.url))
        for it in items where !isIndexed(it) && !known.contains(it.url) { queue.append(it) }
        // 不在截图架里的图，记录删掉
        let alive = Set(items.map(\.url.path))
        if !items.isEmpty, entries.keys.contains(where: { !alive.contains($0) }) {
            entries = entries.filter { alive.contains($0.key) }
            folded = folded.filter { alive.contains($0.key) }
            scheduleSave()
        }
        runNext()
    }

    /// 文件搬了位置（换截图文件夹时）：认过的字跟着换到新路径，不用重新认
    func remap(_ moved: [(from: URL, to: URL)]) {
        guard !moved.isEmpty else { return }
        for m in moved {
            let from = m.from.standardizedFileURL.path
            folded.removeValue(forKey: from)
            if let e = entries.removeValue(forKey: from) { entries[m.to.standardizedFileURL.path] = e }
        }
        scheduleSave()
    }

    /// 刚截好的这张放最前面认
    func prioritize(_ item: ShelfItem) {
        queue.removeAll { $0.url == item.url }
        if !isIndexed(item) { queue.insert(item, at: 0) }
        runNext()
    }

    private func isIndexed(_ it: ShelfItem) -> Bool {
        entries[it.url.path]?.modified == it.modified.timeIntervalSinceReferenceDate
    }

    private func runNext() {
        guard !running, !queue.isEmpty else { return }
        running = true
        let it = queue.removeFirst()
        let url = it.url, modified = it.modified.timeIntervalSinceReferenceDate
        DispatchQueue.global(qos: .utility).async {
            let lines = Self.recognize(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.entries[url.path] = Entry(modified: modified, lines: lines)
                    self.running = false
                    self.scheduleSave()
                    self.notifyIndexed()
                    self.runNext()
                }
            }
        }
    }

    nonisolated private static func recognize(_ url: URL) -> [Line] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        req.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(url: url)
        try? handler.perform([req])
        return (req.results ?? []).compactMap { o in
            guard let s = o.topCandidates(1).first?.string, !s.isEmpty else { return nil }
            return Line(text: s, box: o.boundingBox)
        }
    }

    /// 认好一张就通知一次的话，后台一张张认时搜索结果每张都整个重算一遍：合起来，最多半秒一次
    private var notifyWork: DispatchWorkItem?
    private func notifyIndexed() {
        guard notifyWork == nil else { return }
        let w = DispatchWorkItem { [weak self] in
            self?.notifyWork = nil
            self?.onIndexed?()
        }
        notifyWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = entries, file = file
        let w = DispatchWorkItem {
            DispatchQueue.global(qos: .utility).async {
                if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: file, options: .atomic) }
            }
        }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    // MARK: 搜

    /// 这张图对不对得上（每个词都要在图里出现，不分大小写、全角半角）。对上的那几行的位置
    /// 每敲一个字都要对一遍所有截图：处理好（转小写、去全角）的字记住，同一个搜索词也只拆一次。
    /// 以前每次都把每张图的字重新拼起来、重新处理，截图多了打字会卡
    private var folded: [String: (modified: Double, all: String, lines: [String])] = [:]
    private var lastQuery: (query: String, words: [String]) = ("", [])

    func match(_ url: URL, query: String) -> [CGRect]? {
        if lastQuery.query != query { lastQuery = (query, Self.words(query)) }
        let words = lastQuery.words
        let key = url.standardizedFileURL.path
        guard !words.isEmpty, let e = entries[key] else { return nil }
        let f: (modified: Double, all: String, lines: [String])
        if let c = folded[key], c.modified == e.modified { f = c } else {
            let lines = e.lines.map { Self.fold($0.text) }
            f = (e.modified, lines.joined(separator: " "), lines)
            folded[key] = f
        }
        guard words.allSatisfy({ f.all.contains($0) }) else { return nil }
        return zip(e.lines, f.lines).filter { _, t in words.contains { t.contains($0) } }.map(\.0.box)
    }

    private static func words(_ q: String) -> [String] {
        fold(q).split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    // 调试用
    var debugText: String { "indexed=\(entries.count) pending=\(pending)" }
}
