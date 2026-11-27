import AppKit
import Vision

/// 截图架搜索：哪张图里有这些字，问系统的 Spotlight 索引（和访达搜索同一份，系统自己在后台认图里的字），
/// QuickCap 不再自己把整个文件夹认一遍、也不在磁盘上存任何东西。
/// 系统认图要等电脑空闲，刚截的那几张还没认到：这次运行里截的图，截好时 QuickCap 自己认一次，只放在内存里。
/// 对上的图要框出字在哪里（系统只告诉哪张对上，不给位置）：只认对上的那几张，结果也只放内存
@MainActor
final class ShelfTextIndex {
    static let shared = ShelfTextIndex()

    /// 一张图里认出来的一行字，和它在图里的位置（0…1，原点左下，和 Vision 一样）
    struct Line { let text: String; let box: CGRect }
    private struct Entry { let modified: Double; let lines: [Line]; let folded: [String]; let all: String }

    /// 内存里认过的：这次截的图，和搜索时对上、要框位置的图。最多留这么多张
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private static let keepLimit = 200
    /// 这次运行里截的图（系统还没认到也能搜）
    private var recent = Set<String>()
    /// 认好了一张、或者系统搜完了（搜索结果要更新）
    var onIndexed: (() -> Void)?

    private init() {
        // 以前自己存在磁盘上的字（现在不用了）
        let old = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuickCap/text-index.json")
        DispatchQueue.global(qos: .background).async { try? FileManager.default.removeItem(at: old) }
    }

    // MARK: 截图架里有哪些图

    private var alive: [String: Double] = [:]
    private var scopes: [URL] = []

    /// 截图架里现在的图：记住在哪些文件夹（系统搜索只搜这几个），不在了的从内存里去掉
    func enqueue(_ items: [ShelfItem]) {
        alive = Dictionary(items.map { ($0.url.standardizedFileURL.path, $0.modified.timeIntervalSinceReferenceDate) },
                           uniquingKeysWith: { a, _ in a })
        let dirs = Set(items.map { $0.url.deletingLastPathComponent().standardizedFileURL })
        if dirs != Set(scopes) { scopes = Array(dirs); lastSystemQuery = nil }
        for k in entries.keys where alive[k] == nil { drop(k) }
        evicted = evicted.filter { alive[$0.key] != nil }
        recent = recent.filter { alive[$0] != nil }
    }

    /// 文件搬了位置（换截图文件夹时）：认过的字跟着换到新路径
    func remap(_ moved: [(from: URL, to: URL)]) {
        for m in moved {
            let from = m.from.standardizedFileURL.path, to = m.to.standardizedFileURL.path
            if let e = entries.removeValue(forKey: from) { entries[to] = e; order = order.map { $0 == from ? to : $0 } }
            if recent.remove(from) != nil { recent.insert(to) }
        }
        lastSystemQuery = nil
    }

    /// 刚截好的这张：马上认（系统要等很久才认到）
    func prioritize(_ item: ShelfItem) {
        let key = item.url.standardizedFileURL.path
        recent.insert(key)
        recognize(item.url, modified: item.modified.timeIntervalSinceReferenceDate)
    }

    // MARK: 认字（只认需要的那几张）

    private var running = Set<String>()
    /// 最多两张同时认（每张都整图解码，一次全丢出去会占满所有核）
    nonisolated private static let workQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()
    /// 认过、因为内存放不下被挤掉的（路径 → 修改时间）：搜索时不再重认，不然命中多于上限时认一张挤一张、永远认不完
    private var evicted: [String: Double] = [:]
    /// 还有几张在认（搜索条上显示"还在找"）
    var pending: Int { running.count + (systemQuery?.isGathering == true ? 1 : 0) }

