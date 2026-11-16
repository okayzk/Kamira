import AppKit

/// Icon-only button for the control bar; the tooltip carries its name. A toggle shows
/// its state through the symbol and tint.
final class BarButton: NSButton {
    private let onSymbol: String
    private let offSymbol: String
    private let isToggle: Bool
    var isOn: Bool { didSet { refresh() } }
    var onClick: (() -> Void)?

    /// A two-state toggle.
    init(label: String, onSymbol: String, offSymbol: String, isOn: Bool) {
        self.onSymbol = onSymbol
        self.offSymbol = offSymbol
        self.isOn = isOn
        isToggle = true
        super.init(frame: .zero)
        configure(label)
    }

    /// A plain action button. `symbol` may be short text (such as "GIF") instead of a symbol name.
    init(label: String, symbol: String) {
        onSymbol = symbol
        offSymbol = symbol
        isOn = false
        isToggle = false
        super.init(frame: .zero)
        configure(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func configure(_ label: String) {
        title = ""
        isBordered = false
        imagePosition = .imageOnly
        toolTip = label
        setAccessibilityLabel(label)
        target = self
        action = #selector(clicked)
        widthAnchor.constraint(equalToConstant: 40).isActive = true
        heightAnchor.constraint(equalToConstant: 36).isActive = true
        refresh()
    }

    override var isEnabled: Bool { didSet { refresh() } }

    @objc private func clicked() {
        if isToggle { isOn.toggle() }
        onClick?()
    }

    private func refresh() {
        let name = isOn ? onSymbol : offSymbol
        image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .regular)) ?? Self.badge(name)
        if isToggle {
            contentTintColor = isOn ? .controlAccentColor : .secondaryLabelColor
            setAccessibilityValue(isOn ? L("toggle.on") : L("toggle.off"))
        } else {
            contentTintColor = .labelColor
        }
    }

    /// Text in a rounded outline, for actions that have no system symbol.
    private static func badge(_ text: String) -> NSImage {
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .heavy), .foregroundColor: NSColor.black
        ])
        let textSize = string.size()
        let size = NSSize(width: textSize.width + 9, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 5, yRadius: 5)
            outline.lineWidth = 1.5
            NSColor.black.setStroke()
            outline.stroke()
            string.draw(at: NSPoint(x: (rect.width - textSize.width) / 2, y: (rect.height - textSize.height) / 2))
            return true
        }
        image.isTemplate = true
        return image
    }
}
