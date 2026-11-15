import AppKit

/// Content of a pin: the image itself, reporting hover so the window can react.
private final class PinView: NSView {
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

/// An image pinned above all windows at its original on-screen size. Drag to move;
/// hovering shows Close and Annotate buttons and, optionally, fades the pin to see underneath.
final class PinnedImageWindow: NSPanel {
    var onRemove: ((PinnedImageWindow) -> Void)?
    /// Annotate the pinned image; the owner opens the editor and removes this pin.
    var onAnnotate: ((PinnedImageWindow) -> Void)?
    let capture: CapturedImage
    var hoverFade = true { didSet { if !hoverFade { pinView?.imageOpacity = 1 } } }
    private weak var pinView: PinView?
    private var buttons: [NSView] = []

    init(capture: CapturedImage, offset: CGFloat = 0) {
        self.capture = capture
        let screen = NSScreen.underPointer
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Original size, shrunk only if it would not fit comfortably on screen.
        let fit = min(1, visible.width * 0.8 / capture.pointSize.width,
                      visible.height * 0.8 / capture.pointSize.height)
        let size = NSSize(width: max(24, (capture.pointSize.width * fit).rounded()),
                          height: max(24, (capture.pointSize.height * fit).rounded()))
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        // See `hasTransparentEdges`: a window capture brings its own shadow.
        hasShadow = !capture.hasTransparentEdges
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true

        let view = PinView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        // Keep only the pixels this pin can show. At original size the renderer decodes
        // straight from the encoded bytes; only oversized images get a downsampled copy.
        let scale = screen?.backingScaleFactor ?? 2
        let neededPixels = max(size.width, size.height) * scale
        view.image = neededPixels >= max(capture.pixelSize.width, capture.pixelSize.height)
            ? capture.fullSizeUncached()
            : capture.downsampled(maxPixel: neededPixels)
        view.onHover = { [weak self] over in self?.setHovering(over) }
        pinView = view
        contentView = view

        // Same corners as the floating preview: close top-left, annotate bottom-left.
        let close = makeRoundIconButton(symbol: "xmark", label: L("pin.close"), diameter: 26,
                                        target: self, action: #selector(removePin))
        let annotate = makeRoundIconButton(symbol: "pencil", label: L("action.annotate"), diameter: 26,
                                           target: self, action: #selector(annotatePin))
        buttons = [close, annotate]
        buttons.forEach {
            $0.isHidden = true
            view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            close.topAnchor.constraint(equalTo: view.topAnchor, constant: 7),
            close.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 7),
            annotate.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -7),
            annotate.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 7)
        ])
        // On a very small pin there is only room for the close button.
        if size.height < 70 { annotate.removeFromSuperview() }

        setFrameOrigin(NSPoint(x: visible.midX - size.width / 2 + offset,
                               y: visible.midY - size.height / 2 - offset))
    }

    private func setHovering(_ over: Bool) {
        buttons.forEach { $0.isHidden = !over }
        pinView?.imageOpacity = (hoverFade && over) ? 0.22 : 1
    }

    @objc private func removePin() { onRemove?(self) }
    @objc private func annotatePin() { onAnnotate?(self) }
}
