import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Combines several screenshots into one picture, laid out by `CollageLayout`, on the
/// background last chosen in the editor; by default nothing (see-through), as around a
/// window capture. Pictures from screens of different sharpness come out as large as they
/// were on screen, at the sharpest one's resolution. Runs in a helper process
/// (`--combine <output> <background> <picture>…`), since it decodes every picture.
enum Collage {
    /// Between the pictures and around them, in points.
    static let gap = CapturedImage.Part.spacing

    /// Where each picture goes, read from the files' headers without decoding them.
    static func layout(of files: [URL], gap: CGFloat = gap) -> [CGRect]? {
        let sizes = files.compactMap { file in
            (try? Data(contentsOf: file, options: .alwaysMapped)).flatMap(CapturedImage.init(data:))?.pointSize
        }
        return sizes.count == files.count ? CollageLayout.arrange(sizes, gap: gap).frames : nil
    }

    /// The combined picture as PNG bytes, or nil when there is nothing to combine.
    static func combining(_ pictures: [CapturedImage], gap: CGFloat = gap, background: CGColor? = nil) -> Data? {
        guard !pictures.isEmpty else { return nil }
        let layout = CollageLayout.arrange(pictures.map(\.pointSize), gap: gap)
        let scale = pictures.map { $0.pixelSize.width / $0.pointSize.width }.max()!
        let width = Int((layout.size.width * scale).rounded()), height = Int((layout.size.height * scale).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if let background = background {
            context.setFillColor(background)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.interpolationQuality = .high
        for (picture, frame) in zip(pictures, layout.frames) {
            // One at a time, so only one decoded picture is held besides the whole.
            autoreleasepool {
                guard let image = picture.fullSizeUncached() else { return }
                context.draw(image, in: CGRect(x: frame.minX * scale, y: frame.minY * scale,
                                               width: frame.width * scale, height: frame.height * scale))
            }
        }
        guard let whole = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        let dpi = 72 * scale
        CGImageDestinationAddImage(destination, whole, [kCGImagePropertyDPIWidth: dpi,
                                                        kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    /// How the background travels on the command line: four sRGB components, or `none`.
    static func argument(for background: CGColor?) -> String {
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let c = background?.converted(to: sRGB, intent: .defaultIntent, options: nil)?.components,
              c.count == 4 else { return "none" }
        return c.map { String(Double($0)) }.joined(separator: ",")
    }

    static func background(fromArgument text: String) -> CGColor? {
        let c = text.split(separator: ",").compactMap { Double($0) }
        return c.count == 4 ? CGColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c[3]) : nil
    }

    /// Entry point for the helper process, given `<output> <background> <picture>…`: writes
    /// the combined picture to `output`; never returns. The pictures are left for the app.
    static func runHelper(arguments: [String]) -> Never {
        guard arguments.count >= 3 else { exit(1) }
        let paths = arguments.dropFirst(2)
        let pictures = paths.compactMap { path in
            (try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)).flatMap(CapturedImage.init(data:))
        }
        guard pictures.count == paths.count,
              let data = combining(pictures, background: background(fromArgument: arguments[1])) else { exit(1) }
        do { try data.write(to: URL(fileURLWithPath: arguments[0]), options: .atomic) } catch { exit(1) }
        exit(0)
    }
}
