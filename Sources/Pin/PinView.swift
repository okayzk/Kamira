import AppKit

/// Content of a pin: the image itself, reporting hover so the window can react.
final class PinView: NSView {
    var image: CGImage?
    var onHover: ((Bool) -> Void)?

    override var wantsUpdateLayer: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The image has a layer of its own so that it can fade without the buttons fading.
    private let imageLayer = CALayer()
    var imageOpacity: Float = 1 {
        didSet {
            imageLayer.opacity = imageOpacity
            window?.invalidateShadow()
        }
    }

    override func updateLayer() {
        guard let layer = layer else { return }
        // Just the image: no border and no rounding, only the window's shadow around it.
        if imageLayer.superlayer == nil { layer.insertSublayer(imageLayer, at: 0) }
        imageLayer.frame = layer.bounds
        imageLayer.contents = image
        imageLayer.contentsGravity = .resize
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}
