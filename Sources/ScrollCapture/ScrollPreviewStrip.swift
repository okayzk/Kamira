import CoreGraphics
import Foundation

/// The picture behind the live preview of a scrolling capture: a narrow copy of the
/// stitched picture, as wide as the preview and no taller than the room it has. While
/// the picture is short all of it shows; after that only its newest part, which is
/// where the user is looking for a bad seam. Memory does not grow with the capture.
final class ScrollPreviewStrip {
    let width: Int
    /// The most rows the preview can show.
    let height: Int
    private let sourceWidth: Int
    private let context: CGContext
    /// Rows of the full-size picture represented so far.
    private var sourceRows = 0
    private var scale: CGFloat { CGFloat(width) / CGFloat(sourceWidth) }
    /// Height of the whole picture at preview size; the bitmap's bottom edge sits at
    /// this many rows, rounded down.
    private var total: CGFloat { CGFloat(sourceRows) * scale }

    /// `sourceWidth` is the width of the rows that will be appended; `width` and
    /// `height` are the preview's own size, all in pixels.
    init?(sourceWidth: Int, width: Int, height: Int) {
        guard sourceWidth > 0, width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        self.sourceWidth = sourceWidth
        self.width = width
        self.height = height
        self.context = context
        context.interpolationQuality = .medium
    }

    /// Adds `rows` rows of RGBA pixels, `sourceWidth` wide, below what is there.
    func append(_ pixels: UnsafeRawBufferPointer, rows: Int) {
        guard rows > 0, pixels.count >= rows * sourceWidth * 4, let base = pixels.baseAddress,
              let provider = CGDataProvider(dataInfo: nil, data: base, size: rows * sourceWidth * 4,
                                            releaseData: { _, _, _ in }),
              let image = CGImage(width: sourceWidth, height: rows, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: sourceWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent) else { return }
        let before = total
        sourceRows += rows
        let after = total
        shift(by: Int(after.rounded(.down)) - Int(before.rounded(.down)))
        // In the bitmap, measured up from its bottom edge, the new rows reach from the
        // old end of the picture down to the new one.
        // Both edges go out to whole rows: an edge inside a row would be blended with the
        // blank behind it and show as a dark line between two additions.
        let bottom = (after.rounded(.down) - after).rounded(.down)
        let top = (after.rounded(.down) - before).rounded(.up)
        context.draw(image, in: CGRect(x: 0, y: bottom, width: CGFloat(width), height: top - bottom))
    }

    /// Takes the last `rows` rows back out.
    func removeLast(rows: Int) {
        let before = total
        sourceRows = max(0, sourceRows - rows)
        shift(by: Int(total.rounded(.down)) - Int(before.rounded(.down)))
    }

    /// Moves the bitmap's content up by `rows` rows (down when negative); what moves in
    /// from the edge is blank.
    private func shift(by rows: Int) {
        guard rows != 0, let data = context.data else { return }
        let bytesPerRow = context.bytesPerRow
        let count = min(abs(rows), height)
        let kept = (height - count) * bytesPerRow
        // Row 0 of the memory is the top of the picture.
        if rows > 0 {
            memmove(data, data + count * bytesPerRow, kept)
            memset(data + kept, 0, count * bytesPerRow)
        } else {
            memmove(data + count * bytesPerRow, data, kept)
            memset(data, 0, count * bytesPerRow)
        }
    }

    /// What to show now: the picture so far, or its newest part once it is taller than
    /// the preview. Nil while there is nothing.
    func image() -> CGImage? {
        let filled = min(height, Int(total.rounded(.down)))
        guard filled > 0, let whole = context.makeImage() else { return nil }
        return whole.cropping(to: CGRect(x: 0, y: height - filled, width: width, height: filled))
    }
}
