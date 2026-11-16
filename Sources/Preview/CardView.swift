import AppKit

/// The thumbnail card: shows the image, reports pointer activity, and lets the capture
/// be dragged out into other apps as a PNG file.
final class CardView: NSView, NSDraggingSource {
    var image: CGImage? { didSet { needsDisplay = true } }
    /// Fired when the pointer enters, leaves, or moves over the card. It is only a hint:
    /// overlapping, moving overlays make AppKit's enter/exit pairing unreliable, so the
    /// owner decides from the pointer position which overlay is really hovered.
    var onPointerActivity: (() -> Void)?
    /// Returns the file to hand to the drop target.
    var dragFile: (() -> URL?)?
    var onDragCompleted: (() -> Void)?
    private var mouseDownPoint: NSPoint?
    private var dragging = false

    override var wantsUpdateLayer: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateLayer() {
        guard let layer = layer else { return }
        layer.contents = image
        layer.contentsGravity = .resizeAspectFill
        layer.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        layer.cornerRadius = 10
        layer.masksToBounds = true
        layer.borderWidth = 1
        layer.borderColor = NSColor(white: 1, alpha: 0.28).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onPointerActivity?() }
    override func mouseExited(with event: NSEvent) { onPointerActivity?() }
    override func mouseMoved(with event: NSEvent) { onPointerActivity?() }
    override func mouseDown(with event: NSEvent) { mouseDownPoint = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let start = mouseDownPoint else { return }
        let now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) > 3, let url = dragFile?() else { return }
        dragging = true
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        // Drag image: the thumbnail, aspect-fitted inside the card.
        var frame = bounds
        if let image = image, image.width > 0, image.height > 0 {
            let fit = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
            let size = NSSize(width: CGFloat(image.width) * fit, height: CGFloat(image.height) * fit)
            frame = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                           width: size.width, height: size.height)
            item.setDraggingFrame(frame, contents: NSImage(cgImage: image, size: size))
        }
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        dragging = false
        mouseDownPoint = nil
        if !operation.isEmpty { onDragCompleted?() }
    }
}
