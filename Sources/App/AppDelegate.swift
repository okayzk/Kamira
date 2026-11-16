import AppKit
import Carbon.HIToolbox

/// Button whose icon and label subviews never take the click away from the button itself.
private final class PaletteButton: NSButton {
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }
}

/// Menu bar item, global shortcut, All-in-One palette, and the capture → preview → pin flow.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let maxPreviews = 5

    private var statusItem: NSStatusItem!
    private var palette: NSPanel?
    /// Oldest first. On screen the newest is frontmost, with older ones tucked behind it
    /// until the pointer is over the stack.
    private var previews: [PreviewOverlay] = []
    private var previewsExpanded = false
    /// The screen the preview stack stands on.
    private var previewScreen: NSScreen?
    /// Runs only while the pointer is over the preview stack.
    private var hoverTimer: Timer?
    private var pins: [PinnedImageWindow] = []
    /// Running annotation editors; each is its own process, see `EditorProcessDelegate`.
    private var editors: [Process] = []
    /// Running Quick Look helpers, one per recording being looked at.
    private var quickLooks: [Process] = []
    private var hotKeys: [EventHotKeyRef?] = []
    /// The menu items that show an action's global shortcut.
    private var shortcutItems: [ShortcutAction: NSMenuItem] = [:]
    /// The system screenshot tool while it is waiting for the user to select something.
    private var interactiveCapture: Process?
    private var hotKeyHandler: EventHandlerRef?
    /// The settings window, only while it is open.
    private var settingsWindow: SettingsWindowController?
    private var welcomeWindow: WelcomeWindowController?
    private var countdown: CountdownWindow?
    private var scrollCapture: ScrollCaptureSession?
    /// The message currently on screen, if any.
    private var toast: Toast?
    /// The helper that prepares text recognition at launch; see `TextRecognizer.runWarmUp`.
    private var textRecognitionWarmUp: Process?
    private var regionSelector: RegionSelector?
    /// Outline around the region being recorded.
    private var recordingFrame: RecordingFrameWindow?
    private var statusMenu: NSMenu?
    /// Hides the desktop icons for as long as a recording runs.
    private var recordingCover: DesktopCoverSession?
    private let recorder = ScreenRecorder()
    /// Updates the elapsed time in the menu bar while recording.
    private var recordingTimer: Timer?

    /// Holds PNGs created when a preview is dragged out. Emptied at launch and quit.
    private let dragDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(AppInfo.name, isDirectory: true)
    /// Holds the image files behind screenshots that are still on screen as a preview or pin.
    private var captureDirectory: URL { dragDirectory.appendingPathComponent("captures", isDirectory: true) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        EditMenu.install()
        try? FileManager.default.removeItem(at: dragDirectory)
        makeStatusMenu()
        makePalette()
        installHotKeyHandler()
        registerHotKeys()
        recorder.workDirectory = dragDirectory
        configureRecorder()
        if !QuietMode.isOn { Updater.start() }
        QuietMode.start()
        warmUpTextRecognition()
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
                self?.statusItem.button?.performClick(nil)
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
            recorder.options = options
            // Outside the app's own temporary folder, which is emptied on quit, and never
            // in the maintainer's save folder.
            recorder.workDirectory = FileManager.default.temporaryDirectory
            recorder.saveDirectory = FileManager.default.temporaryDirectory
            // Stops at the size set in Settings, as a real recording does.
            recorder.maxBytes = RecordingSize.bytes(gigabytes: Settings.maxRecordingGigabytes)
            recorder.onFinished = { result in
                print("demo-record:", result)
                // Long enough for a message about a limit to be seen.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSApp.terminate(nil) }
            }
            if let region = region { showRecordingFrame(region) }
            // `--window <number>` records that window instead.
            if let at = arguments.firstIndex(of: "--window"), at + 1 < arguments.count,
               let number = CGWindowID(arguments[at + 1]) {
                recorder.start(windowID: number)
            } else {
                recorder.start(region: region, on: screen)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.recorder.stop()
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
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.closeAllPins() }
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
            recognizeText(in: URL(fileURLWithPath: arguments[index + 1]), removingFile: false)
        }
        // `--demo-recording <file>` shows the floating preview for an existing recording.
        if let index = arguments.firstIndex(of: "--demo-recording"), index + 1 < arguments.count {
            showRecordingPreview(URL(fileURLWithPath: arguments[index + 1]), pointSize: CGSize(width: 800, height: 500))
        }
        for (index, flag) in arguments.enumerated().dropLast() where flag.hasPrefix("--demo-") {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: arguments[index + 1]), options: .alwaysMapped),
                  let capture = CapturedImage.stored(data, in: captureDirectory) else { continue }
            if flag == "--demo-preview" { showPreview(capture) }
            if flag == "--demo-pin" { addPin(capture) }
            if flag == "--demo-edit" { openEditor(capture) }
            if ["--demo-draw", "--demo-copy", "--demo-move", "--demo-zoom"].contains(flag) { openEditor(capture, demo: flag) }
        }
    }

    /// The app was opened again while running (from Finder, Spotlight, the Dock…): the
    /// way back to the settings when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        editors.forEach { $0.terminate() }
        quickLooks.forEach { $0.terminate() }
        scrollCapture?.cancel()
        try? FileManager.default.removeItem(at: dragDirectory)
    }

    // MARK: Menu and palette

    private func makeStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = StatusIcon.image
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let menu = NSMenu()
        shortcutItems[.area] = add(menu, L("menu.captureArea"), #selector(captureRegion))
        shortcutItems[.window] = add(menu, L("menu.captureWindow"), #selector(captureWindow))
        shortcutItems[.screen] = add(menu, L("menu.captureScreen"), #selector(captureScreen))
        shortcutItems[.scrolling] = add(menu, L("menu.scrollingCapture"), #selector(captureScrolling))
        shortcutItems[.text] = add(menu, L("menu.recognizeText"), #selector(captureText))
        menu.addItem(.separator())
        shortcutItems[.record] = add(menu, L("menu.recordScreen"), #selector(recordScreen))
        menu.addItem(.separator())
        shortcutItems[.pin] = add(menu, L("menu.pinClipboard"), #selector(pinClipboard))
        add(menu, L("menu.annotateClipboard"), #selector(annotateClipboard))
        add(menu, L("menu.closeAllPins"), #selector(closeAllPins))
        menu.addItem(.separator())
        shortcutItems[.panel] = add(menu, L("menu.quickPanel"), #selector(togglePalette))

        add(menu, L("menu.settings"), #selector(showSettings)).keyEquivalent = ","
        add(menu, L("menu.quit", AppInfo.name), #selector(quit)).keyEquivalent = "q"
        statusItem.menu = menu
        statusMenu = menu
        statusItem.isVisible = !Settings.hideMenuBarIcon && !QuietMode.isOn
        showShortcutsInMenu()
    }

    /// The menu shows each action's global shortcut, the one registered in `registerHotKeys()`.
    private func showShortcutsInMenu() {
        let table = Settings.shortcuts
        for (action, item) in shortcutItems {
            item.keyEquivalent = table[action]?.menuKey ?? ""
            item.keyEquivalentModifierMask = table[action]?.menuModifiers ?? []
        }
    }

    // MARK: Settings

    /// Opens the settings window. While it is open the menu bar icon is shown even if
    /// the user chose to hide it, so that hiding it is never a dead end.
    @objc private func showSettings() {
        if settingsWindow == nil {
            let controller = SettingsWindowController()
            controller.onChange = { [weak self] in self?.applySettings() }
            controller.onQuit = { [weak self] in self?.quit() }
            controller.onShowWelcome = { [weak self] in self?.showWelcome() }
            // A shortcut typed into the settings must not also start its action.
            controller.onRecordingShortcut = { [weak self] recording in
                if recording { self?.unregisterHotKeys() } else { self?.registerHotKeys() }
            }
            controller.onClose = { [weak self] in
                self?.settingsWindow = nil
                self?.applySettings()
            }
            settingsWindow = controller
        }
        statusItem.isVisible = !QuietMode.isOn
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
            if recording { self?.unregisterHotKeys() } else { self?.registerHotKeys() }
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
        statusItem.isVisible = (settingsWindow != nil || !Settings.hideMenuBarIcon) && !QuietMode.isOn
        // A preview that was switched off goes away; a recording is in the save folder already.
        for overlay in previews where !(overlay.isRecording ? Settings.recordingPreviewEnabled : Settings.previewEnabled) {
            overlay.close()
        }
        previews.removeAll { !$0.isVisible }
        previews.forEach { $0.autoCloseDelay = closeDelay(recording: $0.isRecording) }
        pins.forEach { $0.hoverFade = Settings.fadePinsOnHover }
        registerHotKeys()
        showShortcutsInMenu()
    }

    /// How long a preview stays by itself; nil keeps it until it is closed.
    private func closeDelay(recording: Bool) -> TimeInterval? {
        let seconds = recording ? Settings.recordingPreviewCloseAfter : Settings.previewCloseAfter
        return seconds > 0 ? TimeInterval(seconds) : nil
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    /// The All-in-One palette: a floating Liquid Glass bar with one button per action.
    private func makePalette() {
        let row = NSStackView(views: [
            paletteButton(L("palette.area"), id: "palette.area", symbol: "rectangle.dashed", action: #selector(captureRegion)),
            paletteButton(L("palette.window"), id: "palette.window", symbol: "macwindow", action: #selector(captureWindow)),
            paletteButton(L("palette.screen"), id: "palette.screen", symbol: "display", action: #selector(captureScreen)),
            paletteButton(L("palette.scrolling"), id: "palette.scrolling", symbol: "arrow.up.and.down", action: #selector(captureScrolling)),
            paletteButton(L("palette.text"), id: "palette.text", symbol: "text.viewfinder", action: #selector(captureText)),
            paletteButton(L("palette.record"), id: "palette.record", symbol: "record.circle", action: #selector(recordScreen)),
            paletteButton(L("palette.pin"), id: "palette.pin", symbol: "pin", action: #selector(pinClipboard)),
            paletteButton(L("palette.close"), id: "palette.close", symbol: "xmark", action: #selector(hidePalette))
        ])
        row.orientation = .horizontal
        row.spacing = 4
        row.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)

        let size = row.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        // Hidden at once, without the system's fade: a selection that starts right after
        // would otherwise still find the panel under the pointer and offer it as a window.
        panel.animationBehavior = .none
        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
        glass.cornerRadius = 24
        glass.contentView = row
        panel.contentView = glass
        panel.center()
        panel.setAccessibilityIdentifier("palette")
        palette = panel
    }

    private func paletteButton(_ title: String, id: String, symbol: String, action: Selector) -> NSButton {
        // NSButton's own image-above-title layout pins the image to the top edge, so the
        // icon and label are laid out by a centred stack inside an empty button instead.
        let button = PaletteButton(title: "", target: self, action: action)
        button.isBordered = false
        button.setAccessibilityLabel(title)
        button.setAccessibilityIdentifier(id)
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))
        icon.contentTintColor = .labelColor
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .labelColor
        let column = NSStackView(views: [icon, label])
        column.orientation = .vertical
        column.spacing = 5
        column.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            column.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            icon.heightAnchor.constraint(equalToConstant: 26),
            button.widthAnchor.constraint(equalToConstant: 68),
            button.heightAnchor.constraint(equalToConstant: 60)
        ])
        return button
    }

    /// Hears the global shortcuts registered in `registerHotKeys()`.
    private func installHotKeyHandler() {
        var kind = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData = userData, let event = event else { return OSStatus(-9874) }
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let app = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            let which = pressed.id
            DispatchQueue.main.async {
                if let action = ShortcutAction.allCases.first(where: { $0.hotKeyID == which }) { app.perform(action) }
            }
            return noErr
        }, 1, &kind, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
    }

    /// Registers the shortcuts the settings hold, in place of those registered before.
    /// One the system uses for itself registers without error and then never arrives;
    /// the settings mark those (`Shortcut.isTaken`).
    private func registerHotKeys() {
        unregisterHotKeys()
        // A test copy must not take the shortcuts from the copy in use.
        guard !QuietMode.isOn else { return }
        for (action, shortcut) in Settings.shortcuts {
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: OSType(0x43455054), id: action.hotKeyID) // 'CEPT'
            let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, identifier,
                                             GetApplicationEventTarget(), 0, &reference)
            if result != noErr {
                NSLog("%@: shortcut %@ could not be registered (%d).", AppInfo.name, shortcut.display, result)
            }
            hotKeys.append(reference)
        }
    }

    private func unregisterHotKeys() {
        hotKeys.compactMap { $0 }.forEach { UnregisterEventHotKey($0) }
        hotKeys.removeAll()
    }

    /// What a global shortcut starts: the same code as the menu and the Quick Panel.
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

    @objc func togglePalette() {
        guard let panel = palette else { return }
        if panel.isVisible { panel.orderOut(nil) }
        else {
            // In the middle of the screen the pointer is on, a little above the centre as `center()` does.
            if let visible = NSScreen.underPointer?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2,
                                             y: visible.minY + (visible.height - panel.frame.height) * 2 / 3))
            }
            panel.orderFrontRegardless()
        }
    }
    @objc private func hidePalette() { palette?.orderOut(nil) }

    // MARK: Capture

    // Both interactive modes are the system's own: Space switches between dragging a
    // region and picking a window, in either direction.
    @objc private func captureRegion() { captureInteractively(["-i", "-x"]) }
    @objc private func captureWindow() { captureInteractively(["-i", "-W", "-x"]) }

    /// A region or window screenshot with the window shadow the user chose. The system
    /// tool can only draw its own wide shadow or none (`-o`); the sizes in between are
    /// added afterwards by a helper process, which leaves anything but a window capture alone.
    private func captureInteractively(_ arguments: [String]) {
        let level = Settings.windowShadowLevel
        capture(arguments + (level == WindowShadow.systemLevel ? [] : ["-o"]), interactive: true) { [weak self] file in
            guard level > 0, level < WindowShadow.systemLevel, FileManager.default.fileExists(atPath: file.path) else {
                self?.captureFinished(file)
                return
            }
            let helper = Process()
            helper.executableURL = Bundle.main.executableURL
            helper.arguments = ["--window-shadow", file.path, String(level)]
            helper.terminationHandler = { _ in DispatchQueue.main.async { self?.captureFinished(file) } }
            // Without the helper the capture is still good, only without a shadow.
            do { try helper.run() } catch { self?.captureFinished(file) }
        }
    }
    /// Captures the whole screen at once. If a region or window selection is in
    /// progress, this replaces it, so the shortcut also works from inside a selection.
    @objc func captureScreen() {
        // While the recording selector is open the same shortcut means "the whole screen" there.
        if let selector = regionSelector {
            selector.selectFullScreen()
            return
        }
        interactiveCapture?.terminate()
        interactiveCapture = nil
        capture(["-x"], interactive: false)
    }

    /// Runs the system screenshot tool. It writes the picture to a temporary file, which
    /// is handed to `completion`; by default it becomes a screenshot (mapped, never read
    /// into allocated memory, and copied to the clipboard). No file means it was cancelled.
    private func capture(_ arguments: [String], interactive: Bool, hidingDesktopIcons: Bool = true,
                         completion: ((URL) -> Void)? = nil) {
        hidePalette()
        // One selection at a time.
        if interactive, interactiveCapture?.isRunning == true { return }
        let file = captureDirectory.appendingPathComponent("capture-\(UUID().uuidString).png")
        try? FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments + ["-t", "png", file.path]
        // With that setting on, the icons are covered first and shown again afterwards.
        let cover = hidingDesktopIcons && Settings.hideDesktopIcons ? DesktopCoverSession() : nil
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                cover?.stop()
                if self?.interactiveCapture === finished { self?.interactiveCapture = nil }
                if let completion = completion { completion(file) } else { self?.captureFinished(file) }
            }
        }
        if interactive { interactiveCapture = process }
        let run = { [weak self] in
            do { try process.run() } catch {
                cover?.stop()
                self?.showError(L("error.screenshotTool", error.localizedDescription))
            }
        }
        // Give AppKit one event-loop turn to remove the palette before capture begins.
        DispatchQueue.main.async {
            if let cover = cover { cover.start(then: run) } else { run() }
        }
    }

    /// Scrolling capture: choose a region, then scroll it by hand while a helper process
    /// photographs and stitches it; Done turns the result into an ordinary screenshot.
    @objc private func captureScrolling() {
        hidePalette()
        guard scrollCapture == nil, regionSelector == nil, !recorder.isBusy else { return }
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
            if let result = result { self?.captureFinished(result) }
        }
        scrollCapture = session
        session.start()
    }

    private func captureFinished(_ file: URL) {
        // No file means the user cancelled the selection.
        guard FileManager.default.fileExists(atPath: file.path),
              let capture = CapturedImage(owningFile: file) else { return }
        if Settings.copyAfterCapture { capture.copyToPasteboard() }
        if Settings.saveAfterCapture { save(capture) }
        if Settings.previewEnabled { showPreview(capture) }
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
            showError(L("error.save", error.localizedDescription))
        }
    }

    // MARK: Text recognition

    /// Select a region (or, with Space, a window) exactly as for a screenshot; the text
    /// in it goes to the clipboard. The picture itself is not kept.
    @objc private func captureText() {
        capture(["-i", "-x"], interactive: true, hidingDesktopIcons: false) { [weak self] file in
            guard FileManager.default.fileExists(atPath: file.path) else { return }
            self?.recognizeText(in: file, removingFile: true)
        }
    }

    /// Starts the warm-up helper, which reads one drawn picture so that the user's first
    /// reading does not wait for the system to prepare its models.
    private func warmUpTextRecognition() {
        let helper = Process()
        helper.executableURL = Bundle.main.executableURL
        helper.arguments = ["--ocr-warm-up"]
        guard (try? helper.run()) != nil else { return }
        textRecognitionWarmUp = helper
    }

    /// Recognises the text in a helper process (see `TextRecognizer`), copies it and
    /// says so in a toast.
    private func recognizeText(in file: URL, removingFile: Bool) {
        // While the warm-up still prepares the models, a second reader would prepare them
        // again alongside it and finish later than the warm-up does (52 s against 42 s,
        // measured): wait for it instead, and say why nothing happens yet.
        if let warmUp = textRecognitionWarmUp, warmUp.isRunning {
            showToast(symbol: "text.viewfinder", message: L("ocr.preparing"))
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                warmUp.waitUntilExit()
                DispatchQueue.main.async { self?.recognizeText(in: file, removingFile: removingFile) }
            }
            return
        }
        let helper = Process()
        let pipe = Pipe()
        helper.executableURL = Bundle.main.executableURL
        helper.arguments = ["--ocr", file.path]
        helper.standardOutput = pipe
        do { try helper.run() } catch {
            if removingFile { try? FileManager.default.removeItem(at: file) }
            showError(L("error.textRecognition", error.localizedDescription))
            return
        }
        // Read while the helper runs: a long text would otherwise fill the pipe and stall it.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            helper.waitUntilExit()
            if removingFile { try? FileManager.default.removeItem(at: file) }
            let text = helper.terminationStatus == 0 ? String(data: data, encoding: .utf8) ?? "" : ""
            DispatchQueue.main.async {
                guard !text.isEmpty else {
                    self?.showToast(symbol: "text.viewfinder", message: L("ocr.noText"))
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                // The toast shows the text itself, so a wrong reading is noticed at once.
                // VoiceOver reads only its start, about as much as the toast shows.
                let line = text.replacingOccurrences(of: "\n", with: " ")
                self?.showToast(symbol: "doc.on.clipboard", message: L("ocr.copied", line),
                                announcement: L("ocr.copied", line.count > 30 ? line.prefix(30) + "…" : line))
            }
        }
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
    @objc private func recordScreen() {
        hidePalette()
        guard !recorder.isBusy, regionSelector == nil, countdown == nil else { return }
        let selector = RegionSelector { [weak self] request in
            guard let self = self else { return }
            self.regionSelector = nil
            guard let request = request else { return }
            self.recorder.options = request.options
            self.recorder.saveDirectory = Settings.saveDirectory
            self.recorder.maxBytes = RecordingSize.bytes(gigabytes: Settings.maxRecordingGigabytes)
            let record = { [weak self] in
                guard let self = self else { return }
                if let window = request.windowID {
                    self.recorder.start(windowID: window)
                } else if request.isFullScreen {
                    self.recorder.start(region: nil, on: request.screen)
                } else {
                    self.showRecordingFrame(request.area)
                    self.recorder.start(region: request.area, on: request.screen)
                }
            }
            let start = { [weak self] in
                guard let self = self else { return }
                self.countdown = nil
                // A recording of one window has no desktop in it.
                guard Settings.hideDesktopIcons, request.windowID == nil else { record(); return }
                let cover = DesktopCoverSession()
                self.recordingCover = cover
                cover.start(then: record)
            }
            guard request.countdown else { start(); return }
            let window = CountdownWindow(centredIn: request.area)
            self.countdown = window
            window.run(completion: start)
        }
        regionSelector = selector
        selector.begin()
    }

    private func showRecordingFrame(_ rect: CGRect) {
        recordingFrame?.close()
        recordingFrame = RecordingFrameWindow(around: rect)
        recordingFrame?.orderFrontRegardless()
    }

    @objc private func stopRecording() { recorder.stop() }

    private func configureRecorder() {
        recorder.onStateChange = { [weak self] in self?.updateRecordingIndicator() }
        recorder.onLimitReached = { [weak self] limit in
            switch limit {
            case .size:
                self?.showToast(symbol: "stop.circle",
                                message: L("recording.stopped.size", Settings.maxRecordingGigabytes))
            case .disk:
                self?.showToast(symbol: "externaldrive.badge.exclamationmark", message: L("recording.stopped.disk"))
            }
        }
        recorder.onFinished = { [weak self] result in
            switch result {
            case .success(let url):
                self?.showRecordingPreview(url, pointSize: self?.recorder.lastPointSize ?? .zero)
            case .failure(let error):
                QuietMode.activate()
                self?.showError(L("error.recording", error.localizedDescription))
            }
        }
    }

    /// While recording, the menu bar item shows the elapsed time and a click stops the
    /// recording instead of opening the menu.
    private func updateRecordingIndicator() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        guard let button = statusItem.button else { return }
        if !recorder.isRecording {
            recordingFrame?.close()
            recordingFrame = nil
            recordingCover?.stop()
            recordingCover = nil
        }
        if recorder.isConverting {
            // Nothing to click while the GIF is being written.
            statusItem.menu = nil
            button.action = nil
            button.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: L("gif.creating"))
            button.title = " GIF"
            button.toolTip = L("gif.creating")
        } else if recorder.isRecording {
            statusItem.menu = nil
            button.target = self
            button.action = #selector(stopRecording)
            // A red dot and the time, not a second stop button: the system already puts its
            // own stop control in the menu bar. Clicking this one stops the recording too.
            button.image = NSImage(systemSymbolName: "circle.fill",
                                   accessibilityDescription: L("recording.inProgress"))?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .regular)
                    .applying(.init(paletteColors: [.systemRed])))
            button.toolTip = L("recording.clickToStop")
            updateRecordingTime()
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.updateRecordingTime()
            }
        } else {
            button.action = nil
            statusItem.menu = statusMenu
            button.image = StatusIcon.image
            button.toolTip = nil
            button.title = ""
        }
    }

    private func updateRecordingTime() {
        let seconds = recorder.startDate.map { Int(Date().timeIntervalSince($0)) } ?? 0
        statusItem.button?.title = String(format: " %d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: Floating previews

    private func showPreview(_ capture: CapturedImage) {
        let overlay = PreviewOverlay(capture: capture)
        overlay.dragDirectory = dragDirectory
        overlay.autoCloseDelay = closeDelay(recording: false)
        overlay.onPin = { [weak self] capture in self?.addPin(capture) }
        overlay.onAnnotate = { [weak self] capture in self?.openEditor(capture) }
        present(overlay)
    }

    /// Preview for a finished recording. The file is in the save folder already, written
    /// there as it was recorded; closing the preview, by hand or by itself, leaves it there.
    private func showRecordingPreview(_ url: URL, pointSize: CGSize) {
        guard Settings.recordingPreviewEnabled else { return }
        let side = Int(min(1600, max(pointSize.width, pointSize.height)))
        let overlay = PreviewOverlay(recording: url, gifMaxSide: side)
        overlay.autoCloseDelay = closeDelay(recording: true)
        overlay.onQuickLook = { [weak self] file in self?.openQuickLook(file) }
        overlay.convertToGIF = { video, gif, maxSide, done in
            ScreenRecorder.convertToGIF(video: video, gif: gif, maxSide: maxSide, completion: done)
        }
        present(overlay)
    }

    /// Shows a recording in the system's Quick Look, in a helper process (see
    /// `QuickLookProcessDelegate`).
    private func openQuickLook(_ file: URL) {
        let helper = Process()
        helper.executableURL = Bundle.main.executableURL
        helper.arguments = ["--quicklook", file.path] + QuietMode.arguments
        helper.terminationHandler = { [weak self] process in
            DispatchQueue.main.async { self?.quickLooks.removeAll { $0 === process } }
        }
        do {
            try helper.run()
            quickLooks.append(helper)
        } catch {
            NSSound.beep()
        }
    }

    private func present(_ overlay: PreviewOverlay) {
        overlay.onDismiss = { [weak self] overlay in self?.removePreview(overlay) }
        overlay.onPointerActivity = { [weak self] in self?.updatePreviewHover() }
        previews.append(overlay)
        // The stack stands on the screen the pointer is on when a capture arrives.
        previewScreen = NSScreen.underPointer
        if previews.count > Self.maxPreviews {
            previews.removeFirst().close()
        }
        layoutPreviews()
        overlay.alphaValue = 0
        overlay.orderFrontRegardless()
        overlay.animator().alphaValue = 1
    }

    private func removePreview(_ overlay: PreviewOverlay) {
        overlay.close()
        previews.removeAll { $0 === overlay }
        layoutPreviews()
        updatePreviewHover()
    }

    /// Works out from the pointer position which overlay is hovered, and expands the stack
    /// while the pointer is over it. Overlays overlap when collapsed and move when the
    /// stack expands, so this is re-checked on a short timer until the pointer leaves.
    private func updatePreviewHover() {
        let pointer = NSEvent.mouseLocation
        // Collapsed overlays overlap; the newest is frontmost and wins.
        let hovered = previews.last { $0.frame.contains(pointer) }
        previews.forEach { $0.setHovering($0 === hovered) }
        // The margin keeps the stack open while crossing the gap between two overlays.
        let overStack = previews.contains { $0.frame.insetBy(dx: -8, dy: -8).contains(pointer) }
        if overStack {
            if !previewsExpanded {
                previewsExpanded = true
                layoutPreviews()
            }
            if hoverTimer == nil {
                hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    self?.updatePreviewHover()
                }
            }
        } else {
            hoverTimer?.invalidate()
            hoverTimer = nil
            if previewsExpanded {
                previewsExpanded = false
                layoutPreviews()
            }
        }
    }

    /// Places the overlays in the bottom-left corner, newest lowest. Expanded, they form a
    /// column; collapsed, older ones peek out narrower above the newest like a deck of cards.
    private func layoutPreviews() {
        let visible = previewScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = PreviewOverlay.cardSize
        let base = NSPoint(x: visible.minX + 18, y: visible.minY + 18)
        for (index, overlay) in previews.reversed().enumerated() {
            let depth = CGFloat(index)
            let frame = previewsExpanded
                ? NSRect(x: base.x, y: base.y + depth * (size.height + 10),
                         width: size.width, height: size.height)
                : NSRect(x: base.x + depth * 7, y: base.y + depth * 8,
                         width: size.width - depth * 14, height: size.height)
            if overlay.isVisible {
                overlay.animator().setFrame(frame, display: true)
            } else {
                overlay.setFrame(frame, display: false)
            }
        }
    }

    // MARK: Annotation

    @objc private func annotateClipboard() {
        guard let capture = CapturedImage.fromPasteboard(.general, storingIn: captureDirectory) else {
            showError(L("error.noClipboardImage.annotate"))
            return
        }
        openEditor(capture)
    }

    /// Opens the annotation editor in a helper process, so that the memory editing
    /// needs is fully returned when the editor closes. A pinned result comes back as a file.
    private func openEditor(_ capture: CapturedImage, demo: String? = nil) {
        let id = UUID().uuidString
        let imageURL = dragDirectory.appendingPathComponent("edit-\(id).png")
        let pinURL = dragDirectory.appendingPathComponent("pin-\(id).png")
        let helper = Process()
        helper.executableURL = Bundle.main.executableURL
        helper.arguments = ["--editor", imageURL.path, pinURL.path] + (demo.map { [$0] } ?? []) + QuietMode.arguments
        helper.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.editors.removeAll { $0 === process }
                // The capture takes the file over and deletes it when the pin closes.
                if FileManager.default.fileExists(atPath: pinURL.path),
                   let result = CapturedImage(owningFile: pinURL) {
                    self.addPin(result)
                }
                try? FileManager.default.removeItem(at: imageURL)
            }
        }
        do {
            try FileManager.default.createDirectory(at: dragDirectory, withIntermediateDirectories: true)
            try capture.data.write(to: imageURL, options: .atomic)
            try helper.run()
            editors.append(helper)
        } catch {
            showError(L("error.editor", error.localizedDescription))
        }
    }

    // MARK: Pins

    @objc private func pinClipboard() {
        hidePalette()
        guard let capture = CapturedImage.fromPasteboard(.general, storingIn: captureDirectory) else {
            showError(L("error.noClipboardImage.pin"))
            return
        }
        addPin(capture)
    }

    private func addPin(_ capture: CapturedImage) {
        let pin = PinnedImageWindow(capture: capture, offset: CGFloat(pins.count % 5) * 22)
        pin.hoverFade = Settings.fadePinsOnHover
        pin.onRemove = { [weak self] window in
            window.close()
            self?.pins.removeAll { $0 === window }
        }
        pin.onAnnotate = { [weak self] window in
            self?.openEditor(window.capture)
            window.close()
            self?.pins.removeAll { $0 === window }
        }
        pins.append(pin)
        pin.orderFrontRegardless()
    }

    @objc private func closeAllPins() {
        pins.forEach { $0.close() }
        pins.removeAll()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = AppInfo.name
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
