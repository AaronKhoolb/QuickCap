import AppKit
import Carbon.HIToolbox

/// 收起后怎么唤出悬挂架
enum RevealTrigger: String, CaseIterable {
    /// 鼠标推到屏幕边上、把手滑出来后碰到它
    case hover
    /// 把手滑出来后点一下
    case click
}

/// 一个全局快捷键：键码 + Carbon 修饰键
struct HotKey: Equatable, Codable {
    var keyCode: UInt32
    var modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// 从按键事件生成。至少要有 ⌘、⌃、⌥ 其中一个，否则返回 nil
    init?(event: NSEvent) {
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        guard m & UInt32(cmdKey | controlKey | optionKey) != 0 else { return nil }
        let code = Int(event.keyCode)
        if !Self.functionKeys.contains(code) {
            // 全局快捷键会把这个组合从所有应用手里拿走：⌘C、⌘V、⌘Q 这种一录上，全系统复制粘贴就失效；
            // 只有 ⌥（打特殊字符用的）也不行。字母、数字、符号、空格这些键要带 ⌃，或者 ⌘ 再加别的修饰键
            let cmd = m & UInt32(cmdKey) != 0, ctrl = m & UInt32(controlKey) != 0
            let others = m & UInt32(shiftKey | optionKey | controlKey)
            if !ctrl && !(cmd && others != 0) { return nil }
            // ⇧⌘Z（重做）这种几乎每个应用都在用的也不收
            if m == UInt32(cmdKey | shiftKey), Self.commonShiftCommand.contains(code) { return nil }
        }
        self.init(keyCode: UInt32(event.keyCode), modifiers: m)
    }

    /// F1–F20：带什么修饰键都行
    private static let functionKeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                                 kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
    /// 各个应用常用的 ⇧⌘ 组合：重做、另存为、新文件夹、显示隐藏文件之类
    private static let commonShiftCommand: Set<Int> = [kVK_ANSI_Z, kVK_ANSI_S, kVK_ANSI_N, kVK_ANSI_T, kVK_ANSI_G, kVK_ANSI_Period,
                                                       kVK_ANSI_LeftBracket, kVK_ANSI_RightBracket, kVK_Tab]

