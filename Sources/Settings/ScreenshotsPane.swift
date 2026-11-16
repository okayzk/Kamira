import AppKit

/// Screenshots: copying and saving by themselves, the file name, the preview, and the
/// shadow around a window capture.
final class ScreenshotsPane: SettingsPane {
    override func makeView() -> NSView {
        // From none to the system's own in five steps; the slider stops only on those.
        let shadow = NSSlider(value: Double(Settings.windowShadowLevel), minValue: 0,
                              maxValue: Double(WindowShadowLevel.system), target: nil, action: nil)
        shadow.numberOfTickMarks = WindowShadowLevel.system + 1
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
}
