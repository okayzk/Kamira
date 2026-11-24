import AppKit
import UniformTypeIdentifiers

/// Draws annotations with Core Graphics only, so the on-screen canvas and the exported
/// image go through exactly the same code.
enum AnnotationRenderer {
    static let lineWidth: CGFloat = 3
    static let fontSize: CGFloat = 18
    static let counterRadius: CGFloat = 12

    static var textFont: NSFont { .boldSystemFont(ofSize: fontSize) }

    /// A coarse copy of a picture and where it lies; drawn enlarged without smoothing,
    /// the copies of all the pictures become the mosaic.
    struct MosaicTile {
        let image: CGImage
        let frame: CGRect
    }

    /// A coarse copy of the capture; drawn enlarged without smoothing it becomes the mosaic.
    static func mosaicImage(for capture: CapturedImage) -> CGImage? {
        capture.downsampled(maxPixel: max(4, max(capture.pointSize.width, capture.pointSize.height) / 10))
    }

    /// The mosaic's tiles for `pictures` lying as `stack` says, bottom to top.
    static func mosaicTiles(_ pictures: [CapturedImage], _ stack: LayerStack) -> [MosaicTile] {
        let images = pictures.map(mosaicImage(for:))
        return stack.layers.compactMap { layer in images[layer.picture].map { MosaicTile(image: $0, frame: layer.frame) } }
    }

    /// - Parameters:
    ///   - scale: device units per image point (view zoom on screen, pixel density on export).
    ///   - mosaic: what a mosaic shows, coarsened.
    static func draw(_ annotations: [Annotation], in context: CGContext, scale: CGFloat, mosaic: [MosaicTile]) {
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        for annotation in annotations {
            context.saveGState()
            draw(annotation, in: context, mosaic: mosaic)
            context.restoreGState()
        }
        context.restoreGState()
    }

    private static func draw(_ annotation: Annotation, in context: CGContext, mosaic: [MosaicTile]) {
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
        case .line:
            context.move(to: first)
            context.addLine(to: last)
            context.strokePath()
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
            context.clip(to: annotation.rect)
            context.interpolationQuality = .none
            for tile in mosaic { context.draw(tile.image, in: tile.frame) }
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

    /// Burns the annotations into the capture at full resolution and returns PNG bytes:
    /// all of it, or only `area` (image points) if it was cropped.
    static func export(capture: CapturedImage, annotations: [Annotation], area: CGRect? = nil) -> Data? {
        let whole = CGRect(origin: .zero, size: capture.pointSize)
        return export(pictures: [capture], stack: LayerStack(frames: [whole]), background: nil,
                      annotations: annotations, area: area ?? whole)
    }

    /// Burns the pictures, lying as `stack` says, and the annotations over them into one
    /// picture at the sharpest picture's resolution, and returns PNG bytes of `area`
    /// (points). Between several pictures lies `background`; nil leaves it see-through.
    static func export(pictures: [CapturedImage], stack: LayerStack, background: CGColor?,
                       annotations: [Annotation], area: CGRect) -> Data? {
        guard !pictures.isEmpty else { return nil }
        let scale = pictures.map { $0.pixelSize.width / $0.pointSize.width }.max()!
        let width = Int((area.width * scale).rounded()), height = Int((area.height * scale).rounded())
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        func makeContext(_ space: CGColorSpace) -> CGContext? {
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        // Keep a single capture's own colour space when a bitmap can be created in it.
        let own = pictures.count == 1 ? pictures[0].fullSizeUncached()?.colorSpace : nil
        let preferred = own?.model == .rgb ? own! : sRGB
        guard width > 0, height > 0, let context = makeContext(preferred) ?? makeContext(sRGB) else { return nil }
        context.translateBy(x: -area.minX * scale, y: -area.minY * scale)
        if stack.isSeveral, let background = background {
            context.setFillColor(background)
            context.fill(stack.bounds.applying(CGAffineTransform(scaleX: scale, y: scale)))
        }
        context.interpolationQuality = .high
        for layer in stack.layers {
            // One at a time, so only one decoded picture is held besides the whole.
            autoreleasepool {
                guard let image = pictures[layer.picture].fullSizeUncached() else { return }
                context.draw(image, in: layer.frame.applying(CGAffineTransform(scaleX: scale, y: scale)))
            }
        }
        draw(annotations, in: context, scale: scale, mosaic: mosaicTiles(pictures, stack))
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
