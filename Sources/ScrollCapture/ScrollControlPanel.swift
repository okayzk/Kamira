import AppKit

/// Small glass panel shown beside the region during a scrolling capture: what to do,
/// how tall the picture is so far, and Done / Cancel. It is excluded from captures.
final class ScrollControlPanel: NSPanel {
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?
    private let label = NSTextField(labelWithString: L("scroll.start"))

    init(beside area: CGRect, on screen: NSScreen) {
        let size = NSSize(width: 250, height: 44)
        // Below the region if there is room, otherwise above it, otherwise inside its bottom edge.
        let visible = screen.visibleFrame
        var origin = NSPoint(x: area.midX - size.width / 2, y: area.minY - size.height - 10)
        if origin.y < visible.minY + 4 { origin.y = area.maxY + 10 }
        if origin.y + size.height > visible.maxY - 4 { origin.y = area.minY + 10 }
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        super.init(contentRect: NSRect(origin: origin, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // Development aid: `--demo-show-capture-ui` lets screenshots see this panel.
        sharingType = CommandLine.arguments.contains("--demo-show-capture-ui") ? .readOnly : .none
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let cancel = button("xmark", L("action.cancel"), #selector(cancelClicked))
        let done = button("checkmark", L("action.done"), #selector(doneClicked))
        done.contentTintColor = .controlAccentColor
        let row = NSStackView(views: [label, cancel, done])
        row.orientation = .horizontal
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 8)
        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
        glass.cornerRadius = size.height / 2
        glass.contentView = row
        contentView = glass
    }

    private func button(_ symbol: String, _ title: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold)) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .labelColor
        button.toolTip = title
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    /// `progress` is a line from the helper: "lost" or "height <pixels>".
    func show(progress: String) {
        if progress == "lost" {
            label.stringValue = L("scroll.tooFast")
        } else if progress.hasPrefix("height "), let pixels = Int(progress.dropFirst(7)) {
            label.stringValue = L("scroll.progress", pixels)
        }
    }

    @objc private func doneClicked() { onDone?() }
    @objc private func cancelClicked() { onCancel?() }
}
