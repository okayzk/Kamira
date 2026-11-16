import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A capture kept as its encoded bytes (PNG or TIFF).
/// The full-resolution bitmap is never held decoded in memory: views ask for a
/// downsampled copy sized for what they actually display.
///
/// In the menu bar app the bytes live in a temporary file that is mapped into memory
/// rather than read (`init(owningFile:)`): mapped pages cost no memory until touched and
/// go straight back to the system, where allocated memory would linger after use.
final class CapturedImage {
    let data: Data
    /// The temporary file behind `data`, if any. It is deleted with this object.
    let fileURL: URL?
    /// Size in pixels.
    let pixelSize: CGSize
    /// Size in points, i.e. how large the image appeared on screen when captured.
    let pointSize: CGSize
    /// Default file name for saving and dragging, fixed at capture time.
    let suggestedFileName: String
    private let source: CGImageSource
    /// The folder of its own the file was moved into, removed with it.
    private let ownFolder: URL?
    /// Set when the file was handed to another app by dragging: that app may still be
    /// reading it, so it is deleted `dragGrace` seconds after this object goes away.
    var wasDraggedOut = false
    static var dragGrace: TimeInterval = 300

    convenience init?(data: Data) { self.init(data: data, fileURL: nil, ownFolder: nil) }

    /// Takes over an image file: moves it into a folder of its own under the name it will
    /// have when dragged out, maps it, and deletes both when this object goes away. A drag
    /// then hands over this very file; no copy is written.
    convenience init?(owningFile url: URL) {
        let name = FileNaming.screenshotName() + "." + (url.pathExtension.isEmpty ? "png" : url.pathExtension)
        let folder = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
        var file = folder.appendingPathComponent(name)
        var ownFolder: URL? = folder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: file)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            file = url
            ownFolder = nil
        }
        guard let mapped = try? Data(contentsOf: file, options: .alwaysMapped) else {
            try? FileManager.default.removeItem(at: file)
            if let ownFolder = ownFolder { try? FileManager.default.removeItem(at: ownFolder) }
            return nil
        }
        self.init(data: mapped, fileURL: file, ownFolder: ownFolder)
    }

    /// Writes `data` into `directory`, as PNG, and returns a capture backed by that file.
    static func stored(_ data: Data, in directory: URL) -> CapturedImage? {
        var data = data
        // A TIFF from the clipboard becomes PNG once, here, so a drag never needs a copy.
        if data.prefix(4) != Data([0x89, 0x50, 0x4E, 0x47]) {
            guard let png = CapturedImage(data: data)?.pngData() else { return nil }
            data = png
        }
        let url = directory.appendingPathComponent("capture-\(UUID().uuidString).png")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        return CapturedImage(owningFile: url)
    }

    deinit {
        guard let fileURL = fileURL else { return }
        let folder = ownFolder
        let remove = {
            try? FileManager.default.removeItem(at: fileURL)
            if let folder = folder { try? FileManager.default.removeItem(at: folder) }
        }
        // A mapped file can be unlinked while mapped: the pages stay until unmapped.
        if wasDraggedOut {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.dragGrace, execute: remove)
        } else {
            remove()
        }
    }

    private init?(data: Data, fileURL: URL?, ownFolder: URL?) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else {
            if let fileURL = fileURL { try? FileManager.default.removeItem(at: fileURL) }
            if let ownFolder = ownFolder { try? FileManager.default.removeItem(at: ownFolder) }
            return nil
        }
        self.data = data
        self.fileURL = fileURL
        self.ownFolder = ownFolder
        self.source = source
        pixelSize = CGSize(width: width, height: height)
        // Retina captures are tagged 144 dpi; anything untagged is treated as 72 dpi.
        let dpi = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let scale = dpi > 0 ? dpi / 72 : 1
        pointSize = CGSize(width: width / scale, height: height / scale)
        suggestedFileName = fileURL.map { $0.deletingPathExtension().lastPathComponent + ".png" }
            ?? FileNaming.screenshotName() + ".png"
    }

    /// The image currently on the pasteboard, if any, stored in `directory`.
    /// A copied image file comes first: Finder puts the file's icon beside it, and the
    /// file's bytes are copied as they are rather than decoded into a bitmap.
    static func fromPasteboard(_ pasteboard: NSPasteboard, storingIn directory: URL) -> CapturedImage? {
        let imageFiles: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier]
        ]
        if let file = (pasteboard.readObjects(forClasses: [NSURL.self], options: imageFiles) as? [URL])?.first {
            guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return nil }
            return stored(data, in: directory)
        }
        guard let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
                ?? NSImage(pasteboard: pasteboard)?.tiffRepresentation else { return nil }
        return stored(data, in: directory)
    }

    /// Decodes a copy whose longer side is at most `maxPixel` pixels. Never upscales.
    func downsampled(maxPixel: CGFloat) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixel.rounded(.up)))
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The alpha value of every pixel of a small copy, top row first.
    private func smallAlphaMap() -> (alpha: [UInt8], width: Int, height: Int)? {
        guard let small = downsampled(maxPixel: 256) else { return nil }
        var pixels = [UInt8](repeating: 0, count: small.width * small.height * 4)
        guard let context = CGContext(data: &pixels, width: small.width, height: small.height,
                                      bitsPerComponent: 8, bytesPerRow: small.width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(small, in: CGRect(x: 0, y: 0, width: small.width, height: small.height))
        return (stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }, small.width, small.height)
    }

    /// Whether the picture is see-through at its corners, as a window capture is (rounded
    /// corners and a soft shadow around the window). A system window shadow around such
    /// a picture would trace a visible line along the faint edge of that shadow.
    var hasTransparentEdges: Bool {
        guard let map = smallAlphaMap() else { return false }
        let corners = [0, map.width - 1, (map.height - 1) * map.width, map.height * map.width - 1]
        return corners.contains { map.alpha[$0] < 250 }
    }

    /// The image at full size, decoded lazily by whoever draws it and not cached here,
    /// so the only decoded copy is the one the renderer keeps.
    func fullSizeUncached() -> CGImage? {
        CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    /// The capture as PNG bytes. PNG input is returned untouched.
    func pngData() -> Data? {
        if (CGImageSourceGetType(source) as String?) == UTType.png.identifier { return data }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, CGImageSourceCopyPropertiesAtIndex(source, 0, nil))
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    func copyToPasteboard() {
        guard let png = pngData() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
    }
}
