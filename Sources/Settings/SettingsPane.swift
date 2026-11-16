import AppKit

/// One pane of the settings window: the view it shows, built when first asked for, and
/// the rows the Screenshots and Recording panes both have.
class SettingsPane: SettingsSurface, NSTextFieldDelegate {
    private(set) lazy var view: NSView = makeView()

    /// What to do when the text of a field changes.
    private var edits: [ObjectIdentifier: () -> Void] = [:]
    private var restores: [ObjectIdentifier: () -> Void] = [:]

    /// The pane's content; each pane builds its own.
    func makeView() -> NSView {
        preconditionFailure("\(type(of: self)) builds no view")
    }

    /// Never, or after one of a few numbers of seconds.
    func timeChoice(_ current: Int, set: @escaping (Int) -> Void) -> NSPopUpButton {
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
    func nameRow(format: String, extension ext: String, fallback: String, id: String,
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
        whenEdited(field) { [weak field] in
            set(field?.stringValue ?? "")
            show()
        }
        // Back to the name the app would give by itself.
        let restore = NSButton(image: NSImage(systemSymbolName: "arrow.counterclockwise",
                                              accessibilityDescription: L("settings.fileName.restore")) ?? NSImage(),
                               target: self, action: #selector(restoreName(_:)))
        restore.isBordered = false
        restore.contentTintColor = .secondaryLabelColor
        restore.toolTip = L("settings.fileName.restore")
        restore.setAccessibilityIdentifier(id + ".restore")
        restores[ObjectIdentifier(restore)] = { [weak self, weak field] in
            guard let field = field else { return }
            field.stringValue = fallback
            self?.edits[ObjectIdentifier(field)]?()
        }
        let line = NSStackView(views: [restore, field])
        line.spacing = 6
        let column = NSStackView(views: [line, example])
        column.orientation = .vertical
        column.alignment = .trailing
        column.spacing = 3
        return row(L("settings.fileName"), control: column)
    }

    /// Runs `edit` whenever the text of `field` changes, as it is typed.
    func whenEdited(_ field: NSTextField, _ edit: @escaping () -> Void) {
        edits[ObjectIdentifier(field)] = edit
        field.delegate = self
    }

    @objc private func restoreName(_ sender: NSButton) { restores[ObjectIdentifier(sender)]?() }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        edits[ObjectIdentifier(field)]?()
    }
}
