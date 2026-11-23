import AppKit

/// 滚动截图时的两个小面板（截图界面那时是点穿的，只有它们能点）：
/// - 条：● 状态 │ 自动滚动 │ Cancel  [Done]。状态跟着真的在发生的事变：
///   还没滚 → 灰点"Scroll to Start"；在滚 → 红点一闪一闪"Scrolling"；停下了 → 灰点"Paused"；
///   自动滚动 → 红点"Auto Scrolling"；自动滚到底 → 绿点"Reached the End"；滚太快 → 橙色提示
/// - 选区旁边一条竖的预览：拼好的图越来越长，只显示最下面那一截，下面写现在多少像素
@MainActor
final class ScrollBar: GlassBar {
    var onCancel: (() -> Void)?
    var onDone: (() -> Void)?
    var onAuto: (() -> Void)?
    private let dot = NSView()
    private var autoButton: BarButton!
    private var auto = false
    private let status = NSTextField(labelWithString: "Scroll to Start")

    enum State: Equatable {
        case waiting, scrolling, paused, auto
        case done(String)
        case warning(String)
    }
    private(set) var state: State = .waiting

    init() {
        super.init(frame: .zero)
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor(white: 0, alpha: 0.28).cgColor
        dot.layer?.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 7).isActive = true
        status.font = .systemFont(ofSize: 13, weight: .medium)
        status.textColor = NSColor(white: 0, alpha: 0.75)
        let left = NSStackView(views: [dot, status])
        left.spacing = 7
        left.alignment = .centerY
        left.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 6)
        let a = BarButton(symbol: "arrow.down.circle", pointSize: 16, width: 36)
        a.help("Auto Scroll", key: "A", sub: "Scrolls for you at a steady speed")
        a.onClick = { [weak self] _ in self?.onAuto?() }
        autoButton = a
        let cancel = BarButton(title: "Cancel", trailingSymbol: nil, padding: 12)
        cancel.label?.textColor = NSColor(white: 0, alpha: 0.62)
        cancel.help("Cancel", key: "Esc")
        cancel.onClick = { [weak self] _ in self?.onCancel?() }
        let done = PrimaryButton(title: "Done")
        done.help("Finish and capture", key: "↩")
        done.onClick = { [weak self] _ in self?.onDone?() }
        for v in [left, BarSeparator(), a, BarSeparator(), cancel, done] { stack.addArrangedSubview(v) }
        stack.setCustomSpacing(4, after: cancel)
        setupGlass()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 条上的状态（点的颜色、闪不闪、字）。一样就什么都不做（每帧都会调）
    func setState(_ st: State) {
        guard st != state else { return }
        state = st
        let text: String, color: NSColor, pulse: Bool
        var warn = false
        switch st {
        case .waiting: text = "Scroll to Start"; color = NSColor(white: 0, alpha: 0.28); pulse = false
        case .scrolling: text = "Scrolling"; color = .systemRed; pulse = true
        case .paused: text = "Paused"; color = NSColor(white: 0, alpha: 0.28); pulse = false
        case .auto: text = "Auto Scrolling"; color = .systemRed; pulse = true
        case .done(let s): text = s; color = .systemGreen; pulse = false
        case .warning(let s): text = s; color = .systemOrange; pulse = false; warn = true
        }
        status.stringValue = text
        status.textColor = warn ? NSColor.systemOrange.blended(withFraction: 0.25, of: .black) ?? .systemOrange : NSColor(white: 0, alpha: 0.75)
        if let l = dot.layer {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.2)
            l.backgroundColor = color.cgColor
            CATransaction.commit()
            // 一闪一闪（录着的意思），减少动态效果时不闪
            if pulse && !ReduceMotion.isOn {
                if l.animation(forKey: "pulse") == nil {
                    let a = CABasicAnimation(keyPath: "opacity")
                    a.fromValue = 1
                    a.toValue = 0.35
                    a.duration = 0.8
                    a.autoreverses = true
                    a.repeatCount = .infinity
                    l.add(a, forKey: "pulse")
                }
            } else {
                l.removeAnimation(forKey: "pulse")
            }
        }
        // 字的长短变了：条跟着变宽（居中）
        if let p = window as? FloatingPanel {
            let old = p.frame
            let size = fittingSize
            let f = CGRect(x: old.midX - size.width / 2, y: old.minY + FloatingPanel.margin, width: size.width, height: size.height)
            if abs(f.width + FloatingPanel.margin * 2 - old.width) > 0.5 { p.place(f) }
        }
    }

    /// 调试用：直接显示自动滚动按钮的悬停提示
    func debugShowAutoTip() {
        showTooltip(autoButton.tipTitle ?? "", key: autoButton.tipKey, sub: autoButton.tipSub, over: autoButton)
    }

    /// 自动滚动开着：按钮变成暂停，字跟着变
    func setAuto(_ on: Bool) {
        guard on != auto else { return }
        auto = on
        autoButton.isSelected = on
        autoButton.setSymbol(on ? "pause.circle" : "arrow.down.circle")
        autoButton.help(on ? "Stop Auto Scroll" : "Auto Scroll", key: "A", sub: on ? nil : "Scrolls for you at a steady speed")
    }
}

