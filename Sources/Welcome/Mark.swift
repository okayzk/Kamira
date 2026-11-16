import AppKit

/// A row's symbol in its colour, or a green tick once the row is done.
final class Mark: NSImageView {
    static let side: CGFloat = 22
    private let symbol: String
    private let colour: NSColor
    private var isDone = false

    init(symbol: String, colour: NSColor) {
        self.symbol = symbol
        self.colour = colour
        super.init(frame: .zero)
        symbolConfiguration = .init(pointSize: 17, weight: .medium)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        contentTintColor = colour
        widthAnchor.constraint(equalToConstant: Self.side).isActive = true
        heightAnchor.constraint(equalToConstant: Self.side).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setDone(_ done: Bool, animated: Bool) {
        guard done != isDone else { return }
        isDone = done
        guard let picture = NSImage(systemSymbolName: done ? "checkmark.circle.fill" : symbol,
                                    accessibilityDescription: nil) else { return }
        contentTintColor = done ? .systemGreen : colour
        if animated {
            setSymbolImage(picture, contentTransition: .replace)
            if done { addSymbolEffect(.bounce) }
        } else {
            image = picture
        }
    }
}
