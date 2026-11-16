import AppKit

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
