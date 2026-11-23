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
        case oneTimeCode(label: String, URL)
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

    // MARK: 认

    /// 在图里找码，按面积从大到小。size：选区的大小（pt），用来把位置换成选区坐标
    nonisolated static func detect(in image: CGImage, size: CGSize) async -> [ScannedCode] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let req = VNDetectBarcodesRequest()
                let handler = VNImageRequestHandler(cgImage: image)
                try? handler.perform([req])
                var seen = Set<String>()
                let codes: [ScannedCode] = (req.results ?? []).compactMap { o in
                    guard let s = o.payloadStringValue, !s.isEmpty, seen.insert(s).inserted else { return nil }
                    let b = o.boundingBox
                    let r = CGRect(x: b.minX * size.width, y: b.minY * size.height, width: b.width * size.width, height: b.height * size.height)
                    return ScannedCode(payload: s, rect: r, isQR: o.symbology == .qr || o.symbology == .microQR)
                }
                cont.resume(returning: codes.sorted { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height })
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
            let c = String(t.dropFirst(4)).split(separator: "?")[0].split(separator: ",")
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
        if lower.hasPrefix("otpauth://"), let u = URL(string: t) {
            let label = (u.path.removingPercentEncoding ?? u.path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return .oneTimeCode(label: label.isEmpty ? "Verification Code" : label, u)
        }
        if let u = link(t) { return .link(u) }
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
            if parts[0].split(separator: ";")[0].uppercased() == key {
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
        case .oneTimeCode(_, let u): return NSWorkspace.shared.urlForApplication(toOpen: u) == nil ? nil : "Set Up"
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
        case .oneTimeCode: return "Verification code"
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
        case .oneTimeCode(let l, _): return l
        case .text(let s): return s.components(separatedBy: .newlines).first { !$0.isEmpty } ?? s
        }
    }

    /// ⌘C 和点文字时复制什么
    var copyText: String {
        switch kind {
        case .link(let u): return u.absoluteString
        case .wifi(let ssid, let pw, _): return pw ?? ssid
        case .email(let a, _): return a
        case .phone(let n, _), .message(let n, _): return n
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
        case .link(let u), .email(_, let u), .phone(_, let u), .message(_, let u), .location(_, let u), .oneTimeCode(_, let u):
            return NSWorkspace.shared.open(u)
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
