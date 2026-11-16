import AppKit

/// A window that is only its content: no frame, no title bar, no buttons. Borderless
/// windows cannot become key on their own, and this one takes typing (the shortcuts).
final class WelcomeWindow: NSWindow {
    static let cornerRadius: CGFloat = 16

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: WelcomeWindowController.width, height: 600),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
