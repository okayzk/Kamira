import AppKit

/// The floating previews of the latest captures and recordings, stacked in the
/// bottom-left corner of the screen: newest frontmost, older ones tucked behind it until
/// the pointer is over the stack.
final class PreviewStack {
    private static let maxPreviews = 5

    /// The card's Pin and Annotate buttons.
    var onPin: ((CapturedImage) -> Void)?
    var onAnnotate: ((CapturedImage) -> Void)?
    /// Converts a video to a GIF: (video, destination, longest side in pixels, done).
    var convertToGIF: ((URL, URL, Int, @escaping (Bool) -> Void) -> Void)?

    /// Holds PNGs created when a preview is dragged out.
    private let dragDirectory: URL
    /// Oldest first.
    private var previews: [PreviewOverlay] = []
    private var expanded = false
    /// The screen the stack stands on.
    private var screen: NSScreen?
    /// Runs only while the pointer is over the stack.
    private var hoverTimer: Timer?
    /// Running Quick Look helpers, one per recording being looked at.
    private var quickLooks: [Process] = []

    init(dragDirectory: URL) {
        self.dragDirectory = dragDirectory
    }

    func show(_ capture: CapturedImage) {
        let overlay = PreviewOverlay(capture: capture)
        overlay.dragDirectory = dragDirectory
        overlay.autoCloseDelay = closeDelay(recording: false)
        overlay.onPin = { [weak self] capture in self?.onPin?(capture) }
        overlay.onAnnotate = { [weak self] capture in self?.onAnnotate?(capture) }
        present(overlay)
    }

    /// Preview for a finished recording. The file is in the save folder already, written
    /// there as it was recorded; closing the preview, by hand or by itself, leaves it there.
    func showRecording(_ url: URL, pointSize: CGSize) {
        guard Settings.recordingPreviewEnabled else { return }
        let side = Int(min(1600, max(pointSize.width, pointSize.height)))
        let overlay = PreviewOverlay(recording: url, gifMaxSide: side)
        overlay.autoCloseDelay = closeDelay(recording: true)
        overlay.onQuickLook = { [weak self] file in self?.openQuickLook(file) }
        overlay.convertToGIF = { [weak self] video, gif, maxSide, done in
            self?.convertToGIF?(video, gif, maxSide, done)
        }
        present(overlay)
    }

    /// Brings the previews in line with the settings.
    func applySettings() {
        // A preview that was switched off goes away; a recording is in the save folder already.
        for overlay in previews where !(overlay.isRecording ? Settings.recordingPreviewEnabled : Settings.previewEnabled) {
            overlay.close()
        }
        previews.removeAll { !$0.isVisible }
        previews.forEach { $0.autoCloseDelay = closeDelay(recording: $0.isRecording) }
    }

    /// Ends every Quick Look helper, as the app quits.
    func closeQuickLooks() {
        quickLooks.forEach { $0.terminate() }
    }

    /// How long a preview stays by itself; nil keeps it until it is closed.
    private func closeDelay(recording: Bool) -> TimeInterval? {
        let seconds = recording ? Settings.recordingPreviewCloseAfter : Settings.previewCloseAfter
        return seconds > 0 ? TimeInterval(seconds) : nil
    }

    /// Shows a recording in the system's Quick Look, in a helper process (see
    /// `QuickLookProcessDelegate`).
    private func openQuickLook(_ file: URL) {
        let helper = Process()
        helper.executableURL = Bundle.main.executableURL
        helper.arguments = ["--quicklook", file.path] + QuietMode.arguments
        helper.terminationHandler = { [weak self] process in
            DispatchQueue.main.async { self?.quickLooks.removeAll { $0 === process } }
        }
        do {
            try helper.run()
            quickLooks.append(helper)
        } catch {
            NSSound.beep()
        }
    }

    private func present(_ overlay: PreviewOverlay) {
        overlay.onDismiss = { [weak self] overlay in self?.remove(overlay) }
        overlay.onPointerActivity = { [weak self] in self?.updateHover() }
        previews.append(overlay)
        // The stack stands on the screen the pointer is on when a capture arrives.
        screen = NSScreen.underPointer
        if previews.count > Self.maxPreviews {
            previews.removeFirst().close()
        }
        layout()
        overlay.alphaValue = 0
        overlay.orderFrontRegardless()
        overlay.animator().alphaValue = 1
    }

    private func remove(_ overlay: PreviewOverlay) {
        overlay.close()
        previews.removeAll { $0 === overlay }
        layout()
        updateHover()
    }

    /// Works out from the pointer position which overlay is hovered, and expands the stack
    /// while the pointer is over it. Overlays overlap when collapsed and move when the
    /// stack expands, so this is re-checked on a short timer until the pointer leaves.
    private func updateHover() {
        let pointer = NSEvent.mouseLocation
        // Collapsed overlays overlap; the newest is frontmost and wins.
        let hovered = previews.last { $0.frame.contains(pointer) }
        previews.forEach { $0.setHovering($0 === hovered) }
        // The margin keeps the stack open while crossing the gap between two overlays.
        let overStack = previews.contains { $0.frame.insetBy(dx: -8, dy: -8).contains(pointer) }
        if overStack {
            if !expanded {
                expanded = true
                layout()
            }
            if hoverTimer == nil {
                hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    self?.updateHover()
                }
            }
        } else {
            hoverTimer?.invalidate()
            hoverTimer = nil
            if expanded {
                expanded = false
                layout()
            }
        }
    }

    /// Places the overlays in the bottom-left corner, newest lowest. Expanded, they form a
    /// column; collapsed, older ones peek out narrower above the newest like a deck of cards.
    private func layout() {
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = PreviewCard.size
        let base = NSPoint(x: visible.minX + 18, y: visible.minY + 18)
        for (index, overlay) in previews.reversed().enumerated() {
            let depth = CGFloat(index)
            let frame = expanded
                ? NSRect(x: base.x, y: base.y + depth * (size.height + 10),
                         width: size.width, height: size.height)
                : NSRect(x: base.x + depth * 7, y: base.y + depth * 8,
                         width: size.width - depth * 14, height: size.height)
            if overlay.isVisible {
                overlay.animator().setFrame(frame, display: true)
            } else {
                overlay.setFrame(frame, display: false)
            }
        }
    }
}
