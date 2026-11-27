import AppKit

/// 扫描认出二维码后，贴在码下面的小条。和截图的操作条同一种白色玻璃、同一个高度：
///   ⓧ │ 🌐 menu.lumen.cafe/table/12          [Open]
///   ⓧ │ 📶 Cafe Lumen Guest  Wi‑Fi           [Join]
///        🔒 ••••••••
/// 链接：域名加粗、后面灰的会被截断，条不会被长网址拉长；点文字复制。
/// Wi‑Fi：点圆点显示密码并复制，没有另外的复制按钮和眼睛按钮。
/// 回车 = 主按钮，⌘C 复制，Tab 换下一个码（选区里有好几个码时才有）
@MainActor
final class ScanResultBar: GlassBar {
    var onCancel: (() -> Void)?
    var onPrimary: (() -> Void)?
    var onCopy: ((String) -> Void)?
    var onNext: (() -> Void)?
    /// 验证码：存进系统"密码" app
    var onSetUp: (() -> Void)?
    /// 条下面的一行提醒（验证码：这张图里有密钥）
    var note: String? {
        if case .oneTimeCode = code.kind { return "This QR contains a secret key. Don’t share this screenshot." }
        return nil
    }
    /// 验证码：每秒刷新数字和倒计时
    private var otpTimer: Timer?
    private var otpLabel: NSTextField?
    private var otpRing: CAShapeLayer?
    /// 放进过窗口了（之后窗口藏起来、条被拿走就停计时器）
    private var otpShown = false

    let code: ScannedCode
    private var primary: PrimaryButton!
    private var copyTarget: BarButton?
    private var password: (button: BarButton, label: NSTextField)?
    private var revealed = false

    static let ink = NSColor(white: 0, alpha: 0.85)
    static let gray = NSColor(white: 0, alpha: 0.48)

    init(code: ScannedCode, index: Int, count: Int) {
        self.code = code
        super.init(frame: .zero)
        let cancel = BarButton(symbol: "xmark.circle.fill", pointSize: 17, width: 32, tint: .tertiaryLabelColor)
        cancel.help("Close", key: "Esc")
        cancel.onClick = { [weak self] _ in self?.onCancel?() }
        stack.addArrangedSubview(cancel)
        stack.addArrangedSubview(BarSeparator())
        let icon = Self.badge(code.symbol)
        stack.addArrangedSubview(icon)
        stack.setCustomSpacing(4, after: icon)
        let info = infoView()
        stack.addArrangedSubview(info)
        stack.setCustomSpacing(8, after: info)
        if count > 1 {
            let next = BarButton(title: "\(index + 1) of \(count)", trailingSymbol: nil, padding: 9)
            next.label?.textColor = Self.gray
            next.label?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            next.help("Next Code", key: "⇥")
            next.onClick = { [weak self] _ in self?.onNext?() }
            stack.addArrangedSubview(next)
            stack.setCustomSpacing(4, after: next)
        }
        // 验证码：旁边一个小按钮交给系统"密码" app 存起来（以后自动填）
        if case .oneTimeCode(let a) = code.kind, let u = a.setupURL, NSWorkspace.shared.urlForApplication(toOpen: u) != nil {
            let setup = BarButton(title: "Set Up", trailingSymbol: nil, padding: 9)
            setup.help("Save to Passwords", key: nil)
            setup.onClick = { [weak self] _ in self?.onSetUp?() }
            stack.addArrangedSubview(setup)
            stack.setCustomSpacing(4, after: setup)
        }
        let p = PrimaryButton(title: code.action ?? "Copy")
        p.help(code.action == nil ? "Copy" : primaryHelp, key: "↩")
        p.onClick = { [weak self] _ in self?.onPrimary?() }
        primary = p
        stack.addArrangedSubview(p)
        setupGlass()
    }

    required init?(coder: NSCoder) { fatalError() }

    private var primaryHelp: String {
        switch code.kind {
        case .link(let u): return u.scheme.map { ["http", "https"].contains($0.lowercased()) } == true ? "Open in Browser" : "Open"
        case .wifi(let ssid, _, _): return "Join \(ssid)"
        default: return code.action ?? "Copy"
        }
    }

    // MARK: 中间的文字

    private func infoView() -> NSView {
        switch code.kind {
        case .link(let u): return linkView(u)
        case .wifi(let ssid, let pw, _): return wifiView(ssid.isEmpty ? "Wi‑Fi Network" : ssid, pw)
        case .oneTimeCode(let a): return otpView(a)
        default: return twoLine(code.title, code.caption)
        }
    }

