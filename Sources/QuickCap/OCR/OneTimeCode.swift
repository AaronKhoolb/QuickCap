import Foundation
import CryptoKit

/// 两步验证的账号（网站开两步验证时给的二维码：otpauth://totp/GitHub:me?secret=…）。
/// 验证码按公开的标准（RFC 6238 / 4226）在本机算，不联网、不存密钥
struct OTPAccount {
    enum Algorithm: String { case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512" }

    let secret: Data
    let issuer: String?
    let name: String
    let algorithm: Algorithm
    let digits: Int
    let period: Int
    /// nil：按时间（TOTP，最常见）；有值：按次数（HOTP）
    let counter: UInt64?

    /// 显示的名字：GitHub · me@example.com
    var label: String {
        let n = name.isEmpty ? nil : name
        switch (issuer, n) {
        case let (i?, n?) where i != n: return "\(i) · \(n)"
        case let (i?, _): return i
        case let (nil, n?): return n
        default: return "Verification Code"
        }
    }

    // MARK: 读

    /// otpauth://totp/发行方:账号?secret=BASE32&issuer=…&algorithm=SHA1&digits=6&period=30
    init?(url u: URL) {
        guard u.scheme?.lowercased() == "otpauth", let type = u.host?.lowercased(), type == "totp" || type == "hotp",
              let comps = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return nil }
        var q: [String: String] = [:]
        for item in comps.queryItems ?? [] { q[item.name.lowercased()] = item.value }
        guard let s = q["secret"], let secret = Self.base32(s), !secret.isEmpty else { return nil }
        // 路径是 /发行方:账号（发行方可以没有）
        let path = (comps.percentEncodedPath.removingPercentEncoding ?? comps.path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = path.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let issuer = q["issuer"].flatMap { $0.isEmpty ? nil : $0 } ?? (parts.count == 2 ? parts[0] : nil)
        let digits = Int(q["digits"] ?? "") ?? 6
        let period = Int(q["period"] ?? "") ?? 30
        guard (6...8).contains(digits), (1...300).contains(period) else { return nil }
        let counter: UInt64? = type == "hotp" ? UInt64(q["counter"] ?? "0") ?? 0 : nil
        self.init(secret: secret, issuer: issuer, name: parts.last ?? "",
                  algorithm: Algorithm(rawValue: (q["algorithm"] ?? "SHA1").uppercased()) ?? .sha1,
                  digits: digits, period: period, counter: counter)
    }

    init(secret: Data, issuer: String?, name: String, algorithm: Algorithm, digits: Int, period: Int, counter: UInt64?) {
        self.secret = secret; self.issuer = issuer; self.name = name
        self.algorithm = algorithm; self.digits = digits; self.period = period; self.counter = counter
    }

    /// Google Authenticator "导出账号" 的码：otpauth-migration://offline?data=BASE64，一个码里有好几个账号
    static func migration(_ u: URL) -> [OTPAccount]? {
        guard u.scheme?.lowercased() == "otpauth-migration",
              let comps = URLComponents(url: u, resolvingAgainstBaseURL: false),
              var b64 = comps.queryItems?.first(where: { $0.name == "data" })?.value else { return nil }
        // 有的码把 + 写成了空格（没转义）
        b64 = b64.replacingOccurrences(of: " ", with: "+").replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        var accounts: [OTPAccount] = []
        var r = ProtoReader(data)
        while let (field, value) = r.next() {
            guard field == 1, case .bytes(let sub) = value else { continue }
            var secret = Data(), name = "", issuer = "", algo = 1, digits = 1, type = 2
            var counter: UInt64 = 0
            var p = ProtoReader(sub)
            while let (f, v) = p.next() {
                switch (f, v) {
                case (1, .bytes(let d)): secret = d
                case (2, .bytes(let d)): name = String(decoding: d, as: UTF8.self)
                case (3, .bytes(let d)): issuer = String(decoding: d, as: UTF8.self)
                case (4, .varint(let n)): algo = Int(truncatingIfNeeded: n)
                case (5, .varint(let n)): digits = Int(truncatingIfNeeded: n)
                case (6, .varint(let n)): type = Int(truncatingIfNeeded: n)
                case (7, .varint(let n)): counter = n
                default: break
                }
            }
            guard !secret.isEmpty else { continue }
            // 名字里常带着 "发行方:账号"
            if issuer.isEmpty, let i = name.firstIndex(of: ":") { issuer = String(name[..<i]) }
            if let i = name.firstIndex(of: ":") { name = String(name[name.index(after: i)...]).trimmingCharacters(in: .whitespaces) }
            let a: Algorithm = algo == 2 ? .sha256 : algo == 3 ? .sha512 : .sha1
            accounts.append(OTPAccount(secret: secret, issuer: issuer.isEmpty ? nil : issuer, name: name, algorithm: a,
                                       digits: digits == 2 ? 8 : 6, period: 30, counter: type == 1 ? counter : nil))
        }
        return accounts.isEmpty ? nil : accounts
    }

