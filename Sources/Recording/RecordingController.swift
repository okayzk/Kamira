import AppKit

/// Starts a recording as the user set it up in the selector: after a countdown if asked
/// for, with the desktop icons covered if the settings say so, and with an outline
/// around a region. Ends it, and tells the app how it went.
final class RecordingController {
    private let recorder = ScreenRecorder()
    /// Called whenever `isRecording`, `isConverting` or `startDate` change.
    var onStateChange: (() -> Void)?
    var onLimitReached: ((RecordingLimit) -> Void)?
    var onFinished: ((Result<URL, Error>) -> Void)?

    /// Counting down before a recording starts.
    private(set) var countdown: CountdownWindow?
    /// Outline around the region being recorded.
    private var frame: RecordingFrameWindow?
    /// Hides the desktop icons for as long as a recording runs.
    private var cover: DesktopCoverSession?

    /// Recording, or writing a GIF from a recording.
    var isBusy: Bool { recorder.isBusy }
    var isRecording: Bool { recorder.isRecording }
    var isConverting: Bool { recorder.isConverting }
    var startDate: Date? { recorder.startDate }
    /// The size in points of what was recorded last, for its preview.
    var lastPointSize: CGSize { recorder.lastPointSize }

    init(workDirectory: URL) {
        recorder.workDirectory = workDirectory
        recorder.onStateChange = { [weak self] in
            guard let self = self else { return }
            if !self.recorder.isRecording {
                self.frame?.close()
                self.frame = nil
                self.cover?.stop()
                self.cover = nil
            }
            self.onStateChange?()
        }
        recorder.onLimitReached = { [weak self] limit in self?.onLimitReached?(limit) }
        recorder.onFinished = { [weak self] result in self?.onFinished?(result) }
    }

    /// Records one window (`windowID`), a whole screen, or a region of it, into the save
    /// folder, after a countdown when `countdown` is set.
    func start(area: CGRect, screen: NSScreen, windowID: CGWindowID?, isFullScreen: Bool,
               options: RecordingOptions, countdown: Bool) {
        recorder.options = options
        recorder.saveDirectory = Settings.saveDirectory
        recorder.maxBytes = RecordingSize.bytes(gigabytes: Settings.maxRecordingGigabytes)
        let record = { [weak self] in
            guard let self = self else { return }
            if let window = windowID {
                self.recorder.start(windowID: window)
            } else if isFullScreen {
                self.recorder.start(region: nil, on: screen)
            } else {
                self.showFrame(around: area)
                self.recorder.start(region: area, on: screen)
            }
        }
        let start = { [weak self] in
            guard let self = self else { return }
            self.countdown = nil
            // A recording of one window has no desktop in it.
            guard Settings.hideDesktopIcons, windowID == nil else { record(); return }
            let cover = DesktopCoverSession()
            self.cover = cover
            cover.start(then: record)
        }
        guard countdown else { start(); return }
        let window = CountdownWindow(centredIn: area)
        self.countdown = window
        window.run(completion: start)
    }

    /// For `--demo-record`: records at once, without countdown or cover, into `directory`
    /// rather than the user's save folder, stopping at the size set in Settings as a real
    /// recording does. `windowID` records that window instead.
    func startDemo(region: CGRect?, on screen: NSScreen, windowID: CGWindowID?,
                   options: RecordingOptions, directory: URL) {
        recorder.options = options
        recorder.workDirectory = directory
        recorder.saveDirectory = directory
        recorder.maxBytes = RecordingSize.bytes(gigabytes: Settings.maxRecordingGigabytes)
        if let region = region { showFrame(around: region) }
        if let windowID = windowID {
            recorder.start(windowID: windowID)
        } else {
            recorder.start(region: region, on: screen)
        }
    }

    func stop() { recorder.stop() }

    /// Converts a recorded video to a GIF in a helper process; `completion` gets whether it worked.
    static func convertToGIF(video: URL, gif: URL, maxSide: Int, completion: @escaping (Bool) -> Void) {
        ScreenRecorder.convertToGIF(video: video, gif: gif, maxSide: maxSide, completion: completion)
    }

    /// The outline around the region being recorded.
    func showFrame(around rect: CGRect) {
        frame?.close()
        frame = RecordingFrameWindow(around: rect)
        frame?.orderFrontRegardless()
    }
}
