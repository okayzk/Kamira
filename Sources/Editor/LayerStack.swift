import CoreGraphics

/// The pictures in an editor and where each lies, bottom to top: one for an ordinary
/// capture, several for screenshots combined into one. Frames are in points from the
/// bottom-left, like the annotations, which lie over all the pictures and do not move
/// with them. Indices count from the bottom of the stack.
struct LayerStack: Equatable {
    struct Layer: Equatable {
        /// Which picture, in the order the pictures were given.
        let picture: Int
        var frame: CGRect
    }

    private(set) var layers: [Layer]

    /// Picture `i` at `frames[i]`, the first at the bottom.
    init(frames: [CGRect]) {
        layers = frames.enumerated().map { Layer(picture: $0, frame: $1) }
    }

    var isSeveral: Bool { layers.count > 1 }

    /// The whole the pictures make: one picture is all of it; several have the same gap
    /// around them as when they were combined.
    var bounds: CGRect {
        let union = layers.reduce(CGRect.null) { $0.union($1.frame) }
        let margin = isSeveral ? CapturedImage.Part.spacing : 0
        return union.insetBy(dx: -margin, dy: -margin)
    }

    /// The topmost picture under `point`, if any.
    func topmost(at point: CGPoint) -> Int? {
        layers.indices.last { layers[$0].frame.contains(point) }
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
}
