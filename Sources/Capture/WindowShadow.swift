import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Gives a window capture a shadow of its own. The system's shadow is wide (it more
/// than doubles the margin around a small window) and cannot be made smaller, so for
/// the steps of the setting between none and the system's the capture is taken without
/// one and this adds one of that size. Runs in a helper process
/// (`--window-shadow <file> <level>`), since it decodes the picture.
enum WindowShadow {
    /// The steps of the setting run from 0, no shadow, to this one, the system's own;
    /// those in between are drawn here.
    static let systemLevel = 4
    /// In points, at the first step: how soft the shadow is, how far it drops, and the
    /// room it is given. Each further step adds as much again.
    static let blur: CGFloat = 10
    static let drop: CGFloat = 4
    static let margin = (side: CGFloat(14), top: CGFloat(10), bottom: CGFloat(18))

    /// The step the preferences hold. `earlier` is the choice of none, small or system
    /// that the setting was before it had steps.
    static func level(stored: Int?, earlier: String?) -> Int {
        if let stored = stored { return min(max(stored, 0), systemLevel) }
        switch earlier {
        case "none": return 0
        case "system": return systemLevel
        default: return 1
        }
    }

    /// The capture with a shadow around it as PNG bytes, or nil when it is not a window
    /// capture (nothing see-through at its corners) and should stay as it is.
    static func adding(to capture: CapturedImage, level: Int = 1) -> Data? {
        guard level > 0, capture.hasTransparentEdges, let image = capture.fullSizeUncached() else { return nil }
        // Points of the picture times the step.
        let scale = CGFloat(image.width) / capture.pointSize.width * CGFloat(level)
        let left = Int((margin.side * scale).rounded()), top = Int((margin.top * scale).rounded())
        let bottom = Int((margin.bottom * scale).rounded())
        let width = image.width + left * 2, height = image.height + top + bottom
        let space = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Shadow offsets and blur are in pixels and ignore the context's transform.
        context.setShadow(offset: CGSize(width: 0, height: -drop * scale), blur: blur * scale,
                          color: CGColor(gray: 0, alpha: 0.35))
        context.draw(image, in: CGRect(x: left, y: bottom, width: image.width, height: image.height))
        guard let result = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        let dpi = 72 * scale / CGFloat(level)
        CGImageDestinationAddImage(destination, result, [kCGImagePropertyDPIWidth: dpi,
                                                         kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    /// Entry point for the helper process: rewrites the file in place when it is a
    /// window capture, leaves it alone otherwise; never returns.
    static func runHelper(image path: String, level: Int) -> Never {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url), let capture = CapturedImage(data: data) else { exit(1) }
        if let shadowed = adding(to: capture, level: level) {
            do { try shadowed.write(to: url, options: .atomic) } catch { exit(1) }
        }
        exit(0)
    }
}