    /// 显示用，比如 "⌃⌥⌘H"
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    /// 一个个键帽上的字：⌃ ⌥ ⇧ ⌘ 和键名（设置里画成一颗颗键）
    var glyphs: [String] {
        var g: [String] = []
        if modifiers & UInt32(controlKey) != 0 { g.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { g.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { g.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { g.append("⌘") }
        return g + [Self.keyName(keyCode)]
    }

    /// 菜单项右边显示的快捷键
    var menuKeyEquivalent: (String, NSEvent.ModifierFlags) {
        var f: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        // 菜单的按键要给真正的字符：空格是 " "、F5 是功能键字符，不能是 "space"、"f5"（以前菜单里会显示成那几个字母或者不显示）
        let fn: [Int: Int] = [kVK_F1: NSF1FunctionKey, kVK_F2: NSF2FunctionKey, kVK_F3: NSF3FunctionKey, kVK_F4: NSF4FunctionKey,
                              kVK_F5: NSF5FunctionKey, kVK_F6: NSF6FunctionKey, kVK_F7: NSF7FunctionKey, kVK_F8: NSF8FunctionKey,
                              kVK_F9: NSF9FunctionKey, kVK_F10: NSF10FunctionKey, kVK_F11: NSF11FunctionKey, kVK_F12: NSF12FunctionKey,
                              kVK_F13: NSF13FunctionKey, kVK_F14: NSF14FunctionKey, kVK_F15: NSF15FunctionKey, kVK_F16: NSF16FunctionKey,
                              kVK_F17: NSF17FunctionKey, kVK_F18: NSF18FunctionKey, kVK_F19: NSF19FunctionKey, kVK_F20: NSF20FunctionKey,
                              kVK_LeftArrow: NSLeftArrowFunctionKey, kVK_RightArrow: NSRightArrowFunctionKey,
                              kVK_UpArrow: NSUpArrowFunctionKey, kVK_DownArrow: NSDownArrowFunctionKey,
                              kVK_Home: NSHomeFunctionKey, kVK_End: NSEndFunctionKey, kVK_PageUp: NSPageUpFunctionKey,
                              kVK_PageDown: NSPageDownFunctionKey, kVK_ForwardDelete: NSDeleteFunctionKey]
        let plain: [Int: String] = [kVK_Space: " ", kVK_Return: "\r", kVK_Tab: "\t", kVK_Delete: "\u{8}", kVK_Escape: "\u{1b}",
                                    kVK_ANSI_KeypadEnter: "\u{3}"]
        if let u = fn[Int(keyCode)], let scalar = UnicodeScalar(u) { return (String(Character(scalar)), f) }
        if let p = plain[Int(keyCode)] { return (p, f) }
        return (Self.keyName(keyCode).lowercased(), f)
    }

    private static func keyName(_ code: UInt32) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "⎋",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
            kVK_F19: "F19", kVK_F20: "F20", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_ForwardDelete: "⌦", kVK_ANSI_KeypadEnter: "⌤",
        ]
        if let s = special[Int(code)] { return s }
        // 按当前键盘布局把键码翻译成字符
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// 用户设置，存在 UserDefaults 里。调试运行时不写入（persist = false）。
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    var persist = true

    @Published var revealTrigger: RevealTrigger { didSet { save("revealTrigger", revealTrigger.rawValue) } }
    @Published var side: ShelfSide { didSet { save("shelfSide", side.rawValue) } }
    @Published var toggleShelfKey: HotKey? { didSet { saveKey("toggleShelfKey", toggleShelfKey) } }
    @Published var captureKey: HotKey? { didSet { saveKey("captureKey", captureKey) } }
    @Published var captureTextKey: HotKey? { didSet { saveKey("captureTextKey", captureTextKey) } }
    /// 直接进区域、窗口、整个屏幕的快捷键（可选，默认不设；⇧⌘2 是 All-In-One，进上次用的模式）
    @Published var captureAreaKey: HotKey? { didSet { saveKey("captureAreaKey", captureAreaKey) } }
    @Published var captureWindowKey: HotKey? { didSet { saveKey("captureWindowKey", captureWindowKey) } }
    @Published var captureScreenKey: HotKey? { didSet { saveKey("captureScreenKey", captureScreenKey) } }

    // 截图选项（Options 菜单里的）
    @Published var captureMode: CaptureMode { didSet { save("captureMode", captureMode.rawValue) } }
    /// 计时秒数，0 表示不计时
    @Published var captureTimer: Int { didSet { if persist { UserDefaults.standard.set(captureTimer, forKey: "captureTimer") } } }
    @Published var snapToEdges: Bool { didSet { saveBool("snapToEdges", snapToEdges) } }
    @Published var showMagnifier: Bool { didSet { saveBool("showMagnifier", showMagnifier) } }
    @Published var freezeScreen: Bool { didSet { saveBool("freezeScreen", freezeScreen) } }
    @Published var showPointer: Bool { didSet { saveBool("showPointer", showPointer) } }
    @Published var rememberSelection: Bool { didSet { saveBool("rememberSelection", rememberSelection) } }

    // Capture（和回车）：一定保存到截图文件夹、挂上截图架；这里决定要不要同时放进剪贴板
    @Published var captureCopy: Bool { didSet { saveBool("captureCopy", captureCopy) } }
    /// 截图存在哪个文件夹（路径，可以带 ~）。截图架显示的就是这个文件夹
    @Published var screenshotFolder: String { didSet { save("screenshotFolder", screenshotFolder) } }
    static let defaultScreenshotFolder = "~/Pictures/QuickCap"
    var screenshotFolderURL: URL { URL(fileURLWithPath: (screenshotFolder as NSString).expandingTildeInPath, isDirectory: true) }
    @Published var captureSound: Bool { didSet { saveBool("captureSound", captureSound) } }
    /// 屏幕上有 HDR 内容时存成 HDR（HEIC）
    @Published var captureHDR: Bool { didSet { saveBool("captureHDR", captureHDR) } }
    /// 截窗口时带上系统的窗口阴影（和系统截图一样默认带；截的时候按住 ⌥ 反过来）
    @Published var windowShadow: Bool { didSet { saveBool("windowShadow", windowShadow) } }
    /// 窗口截图后面铺上桌面壁纸（窗口后面那一块），不是透明的
    @Published var windowWallpaper: Bool { didSet { saveBool("windowWallpaper", windowWallpaper) } }
    /// Scan 识别哪种语言："auto" 自动判断，或者 Vision 的语言代码（zh-Hans、en-US……）
    @Published var scanLanguage: String { didSet { save("scanLanguage", scanLanguage) } }
    /// Scan 复制文字时保留原来的换行；关掉就把一行行接成一段
    @Published var scanKeepLineBreaks: Bool { didSet { saveBool("scanKeepLineBreaks", scanKeepLineBreaks) } }
    /// 截图文件存成哪种格式
    @Published var captureFormat: CaptureOutput.Format { didSet { save("captureFormat", captureFormat.rawValue) } }
    /// 上次的自由框选（屏幕坐标），"记住上次选区"和 R 键用
    var lastCaptureRect: CGRect? {
        didSet {
            guard persist else { return }
            UserDefaults.standard.set(lastCaptureRect.map { NSStringFromRect($0) }, forKey: "lastCaptureRect")
        }
    }
    /// 展开后多久没操作就自动收起（秒），0 表示不自动收起
    @Published var autoHideDelay: Double {
        didSet { if persist { UserDefaults.standard.set(autoHideDelay, forKey: "autoHideDelay") } }
    }
    static let autoHideChoices: [Double] = [2, 3, 5, 10, 0]
    /// 注册失败（被别的 app 占用）的快捷键
    @Published var conflictingKeys: Set<HotKeyID> = []
    /// 和 macOS 自己的快捷键重复、因此没有注册的
    @Published var reservedKeys: Set<HotKeyID> = []

    enum HotKeyID: UInt32 {
        case toggleShelf = 1
        /// 鼠标停在悬挂架上时临时注册的 Esc
        case escape = 2
        case capture = 3
        case captureText = 4
        /// 倒计时期间临时注册的 Esc
        case captureEscape = 5
        case captureArea = 6
        case captureWindow = 7
        case captureScreen = 8
        /// 鼠标停在截图架上时临时注册的 ⌘F（搜索）
        case shelfFind = 9
        /// 鼠标停在卡片上时临时注册的空格（快速查看）、Delete（删除）、⌘C（复制）
        case cardQuickLook = 10
        case cardTrash = 11
        case cardCopy = 12
    }

    private init() {
        let d = UserDefaults.standard
        revealTrigger = RevealTrigger(rawValue: d.string(forKey: "revealTrigger") ?? "") ?? .hover
        side = ShelfSide(rawValue: d.string(forKey: "shelfSide") ?? "") ?? .right
        // 快捷键默认都不绑：第一次打开时在欢迎页自己选，不选也行（菜单栏里都能点）
        toggleShelfKey = Self.loadKey("toggleShelfKey", default: nil)
        captureKey = Self.loadKey("captureKey", default: nil)
        captureTextKey = Self.loadKey("captureTextKey", default: nil)
        captureAreaKey = Self.loadKey("captureAreaKey", default: nil)
        captureWindowKey = Self.loadKey("captureWindowKey", default: nil)
        captureScreenKey = Self.loadKey("captureScreenKey", default: nil)
        captureMode = CaptureMode(rawValue: d.string(forKey: "captureMode") ?? "") ?? .area
        captureTimer = d.object(forKey: "captureTimer") as? Int ?? 0
        snapToEdges = d.object(forKey: "snapToEdges") as? Bool ?? true
        showMagnifier = d.object(forKey: "showMagnifier") as? Bool ?? false
        freezeScreen = d.object(forKey: "freezeScreen") as? Bool ?? true
        showPointer = d.object(forKey: "showPointer") as? Bool ?? false
        rememberSelection = d.object(forKey: "rememberSelection") as? Bool ?? false
        captureCopy = d.object(forKey: "captureCopy") as? Bool ?? true
        captureHDR = d.object(forKey: "captureHDR") as? Bool ?? true
        windowShadow = d.object(forKey: "windowShadow") as? Bool ?? true
        windowWallpaper = d.object(forKey: "windowWallpaper") as? Bool ?? false
        scanLanguage = d.string(forKey: "scanLanguage") ?? "auto"
        scanKeepLineBreaks = d.object(forKey: "scanKeepLineBreaks") as? Bool ?? true
        captureFormat = d.string(forKey: "captureFormat").flatMap(CaptureOutput.Format.init(rawValue:)) ?? .heic
        screenshotFolder = d.string(forKey: "screenshotFolder") ?? Self.defaultScreenshotFolder
        captureSound = d.object(forKey: "captureSound") as? Bool ?? false
        lastCaptureRect = d.string(forKey: "lastCaptureRect").map { NSRectFromString($0) }.flatMap { $0.width >= 4 ? $0 : nil }
        autoHideDelay = d.object(forKey: "autoHideDelay") as? Double ?? 3
    }

    private func saveBool(_ key: String, _ value: Bool) {
        guard persist else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    private func save(_ key: String, _ value: String) {
        guard persist else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    /// 清除快捷键时存一个空值，和"从没设置过"（用默认值）区分开
    private func saveKey(_ key: String, _ value: HotKey?) {
        guard persist else { return }
        let data = value.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func loadKey(_ key: String, default value: HotKey?) -> HotKey? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return value }
        return data.isEmpty ? nil : try? JSONDecoder().decode(HotKey.self, from: data)
    }
}

/// 用 Carbon 注册全局快捷键。不需要辅助功能权限，app 在后台也能收到。
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var installed = false

    /// 注册或替换 id 对应的快捷键。返回 false 表示被别的 app 占用了
    @discardableResult
    func register(id: UInt32, _ key: HotKey?, handler: @escaping () -> Void) -> Bool {
        installHandler()
        if let old = refs.removeValue(forKey: id) { UnregisterEventHotKey(old) }
        handlers[id] = handler
        guard let key else { return true }
        var ref: EventHotKeyRef?
        let hid = EventHotKeyID(signature: OSType(0x4853_4854), id: id) // 'HSHT'
        let status = RegisterEventHotKey(key.keyCode, key.modifiers, hid, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        return true
    }

    /// 录制快捷键时先暂停，免得按下当前组合就触发了
    func setPaused(_ paused: Bool) {
        if paused {
            for (_, ref) in refs { UnregisterEventHotKey(ref) }
            refs = [:]
        } else {
            NotificationCenter.default.post(name: .hotKeysNeedRegistration, object: nil)
        }
    }

    func isRegistered(_ id: UInt32) -> Bool { refs[id] != nil }

    fileprivate func fire(_ id: UInt32) { handlers[id]?() }

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hid = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hid)
            let id = hid.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeyCenter.shared.fire(id) } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// 截图界面的模式。screen 不会被记住：点一下就直接选中整个屏幕
enum CaptureMode: String, CaseIterable {
    case screen, window, area, text
}

/// macOS 自己占用的快捷键（系统设置 → 键盘 → 键盘快捷键里启用的那些）。
/// 不注册和它们重复的组合，免得把系统截图之类的功能顶掉。
enum SystemHotKeys {
    static func isReserved(_ key: HotKey) -> Bool {
        var arr: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&arr) == noErr, let list = arr?.takeRetainedValue() as? [[String: Any]] else { return false }
        let mask = UInt32(cmdKey | shiftKey | optionKey | controlKey)
        return list.contains { d in
            guard (d[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = d[kHISymbolicHotKeyCode as String] as? Int,
                  let mods = d[kHISymbolicHotKeyModifiers as String] as? Int else { return false }
            return UInt32(code) == key.keyCode && UInt32(mods) & mask == key.modifiers & mask
        }
    }
}

extension Notification.Name {
    static let hotKeysNeedRegistration = Notification.Name("QuickCapHotKeysNeedRegistration")
}
