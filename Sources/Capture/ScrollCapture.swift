import AppKit
import ImageIO
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

/// The live preview of a scrolling capture: the picture so far at a narrow width, beside
/// the region. It grows downwards from the region's top edge until it is as tall as the
/// region, then shows the newest part. Only to look at: clicks pass through it, and it
/// is excluded from captures.
private final class ScrollPreviewWindow: NSPanel {
    private let room: CGRect

    init(room: CGRect) {
        self.room = room
        super.init(contentRect: room, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        // Development aid: `--demo-show-capture-ui` lets screenshots see this window.
        sharingType = CommandLine.arguments.contains("--demo-show-capture-ui") ? .readOnly : .none
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSView(frame: NSRect(origin: .zero, size: room.size))
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 0.5
        view.layer?.borderColor = NSColor.separatorColor.cgColor
        view.layer?.contentsGravity = .resize
        contentView = view
    }

    /// `image` is in pixels, `scale` of them to a point.
    func show(_ image: CGImage, scale: CGFloat) {
        let height = min(room.height, CGFloat(image.height) / scale)
        setFrame(NSRect(x: room.minX, y: room.maxY - height, width: room.width, height: height), display: false)
        contentView?.layer?.contents = image
        if !isVisible { orderFrontRegardless() }
    }
}

/// Scrolling capture, menu bar side: starts the helper for a region, shows an outline
/// and a small control panel next to it, and hands back the finished picture.
final class ScrollCaptureSession {
    /// Called on the main thread with the stitched PNG, or nil if cancelled or failed.
    var onFinished: ((URL?) -> Void)?

    private let helper = Process()
    private let output: URL
    private let frame: RecordingFrameWindow
    private let panel: ScrollControlPanel

    /// `area` is in global AppKit coordinates on `screen`.
    init(area: CGRect, screen: NSScreen, output: URL) {
        self.output = output
        frame = RecordingFrameWindow(around: area)
        panel = ScrollControlPanel(beside: area, on: screen)
        // `screencapture -R` measures from the top-left corner of the primary screen.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let local = CGRect(x: area.minX, y: primaryHeight - area.maxY, width: area.width, height: area.height)
        helper.executableURL = Bundle.main.executableURL
        helper.arguments = ["--scroll-capture",
                            "\(local.minX),\(local.minY),\(local.width),\(local.height)",
                            String(Double(screen.backingScaleFactor)), output.path]
        // The live preview stands beside the region when the screen has room for it.
        if let room = ScrollPreviewLayout.frame(beside: area, in: screen.visibleFrame) {
            helper.arguments? += ["--preview", "\(room.minX),\(room.minY),\(room.width),\(room.height)"]
        }
        if CommandLine.arguments.contains("--demo-show-capture-ui") { helper.arguments?.append("--demo-show-capture-ui") }
    }

    func start() {
        let pipe = Pipe()
        helper.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let text = String(data: handle.availableData, encoding: .utf8),
                  let line = text.split(separator: "\n").last else { return }
            DispatchQueue.main.async { self?.panel.show(progress: String(line)) }
        }
        helper.terminationHandler = { [weak self] process in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.frame.close()
                self.panel.close()
                let made = process.terminationStatus == 0 && FileManager.default.fileExists(atPath: self.output.path)
                self.onFinished?(made ? self.output : nil)
            }
        }
        panel.onDone = { [weak self] in self?.helper.interrupt() }
        panel.onCancel = { [weak self] in self?.helper.terminate() }
        do {
            try helper.run()
            frame.orderFrontRegardless()
            panel.orderFrontRegardless()
        } catch {
            onFinished?(nil)
        }
    }

    /// Ends the capture without keeping anything, e.g. when the app quits.
    func cancel() {
        if helper.isRunning { helper.terminate() }
    }
}

/// Small glass panel shown beside the region during a scrolling capture: what to do,
/// how tall the picture is so far, and Done / Cancel. It is excluded from captures.
private final class ScrollControlPanel: NSPanel {
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?
    private let label = NSTextField(labelWithString: L("scroll.start"))

    init(beside area: CGRect, on screen: NSScreen) {
        let size = NSSize(width: 250, height: 44)
        // Below the region if there is room, otherwise above it, otherwise inside its bottom edge.
        let visible = screen.visibleFrame
        var origin = NSPoint(x: area.midX - size.width / 2, y: area.minY - size.height - 10)
        if origin.y < visible.minY + 4 { origin.y = area.maxY + 10 }
        if origin.y + size.height > visible.maxY - 4 { origin.y = area.minY + 10 }
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        super.init(contentRect: NSRect(origin: origin, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // Development aid: `--demo-show-capture-ui` lets screenshots see this panel.
        sharingType = CommandLine.arguments.contains("--demo-show-capture-ui") ? .readOnly : .none
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let cancel = button("xmark", L("action.cancel"), #selector(cancelClicked))
        let done = button("checkmark", L("action.done"), #selector(doneClicked))
        done.contentTintColor = .controlAccentColor
        let row = NSStackView(views: [label, cancel, done])
        row.orientation = .horizontal
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 8)
        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
        glass.cornerRadius = size.height / 2
        glass.contentView = row
        contentView = glass
    }

    private func button(_ symbol: String, _ title: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold)) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .labelColor
        button.toolTip = title
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    /// `progress` is a line from the helper: "lost" or "height <pixels>".
    func show(progress: String) {
        if progress == "lost" {
            label.stringValue = L("scroll.tooFast")
        } else if progress.hasPrefix("height "), let pixels = Int(progress.dropFirst(7)) {
            label.stringValue = L("scroll.progress", pixels)
        }
    }

    @objc private func doneClicked() { onDone?() }
    @objc private func cancelClicked() { onCancel?() }
}
