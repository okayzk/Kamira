import AppKit
import UniformTypeIdentifiers

/// Scrolling capture, helper side. Runs as its own process
/// (`--scroll-capture <x,y,w,h> <scale> <output.png>`, the rectangle in global points
/// measured from the top-left of the primary screen): it photographs the region several
/// times a second with the system's `screencapture` tool while the user scrolls,
/// stitches the frames, and writes one PNG when it receives SIGINT. SIGTERM cancels.
/// Progress goes to standard output, one word or "height <pixels>" per line.
/// With `--preview <x,y,w,h>` (AppKit screen coordinates) it also shows the picture so
/// far in that place: the pixels are in this process, so the window is too.
final class ScrollCaptureHelper {
    private let region: CGRect
    private let scale: CGFloat
    private let output: URL
    private let rawURL: URL
    private let frameURL: URL
    private let pixelWidth: Int
    private let pixelHeight: Int
    private let buffer: UnsafeMutableRawPointer
    private let context: CGContext
    private let stitcher: ScrollStitcher
    private let queue = DispatchQueue(label: "scroll-capture")
    private var stopping = false
    private var signals: [DispatchSourceSignal] = []
    private var lastReport = ""
    /// The live preview: its picture, touched only on `queue`, and its window.
    private var strip: ScrollPreviewStrip?
    private var preview: ScrollPreviewWindow?
    private var previewChanged = false

    static func run(arguments: [String]) -> Never {
        let numbers = arguments[0].split(separator: ",").compactMap { Double($0) }
        guard numbers.count == 4, arguments.count >= 3, let scale = Double(arguments[1]),
              let helper = ScrollCaptureHelper(
                region: CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]),
                scale: CGFloat(scale), output: URL(fileURLWithPath: arguments[2])) else {
            FileHandle.standardError.write(Data("scroll capture: bad arguments\n".utf8))
            exit(2)
        }
        if let index = arguments.firstIndex(of: "--preview"), index + 1 < arguments.count {
            let n = arguments[index + 1].split(separator: ",").compactMap { Double($0) }
            if n.count == 4 {
                // A window needs an application; it never becomes active or shows in the Dock.
                let app = NSApplication.shared
                app.setActivationPolicy(.accessory)
                helper.showPreview(in: CGRect(x: n[0], y: n[1], width: n[2], height: n[3]))
                helper.start()
                app.run()
                exit(0)
            }
        }
        helper.start()
        dispatchMain()
    }

    /// Sets up the preview window and the narrow picture it shows, fed by the stitcher.
    private func showPreview(in room: CGRect) {
        guard let strip = ScrollPreviewStrip(sourceWidth: pixelWidth, width: Int(room.width * scale),
                                             height: Int(room.height * scale)) else { return }
        self.strip = strip
        preview = ScrollPreviewWindow(room: room)
        stitcher.onRowsAdded = { [weak self] pixels, rows in
            strip.append(pixels, rows: rows)
            self?.previewChanged = true
        }
        stitcher.onRowsRemoved = { [weak self] rows in
            strip.removeLast(rows: rows)
            self?.previewChanged = true
        }
    }

    private init?(region: CGRect, scale: CGFloat, output: URL) {
        self.region = region
        self.scale = scale
        self.output = output
        rawURL = output.appendingPathExtension("raw")
        frameURL = output.appendingPathExtension("frame.tiff")
        pixelWidth = Int(region.width * scale)
        pixelHeight = Int(region.height * scale)
        guard pixelWidth > 0, pixelHeight > 0,
              let stitcher = ScrollStitcher(width: pixelWidth, height: pixelHeight, outputURL: rawURL) else { return nil }
        self.stitcher = stitcher
        buffer = UnsafeMutableRawPointer.allocate(byteCount: pixelWidth * pixelHeight * 4, alignment: 16)
        guard let context = CGContext(data: buffer, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                      bytesPerRow: pixelWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        self.context = context
    }

    private func start() {
        for (number, finishing) in [(SIGINT, true), (SIGTERM, false)] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self = self else { return }
                if finishing { self.stopping = true } else { self.cancel() }
            }
            source.resume()
            signals.append(source)
        }
        queue.async { self.captureNext() }
    }

    /// One frame: the system tool photographs the region into a scratch file, which is
    /// drawn into the pixel buffer and handed to the stitcher.
    private func captureNext() {
        if stopping { finish() }
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        tool.arguments = ["-x", "-t", "tiff", "-R",
                          "\(region.minX),\(region.minY),\(region.width),\(region.height)", frameURL.path]
        do { try tool.run() } catch { fail("cannot run screencapture: \(error)") }
        tool.waitUntilExit()
        guard let source = CGImageSourceCreateWithURL(frameURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            fail("screencapture produced no picture")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        let outcome = stitcher.add(UnsafeRawBufferPointer(start: buffer, count: pixelWidth * pixelHeight * 4))
        report(outcome == .lost ? "lost" : "height \(stitcher.totalRows)")
        if previewChanged, let image = strip?.image() {
            previewChanged = false
            DispatchQueue.main.async { [preview, scale] in preview?.show(image, scale: scale) }
        }
        queue.async { self.captureNext() }
    }

    private func report(_ line: String) {
        guard line != lastReport else { return }
        lastReport = line
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    /// Turns the raw rows into a PNG tagged with the screen's resolution, then exits.
    private func finish() -> Never {
        let rows = stitcher.finish()
        guard rows > 0, let raw = try? Data(contentsOf: rawURL, options: .alwaysMapped),
              let provider = CGDataProvider(data: raw as CFData),
              let image = CGImage(width: pixelWidth, height: rows, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: pixelWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString,
                                                                1, nil) else {
            fail("could not build the picture")
        }
        let dpi = 72 * Double(scale)
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: dpi,
                                                        kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { fail("could not write the picture") }
        cleanUp()
        exit(0)
    }

    private func cancel() -> Never {
        _ = stitcher.finish()
        cleanUp()
        exit(1)
    }

    private func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("scroll capture: \(message)\n".utf8))
        _ = stitcher.finish()
        cleanUp()
        exit(3)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: rawURL)
        try? FileManager.default.removeItem(at: frameURL)
    }
}
