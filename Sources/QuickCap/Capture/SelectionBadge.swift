import AppKit

/// 选区左上角的标签。
/// 自由框选：两个数字可以直接点进去改，回车生效，Tab 换到另一个，Esc 放弃。
/// 选中窗口或整个屏幕：只显示名字和尺寸，不能改。
@MainActor
final class SelectionBadge: NSView, NSTextFieldDelegate {
    var onCommit: ((CGSize) -> Void)?
    /// 改完（回车或 Esc）后把键盘交回截图界面
    var onEndEditing: (() -> Void)?

    private let glass = NSGlassEffectView()
    private let row = NSStackView()
    private let wField = BadgeField()
    private let hField = BadgeField()
    private let times = NSTextField(labelWithString: "×")
    private let nameLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private var size = CGSize.zero

    static let height: CGFloat = 26
    static let cornerRadius: CGFloat = 9

    init() {
        super.init(frame: .zero)
        appearance = NSAppearance(named: .aqua)
        isHidden = true

        times.font = .systemFont(ofSize: 12, weight: .medium)
        times.textColor = NSColor(white: 0, alpha: 0.3)
        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.textColor = NSColor(white: 0, alpha: 0.85)
        nameLabel.lineBreakMode = .byTruncatingTail
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        sizeLabel.textColor = NSColor(white: 0, alpha: 0.5)
        for v in [nameLabel, sizeLabel, wField, times, hField] { row.addArrangedSubview(v) }
        nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true

        glass.style = .regular
        glass.cornerRadius = Self.cornerRadius
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        row.orientation = .horizontal
        row.detachesHiddenViews = true
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(row)
        glass.contentView = content
        for f in [wField, hField] { f.delegate = self }
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            row.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            content.heightAnchor.constraint(equalToConstant: Self.height),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 只是显示（窗口模式下跟着鼠标停着的窗口）：点击穿过去，交给下面的截图界面
    var clickThrough = false
    override func hitTest(_ point: NSPoint) -> NSView? { clickThrough ? nil : super.hitTest(point) }

    var width: CGFloat { row.fittingSize.width.rounded(.up) }
    var isEditing: Bool { wField.currentEditor() != nil || hField.currentEditor() != nil }

    /// 自由框选：两个数字。拖动途中只显示，松手后才能改
    func show(_ s: CGSize, editable: Bool) {
        size = s
        nameLabel.isHidden = true
        sizeLabel.isHidden = true
        for v in [wField, times, hField] { v.isHidden = false }
        row.spacing = 1
        row.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        if wField.currentEditor() == nil { wField.stringValue = "\(Int(s.width.rounded()))" }
        if hField.currentEditor() == nil { hField.stringValue = "\(Int(s.height.rounded()))" }
        for f in [wField, hField] { f.isEditable = editable; f.isSelectable = editable }
    }

    /// 窗口或整个屏幕：名字加尺寸，不能改
    func showLabel(_ name: String, size s: CGSize) {
        size = s
        nameLabel.stringValue = name
        sizeLabel.stringValue = "\(Int(s.width.rounded())) × \(Int(s.height.rounded()))"
        nameLabel.isHidden = name.isEmpty
        sizeLabel.isHidden = false
        for v in [wField, times, hField] { v.isHidden = true }
        row.spacing = 7
        row.edgeInsets = NSEdgeInsets(top: 0, left: 9, bottom: 0, right: 9)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            commit(); onEndEditing?(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            wField.stringValue = "\(Int(size.width.rounded()))"
            hField.stringValue = "\(Int(size.height.rounded()))"
            onEndEditing?(); return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            commit()
            window?.makeFirstResponder(control === wField ? hField : wField)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) { commit() }

    private func commit() {
        let w = Int(wField.stringValue.filter(\.isNumber)) ?? Int(size.width.rounded())
        let h = Int(hField.stringValue.filter(\.isNumber)) ?? Int(size.height.rounded())
        onCommit?(CGSize(width: max(4, w), height: max(4, h)))
    }

    // 调试用
    var debugText: String {
        if !sizeLabel.isHidden { return "\"\(nameLabel.stringValue)\" \(sizeLabel.stringValue)" }
        return "\(wField.stringValue)x\(hField.stringValue)\(isEditing ? " editing" : "")\(wField.isEditable ? "" : " readonly")"
    }

    func fieldCenter(_ which: Int, in v: NSView) -> CGPoint {
        let f = which == 0 ? wField : hField
        let r = f.convert(f.bounds, to: v)
        return CGPoint(x: r.midX, y: r.midY)
    }
}

/// 尺寸标签里的一个数字。点进去时整个数字选中，变成白底橙边
@MainActor
final class BadgeField: NSTextField {
    init() {
        super.init(frame: .zero)
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        alignment = .center
        font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        textColor = NSColor(white: 0, alpha: 0.82)
        usesSingleLineMode = true
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 40).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { setEditingLook(true) }
        return ok
    }

    /// 点进来直接全选，输入新数字就替换掉旧的
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        currentEditor()?.selectAll(nil)
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        setEditingLook(false)
    }

    private func setEditingLook(_ on: Bool) {
        layer?.backgroundColor = on ? NSColor.white.cgColor : nil
        layer?.borderWidth = on ? 1.5 : 0
        layer?.borderColor = NSColor(calibratedRed: 1, green: 0.58, blue: 0, alpha: 0.65).cgColor
    }
}
