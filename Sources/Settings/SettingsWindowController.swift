import AppKit

/// The settings window, in the system's form: panes chosen in the tool bar, each a group
/// of rows with the name on the left and the control on the right. Created when asked
/// for and released when closed.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    enum Pane: Int { case general, screenshots, recording, shortcuts, about }

    /// Called after any setting changed, so the app can apply it.
    var onChange: (() -> Void)?
    var onClose: (() -> Void)?
    var onQuit: (() -> Void)?
    var onShowWelcome: (() -> Void)?
    /// Called with true while a shortcut is being typed into a recorder.
    var onRecordingShortcut: ((Bool) -> Void)?

    private let window: NSWindow
    private let tabs = SettingsTabs()
    private let general = GeneralPane()
    private let shortcuts = ShortcutsPane()
    private let about = AboutPane()
    /// Each pane's view stays in its tab; the pane, which its controls report to, stays
    /// with this window.
    private var panes: [SettingsPane] = []

    override init() {
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.setAccessibilityIdentifier("settings")
        window.delegate = self
        window.toolbarStyle = .preference

        general.onQuit = { [weak self] in self?.onQuit?() }
        general.onResize = { [weak self] in self?.tabs.resizeSelectedPane() }
        shortcuts.onRecordingShortcut = { [weak self] recording in self?.onRecordingShortcut?(recording) }
        about.onShowWelcome = { [weak self] in self?.onShowWelcome?() }

        tabs.tabStyle = .toolbar
        addPane(general, title: L("settings.general"), symbol: "gearshape")
        addPane(ScreenshotsPane(), title: L("settings.screenshots"), symbol: "camera.viewfinder")
        addPane(RecordingPane(), title: L("settings.recording"), symbol: "record.circle")
        addPane(shortcuts, title: L("settings.shortcuts"), symbol: "keyboard")
        addPane(about, title: L("settings.about"), symbol: "info.circle")
        window.contentViewController = tabs
        shortcuts.refresh()
    }

    private func addPane(_ pane: SettingsPane, title: String, symbol: String) {
        pane.onChange = { [weak self] in self?.onChange?() }
        panes.append(pane)
        let controller = NSViewController()
        controller.view = pane.view
        controller.title = title
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        tabs.addTabViewItem(item)
    }

    /// The note on switching off the system's own screenshot shortcuts.
    func showGuide() { shortcuts.showGuide() }

    func show(_ pane: Pane? = nil) {
        if let pane = pane { tabs.selectedTabViewItemIndex = pane.rawValue }
        window.title = tabs.tabViewItems[tabs.selectedTabViewItemIndex].label
        if !window.isVisible {
            window.setContentSize(tabs.tabViewItems[tabs.selectedTabViewItemIndex].view?.fittingSize ?? .zero)
            window.center()
        }
        QuietMode.activate()
        window.makeKeyAndOrderFront(nil)
    }

    // Back from System Settings, the warnings follow what was changed there.
    func windowDidBecomeKey(_ notification: Notification) { shortcuts.refresh() }

    func windowWillClose(_ notification: Notification) {
        window.makeFirstResponder(nil)
        // Let the close finish before the owner drops its reference to this object.
        DispatchQueue.main.async { [self] in onClose?() }
    }
}
