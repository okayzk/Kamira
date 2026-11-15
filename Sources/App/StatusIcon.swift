import AppKit

/// The menu bar icon: the app's mark at menu bar size (`AppMark`), as a template so the
/// menu bar colours it.
enum StatusIcon {
    static let image: NSImage = {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            AppMark.drawMenuBarIcon(in: context)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = AppInfo.name
        return image
    }()
}
