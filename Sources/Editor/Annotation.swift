import AppKit
import ImageIO
import UniformTypeIdentifiers

enum AnnotationTool: Int, CaseIterable {
    case arrow, rectangle, ellipse, pen, highlight, text, counter, mosaic

    var label: String {
        switch self {
        case .arrow: return L("tool.arrow")
        case .rectangle: return L("tool.rectangle")
        case .ellipse: return L("tool.ellipse")
        case .pen: return L("tool.pen")
        case .highlight: return L("tool.highlight")
        case .text: return L("tool.text")
        case .counter: return L("tool.counter")
        case .mosaic: return L("tool.mosaic")
        }
    }

    var symbolName: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .pen: return "scribble"
        case .highlight: return "highlighter"
        case .text: return "textformat"
        case .counter: return "1.circle"
        case .mosaic: return "checkerboard.rectangle"
        }
    }
}

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
        case .arrow, .rectangle, .ellipse, .highlight, .mosaic: return points.count == 2
        case .pen, .text, .counter: return false
        }
    }

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
        case .arrow, .rectangle, .ellipse, .highlight, .mosaic:
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
        case .arrow:
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

    /// The points that can be dragged to reshape the annotation: both ends of an arrow,
    /// the four corners of anything spanned by a rectangle, none for the rest.
    var handles: [CGPoint] {
        guard hasTwoPoints else { return [] }
        if tool == .arrow { return points }
        // Handle `h` takes its x from point `h & 1` and its y from point `h >> 1`.
        return (0..<4).map { CGPoint(x: points[$0 & 1].x, y: points[$0 >> 1].y) }
    }

    /// The annotation after dragging handle `index` (into `handles`) to `point`.
    func movingHandle(_ index: Int, to point: CGPoint) -> Annotation {
        guard hasTwoPoints else { return self }
        var copy = self
        if tool == .arrow {
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

/// Draws annotations with Core Graphics only, so the on-screen canvas and the exported
/// image go through exactly the same code.
enum AnnotationRenderer {
    static let lineWidth: CGFloat = 3
    static let fontSize: CGFloat = 18
    static let counterRadius: CGFloat = 12

    static var textFont: NSFont { .boldSystemFont(ofSize: fontSize) }

    /// A coarse copy of the capture; drawn enlarged without smoothing it becomes the mosaic.
    static func mosaicImage(for capture: CapturedImage) -> CGImage? {
        capture.downsampled(maxPixel: max(4, max(capture.pointSize.width, capture.pointSize.height) / 10))
    }

    /// - Parameters:
    ///   - scale: device units per image point (view zoom on screen, pixel density on export).
    ///   - imageSize: the image size in points.
    static func draw(_ annotations: [Annotation], in context: CGContext, scale: CGFloat,
                     imageSize: CGSize, mosaic: CGImage?) {
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        for annotation in annotations {
            context.saveGState()
            draw(annotation, in: context, imageSize: imageSize, mosaic: mosaic)
            context.restoreGState()
        }
        context.restoreGState()
    }

    private static func draw(_ annotation: Annotation, in context: CGContext,
                             imageSize: CGSize, mosaic: CGImage?) {
        guard let first = annotation.points.first, let last = annotation.points.last else { return }
        context.setStrokeColor(annotation.color)
        context.setFillColor(annotation.color)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch annotation.tool {
        case .arrow:
            let length = hypot(last.x - first.x, last.y - first.y)
            guard length > 0 else { return }
            let unit = CGPoint(x: (last.x - first.x) / length, y: (last.y - first.y) / length)
            let head = min(16, length * 0.6)
            let half = head * 0.45
            let base = CGPoint(x: last.x - unit.x * head, y: last.y - unit.y * head)
            context.move(to: first)
            context.addLine(to: base)
            context.strokePath()
            context.move(to: last)
            context.addLine(to: CGPoint(x: base.x - unit.y * half, y: base.y + unit.x * half))
            context.addLine(to: CGPoint(x: base.x + unit.y * half, y: base.y - unit.x * half))
            context.closePath()
            context.fillPath()
        case .rectangle:
            context.stroke(annotation.rect)
        case .ellipse:
            context.strokeEllipse(in: annotation.rect)
        case .pen:
            context.addLines(between: annotation.points)
            context.strokePath()
        case .highlight:
            // Plain translucent colour: a multiply blend would vanish on dark images.
            context.setFillColor(annotation.color.copy(alpha: 0.4) ?? annotation.color)
            context.fill(annotation.rect)
        case .text:
            let line = makeLine(annotation.text, font: textFont, color: annotation.color)
            context.textPosition = CGPoint(x: first.x, y: first.y - textFont.ascender)
            CTLineDraw(line, context)
        case .counter:
            let disc = CGRect(x: first.x - counterRadius, y: first.y - counterRadius,
                              width: counterRadius * 2, height: counterRadius * 2)
            context.fillEllipse(in: disc)
            let font = NSFont.boldSystemFont(ofSize: 13)
            let ink = isLight(annotation.color) ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1)
            let line = makeLine(annotation.text, font: font, color: ink)
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            context.textPosition = CGPoint(x: first.x - width / 2, y: first.y - font.capHeight / 2)
            CTLineDraw(line, context)
        case .mosaic:
            guard let mosaic = mosaic else { return }
            context.clip(to: annotation.rect)
            context.interpolationQuality = .none
            context.draw(mosaic, in: CGRect(origin: .zero, size: imageSize))
        }
    }

    static func makeLine(_ text: String, font: NSFont, color: CGColor) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    private static func isLight(_ color: CGColor) -> Bool {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let c = color.converted(to: srgb, intent: .defaultIntent, options: nil)?.components,
              c.count >= 3 else { return false }
        return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2] > 0.7
    }

    /// Burns the annotations into the capture at full resolution and returns PNG bytes.
    static func export(capture: CapturedImage, annotations: [Annotation]) -> Data? {
        guard let image = capture.fullSizeUncached() else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        func makeContext(_ space: CGColorSpace) -> CGContext? {
            CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        // Keep the capture's own colour space when a bitmap can be created in it.
        let preferred = image.colorSpace?.model == .rgb ? image.colorSpace! : sRGB
        guard let context = makeContext(preferred) ?? makeContext(sRGB) else { return nil }
        context.draw(image, in: bounds)
        let scale = CGFloat(image.width) / capture.pointSize.width
        draw(annotations, in: context, scale: scale, imageSize: capture.pointSize,
             mosaic: mosaicImage(for: capture))
        guard let result = context.makeImage() else { return nil }

        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let dpi = 72 * scale
        let properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        CGImageDestinationAddImage(destination, result, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}

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
