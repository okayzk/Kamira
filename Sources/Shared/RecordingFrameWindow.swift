import AppKit

/// Thin outline drawn just outside the region being recorded. It ignores the mouse and
/// is excluded from captures.
final class RecordingFrameWindow: NSPanel {
    private static let thickness: CGFloat = 2

    init(around rect: CGRect) {
        let frame = rect.insetBy(dx: -Self.thickness, dy: -Self.thickness)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        sharingType = .none
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.borderWidth = Self.thickness
        view.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.9).cgColor
        contentView = view
    }
}
