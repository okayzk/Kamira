import AppKit

/// What the app is, in a few lines: its icon, name, version, one sentence, and where
/// its source is.
final class AboutPane: SettingsPane {
    var onShowWelcome: (() -> Void)?

    override func makeView() -> NSView {
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
}
