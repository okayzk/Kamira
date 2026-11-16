import AppKit
import ServiceManagement

/// The settings window, in the system's form: panes chosen in the tool bar, each a group
/// of rows with the name on the left and the control on the right. Created when asked
/// for and released when closed.
final class SettingsWindowController: SettingsSurface, NSWindowDelegate, NSTextFieldDelegate {
    enum Pane: Int { case general, screenshots, recording, shortcuts, about }

    var onClose: (() -> Void)?
    var onQuit: (() -> Void)?
    var onShowWelcome: (() -> Void)?
    /// Called with true while a shortcut is being typed into a recorder.
    var onRecordingShortcut: ((Bool) -> Void)?

    private let window: NSWindow
    private let tabs = SettingsTabs()
    /// What to do when the text of a file name field changes.
    private var nameEdits: [ObjectIdentifier: () -> Void] = [:]
    private var nameRestores: [ObjectIdentifier: () -> Void] = [:]
    /// Each action's recorder and the warning beside it.
    private var recorders: [ShortcutAction: (recorder: ShortcutRecorder, warning: NSImageView)] = [:]
    private let guideButton = NSButton()

    override init() {
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.setAccessibilityIdentifier("settings")
        window.delegate = self
        window.toolbarStyle = .preference

        tabs.tabStyle = .toolbar
        addPane(generalPane(), title: L("settings.general"), symbol: "gearshape")
        addPane(screenshotsPane(), title: L("settings.screenshots"), symbol: "camera.viewfinder")
        addPane(recordingPane(), title: L("settings.recording"), symbol: "record.circle")
        addPane(shortcutsPane(), title: L("settings.shortcuts"), symbol: "keyboard")
        addPane(aboutPane(), title: L("settings.about"), symbol: "info.circle")
        window.contentViewController = tabs
        refreshShortcuts()
    }

    private func addPane(_ view: NSView, title: String, symbol: String) {
        let controller = NSViewController()
        controller.view = view
        controller.title = title
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        tabs.addTabViewItem(item)
    }

    // MARK: Panes

