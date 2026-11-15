import AppKit

/// Kamira's mark, drawn here and nowhere else, at both of its sizes: the app icon
/// (`make icon` runs `scripts/make_icon.swift`, which calls `drawAppIcon`) and the menu
/// bar icon (`StatusIcon`). A round mirror holding a four-point star a little above and
/// right of its centre: Kamira joins Kagami, the mirror, with Mira, the star.
/// Uses nothing but AppKit, so the icon script can compile it on its own.
enum AppMark {
    /// Adds a four-point star, pinched towards its centre, to the context's path.
    static func addStar(to context: CGContext, at point: CGPoint, reach: CGFloat, pinch: CGFloat) {
        context.move(to: CGPoint(x: point.x, y: point.y + reach))
        for step in 1...4 {
            let angle = CGFloat.pi / 2 - CGFloat(step) * .pi / 2
            let between = angle + .pi / 4
            context.addQuadCurve(to: CGPoint(x: point.x + cos(angle) * reach, y: point.y + sin(angle) * reach),
                                 control: CGPoint(x: point.x + cos(between) * pinch, y: point.y + sin(between) * pinch))
        }
        context.closePath()
    }

    /// The menu bar icon in an 18-point square, in the context's current colours, for a
    /// template image: the mirror's rim at the menu bar's 1.5-point line, and the star.
    static func drawMenuBarIcon(in context: CGContext) {
        context.setLineWidth(1.5)
        context.strokeEllipse(in: CGRect(x: 1.5, y: 1.5, width: 15, height: 15))
        addStar(to: context, at: CGPoint(x: 9.9, y: 10), reach: 4.4, pinch: 1.0)
        context.fillPath()
    }

    /// The app icon on a 1024-unit canvas, Apple's icon template, already scaled into
    /// the context. `unit` is pixels per canvas unit: shadows ignore the transform, so
    /// their sizes are multiplied by it.
    static func drawAppIcon(in context: CGContext, unit: CGFloat) {
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        func colour(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
            CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }
        let centre = CGPoint(x: 512, y: 512)

        // The tile: 824 units wide with the system's corner radius, leaving room for a shadow.
        let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
        let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
        let night = [colour(0.20, 0.27, 0.62), colour(0.11, 0.12, 0.36), colour(0.22, 0.10, 0.36)]
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10 * unit), blur: 24 * unit,
                          color: CGColor(gray: 0, alpha: 0.28))
        context.addPath(tilePath)
        context.setFillColor(night[1])
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(tilePath)
        context.clip()
        context.drawLinearGradient(CGGradient(colorsSpace: sRGB, colors: night as CFArray, locations: [0, 0.55, 1])!,
                                   start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY),
                                   options: [])
        // A soft light from the top edge, like glass.
        let sheen = CGGradient(colorsSpace: sRGB,
                               colors: [CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0)] as CFArray,
                               locations: [0, 1])!
        context.drawLinearGradient(sheen, start: CGPoint(x: 512, y: tile.maxY), end: CGPoint(x: 512, y: 512),
                                   options: [])
        context.restoreGState()

        // The mirror: glass lit from the top left, two faint reflections across it, a white
        // rim. Its diameter is 72% of the tile, chosen by eye in the Dock against 70% and 73%.
        let radius: CGFloat = 298
        let disc = CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius)
        context.saveGState()
        context.addEllipse(in: disc)
        context.clip()
        context.drawLinearGradient(CGGradient(colorsSpace: sRGB,
                                              colors: [colour(0.36, 0.46, 0.95), colour(0.14, 0.16, 0.45)] as CFArray,
                                              locations: nil)!,
                                   start: CGPoint(x: disc.minX, y: disc.maxY), end: CGPoint(x: disc.maxX, y: disc.minY),
                                   options: [])
        context.translateBy(x: centre.x, y: centre.y)
        context.rotate(by: .pi / 4)
        context.setFillColor(CGColor(gray: 1, alpha: 0.16))
        context.fill(CGRect(x: -radius, y: radius * 0.30, width: 2 * radius, height: radius * 0.20))
        context.setFillColor(CGColor(gray: 1, alpha: 0.10))
        context.fill(CGRect(x: -radius, y: radius * 0.60, width: 2 * radius, height: radius * 0.08))
        context.restoreGState()
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(41)
        context.strokeEllipse(in: disc)

        // Mira, bright and glowing, and three faint stars.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.saveGState()
        context.setShadow(offset: .zero, blur: 46 * unit, color: CGColor(gray: 1, alpha: 0.9))
        addStar(to: context, at: CGPoint(x: 581, y: 585), reach: 124, pinch: 23)
        context.fillPath()
        context.restoreGState()
        addStar(to: context, at: CGPoint(x: 384, y: 418), reach: 18, pinch: 4.6)
        addStar(to: context, at: CGPoint(x: 443, y: 659), reach: 12.6, pinch: 3.2)
        addStar(to: context, at: CGPoint(x: 659, y: 407), reach: 15, pinch: 3.7)
        context.fillPath()
    }
}
