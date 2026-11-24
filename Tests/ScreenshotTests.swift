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

    // Several screenshots are laid out in the order taken, in rows, as near a square as
    // rows allow, with the same gap between them and around them. Frames are measured
    // from the bottom-left corner of the whole.
    do {
        let one = CollageLayout.arrange([CGSize(width: 400, height: 200)], gap: 16)
        check(one.frames == [CGRect(x: 16, y: 16, width: 400, height: 200)], "one picture inside the margin, got \(one.frames)")
        check(one.size == CGSize(width: 432, height: 232), "the whole is the picture and its margin, got \(one.size)")

        let square = CGSize(width: 300, height: 300)
        let two = CollageLayout.arrange([square, square], gap: 16)
        check(two.size == CGSize(width: 648, height: 332), "two squares side by side, not stacked, got \(two.size)")
        check(two.frames.map(\.minX) == [16, 332], "the first on the left, got \(two.frames)")

        let four = CollageLayout.arrange([square, square, square, square], gap: 16)
        check(four.size == CGSize(width: 648, height: 648), "four squares two by two, got \(four.size)")
        check(four.frames == [CGRect(x: 16, y: 332, width: 300, height: 300), CGRect(x: 332, y: 332, width: 300, height: 300),
                              CGRect(x: 16, y: 16, width: 300, height: 300), CGRect(x: 332, y: 16, width: 300, height: 300)],
              "read like a page: left to right, then the next row down, got \(four.frames)")

        let wide = CGSize(width: 1000, height: 100)
        let strips = CollageLayout.arrange([wide, wide, wide], gap: 16)
        check(strips.size == CGSize(width: 1032, height: 364), "wide pictures one under another, got \(strips.size)")

        // In a row, pictures of different heights line up at the top.
        let mixed = CollageLayout.arrange([CGSize(width: 100, height: 100), CGSize(width: 100, height: 200)], gap: 16)
        check(mixed.size == CGSize(width: 248, height: 232), "two narrow pictures in one row, got \(mixed.size)")
        check(mixed.frames[0].maxY == mixed.frames[1].maxY, "tops level in a row, got \(mixed.frames)")

        check(CollageLayout.arrange([], gap: 16).frames.isEmpty, "nothing to lay out")
    }

    // Combining: transparent around the pictures, at the sharpest picture's resolution,
    // each picture as large as it was on screen.
    do {
        let sharp = CapturedImage(data: retinaPNG)!                                          // 400 × 200 points at 2×
        let plain = CapturedImage(data: makeImageData(width: 100, height: 100, dpi: 72, type: .png))!   // 100 × 100 at 1×
        if let data = Collage.combining([sharp, plain], gap: 16), let whole = CapturedImage(data: data),
           let picture = whole.fullSizeUncached() {
            let layout = CollageLayout.arrange([sharp.pointSize, plain.pointSize], gap: 16)
            check(whole.pointSize == layout.size, "as large as the layout in points, got \(whole.pointSize)")
            check(whole.pixelSize == CGSize(width: layout.size.width * 2, height: layout.size.height * 2),
                  "at the sharper picture's resolution, got \(whole.pixelSize)")
            let width = picture.width, height = picture.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let canvas = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            canvas.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
            func alpha(_ point: CGPoint) -> UInt8 {   // a point of the layout, from the bottom-left
                let x = Int(point.x * 2), y = height - 1 - Int(point.y * 2)
                return bytes[(y * width + x) * 4 + 3]
            }
            check(alpha(CGPoint(x: 4, y: 4)) == 0, "the margin is transparent")
            for frame in layout.frames {
                check(alpha(CGPoint(x: frame.midX, y: frame.midY)) == 255, "each picture is in its place, \(frame)")
                check(alpha(CGPoint(x: frame.maxX - 1, y: frame.maxY - 1)) == 255, "and fills its frame, \(frame)")
            }
        } else { check(false, "the pictures were not combined") }
        check(Collage.combining([], gap: 16) == nil, "nothing to combine")
    }
}
