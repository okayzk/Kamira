import AppKit
import ServiceManagement

/// The user's choices. Everything is kept by the system: preferences in user defaults,
/// the login item in the system's own list (System Settings → General → Login Items).
enum Settings {
    private static func flag(_ key: String, default fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? fallback : UserDefaults.standard.bool(forKey: key)
    }

    /// Whether the welcome window was closed once.
    static var welcomed: Bool {
        get { flag("welcomed", default: false) }
        set { UserDefaults.standard.set(newValue, forKey: "welcomed") }
    }

    static var previewEnabled: Bool {
        get { flag("previewEnabled", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: "previewEnabled") }
    }
    /// Seconds before a screenshot's or a recording's preview closes by itself; 0 keeps
    /// it until it is closed.
    static var previewCloseAfter: Int {
        get {
            PreviewTiming.closeAfter(stored: UserDefaults.standard.object(forKey: "previewCloseAfter") as? Int,
                                     earlier: UserDefaults.standard.object(forKey: "previewAutoClose") as? Bool)
        }
        set { UserDefaults.standard.set(newValue, forKey: "previewCloseAfter") }
    }
    static var recordingPreviewCloseAfter: Int {
        get { PreviewTiming.closeAfter(stored: UserDefaults.standard.object(forKey: "recordingPreviewCloseAfter") as? Int, earlier: nil) }
        set { UserDefaults.standard.set(newValue, forKey: "recordingPreviewCloseAfter") }
    }

    // What happens to a capture by itself, without the preview's buttons.
    static var copyAfterCapture: Bool {
        get { flag("copyAfterCapture", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: "copyAfterCapture") }
    }
    static var saveAfterCapture: Bool {
        get { flag("saveAfterCapture", default: false) }
        set { UserDefaults.standard.set(newValue, forKey: "saveAfterCapture") }
    }
    /// A recording stops by itself at this size (`RecordingSize`).
    static var maxRecordingGigabytes: Int {
        get { RecordingSize.gigabytes(stored: UserDefaults.standard.object(forKey: "maxRecordingGigabytes") as? Int) }
        set { UserDefaults.standard.set(RecordingSize.gigabytes(stored: newValue), forKey: "maxRecordingGigabytes") }
    }

