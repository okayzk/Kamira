import AppKit
import UniformTypeIdentifiers

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
