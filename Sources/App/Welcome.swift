import AppKit

/// Shown on the first start, on one borderless sheet of glass: a short loop of the app at
/// work (`WelcomeDemo`), then four things to settle (the screen-recording permission, the
/// screenshot keys, Open at Login, updates), each marked by a coloured symbol that turns
/// into a green tick once it is done. Everything is settled here, nothing sends the user
/// elsewhere but the system's own panes. Get Started closes it and keeps what it shows.
final class WelcomeWindowController: SettingsSurface, NSWindowDelegate {
    var onClose: (() -> Void)?
    /// Called with true while a shortcut is being typed: the app's own must not fire then.
    var onRecordingShortcut: ((Bool) -> Void)?
    /// For `--demo-welcome-pending`: shows the permission and the system's keys as not done.
    var showsPending = false
    /// For the demo modes: closing does not count as having seen it.
    var isDemo = false

    static let width: CGFloat = 440
    private static let inset: CGFloat = 32
    /// The actions that have a shortcut out of the box, set right here.
    private static let keyActions: [ShortcutAction] = [.area, .screen, .panel]

    private let window = WelcomeWindow()
    private let permissionMark = Mark(symbol: "record.circle", colour: .systemRed)
    private let keysMark = Mark(symbol: "command", colour: .systemBlue)
    private let allow = WelcomeWindowController.glassButton(L("welcome.permission.allow"))
    private let turnOff = WelcomeWindowController.glassButton(L("settings.systemShortcuts"))
    private let keysDetail = WelcomeWindowController.detail("")
    private var recorders: [ShortcutAction: ShortcutRecorder] = [:]
    private var interval = NSPopUpButton()
    /// What comes in, one after another, when the window opens.
    private var entrance: [NSView] = []
    /// Once shown, a mark that becomes done bounces into its tick.
    private var isShown = false

    override init() {
        super.init()
        window.delegate = self

        // The suggestion, unless updates were already chosen (the app restarts once the
        // screen-recording permission is given, and shows this again).
        if UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") == nil { Updater.policy = .ask }

        let demo = WelcomeDemo()
        let title = NSTextField(labelWithString: L("welcome.title", AppInfo.name))
        title.font = .systemFont(ofSize: 20, weight: .bold)

        allow.target = self
        allow.action = #selector(allowRecording)
        allow.setAccessibilityIdentifier("welcome.allowRecording")
        turnOff.setAccessibilityIdentifier("welcome.systemShortcuts")
        turnOff.target = self
        turnOff.action = #selector(openKeyboard)

        let login = loginSwitch()
        login.setAccessibilityIdentifier("welcome.openAtLogin")
        let menus = updateMenus { [weak self] in self?.refresh() }
        interval = menus.interval
        menus.policy.setAccessibilityIdentifier("welcome.updatePolicy")
        menus.interval.setAccessibilityIdentifier("welcome.updateInterval")
        let updateMenus = NSStackView(views: [menus.policy, menus.interval])
        updateMenus.spacing = 6

        let rows = [
            row(permissionMark, L("welcome.permission"), Self.detail(L("welcome.permission.detail")), beside: allow),
            row(keysMark, L("welcome.shortcuts"), keysDetail, below: shortcutList()),
            row(Mark(symbol: "power", colour: .systemOrange), L("settings.openAtLogin"),
                Self.detail(L("welcome.login.detail")), beside: login),
            row(Mark(symbol: "arrow.triangle.2.circlepath", colour: .systemPurple), L("settings.update"),
                Self.detail(L("welcome.update.detail")), below: updateMenus)
        ]
        let list = NSStackView(views: rows)
        list.orientation = .vertical
        list.spacing = 16
        for row in rows { row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }

        let start = NSButton(title: L("welcome.start"), target: self, action: #selector(finish))
        start.bezelStyle = .glass
        start.borderShape = .capsule
        start.tintProminence = .primary
        start.controlSize = .large
        start.keyEquivalent = "\r"
        start.setAccessibilityIdentifier("welcome.start")
        start.widthAnchor.constraint(equalToConstant: 200).isActive = true

        let column = NSStackView(views: [demo, title, list, start])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.setCustomSpacing(20, after: demo)
        column.setCustomSpacing(16, after: title)
        column.setCustomSpacing(24, after: list)
        column.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.inset, bottom: 28, right: Self.inset)
        column.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        list.widthAnchor.constraint(equalToConstant: Self.width - 2 * Self.inset).isActive = true
        start.centerXAnchor.constraint(equalTo: column.centerXAnchor).isActive = true
        entrance = [title] + rows + [start]

        // The window is the glass and nothing around it.
        let glass = NSGlassEffectView()
        glass.cornerRadius = WelcomeWindow.cornerRadius
        glass.contentView = column
        // Clipped to the same outline, so that the corners are see-through and the
        // window's shadow follows the glass rather than a rectangle.
        let clip = NSView()
        clip.wantsLayer = true
        clip.layer?.cornerRadius = WelcomeWindow.cornerRadius
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        glass.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(glass)
        NSLayoutConstraint.activate([glass.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
                                     glass.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
                                     glass.topAnchor.constraint(equalTo: clip.topAnchor),
                                     glass.bottomAnchor.constraint(equalTo: clip.bottomAnchor)])
        window.contentView = clip
        window.setAccessibilityIdentifier("welcome")
        refresh()
    }