    /// Where captures are saved, and where save panels open: the folder chosen here, or
    /// the one the system saves its own screenshots to.
    static var saveDirectory: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: "saveDirectory") {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                    return URL(fileURLWithPath: path, isDirectory: true)
                }
            }
            return ScreenRecorder.outputDirectory
        }
        set { UserDefaults.standard.set(newValue.path, forKey: "saveDirectory") }
    }
    /// The patterns saved files are named by; see `FileNaming`.
    static var screenshotNameFormat: String {
        get { UserDefaults.standard.string(forKey: FileNaming.screenshotKey) ?? FileNaming.screenshotDefault }
        set { UserDefaults.standard.set(newValue, forKey: FileNaming.screenshotKey) }
    }
    static var recordingNameFormat: String {
        get { UserDefaults.standard.string(forKey: FileNaming.recordingKey) ?? FileNaming.recordingDefault }
        set { UserDefaults.standard.set(newValue, forKey: FileNaming.recordingKey) }
    }

    /// Covers the desktop icons while a screenshot or a recording is taken; see `DesktopCover`.
    static var hideDesktopIcons: Bool {
        get { flag("hideDesktopIcons", default: false) }
        set { UserDefaults.standard.set(newValue, forKey: "hideDesktopIcons") }
    }
    /// With the preview off, a finished recording goes straight to the save folder.
    static var recordingPreviewEnabled: Bool {
        get { flag("recordingPreviewEnabled", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: "recordingPreviewEnabled") }
    }
    static var fadePinsOnHover: Bool {
        get { flag("fadeEnabled", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: "fadeEnabled") }
    }
    /// With the icon hidden, opening the app again shows it together with the settings.
    static var hideMenuBarIcon: Bool {
        get { flag("hideMenuBarIcon", default: false) }
        set { UserDefaults.standard.set(newValue, forKey: "hideMenuBarIcon") }
    }

    /// The shadow around a window capture: 0 for none, up to `WindowShadow.systemLevel`
    /// for the system's own.
    static var windowShadowLevel: Int {
        get {
            WindowShadow.level(stored: UserDefaults.standard.object(forKey: "windowShadowLevel") as? Int,
                               earlier: UserDefaults.standard.string(forKey: "windowShadow"))
        }
        set { UserDefaults.standard.set(newValue, forKey: "windowShadowLevel") }
    }

    /// The global shortcut of each action that has one.
    static var shortcuts: [ShortcutAction: Shortcut] {
        get {
            var table: [ShortcutAction: Shortcut] = [:]
            for action in ShortcutAction.allCases {
                table[action] = action.shortcut(fromStored: UserDefaults.standard.string(forKey: action.preferenceKey))
            }
            return table
        }
        set {
            // An empty text, not a missing one: missing means the default.
            for action in ShortcutAction.allCases {
                UserDefaults.standard.set(newValue[action]?.stored ?? "", forKey: action.preferenceKey)
            }
        }
    }

    static var openAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    static func setOpenAtLogin(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// A button that shows a shortcut and, once clicked, takes the next key press as the new
/// one. Delete clears it, Esc leaves it as it was.
final class ShortcutRecorder: NSButton {
    var shortcut: Shortcut? { didSet { refresh() } }
    /// What the shortcut does. Assistive apps say it before the shortcut ("Capture Area,
    /// ⇧⌘4"); the button itself shows only the keys.
    var actionName: String? { didSet { refresh() } }
    var onChange: ((Shortcut?) -> Void)?
    /// Called when recording starts and ends: the app's own shortcuts must not fire
    /// while one of them is being typed here.
    var onRecording: ((Bool) -> Void)?
    private var isRecording = false { didSet { refresh() } }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(startRecording)
        toolTip = L("settings.shortcut.hint")
        widthAnchor.constraint(equalToConstant: 124).isActive = true
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func refresh() {
        title = isRecording ? L("settings.shortcut.recording") : shortcut?.display ?? L("settings.shortcut.record")
        contentTintColor = shortcut == nil || isRecording ? .secondaryLabelColor : nil
        if let actionName = actionName {
            setAccessibilityLabel(actionName)
            setAccessibilityValue(title)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    @objc private func startRecording() {
        guard !isRecording, window?.makeFirstResponder(self) == true else { return }
        isRecording = true
        onRecording?(true)
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        onRecording?(false)
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    // Shortcuts with ⌘ arrive here, the others in keyDown.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        record(event)
    }

    private func record(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags.isEmpty, event.keyCode == 53 { // Esc
            stopRecording()
            return
        }
        if flags.isEmpty, event.keyCode == 51 || event.keyCode == 117 { // Delete, Forward Delete
            stopRecording()
            onChange?(nil)
            return
        }
        // The key as it prints on its own: with Shift held, "4" would arrive as "$".
        let new = Shortcut(keyCode: event.keyCode, flags: flags, key: event.characters(byApplyingModifiers: []) ?? "")
        guard new.isUsable else {
            NSSound.beep()
            return
        }
        stopRecording()
        onChange?(new)
    }
}

/// Grows or shrinks the window to the pane that was chosen, as the system's settings do.
private final class SettingsTabs: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        resizeSelectedPane()
    }

    func resizeSelectedPane() {
        guard tabViewItems.indices.contains(selectedTabViewItemIndex),
              let window = view.window else { return }
        let item = tabViewItems[selectedTabViewItemIndex]
        guard let pane = item.view else { return }
        window.title = item.label
        let size = pane.fittingSize
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        // The title bar stays where it is.
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: window.isVisible)
    }
}

/// What the settings window and the welcome window are built from: groups of rows with
/// the name on the left and the control on the right, all equally wide.
class SettingsSurface: NSObject {
    /// Called after any setting changed, so the app can apply it.
    var onChange: (() -> Void)?

