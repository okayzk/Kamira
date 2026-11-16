import AppKit

/// Circular icon button used on top of images (close, pin, annotate). It draws its own
/// disc, so it is a true circle whatever the system does to standard button bezels.
final class RoundIconButton: NSControl {
    private let symbol: NSImage?
    private var pressed = false { didSet { needsDisplay = true } }

    /// `symbol` is an SF Symbol name, or short text (such as "GIF") drawn as the icon
    /// when no symbol of that name exists.
    init(symbol: String, label: String, diameter: CGFloat, target: AnyObject, action: Selector) {
        let colors = NSImage.SymbolConfiguration(paletteColors: [.black])
        self.symbol = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: diameter * 0.46, weight: .bold)
                .applying(colors)) ?? Self.textIcon(symbol, size: diameter * 0.36)
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        self.target = target
        self.action = action
        toolTip = label
        setAccessibilityLabel(label)
        setAccessibilityRole(.button)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: diameter).isActive = true
        heightAnchor.constraint(equalToConstant: diameter).isActive = true
        // A soft shadow keeps the white disc visible on white images.
        wantsLayer = true
        shadow = NSShadow()
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 2.5
        layer?.shadowOffset = CGSize(width: 0, height: -1)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static func textIcon(_ text: String, size: CGFloat) -> NSImage {
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .heavy), .foregroundColor: NSColor.black
        ])
        let bounds = string.size()
        return NSImage(size: bounds, flipped: false) { _ in
            string.draw(at: .zero)
            return true
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: pressed ? 0.82 : 1, alpha: 0.96).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        guard let symbol = symbol else { return }
        let size = symbol.size
        symbol.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                               width: size.width, height: size.height))
    }

    override func mouseDown(with event: NSEvent) { pressed = true }

    override func accessibilityPerformPress() -> Bool { sendAction(action, to: target) }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            sendAction(action, to: target)
        }
    }
}

func makeRoundIconButton(symbol: String, label: String, diameter: CGFloat = 24,
                         target: AnyObject, action: Selector) -> RoundIconButton {
    RoundIconButton(symbol: symbol, label: label, diameter: diameter, target: target, action: action)
}
