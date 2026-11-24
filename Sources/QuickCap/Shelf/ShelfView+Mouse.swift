import AppKit

extension ShelfView: NSDraggingSource {
    /// 视图坐标（y 向上）转根图层坐标（y 向下）。
    func layerPoint(_ viewPoint: NSPoint) -> CGPoint {
        CGPoint(x: viewPoint.x, y: bounds.height - viewPoint.y)
    }

    func card(at layerPoint: CGPoint) -> CardNode? {
        cards.reversed().first { $0.phase == .hanging && $0.contains(layerPoint, in: root) }
    }

    /// 由控制器在鼠标移动时调用。返回鼠标是否在某张卡片上。
    @discardableResult
    func updateHover(at layerPoint: CGPoint) -> Bool {
        if hoverLocked { return hovered != nil }
        if reorderingCard != nil { return true }
        // 撤销条：鼠标在上面时要能点，卡片悬停先放下
        let onUndo = undoPill.contains(layerPoint)
        undoPill.setHot(onUndo)
        if onUndo {
            if hovered != nil { clearHover() }
            return true
        }
        // 正在滚动时卡片会从鼠标下面滑过，不切换悬停，停下后再判断（见 ShelfView.tick）
        if isScrollGestureActive || !scroll.isSettled {
            pendingHoverPoint = layerPoint
            return isInScrollBand(layerPoint)
        }
        let hit = isShown ? card(at: layerPoint) : nil
        if hit !== hovered {
            hovered?.hoverTarget = 0
            hit?.hoverTarget = 1
            hovered = hit
            // 鼠标停上来就在后台把 HEIC 转好 PNG：真拖出去时不用在主线程上现转（大图要零点几秒，抓起那一下会卡）
            // 停 0.35 秒才转：鼠标扫过一排卡片时不会每张都整张解码一遍
            prefetchWork?.cancel()
            if let hit {
                let url = hit.item.url
                let w = DispatchWorkItem { ShelfDragWriter.prefetch(url) }
                prefetchWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
            }
            wake()
        }
        if let hit, let last = lastHoverPoint {
            // 鼠标划过卡片时顺手轻推一下，幅度单独限制得很小
            let dx = layerPoint.x - last.x
            if abs(dx) > 0.5 { hit.nudge(dx * Metrics.hoverPushGain, maxAngle: Metrics.hoverMaxAngle); wake() }
        }
        lastHoverPoint = hit == nil ? nil : layerPoint
        hit?.hoveredAction = hit?.action(at: layerPoint, in: root)
        // 能滚动时整排横条都接收鼠标，在卡片之间的空隙里也能滑
        return hit != nil || isInScrollBand(layerPoint)
    }

    func clearHover() {
        hovered?.hoveredAction = nil
        hovered?.hoverTarget = 0
        hovered = nil
        lastHoverPoint = nil
        wake()
    }

    override func mouseDown(with event: NSEvent) {
        let p = layerPoint(convert(event.locationInWindow, from: nil))
        if undoPill.contains(p) {
            undoPill.fire()
            delegate?.shelfViewDidInteract(self)
            return
        }
        pressed = card(at: p)
        pressedAction = pressed?.action(at: p, in: root)
        pressPoint = p
        emptyPressPoint = pressed == nil ? p : nil
        delegate?.shelfViewDidInteract(self)
    }

