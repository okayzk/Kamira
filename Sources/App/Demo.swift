import CoreGraphics
import Foundation

/// Development aid: the `--demo-…` arguments each show one piece of the app without
/// taking a capture (the list is in internal/testing-built-app.md). This is the first
/// half, reading the arguments; doing what they ask is `AppDelegate.run(_:)`, which
/// holds the features.
enum Demo: Equatable {
    enum SettingsPane: Equatable { case screenshots, recording, shortcuts, about }

    /// `--demo-welcome`, and `--demo-welcome-pending` as on a Mac where nothing is
    /// allowed or switched off yet.
    case welcome(pending: Bool)
    case palette
    /// `--demo-settings` opens the window as it opens (nil); the others pick a pane.
    case settings(SettingsPane?)
    /// `--demo-shortcut-guide`: the note about the system's screenshot shortcuts.
    case shortcutGuide
    /// `--demo-login-item` adds the app to the login items, takes it out again, prints
    /// what the system answered each time, and quits.
    case loginItem
    case menu
    /// `--demo-record <seconds>` records the first display, or with `--screen <number>`
    /// another one, or with `--region x,y,w,h` (global AppKit coordinates) that part of
    /// the screen it lies on, or with `--window <number>` that window; prints the file
    /// and quits. `--gif` and `--mic` change the options.
    case record(seconds: TimeInterval, region: CGRect?, screen: Int?, window: CGWindowID?, gif: Bool, microphone: Bool)
    /// `--demo-select`: the recording selector with a sample selection.
    case select
    /// `--demo-unpin <seconds>` closes all pins after that long (for memory measurements).
    case unpin(after: TimeInterval)
    /// `--demo-scroll <x,y,w,h>`: a scrolling capture of that region (global AppKit
    /// coordinates, on whichever screen) without the selector.
    case scroll(area: CGRect)
    /// `--demo-ocr <image>` recognises the text in an image file, as after a selection.
    case recognizeText(URL)
    /// `--demo-recording <file>`: the floating preview for an existing recording.
    case recording(URL)
    /// `--demo-preview`, `--demo-pin`, `--demo-edit <image>`, and the editor's own demos
    /// (`--demo-draw` and the like, passed on as `mode`). They may repeat.
    case preview(URL)
    case pin(URL)
    case edit(URL, mode: String?)
    /// `--demo-several <image>`, once per picture: the preview of those pictures combined,
    /// as after Capture Several.
    case several([URL])

    private static let editorModes = ["--demo-draw", "--demo-copy", "--demo-move", "--demo-zoom", "--demo-crop"]

    /// Whether this is a demo run at all, which keeps the first-start welcome away.
    static func isAny(_ arguments: [String]) -> Bool {
        arguments.contains { $0.hasPrefix("--demo") }
    }

    /// What the arguments ask for, in the order it is shown: the same order whatever the
    /// order typed, with the picture demos last, in the order given.
    static func parse(_ arguments: [String]) -> [Demo] {
        func has(_ flag: String) -> Bool { arguments.contains(flag) }
        /// The argument after `flag`, if both are there.
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        func rect(_ text: String?) -> CGRect? {
            let n = (text ?? "").split(separator: ",").compactMap { Double($0) }
            return n.count == 4 ? CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) : nil
        }

        var demos: [Demo] = []
        if has("--demo-welcome") { demos.append(.welcome(pending: false)) }
        if has("--demo-welcome-pending") { demos.append(.welcome(pending: true)) }
        if has("--demo-palette") { demos.append(.palette) }
        if has("--demo-settings") { demos.append(.settings(nil)) }
        for (flag, pane) in [("--demo-settings-screenshots", SettingsPane.screenshots),
                             ("--demo-settings-recording", .recording), ("--demo-about", .about)] where has(flag) {
            demos.append(.settings(pane))
        }
        if has("--demo-shortcuts") || has("--demo-shortcut-guide") { demos.append(.settings(.shortcuts)) }
        if has("--demo-shortcut-guide") { demos.append(.shortcutGuide) }
        if has("--demo-login-item") { demos.append(.loginItem) }
        if has("--demo-menu") { demos.append(.menu) }
        if let seconds = value("--demo-record").flatMap(TimeInterval.init) {
            demos.append(.record(seconds: seconds, region: rect(value("--region")), screen: value("--screen").flatMap { Int($0) },
                                 window: value("--window").flatMap { CGWindowID($0) },
                                 gif: has("--gif"), microphone: has("--mic")))
        }
        if has("--demo-select") { demos.append(.select) }
        if let seconds = value("--demo-unpin").flatMap(TimeInterval.init) { demos.append(.unpin(after: seconds)) }
        if let area = rect(value("--demo-scroll")) { demos.append(.scroll(area: area)) }
        if let path = value("--demo-ocr") { demos.append(.recognizeText(URL(fileURLWithPath: path))) }
        if let path = value("--demo-recording") { demos.append(.recording(URL(fileURLWithPath: path))) }
        for (index, flag) in arguments.enumerated().dropLast() {
            let file = URL(fileURLWithPath: arguments[index + 1])
            switch flag {
            case "--demo-preview": demos.append(.preview(file))
            case "--demo-pin": demos.append(.pin(file))
            case "--demo-edit": demos.append(.edit(file, mode: nil))
            case _ where editorModes.contains(flag): demos.append(.edit(file, mode: flag))
            default: break
            }
        }
        let several = arguments.indices.dropLast().filter { arguments[$0] == "--demo-several" }
            .map { URL(fileURLWithPath: arguments[$0 + 1]) }
        if !several.isEmpty { demos.append(.several(several)) }
        return demos
    }
}
