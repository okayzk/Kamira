import AppKit

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
