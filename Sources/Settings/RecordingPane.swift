import AppKit

/// Recording: the file name, the size a recording stops at, and the preview.
final class RecordingPane: SettingsPane {
    override func makeView() -> NSView {
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
        whenEdited(field) { [weak field] in
            guard let typed = Int(field?.stringValue.trimmingCharacters(in: .whitespaces) ?? "") else { return }
            Settings.maxRecordingGigabytes = typed
            show(Settings.maxRecordingGigabytes)
        }
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
}
