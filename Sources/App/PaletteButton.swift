import AppKit

/// Button whose icon and label subviews never take the click away from the button itself.
final class PaletteButton: NSButton {
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }
}
