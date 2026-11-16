import AppKit

/// The pictures pinned above all windows (`PinnedImageWindow`).
final class PinBoard {
    /// Annotate this picture; its pin is gone already.
    var onAnnotate: ((CapturedImage) -> Void)?

    private var pins: [PinnedImageWindow] = []

    func add(_ capture: CapturedImage) {
        let pin = PinnedImageWindow(capture: capture, offset: CGFloat(pins.count % 5) * 22)
        pin.hoverFade = Settings.fadePinsOnHover
        pin.onRemove = { [weak self] window in
            window.close()
            self?.pins.removeAll { $0 === window }
        }
        pin.onAnnotate = { [weak self] window in
            self?.onAnnotate?(window.capture)
            window.close()
            self?.pins.removeAll { $0 === window }
        }
        pins.append(pin)
        pin.orderFrontRegardless()
    }

    func closeAll() {
        pins.forEach { $0.close() }
        pins.removeAll()
    }

    /// Brings the pins in line with the settings.
    func applySettings() {
        pins.forEach { $0.hoverFade = Settings.fadePinsOnHover }
    }
}
