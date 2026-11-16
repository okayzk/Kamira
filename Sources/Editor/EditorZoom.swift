import CoreGraphics

/// How far the editor zooms into the picture: 1 shows all of it, and the button and
/// the keys move between fixed steps while a pinch can stop anywhere in between.
enum EditorZoom {
    static let steps: [CGFloat] = [1, 2, 4, 8]

    static func clamped(_ zoom: CGFloat) -> CGFloat { min(max(zoom, steps[0]), steps[steps.count - 1]) }
    /// The next step above `zoom`, or the largest.
    static func stepIn(from zoom: CGFloat) -> CGFloat { steps.first { $0 > zoom + 0.01 } ?? steps[steps.count - 1] }
    /// The next step below `zoom`, or the whole picture.
    static func stepOut(from zoom: CGFloat) -> CGFloat { steps.last { $0 < zoom - 0.01 } ?? steps[0] }
}
