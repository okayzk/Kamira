import AppKit

/// The live preview of a scrolling capture: the picture so far at a narrow width, beside
/// the region. It grows downwards from the region's top edge until it is as tall as the
/// region, then shows the newest part. Only to look at: clicks pass through it, and it
/// is excluded from captures.
final class ScrollPreviewWindow: NSPanel {
    private let room: CGRect

    init(room: CGRect) {
        self.room = room
        super.init(contentRect: room, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        // Development aid: `--demo-show-capture-ui` lets screenshots see this window.
        sharingType = CommandLine.arguments.contains("--demo-show-capture-ui") ? .readOnly : .none
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSView(frame: NSRect(origin: .zero, size: room.size))
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 0.5
        view.layer?.borderColor = NSColor.separatorColor.cgColor
        view.layer?.contentsGravity = .resize
        contentView = view
    }

    /// `image` is in pixels, `scale` of them to a point.
    func show(_ image: CGImage, scale: CGFloat) {
        let height = min(room.height, CGFloat(image.height) / scale)
        setFrame(NSRect(x: room.minX, y: room.maxY - height, width: room.width, height: height), display: false)
        contentView?.layer?.contents = image
        if !isVisible { orderFrontRegardless() }
    }
}
