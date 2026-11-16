import CoreGraphics

/// Where a selection screen's parts go, in view coordinates: the dimming around the
/// selection and the size label. `SelectionView` shows them as plain layers, which the
/// system composites without a screen-sized bitmap in the app.
enum SelectionShade {
    /// Rectangles that dim `bounds` everywhere except `selection`: one band below and
    /// one above it at full width, and one on each side of it, so none overlaps another.
    static func dimmed(_ bounds: CGRect, except selection: CGRect?) -> [CGRect] {
        guard let selection = selection?.intersection(bounds), !selection.isNull else { return [bounds] }
        return [
            CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: selection.minY - bounds.minY),
            CGRect(x: bounds.minX, y: selection.maxY, width: bounds.width, height: bounds.maxY - selection.maxY),
            CGRect(x: bounds.minX, y: selection.minY, width: selection.minX - bounds.minX, height: selection.height),
            CGRect(x: selection.maxX, y: selection.minY, width: bounds.maxX - selection.maxX, height: selection.height)
        ].filter { $0.width > 0 && $0.height > 0 }
    }

    /// The size label's pill, for text of `text` size: just below the selection, or
    /// inside its bottom edge when there is no room below.
    static func labelFrame(for selection: CGRect, text: CGSize) -> CGRect {
        var origin = CGPoint(x: selection.minX + 6, y: selection.minY - text.height - 10)
        if origin.y < 4 { origin.y = selection.minY + 8 }
        return CGRect(x: origin.x - 6, y: origin.y - 3, width: text.width + 12, height: text.height + 6)
    }
}
