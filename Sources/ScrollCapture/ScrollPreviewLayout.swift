import Foundation

/// Where the live preview of a scrolling capture stands.
enum ScrollPreviewLayout {
    static let width: CGFloat = 160
    /// Between the region and the preview.
    static let gap: CGFloat = 12
    /// Kept clear at the edge of the screen.
    private static let edge: CGFloat = 4

    /// The room for the preview: as tall as the region and level with it, on its right,
    /// or on its left when the right has no room. Nil when neither side has: a preview
    /// over the region itself would be photographed with it.
    static func frame(beside area: CGRect, in visible: CGRect) -> CGRect? {
        if area.maxX + gap + width <= visible.maxX - edge {
            return CGRect(x: area.maxX + gap, y: area.minY, width: width, height: area.height)
        }
        if area.minX - gap - width >= visible.minX + edge {
            return CGRect(x: area.minX - gap - width, y: area.minY, width: width, height: area.height)
        }
        return nil
    }
}
