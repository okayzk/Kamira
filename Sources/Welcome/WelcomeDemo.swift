import AppKit

/// The top of the welcome window: a small desktop on which, over and over, the pointer
/// drags out a selection, the screen flashes, the preview card rises in the bottom-left
/// corner with the picture in it, and is dragged away. Drawn with layers from the app's
/// own measurements (the card is `PreviewCard.size`, scaled), so it shows the app
/// as it is. With Reduce Motion on it is one still frame: the card, just arrived.
final class WelcomeDemo: NSView {
    static let size = NSSize(width: 376, height: 176)
    private static let loop: CFTimeInterval = 5

    /// The window on the small desktop, and the part of it that is selected.
    private let windowFrame = CGRect(x: 96, y: 34, width: 232, height: 122)
    private let selected = CGRect(x: 112, y: 52, width: 120, height: 76)
    private let cardScale: CGFloat = 0.42

    override init(frame: NSRect) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        widthAnchor.constraint(equalToConstant: Self.size.width).isActive = true
        heightAnchor.constraint(equalToConstant: Self.size.height).isActive = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func build() {
        guard let root = layer else { return }
        let desktop = CAGradientLayer()
        desktop.frame = bounds
        desktop.colors = [NSColor(red: 0.16, green: 0.15, blue: 0.42, alpha: 1).cgColor,
                          NSColor(red: 0.45, green: 0.33, blue: 0.80, alpha: 1).cgColor]
        desktop.startPoint = CGPoint(x: 0, y: 0)
        desktop.endPoint = CGPoint(x: 1, y: 1)
        root.addSublayer(desktop)
        root.addSublayer(window())

        // The selection: a dashed outline that grows from the pointer.
        let selection = CAShapeLayer()
        selection.fillColor = NSColor(white: 0, alpha: 0.12).cgColor
        selection.strokeColor = NSColor(white: 0, alpha: 0.55).cgColor
        selection.lineWidth = 1
        selection.lineDashPattern = [4, 3]
        selection.opacity = 0
        root.addSublayer(selection)

        let flash = CALayer()
        flash.frame = selected
        flash.backgroundColor = NSColor.white.cgColor
        flash.opacity = 0
        root.addSublayer(flash)

        let card = self.card()
        root.addSublayer(card)

        let pointer = CALayer()
        let arrow = NSCursor.arrow, crosshair = NSCursor.crosshair
        pointer.bounds = CGRect(origin: .zero, size: arrow.image.size)
        pointer.contents = arrow.image
        // The hot spot is where the layer's position is.
        pointer.anchorPoint = CGPoint(x: arrow.hotSpot.x / arrow.image.size.width,
                                      y: 1 - arrow.hotSpot.y / arrow.image.size.height)
        root.addSublayer(pointer)

        let start = CGPoint(x: selected.minX, y: selected.maxY)
        let end = CGPoint(x: selected.maxX, y: selected.minY)
        let cardCentre = CGPoint(x: card.position.x, y: card.position.y)
        let away = CGPoint(x: cardCentre.x + 250, y: cardCentre.y + 70)
        let rest = CGPoint(x: 330, y: 40)

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            pointer.isHidden = true
            return
        }
        card.opacity = 0

        pointer.add(keyframes("position", [rest, start, start, end, end, cardCentre, cardCentre, away, rest].map(NSValue.init(point:)),
                              [0, 0.12, 0.15, 0.33, 0.42, 0.56, 0.60, 0.74, 1]), forKey: nil)
        // Discrete key frames take one time more than values: when each one begins, and the end.
        let images = keyframes("contents", [arrow.image, crosshair.image, arrow.image], [0, 0.12, 0.38, 1])
        images.calculationMode = .discrete
        pointer.add(images, forKey: nil)
        let hotSpot = keyframes("anchorPoint", [pointer.anchorPoint, CGPoint(x: 0.5, y: 0.5), pointer.anchorPoint]
                                    .map(NSValue.init(point:)), [0, 0.12, 0.38, 1])
        hotSpot.calculationMode = .discrete
        pointer.add(hotSpot, forKey: nil)

