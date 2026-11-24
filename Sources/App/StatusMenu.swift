import AppKit

/// The menu bar item and its menu. While recording it shows the elapsed time instead,
/// and a click stops the recording.
final class StatusMenu: NSObject {
    enum Command {
        case action(ShortcutAction)
        case annotateClipboard, closeAllPins, settings, quit
    }
    /// What the recording is doing, as the menu bar shows it.
    enum Recording {
        case idle
        case recording(since: Date?)
        case convertingToGIF
    }

    /// A menu item was chosen.
    var onCommand: ((Command) -> Void)?
    /// The item was clicked while recording.
    var onStopRecording: (() -> Void)?

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    /// The commands of the menu's items, by tag.
    private var commands: [Command] = []
    /// The menu items that show an action's global shortcut.
    private var shortcutItems: [ShortcutAction: NSMenuItem] = [:]
    /// Updates the elapsed time while recording.
    private var timer: Timer?

    override init() {
        super.init()
        item.button?.image = StatusIcon.image
        item.button?.imagePosition = .imageLeading
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        shortcutItems[.area] = add(L("menu.captureArea"), .action(.area))
        shortcutItems[.window] = add(L("menu.captureWindow"), .action(.window))
        shortcutItems[.screen] = add(L("menu.captureScreen"), .action(.screen))
        shortcutItems[.several] = add(L("menu.captureSeveral"), .action(.several))
        shortcutItems[.scrolling] = add(L("menu.scrollingCapture"), .action(.scrolling))
        shortcutItems[.text] = add(L("menu.recognizeText"), .action(.text))
        menu.addItem(.separator())
        shortcutItems[.record] = add(L("menu.recordScreen"), .action(.record))
        menu.addItem(.separator())
        shortcutItems[.pin] = add(L("menu.pinClipboard"), .action(.pin))
        add(L("menu.annotateClipboard"), .annotateClipboard)
        add(L("menu.closeAllPins"), .closeAllPins)
        menu.addItem(.separator())
        shortcutItems[.panel] = add(L("menu.quickPanel"), .action(.panel))

        add(L("menu.settings"), .settings).keyEquivalent = ","
        add(L("menu.quit", AppInfo.name), .quit).keyEquivalent = "q"
        item.menu = menu
        showShortcuts()
    }

    var isVisible: Bool {
        get { item.isVisible }
        set { item.isVisible = newValue }
    }

    /// The menu shows each action's global shortcut, the one registered in `HotKeys`.
    func showShortcuts() {
        let table = Settings.shortcuts
        for (action, item) in shortcutItems {
            item.keyEquivalent = table[action]?.menuKey ?? ""
            item.keyEquivalentModifierMask = table[action]?.menuModifiers ?? []
        }
    }

    /// Opens the menu as a click on the item does.
    func open() { item.button?.performClick(nil) }

    func show(_ recording: Recording) {
        timer?.invalidate()
        timer = nil
        guard let button = item.button else { return }
        switch recording {
        case .convertingToGIF:
            // Nothing to click while the GIF is being written.
            item.menu = nil
            button.action = nil
            button.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: L("gif.creating"))
            button.title = " GIF"
            button.toolTip = L("gif.creating")
        case .recording(let since):
            item.menu = nil
            button.target = self
            button.action = #selector(stopClicked)
            // A red dot and the time, not a second stop button: the system already puts its
            // own stop control in the menu bar. Clicking this one stops the recording too.
            button.image = NSImage(systemSymbolName: "circle.fill",
                                   accessibilityDescription: L("recording.inProgress"))?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .regular)
                    .applying(.init(paletteColors: [.systemRed])))
            button.toolTip = L("recording.clickToStop")
            showTime(since: since)
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.showTime(since: since)
            }
        case .idle:
            button.action = nil
            item.menu = menu
            button.image = StatusIcon.image
            button.toolTip = nil
            button.title = ""
        }
    }

    private func showTime(since start: Date?) {
        let seconds = start.map { Int(Date().timeIntervalSince($0)) } ?? 0
        item.button?.title = String(format: " %d:%02d", seconds / 60, seconds % 60)
    }

    @discardableResult
    private func add(_ title: String, _ command: Command) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: #selector(itemChosen(_:)), keyEquivalent: "")
        menuItem.target = self
        menuItem.tag = commands.count
        commands.append(command)
        menu.addItem(menuItem)
        return menuItem
    }

    @objc private func itemChosen(_ sender: NSMenuItem) { onCommand?(commands[sender.tag]) }
    @objc private func stopClicked() { onStopRecording?() }
}
