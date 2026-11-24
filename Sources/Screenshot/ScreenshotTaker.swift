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
    /// While several screenshots are being taken (`captureSeveral`), the pictures so far.
    private var several: [URL]?
    /// Keeps the desktop icons covered for the whole of `captureSeveral`, not shot by shot.
    private var severalCover: DesktopCoverSession?
    /// Set when the Capture Screen shortcut ends a selection of `captureSeveral`: the
    /// screen becomes the next picture instead of the end.
    private var severalTakesScreen = false

    init(directory: URL) {
        self.directory = directory
    }

    // Both interactive modes are the system's own: Space switches between dragging a
    // region and picking a window, in either direction. While several screenshots are
    // being taken, the next selection is theirs.
    func captureRegion() { if several == nil { captureInteractively(["-i", "-x"]) } }
    func captureWindow() { if several == nil { captureInteractively(["-i", "-W", "-x"]) } }

    /// Several screenshots in a row, combined into one. The system's selection comes back
    /// as soon as a picture is taken, until Esc; then the pictures are laid side by side
    /// (`Collage`) and the result is an ordinary screenshot. One picture stays as it is.
    func captureSeveral() {
        guard several == nil, interactiveCapture?.isRunning != true else { return }
        several = []
        let cover = Settings.hideDesktopIcons ? DesktopCoverSession() : nil
        severalCover = cover
        if let cover = cover {
            cover.start { [weak self] in self?.captureNextOfSeveral() }
        } else {
            captureNextOfSeveral()
        }
    }

    private func captureNextOfSeveral() {
        captureInteractively(["-i", "-x"], hidingDesktopIcons: false) { [weak self] file in
            guard let self = self else { return }
            if FileManager.default.fileExists(atPath: file.path) {
                self.several?.append(file)
                self.captureNextOfSeveral()
            } else if self.severalTakesScreen {
                self.severalTakesScreen = false
                self.capture(["-x"], interactive: false, hidingDesktopIcons: false) { [weak self] screen in
                    if FileManager.default.fileExists(atPath: screen.path) { self?.several?.append(screen) }
                    self?.captureNextOfSeveral()
                }
            } else {
                // Esc: the pictures so far become one screenshot.
                let pictures = self.several ?? []
                self.several = nil
                self.severalCover?.stop()
                self.severalCover = nil
                self.combine(pictures)
            }
        }
    }

    /// Combines the picture files into one in a helper process and hands that to `done`,
    /// by default to become a screenshot; one picture is handed on as it is. The pictures
    /// go along as the parts of the whole, which the editor lays out again. The demo of
    /// several screenshots comes in here with files of its own.
    func combine(_ pictures: [URL], then done: ((URL, [CapturedImage.Part]) -> Void)? = nil) {
        let done = done ?? { [weak self] file, parts in self?.finish(file, parts: parts) }
        guard pictures.count > 1 else {
            if let picture = pictures.first { done(picture, []) }
            return
        }
        let failed = { [weak self] in
            pictures.forEach { try? FileManager.default.removeItem(at: $0) }
            self?.onError?(L("error.combine"))
        }
        guard let frames = Collage.layout(of: pictures) else { return failed() }
        let parts = zip(pictures, frames).map { CapturedImage.Part(file: $0, frame: $1) }
        let output = directory.appendingPathComponent("capture-\(UUID().uuidString).png")
        let helper = Process()
        helper.executableURL = Bundle.main.executableURL
        helper.arguments = ["--combine", output.path, Collage.argument(for: Settings.combinedBackground)]
            + pictures.map(\.path)
        helper.terminationHandler = { finished in
            DispatchQueue.main.async {
                if finished.terminationStatus == 0 { done(output, parts) } else { failed() }
            }
        }
        do { try helper.run() } catch { failed() }
    }

    /// Captures the whole screen at once. If a region or window selection is in
    /// progress, this replaces it, so the shortcut also works from inside a selection;
    /// while taking several, the screen is the next of them.
    func captureScreen() {
        if several != nil {
            guard interactiveCapture?.isRunning == true else { return }
            severalTakesScreen = true
            interactiveCapture?.terminate()
            return
        }
        interactiveCapture?.terminate()
        interactiveCapture = nil
        capture(["-x"], interactive: false)
    }

    /// Lets the user select a region or window as for a screenshot, and hands the
    /// picture's file over instead of making a screenshot of it. The desktop icons stay.
    func selectArea(then completion: @escaping (URL) -> Void) {
        guard several == nil else { return }
        capture(["-i", "-x"], interactive: true, hidingDesktopIcons: false) { file in
            guard FileManager.default.fileExists(atPath: file.path) else { return }
            completion(file)
        }
    }

    /// Makes a screenshot of a picture taken another way (a scrolling capture), or of
    /// several combined, with the pictures it was made of.
    func finish(_ file: URL, parts: [CapturedImage.Part] = []) {
        // No file means the user cancelled the selection.
        guard FileManager.default.fileExists(atPath: file.path),
              let capture = CapturedImage(owningFile: file, parts: parts) else { return }
        if Settings.copyAfterCapture { capture.copyToPasteboard() }
        if Settings.saveAfterCapture { save(capture) }
        onCaptured?(capture)
    }

    /// A region or window screenshot with the window shadow the user chose. The system
    /// tool can only draw its own wide shadow or none (`-o`); the sizes in between are
    /// added afterwards by a helper process, which leaves anything but a window capture alone.
    /// The picture's file goes to `done`, by default to become a screenshot.
    private func captureInteractively(_ arguments: [String], hidingDesktopIcons: Bool = true,
                                      then done: ((URL) -> Void)? = nil) {
        let level = Settings.windowShadowLevel
        let done = done ?? { [weak self] file in self?.finish(file) }
        capture(arguments + (level == WindowShadowLevel.system ? [] : ["-o"]), interactive: true,
                hidingDesktopIcons: hidingDesktopIcons) { file in
            guard level > 0, level < WindowShadowLevel.system, FileManager.default.fileExists(atPath: file.path) else {
                done(file)
                return
            }
            let helper = Process()
            helper.executableURL = Bundle.main.executableURL
            helper.arguments = ["--window-shadow", file.path, String(level)]
            helper.terminationHandler = { _ in DispatchQueue.main.async { done(file) } }
            // Without the helper the capture is still good, only without a shadow.
            do { try helper.run() } catch { done(file) }
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
