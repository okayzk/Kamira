import AppKit

/// A button that shows a shortcut and, once clicked, takes the next key press as the new
/// one. Delete clears it, Esc leaves it as it was.
final class ShortcutRecorder: NSButton {
    var shortcut: Shortcut? { didSet { refresh() } }
    /// What the shortcut does. Assistive apps say it before the shortcut ("Capture Area,
    /// ⇧⌘4"); the button itself shows only the keys.
    var actionName: String? { didSet { refresh() } }
    var onChange: ((Shortcut?) -> Void)?
    /// Called when recording starts and ends: the app's own shortcuts must not fire
    /// while one of them is being typed here.
    var onRecording: ((Bool) -> Void)?
    private var isRecording = false { didSet { refresh() } }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(startRecording)
        toolTip = L("settings.shortcut.hint")
        widthAnchor.constraint(equalToConstant: 124).isActive = true
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func refresh() {
        title = isRecording ? L("settings.shortcut.recording") : shortcut?.display ?? L("settings.shortcut.record")
        contentTintColor = shortcut == nil || isRecording ? .secondaryLabelColor : nil
        if let actionName = actionName {
            setAccessibilityLabel(actionName)
            setAccessibilityValue(title)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    @objc private func startRecording() {
        guard !isRecording, window?.makeFirstResponder(self) == true else { return }
        isRecording = true
        onRecording?(true)
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        onRecording?(false)
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    // Shortcuts with ⌘ arrive here, the others in keyDown.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        record(event)
    }

    private func record(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags.isEmpty, event.keyCode == 53 { // Esc
            stopRecording()
            return
        }
        if flags.isEmpty, event.keyCode == 51 || event.keyCode == 117 { // Delete, Forward Delete
            stopRecording()
            onChange?(nil)
            return
        }
        // The key as it prints on its own: with Shift held, "4" would arrive as "$".
        let new = Shortcut(keyCode: event.keyCode, flags: flags, key: event.characters(byApplyingModifiers: []) ?? "")
        guard new.isUsable else {
            NSSound.beep()
            return
        }
        stopRecording()
        onChange?(new)
    }
}
