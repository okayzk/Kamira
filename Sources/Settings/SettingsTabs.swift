import AppKit
import ServiceManagement

/// Grows or shrinks the window to the pane that was chosen, as the system's settings do.
final class SettingsTabs: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        resizeSelectedPane()
    }

    func resizeSelectedPane() {
        guard tabViewItems.indices.contains(selectedTabViewItemIndex),
              let window = view.window else { return }
        let item = tabViewItems[selectedTabViewItemIndex]
        guard let pane = item.view else { return }
        window.title = item.label
        let size = pane.fittingSize
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        // The title bar stays where it is.
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: window.isVisible)
    }
}
