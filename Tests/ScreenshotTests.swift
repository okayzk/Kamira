import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Screenshots (Sources/Screenshot/).
func testScreenshot() {
    // A window capture has see-through margins (its shadow); an ordinary capture does not.
    do {
        let context = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 40, y: 40, width: 220, height: 120))
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        check(CapturedImage(data: out as Data)?.hasTransparentEdges == true, "a picture with clear margins has transparent edges")
        check(CapturedImage(data: retinaPNG)?.hasTransparentEdges == false, "a solid picture has no transparent edges")
        // A small shadow of our own: only for window captures, with room around the picture.
        let cutOut = CapturedImage(data: out as Data)!   // 300×200 px at 72 dpi
        if let data = WindowShadow.adding(to: cutOut), let shadowed = CapturedImage(data: data),
           let picture = shadowed.fullSizeUncached() {
            check(shadowed.pixelSize == CGSize(width: 328, height: 228), "shadow adds its margins, got \(shadowed.pixelSize)")
            check(shadowed.pointSize == shadowed.pixelSize, "shadow keeps the resolution, got \(shadowed.pointSize)")
            var bytes = [UInt8](repeating: 0, count: 328 * 228 * 4)
            let canvas = CGContext(data: &bytes, width: 328, height: 228, bitsPerComponent: 8, bytesPerRow: 328 * 4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            canvas.draw(picture, in: CGRect(x: 0, y: 0, width: 328, height: 228))
            func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[(y * 328 + x) * 4 + 3] }   // y from the top
            check(alpha(164, 114) == 255, "the picture itself stays solid")
            // The box ends 40 px above the old bottom edge; just under it lies shadow.
            check(alpha(164, 10 + 160 + 4) > 20 && alpha(164, 10 + 160 + 4) < 255, "shadow under the picture, got \(alpha(164, 174))")
            check(alpha(2, 2) == 0, "nothing in the far corner, got \(alpha(2, 2))")
        } else { check(false, "shadow was not added") }
        check(WindowShadow.adding(to: CapturedImage(data: retinaPNG)!) == nil, "an ordinary capture gets no shadow")
        // Larger steps of the setting give a larger shadow and more room for it.
        check(WindowShadow.adding(to: cutOut, level: 2).flatMap { CapturedImage(data: $0) }?.pixelSize
                == CGSize(width: 356, height: 256), "the second step doubles the margins")
        check(WindowShadow.adding(to: cutOut, level: 3).flatMap { CapturedImage(data: $0) }?.pixelSize
                == CGSize(width: 384, height: 284), "the third step triples them")
    }
}
