import AppKit

/// What the user asked for in the recording selector.
struct RecordingRequest {
    /// Area in global AppKit coordinates: the dragged region, the window's frame, or the
    /// whole screen.
    var area: CGRect
    var screen: NSScreen
    /// Set when a window was chosen: that window is recorded, wherever it moves.
    var windowID: CGWindowID?
    /// True when the whole of `screen` was chosen.
    var isFullScreen: Bool
    var options: RecordingOptions
    /// Count down three seconds before recording starts.
    var countdown: Bool
}

/// What the selector is being used for; it decides which controls the bar shows.
enum SelectionPurpose {
    case recording
    case scrollingCapture
}

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
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
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
        NSApp.activate(ignoringOtherApps: true)
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

private final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    var onCancel: (() -> Void)?
    /// Return starts a video, Option-Return a GIF.
    var onRecord: ((Bool) -> Void)?
    /// Space switches to picking a window, as it does when taking a screenshot.
    var onPickWindow: (() -> Void)?
    var onSelectionChange: (() -> Void)?
    /// In view coordinates; nil means nothing is selected on this screen.
    var selection: CGRect? {
        didSet {
            needsDisplay = true
            if selection != oldValue { onSelectionChange?() }
        }
    }
    private var anchor: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.3).setFill()
        bounds.fill()
        guard let selection = selection else { return }
        NSColor.clear.setFill()
        selection.fill(using: .copy)
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()

        // Size label just below the selection, or inside it when there is no room.
        let text = "\(Int(selection.width)) × \(Int(selection.height))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        var origin = NSPoint(x: selection.minX + 6, y: selection.minY - size.height - 10)
        if origin.y < 4 { origin.y = selection.minY + 8 }
        let pill = NSRect(x: origin.x - 6, y: origin.y - 3, width: size.width + 12, height: size.height + 6)
        NSColor(white: 0, alpha: 0.7).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        text.draw(at: origin, withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = anchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                           width: abs(point.x - anchor.x), height: abs(point.y - anchor.y))
            .intersection(bounds)
    }

    override func mouseUp(with event: NSEvent) {
        anchor = nil
        // A click or a tiny drag is not a selection.
        if let rect = selection?.integral, rect.width >= 16, rect.height >= 16 {
            selection = rect
        } else {
            selection = nil
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()
        case 36, 76: onRecord?(event.modifierFlags.contains(.option))
        case 49: onPickWindow?()
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Icon-only button for the control bar; the tooltip carries its name. A toggle shows
/// its state through the symbol and tint.
private final class BarButton: NSButton {
    private let onSymbol: String
    private let offSymbol: String
    private let isToggle: Bool
    var isOn: Bool { didSet { refresh() } }
    var onClick: (() -> Void)?

    /// A two-state toggle.
    init(label: String, onSymbol: String, offSymbol: String, isOn: Bool) {
        self.onSymbol = onSymbol
        self.offSymbol = offSymbol
        self.isOn = isOn
        isToggle = true
        super.init(frame: .zero)
        configure(label)
    }

    /// A plain action button. `symbol` may be short text (such as "GIF") instead of a symbol name.
    init(label: String, symbol: String) {
        onSymbol = symbol
        offSymbol = symbol
        isOn = false
        isToggle = false
        super.init(frame: .zero)
        configure(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func configure(_ label: String) {
        title = ""
        isBordered = false
        imagePosition = .imageOnly
        toolTip = label
        setAccessibilityLabel(label)
        target = self
        action = #selector(clicked)
        widthAnchor.constraint(equalToConstant: 40).isActive = true
        heightAnchor.constraint(equalToConstant: 36).isActive = true
        refresh()
    }

    override var isEnabled: Bool { didSet { refresh() } }

    @objc private func clicked() {
        if isToggle { isOn.toggle() }
        onClick?()
    }

    private func refresh() {
        let name = isOn ? onSymbol : offSymbol
        image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .regular)) ?? Self.badge(name)
        if isToggle {
            contentTintColor = isOn ? .controlAccentColor : .secondaryLabelColor
            setAccessibilityValue(isOn ? L("toggle.on") : L("toggle.off"))
        } else {
            contentTintColor = .labelColor
        }
    }

    /// Text in a rounded outline, for actions that have no system symbol.
    private static func badge(_ text: String) -> NSImage {
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .heavy), .foregroundColor: NSColor.black
        ])
        let textSize = string.size()
        let size = NSSize(width: textSize.width + 9, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 5, yRadius: 5)
            outline.lineWidth = 1.5
            NSColor.black.setStroke()
            outline.stroke()
            string.draw(at: NSPoint(x: (rect.width - textSize.width) / 2, y: (rect.height - textSize.height) / 2))
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// The floating Liquid Glass bar: recording options, what to record, and the two record
/// buttons. Icons only; each one's name appears as a tooltip. The toggles remember
/// their state between recordings.
private final class RecordingControlBar: NSView {
    var onRecord: ((Bool) -> Void)?
    var onFullScreen: (() -> Void)?
    var onPickWindow: (() -> Void)?

    private let microphone: BarButton
    private let systemAudio: BarButton
    private let timer: BarButton
    private let gif = BarButton(label: L("selector.recordGIF"), symbol: "GIF")
    private let video: BarButton

    var options: RecordingOptions {
        RecordingOptions(systemAudio: systemAudio.isOn, microphone: microphone.isOn, gif: false)
    }
    var countdown: Bool { timer.isOn }
    /// The record buttons work only once something is selected.
    var canRecord = false {
        didSet {
            gif.isEnabled = canRecord
            video.isEnabled = canRecord
        }
    }

    init(purpose: SelectionPurpose) {
        video = purpose == .recording
            ? BarButton(label: L("selector.recordVideo"), symbol: "video.fill")
            : BarButton(label: L("selector.startScrolling"), symbol: "play.fill")
        let defaults = UserDefaults.standard
        microphone = BarButton(label: L("selector.microphone"), onSymbol: "mic.fill", offSymbol: "mic.slash",
                               isOn: defaults.bool(forKey: "recordingMicrophone"))
        systemAudio = BarButton(label: L("selector.systemAudio"), onSymbol: "speaker.wave.2.fill", offSymbol: "speaker.slash",
                                isOn: defaults.object(forKey: "recordingAudio") == nil
                                    || defaults.bool(forKey: "recordingAudio"))
        timer = BarButton(label: L("selector.countdown"), onSymbol: "timer", offSymbol: "timer",
                          isOn: defaults.bool(forKey: "recordingCountdown"))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        [microphone, systemAudio, timer].forEach { $0.onClick = { [weak self] in self?.remember() } }

        // The shortcut that captures the whole screen selects it here; the tooltip says so.
        let wholeScreen = L("selector.wholeScreen")
        let fullScreen = BarButton(label: Settings.shortcuts[.screen].map { L("tooltip.withShortcut", wholeScreen, $0.display) }
                                       ?? wholeScreen, symbol: "macbook")
        fullScreen.onClick = { [weak self] in self?.onFullScreen?() }
        let window = BarButton(label: L("selector.chooseWindow"), symbol: "macwindow")
        window.onClick = { [weak self] in self?.onPickWindow?() }
        gif.onClick = { [weak self] in self?.onRecord?(true) }
        video.onClick = { [weak self] in self?.onRecord?(false) }
        gif.isEnabled = false
        video.isEnabled = false

        // A scrolling capture has no sound, countdown or format to choose.
        let row = NSStackView(views: purpose == .recording
            ? [microphone, systemAudio, timer, divider(), fullScreen, window, divider(), gif, video]
            : [fullScreen, window, divider(), video])
        row.orientation = .horizontal
        row.spacing = 4
        row.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        let glass = NSGlassEffectView()
        glass.cornerRadius = 24
        glass.contentView = row
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The bar is not part of the area to drag a selection in.
    override func mouseDown(with event: NSEvent) {}
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    private func divider() -> NSView {
        let line = NSBox()
        line.boxType = .custom
        line.borderWidth = 0
        line.fillColor = .separatorColor
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return line
    }

    private func remember() {
        let defaults = UserDefaults.standard
        defaults.set(microphone.isOn, forKey: "recordingMicrophone")
        defaults.set(systemAudio.isOn, forKey: "recordingAudio")
        defaults.set(timer.isOn, forKey: "recordingCountdown")
    }
}

/// Thin outline drawn just outside the region being recorded. It ignores the mouse and
/// is excluded from captures.
final class RecordingFrameWindow: NSPanel {
    private static let thickness: CGFloat = 2

    init(around rect: CGRect) {
        let frame = rect.insetBy(dx: -Self.thickness, dy: -Self.thickness)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        sharingType = .none
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.borderWidth = Self.thickness
        view.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.9).cgColor
        contentView = view
    }
}

/// Big 3-2-1 shown over the area about to be recorded.
final class CountdownWindow: NSPanel {
    private let label = NSTextField(labelWithString: "3")
    private var remaining = 3
    private var timer: Timer?
    private var completion: (() -> Void)?

    init(centredIn rect: CGRect) {
        let side: CGFloat = 120
        super.init(contentRect: NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        label.font = .monospacedDigitSystemFont(ofSize: 60, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        let holder = NSView()
        holder.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: holder.centerYAnchor)
        ])
        let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        glass.cornerRadius = side / 2
        glass.contentView = holder
        contentView = glass
    }

    /// Counts 3, 2, 1, then closes and calls `completion`.
    func run(completion: @escaping () -> Void) {
        self.completion = completion
        orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.remaining -= 1
            if self.remaining > 0 {
                self.label.stringValue = "\(self.remaining)"
            } else {
                self.timer?.invalidate()
                self.close()
                self.completion?()
                self.completion = nil
            }
        }
    }

    func cancel() {
        timer?.invalidate()
        completion = nil
        close()
    }
}
