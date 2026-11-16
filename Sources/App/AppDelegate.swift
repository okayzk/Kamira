import AppKit

/// Starts the app and joins its features: the menu bar, the Quick Panel and the global
/// shortcuts start them, and each one's result is handed to the next with callbacks
/// (a screenshot to its preview, a preview to a pin or the editor, and so on). The
/// features themselves know nothing of each other.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenu!
    private var quickPanel: QuickPanel!
    private var hotKeys: HotKeys!
    /// The settings window, only while it is open.
    private var settingsWindow: SettingsWindowController?
    private var welcomeWindow: WelcomeWindowController?
    private var scrollCapture: ScrollCaptureSession?
    /// The message currently on screen, if any.
    private var toast: Toast?
    private let textReader = TextReader()
    private lazy var screenshots = ScreenshotTaker(directory: captureDirectory)
    private lazy var previews = PreviewStack(dragDirectory: dragDirectory)
    private let pins = PinBoard()
    private lazy var editors = EditorLauncher(directory: dragDirectory)
    private var regionSelector: RegionSelector?
    private lazy var recording = RecordingController(workDirectory: dragDirectory)

    /// Holds PNGs created when a preview is dragged out. Emptied at launch and quit.
    private let dragDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(AppInfo.name, isDirectory: true)
    /// Holds the image files behind screenshots that are still on screen as a preview or pin.
    private var captureDirectory: URL { dragDirectory.appendingPathComponent("captures", isDirectory: true) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        EditMenu.install()
        try? FileManager.default.removeItem(at: dragDirectory)
        statusMenu = StatusMenu()
        statusMenu.isVisible = !Settings.hideMenuBarIcon && !QuietMode.isOn
        statusMenu.onCommand = { [weak self] command in self?.perform(command) }
        statusMenu.onStopRecording = { [weak self] in self?.recording.stop() }
        quickPanel = QuickPanel()
        quickPanel.onAction = { [weak self] action in self?.perform(action) }
        hotKeys = HotKeys()
        hotKeys.onPress = { [weak self] action in self?.perform(action) }
        hotKeys.register()
        configureRecorder()
        if !QuietMode.isOn { Updater.start() }
        QuietMode.start()
        configureScreenshots()
        connectPreviewsPinsAndEditors()
        configureTextReader()
        textReader.warmUp()
        // The first start only. `--demo-welcome` shows it again; `--demo-welcome-pending`
        // as on a Mac where nothing is allowed or switched off yet.
        let demo = CommandLine.arguments.contains { $0.hasPrefix("--demo") }
        if (!Settings.welcomed && !demo) || CommandLine.arguments.contains("--demo-welcome") { showWelcome() }
        if CommandLine.arguments.contains("--demo-welcome-pending") { showWelcome(pending: true) }

        // Development aid: `--demo-preview`, `--demo-pin` or `--demo-edit`, each followed by
        // an image file, shows that piece of UI without taking a capture. Flags may repeat.
        let arguments = CommandLine.arguments
        if arguments.contains("--demo-palette") { togglePalette() }
        if arguments.contains("--demo-settings") { showSettings() }
        // `--demo-shortcuts` shows the shortcuts pane; `--demo-shortcut-guide` also opens
        // the note about the system's screenshot shortcuts.
        // `--demo-settings-screenshots`, `-recording`, `--demo-about`: the other panes.
        for (flag, pane) in [("--demo-settings-screenshots", SettingsWindowController.Pane.screenshots),
                             ("--demo-settings-recording", .recording), ("--demo-about", .about)]
        where arguments.contains(flag) {
            showSettings()
            settingsWindow?.show(pane)
        }
        if arguments.contains("--demo-shortcuts") || arguments.contains("--demo-shortcut-guide") {
            showSettings()
            settingsWindow?.show(.shortcuts)
            if arguments.contains("--demo-shortcut-guide") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.settingsWindow?.showGuide() }
            }
        }
        // `--demo-login-item` adds the app to the login items, takes it out again, prints
        // what the system answered each time, and quits.
        if arguments.contains("--demo-login-item") {
            for enabled in [true, false] {
                do { try Settings.setOpenAtLogin(enabled) } catch { print("demo-login-item: error:", error) }
                print("demo-login-item: asked for \(enabled), system says \(Settings.openAtLogin)")
            }
            exit(0)
        }
        if arguments.contains("--demo-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.statusMenu.open()
            }
        }
        // `--demo-record <seconds>` records the first display, or with `--screen <number>`
        // another one, or with `--region x,y,w,h` (global AppKit coordinates) that part of
        // the screen it lies on; prints the file and quits. `--gif` and `--mic` change the options.
        if let index = arguments.firstIndex(of: "--demo-record"), index + 1 < arguments.count,
           let seconds = TimeInterval(arguments[index + 1]), var screen = NSScreen.screens.first {
            var region: CGRect?
            if let at = arguments.firstIndex(of: "--region"), at + 1 < arguments.count {
                let n = arguments[at + 1].split(separator: ",").compactMap { Double($0) }
                if n.count == 4 { region = CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) }
            }
            if let region = region, let home = NSScreen.containing(region) { screen = home }
            if let at = arguments.firstIndex(of: "--screen"), at + 1 < arguments.count,
               let number = Int(arguments[at + 1]), NSScreen.screens.indices.contains(number) {
                screen = NSScreen.screens[number]
            }
            var options = RecordingOptions()
            options.gif = arguments.contains("--gif")
            options.microphone = arguments.contains("--mic")
            let recorder = recording.recorder
            recorder.options = options
            // Outside the app's own temporary folder, which is emptied on quit, and never
            // in the maintainer's save folder.
            recorder.workDirectory = FileManager.default.temporaryDirectory
            recorder.saveDirectory = FileManager.default.temporaryDirectory
            // Stops at the size set in Settings, as a real recording does.
            recorder.maxBytes = RecordingSize.bytes(gigabytes: Settings.maxRecordingGigabytes)
            recording.onFinished = { result in
                print("demo-record:", result)
                // Long enough for a message about a limit to be seen.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSApp.terminate(nil) }
            }
            if let region = region { recording.showFrame(around: region) }
            // `--window <number>` records that window instead.
            if let at = arguments.firstIndex(of: "--window"), at + 1 < arguments.count,
               let number = CGWindowID(arguments[at + 1]) {
                recorder.start(windowID: number)
            } else {
                recorder.start(region: region, on: screen)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.recording.stop()
            }
        }
        // `--demo-select` shows the region selector with a sample selection.
        if arguments.contains("--demo-select") {
            recordScreen()
            regionSelector?.showSample(CGRect(x: 300, y: 300, width: 640, height: 400))
        }
        // `--demo-unpin <seconds>` closes all pins after that long (for memory measurements).
        if let index = arguments.firstIndex(of: "--demo-unpin"), index + 1 < arguments.count,
           let seconds = TimeInterval(arguments[index + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.pins.closeAll() }
        }
        // `--demo-scroll <x,y,w,h>` starts a scrolling capture of that region (global
        // AppKit coordinates, on whichever screen) without the selector.
        if let index = arguments.firstIndex(of: "--demo-scroll"), index + 1 < arguments.count {
            let n = arguments[index + 1].split(separator: ",").compactMap { Double($0) }
            if n.count == 4 {
                let area = CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
                if let screen = NSScreen.containing(area) { startScrollCapture(area: area, screen: screen) }
            }
        }
        // `--demo-ocr <image>` recognises the text in an image file, as after a selection.
        if let index = arguments.firstIndex(of: "--demo-ocr"), index + 1 < arguments.count {
            textReader.read(URL(fileURLWithPath: arguments[index + 1]), removingFile: false)
        }
        // `--demo-recording <file>` shows the floating preview for an existing recording.
        if let index = arguments.firstIndex(of: "--demo-recording"), index + 1 < arguments.count {
            previews.showRecording(URL(fileURLWithPath: arguments[index + 1]), pointSize: CGSize(width: 800, height: 500))
        }
        for (index, flag) in arguments.enumerated().dropLast() where flag.hasPrefix("--demo-") {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: arguments[index + 1]), options: .alwaysMapped),
                  let capture = CapturedImage.stored(data, in: captureDirectory) else { continue }
            if flag == "--demo-preview" { previews.show(capture) }
            if flag == "--demo-pin" { pins.add(capture) }
            if flag == "--demo-edit" { editors.open(capture) }
            if ["--demo-draw", "--demo-copy", "--demo-move", "--demo-zoom"].contains(flag) { editors.open(capture, demo: flag) }
        }
    }

    /// The app was opened again while running (from Finder, Spotlight, the Dock…): the
    /// way back to the settings when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        editors.closeAll()
        previews.closeQuickLooks()
        scrollCapture?.cancel()
        try? FileManager.default.removeItem(at: dragDirectory)
    }

    // MARK: Settings

    /// Opens the settings window. While it is open the menu bar icon is shown even if
    /// the user chose to hide it, so that hiding it is never a dead end.
    private func showSettings() {
        if settingsWindow == nil {
            let controller = SettingsWindowController()
            controller.onChange = { [weak self] in self?.applySettings() }
            controller.onQuit = { [weak self] in self?.quit() }
            controller.onShowWelcome = { [weak self] in self?.showWelcome() }
            // A shortcut typed into the settings must not also start its action.
            controller.onRecordingShortcut = { [weak self] recording in
                if recording { self?.hotKeys.unregister() } else { self?.hotKeys.register() }
            }
            controller.onClose = { [weak self] in
                self?.settingsWindow = nil
                self?.applySettings()
            }
            settingsWindow = controller
        }
        statusMenu.isVisible = !QuietMode.isOn
        settingsWindow?.show()
    }

    private func showWelcome(pending: Bool = false) {
        if let welcomeWindow = welcomeWindow {
            welcomeWindow.show()
            return
        }
        let controller = WelcomeWindowController()
        controller.showsPending = pending
        let demo = CommandLine.arguments.contains { $0.hasPrefix("--demo-welcome") }
        controller.isDemo = demo
        controller.onChange = { [weak self] in self?.applySettings() }
        // A shortcut typed into the welcome window must not also start its action.
        controller.onRecordingShortcut = { [weak self] recording in
            if recording { self?.hotKeys.unregister() } else { self?.hotKeys.register() }
        }
        // A demo ends with its window, so that trying it leaves nothing behind.
        controller.onClose = { [weak self] in
            self?.welcomeWindow = nil
            if demo { NSApp.terminate(nil) }
        }
        welcomeWindow = controller
        controller.show()
    }

    /// Brings what is on screen in line with the settings.
    private func applySettings() {
        statusMenu.isVisible = (settingsWindow != nil || !Settings.hideMenuBarIcon) && !QuietMode.isOn
        previews.applySettings()
        pins.applySettings()
        hotKeys.register()
        statusMenu.showShortcuts()
    }

    // MARK: Starting things

    /// What a global shortcut, a menu item or a Quick Panel button starts: the same code
    /// whichever it was.
    private func perform(_ action: ShortcutAction) {
        switch action {
        case .area: captureRegion()
        case .window: captureWindow()
        case .screen: captureScreen()
        case .scrolling: captureScrolling()
        case .text: captureText()
        case .record: recordScreen()
        case .pin: pinClipboard()
        case .panel: togglePalette()
        }
    }

    private func perform(_ command: StatusMenu.Command) {
        switch command {
        case .action(let action): perform(action)
        case .annotateClipboard: annotateClipboard()
        case .closeAllPins: pins.closeAll()
        case .settings: showSettings()
        case .quit: quit()
        }
    }

    private func togglePalette() { quickPanel.toggle() }
    private func hidePalette() { quickPanel.hide() }

    // MARK: Capture

    private func captureRegion() {
        hidePalette()
        screenshots.captureRegion()
    }
    private func captureWindow() {
        hidePalette()
        screenshots.captureWindow()
    }
    private func captureScreen() {
        // While the recording selector is open the same shortcut means "the whole screen" there.
        if let selector = regionSelector {
            selector.selectFullScreen()
            return
        }
        hidePalette()
        screenshots.captureScreen()
    }

    private func configureScreenshots() {
        screenshots.onCaptured = { [weak self] capture in
            if Settings.previewEnabled { self?.previews.show(capture) }
        }
        screenshots.onError = { [weak self] message in self?.showError(message) }
    }

    /// Scrolling capture: choose a region, then scroll it by hand while a helper process
    /// photographs and stitches it; Done turns the result into an ordinary screenshot.
    private func captureScrolling() {
        hidePalette()
        guard scrollCapture == nil, regionSelector == nil, !recording.recorder.isBusy else { return }
        let selector = RegionSelector(purpose: .scrollingCapture) { [weak self] request in
            guard let self = self else { return }
            self.regionSelector = nil
            guard let request = request else { return }
            self.startScrollCapture(area: request.area, screen: request.screen)
        }
        regionSelector = selector
        selector.begin()
    }

    private func startScrollCapture(area: CGRect, screen: NSScreen) {
        let file = captureDirectory.appendingPathComponent("capture-\(UUID().uuidString).png")
        try? FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        let session = ScrollCaptureSession(area: area, screen: screen, output: file)
        session.onFinished = { [weak self] result in
            self?.scrollCapture = nil
            if let result = result { self?.screenshots.finish(result) }
        }
        scrollCapture = session
        session.start()
    }

    // MARK: Text recognition

    /// Select a region (or, with Space, a window) exactly as for a screenshot; the text
    /// in it goes to the clipboard. The picture itself is not kept.
    private func captureText() {
        hidePalette()
        screenshots.selectArea { [weak self] file in self?.textReader.read(file, removingFile: true) }
    }

    private func configureTextReader() {
        textReader.onPreparing = { [weak self] in
            self?.showToast(symbol: "text.viewfinder", message: L("ocr.preparing"))
        }
        textReader.onNothingFound = { [weak self] in
            self?.showToast(symbol: "text.viewfinder", message: L("ocr.noText"))
        }
        textReader.onCopied = { [weak self] text in
            // The toast shows the text itself, so a wrong reading is noticed at once.
            // VoiceOver reads only its start, about as much as the toast shows.
            let line = text.replacingOccurrences(of: "\n", with: " ")
            self?.showToast(symbol: "doc.on.clipboard", message: L("ocr.copied", line),
                            announcement: L("ocr.copied", line.count > 30 ? line.prefix(30) + "…" : line))
        }
        textReader.onError = { [weak self] message in self?.showError(message) }
    }

    private func showToast(symbol: String, message: String, announcement: String? = nil) {
        guard let screen = NSScreen.underPointer else { return }
        toast?.close()
        let new = Toast(symbol: symbol, message: message, announcement: announcement, on: screen)
        toast = new
        new.show(for: 2.5) { [weak self, weak new] in
            if self?.toast === new { self?.toast = nil }
        }
    }

    // MARK: Screen recording

    /// Shows the selector: drag a region (or keep the whole screen), set the options,
    /// then choose video or GIF. Nothing is recorded before that choice.
    private func recordScreen() {
        hidePalette()
        guard !recording.recorder.isBusy, regionSelector == nil, recording.countdown == nil else { return }
        let selector = RegionSelector { [weak self] request in
            guard let self = self else { return }
            self.regionSelector = nil
            guard let request = request else { return }
            self.recording.start(area: request.area, screen: request.screen, windowID: request.windowID,
                                 isFullScreen: request.isFullScreen, options: request.options,
                                 countdown: request.countdown)
        }
        regionSelector = selector
        selector.begin()
    }

    private func configureRecorder() {
        recording.onStateChange = { [weak self] in self?.updateRecordingIndicator() }
        recording.onLimitReached = { [weak self] limit in
            switch limit {
            case .size:
                self?.showToast(symbol: "stop.circle",
                                message: L("recording.stopped.size", Settings.maxRecordingGigabytes))
            case .disk:
                self?.showToast(symbol: "externaldrive.badge.exclamationmark", message: L("recording.stopped.disk"))
            }
        }
        recording.onFinished = { [weak self] result in
            switch result {
            case .success(let url):
                self?.previews.showRecording(url, pointSize: self?.recording.recorder.lastPointSize ?? .zero)
            case .failure(let error):
                QuietMode.activate()
                self?.showError(L("error.recording", error.localizedDescription))
            }
        }
    }

    /// While recording, the menu bar item shows the elapsed time and a click stops the
    /// recording instead of opening the menu.
    private func updateRecordingIndicator() {
        let recorder = recording.recorder
        statusMenu.show(recorder.isConverting ? .convertingToGIF
                        : recorder.isRecording ? .recording(since: recorder.startDate) : .idle)
    }

    // MARK: Previews, pins and the editor

    /// A preview's Pin and Annotate, a pin's Annotate and the editor's Pin hand the
    /// picture from one to the other.
    private func connectPreviewsPinsAndEditors() {
        previews.onPin = { [weak self] capture in self?.pins.add(capture) }
        previews.onAnnotate = { [weak self] capture in self?.editors.open(capture) }
        previews.convertToGIF = { video, gif, maxSide, done in
            ScreenRecorder.convertToGIF(video: video, gif: gif, maxSide: maxSide, completion: done)
        }
        pins.onAnnotate = { [weak self] capture in self?.editors.open(capture) }
        editors.onPin = { [weak self] capture in self?.pins.add(capture) }
        editors.onError = { [weak self] message in self?.showError(message) }
    }

    private func annotateClipboard() {
        guard let capture = CapturedImage.fromPasteboard(.general, storingIn: captureDirectory) else {
            showError(L("error.noClipboardImage.annotate"))
            return
        }
        editors.open(capture)
    }

    private func pinClipboard() {
        hidePalette()
        guard let capture = CapturedImage.fromPasteboard(.general, storingIn: captureDirectory) else {
            showError(L("error.noClipboardImage.pin"))
            return
        }
        pins.add(capture)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = AppInfo.name
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func quit() { NSApp.terminate(nil) }
}