    private func generalPane() -> NSView {
        // The system's own control for a folder: it shows the folder and offers to choose another.
        let folder = NSPathControl()
        folder.pathStyle = .popUp
        folder.url = Settings.saveDirectory
        folder.allowedTypes = ["public.folder"]
        // As wide as the folder's name, not as the row has room.
        folder.setContentHuggingPriority(.required, for: .horizontal)
        bind(folder) { [weak folder] in
            if let url = folder?.url { Settings.saveDirectory = url }
        }

        // The one way to quit when the menu bar icon is hidden.
        let quit = NSButton(title: "", target: self, action: #selector(quitClicked))
        quit.setAccessibilityIdentifier("settings.quit")
        quit.bezelStyle = .rounded
        quit.attributedTitle = NSAttributedString(string: L("menu.quit", AppInfo.name), attributes: [
            .foregroundColor: NSColor.systemRed, .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
        ])

        return pane([
            group([
                row(L("settings.openAtLogin"), id: "settings.openAtLogin", control: loginSwitch()),
                row(L("settings.hideIcon"), hint: L("settings.hideIconHint"), id: "settings.hideMenuBarIcon",
                    control: toggle(Settings.hideMenuBarIcon) { Settings.hideMenuBarIcon = $0 })
            ]),
            group([
                row(L("settings.saveLocation"), hint: L("settings.saveLocation.hint"), id: "settings.saveLocation",
                    control: folder),
                row(L("settings.hideDesktopIcons"), id: "settings.hideDesktopIcons",
                    control: toggle(Settings.hideDesktopIcons) { Settings.hideDesktopIcons = $0 }),
                row(L("settings.fadePins"), id: "settings.fadePins", control: toggle(Settings.fadePinsOnHover) { Settings.fadePinsOnHover = $0 })
            ]),
            updateGroup { [weak self] in self?.tabs.resizeSelectedPane() },
            quit
        ])
    }

    @objc private func quitClicked() { onQuit?() }

    private func screenshotsPane() -> NSView {
        // From none to the system's own in five steps; the slider stops only on those.
        let shadow = NSSlider(value: Double(Settings.windowShadowLevel), minValue: 0,
                              maxValue: Double(WindowShadow.systemLevel), target: nil, action: nil)
        shadow.numberOfTickMarks = WindowShadow.systemLevel + 1
        shadow.allowsTickMarkValuesOnly = true
        shadow.widthAnchor.constraint(equalToConstant: 140).isActive = true
        shadow.setAccessibilityIdentifier("settings.windowShadow")
        bind(shadow) { [weak shadow] in Settings.windowShadowLevel = Int((shadow?.doubleValue ?? 1).rounded()) }
        let shadowRow = NSStackView(views: [caption(L("settings.shadow.none")), shadow, caption(L("settings.shadow.max"))])
        shadowRow.spacing = 8

        return pane([
            group([
                row(L("settings.copyAfterCapture"), id: "settings.copyAfterCapture",
                    control: toggle(Settings.copyAfterCapture) { Settings.copyAfterCapture = $0 }),
                row(L("settings.saveAfterCapture"), id: "settings.saveAfterCapture",
                    control: toggle(Settings.saveAfterCapture) { Settings.saveAfterCapture = $0 }),
                nameRow(format: Settings.screenshotNameFormat, extension: "png", fallback: FileNaming.screenshotDefault,
                        id: "settings.screenshotName") {
                    Settings.screenshotNameFormat = $0
                }
            ]),
            group([
                row(L("settings.showPreview"), id: "settings.screenshotPreview",
                    control: toggle(Settings.previewEnabled) { Settings.previewEnabled = $0 }),
                row(L("settings.closePreview"), id: "settings.screenshotPreviewCloseAfter",
                    control: timeChoice(Settings.previewCloseAfter) { Settings.previewCloseAfter = $0 })
            ]),
            group([row(L("settings.windowShadow"), control: shadowRow)])
        ])
    }

    private func recordingPane() -> NSView {
        pane([
            group([
                nameRow(format: Settings.recordingNameFormat, extension: "mp4", fallback: FileNaming.recordingDefault,
                        id: "settings.recordingName") {
                    Settings.recordingNameFormat = $0
                },
                sizeRow()
            ]),
            group([
                row(L("settings.showPreview"), id: "settings.recordingPreview",
                    control: toggle(Settings.recordingPreviewEnabled) { Settings.recordingPreviewEnabled = $0 }),
                row(L("settings.closePreview"), id: "settings.recordingPreviewCloseAfter",
                    control: timeChoice(Settings.recordingPreviewCloseAfter) { Settings.recordingPreviewCloseAfter = $0 })
            ])
        ])
    }

    /// Never, or after one of a few numbers of seconds.
    private func timeChoice(_ current: Int, set: @escaping (Int) -> Void) -> NSPopUpButton {
        let choices = PreviewTiming.choices(including: current)
        let menu = NSPopUpButton(frame: .zero, pullsDown: false)
        menu.addItems(withTitles: choices.map { $0 == 0 ? L("settings.closePreview.never") : L("settings.closePreview.seconds", $0) })
        menu.selectItem(at: choices.firstIndex(of: current) ?? 0)
        bind(menu) { [weak menu] in
            guard let index = menu?.indexOfSelectedItem, choices.indices.contains(index) else { return }
            set(choices[index])
        }
        return menu
    }

    /// The pattern files are named by, with the name it gives right now underneath.
    private func nameRow(format: String, extension ext: String, fallback: String, id: String,
                         set: @escaping (String) -> Void) -> NSView {
        let field = NSTextField(string: format)
        field.setAccessibilityIdentifier(id)
        field.placeholderString = fallback
        field.toolTip = L("settings.fileName.hint")
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.widthAnchor.constraint(equalToConstant: 236).isActive = true
        let example = caption("")
        example.lineBreakMode = .byTruncatingMiddle
        let show = { [weak field, weak example] in
            example?.stringValue = FileNaming.name(format: field?.stringValue ?? "", date: Date(), fallback: fallback) + "." + ext
        }
        show()
        // Kept as it is typed: a window that closes does not end the editing first.
        nameEdits[ObjectIdentifier(field)] = { [weak field] in
            set(field?.stringValue ?? "")
            show()
        }
        field.delegate = self
        // Back to the name the app would give by itself.
        let restore = NSButton(image: NSImage(systemSymbolName: "arrow.counterclockwise",
                                              accessibilityDescription: L("settings.fileName.restore")) ?? NSImage(),
                               target: self, action: #selector(restoreName(_:)))
        restore.isBordered = false
        restore.contentTintColor = .secondaryLabelColor
        restore.toolTip = L("settings.fileName.restore")
        restore.setAccessibilityIdentifier(id + ".restore")
        nameRestores[ObjectIdentifier(restore)] = { [weak self, weak field] in
            guard let field = field else { return }
            field.stringValue = fallback
            self?.nameEdits[ObjectIdentifier(field)]?()
        }
        let line = NSStackView(views: [restore, field])
        line.spacing = 6
        let column = NSStackView(views: [line, example])
        column.orientation = .vertical
        column.alignment = .trailing
        column.spacing = 3
        return row(L("settings.fileName"), control: column)
    }

    /// The size a recording stops at, with how long that lasts on the main screen under
    /// it, kept up to date as it is typed.
    private func sizeRow() -> NSView {
        let field = NSTextField(string: String(Settings.maxRecordingGigabytes))
        field.setAccessibilityIdentifier("settings.maxRecordingSize")
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.alignment = .right
        field.toolTip = L("settings.maxRecordingSize.tooltip")
        field.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let unit = caption(L("settings.unit.gigabytes"))
        let lasts = caption("")
        let screen = NSScreen.main ?? NSScreen.screens.first
        let pixels = (screen?.frame.width ?? 1440) * (screen?.frame.height ?? 900) * pow(screen?.backingScaleFactor ?? 2, 2)
        let show = { [weak lasts] (gigabytes: Int) in
            let span = RecordingSize.minutes(gigabytes: gigabytes, pixels: Double(pixels))
            lasts?.stringValue = L("settings.maxRecordingSize.lasts", Self.duration(span.shortest), Self.duration(span.longest))
        }
        show(Settings.maxRecordingGigabytes)
        nameEdits[ObjectIdentifier(field)] = { [weak field] in
            guard let typed = Int(field?.stringValue.trimmingCharacters(in: .whitespaces) ?? "") else { return }
            Settings.maxRecordingGigabytes = typed
            show(Settings.maxRecordingGigabytes)
        }
        field.delegate = self
        let line = NSStackView(views: [field, unit])
        line.spacing = 4
        let column = NSStackView(views: [line, lasts])
        column.orientation = .vertical
        column.alignment = .trailing
        column.spacing = 3
        return row(L("settings.maxRecordingSize"), hint: L("settings.maxRecordingSize.hint"), control: column)
    }

    /// Minutes below two hours, hours to one decimal above.
    private static func duration(_ minutes: Int) -> String {
        if minutes < 120 { return L("settings.duration.minutes", minutes) }
        return L("settings.duration.hours", String(format: "%.1f", Double(minutes) / 60))
    }

    @objc private func restoreName(_ sender: NSButton) { nameRestores[ObjectIdentifier(sender)]?() }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        nameEdits[ObjectIdentifier(field)]?()
    }

    private func shortcutsPane() -> NSView {
        let rows = ShortcutAction.allCases.map { action -> NSView in
            let recorder = ShortcutRecorder()
            recorder.actionName = action.title
            recorder.setAccessibilityIdentifier("settings.shortcut.\(action)")
            recorder.onRecording = { [weak self] recording in self?.onRecordingShortcut?(recording) }
            recorder.onChange = { [weak self] shortcut in
                Settings.shortcuts = ShortcutAction.assigning(shortcut, to: action, in: Settings.shortcuts)
                self?.refreshShortcuts()
                self?.onChange?()
            }
            let warning = NSImageView()
            warning.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                    accessibilityDescription: L("settings.shortcut.taken"))
            warning.contentTintColor = .systemYellow
            warning.toolTip = L("settings.shortcut.taken")
            recorders[action] = (recorder, warning)
            let controls = NSStackView(views: [warning, recorder])
            controls.spacing = 8
            return row(action.title, control: controls)
        }

        guideButton.title = L("settings.systemShortcuts")
        guideButton.bezelStyle = .rounded
        guideButton.setAccessibilityIdentifier("settings.systemShortcuts")
        guideButton.target = self
        guideButton.action = #selector(showGuide)
        return pane([group(rows), guideButton])
    }