    /// 置顶的卡片：横着拖在置顶的那几张之间调整顺序，竖着拖（或拖动中往下拉远）就拖出到其他应用。
    /// 没置顶的卡片按时间排，只能拖出去。
    override func mouseDragged(with event: NSEvent) {
        let p = layerPoint(convert(event.locationInWindow, from: nil))
        if let card = reorderingCard {
            if abs(p.y - pressPoint.y) > Metrics.dragOutThreshold {
                endReorder(card)
                beginDrag(card, event: event)
            } else {
                updateReorder(screenX: p.x - reorderGrabOffset)
            }
            delegate?.shelfViewDidInteract(self)
            return
        }
        guard let card = pressed, pressedAction == nil else { return }
        let dx = p.x - pressPoint.x, dy = p.y - pressPoint.y
        guard hypot(dx, dy) > Metrics.reorderThreshold else { return }
        pressed = nil
        if card.isPinned, live.filter(\.isPinned).count > 1, abs(dx) > abs(dy) {
            reorderGrabOffset = pressPoint.x - card.x
            beginReorder(card)
            updateReorder(screenX: p.x - reorderGrabOffset)
        } else {
            beginDrag(card, event: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil; pressedAction = nil; emptyPressPoint = nil }
        if let e = emptyPressPoint, pressed == nil, reorderingCard == nil {
            let p = layerPoint(convert(event.locationInWindow, from: nil))
            // 卡片多到要滚动时，卡片之间的空处也接收鼠标（为了能在空处滑），以前点了什么都不发生，还挡住下面应用的点击
            if hypot(p.x - e.x, p.y - e.y) < 4 { delegate?.shelfViewDidClickEmpty(self) }
            return
        }
        if let card = reorderingCard {
            endReorder(card)
            // 松手后按鼠标位置重新判断悬停
            pendingHoverPoint = layerPoint(convert(event.locationInWindow, from: nil))
            return
        }
        guard let card = pressed else { return }
        let p = layerPoint(convert(event.locationInWindow, from: nil))
        if let action = pressedAction {
            if card.action(at: p, in: root) == action {
                lastActionClickAt = CACurrentMediaTime()
                delegate?.shelfView(self, perform: action, on: card.item)
            }
            return
        }
        // 刚点了按钮（比如删掉一张），旁边那张正滑到鼠标下面：这一下是冲着按钮去的，不打开、不拿去改
        if CACurrentMediaTime() - lastActionClickAt < NSEvent.doubleClickInterval || !card.slide.isSettled { return }
        if card.contains(p, in: root) {
            // 单击马上打开（以前要等一个双击间隔、看是不是双击，点了要愣 0.5 秒）。
            // 拿下来改：工具栏上的 Annotate，或者按着 ⌥ 单击。双击的第二下不再做什么（不会打开两次）
            if event.clickCount >= 2 { return }
            card.push(angle: 0.05)
            wake()
            if event.modifierFlags.contains(.option) {
                delegate?.shelfView(self, didDoubleClick: card.item)
            } else {
                delegate?.shelfView(self, didClick: card.item)
            }
        }
    }

    /// 右键卡片：卡片的菜单，最后加一项"跳到"。右键绳子上卡片之间的空处：只有日期列表
    override func rightMouseDown(with event: NSEvent) {
        let p = layerPoint(convert(event.locationInWindow, from: nil))
        let menu: NSMenu
        if let card = card(at: p), let m = delegate?.shelfView(self, menuFor: card.item) {
            menu = m
            if let days = dayMenu() {
                menu.addItem(.separator())
                let item = NSMenuItem(title: "Jump To", action: nil, keyEquivalent: "")
                item.submenu = days
                menu.addItem(item)
            }
        } else if isInScrollBand(p), let days = dayMenu() {
            menu = days
            delegate?.shelfViewWillShowMenu(self)
        } else {
            return
        }
        delegate?.shelfViewDidInteract(self)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func shotCount(_ n: Int) -> String { n == 1 ? "1 shot" : "\(n) shots" }

    /// 日期列表：置顶一项，然后每天一项（写着几张），当前看到的那一天打勾。
    /// 一屏放得下、或者只有一天时没有必要，返回 nil
    func dayMenu() -> NSMenu? {
        guard canScroll, dayGroups.count + (pinnedCount > 0 ? 1 : 0) > 1 else { return nil }
        let menu = NSMenu()
        let current = leadingEntryIndex
        if pinnedCount > 0 {
            let item = ClosureMenuItem("Pinned · \(shotCount(pinnedCount))") { [weak self] in self?.jump(toIndex: 0) }
            item.state = current < pinnedCount ? .on : .off
            menu.addItem(item)
        }
        for g in dayGroups {
            let item = ClosureMenuItem("\(ShelfDates.title(for: g.day)) · \(shotCount(g.count))") { [weak self] in
                self?.jump(toIndex: g.index)
            }
            item.state = (g.index..<(g.index + g.count)).contains(current) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    /// 把第 i 张滑到最靠前的位置（那一天最新的那张靠边），日期牌跟着出来
    func jump(toIndex i: Int) {
        userScrolling = true
        jumpLabelIndex = i
        settleScroll(to: CGFloat(i) * Metrics.slotSpacing)
        delegate?.shelfViewDidInteract(self)
        wake()
    }

    // MARK: 拖出到其他应用

    private func beginDrag(_ card: CardNode, event: NSEvent) {
        clearHover()
        let item = NSDraggingItem(pasteboardWriter: ShelfDragWriter(url: card.item.url))
        // 拖动的图按卡片摆正的样子画，放在卡片现在的中心
        let c = card.container.convert(CGPoint(x: card.body.frame.midX, y: card.body.frame.midY), to: root)
        let s = card.size
        let viewRect = NSRect(x: c.x - s.width / 2, y: bounds.height - c.y - s.height / 2, width: s.width, height: s.height)
        item.setDraggingFrame(viewRect, contents: dragImage(for: card))
        card.body.opacity = 0.35
        draggingCard = card
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        delegate?.shelfViewDidInteract(self)
    }

    /// 拖动时跟着鼠标的图：圆角缩略图
    private func dragImage(for card: CardNode) -> NSImage {
        guard let thumb = card.thumbnail else { return NSWorkspace.shared.icon(forFile: card.item.url.path) }
        let corner = Metrics.cardCorner
        return NSImage(size: card.size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: corner, yRadius: corner)
            NSColor(white: 0.97, alpha: 1).setFill()
            path.fill()
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState()
                path.addClip()
                // 和卡片一样铺满裁切
                let iw = CGFloat(thumb.width), ih = CGFloat(thumb.height)
                let k = max(rect.width / iw, rect.height / ih)
                ctx.interpolationQuality = .high
                ctx.draw(thumb, in: CGRect(x: rect.midX - iw * k / 2, y: rect.midY - ih * k / 2, width: iw * k, height: ih * k))
                ctx.restoreGState()
            }
            NSColor(white: 0, alpha: 0.12).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            return true
        }
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        // 悬挂架是盖住整块屏幕的透明窗口。拖动开始后必须让它点穿，
        // 否则鼠标下面永远是它自己，别的应用收不到拖进来的图（之前拖不出去就是这个）
        window?.ignoresMouseEvents = true
    }

    /// 只给复制：访达在同一个磁盘里收到"通用"操作会当成移动，截图就被从文件夹里挪走了
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if let url = draggingCard?.item.url { ShelfDragWriter.dragEnded(url) }
        if let card = draggingCard {
            if operation.isEmpty {
                // 没放下去：系统已经把图滑回卡片上了，卡片马上恢复，
                // 再朝松手的方向那边晃一下，像被拉了一下又弹回来
                withoutAnimation { card.body.opacity = card.isSearchDimmed ? 0.32 : 1 }
                var dir: CGFloat = 1
                if let window {
                    let p = layerPoint(convert(window.convertPoint(fromScreen: screenPoint), from: nil))
                    dir = p.x < card.x ? -1 : 1
                }
                card.push(angle: Metrics.dragCancelSwing * dir)
            } else {
                // 放下去了：慢慢恢复，轻轻晃一下
                let fade = CABasicAnimation(keyPath: "opacity")
                let target: Float = card.isSearchDimmed ? 0.32 : 1
                fade.fromValue = card.body.opacity
                fade.toValue = target
                fade.duration = 0.25
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                card.body.opacity = target
                card.body.add(fade, forKey: "dropFade")
                card.push(angle: 0.06)
            }
        }
        draggingCard = nil
        wake()
        delegate?.shelfViewDidInteract(self)
        delegate?.shelfViewDidEndDragOut(self)
    }
}

/// 拖出去的内容：文件（访达、邮件、聊天软件收文件），再附一份 PNG 和 TIFF 图片数据，
/// 给只收图片、不收文件的应用。截图文件是 HEIC 的话，拖出去的文件是转好的 PNG（放在临时文件夹，名字不变），
/// 发给别人、传网页、给 Windows 都能用；截图文件夹里的原图不动。
final class ShelfDragWriter: NSObject, NSPasteboardWriting {
    let url: URL
    private let outURL: URL
    private var file: NSPasteboardWriting { outURL as NSURL }

