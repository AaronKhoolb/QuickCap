import AppKit
import Vision

/// 用系统 Vision 框架离线识别文字，支持简体、繁体中文和英文。
enum TextRecognizer {
    /// 识别模型平时由系统缓存，加载好后一次只要零点几秒；但系统有时会把它清掉，
    /// 下一次就要重新加载（实测 13 到 39 秒）。启动时、每次打开截图界面时都在后台先认一张小图，
    /// 简体、繁体、英文都有，让模型提前加载好
    static func warmUp() {
        // 最近几分钟刚认过（或刚预热过）：模型还在，不用再跑一遍（以前每次打开截图界面都在后台认一张图）
        if let last = lastUsed, Date().timeIntervalSince(last) < 180 { return }
        lastUsed = Date()
        let lines = ["Screenshot capture test", "截图识别中文测试", "繁體中文辨識測試", "Mixed 混合 text 2026"]
        let size = CGSize(width: 460, height: CGFloat(lines.count) * 40 + 12)
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for (i, l) in lines.enumerated() {
            (l as NSString).draw(at: CGPoint(x: 10, y: size.height - CGFloat(i + 1) * 40),
                                 withAttributes: [.font: NSFont.systemFont(ofSize: 24)])
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let img = ctx.makeImage() else { return }
        let start = Date()
        run(VNImageRequestHandler(cgImage: img), qos: .utility, options: Options()) { _ in warmUpSeconds = Date().timeIntervalSince(start) }
    }

    /// 调试用：预热花了多久、最近一次识别花了多久、图多大
    @MainActor static var warmUpSeconds: Double?
    @MainActor static var lastRun: String?

    /// 怎么认：哪种语言、保不保留换行（设置里 Scan 那一页）
    struct Options: Sendable {
        /// "auto" 或 Vision 的语言代码
        var language = "auto"
        var keepLineBreaks = true
        @MainActor static var current: Options {
            Options(language: AppSettings.shared.scanLanguage, keepLineBreaks: AppSettings.shared.scanKeepLineBreaks)
        }
    }

    /// 能选的语言（Vision 支持的，按英文名排；界面是英文的）
    static let languages: [(code: String, name: String)] = {
        let codes = (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? ["en-US", "zh-Hans", "zh-Hant"]
        let en = Locale(identifier: "en")
        return codes.map { ($0, en.localizedString(forIdentifier: $0) ?? $0) }.sorted { $0.1 < $1.1 }
    }()

    /// 识别一个图片文件（截图架卡片上的按钮用）
    @MainActor static func recognize(url: URL, completion: @escaping @MainActor (Result<String, Error>) -> Void) {
        run(VNImageRequestHandler(url: url), options: .current, completion: completion)
    }

    /// 识别一张图（Text 模式框选的那一块）
    /// 上一次用识别模型（预热或真的认）的时间
    nonisolated(unsafe) static var lastUsed: Date?

    @MainActor static func recognize(image: CGImage, qos: DispatchQoS.QoSClass = .userInitiated,
                                     completion: @escaping @MainActor (Result<String, Error>) -> Void) {
        lastUsed = Date()
        run(VNImageRequestHandler(cgImage: image), qos: qos, options: .current, completion: completion)
    }

    private static func run(_ handler: VNImageRequestHandler, qos: DispatchQoS.QoSClass = .userInitiated, options: Options,
                            completion: @escaping @MainActor (Result<String, Error>) -> Void) {
        nonisolated(unsafe) let handler = handler
        let started = Date()
        DispatchQueue.global(qos: qos).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            if options.language == "auto" {
                request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
                // 中文排在前面时，大图里的英文会按中文模型认，容易认错（QuickCap 认成 OuickCap）。
                // 让它自己判断每段是什么语言就都对了
                request.automaticallyDetectsLanguage = true
            } else {
                request.recognitionLanguages = [options.language]
                request.automaticallyDetectsLanguage = false
            }
            let result: Result<String, Error>
            do {
                try handler.perform([request])
                let text = lines(request.results ?? [])
                result = .success(options.keepLineBreaks ? text : joined(text))
            } catch {
                result = .failure(error)
            }
            let secs = Date().timeIntervalSince(started)
            DispatchQueue.main.async { MainActor.assumeIsolated {
                lastRun = String(format: "%.2fs", secs)
                completion(result)
            } }
        }
    }

    /// 按阅读顺序排：先把高度上重叠的片段归成一行（从上到下），每行里从左到右。
    /// 同一行里的片段用空格接，中文和中文之间不加空格
    static func lines(_ obs: [VNRecognizedTextObservation]) -> String {
        let items = obs.compactMap { o -> (CGRect, String)? in
            guard let s = o.topCandidates(1).first?.string, !s.isEmpty else { return nil }
            return (o.boundingBox, s)
        }.sorted { $0.0.maxY > $1.0.maxY } // Vision 坐标 y 向上
        var rows: [(midY: CGFloat, height: CGFloat, parts: [(CGRect, String)])] = []
        for it in items {
            if let i = rows.firstIndex(where: { abs($0.midY - it.0.midY) < min($0.height, it.0.height) * 0.5 }) {
                rows[i].parts.append(it)
            } else {
                rows.append((it.0.midY, it.0.height, [it]))
            }
        }
        var text = ""
        for (i, row) in rows.enumerated() {
            let parts = row.parts.sorted { $0.0.minX < $1.0.minX }.map(\.1)
            var out = ""
            for p in parts {
                if let last = out.last, let first = p.first, !(isCJK(last) && isCJK(first)) { out += " " }
                out += p
            }
            if i > 0 {
                // 和上一行之间空得比一行字还多：是换了一段，空一行（以前段落之间不留空）
                let prev = rows[i - 1]
                let gap = (prev.midY - prev.height / 2) - (row.midY + row.height / 2)
                text += gap > max(prev.height, row.height) * 0.8 ? "\n\n" : "\n"
            }
            text += out
        }
        return text
    }

    /// 不保留换行：一段里的行接成一行，段落之间还是空一行。两边都是中日韩文字才不加空格，别的都加一个。
    /// 行尾是连字符、下一行小写开头：接起来是一个词（inter- national）就去掉连字符；
    /// 本来就是带连字符的词（well- known，两半各自是词、接起来不是）就留着
    static func joined(_ text: String) -> String {
        text.components(separatedBy: "\n\n").map(joinParagraph).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static func joinParagraph(_ text: String) -> String {
        var out = ""
        for line in text.components(separatedBy: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty else { continue }
            guard let last = out.last, let first = l.first else { out += l; continue }
            if last == "-", first.isLowercase, out.dropLast().last?.isLetter == true {
                let head = String(out.dropLast().reversed().prefix { $0.isLetter }.reversed()).lowercased()
                let tail = String(l.prefix { $0.isLetter }).lowercased()
                let keep = !words.contains(head + tail) && words.contains(head) && words.contains(tail)
                if !keep { out.removeLast() }
                out += l
                continue
            }
            out += isCJK(last) && isCJK(first) ? "" : " "
            out += l
        }
        return out
    }

    /// 系统自带的英文词表（判断连字符要不要留）
    private static let words: Set<String> = {
        guard let s = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        return Set(s.split(separator: "\n").map { $0.lowercased() })
    }()

    private static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x3000...0x9FFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
    }
}
