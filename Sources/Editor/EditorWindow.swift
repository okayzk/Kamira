import AppKit

/// Window that maps ⌘-shortcuts to editor actions; the app has no main menu to carry them.
final class EditorWindow: NSWindow {
    var shortcuts: [String: () -> Void] = [:]
    var onEscape: (() -> Void)?

    // Borderless windows refuse keyboard focus unless told otherwise.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, !(firstResponder is NSTextView),
           let key = event.charactersIgnoringModifiers?.lowercased(), let action = shortcuts[key] {
            action()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
