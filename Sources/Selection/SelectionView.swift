import AppKit

/// One screen of the selector: dimmed, with the selection clear and outlined and its size
/// beside it. All of it is plain layers (see `SelectionShade`), never drawn into a
/// bitmap: a screen-sized bitmap, redrawn while dragging, held hundreds of megabytes.
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
            updateShade()
            if selection != oldValue { onSelectionChange?() }
        }
    }
    private var anchor: NSPoint?

    /// Beneath every subview, so the control bar stays above the dimming.
    private let shade = NSView()
    private let dims = (0..<4).map { _ in CALayer() }
    private let border = CALayer()
    private let pill = CALayer()
    private let label = SizeLabel()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shade.frame = bounds
        shade.autoresizingMask = [.width, .height]
        shade.wantsLayer = true
        addSubview(shade)
        let dim = NSColor(white: 0, alpha: 0.3).cgColor
        dims.forEach { $0.backgroundColor = dim }
        border.borderColor = NSColor.white.cgColor
        border.borderWidth = 1
        pill.backgroundColor = NSColor(white: 0, alpha: 0.7).cgColor
        (dims + [border, pill]).forEach { shade.layer?.addSublayer($0) }
        shade.addSubview(label)
        updateShade()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func layout() {
        super.layout()
        updateShade()
    }

    private func updateShade() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let parts = SelectionShade.dimmed(bounds, except: selection)
        for (index, dim) in dims.enumerated() {
            dim.isHidden = index >= parts.count
            if index < parts.count { dim.frame = parts[index] }
        }
        guard let selection = selection else {
            [border, pill].forEach { $0.isHidden = true }
            label.isHidden = true
            return
        }
        [border, pill].forEach { $0.isHidden = false }
        label.isHidden = false
        border.frame = selection
        label.text = "\(Int(selection.width)) × \(Int(selection.height))" as NSString
        let size = label.text.size(withAttributes: SizeLabel.attributes)
        let frame = SelectionShade.labelFrame(for: selection, text: size)
        pill.frame = frame
        pill.cornerRadius = frame.height / 2
        label.frame = CGRect(x: frame.minX + 6, y: frame.minY + 3, width: ceil(size.width) + 1, height: ceil(size.height))
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
