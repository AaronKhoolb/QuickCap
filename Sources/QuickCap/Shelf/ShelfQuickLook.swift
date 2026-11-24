import AppKit
import Quartz

/// 空格快速查看：系统的 Quick Look 面板，显示鼠标停着的那张截图。再按一次空格（或 Esc）关掉
@MainActor
final class ShelfQuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = ShelfQuickLook()
    private var url: URL?

    func show(_ url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible, self.url == url { panel.orderOut(nil); return }
        self.url = url
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        // 先切到 QuickCap：不然空格、Esc 进了前面那个 app，面板关不掉
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        // 截图架的窗口层级很高，面板要在它上面才看得见
        panel.level = NSWindow.Level(rawValue: CaptureOverlayWindow.captureLevel.rawValue - 1)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { url as NSURL? }
    }
}
