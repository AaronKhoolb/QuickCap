import AppKit
import Vision

/// 选区里认出来的一个二维码或条形码。全部在本机认，不用联网
struct ScannedCode {
    enum Kind {
        case link(URL)
        case wifi(ssid: String, password: String?, hidden: Bool)
        case email(String, URL)
        case phone(String, URL)
        case message(String, URL)
        case location(String, URL)
        case contact(name: String, data: String)
        case event(title: String, data: String)
        /// 两步验证（otpauth://）：当场算出现在的验证码
        case oneTimeCode(OTPAccount)
        /// 视频会议（Zoom、Teams、Meet、FaceTime、Webex）
        case meeting(service: String, URL)
        /// App Store、TestFlight 的链接
        case appStore(title: String, testFlight: Bool, URL)
        /// 商品条码（EAN、UPC）、书号（ISBN）
        case product(code: String, isBook: Bool)
        /// 付款码（PayNow、DuitNow、PromptPay、微信、支付宝……）：电脑上付不了，只说是什么、收款方是谁
        case payment(service: String, detail: String?)
        /// 加密货币地址：只给复制，标清楚是哪种币
        case crypto(coin: String, address: String)
        case text(String)
    }

    let payload: String
    let kind: Kind
    /// 在选区里的位置（选区坐标，原点左下，单位 pt）
    var rect: CGRect
    let isQR: Bool

    init(payload: String, rect: CGRect, isQR: Bool) {
        self.payload = payload
        self.rect = rect
        self.isQR = isQR
        kind = Self.parse(payload)
    }

    init(payload: String, rect: CGRect, isQR: Bool, kind: Kind) {
        self.payload = payload
        self.rect = rect
        self.isQR = isQR
        self.kind = kind
    }

    /// 一个码拆成几项：Google Authenticator 的导出码里有好几个账号，每个账号一项（Tab 一个个看）
    static func expand(payload: String, rect: CGRect, isQR: Bool) -> [ScannedCode] {
        let t = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("otpauth-migration://"), let u = URL(string: t), let list = OTPAccount.migration(u) {
            return list.map { ScannedCode(payload: payload, rect: rect, isQR: isQR, kind: .oneTimeCode($0)) }
        }
        return [ScannedCode(payload: payload, rect: rect, isQR: isQR)]
    }

    // MARK: 认