    static let paneWidth: CGFloat = 460

    private var actions: [() -> Void] = []
    private var guide: NSPopover?

    /// The same system-shortcut instructions in Settings and the welcome window.
    func showShortcutGuide(relativeTo button: NSButton) {
        guide?.close()
        let text = NSTextField(wrappingLabelWithString: L("settings.systemShortcuts.steps"))
        text.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let open = NSButton(title: L("settings.systemShortcuts.open"), target: self,
                            action: #selector(openKeyboardFromGuide))
        open.bezelStyle = .rounded
        open.keyEquivalent = "\r"
        let column = NSStackView(views: [text, open])
        column.orientation = .vertical
        column.alignment = .trailing
        column.spacing = 14
        column.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            column.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
        let controller = NSViewController()
        controller.view = content
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        guide = popover
    }

    @objc private func openKeyboardFromGuide() {
        guide?.close()
        Self.openKeyboardSettings()
    }

    static func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Open at Login. Registering can be refused by the system; the switch then goes back
    /// to the truth.
    func loginSwitch() -> NSSwitch {
        let login = NSSwitch()
        login.state = Settings.openAtLogin ? .on : .off
        bind(login) { [weak login] in
            guard let login = login else { return }
            do { try Settings.setOpenAtLogin(login.state == .on) } catch {
                let alert = NSAlert(error: error)
                if let window = login.window { alert.beginSheetModal(for: window) }
            }
            login.state = Settings.openAtLogin ? .on : .off
        }
        return login
    }

    /// The two update menus: what the app does on its own (`UpdatePolicy`), and how often
    /// it checks. `changed` runs after the first one is used.
    func updateMenus(changed: @escaping () -> Void) -> (policy: NSPopUpButton, interval: NSPopUpButton) {
        let policies = UpdatePolicy.allCases
        let policy = NSPopUpButton(frame: .zero, pullsDown: false)
        policy.addItems(withTitles: policies.map {
            switch $0 {
            case .manual: L("settings.update.manual")
            case .ask: L("settings.update.ask")
            case .automatic: L("settings.update.automatic")
            }
        })
        policy.selectItem(at: policies.firstIndex(of: Updater.policy) ?? 0)
        let intervals = UpdatePolicy.intervals
        let interval = NSPopUpButton(frame: .zero, pullsDown: false)
        interval.addItems(withTitles: [L("settings.update.interval.day"), L("settings.update.interval.week"),
                                      L("settings.update.interval.month")])
        interval.selectItem(at: intervals.firstIndex(of: Updater.interval) ?? 0)
        bind(policy) { [weak policy] in
            guard let index = policy?.indexOfSelectedItem, policies.indices.contains(index) else { return }
            Updater.policy = policies[index]
            changed()
        }
        bind(interval) { [weak interval] in
            guard let index = interval?.indexOfSelectedItem, intervals.indices.contains(index) else { return }
            Updater.interval = intervals[index]
        }
        return (policy, interval)
    }

    /// Updates in Settings: the second row shows only while the app checks on its own.
    func updateGroup(resize: @escaping () -> Void) -> NSView {
        var showInterval = {}
        let menus = updateMenus { showInterval() }
        let intervalRow = row(L("settings.update.interval"), id: "settings.updateInterval", control: menus.interval)
        let check = NSButton(title: L("about.checkForUpdates"), target: nil, action: nil)
        check.setAccessibilityIdentifier("settings.checkForUpdates")
        check.bezelStyle = .rounded
        bind(check) { Updater.checkNow() }
        check.controlSize = .regular
        check.font = .systemFont(ofSize: NSFont.systemFontSize)
        let group = group([row(L("settings.update"), id: "settings.updatePolicy", control: menus.policy), intervalRow,
                           row("", control: check)])
        // The separator above the second row goes with it.
        let separator = intervalRow.superview?.subviews.first { $0 is NSBox && $0 !== intervalRow }
        showInterval = { [weak intervalRow, weak separator] in
            intervalRow?.isHidden = !Updater.policy.checks
            separator?.isHidden = !Updater.policy.checks
            resize()
        }
        showInterval()
        return group
    }

    // MARK: Building blocks

    /// A pane: groups and loose controls in a column, all panes equally wide.
    func pane(_ parts: [NSView]) -> NSView {
        let column = NSStackView(views: parts)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 16
        column.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        column.widthAnchor.constraint(equalToConstant: Self.paneWidth).isActive = true
        for part in parts where part is NSBox {
            part.widthAnchor.constraint(equalToConstant: Self.paneWidth - 40).isActive = true
        }
        return column
    }

    /// Rows on one rounded backing with hairlines between them.
    func group(_ rows: [NSView]) -> NSView {
        var views: [NSView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let line = NSBox()
                line.boxType = .separator
                views.append(line)
            }
            views.append(row)
        }
        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.cornerRadius = 10
        box.borderWidth = 0
        box.fillColor = .quaternarySystemFill
        box.contentViewMargins = .zero
        box.contentView?.addSubview(column)
        if let content = box.contentView {
            NSLayoutConstraint.activate([
                column.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
                column.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
                column.topAnchor.constraint(equalTo: content.topAnchor),
                column.bottomAnchor.constraint(equalTo: content.bottomAnchor)
            ])
        }
        for view in views { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        return box
    }

    /// One setting: its name (and, for the one that needs it, a line of explanation) on
    /// the left, its control on the right.
    /// `id`, when given, is the control's identifier, by which assistive apps and scripts
    /// find it whatever the language.
    func row(_ title: String, hint: String? = nil, id: String? = nil, control: NSView) -> NSView {
        if let id = id { control.setAccessibilityIdentifier(id) }
        let label = NSTextField(labelWithString: title)
        var left: NSView = label
        if let hint = hint {
            let small = NSTextField(wrappingLabelWithString: hint)
            small.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            small.textColor = .secondaryLabelColor
            small.preferredMaxLayoutWidth = 230
            let column = NSStackView(views: [label, small])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 2
            left = column
        }
        let row = NSStackView(views: [left, NSView(), control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        // A name with an explanation under it, or a control with one, is taller than a
        // plain row: the row grows with it.
        left.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 8).isActive = true
        left.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -8).isActive = true
        control.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 8).isActive = true
        control.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -8).isActive = true
        control.setContentHuggingPriority(.required, for: .horizontal)
        if !title.isEmpty { Self.name(control, title, help: hint) }
        return row
    }

    /// Gives the controls in `view` that have no name of their own the name written
    /// beside them, so that assistive apps say "Open at Login, switch, on" rather than
    /// "switch, on". Buttons with a title and controls named already keep theirs; a pop-up
    /// menu's title is its choice, not its name.
    static func name(_ view: NSView, _ title: String, help: String? = nil) {
        let titled = view is NSButton && !(view is NSPopUpButton) && !(view as! NSButton).title.isEmpty
        if let control = view as? NSControl, !(control is NSTextField && !(control as! NSTextField).isEditable),
           control.accessibilityLabel()?.isEmpty ?? true, !titled {
            control.setAccessibilityLabel(title)
            if let help = help { control.setAccessibilityHelp(help) }
        }
        view.subviews.forEach { name($0, title, help: help) }
    }

    /// Small grey text beside or under a control.
    func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        return label
    }

    func toggle(_ isOn: Bool, set: @escaping (Bool) -> Void) -> NSSwitch {
        let toggle = NSSwitch()
        toggle.state = isOn ? .on : .off
        bind(toggle) { [weak toggle] in set(toggle?.state == .on) }
        return toggle
    }

    /// Runs `action`, then tells the app, whenever the control is used.
    func bind(_ control: NSControl, to action: @escaping () -> Void) {
        control.controlSize = .small
        control.target = self
        control.action = #selector(changed(_:))
        control.tag = actions.count
        actions.append(action)
    }

    @objc private func changed(_ sender: NSControl) {
        actions[sender.tag]()
        onChange?()
    }
}

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