    private func recognize(_ url: URL, modified: Double) {
        let key = url.standardizedFileURL.path
        guard entries[key]?.modified != modified, !running.contains(key) else { return }
        running.insert(key)
        Self.workQueue.addOperation {
            let lines = Self.recognizeLines(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.running.remove(key)
                    let folded = lines.map { Self.fold($0.text) }
                    self.store(key, Entry(modified: modified, lines: lines, folded: folded, all: folded.joined(separator: " ")))
                    self.notifyIndexed()
                }
            }
        }
    }

    private func store(_ key: String, _ e: Entry) {
        entries[key] = e
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > Self.keepLimit, let k = order.first {
            // 这次截的图留着（系统可能还没认到）
            if recent.contains(k) { order.removeFirst(); order.append(k); if order.allSatisfy(recent.contains) { break }; continue }
            drop(k)
        }
    }

    private func drop(_ k: String) {
        if let m = entries[k]?.modified { evicted[k] = m }
        entries.removeValue(forKey: k)
        order.removeAll { $0 == k }
    }

    nonisolated private static func recognizeLines(_ url: URL) -> [Line] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        req.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(url: url).perform([req])
        return (req.results ?? []).compactMap { o in
            guard let s = o.topCandidates(1).first?.string, !s.isEmpty else { return nil }
            return Line(text: s, box: o.boundingBox)
        }
    }

    /// 好几张一起认好时合起来通知，最多 0.3 秒一次（不然搜索结果每张都整个重算一遍）
    private var notifyWork: DispatchWorkItem?
    private func notifyIndexed() {
        guard notifyWork == nil else { return }
        let w = DispatchWorkItem { [weak self] in
            self?.notifyWork = nil
            self?.onIndexed?()
        }
        notifyWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    /// 以前退出时要把字写进磁盘；现在什么都不存
    func flush() {}

    // MARK: 问系统

    private var systemQuery: NSMetadataQuery?
    private var lastSystemQuery: String?
    private var systemHits = Set<String>()
    private var queryWork: DispatchWorkItem?
    private var gatherObserver: NSObjectProtocol?

    /// 搜索词变了：停一下（打字时不是每个字都去问），再问系统哪些图里有这些字
    private func askSystem(_ words: [String], query: String) {
        guard query != lastSystemQuery else { return }
        lastSystemQuery = query
        queryWork?.cancel()
        systemQuery?.stop()
        systemQuery = nil
        systemHits = []
        guard !words.isEmpty, !scopes.isEmpty else { return }
        let w = DispatchWorkItem { [weak self] in self?.startQuery(words) }
        queryWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
    }

    private func startQuery(_ words: [String]) {
        let q = NSMetadataQuery()
        // 和访达一样：每个词都要在（文件名、图里认出的字……）任何一处出现，按词开头对，不分大小写、重音
        let parts = words.map { w -> String in
            let e = w.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "*", with: "\\*")
            return "(** == \"\(e)*\"cdw)"
        }
        q.predicate = NSPredicate(fromMetadataQueryString: parts.joined(separator: " && "))
        q.searchScopes = scopes
        if let o = gatherObserver { NotificationCenter.default.removeObserver(o) }
        gatherObserver = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, let q = n.object as? NSMetadataQuery, self.systemQuery === q else { return }
                if let o = self.gatherObserver { NotificationCenter.default.removeObserver(o); self.gatherObserver = nil }
                q.disableUpdates()
                var hits = Set<String>()
                for i in 0..<q.resultCount {
                    if let p = (q.result(at: i) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String {
                        hits.insert(URL(fileURLWithPath: p).standardizedFileURL.path)
                    }
                }
                q.stop()
                self.systemHits = hits
                self.onIndexed?()
            }
        }
        systemQuery = q
        q.start()
    }

    // MARK: 搜

    private var lastQuery: (query: String, words: [String]) = ("", [])

    /// 这张图对不对得上。对上了返回字在图里的位置（还没认出位置时是空的，卡片照样算对上）
    func match(_ url: URL, query: String) -> [CGRect]? {
        if lastQuery.query != query { lastQuery = (query, Self.words(query)) }
        let words = lastQuery.words
        guard !words.isEmpty else { return nil }
        askSystem(words, query: query)
        let key = url.standardizedFileURL.path
        // 内存里认过的：直接对（这次截的图靠这个）
        if let e = entries[key], e.modified == alive[key] ?? e.modified, words.allSatisfy({ e.all.contains($0) }) {
            return zip(e.lines, e.folded).filter { _, t in words.contains { t.contains($0) } }.map(\.0.box)
        }
        // 系统说对上了：先算对上，后台认一下这张好框出位置
        guard systemHits.contains(key) else { return nil }
        if entries[key] == nil, let m = alive[key], evicted[key] != m { recognize(url, modified: m) }
        return []
    }

    private static func words(_ q: String) -> [String] {
        fold(q).split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    // 调试用
    var debugText: String { "memory=\(entries.count) recent=\(recent.count) systemHits=\(systemHits.count) pending=\(pending)" }
}
