import AppKit

/// A short message in a glass capsule near the bottom of the screen that fades away by
/// itself. It never takes the mouse or the keyboard.
final class Toast: NSPanel {
    private static let maxTextWidth: CGFloat = 380

    init(symbol: String, message: String, on screen: NSScreen) {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        icon.contentTintColor = .labelColor
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxTextWidth).isActive = true
        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 18)

        let size = NSSize(width: row.fittingSize.width, height: 40)
        let visible = screen.visibleFrame
        super.init(contentRect: NSRect(x: visible.midX - size.width / 2, y: visible.minY + 96,
                                       width: size.width, height: size.height),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
        glass.cornerRadius = size.height / 2
        glass.contentView = row
        contentView = glass
        setAccessibilityLabel(message)
    }

    /// Fades in, stays for `seconds`, fades out, then calls `completion`.
    func show(for seconds: TimeInterval, completion: @escaping () -> Void) {
        alphaValue = 0
        orderFrontRegardless()
        animator().alphaValue = 1
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            NSAnimationContext.runAnimationGroup({ _ in
                self?.animator().alphaValue = 0
            }, completionHandler: {
                self?.close()
                completion()
            })
        }
    }
}