    /// 在图里找码，按面积从大到小。size：选区的大小（pt），用来把位置换成选区坐标
    nonisolated static func detect(in image: CGImage, size: CGSize) async -> [ScannedCode] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let req = VNDetectBarcodesRequest()
                let handler = VNImageRequestHandler(cgImage: image)
                try? handler.perform([req])
                var seen = Set<String>()
                let found: [ScannedCode] = (req.results ?? []).compactMap { o in
                    guard let s = o.payloadStringValue, !s.isEmpty, seen.insert(s).inserted else { return nil }
                    let b = o.boundingBox
                    let r = CGRect(x: b.minX * size.width, y: b.minY * size.height, width: b.width * size.width, height: b.height * size.height)
                    return ScannedCode(payload: s, rect: r, isQR: o.symbology == .qr || o.symbology == .microQR)
                }
                // 先按码的面积排，再把导出码拆成一个个账号（拆出来的挨在一起）
                let sorted = found.sorted { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }
                cont.resume(returning: sorted.flatMap { expand(payload: $0.payload, rect: $0.rect, isQR: $0.isQR) })
            }
        }
    }

    // MARK: 内容是什么

    static func parse(_ s: String) -> Kind {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        if lower.hasPrefix("wifi:") { return wifi(t) }
        if lower.hasPrefix("mailto:"), let u = URL(string: t) {
            return .email(String(t.dropFirst(7)).components(separatedBy: "?")[0].removingPercentEncoding ?? "", u)
        }
        if lower.hasPrefix("matmsg:") {
            let f = fields(String(t.dropFirst(7)))
            if let to = f["TO"], let u = URL(string: "mailto:\(to)") { return .email(to, u) }
        }
        if lower.hasPrefix("tel:"), let u = URL(string: t.replacingOccurrences(of: " ", with: "")) { return .phone(String(t.dropFirst(4)), u) }
        if lower.hasPrefix("smsto:") || lower.hasPrefix("sms:") {
            let rest = t.split(separator: ":", maxSplits: 2).dropFirst().first.map(String.init) ?? ""
            if let u = URL(string: "sms:" + rest.replacingOccurrences(of: " ", with: "")) { return .message(rest, u) }
        }
        if lower.hasPrefix("geo:") {
            let c = (String(t.dropFirst(4)).split(separator: "?").first ?? "").split(separator: ",")
            if c.count >= 2, let lat = Double(c[0]), let lon = Double(c[1]),
               let u = URL(string: "https://maps.apple.com/?ll=\(lat),\(lon)&q=\(lat),\(lon)") {
                return .location(String(format: "%.5f, %.5f", lat, lon), u)
            }
        }
        if lower.hasPrefix("begin:vcard") { return .contact(name: vcardName(t) ?? "Contact", data: t) }
        if lower.hasPrefix("mecard:") {
            let f = fields(String(t.dropFirst(7)))
            let name = (f["N"] ?? "Contact").replacingOccurrences(of: ",", with: " ")
            return .contact(name: name, data: meToVCard(f))
        }
        if lower.hasPrefix("begin:vevent") || lower.hasPrefix("begin:vcalendar") {
            let title = line(t, "SUMMARY") ?? "Event"
            let cal = lower.hasPrefix("begin:vcalendar") ? t : "BEGIN:VCALENDAR\nVERSION:2.0\n\(t)\nEND:VCALENDAR"
            return .event(title: title, data: cal)
        }
        if lower.hasPrefix("otpauth://"), let u = URL(string: t), let a = OTPAccount(url: u) { return .oneTimeCode(a) }
        // 认不出的验证码链接（缺密钥、导出码坏了）：只当文字，不当网址打开
        if lower.hasPrefix("otpauth") { return .text(t) }
        if let k = payment(t, lower) { return k }
        if let k = crypto(t, lower) { return k }
        if let u = link(t) {
            if let k = meeting(u) { return k }
            if let k = appStore(u) { return k }
            return .link(u)
        }
        if let k = product(t) { return k }
        return .text(t)
    }

    private static let blockedSchemes: Set<String> = ["file", "shortcuts", "workflow", "applescript", "javascript", "data",
                                                      "vnc", "ssh", "telnet", "smb", "afp", "nfs", "ftp", "sftp",
                                                      "itms-services", "x-man-page", "help", "terminal"]

    /// 是网址：有 http(s) 之类的协议，或者整串就是一个网址（example.com/abc）
    private static func link(_ t: String) -> URL? {
        guard !t.contains(where: \.isWhitespace) else { return nil }
        if let u = URL(string: t), let scheme = u.scheme?.lowercased(), scheme.count > 1 {
            if scheme == "http" || scheme == "https" { return u.host == nil ? nil : u }
            // 扫到的码是别人给的：本地文件、快捷指令、远程登录这类能直接动到电脑的链接不给"打开"，只当文字（可以复制）
            if blockedSchemes.contains(scheme) || scheme.hasPrefix("x-apple") { return nil }
            // 其他 app 的链接（weixin://、spotify:…）：有 app 能打开才算，不然 "Note:abc" 这种字也会被当成链接
            if t.contains("://") || NSWorkspace.shared.urlForApplication(toOpen: u) != nil { return u }
        }
        guard let d = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
              let m = d.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              m.range.length == (t as NSString).length, let u = m.url else { return nil }
        return u
    }

    // MARK: 会议、App Store、商品、付款、加密货币

    private static func meeting(_ u: URL) -> Kind? {
        guard let host = u.host?.lowercased() else { return nil }
        let path = u.path.lowercased()
        func on(_ d: String) -> Bool { host == d || host.hasSuffix("." + d) }
        if on("zoom.us") || on("zoom.com"), path.hasPrefix("/j/") || path.hasPrefix("/w/") || path.hasPrefix("/my/") { return .meeting(service: "Zoom", u) }
        if on("teams.microsoft.com") || on("teams.live.com"), path.contains("meetup-join") || path.hasPrefix("/meet") { return .meeting(service: "Microsoft Teams", u) }
        if host == "meet.google.com", path.count > 1 { return .meeting(service: "Google Meet", u) }
        if host == "facetime.apple.com", path.hasPrefix("/join") { return .meeting(service: "FaceTime", u) }
        if on("webex.com"), path.contains("/meet") || path.contains("j.php") { return .meeting(service: "Webex", u) }
        return nil
    }

    private static func appStore(_ u: URL) -> Kind? {
        let scheme = u.scheme?.lowercased() ?? ""
        let host = u.host?.lowercased() ?? ""
        if host == "testflight.apple.com", u.path.lowercased().hasPrefix("/join") { return .appStore(title: "TestFlight Beta", testFlight: true, u) }
        guard host == "apps.apple.com" || host == "itunes.apple.com" || scheme == "itms-apps" || scheme == "macappstore" else { return nil }
        // /us/app/some-app-name/id123456：拿中间那段当名字
        let parts = u.pathComponents.filter { $0 != "/" }
        var title = "App Store"
        if let i = parts.firstIndex(of: "app"), i + 1 < parts.count, !parts[i + 1].hasPrefix("id") {
            title = parts[i + 1].replacingOccurrences(of: "-", with: " ").capitalized
        }
        return .appStore(title: title, testFlight: false, u)
    }

    /// 只有数字、长度 8/12/13、校验位对：商品条码；978/979 开头是书
    private static func product(_ t: String) -> Kind? {
        guard [8, 12, 13].contains(t.count), t.allSatisfy(\.isASCII), t.allSatisfy(\.isNumber) else { return nil }
        let d = t.compactMap { Int(String($0)) }
        // EAN/UPC 校验：从右往左（不含校验位）奇数位乘 3
        var sum = 0
        for (i, v) in d.dropLast().reversed().enumerated() { sum += i % 2 == 0 ? v * 3 : v }
        guard (10 - sum % 10) % 10 == d.last else { return nil }
        return .product(code: t, isBook: t.count == 13 && (t.hasPrefix("978") || t.hasPrefix("979")))
    }

    private static func payment(_ t: String, _ lower: String) -> Kind? {
        if lower.hasPrefix("wxp://") || lower.hasPrefix("weixin://wxpay") { return .payment(service: "WeChat Pay", detail: nil) }
        if lower.hasPrefix("alipays://") || lower.hasPrefix("alipay://") || lower.hasPrefix("https://qr.alipay.com/") { return .payment(service: "Alipay", detail: nil) }
        // EMVCo 的统一付款码（PayNow、DuitNow、PromptPay、QRIS、银联……）：000201 开头，一串 两位编号+两位长度+内容
        guard t.hasPrefix("000201"), let f = emv(t) else { return nil }
        let accounts = (26...51).compactMap { f[String(format: "%02d", $0)] }.joined(separator: " ").uppercased()
        let service: String
        if accounts.contains("SG.PAYNOW") { service = "PayNow" }
        else if accounts.contains("SG.COM.NETS") { service = "NETS" }
        else if accounts.contains("PAYNET") || accounts.contains("DUITNOW") { service = "DuitNow" }
        else if accounts.contains("A000000677") { service = "PromptPay" }
        else if accounts.contains("ID.CO.QRIS") { service = "QRIS" }
        else if accounts.contains("UNIONPAY") || f["15"] != nil { service = "UnionPay" }
        else { service = "Payment" }
        var detail: [String] = []
        if let name = f["59"]?.trimmingCharacters(in: .whitespaces), !name.isEmpty { detail.append(name) }
        if let amt = f["54"] {
            let cur = f["53"].flatMap { currencies[$0] } ?? ""
            detail.append(cur.isEmpty ? amt : "\(cur) \(amt)")
        }
        return .payment(service: service, detail: detail.isEmpty ? nil : detail.joined(separator: " · "))
    }

    /// 常见的几种（ISO 4217 数字代码）
    private static let currencies = ["702": "SGD", "458": "MYR", "764": "THB", "360": "IDR", "156": "CNY", "344": "HKD",
                                     "840": "USD", "978": "EUR", "826": "GBP", "392": "JPY", "410": "KRW", "608": "PHP", "704": "VND", "356": "INR"]

    /// 两位编号 + 两位长度 + 内容，一层（里面的子项原样留着，按字找就够了）
    private static func emv(_ t: String) -> [String: String]? {
        let c = Array(t)
        var i = 0
        var out: [String: String] = [:]
        while i + 4 <= c.count {
            let id = String(c[i..<i + 2])
            // 长度只认两位数字（"-1" 之类会让下面的范围倒过来、直接崩）
            let lenText = c[i + 2..<i + 4]
            guard lenText.allSatisfy({ $0.isASCII && $0.isNumber }), let len = Int(String(lenText)), i + 4 + len <= c.count else { return nil }
            out[id] = String(c[i + 4..<i + 4 + len])
            i += 4 + len
        }
        return i == c.count && out["00"] == "01" ? out : nil
    }

    private static func crypto(_ t: String, _ lower: String) -> Kind? {
        let coins = ["bitcoin": "Bitcoin", "ethereum": "Ethereum", "litecoin": "Litecoin", "bitcoincash": "Bitcoin Cash",
                     "dogecoin": "Dogecoin", "solana": "Solana", "monero": "Monero", "tron": "TRON", "ripple": "XRP"]
        guard let colon = lower.firstIndex(of: ":"), let coin = coins[String(lower[..<colon])] else { return nil }
        var addr = String(t[t.index(after: colon)...])
        if addr.hasPrefix("//") { addr.removeFirst(2) }
        // 地址后面的 ?amount=… 和以太坊的 @链号 不要
        addr = String(addr.split(separator: "?").first ?? "").components(separatedBy: "@")[0]
        guard addr.count >= 20, addr.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return .crypto(coin: coin, address: addr)
    }

    /// WIFI:T:WPA;S:名字;P:密码;H:true;;   \ 转义 ; , : \ "
    private static func wifi(_ t: String) -> Kind {
        let f = fields(String(t.dropFirst(5)))
        let ssid = f["S"] ?? ""
        let type = (f["T"] ?? "").uppercased()
        let pw = type == "NOPASS" || (f["P"] ?? "").isEmpty ? nil : f["P"]
        return .wifi(ssid: ssid, password: pw, hidden: (f["H"] ?? "").lowercased() == "true")
    }

    /// 解析 KEY:值;KEY:值;; 这种（Wi‑Fi、MECARD、MATMSG）
    private static func fields(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        var key = "", val = "", inKey = true, esc = false
        func flush() { if !key.isEmpty, out[key] == nil { out[key] = val }; key = ""; val = ""; inKey = true }
        for c in s {
            if esc { if inKey { key.append(c) } else { val.append(c) }; esc = false; continue }
            if c == "\\" { esc = true; continue }
            if inKey { if c == ":" { inKey = false } else if c == ";" { flush() } else { key.append(c) }; continue }
            if c == ";" { flush() } else { val.append(c) }
        }
        flush()
        var upper: [String: String] = [:]
        for (k, v) in out { upper[k.uppercased()] = v }
        return upper
    }

    private static func line(_ t: String, _ key: String) -> String? {
        for l in t.components(separatedBy: .newlines) {
            let parts = l.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0].split(separator: ";").first?.uppercased() == key {
                return String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func vcardName(_ t: String) -> String? {
        if let fn = line(t, "FN"), !fn.isEmpty { return fn }
        guard let n = line(t, "N") else { return nil }
        let p = n.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        let name = [p.count > 1 ? p[1] : "", p.first ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? nil : name
    }

    private static func meToVCard(_ f: [String: String]) -> String {
        var v = ["BEGIN:VCARD", "VERSION:3.0"]
        let n = f["N"] ?? ""
        let parts = n.split(separator: ",").map(String.init)
        v.append("N:\(parts.first ?? "");\(parts.count > 1 ? parts[1] : "")")
        v.append("FN:\(parts.reversed().joined(separator: " "))")
        if let x = f["TEL"] { v.append("TEL:\(x)") }
        if let x = f["EMAIL"] { v.append("EMAIL:\(x)") }
        if let x = f["URL"] { v.append("URL:\(x)") }
        if let x = f["ADR"] { v.append("ADR:;;\(x)") }
        if let x = f["ORG"] { v.append("ORG:\(x)") }
        v.append("END:VCARD")
        return v.joined(separator: "\n")
    }

    // MARK: 怎么显示、按钮做什么

    /// 主按钮的字。nil：没有主按钮（只能复制）
    var action: String? {
        switch kind {
        case .link(let u): return NSWorkspace.shared.urlForApplication(toOpen: u) == nil ? nil : "Open"
        case .wifi: return "Join"
        case .email: return "Email"
        case .phone(_, let u): return NSWorkspace.shared.urlForApplication(toOpen: u) == nil ? nil : "Call"
        case .message: return "Message"
        case .location: return "Open in Maps"
        case .contact: return "Add to Contacts"
        case .event: return "Add to Calendar"
        case .oneTimeCode: return "Copy Code"
        case .meeting(_, let u): return NSWorkspace.shared.urlForApplication(toOpen: u) == nil ? nil : "Join Meeting"
        case .appStore(_, let tf, let u): return NSWorkspace.shared.urlForApplication(toOpen: u) == nil ? nil : tf ? "Open in TestFlight" : "Open in App Store"
        case .product: return "Search"
        case .payment, .crypto: return nil
        case .text: return nil
        }
    }

    var symbol: String {
        switch kind {
        case .link: return "globe"
        case .wifi: return "wifi"
        case .email: return "envelope"
        case .phone: return "phone"
        case .message: return "message"
        case .location: return "mappin.and.ellipse"
        case .contact: return "person.crop.circle"
        case .event: return "calendar"
        case .oneTimeCode: return "key"
        case .meeting: return "video"
        case .appStore: return "app.badge"
        case .product(_, let book): return book ? "book" : "barcode"
        case .payment: return "creditcard"
        case .crypto: return "bitcoinsign.circle"
        case .text: return isQR ? "qrcode" : "barcode"
        }
    }

    /// 第二行的灰字：这是什么
    var caption: String {
        switch kind {
        case .link: return "Link"
        case .wifi(_, let pw, _): return pw == nil ? "Wi‑Fi · Open network" : "Wi‑Fi"
        case .email: return "Email"
        case .phone: return "Phone"
        case .message: return "Message"
        case .location: return "Location"
        case .contact: return "Contact"
        case .event: return "Event"
        case .oneTimeCode(let a): return a.label
        case .meeting(let s, _): return "\(s) meeting"
        case .appStore(_, let tf, _): return tf ? "TestFlight" : "App Store"
        case .product(_, let book): return book ? "ISBN" : "Product barcode"
        case .payment(_, let d): return d.map { "Payment code · \($0)" } ?? "Payment code"
        case .crypto(let c, _): return "\(c) address"
        case .text: return isQR ? "QR code" : "Barcode"
        }
    }

    var title: String {
        switch kind {
        case .link(let u): return u.absoluteString
        case .wifi(let ssid, _, _): return ssid.isEmpty ? "Wi‑Fi Network" : ssid
        case .email(let a, _): return a
        case .phone(let n, _), .message(let n, _): return n
        case .location(let s, _): return s
        case .contact(let n, _): return n
        case .event(let t, _): return t
        case .oneTimeCode(let a): return OTPAccount.spaced(a.code())
        case .meeting(let s, let u): return Self.meetingID(u) ?? s
        case .appStore(let t, _, _): return t
        case .product(let c, _): return c
        case .payment(let s, _): return s
        // 中间省略：开头和结尾最容易被调包，留着给人对
        case .crypto(_, let a): return a.count > 22 ? "\(a.prefix(10))…\(a.suffix(8))" : a
        case .text(let s): return s.components(separatedBy: .newlines).first { !$0.isEmpty } ?? s
        }
    }

    /// 会议号：Zoom 的数字（123 4567 8901）、Meet 的 abc-defg-hij
    private static func meetingID(_ u: URL) -> String? {
        let parts = u.pathComponents.filter { $0 != "/" }
        if u.host?.lowercased() == "meet.google.com" { return parts.first }
        if let i = parts.firstIndex(where: { $0 == "j" || $0 == "w" }), i + 1 < parts.count, parts[i + 1].allSatisfy(\.isNumber) {
            let d = Array(parts[i + 1])
            // Zoom 的习惯写法：3-4-4（11 位）或 3-3-4（10 位）
            let groups = d.count == 11 ? [3, 4, 4] : d.count == 10 ? [3, 3, 4] : [d.count]
            var out: [String] = [], k = 0
            for g in groups { out.append(String(d[k..<min(k + g, d.count)])); k += g }
            return "ID " + out.joined(separator: " ")
        }
        return nil
    }

    /// ⌘C 和点文字时复制什么
    var copyText: String {
        switch kind {
        case .link(let u): return u.absoluteString
        case .wifi(let ssid, let pw, _): return pw ?? ssid
        case .email(let a, _): return a
        case .phone(let n, _), .message(let n, _): return n
        // 复制的是现在的验证码，不是密钥
        case .oneTimeCode(let a): return a.code()
        case .meeting(_, let u), .appStore(_, _, let u): return u.absoluteString
        case .product(let c, _): return c
        case .crypto(_, let a): return a
        default: return payload
        }
    }
}

// MARK: 做

@MainActor
enum ScanActions {
    /// 打开、加到通讯录、日历……返回 false：没做成
    @discardableResult
    static func perform(_ c: ScannedCode) -> Bool {
        switch c.kind {
        case .link(let u), .email(_, let u), .phone(_, let u), .message(_, let u), .location(_, let u):
            return NSWorkspace.shared.open(u)
        case .oneTimeCode(let a):
            guard let u = a.setupURL else { return false }
            return NSWorkspace.shared.open(u)
        case .meeting(_, let u), .appStore(_, _, let u):
            return NSWorkspace.shared.open(u)
        case .product(let c, _):
            guard let u = URL(string: "https://www.google.com/search?q=\(c)") else { return false }
            return NSWorkspace.shared.open(u)
        case .payment, .crypto: return false
        case .contact(let name, let data): return openFile(data, name: name, ext: "vcf")
        case .event(let title, let data): return openFile(data, name: title, ext: "ics")
        case .wifi, .text: return false
        }
    }

    /// 通讯录、日历：写成临时文件交给系统打开，系统会问要不要加进去
    private static func openFile(_ data: String, name: String, ext: String) -> Bool {
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: " ").prefix(60)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("QuickCap Scan", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(safe.isEmpty ? "Scan" : String(safe)).\(ext)")
        guard (try? data.write(to: url, atomically: true, encoding: .utf8)) != nil else { return false }
        return NSWorkspace.shared.open(url)
    }

    static func copy(_ s: String) {
        CaptureOutput.pasteboard.clearContents()
        CaptureOutput.pasteboard.setString(s, forType: .string)
    }
}

/// 连 Wi‑Fi：用系统自带的 networksetup，在后台跑，不卡界面
enum WiFiJoin {
    enum Outcome { case joined, failed(String) }

    static func join(ssid: String, password: String?, completion: @escaping @MainActor (Outcome) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Outcome
            if let device = wifiDevice() {
                var args = ["-setairportnetwork", device, ssid]
                if let password { args.append(password) }
                let (code, out) = run("/usr/sbin/networksetup", args)
                // 连不上时退出码有时也是 0，只能看它有没有说话：连上了什么都不说
                let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
                result = code == 0 && text.isEmpty ? .joined : .failed(text.isEmpty ? "Could not join \(ssid)" : text)
            } else {
                result = .failed("Wi‑Fi is not available")
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    /// 无线网卡的名字（一般是 en0）
    private static func wifiDevice() -> String? {
        let (_, out) = run("/usr/sbin/networksetup", ["-listallhardwareports"])
        let lines = out.components(separatedBy: .newlines)
        for (i, l) in lines.enumerated() where l.contains("Wi-Fi") || l.contains("AirPort") {
            if i + 1 < lines.count, lines[i + 1].hasPrefix("Device: ") { return String(lines[i + 1].dropFirst(8)) }
        }
        return nil
    }

    private static func run(_ path: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