    /// What the app is, in a few lines: its icon, name, version, one sentence, and where
    /// its source is.
    private func aboutPane() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true
        let name = NSTextField(labelWithString: AppInfo.name)
        name.font = .systemFont(ofSize: 20, weight: .semibold)
        let version = AppInfo.version
        let tagline = NSTextField(labelWithString: L("about.tagline"))
        let source = NSButton(title: L("about.source"), target: self, action: #selector(openSource))
        source.bezelStyle = .rounded
        source.setAccessibilityIdentifier("settings.source")
        let welcome = NSButton(title: L("about.showWelcome"), target: self, action: #selector(showWelcomeClicked))
        welcome.bezelStyle = .rounded
        welcome.setAccessibilityIdentifier("settings.showWelcome")
        let column = NSStackView(views: [icon, name, caption(L("about.version", version)), tagline, source, welcome,
                                         caption(L("about.license"))])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 6
        column.setCustomSpacing(10, after: icon)
        column.setCustomSpacing(14, after: column.views[2])
        column.setCustomSpacing(18, after: tagline)
        column.setCustomSpacing(10, after: welcome)
        column.edgeInsets = NSEdgeInsets(top: 28, left: 20, bottom: 28, right: 20)
        column.widthAnchor.constraint(equalToConstant: Self.paneWidth).isActive = true
        return column
    }

    @objc private func showWelcomeClicked() { onShowWelcome?() }

    @objc private func openSource() {
        if let url = AppInfo.repository { NSWorkspace.shared.open(url) }
    }

    /// Brings the recorders in line with the preferences, and marks every shortcut the
    /// system would answer first.
    private func refreshShortcuts() {
        let table = Settings.shortcuts
        let system = SystemHotKey.current()
        for (action, views) in recorders {
            views.recorder.shortcut = table[action]
            views.warning.isHidden = table[action]?.isTaken(by: system) != true
        }
    }

    // MARK: The system's screenshot shortcuts

    /// Says how to switch off the system's own screenshot shortcuts, which use the same
    /// keys as this app's defaults and are answered first. Shown only when asked for.
    @objc func showGuide() { showShortcutGuide(relativeTo: guideButton) }

    // MARK: Window

    func show(_ pane: Pane? = nil) {
        if let pane = pane { tabs.selectedTabViewItemIndex = pane.rawValue }
        window.title = tabs.tabViewItems[tabs.selectedTabViewItemIndex].label
        if !window.isVisible {
            window.setContentSize(tabs.tabViewItems[tabs.selectedTabViewItemIndex].view?.fittingSize ?? .zero)
            window.center()
        }
        QuietMode.activate()
        window.makeKeyAndOrderFront(nil)
    }

    // Back from System Settings, the warnings follow what was changed there.
    func windowDidBecomeKey(_ notification: Notification) { refreshShortcuts() }

    func windowWillClose(_ notification: Notification) {
        window.makeFirstResponder(nil)
        // Let the close finish before the owner drops its reference to this object.
        DispatchQueue.main.async { [self] in onClose?() }
    }
}
