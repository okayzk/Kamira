import AppKit
import Vision

/// Reads the text in a picture with the system's own recogniser (Vision). Runs in a
/// helper process (`--ocr <image>`), never inside the menu bar app: the recogniser's
/// models take far more memory than the app is allowed to keep.
enum TextRecognizer {
    /// One piece of recognised text. `box` is normalised (0...1) with the origin at the
    /// bottom-left of the picture, as Vision reports it.
    struct Fragment {
        var text: String
        var box: CGRect
    }

    /// Puts fragments back into reading order: rows from top to bottom, and within a row
    /// from left to right, separated by a space. Fragments share a row when the middle
    /// of one lies within the height of the row's first fragment, so table cells and
    /// terminal columns on the same line come out as one line.
    static func assemble(_ fragments: [Fragment]) -> String {
        var rows: [[Fragment]] = []
        for fragment in fragments.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let first = rows.last?.first, fragment.box.midY > first.box.minY {
                rows[rows.count - 1].append(fragment)
            } else {
                rows.append([fragment])
            }
        }
        return rows.map { row in
            row.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ")
        }.joined(separator: "\n")
    }

    /// The text in the image file, or an empty string when there is none.
    static func recognize(imageAt url: URL) throws -> String {
        try recognize(with: VNImageRequestHandler(url: url))
    }

    /// The text in the picture, or an empty string when there is none.
    static func recognize(_ image: CGImage) throws -> String {
        try recognize(with: VNImageRequestHandler(cgImage: image))
    }

    private static func recognize(with handler: VNImageRequestHandler) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Let the system decide the language line by line. Measured on a screen of mixed
        // code and Chinese: a fixed list with Chinese first turns ASCII punctuation into
        // full-width forms, and English first drops the Chinese lines altogether.
        request.automaticallyDetectsLanguage = true
        // Screens are full of code, names and commands that a dictionary "corrects" into
        // wrong words ("assert" became "assent"), and loading it took 15 s in a new process.
        request.usesLanguageCorrection = false
        try handler.perform([request])
        return assemble((request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { Fragment(text: $0.string, box: observation.boundingBox) }
        })
    }

    // MARK: Warming up

    /// A line of English over a line of Chinese, black on white: what the warm-up reads.
    /// Both languages, so that every model a real reading needs gets prepared.
    static func warmUpPicture() -> CGImage {
        let size = NSSize(width: 900, height: 260)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 40),
                                                         .foregroundColor: NSColor.black]
        ("Hello Capture 2026" as NSString).draw(at: NSPoint(x: 40, y: 160), withAttributes: attributes)
        ("滚动长截图与文字识别" as NSString).draw(at: NSPoint(x: 40, y: 60), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.cgImage!
    }

    /// Entry point for the warm-up helper (`--ocr-warm-up`), started when the app starts.
    /// The app's first reading on a Mac waits 30 to 50 s while the system compiles the
    /// recogniser's models for it. The system keeps the result per app, macOS version and
    /// signature (`~/Library/Caches/<bundle id>/com.apple.e5rt.e5bundlecache/<macOS build>`),
    /// keeping one signature at a time: a new Mac, a macOS update, or switching between a
    /// development build and a release starts over; a new build with the same signature,
    /// even elsewhere on disk, does not. Reading a picture here pays that wait before the
    /// user asks; when nothing changed, it takes a quarter of a second.
    static func runWarmUp() -> Never {
        exit((try? recognize(warmUpPicture())) == nil ? 1 : 0)
    }

    /// Entry point for the helper process: prints the text to standard output; never returns.
    static func runHelper(image: String) -> Never {
        do {
            let text = try recognize(imageAt: URL(fileURLWithPath: image))
            FileHandle.standardOutput.write(Data(text.utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("ocr: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
