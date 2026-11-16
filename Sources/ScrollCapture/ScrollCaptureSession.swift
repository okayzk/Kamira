import AppKit
import ImageIO
import UniformTypeIdentifiers

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
