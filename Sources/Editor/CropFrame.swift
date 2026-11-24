import CoreGraphics

/// The part of the picture a crop keeps, as the user adjusts it: in image points with the
/// origin at the bottom-left, like the annotations, and always inside the picture.
struct CropFrame: Equatable {
    var rect: CGRect

    /// The smallest a side can be made, in image points.
    static let minimumSide: CGFloat = 4

    /// Which edge each handle moves, horizontally and vertically: -1 the lower, 1 the
    /// upper, 0 neither. Anticlockwise from the bottom-left corner.
    private static let edges: [(x: Int, y: Int)] = [(-1, -1), (0, -1), (1, -1), (1, 0),
                                                    (1, 1), (0, 1), (-1, 1), (-1, 0)]

    /// The rectangle from `a` to `b`, whichever way it was dragged, cut to `limit`.
    static func spanning(_ a: CGPoint, _ b: CGPoint, inside limit: CGRect) -> CropFrame {
        let low = CGPoint(x: max(min(a.x, b.x), limit.minX), y: max(min(a.y, b.y), limit.minY))
        let high = CGPoint(x: min(max(a.x, b.x), limit.maxX), y: min(max(a.y, b.y), limit.maxY))
        return CropFrame(rect: CGRect(x: low.x, y: low.y, width: max(0, high.x - low.x), height: max(0, high.y - low.y)))
    }

    /// Where the handles are: the four corners and the middle of each edge.
    var handles: [CGPoint] {
        func coordinate(_ edge: Int, _ low: CGFloat, _ mid: CGFloat, _ high: CGFloat) -> CGFloat {
            edge < 0 ? low : edge > 0 ? high : mid
        }
        return Self.edges.map {
            CGPoint(x: coordinate($0.x, rect.minX, rect.midX, rect.maxX),
                    y: coordinate($0.y, rect.minY, rect.midY, rect.maxY))
        }
    }

    /// The frame after dragging handle `index` (into `handles`) to `point`: the edges it
    /// holds follow, as far as `limit` and the opposite edges allow.
    func movingHandle(_ index: Int, to point: CGPoint, inside limit: CGRect) -> CropFrame {
        let edge = Self.edges[index]
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        let side = Self.minimumSide
        if edge.x < 0 { minX = min(max(point.x, limit.minX), maxX - side) }
        if edge.x > 0 { maxX = max(min(point.x, limit.maxX), minX + side) }
        if edge.y < 0 { minY = min(max(point.y, limit.minY), maxY - side) }
        if edge.y > 0 { maxY = max(min(point.y, limit.maxY), minY + side) }
        return CropFrame(rect: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
    }

    /// The frame moved by as much of `offset` as keeps it inside `limit`.
    func moved(by offset: CGVector, inside limit: CGRect) -> CropFrame {
        let dx = min(max(offset.dx, limit.minX - rect.minX), limit.maxX - rect.maxX)
        let dy = min(max(offset.dy, limit.minY - rect.minY), limit.maxY - rect.maxY)
        return CropFrame(rect: rect.offsetBy(dx: dx, dy: dy))
    }

    /// `area`, in points from the bottom-left of a picture `pointSize` large, as whole
    /// pixels from the top-left of its bitmap, `pixelSize` large.
    static func pixelRect(of area: CGRect, pointSize: CGSize, pixelSize: CGSize) -> CGRect {
        let sx = pixelSize.width / pointSize.width, sy = pixelSize.height / pointSize.height
        let left = max(0, (area.minX * sx).rounded()), right = min(pixelSize.width, (area.maxX * sx).rounded())
        let top = max(0, ((pointSize.height - area.maxY) * sy).rounded())
        let bottom = min(pixelSize.height, ((pointSize.height - area.minY) * sy).rounded())
        return CGRect(x: left, y: top, width: max(1, right - left), height: max(1, bottom - top))
    }
}
