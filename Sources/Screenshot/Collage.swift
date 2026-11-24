import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Combines several screenshots into one picture, laid out by `CollageLayout`, with
/// nothing (transparent) between and around them, as around a window capture. Pictures
/// from screens of different sharpness come out as large as they were on screen, at the
/// sharpest one's resolution. Runs in a helper process (`--combine <output> <picture>…`),
/// since it decodes every picture.
enum Collage {
    /// Between the pictures and around them, in points.
    static let gap: CGFloat = 16

    /// The combined picture as PNG bytes, or nil when there is nothing to combine.
    static func combining(_ pictures: [CapturedImage], gap: CGFloat = gap) -> Data? {
        guard !pictures.isEmpty else { return nil }
        let layout = CollageLayout.arrange(pictures.map(\.pointSize), gap: gap)
        let scale = pictures.map { $0.pixelSize.width / $0.pointSize.width }.max()!
        let width = Int((layout.size.width * scale).rounded()), height = Int((layout.size.height * scale).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
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

    /// Entry point for the helper process: writes the combined picture to `output`; never
    /// returns. The pictures are left for the app to delete.
    static func runHelper(output: String, pictures paths: [String]) -> Never {
        let pictures = paths.compactMap { path in
            (try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)).flatMap(CapturedImage.init(data:))
        }
        guard pictures.count == paths.count, let data = combining(pictures) else { exit(1) }
        do { try data.write(to: URL(fileURLWithPath: output), options: .atomic) } catch { exit(1) }
        exit(0)
    }
}
