import AppKit

/// The pictures an editor shows, in copies sized for the screen, and their coarse copies
/// for the mosaic. Where they lie and what lies between them is the canvas's state
/// (`LayerStack`, the background), handed in to draw; the export decodes the full
/// pictures itself.
final class EditorPictures {
    let pictures: [CapturedImage]
    /// Image pixels per point of the sharpest picture, to which a crop is rounded.
    let pixelDensity: CGFloat
    private let shown: [CGImage?]
    private let coarse: [CGImage?]

    /// `viewScale` is how many view points one picture point takes at a zoom of 1.
    init(_ pictures: [CapturedImage], viewScale: CGFloat) {
        self.pictures = pictures
        pixelDensity = pictures.map { $0.pixelSize.width / $0.pointSize.width }.max() ?? 1
        // Only as many pixels as the canvas can show when zoomed in all the way (never
        // more than a picture has).
        let backing = NSScreen.underPointer?.backingScaleFactor ?? 2
        let largestZoom = EditorZoom.steps[EditorZoom.steps.count - 1]
        shown = pictures.map { picture in
            picture.downsampled(maxPixel: max(picture.pointSize.width, picture.pointSize.height)
                                * viewScale * backing * largestZoom)
        }
        coarse = pictures.map(AnnotationRenderer.mosaicImage(for:))
    }

    /// Draws the background between several pictures, then the pictures, bottom to top;
    /// `scale` is view points per picture point.
    func draw(_ stack: LayerStack, background: CGColor?, in context: CGContext, scale: CGFloat) {
        let toView = CGAffineTransform(scaleX: scale, y: scale)
        if stack.isSeveral, let background = background {
            context.setFillColor(background)
            context.fill(stack.bounds.applying(toView))
        }
        context.interpolationQuality = .high
        for layer in stack.layers {
            if let image = shown[layer.picture] { context.draw(image, in: layer.frame.applying(toView)) }
        }
    }

    /// What a mosaic shows, for the pictures lying as `stack` says.
    func mosaic(_ stack: LayerStack) -> [AnnotationRenderer.MosaicTile] {
        stack.layers.compactMap { layer in
            coarse[layer.picture].map { AnnotationRenderer.MosaicTile(image: $0, frame: layer.frame) }
        }
    }
}