    // MARK: Pieces

    /// One thing to settle: a mark, a name with a line under it, and a control. The mark
    /// and a small control (a button, a switch) sit level with the name; a wide control
    /// goes under the words.
    private func row(_ mark: Mark, _ title: String, _ detail: NSTextField,
                     beside: NSView? = nil, below: NSView? = nil) -> NSView {
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        let words = NSStackView(views: [name, detail] + (below.map { [$0] } ?? []))
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 2
        if below != nil { words.setCustomSpacing(10, after: detail) }
        let row = NSView()
        for view in [mark, words] + (beside.map { [$0] } ?? []) {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        var constraints = [
            mark.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            mark.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            words.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 10),
            words.topAnchor.constraint(equalTo: row.topAnchor),
            words.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ]
        if let beside = beside {
            constraints += [beside.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                            beside.centerYAnchor.constraint(equalTo: name.centerYAnchor),
                            words.trailingAnchor.constraint(lessThanOrEqualTo: beside.leadingAnchor, constant: -12)]
        } else {
            constraints.append(words.trailingAnchor.constraint(equalTo: row.trailingAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        for control in [beside, below].compactMap({ $0 }) { Self.name(control, title, help: detail.stringValue) }
        // Wrapped text needs a width to wrap at: the row's, less the mark and the control.
        detail.preferredMaxLayoutWidth = Self.width - 2 * Self.inset - Mark.side - 10
            - (beside.map { $0.fittingSize.width + 12 } ?? 0)
        return row
    }

    /// The actions that come with a shortcut, each with a recorder to change it, then the
    /// way to the system's own screenshot keys while they would answer first.
    private func shortcutList() -> NSView {
        var lines: [NSView] = []
        for action in Self.keyActions {
            let recorder = ShortcutRecorder()
            recorder.actionName = action.title
            recorder.setAccessibilityIdentifier("welcome.shortcut.\(action)")
            recorder.controlSize = .small
            recorder.onRecording = { [weak self] recording in self?.onRecordingShortcut?(recording) }
            recorder.onChange = { [weak self] shortcut in
                Settings.shortcuts = ShortcutAction.assigning(shortcut, to: action, in: Settings.shortcuts)
                self?.refresh()
                self?.onChange?()
            }
            recorders[action] = recorder
            let name = NSTextField(labelWithString: action.title)
            name.font = .systemFont(ofSize: 12)
            let line = NSStackView(views: [name, NSView(), recorder])
            line.widthAnchor.constraint(equalToConstant: Self.width - 2 * Self.inset - Mark.side - 10).isActive = true
            lines.append(line)
        }
        let list = NSStackView(views: lines + [turnOff])
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        list.setCustomSpacing(10, after: lines[lines.count - 1])
        return list
    }

    private static func detail(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }

    private static func glassButton(_ title: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .glass
        button.borderShape = .capsule
        button.controlSize = .small
        return button
    }

    // MARK: State

    /// Follows what was changed here or elsewhere: the permission, the shortcuts and the
    /// system's own, and the update menu (how often means nothing while nothing is checked).
    private func refresh() {
        let permitted = !showsPending && CGPreflightScreenCaptureAccess()
        allow.isHidden = permitted
        permissionMark.setDone(permitted, animated: isShown)
        let table = Settings.shortcuts
        for (action, recorder) in recorders { recorder.shortcut = table[action] }
        let taken = showsPending || ShortcutAction.anyTaken(table, by: SystemHotKey.current())
        turnOff.isHidden = !taken
        keysMark.setDone(!taken, animated: isShown)
        keysDetail.stringValue = taken ? L("welcome.shortcuts.taken") : L("welcome.shortcuts.free")
        interval.isHidden = !Updater.policy.checks
        window.setContentSize(window.contentView?.fittingSize ?? .zero)
        // The shadow follows the glass's rounded outline only once that has been drawn.
        DispatchQueue.main.async { [weak window] in window?.invalidateShadow() }
    }

    /// The system's own request: its prompt leads to System Settings, and macOS offers to
    /// reopen the app once it is allowed.
    @objc private func allowRecording() { CGRequestScreenCaptureAccess() }

    @objc private func openKeyboard() { showShortcutGuide(relativeTo: turnOff) }

    @objc private func finish() { window.close() }

    // MARK: Window

    func show() {
        refresh()
        if window.isVisible {
            QuietMode.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        window.center()
        QuietMode.activate()
        window.makeKeyAndOrderFront(nil)
        // Each piece rises into place a moment after the one above it.
        for (index, view) in entrance.enumerated() {
            view.wantsLayer = true
            guard let layer = view.layer else { continue }
            let delay = CACurrentMediaTime() + 0.08 + Double(index) * 0.05
            let rise = CASpringAnimation(keyPath: "transform.translation.y")
            rise.fromValue = -14
            rise.toValue = 0
            rise.damping = 14
            rise.duration = rise.settlingDuration
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.3
            for animation in [rise, fade] as [CAAnimation] {
                animation.beginTime = delay
                animation.fillMode = .backwards
                layer.add(animation, forKey: nil)
            }
        }
        isShown = true
    }

    func windowDidBecomeKey(_ notification: Notification) { refresh() }

    func windowWillClose(_ notification: Notification) {
        window.makeFirstResponder(nil)
        if !isDemo { Settings.welcomed = true }
        DispatchQueue.main.async { [self] in onClose?() }
    }
}

/// A window that is only its content: no frame, no title bar, no buttons. Borderless
/// windows cannot become key on their own, and this one takes typing (the shortcuts).
private final class WelcomeWindow: NSWindow {
    static let cornerRadius: CGFloat = 16

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: WelcomeWindowController.width, height: 600),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// A row's symbol in its colour, or a green tick once the row is done.
private final class Mark: NSImageView {
    static let side: CGFloat = 22
    private let symbol: String
    private let colour: NSColor
    private var isDone = false

    init(symbol: String, colour: NSColor) {
        self.symbol = symbol
        self.colour = colour
        super.init(frame: .zero)
        symbolConfiguration = .init(pointSize: 17, weight: .medium)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        contentTintColor = colour
        widthAnchor.constraint(equalToConstant: Self.side).isActive = true
        heightAnchor.constraint(equalToConstant: Self.side).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setDone(_ done: Bool, animated: Bool) {
        guard done != isDone else { return }
        isDone = done
        guard let picture = NSImage(systemSymbolName: done ? "checkmark.circle.fill" : symbol,
                                    accessibilityDescription: nil) else { return }
        contentTintColor = done ? .systemGreen : colour
        if animated {
            setSymbolImage(picture, contentTransition: .replace)
            if done { addSymbolEffect(.bounce) }
        } else {
            image = picture
        }
    }
}