    init(url: URL) {
        self.url = url
        outURL = Self.pngFile(for: url) ?? url
    }

    /// HEIC 之类的转成同名 PNG，放在临时文件夹。本来就是 PNG 或者转不了就用原文件。
    /// 按"原文件的路径 + 修改时间"分文件夹放：改过的图、不同文件夹里同名的图不会拖出去旧的那张
    static func pngFile(for url: URL) -> URL? {
        guard url.pathExtension.lowercased() != "png" else { return nil }
        let dir = folder(for: url)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".png")
        if FileManager.default.fileExists(atPath: dst.path) { remember(dir); return dst }
        guard let data = pngData(of: url), (try? data.write(to: dst, options: .atomic)) != nil else { return nil }
        remember(dir)
        return dst
    }

    /// 这张图转好的 PNG 放在哪个文件夹（只算路径，不建）
    private static func folder(for url: URL) -> URL {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSinceReferenceDate ?? 0
        // 固定的哈希（FNV-1a）：系统的 Hasher 每次启动种子都不一样，重开以后就找不到上次转好的了
        var h: UInt64 = 0xcbf29ce484222325
        for b in "\(url.standardizedFileURL.path)|\(modified)".utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        let key = String(h, radix: 36)
        return FileManager.default.temporaryDirectory.appendingPathComponent("QuickCap Drag/\(key)", isDirectory: true)
    }

