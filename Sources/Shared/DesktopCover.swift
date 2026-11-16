import AppKit
import ImageIO

/// Hides the desktop icons while a capture is taken, by laying a picture of the
/// wallpaper over them. Runs as a helper process (`--desktop-cover`), because that
/// picture is a screen-sized bitmap: it prints "ready" once every screen is covered and
/// stays until it is stopped, or until the app is gone (`ParentWatch`), so it can never
/// outlive the app and leave the icons hidden.
///
/// The wallpaper is a window of its own beneath the icons; the system's `screencapture`
/// photographs that one window, which gives the wallpaper exactly as it is right now
/// (also a dynamic or animated one, as a still).
enum DesktopCover {
    static func runHelper() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))
        let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let scratch = FileManager.default.temporaryDirectory
        // One photograph per screen, all taken at once.
        var shots: [(screen: NSScreen, file: URL, tool: Process)] = []
        for (index, screen) in NSScreen.screens.enumerated() {
            // Core Graphics measures from the top-left corner of the primary screen.
            let frame = CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY,
                               width: screen.frame.width, height: screen.frame.height)
            // The list runs front to back: the first window at or below the desktop
            // level that fills the screen is the wallpaper being shown.
            let wallpaper = onScreen.first { window in
                guard let layer = window[kCGWindowLayer as String] as? Int, layer <= desktopLevel,
                      let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
                return rect == frame
            }
            guard let number = wallpaper?[kCGWindowNumber as String] as? Int else { continue }
            let file = scratch.appendingPathComponent("\(AppInfo.name)-wallpaper-\(getpid())-\(index).tiff")
            let tool = Process()
            tool.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            tool.arguments = ["-x", "-o", "-t", "tiff", "-l", String(number), file.path]
            if (try? tool.run()) != nil { shots.append((screen, file, tool)) }
        }
        var covers: [NSWindow] = []
        for shot in shots {
            shot.tool.waitUntilExit()
            defer { try? FileManager.default.removeItem(at: shot.file) }
            // Decoded here and now: an image from a file is otherwise read when it is first
            // drawn, and by then the file is gone (the cover came out blank).
            guard let source = CGImageSourceCreateWithURL(shot.file as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(
                    source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { continue }
            let window = NSWindow(contentRect: shot.screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            // The icons' own level, in front of them: above the icons, below the widgets
            // and every ordinary window.
            window.level = NSWindow.Level(rawValue: iconLevel)
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            let view = NSView(frame: NSRect(origin: .zero, size: shot.screen.frame.size))
            view.wantsLayer = true
            view.layer?.contents = image
            window.contentView = view
            window.orderFrontRegardless()
            covers.append(window)
        }
        FileHandle.standardOutput.write(Data("ready\n".utf8))
        withExtendedLifetime(covers) { app.run() }
        exit(0)
    }
}
