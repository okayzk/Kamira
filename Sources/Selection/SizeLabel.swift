import AppKit

/// The selection's size, drawn as AppKit draws text, so it looks as it always has; its
/// bitmap is only as large as the text. The pill behind it is a layer of `SelectionView`.
final class SizeLabel: NSView {
    static let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor.white
    ]
    var text: NSString = "" { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        text.draw(at: .zero, withAttributes: Self.attributes)
    }
}
