import AppKit

/// General: opening at login, the menu bar icon, where captures are saved, the desktop
/// icons, pins, updates, and the way to quit.
final class GeneralPane: SettingsPane {
    var onQuit: (() -> Void)?
    /// The pane changed height (the update interval came or went).
    var onResize: (() -> Void)?

    override func makeView() -> NSView {
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
            updateGroup { [weak self] in self?.onResize?() },
            quit
        ])
    }

    @objc private func quitClicked() { onQuit?() }
}
