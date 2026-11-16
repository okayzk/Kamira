import AppKit

/// Takes screenshots with the system's own tool (`screencapture`), adds the window
/// shadow the user chose, and copies or saves the result as the settings say. What
/// becomes of a finished screenshot after that is the app's to decide (`onCaptured`).
final class ScreenshotTaker {
    /// A finished screenshot, already copied and saved as the settings say.
    var onCaptured: ((CapturedImage) -> Void)?
    /// A message for the user.
    var onError: ((String) -> Void)?

    /// Where the pictures are written; each is deleted when its screenshot goes.
    private let directory: URL
    /// The system screenshot tool while it is waiting for the user to select something.
    private var interactiveCapture: Process?

    init(directory: URL) {
        self.directory = directory
    }

    // Both interactive modes are the system's own: Space switches between dragging a
    // region and picking a window, in either direction.
    func captureRegion() { captureInteractively(["-i", "-x"]) }
    func captureWindow() { captureInteractively(["-i", "-W", "-x"]) }

    /// Captures the whole screen at once. If a region or window selection is in
    /// progress, this replaces it, so the shortcut also works from inside a selection.
    func captureScreen() {
        interactiveCapture?.terminate()
        interactiveCapture = nil
        capture(["-x"], interactive: false)
    }

    /// Lets the user select a region or window as for a screenshot, and hands the
    /// picture's file over instead of making a screenshot of it. The desktop icons stay.
    func selectArea(then completion: @escaping (URL) -> Void) {
        capture(["-i", "-x"], interactive: true, hidingDesktopIcons: false) { file in
            guard FileManager.default.fileExists(atPath: file.path) else { return }
            completion(file)
        }
    }

    /// Makes a screenshot of a picture taken another way (a scrolling capture).
    func finish(_ file: URL) {
        // No file means the user cancelled the selection.
        guard FileManager.default.fileExists(atPath: file.path),
              let capture = CapturedImage(owningFile: file) else { return }
        if Settings.copyAfterCapture { capture.copyToPasteboard() }
        if Settings.saveAfterCapture { save(capture) }
        onCaptured?(capture)
    }

    /// A region or window screenshot with the window shadow the user chose. The system
    /// tool can only draw its own wide shadow or none (`-o`); the sizes in between are
    /// added afterwards by a helper process, which leaves anything but a window capture alone.
    private func captureInteractively(_ arguments: [String]) {
        let level = Settings.windowShadowLevel
        capture(arguments + (level == WindowShadowLevel.system ? [] : ["-o"]), interactive: true) { [weak self] file in
            guard level > 0, level < WindowShadowLevel.system, FileManager.default.fileExists(atPath: file.path) else {
                self?.finish(file)
                return
            }
            let helper = Process()
            helper.executableURL = Bundle.main.executableURL
            helper.arguments = ["--window-shadow", file.path, String(level)]
            helper.terminationHandler = { _ in DispatchQueue.main.async { self?.finish(file) } }
            // Without the helper the capture is still good, only without a shadow.
            do { try helper.run() } catch { self?.finish(file) }
        }
    }

    /// Runs the system screenshot tool. It writes the picture to a temporary file, which
    /// is handed to `completion`; by default it becomes a screenshot (mapped, never read
    /// into allocated memory, and copied to the clipboard). No file means it was cancelled.
    private func capture(_ arguments: [String], interactive: Bool, hidingDesktopIcons: Bool = true,
                         completion: ((URL) -> Void)? = nil) {
        // One selection at a time.
        if interactive, interactiveCapture?.isRunning == true { return }
        let file = directory.appendingPathComponent("capture-\(UUID().uuidString).png")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments + ["-t", "png", file.path]
        // With that setting on, the icons are covered first and shown again afterwards.
        let cover = hidingDesktopIcons && Settings.hideDesktopIcons ? DesktopCoverSession() : nil
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                cover?.stop()
                if self?.interactiveCapture === finished { self?.interactiveCapture = nil }
                if let completion = completion { completion(file) } else { self?.finish(file) }
            }
        }
        if interactive { interactiveCapture = process }
        let run = { [weak self] in
            do { try process.run() } catch {
                cover?.stop()
                self?.onError?(L("error.screenshotTool", error.localizedDescription))
            }
        }
        // Give AppKit one event-loop turn to take away what the app has just hidden (the
        // Quick Panel) before the capture begins.
        DispatchQueue.main.async {
            if let cover = cover { cover.start(then: run) } else { run() }
        }
    }

    /// Writes a screenshot into the save folder under its own name, without asking.
    private func save(_ capture: CapturedImage) {
        let directory = Settings.saveDirectory
        let name = (capture.suggestedFileName as NSString).deletingPathExtension
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let data = capture.pngData() else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: FileNaming.available(name, extension: "png", in: directory), options: .atomic)
        } catch {
            onError?(L("error.save", error.localizedDescription))
        }
    }
}
