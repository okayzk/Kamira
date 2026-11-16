import AppKit

final class SelectionView: NSView {
    var onCancel: (() -> Void)?
    /// Return starts a video, Option-Return a GIF.
    var onRecord: ((Bool) -> Void)?
    /// Space switches to picking a window, as it does when taking a screenshot.
    var onPickWindow: (() -> Void)?
    var onSelectionChange: (() -> Void)?
    /// In view coordinates; nil means nothing is selected on this screen.
    var selection: CGRect? {
        didSet {
            needsDisplay = true
            if selection != oldValue { onSelectionChange?() }
        }
    }
    private var anchor: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.3).setFill()
        bounds.fill()
        guard let selection = selection else { return }
        NSColor.clear.setFill()
        selection.fill(using: .copy)
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()

        // Size label just below the selection, or inside it when there is no room.
        let text = "\(Int(selection.width)) × \(Int(selection.height))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        var origin = NSPoint(x: selection.minX + 6, y: selection.minY - size.height - 10)
        if origin.y < 4 { origin.y = selection.minY + 8 }
        let pill = NSRect(x: origin.x - 6, y: origin.y - 3, width: size.width + 12, height: size.height + 6)
        NSColor(white: 0, alpha: 0.7).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        text.draw(at: origin, withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = anchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                           width: abs(point.x - anchor.x), height: abs(point.y - anchor.y))
            .intersection(bounds)
    }

    override func mouseUp(with event: NSEvent) {
        anchor = nil
        // A click or a tiny drag is not a selection.
        if let rect = selection?.integral, rect.width >= 16, rect.height >= 16 {
            selection = rect
        } else {
            selection = nil
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()
        case 36, 76: onRecord?(event.modifierFlags.contains(.option))
        case 49: onPickWindow?()
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
