import AppKit

/// The Quick Panel: a floating Liquid Glass bar with one button per action.
final class QuickPanel: NSObject {
    /// A button other than Close was clicked.
    var onAction: ((ShortcutAction) -> Void)?

    /// The buttons in order, each with its action; nil is Close.
    private static let buttons: [(title: String, id: String, symbol: String, action: ShortcutAction?)] = [
        (L("palette.area"), "palette.area", "rectangle.dashed", .area),
        (L("palette.window"), "palette.window", "macwindow", .window),
        (L("palette.screen"), "palette.screen", "display", .screen),
        (L("palette.several"), "palette.several", "square.grid.2x2", .several),
        (L("palette.scrolling"), "palette.scrolling", "arrow.up.and.down", .scrolling),
        (L("palette.text"), "palette.text", "text.viewfinder", .text),
        (L("palette.record"), "palette.record", "record.circle", .record),
        (L("palette.pin"), "palette.pin", "pin", .pin),
        (L("palette.close"), "palette.close", "xmark", nil)
    ]

    private var panel: NSPanel!

    override init() {
        super.init()
        let row = NSStackView(views: Self.buttons.enumerated().map { index, button in
            makeButton(button.title, id: button.id, symbol: button.symbol, tag: index)
        })
        row.orientation = .horizontal
        row.spacing = 4
        row.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)

        let size = row.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        // Hidden at once, without the system's fade: a selection that starts right after
        // would otherwise still find the panel under the pointer and offer it as a window.
        panel.animationBehavior = .none
        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
        glass.cornerRadius = 24
        glass.contentView = row
        panel.contentView = glass
        panel.center()
        panel.setAccessibilityIdentifier("palette")
        self.panel = panel
    }

    func toggle() {
        if panel.isVisible { panel.orderOut(nil) }
        else {
            // In the middle of the screen the pointer is on, a little above the centre as `center()` does.
            if let visible = NSScreen.underPointer?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2,
                                             y: visible.minY + (visible.height - panel.frame.height) * 2 / 3))
            }
            panel.orderFrontRegardless()
        }
    }

    func hide() { panel.orderOut(nil) }

    @objc private func buttonClicked(_ sender: NSButton) {
        guard let action = Self.buttons[sender.tag].action else { hide(); return }
        onAction?(action)
    }

    private func makeButton(_ title: String, id: String, symbol: String, tag: Int) -> NSButton {
        // NSButton's own image-above-title layout pins the image to the top edge, so the
        // icon and label are laid out by a centred stack inside an empty button instead.
        let button = PaletteButton(title: "", target: self, action: #selector(buttonClicked(_:)))
        button.tag = tag
        button.isBordered = false
        button.setAccessibilityLabel(title)
        button.setAccessibilityIdentifier(id)
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))
        icon.contentTintColor = .labelColor
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .labelColor
        let column = NSStackView(views: [icon, label])
        column.orientation = .vertical
        column.spacing = 5
        column.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            column.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            icon.heightAnchor.constraint(equalToConstant: 26),
            button.widthAnchor.constraint(equalToConstant: 68),
            button.heightAnchor.constraint(equalToConstant: 60)
        ])
        return button
    }
}
