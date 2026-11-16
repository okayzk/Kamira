import AppKit

/// Shortcuts: a recorder for each action, a warning beside any the system answers first,
/// and the way to switch the system's own screenshot shortcuts off.
final class ShortcutsPane: SettingsPane {
    /// Called with true while a shortcut is being typed into a recorder.
    var onRecordingShortcut: ((Bool) -> Void)?

    /// Each action's recorder and the warning beside it.
    private var recorders: [ShortcutAction: (recorder: ShortcutRecorder, warning: NSImageView)] = [:]
    private let guideButton = NSButton()

    override func makeView() -> NSView {
        let rows = ShortcutAction.allCases.map { action -> NSView in
            let recorder = ShortcutRecorder()
            recorder.actionName = action.title
            recorder.setAccessibilityIdentifier("settings.shortcut.\(action)")
            recorder.onRecording = { [weak self] recording in self?.onRecordingShortcut?(recording) }
            recorder.onChange = { [weak self] shortcut in
                Settings.shortcuts = ShortcutAction.assigning(shortcut, to: action, in: Settings.shortcuts)
                self?.refresh()
                self?.onChange?()
            }
            let warning = NSImageView()
            warning.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                    accessibilityDescription: L("settings.shortcut.taken"))
            warning.contentTintColor = .systemYellow
            warning.toolTip = L("settings.shortcut.taken")
            recorders[action] = (recorder, warning)
            let controls = NSStackView(views: [warning, recorder])
            controls.spacing = 8
            return row(action.title, control: controls)
        }

        guideButton.title = L("settings.systemShortcuts")
        guideButton.bezelStyle = .rounded
        guideButton.setAccessibilityIdentifier("settings.systemShortcuts")
        guideButton.target = self
        guideButton.action = #selector(showGuide)
        return pane([group(rows), guideButton])
    }

    /// Brings the recorders in line with the preferences, and marks every shortcut the
    /// system would answer first.
    func refresh() {
        let table = Settings.shortcuts
        let system = SystemHotKey.current()
        for (action, views) in recorders {
            views.recorder.shortcut = table[action]
            views.warning.isHidden = table[action]?.isTaken(by: system) != true
        }
    }

    /// Says how to switch off the system's own screenshot shortcuts, which use the same
    /// keys as this app's defaults and are answered first. Shown only when asked for.
    @objc func showGuide() { showShortcutGuide(relativeTo: guideButton) }
}
