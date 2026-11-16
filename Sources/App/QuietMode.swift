import AppKit

/// `--quiet`, added to a demo mode, keeps a test copy of the app out of the way of the
/// person using the Mac while its windows are read (scripts/accessibility_audit.sh): it
/// never takes the focus or the keyboard, registers no global shortcuts, shows no menu
/// bar icon, checks for no updates, and its windows let clicks through to what is below.
/// Its windows still appear, as assistive apps only read windows that are on screen.
enum QuietMode {
    static let isOn = CommandLine.arguments.contains("--quiet")

    /// Passed on to helper processes that show windows (the editor, Quick Look).
    static var arguments: [String] { isOn ? ["--quiet"] : [] }

    /// Brings the app to the front, as the windows that take typing need; never in quiet mode.
    static func activate() {
        guard !isOn else { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Lets clicks through every window from now on; does nothing unless quiet.
    static func start() {
        guard isOn else { return }
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            NSApp.windows.forEach { $0.ignoresMouseEvents = true }
        }
    }
}
