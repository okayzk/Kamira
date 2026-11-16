import AppKit

/// Dims every screen and shows a control bar with the recording options. The user drags
/// out a region, or uses the bar to choose the whole screen or a window, and then
/// presses one of the record buttons; Esc cancels. Nothing is recorded before that.
final class RegionSelector {
    private var windows: [NSWindow] = []
    private var views: [SelectionView] = []
    private var screens: [NSScreen] = []
    private var bar: RecordingControlBar?
    private var barScreen: NSScreen?
    /// The window chosen with the window button, until the selection changes again.
    private var pickedWindow: CGWindowID?
    private var settingSelection = false
    private let purpose: SelectionPurpose
    private let completion: (RecordingRequest?) -> Void

    init(purpose: SelectionPurpose = .recording, completion: @escaping (RecordingRequest?) -> Void) {
        self.purpose = purpose
        self.completion = completion
    }

    func begin() {
        let home = NSScreen.underPointer
        for screen in NSScreen.screens {
            let window = SelectionWindow(contentRect: screen.frame, styleMask: .borderless,
                                         backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.setAccessibilityIdentifier("selector")
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            // Every screen's area says what dragging in it is for, also where the bar is not.
            view.setAccessibilityElement(true)
            view.setAccessibilityRole(.group)
            view.setAccessibilityLabel(purpose == .recording ? L("selector.area.recording") : L("selector.area.scrolling"))
            view.setAccessibilityIdentifier("selector.area")
            view.onCancel = { [weak self] in self?.end(nil) }
            view.onRecord = { [weak self] gif in self?.record(gif: gif) }
            view.onPickWindow = { [weak self] in self?.pickWindow() }
            view.onSelectionChange = { [weak self, weak view] in
                guard let self = self, let view = view else { return }
                // A selection drawn by hand replaces a chosen window.
                if !self.settingSelection { self.pickedWindow = nil }
                // Only one screen holds a selection at a time.
                if view.selection != nil { self.views.forEach { if $0 !== view { $0.selection = nil } } }
                self.bar?.canRecord = self.selection != nil
            }
            window.contentView = view
            if screen == home {
                let bar = RecordingControlBar(purpose: purpose)
                bar.onRecord = { [weak self] gif in self?.record(gif: gif) }
                bar.onFullScreen = { [weak self] in self?.selectFullScreen() }
                bar.onPickWindow = { [weak self] in self?.pickWindow() }
                view.addSubview(bar)
                NSLayoutConstraint.activate([
                    bar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                    bar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -110)
                ])
                self.bar = bar
                barScreen = screen
            }
            windows.append(window)
            views.append(view)
            screens.append(screen)
        }
        showWindows()
    }

    private func showWindows() {
        for (window, view) in zip(windows, views) {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
        }
        QuietMode.activate()
    }

    /// Development aid: shows `rect` (view coordinates of the bar's screen) as selected.
    func showSample(_ rect: CGRect) {
        (bar?.superview as? SelectionView)?.selection = rect
    }

    private var selection: (rect: CGRect, screen: NSScreen, isFullScreen: Bool)? {
        for (view, screen) in zip(views, screens) {
            if let rect = view.selection {
                return (rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY), screen,
                        pickedWindow == nil && rect == view.bounds)
            }
        }
        return nil
    }

    /// Selects `rect` (global coordinates) on the screen that contains most of it.
    private func select(_ rect: CGRect, window: CGWindowID?) {
        func overlap(_ screen: NSScreen) -> CGFloat {
            let part = screen.frame.intersection(rect)
            return part.isNull ? 0 : part.width * part.height
        }
        guard let index = screens.indices.max(by: { overlap(screens[$0]) < overlap(screens[$1]) }) else { return }
        settingSelection = true
        pickedWindow = window
        let frame = screens[index].frame
        views[index].selection = rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
            .intersection(views[index].bounds)
        settingSelection = false
    }

    /// Selects the whole screen; also reached with the global full-screen shortcut.
    func selectFullScreen() {
        guard let screen = barScreen, !windows.isEmpty, windows[0].isVisible else { return }
        select(screen.frame, window: nil)
    }

    /// Chooses a window with the system's own window picker, the one screenshots use:
    /// `screencapture` highlights the window under the pointer and a click selects it.
    /// Its picture is thrown away; what matters is which window was clicked.
    private func pickWindow() {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ce-window-pick-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-w", "-x", "-o", scratch.path]
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                let chose = FileManager.default.fileExists(atPath: scratch.path)
                try? FileManager.default.removeItem(at: scratch)
                guard let self = self, !self.windows.isEmpty else { return }
                // Look the window up before our own windows come back on top of it.
                let found = chose ? Self.windowUnderPointer() : nil
                self.showWindows()
                if let found = found { self.select(found.frame, window: found.id) }
            }
        }
        windows.forEach { $0.orderOut(nil) }
        do { try process.run() }
        catch { showWindows() }
    }

    /// The frontmost ordinary window under the pointer, with its frame in AppKit coordinates.
    private static func windowUnderPointer() -> (id: CGWindowID, frame: CGRect)? {
        guard let pointer = CGEvent(source: nil)?.location,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[CFString: Any]],
              let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        let own = getpid()
        for entry in list {
            guard (entry[kCGWindowLayer] as? Int) == 0,
                  (entry[kCGWindowOwnerPID] as? pid_t) != own,
                  let number = entry[kCGWindowNumber] as? CGWindowID,
                  let dictionary = entry[kCGWindowBounds] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  bounds.contains(pointer) else { continue }
            // Core Graphics measures from the top of the primary screen.
            return (number, CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY,
                                   width: bounds.width, height: bounds.height))
        }
        return nil
    }

    private func record(gif: Bool) {
        guard let bar = bar, let chosen = selection else { return }
        var options = bar.options
        options.gif = gif
        end(RecordingRequest(area: chosen.rect, screen: chosen.screen, windowID: pickedWindow,
                             isFullScreen: chosen.isFullScreen, options: options,
                             countdown: bar.countdown))
    }

    private func end(_ result: RecordingRequest?) {
        guard !windows.isEmpty else { return }
        windows.forEach { $0.close() }
        windows.removeAll()
        views.removeAll()
        screens.removeAll()
        bar = nil
        completion(result)
    }
}
