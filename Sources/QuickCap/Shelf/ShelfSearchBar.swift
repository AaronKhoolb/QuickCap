import AppKit

/// 截图架上的搜索框：浮在绳子下面正中间的一根玻璃条（放大镜、输入框、"3 of 12"、✕）。
/// 输入就搜；回车跳到下一张对上的、⇧回车上一张；Esc 或 ✕ 收起
@MainActor
final class ShelfSearchBar: NSPanel, NSTextFieldDelegate {
    var onChange: ((String) -> Void)?
    var onNext: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    private let field = NSTextField()
    private let count = NSTextField(labelWithString: "")
    static let size = CGSize(width: 320, height: 34)

    init() {
        super.init(contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = NSWindow.Level(rawValue: CaptureOverlayWindow.captureLevel.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        animationBehavior = .none
        appearance = NSAppearance(named: .aqua)

        let glass = NSGlassEffectView(frame: CGRect(origin: .zero, size: Self.size))
        glass.cornerRadius = Self.size.height / 2
        glass.autoresizingMask = [.width, .height]
        let content = NSView(frame: glass.bounds)
        glass.contentView = content
        contentView = glass

        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))!)
        icon.contentTintColor = NSColor(white: 0, alpha: 0.5)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13.5)
        field.placeholderString = "Search text in captures"
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        count.textColor = NSColor(white: 0, alpha: 0.45)
        count.alignment = .right
        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")!
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))!, target: self, action: #selector(closeTapped))
        close.isBordered = false
        close.contentTintColor = NSColor(white: 0, alpha: 0.3)
        close.toolTip = "Close (Esc)"
        for v in [icon, field, count, close] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 13),
            icon.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            field.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            count.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 6),
            count.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            count.widthAnchor.constraint(greaterThanOrEqualToConstant: 54),
            close.leadingAnchor.constraint(equalTo: count.trailingAnchor, constant: 6),
            close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -9),
            close.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    override var canBecomeKey: Bool { true }

    /// 放在 rect（屏幕坐标）上边往下 top 的地方，水平居中；淡入
    func present(centeredIn rect: CGRect, top: CGFloat) {
        let f = CGRect(x: (rect.midX - Self.size.width / 2).rounded(), y: (rect.maxY - top - Self.size.height).rounded(),
                       width: Self.size.width, height: Self.size.height)
        setFrame(f, display: true)
        alphaValue = 0
        orderFrontRegardless()
        makeKey()
        makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in MainActor.assumeIsolated { self?.orderOut(nil) } })
    }

    var query: String { field.stringValue }
    func setQuery(_ s: String) { field.stringValue = s; onChange?(s) }

    /// "3 of 12" / "No matches" / "Reading 5…"（还在认字时）
    func setCount(current: Int?, total: Int, pending: Int) {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            count.stringValue = pending > 0 ? "Reading \(pending)…" : ""
        } else if total == 0 {
            count.stringValue = pending > 0 ? "Reading \(pending)…" : "No matches"
        } else {
            count.stringValue = current.map { "\($0 + 1) of \(total)" } ?? "\(total)"
        }
    }

    func controlTextDidChange(_ obj: Notification) { onChange?(field.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            onNext?(!(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) { onClose?(); return true }
        return false
    }

    @objc private func closeTapped() { onClose?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?(); return }
        super.keyDown(with: event)
    }
}