    /// 一行：域名（粗）+ 后面的路径（灰，放不下就截断）。整块点一下复制链接
    private func linkView(_ u: URL) -> NSView {
        let (head, tail) = Self.split(u)
        let h = Self.label(head, size: 13, weight: .semibold, color: Self.ink)
        let t = Self.label(tail, size: 13, weight: .regular, color: Self.gray)
        h.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [h, t])
        row.spacing = 0
        row.alignment = .firstBaseline
        let b = BarButton(content: row, height: 28, padding: NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6))
        b.widthAnchor.constraint(lessThanOrEqualToConstant: 264).isActive = true
        b.help("Copy Link", key: "⌘C", sub: u.absoluteString.count > 60 ? String(u.absoluteString.prefix(80)) + "…" : u.absoluteString)
        b.onClick = { [weak self] btn in self?.copy(over: btn) }
        copyTarget = b
        return b
    }

    /// 两行：网络名（粗）和灰色的 "Wi‑Fi"；下面是小锁和圆点，点了显示密码、复制。没有密码的写 Open network
    private func wifiView(_ ssid: String, _ pw: String?) -> NSView {
        let name = Self.label(ssid, size: 13, weight: .semibold, color: Self.ink)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
        let kind = Self.label("Wi‑Fi", size: 12, weight: .regular, color: Self.gray)
        kind.setContentCompressionResistancePriority(.required, for: .horizontal)
        let top = NSStackView(views: [name, kind])
        top.spacing = 5
        top.alignment = .firstBaseline
        let bottom: NSView
        if let pw {
            let lock = BarButton.symbolView("lock.fill", pointSize: 9, weight: .medium, tint: Self.gray)
            let dots = Self.label("", size: 12, weight: .regular, color: Self.gray)
            dots.attributedStringValue = Self.dots
            let w = min(max(Self.dots.size().width, Self.revealText(pw).size().width) + 2, 200)
            dots.widthAnchor.constraint(equalToConstant: w.rounded(.up)).isActive = true
            let row = NSStackView(views: [lock, dots])
            row.spacing = 5
            row.alignment = .centerY
            let b = BarButton(content: row, height: 18, padding: NSEdgeInsets(top: 0, left: 5, bottom: 0, right: 5), corner: 5)
            b.help("Show and Copy Password", key: "⌘C")
            b.onClick = { [weak self] btn in self?.reveal(over: btn) }
            password = (b, dots)
            copyTarget = b
            bottom = b
        } else {
            let open = NSStackView(views: [Self.label("Open network", size: 12, weight: .regular, color: Self.gray)])
            open.edgeInsets = NSEdgeInsets(top: 0, left: 5, bottom: 0, right: 0)
            bottom = open
        }
        // 圆点那块有 5pt 的内边距（悬停的灰底），上面一行也缩进 5pt，小锁和网络名左边对齐
        top.edgeInsets = NSEdgeInsets(top: 0, left: 5, bottom: 0, right: 0)
        let col = NSStackView(views: [top, bottom])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 1
        return col
    }

    /// 别的：标题（粗，放不下截断）和下面一行灰字写这是什么。点一下复制
    private func twoLine(_ title: String, _ caption: String) -> NSView {
        let t = Self.label(title, size: 13, weight: .semibold, color: Self.ink)
        t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let c = Self.label(caption, size: 11.5, weight: .regular, color: Self.gray)
        let col = NSStackView(views: [t, c])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 1
        let b = BarButton(content: col, height: 38, padding: NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6))
        b.widthAnchor.constraint(lessThanOrEqualToConstant: 264).isActive = true
        b.help("Copy", key: "⌘C")
        b.onClick = { [weak self] btn in self?.copy(over: btn) }
        copyTarget = b
        return b
    }

    /// 验证码：大号数字（123 456）+ 倒计时小圆圈，下面灰字是账号；再下面一行提醒这张图里有密钥。点数字复制
    private func otpView(_ a: OTPAccount) -> NSView {
        let digits = NSTextField(labelWithString: OTPAccount.spaced(a.code()))
        digits.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        digits.textColor = Self.ink
        otpLabel = digits
        var top: [NSView] = [digits]
        if a.counter == nil {
            let ring = NSView()
            ring.wantsLayer = true
            ring.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([ring.widthAnchor.constraint(equalToConstant: 14), ring.heightAnchor.constraint(equalToConstant: 14)])
            let track = CAShapeLayer(), arc = CAShapeLayer()
            let path = CGPath(ellipseIn: CGRect(x: 1.5, y: 1.5, width: 11, height: 11), transform: nil)
            for (l, c) in [(track, NSColor(white: 0, alpha: 0.1)), (arc, NSColor(white: 0, alpha: 0.55))] {
                l.path = path; l.fillColor = nil; l.strokeColor = c.cgColor; l.lineWidth = 2
                l.frame = CGRect(x: 0, y: 0, width: 14, height: 14)
                ring.layer?.addSublayer(l)
            }
            // 从 12 点开始、顺时针变短
            arc.transform = CATransform3DConcat(CATransform3DMakeRotation(.pi / 2, 0, 0, 1), CATransform3DMakeScale(-1, 1, 1))
            arc.lineCap = .round
            otpRing = arc
            top.append(ring)
        }
        let row = NSStackView(views: top)
        row.spacing = 7
        row.alignment = .centerY
        let who = Self.label(a.label, size: 11.5, weight: .regular, color: Self.gray)
        who.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let col = NSStackView(views: [row, who])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 0
        let b = BarButton(content: col, height: 40, padding: NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6))
        b.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        b.help("Copy Code", key: "⌘C")
        b.onClick = { [weak self] btn in self?.copy(over: btn) }
        copyTarget = b
        tickOTP()
        otpTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                // 截图界面关掉时窗口只是藏起来，条还在：看不见了就停
                guard let self else { t.invalidate(); return }
                if let w = self.window { self.otpShown = true; if !w.isVisible { t.invalidate(); return } }
                else if self.otpShown { t.invalidate(); return }
                self.tickOTP()
            }
        }
        return b
    }

    private func tickOTP() {
        guard case .oneTimeCode(let a) = code.kind else { return }
        let now = Date()
        let text = OTPAccount.spaced(a.code(at: now))
        if otpLabel?.stringValue != text { otpLabel?.stringValue = text }
        if let ring = otpRing, let left = a.secondsLeft(at: now) {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            ring.strokeEnd = CGFloat(left / Double(a.period))
            // 最后 5 秒变红：快换了，别复制这个
            ring.strokeColor = (left <= 5 ? NSColor.systemRed : NSColor(white: 0, alpha: 0.55)).cgColor
            CATransaction.commit()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { otpTimer?.invalidate(); otpTimer = nil }
    }

    // MARK: 点了

    /// ⌘C：复制（Wi‑Fi 的话顺便把密码显示出来）
    func copyFromKeyboard() {
        if let password { reveal(over: password.button) } else if let copyTarget { copy(over: copyTarget) } else { onCopy?(code.copyText) }
    }

    private func copy(over b: BarButton) {
        onCopy?(code.copyText)
        flashCopied(over: b)
    }

    private func reveal(over b: BarButton) {
        guard let (_, label) = password, case .wifi(_, let pw?, _) = code.kind else { return }
        onCopy?(pw)
        if !revealed {
            revealed = true
            label.attributedStringValue = Self.revealText(pw)
            label.lineBreakMode = .byTruncatingMiddle
            b.help("Copy Password", key: "⌘C")
        }
        flashCopied(over: b)
    }

    private var copiedTimer: Timer?
    private func flashCopied(over b: BarButton) {
        copiedTimer?.invalidate()
        showTooltip("Copied", key: nil, sub: nil, over: b)
        copiedTimer = Timer.scheduledTimer(withTimeInterval: 1.1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideTooltip() }
        }
    }

    // MARK: 出现

    /// 从码那边弹出来：在码下面就从上往下，在上面就从下往上
    func animateIn(below: Bool) {
        animateIn(anchor: CGPoint(x: 0.5, y: below ? 1 : 0), scale: 0.92, offsetY: below ? -10 : 10)
    }

    // MARK: 小零件

    /// 圆点：固定 8 个，不让人从长度猜密码
    private static let dots: NSAttributedString = NSAttributedString(string: String(repeating: "•", count: 8), attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .heavy), .foregroundColor: NSColor(white: 0, alpha: 0.55), .kern: 1.2,
        .baselineOffset: -0.5])

    private static func revealText(_ pw: String) -> NSAttributedString {
        NSAttributedString(string: pw, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: ink, .kern: 0.2])
    }

    static func label(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        l.maximumNumberOfLines = 1
        l.cell?.truncatesLastVisibleLine = true
        return l
    }

    /// 圆的浅灰底，中间一个图标
    private static func badge(_ symbol: String) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 14
        v.layer?.backgroundColor = NSColor(white: 0, alpha: 0.06).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        let iv = BarButton.symbolView(symbol, pointSize: 13, weight: .medium, tint: NSColor(white: 0, alpha: 0.72))
        v.addSubview(iv)
        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: 28), v.heightAnchor.constraint(equalToConstant: 28),
            iv.centerXAnchor.constraint(equalTo: v.centerXAnchor), iv.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        return v
    }

    /// 网址拆成显示的两段：域名（www 留着，钓鱼网站常在这里做手脚）和后面的。http 的前缀不显示；别的协议显示协议名
    static func split(_ u: URL) -> (String, String) {
        let s = u.absoluteString
        if let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = u.host {
            let hostPart = host + (u.port.map { ":\($0)" } ?? "")
            guard let r = s.range(of: hostPart) else { return (host, "") }
            var rest = String(s[r.upperBound...])
            if rest == "/" { rest = "" }
            return (hostPart, rest)
        }
        if let scheme = u.scheme, let r = s.range(of: ":") {
            var rest = String(s[r.upperBound...])
            if rest.hasPrefix("//") { rest.removeFirst(2) }
            return (scheme + ":", rest.isEmpty ? "" : " " + rest)
        }
        return (s, "")
    }

    /// 调试用
    var debugText: String {
        let (h, t) = { if case .link(let u) = code.kind { return Self.split(u) }; return (code.title, code.caption) }()
        return "kind=\(code.caption) title=\"\(h)\" detail=\"\(t)\" primary=\"\(primary.title ?? "")\" revealed=\(revealed)"
    }
}
