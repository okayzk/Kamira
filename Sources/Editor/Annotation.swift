import AppKit
import ImageIO
import UniformTypeIdentifiers

/// One mark on the image. Coordinates are in image points with the origin at the
/// bottom-left, so the same data draws on screen and at full resolution on export.
struct Annotation {
    var tool: AnnotationTool
    var color: CGColor
    /// Two corners for shapes, the stroke for the pen, the top-left corner for text,
    /// the centre for a counter.
    var points: [CGPoint]
    /// Text content, or the number shown in a counter.
    var text = ""

    /// Rectangle spanned by the first and last point, whichever way it was dragged.
    var rect: CGRect {
        guard let a = points.first, let b = points.last else { return .zero }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

// MARK: Editing a finished annotation

extension Annotation {
    /// Whether the tool is defined by two points that can each be dragged afterwards.
    private var hasTwoPoints: Bool {
        switch tool {
        case .arrow, .line, .rectangle, .ellipse, .highlight, .mosaic: return points.count == 2
        case .pen, .text, .counter: return false
        }
    }

    /// Whether the annotation is a segment between its two points, reshaped by its ends
    /// rather than by the corners of a box.
    var isSegment: Bool { tool == .arrow || tool == .line }

    /// The smallest rectangle around everything the annotation draws, ignoring line width.
    var bounds: CGRect {
        guard let first = points.first else { return .zero }
        switch tool {
        case .text:
            let font = AnnotationRenderer.textFont
            let line = AnnotationRenderer.makeLine(text, font: font, color: color)
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let height = font.ascender - font.descender
            return CGRect(x: first.x, y: first.y - height, width: width, height: height)
        case .counter:
            let radius = AnnotationRenderer.counterRadius
            return CGRect(x: first.x - radius, y: first.y - radius, width: radius * 2, height: radius * 2)
        case .pen:
            return points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        case .arrow, .line, .rectangle, .ellipse, .highlight, .mosaic:
            return rect
        }
    }

    /// Whether a click at `point` lands on what the annotation draws, give or take
    /// `tolerance`. Outlined shapes are hit on the outline only, so that something can
    /// still be drawn inside them.
    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        let reach = tolerance + AnnotationRenderer.lineWidth / 2
        func nearLine(_ a: CGPoint, _ b: CGPoint) -> Bool {
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared == 0 ? 0
                : min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
            return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy)) <= reach
        }
        func insideEllipse(_ box: CGRect) -> Bool {
            guard box.width > 0, box.height > 0 else { return false }
            let x = (point.x - box.midX) / (box.width / 2), y = (point.y - box.midY) / (box.height / 2)
            return x * x + y * y <= 1
        }
        let outer = rect.insetBy(dx: -reach, dy: -reach)
        // Empty when the shape is too small to have a middle.
        let inner = rect.width > reach * 2 && rect.height > reach * 2 ? rect.insetBy(dx: reach, dy: reach) : .null
        switch tool {
        case .arrow, .line:
            guard let first = points.first, let last = points.last else { return false }
            return nearLine(first, last)
        case .pen:
            return zip(points, points.dropFirst()).contains { nearLine($0, $1) }
        case .rectangle:
            return outer.contains(point) && !inner.contains(point)
        case .ellipse:
            return insideEllipse(outer) && !insideEllipse(inner)
        case .highlight, .mosaic:
            return outer.contains(point)
        case .text, .counter:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    func moved(by offset: CGVector) -> Annotation {
        var copy = self
        copy.points = points.map { CGPoint(x: $0.x + offset.dx, y: $0.y + offset.dy) }
        return copy
    }

    /// Moves as far as `offset` allows without leaving `limit` (the image).
    func moved(by offset: CGVector, keepingInside limit: CGRect) -> Annotation {
        let box = bounds
        func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            low <= high ? min(max(value, low), high) : value
        }
        return moved(by: CGVector(dx: clamp(offset.dx, limit.minX - box.minX, limit.maxX - box.maxX),
                                  dy: clamp(offset.dy, limit.minY - box.minY, limit.maxY - box.maxY)))
    }

    /// The points that can be dragged to reshape the annotation: both ends of an arrow or
    /// a line, the four corners of anything spanned by a rectangle, none for the rest.
    var handles: [CGPoint] {
        guard hasTwoPoints else { return [] }
        if isSegment { return points }
        // Handle `h` takes its x from point `h & 1` and its y from point `h >> 1`.
        return (0..<4).map { CGPoint(x: points[$0 & 1].x, y: points[$0 >> 1].y) }
    }

    /// The annotation after dragging handle `index` (into `handles`) to `point`.
    func movingHandle(_ index: Int, to point: CGPoint) -> Annotation {
        guard hasTwoPoints else { return self }
        var copy = self
        if isSegment {
            copy.points[index] = point
        } else {
            copy.points[index & 1].x = point.x
            copy.points[index >> 1].y = point.y
        }
        return copy
    }

    /// Numbers the counters 1, 2, 3… in drawing order, e.g. after one was deleted.
    static func renumberingCounters(_ annotations: [Annotation]) -> [Annotation] {
        var number = 0
        return annotations.map { annotation in
            guard annotation.tool == .counter else { return annotation }
            number += 1
            var copy = annotation
            copy.text = "\(number)"
            return copy
        }
    }
}