/// 装一根玻璃条或一块预览的小面板。浮在截图界面上面，能点；外面留一圈给阴影
@MainActor
final class FloatingPanel: NSPanel {
    static let margin: CGFloat = 24
    let content: NSView

    init(content: NSView) {
        self.content = content
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        level = NSWindow.Level(rawValue: CaptureOverlayWindow.captureLevel.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        animationBehavior = .none
        isReleasedWhenClosed = false
        let v = NSView()
        v.wantsLayer = true
        contentView = v
        content.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(content)
        let m = Self.margin
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: m),
            content.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -m),
            content.topAnchor.constraint(equalTo: v.topAnchor, constant: m),
            content.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -m),
        ])
    }

    /// 内容放在屏幕上的 rect（不含留白）
    func place(_ r: CGRect) {
        setFrame(r.insetBy(dx: -Self.margin, dy: -Self.margin), display: true)
    }

    func present() {
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        (content as? GlassBar)?.hideTooltip()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in MainActor.assumeIsolated { self?.orderOut(nil) } })
    }
}

/// 竖的预览：白卡片里是拼好的图（宽度撑满，只显示最下面那一截），底部渐隐，写着多高
@MainActor
final class ScrollPreview: NSView {
    private let card = CALayer()
    private let image = CALayer()
    private let fade = CAGradientLayer()
    private let label = NSTextField(labelWithString: "")
    private let glass = NSGlassEffectView()
    static let width: CGFloat = 104

    /// 放下一张这么大（像素）的图要多高：卡片宽度按比例算出来的高，加上下面写像素的那一行
    static func height(forImageWidth w: CGFloat, imageHeight h: CGFloat) -> CGFloat {
        guard w > 0 else { return 120 }
        return ((width - 14) * h / w + 31).rounded()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        appearance = NSAppearance(named: .aqua)
        glass.cornerRadius = 12
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        let inner = NSView()
        inner.wantsLayer = true
        inner.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView = inner
        label.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        label.textColor = NSColor(white: 0, alpha: 0.5)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        inner.addSubview(label)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.centerXAnchor.constraint(equalTo: inner.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: inner.bottomAnchor, constant: -7),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])
        card.backgroundColor = NSColor.white.cgColor
        card.cornerRadius = 6
        card.masksToBounds = true
        card.borderWidth = 0.5
        card.borderColor = NSColor(white: 0, alpha: 0.1).cgColor
        image.contentsGravity = .bottom
        image.minificationFilter = .trilinear
        card.addSublayer(image)
        fade.colors = [NSColor(white: 1, alpha: 0).cgColor, NSColor(white: 1, alpha: 0.85).cgColor]
        fade.startPoint = CGPoint(x: 0.5, y: 1)
        fade.endPoint = CGPoint(x: 0.5, y: 0)
        card.addSublayer(fade)
        inner.layer?.addSublayer(card)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        card.frame = CGRect(x: 7, y: 24, width: bounds.width - 14, height: max(0, bounds.height - 31))
        image.frame = card.bounds
        fade.frame = CGRect(x: 0, y: 0, width: card.bounds.width, height: 26)
        CATransaction.commit()
    }

    /// 拼好的图（小的，按卡片宽度缩好的）和真的高度（像素）
    func update(_ img: CGImage?, pixelHeight: Int, scale: CGFloat) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        image.contents = img
        image.contentsScale = scale
        // 还没卡片高：从上往下长；比卡片高了：只看最下面新接上的那一截
        let h = CGFloat(img?.height ?? 0) / max(scale, 1)
        image.contentsGravity = h <= card.bounds.height ? .top : .bottom
        CATransaction.commit()
        let f = NumberFormatter()
        f.numberStyle = .decimal
        label.stringValue = "\(f.string(from: NSNumber(value: pixelHeight)) ?? "\(pixelHeight)") px"
    }
}