    /// 转好的 PNG 最多留几张（最近停过、拖过的），再多就删最旧的：临时文件夹不会越堆越大
    private static let keepCount = 3
    private static let keepLock = NSLock()
    nonisolated(unsafe) private static var kept: [URL] = []
    private static func remember(_ dir: URL) {
        keepLock.lock()
        kept.removeAll { $0 == dir }
        kept.append(dir)
        let old = kept.count > keepCount ? Array(kept.prefix(kept.count - keepCount)) : []
        kept.removeFirst(old.count)
        keepLock.unlock()
        for d in old { try? FileManager.default.removeItem(at: d) }
    }

    /// 拖完了：过两分钟删掉这张转好的（收的 app 放下后还要读一会儿文件，马上删会读不到）
    static func dragEnded(_ url: URL) {
        guard url.pathExtension.lowercased() != "png" else { return }
        let dir = folder(for: url)
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 120) {
            keepLock.lock(); kept.removeAll { $0 == dir }; keepLock.unlock()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// 提前在后台转好（鼠标停在卡片上时）。排成一队一张张转、同一张不重复排：
    /// 鼠标扫过一排卡片时不会同时开十几个解码，也不会两个一起写同一个文件
    private static let prefetchQueue = DispatchQueue(label: "QuickCap.dragPNG", qos: .utility)
    private static let pendingLock = NSLock()
    nonisolated(unsafe) private static var pending: Set<URL> = []
    /// 上次运行留下的拖出去用的 PNG（启动时清掉，不然临时文件夹一直变大）
    static func clearCache() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("QuickCap Drag", isDirectory: true)
        DispatchQueue.global(qos: .background).async { try? FileManager.default.removeItem(at: dir) }
    }

    static func prefetch(_ url: URL) {
        guard url.pathExtension.lowercased() != "png" else { return }
        pendingLock.lock()
        let fresh = pending.insert(url).inserted
        pendingLock.unlock()
        guard fresh else { return }
        prefetchQueue.async {
            _ = pngFile(for: url)
            pendingLock.lock(); pending.remove(url); pendingLock.unlock()
        }
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types = file.writableTypes(for: pasteboard)
        for t in [NSPasteboard.PasteboardType.png, .tiff] where !types.contains(t) { types.append(t) }
        return types
    }

    func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        if type == .png || type == .tiff { return .promised }
        return file.writingOptions?(forType: type, pasteboard: pasteboard) ?? []
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .png: return Self.pngData(of: outURL)
        case .tiff: return NSImage(contentsOf: outURL)?.tiffRepresentation
        default: return file.pasteboardPropertyList(forType: type)
        }
    }

    /// 文件的 PNG 数据：本来就是 PNG 直接读，其他格式转一下。读不出来返回 nil
    static func pngData(of url: URL) -> Data? {
        if url.pathExtension.lowercased() == "png" { return try? Data(contentsOf: url) }
        // 带增益图的 HEIC：这样读出来的是普通（SDR）的那张底图
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let data = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        // 留着像素倍数，2x 的图在别的应用里还是原大小
        var opts: [CFString: Any] = [:]
        if let dpi = props?[kCGImagePropertyDPIWidth] { opts[kCGImagePropertyDPIWidth] = dpi; opts[kCGImagePropertyDPIHeight] = dpi }
        CGImageDestinationAddImage(dst, image, opts as CFDictionary)
        return CGImageDestinationFinalize(dst) ? data as Data : nil
    }
}