    /// 交给系统"密码" app 保存用的链接
    var setupURL: URL? {
        var c = URLComponents()
        c.scheme = "otpauth"
        c.host = counter == nil ? "totp" : "hotp"
        c.path = "/" + (issuer.map { "\($0):" } ?? "") + name
        var q = [URLQueryItem(name: "secret", value: Self.base32Encode(secret)),
                 URLQueryItem(name: "algorithm", value: algorithm.rawValue),
                 URLQueryItem(name: "digits", value: String(digits))]
        if let issuer { q.append(URLQueryItem(name: "issuer", value: issuer)) }
        if let counter { q.append(URLQueryItem(name: "counter", value: String(counter))) } else { q.append(URLQueryItem(name: "period", value: String(period))) }
        c.queryItems = q
        return c.url
    }

    // MARK: 算

    /// 现在的验证码（按次数的那种：当前次数的那个）
    func code(at date: Date = Date()) -> String {
        let n = counter ?? UInt64(max(0, date.timeIntervalSince1970) / Double(period))
        var be = n.bigEndian
        let msg = Data(bytes: &be, count: 8)
        let key = SymmetricKey(data: secret)
        let mac: [UInt8]
        switch algorithm {
        case .sha1: mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: msg, using: key))
        case .sha256: mac = Array(HMAC<SHA256>.authenticationCode(for: msg, using: key))
        case .sha512: mac = Array(HMAC<SHA512>.authenticationCode(for: msg, using: key))
        }
        let o = Int(mac[mac.count - 1] & 0x0f)
        let bin = (UInt32(mac[o] & 0x7f) << 24) | (UInt32(mac[o + 1]) << 16) | (UInt32(mac[o + 2]) << 8) | UInt32(mac[o + 3])
        var mod: UInt32 = 1
        for _ in 0..<digits { mod *= 10 }
        let s = String(bin % mod)
        return String(repeating: "0", count: digits - s.count) + s
    }

    /// 这个码还剩几秒（按次数的那种没有）
    func secondsLeft(at date: Date = Date()) -> Double? {
        guard counter == nil else { return nil }
        let p = Double(period)
        return p - date.timeIntervalSince1970.truncatingRemainder(dividingBy: p)
    }

    /// 123 456（中间空一格好读）；复制时不带空格
    static func spaced(_ code: String) -> String {
        guard code.count >= 6 else { return code }
        let mid = code.index(code.startIndex, offsetBy: code.count / 2)
        return code[..<mid] + " " + code[mid...]
    }

    // MARK: Base32

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func base32(_ s: String) -> Data? {
        var bits: UInt64 = 0, n = 0
        var out = Data()
        for ch in s.uppercased() where ch != "=" && ch != " " && ch != "-" {
            guard let v = alphabet.firstIndex(of: ch) else { return nil }
            bits = (bits << 5) | UInt64(v)
            n += 5
            if n >= 8 { n -= 8; out.append(UInt8((bits >> UInt64(n)) & 0xff)) }
        }
        return out
    }

    static func base32Encode(_ d: Data) -> String {
        var bits: UInt64 = 0, n = 0
        var out = ""
        for b in d {
            bits = (bits << 8) | UInt64(b)
            n += 8
            while n >= 5 { n -= 5; out.append(alphabet[Int((bits >> UInt64(n)) & 31)]) }
        }
        if n > 0 { out.append(alphabet[Int((bits << UInt64(5 - n)) & 31)]) }
        return out
    }
}

/// 最简单的 protobuf 读法（只认导出码里用到的：数字和一段字节）
private struct ProtoReader {
    enum Value { case varint(UInt64), bytes(Data) }
    private let d: [UInt8]
    private var i = 0
    init(_ data: Data) { d = Array(data) }

    private mutating func varint() -> UInt64? {
        var v: UInt64 = 0, shift: UInt64 = 0
        while i < d.count, shift < 64 {
            let b = d[i]; i += 1
            v |= UInt64(b & 0x7f) << shift
            if b & 0x80 == 0 { return v }
            shift += 7
        }
        return nil
    }

    mutating func next() -> (Int, Value)? {
        guard i < d.count, let key = varint() else { return nil }
        let field = Int(truncatingIfNeeded: key >> 3)
        switch key & 7 {
        case 0: return varint().map { (field, .varint($0)) }
        case 2:
            guard let len = varint(), len <= UInt64(d.count - i) else { return nil }
            let s = Data(d[i..<i + Int(len)]); i += Int(len)
            return (field, .bytes(s))
        case 1: guard i + 8 <= d.count else { return nil }; i += 8; return next()
        case 5: guard i + 4 <= d.count else { return nil }; i += 4; return next()
        default: return nil
        }
    }
}