        let empty = CGPath(rect: CGRect(origin: start, size: .zero), transform: nil)
        let full = CGPath(rect: selected, transform: nil)
        selection.add(keyframes("path", [empty, empty, full, full], [0, 0.15, 0.33, 1]), forKey: nil)
        selection.add(keyframes("opacity", [0, 0, 1, 1, 0, 0], [0, 0.14, 0.15, 0.37, 0.38, 1]), forKey: nil)
        flash.add(keyframes("opacity", [0, 0, 0.7, 0, 0], [0, 0.37, 0.39, 0.45, 1]), forKey: nil)

        // The card rises with a small overshoot, waits, and leaves with the pointer.
        card.add(keyframes("opacity", [0, 0, 1, 1, 0, 0], [0, 0.40, 0.43, 0.66, 0.74, 1]), forKey: nil)
        card.add(keyframes("position", [cardCentre.offset(0, -40), cardCentre.offset(0, -40), cardCentre.offset(0, 4),
                                        cardCentre, cardCentre, away, away].map(NSValue.init(point:)),
                           [0, 0.40, 0.47, 0.51, 0.60, 0.74, 1]), forKey: nil)
    }

    /// A light window with a picture and a few lines of text in it.
    private func window() -> CALayer {
        let window = CALayer()
        window.frame = windowFrame
        window.cornerRadius = 9
        window.backgroundColor = NSColor(white: 0.97, alpha: 1).cgColor
        window.shadowOpacity = 0.25
        window.shadowRadius = 10
        window.shadowOffset = CGSize(width: 0, height: -4)
        for (index, colour) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            let dot = CALayer()
            dot.frame = CGRect(x: 10 + CGFloat(index) * 11, y: windowFrame.height - 14, width: 7, height: 7)
            dot.cornerRadius = 3.5
            dot.backgroundColor = colour.cgColor
            window.addSublayer(dot)
        }
        let picture = Self.picture()
        picture.frame = CGRect(x: selected.minX - windowFrame.minX + 8, y: selected.minY - windowFrame.minY + 8,
                               width: selected.width - 16, height: selected.height - 16)
        picture.cornerRadius = 5
        window.addSublayer(picture)
        for (index, width) in [64, 52, 70, 40].enumerated() {
            let line = CALayer()
            line.frame = CGRect(x: selected.maxX - windowFrame.minX + 10, y: 86 - CGFloat(index) * 14,
                                width: CGFloat(width), height: 6)
            line.cornerRadius = 3
            line.backgroundColor = NSColor(white: 0.82, alpha: 1).cgColor
            window.addSublayer(line)
        }
        return window
    }

    /// The preview card, scaled: the selected picture filling a rounded rectangle.
    private func card() -> CALayer {
        let size = CGSize(width: PreviewCard.size.width * cardScale,
                          height: PreviewCard.size.height * cardScale)
        let card = CALayer()
        card.frame = CGRect(origin: CGPoint(x: 12, y: 12), size: size)
        card.cornerRadius = 10 * cardScale + 2
        card.backgroundColor = NSColor(white: 0.97, alpha: 1).cgColor
        card.borderColor = NSColor(white: 1, alpha: 0.6).cgColor
        card.borderWidth = 1
        card.shadowOpacity = 0.35
        card.shadowRadius = 8
        card.shadowOffset = CGSize(width: 0, height: -3)
        let picture = Self.picture()
        picture.frame = card.bounds.insetBy(dx: 6, dy: 6)
        picture.cornerRadius = 3
        card.addSublayer(picture)
        return card
    }

    /// The picture in the window: a small sunset.
    private static func picture() -> CALayer {
        let picture = CAGradientLayer()
        picture.colors = [NSColor.systemOrange.cgColor, NSColor.systemPink.cgColor, NSColor.systemIndigo.cgColor]
        picture.startPoint = CGPoint(x: 0.5, y: 0)
        picture.endPoint = CGPoint(x: 0.5, y: 1)
        picture.masksToBounds = true
        return picture
    }

    /// One part of the loop: `values` at `times` (fractions of it), eased between.
    private func keyframes(_ keyPath: String, _ values: [Any], _ times: [NSNumber]) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = times
        animation.duration = Self.loop
        animation.repeatCount = .infinity
        animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut),
                                          count: max(values.count - 1, 1))
        animation.isRemovedOnCompletion = false
        return animation
    }
}

private extension CGPoint {
    func offset(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: x + dx, y: y + dy) }
}
