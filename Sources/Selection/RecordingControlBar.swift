import AppKit

/// The floating Liquid Glass bar: recording options, what to record, and the two record
/// buttons. Icons only; each one's name appears as a tooltip. The toggles remember
/// their state between recordings.
final class RecordingControlBar: NSView {
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
        for (button, id) in [(microphone, "microphone"), (systemAudio, "systemAudio"), (timer, "countdown"),
                             (fullScreen, "wholeScreen"), (window, "chooseWindow"), (gif, "recordGIF"), (video, "record")] {
            button.setAccessibilityIdentifier("selector." + id)
        }
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
