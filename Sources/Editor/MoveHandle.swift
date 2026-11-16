import AppKit

/// The round grip left of the tool bar: press and drag it to move the editor window. The
/// image itself cannot be used for that, since dragging on it draws.
final class MoveHandle: NSView {
    static let diameter: CGFloat = 36

    init(label: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = label
        setAccessibilityLabel(label)
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right",
                             accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        icon.contentTintColor = .labelColor
        let glass = NSGlassEffectView()
        glass.cornerRadius = Self.diameter / 2
        glass.contentView = icon
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.diameter),
            heightAnchor.constraint(equalToConstant: Self.diameter),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // The whole disc is the grip, not the icon inside it.
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}
