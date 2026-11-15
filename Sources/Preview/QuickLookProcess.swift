import AppKit
import Quartz

/// Shows one file in the system's Quick Look panel, as its own short-lived process
/// (`--quicklook <file>`), and quits when the panel closes. Playing a video inside the
/// menu bar app would leave its memory there for good.
final class QuickLookProcessDelegate: NSObject, NSApplicationDelegate, QLPreviewPanelDataSource {
    private let url: URL

    init(path: String) {
        url = URL(fileURLWithPath: path)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        guard let panel = QLPreviewPanel.shared() else { NSApp.terminate(nil); return }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel,
                                               queue: .main) { _ in NSApp.terminate(nil) }
        panel.makeKeyAndOrderFront(nil)
    }

    // The panel looks along the responder chain, which ends at the app's delegate, for
    // someone to give it its content.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { url as NSURL }
}
