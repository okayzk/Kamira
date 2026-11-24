import AppKit

/// The system's own screenshot tool (`screencapture`), run the way the app runs it, for
/// screenshots and for a screenshot added in the editor: the desktop icons covered
/// meanwhile when the setting asks, and a selected window given the shadow the setting
/// asks for.
enum ScreenshotTool {
    /// Runs `screencapture` with `arguments`, writing a PNG to `file`; `done` gets the
    /// file on the main thread when it is finished, and no file means the selection was
    /// cancelled. The process is returned before it starts, so a selection can be ended
    /// early; `failed` is called if it cannot start.
    ///
    /// With `windowShadow`, a selected window gets the shadow the user chose: the system
    /// tool draws only its own wide one or none (`-o`), and the sizes in between are added
    /// afterwards by a helper process (`--window-shadow`), which leaves anything but a
    /// window capture alone.
    @discardableResult
    static func run(_ arguments: [String], to file: URL, windowShadow: Bool = false, hidingDesktopIcons: Bool,
                    failed: @escaping (Error) -> Void, done: @escaping (Process, URL) -> Void) -> Process {
        let level = windowShadow ? Settings.windowShadowLevel : WindowShadowLevel.system
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments + (level == WindowShadowLevel.system ? [] : ["-o"]) + ["-t", "png", file.path]
        // With that setting on, the icons are covered first and shown again afterwards.
        let cover = hidingDesktopIcons && Settings.hideDesktopIcons ? DesktopCoverSession() : nil
        process.terminationHandler = { finished in
            DispatchQueue.main.async {
                cover?.stop()
                guard level > 0, level < WindowShadowLevel.system, FileManager.default.fileExists(atPath: file.path) else {
                    return done(finished, file)
                }
                let helper = Process()
                helper.executableURL = Bundle.main.executableURL
                helper.arguments = ["--window-shadow", file.path, String(level)]
                helper.terminationHandler = { _ in DispatchQueue.main.async { done(finished, file) } }
                // Without the helper the capture is still good, only without a shadow.
                do { try helper.run() } catch { done(finished, file) }
            }
        }
        let start = {
            do { try process.run() } catch {
                cover?.stop()
                failed(error)
            }
        }
        // Give AppKit one event-loop turn to take away what the app has just hidden (the
        // Quick Panel, the editor) before the capture begins.
        DispatchQueue.main.async {
            if let cover = cover { cover.start(then: start) } else { start() }
        }
        return process
    }
}
