import CoreGraphics

/// The pictures in an editor and where each lies, bottom to top: one for an ordinary
/// capture, several for screenshots combined into one or added in the editor. Frames are
/// in points from the bottom-left, like the annotations, which lie over all the pictures
/// and do not move with them. Indices count from the bottom of the stack.
struct LayerStack: Equatable {
    struct Layer: Equatable {
        /// Which picture, in the order the pictures were given.
        let picture: Int
        /// The whole picture.
        var frame: CGRect
        /// The part of it that shows, from its own bottom-left corner: all of it, unless
        /// a crop was made before another picture was added.
        var kept: CGRect

        /// Where the part that shows lies.
        var shownFrame: CGRect { kept.offsetBy(dx: frame.minX, dy: frame.minY) }
    }

    private(set) var layers: [Layer]

    /// Picture `i` at `frames[i]`, the first at the bottom.
    init(frames: [CGRect]) {
        layers = frames.enumerated().map { Layer(picture: $0, frame: $1, kept: CGRect(origin: .zero, size: $1.size)) }
    }

    var isSeveral: Bool { layers.count > 1 }

    private static let gap = CapturedImage.Part.spacing

    /// What shows of all the pictures together, without the gap around them.
    private var shown: CGRect { layers.reduce(CGRect.null) { $0.union($1.shownFrame) } }

    /// The whole the pictures make: one picture is all of it; several have the same gap
    /// around them as when they were combined.
    var bounds: CGRect {
        let margin = isSeveral ? Self.gap : 0
        return shown.insetBy(dx: -margin, dy: -margin)
    }

    /// The topmost picture showing at `point`, if any.
    func topmost(at point: CGPoint) -> Int? {
        layers.indices.last { layers[$0].shownFrame.contains(point) }
    }

    /// Puts the picture at `index` with its bottom-left corner at `origin`.
    mutating func move(_ index: Int, to origin: CGPoint) {
        layers[index].frame.origin = origin
    }

    mutating func bringToFront(_ index: Int) {
        layers.append(layers.remove(at: index))
    }

    mutating func sendToBack(_ index: Int) {
        layers.insert(layers.remove(at: index), at: 0)
    }

    /// Makes a crop part of the pictures: each keeps only what lies within `area`, and
    /// one wholly outside it goes.
    mutating func keepOnly(_ area: CGRect) {
        layers = layers.compactMap { layer in
            let inside = layer.shownFrame.intersection(area)
            guard !inside.isNull, inside.width > 0, inside.height > 0 else { return nil }
            var kept = layer
            kept.kept = inside.offsetBy(dx: -layer.frame.minX, dy: -layer.frame.minY)
            return kept
        }
    }

    /// Where a picture of `size` goes when added: beside what shows, the gap apart, to the
    /// right with the tops level or below with the left edges level, whichever leaves the
    /// whole nearer a square; to the right when it is the same.
    func placeForNext(_ size: CGSize) -> CGPoint {
        let now = shown
        let right = CGPoint(x: now.maxX + Self.gap, y: now.maxY - size.height)
        let below = CGPoint(x: now.minX, y: now.minY - Self.gap - size.height)
        func squareness(_ origin: CGPoint) -> CGFloat {
            let whole = now.union(CGRect(origin: origin, size: size))
            return max(whole.width, whole.height) / min(whole.width, whole.height)
        }
        return squareness(below) < squareness(right) ? below : right
    }

    /// Puts a new picture on top, all of it showing.
    mutating func add(picture: Int, at origin: CGPoint, size: CGSize) {
        layers.append(Layer(picture: picture, frame: CGRect(origin: origin, size: size),
                            kept: CGRect(origin: .zero, size: size)))
    }
}
