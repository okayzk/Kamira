import AppKit

/// The pictures an editor shows, in copies sized for the screen, and their coarse copies
/// for the mosaic. Where they lie and what lies between them is the canvas's state
/// (`LayerStack`, the background), handed in to draw; the export decodes the full
/// pictures itself.
final class EditorPictures {
    /// Every picture given or added, also one an undo took off the canvas.
    private(set) var pictures: [CapturedImage] = []
    /// Image pixels per point of the sharpest picture, to which a crop is rounded.
    var pixelDensity: CGFloat { pictures.map { $0.pixelSize.width / $0.pointSize.width }.max() ?? 1 }
    private var shown: [CGImage?] = []
    private var coarse: [CGImage?] = []
    /// View points per picture point at a zoom of 1, when the editor opened.
    private let viewScale: CGFloat

    init(_ pictures: [CapturedImage], viewScale: CGFloat) {
        self.viewScale = viewScale
        pictures.forEach { add($0) }
    }

    /// Takes one more picture and returns its number.
    @discardableResult
    func add(_ picture: CapturedImage) -> Int {
        // Only as many pixels as the canvas can show when zoomed in all the way (never
        // more than a picture has).
        let backing = NSScreen.underPointer?.backingScaleFactor ?? 2
        let largestZoom = EditorZoom.steps[EditorZoom.steps.count - 1]
        pictures.append(picture)
        shown.append(picture.downsampled(maxPixel: max(picture.pointSize.width, picture.pointSize.height)
                                         * viewScale * backing * largestZoom))
        coarse.append(AnnotationRenderer.mosaicImage(for: picture))
        return pictures.count - 1
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
            guard let image = shown[layer.picture] else { continue }
            AnnotationRenderer.drawPicture(image, at: layer.frame, shown: layer.shownFrame, in: context, scale: scale)
        }
    }

    /// What a mosaic shows, for the pictures lying as `stack` says.
    func mosaic(_ stack: LayerStack) -> [AnnotationRenderer.MosaicTile] {
        stack.layers.compactMap { layer in
            coarse[layer.picture].map { AnnotationRenderer.MosaicTile(image: $0, frame: layer.frame, shown: layer.shownFrame) }
        }
    }
}
