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
        // The welcome window on the first start, but never unasked in a demo run.
        if !Settings.welcomed && !Demo.isAny(CommandLine.arguments) { showWelcome() }
        Demo.parse(CommandLine.arguments).forEach(run)
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
        guard scrollCapture == nil, regionSelector == nil, !recording.isBusy else { return }
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
        guard !recording.isBusy, regionSelector == nil, recording.countdown == nil else { return }
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
                self?.previews.showRecording(url, pointSize: self?.recording.lastPointSize ?? .zero)
            case .failure(let error):
                QuietMode.activate()
                self?.showError(L("error.recording", error.localizedDescription))
            }
        }
    }

    /// While recording, the menu bar item shows the elapsed time and a click stops the
    /// recording instead of opening the menu.
    private func updateRecordingIndicator() {
        statusMenu.show(recording.isConverting ? .convertingToGIF
                        : recording.isRecording ? .recording(since: recording.startDate) : .idle)
    }

    // MARK: Previews, pins and the editor

    /// A preview's Pin and Annotate, a pin's Annotate and the editor's Pin hand the
    /// picture from one to the other.
    private func connectPreviewsPinsAndEditors() {
        previews.onPin = { [weak self] capture in self?.pins.add(capture) }
        previews.onAnnotate = { [weak self] capture in self?.editors.open(capture) }
        previews.convertToGIF = { video, gif, maxSide, done in
            RecordingController.convertToGIF(video: video, gif: gif, maxSide: maxSide, completion: done)
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

    // MARK: Demo modes

    /// Does what a `--demo-…` argument asks for; reading the arguments is `Demo.parse`.
    private func run(_ demo: Demo) {
        switch demo {
        case .welcome(let pending):
            showWelcome(pending: pending)
        case .palette:
            togglePalette()
        case .settings(let pane):
            showSettings()
            switch pane {
            case .screenshots?: settingsWindow?.show(.screenshots)
            case .recording?: settingsWindow?.show(.recording)
            case .shortcuts?: settingsWindow?.show(.shortcuts)
            case .about?: settingsWindow?.show(.about)
            case nil: break
            }
        case .shortcutGuide:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.settingsWindow?.showGuide() }
        case .loginItem:
            for enabled in [true, false] {
                do { try Settings.setOpenAtLogin(enabled) } catch { print("demo-login-item: error:", error) }
                print("demo-login-item: asked for \(enabled), system says \(Settings.openAtLogin)")
            }
            exit(0)
        case .menu:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.statusMenu.open() }
        case let .record(seconds, region, number, window, gif, microphone):
            guard var screen = NSScreen.screens.first else { return }
            if let region = region, let home = NSScreen.containing(region) { screen = home }
            if let number = number, NSScreen.screens.indices.contains(number) { screen = NSScreen.screens[number] }
            var options = RecordingOptions()
            options.gif = gif
            options.microphone = microphone
            recording.onFinished = { result in
                print("demo-record:", result)
                // Long enough for a message about a limit to be seen.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSApp.terminate(nil) }
            }
            // Outside the app's own temporary folder, which is emptied on quit, and never
            // in the maintainer's save folder.
            recording.startDemo(region: region, on: screen, windowID: window, options: options,
                                directory: FileManager.default.temporaryDirectory)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.recording.stop() }
        case .select:
            recordScreen()
            regionSelector?.showSample(CGRect(x: 300, y: 300, width: 640, height: 400))
        case .unpin(let seconds):
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.pins.closeAll() }
        case .scroll(let area):
            if let screen = NSScreen.containing(area) { startScrollCapture(area: area, screen: screen) }
        case .recognizeText(let file):
            textReader.read(file, removingFile: false)
        case .recording(let file):
            previews.showRecording(file, pointSize: CGSize(width: 800, height: 500))
        case .preview(let file):
            if let capture = demoCapture(file) { previews.show(capture) }
        case .pin(let file):
            if let capture = demoCapture(file) { pins.add(capture) }
        case let .edit(file, mode):
            if let capture = demoCapture(file) { editors.open(capture, demo: mode) }
        }
    }

    /// A picture file as a screenshot, for the demos that show one.
    private func demoCapture(_ file: URL) -> CapturedImage? {
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return nil }
        return CapturedImage.stored(data, in: captureDirectory)
    }
}
