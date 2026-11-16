import AppKit
import AVFoundation
import ScreenCaptureKit

/// Records a display, a window or a screen region straight to a file. ScreenCaptureKit
/// captures and encodes outside this process, so no frames pass through the app; a GIF
/// is converted from the finished video by a short-lived helper process.
final class ScreenRecorder: NSObject, SCStreamDelegate,
                            SCRecordingOutputDelegate {
    /// Called on the main thread whenever `isRecording`, `isConverting` or `startDate` change.
    var onStateChange: (() -> Void)?
    /// Called on the main thread with the finished file, or with the reason there is none.
    var onFinished: ((Result<URL, Error>) -> Void)?
    /// Called on the main thread when a recording is stopped by a limit, before `onFinished`.
    var onLimitReached: ((RecordingLimit) -> Void)?
    var options = RecordingOptions()
    /// Where finished recordings go: written there directly, never moved afterwards.
    var saveDirectory = FileManager.default.temporaryDirectory
    /// Where the video behind a GIF is recorded; it is removed once the GIF is made.
    var workDirectory = FileManager.default.temporaryDirectory
    /// The recording stops by itself when its file reaches this many bytes; 0 for no limit.
    var maxBytes: Int64 = 0
    /// The recording stops by itself when the disk has less than this left, so that the
    /// file can still be finished and played rather than cut off by a full disk.
    static let minimumFreeSpace: Int64 = 1_000_000_000
    /// Size in points of the content last recorded, used to size a GIF made from it.
    private(set) var lastPointSize = CGSize.zero

    private(set) var isRecording = false
    /// True while a finished recording is being turned into a GIF.
    private(set) var isConverting = false
    /// When the file actually began; nil while the stream is still starting up.
    private(set) var startDate: Date?
    var isBusy: Bool { isRecording || isConverting }

    private var stream: SCStream?
    private var output: SCRecordingOutput?
    /// Checks the file's size and the free space once a second while recording.
    private var limitTimer: Timer?
    private var videoURL: URL?
    /// Final destination when the recording is to become a GIF.
    private var gifURL: URL?

    static let gifFramesPerSecond = 15
    private static let gifMaxSide: CGFloat = 1600

    /// Appends a line to a small diagnostic log in the temporary folder. Recording goes
    /// through several system callbacks that cannot be exercised by the tests.
    static let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(AppInfo.name)-recording.log")
    static func log(_ message: String) {
        LogFile.append("\(Date()) \(message)", to: logURL)
    }

    // MARK: Choosing what to record

    /// Records `rect` (global AppKit coordinates) of `screen`; nil records the whole screen.
    func start(region rect: CGRect?, on screen: NSScreen) {
        guard !isBusy else { return }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let screenID = (screen.deviceDescription[key] as? NSNumber)?.uint32Value
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            DispatchQueue.main.async {
                guard let display = content?.displays.first(where: { $0.displayID == screenID })
                        ?? content?.displays.first else {
                    self.finish(.failure(error ?? RecorderError(errorDescription: L("error.noScreen"))))
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                var source: CGRect?
                if let rect = rect {
                    // ScreenCaptureKit wants display-local points with a top-left origin.
                    source = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY,
                                    width: rect.width, height: rect.height)
                }
                self.start(filter: filter, sourceRect: source,
                           pointSize: rect?.size ?? screen.frame.size, scale: screen.backingScaleFactor)
            }
        }
    }

    /// Records one window, found by its window number; the recording follows the window.
    func start(windowID: CGWindowID) {
        guard !isBusy else { return }
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
            DispatchQueue.main.async {
                guard let window = content?.windows.first(where: { $0.windowID == windowID }) else {
                    self.finish(.failure(error ?? RecorderError(errorDescription: L("error.noWindow"))))
                    return
                }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                self.start(filter: filter, sourceRect: nil, pointSize: window.frame.size,
                           scale: CGFloat(filter.pointPixelScale))
            }
        }
    }

    // MARK: Recording

    private func start(filter: SCContentFilter, sourceRect: CGRect?, pointSize: CGSize, scale: CGFloat) {
        guard !isBusy else { return }
        let wantsMicrophone = options.microphone && !options.gif
        guard wantsMicrophone else {
            begin(filter: filter, sourceRect: sourceRect, pointSize: pointSize, scale: scale)
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                if granted {
                    self.begin(filter: filter, sourceRect: sourceRect, pointSize: pointSize, scale: scale)
                } else {
                    self.finish(.failure(RecorderError(errorDescription:
                        L("error.microphone", AppInfo.name))))
                }
            }
        }
    }

    private func begin(filter: SCContentFilter, sourceRect: CGRect?, pointSize: CGSize, scale: CGFloat) {
        guard !isBusy else { return }
        let gif = options.gif
        // Video keeps the native pixels; a GIF is recorded at point size, capped, since
        // GIF files grow very quickly with resolution.
        var pixelScale = scale
        if gif { pixelScale = min(1, Self.gifMaxSide / max(pointSize.width, pointSize.height, 1)) }
        let configuration = SCStreamConfiguration()
        configuration.width = max(2, Int(pointSize.width * pixelScale) / 2 * 2)
        configuration.height = max(2, Int(pointSize.height * pixelScale) / 2 * 2)
        if let sourceRect = sourceRect { configuration.sourceRect = sourceRect }
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: gif ? 30 : 60)
        configuration.showsCursor = true
        configuration.capturesAudio = options.systemAudio && !gif
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = options.microphone && !gif

        let name = FileNaming.recordingName()
        // A video goes straight into the save folder. A GIF's source video is temporary
        // and never shown to the user; the GIF itself goes into the save folder.
        let videoDirectory = gif ? workDirectory : saveDirectory
        do {
            try FileManager.default.createDirectory(at: videoDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
        } catch {
            finish(.failure(error)); return
        }
        // A name pattern without the time in it gives every recording the same name:
        // an earlier one must not be written over.
        let url = FileNaming.available(name, extension: "mp4", in: videoDirectory)
        lastPointSize = pointSize
        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = url
        recording.outputFileType = .mp4
        recording.videoCodecType = .h264

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        let output = SCRecordingOutput(configuration: recording, delegate: self)
        do { try stream.addRecordingOutput(output) }
        catch { finish(.failure(error)); return }
        self.stream = stream
        self.output = output
        videoURL = url
        gifURL = gif ? FileNaming.available(url.deletingPathExtension().lastPathComponent, extension: "gif", in: saveDirectory) : nil
        isRecording = true
        onStateChange?()
        stream.startCapture { error in
            Self.log("capture started, error: \(String(describing: error))")
            guard let error = error else { return }
            DispatchQueue.main.async { self.finish(.failure(error)) }
        }
    }

    /// Ends the recording; `onFinished` follows once the file is complete.
    func stop() {
        guard isRecording, let stream = stream else { return }
        stream.stopCapture { error in
            // If stopping fails there will be no "finished" callback, so end here.
            guard let error = error else { return }
            DispatchQueue.main.async { self.finish(.failure(error)) }
        }
    }

    /// The file starts a moment after the stream does; the clock counts from here.
    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        DispatchQueue.main.async {
            guard self.isRecording else { return }
            self.startDate = Date()
            self.onStateChange?()
            self.limitTimer?.invalidate()
            self.limitTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.checkLimits()
            }
        }
    }

    /// Stops the recording, the normal way so the file stays playable, once it reaches
    /// the size limit or the disk is nearly full.
    private func checkLimits() {
        guard isRecording, let output = output, let video = videoURL else { return }
        var reached: RecordingLimit?
        if maxBytes > 0, Int64(output.recordedFileSize) >= maxBytes {
            reached = .size
        } else if let free = try? video.deletingLastPathComponent()
                    .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    .volumeAvailableCapacityForImportantUsage,
                  free < Self.minimumFreeSpace {
            reached = .disk
        }
        guard let limit = reached else { return }
        Self.log("limit reached: \(limit), \(output.recordedFileSize) bytes")
        limitTimer?.invalidate()
        limitTimer = nil
        onLimitReached?(limit)
        stop()
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        DispatchQueue.main.async { self.videoCompleted(error: nil) }
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        DispatchQueue.main.async { self.finish(.failure(error)) }
    }

    /// The system ended the stream, for example because the recorded window closed or
    /// the user chose "stop sharing" in the menu bar. What was written so far is kept;
    /// the short wait lets the normal "finished" callback win if it is on its way.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard stream === self.stream else { return }
            self.videoCompleted(error: error)
        }
    }

    private func videoCompleted(error: Error?) {
        guard isRecording, let video = videoURL else { return }
        guard FileManager.default.fileExists(atPath: video.path) else {
            finish(.failure(error ?? RecorderError(errorDescription: L("error.noRecordingFile"))))
            return
        }
        guard let gif = gifURL else {
            finish(.success(video))
            return
        }
        limitTimer?.invalidate()
        limitTimer = nil
        stream = nil
        output = nil
        isRecording = false
        isConverting = true
        startDate = nil
        onStateChange?()
        convert(video: video, to: gif)
    }

    private func convert(video: URL, to gif: URL) {
        Self.convertToGIF(video: video, gif: gif, maxSide: 0) { succeeded in
            try? FileManager.default.removeItem(at: video)
            if succeeded {
                self.finish(.success(gif))
            } else {
                self.finish(.failure(RecorderError(errorDescription: L("error.gifConversion"))))
            }
        }
    }

    /// Converts a video to a GIF by running this executable as a helper, so the memory
    /// decoding needs is returned to the system when the helper exits instead of
    /// lingering in the menu bar app. `maxSide` caps the longest side in pixels (0: no cap).
    static func convertToGIF(video: URL, gif: URL, maxSide: Int, completion: @escaping (Bool) -> Void) {
        let helper = Process()
        helper.executableURL = Bundle.main.executableURL
        helper.arguments = ["--convert-gif", video.path, gif.path, String(maxSide)]
        helper.terminationHandler = { process in
            DispatchQueue.main.async { completion(process.terminationStatus == 0) }
        }
        do { try helper.run() }
        catch { completion(false) }
    }

    /// Returns to the idle state and reports the outcome.
    private func finish(_ result: Result<URL, Error>) {
        Self.log("finished: \(result)")
        limitTimer?.invalidate()
        limitTimer = nil
        stream = nil
        output = nil
        videoURL = nil
        gifURL = nil
        isRecording = false
        isConverting = false
        startDate = nil
        onStateChange?()
        onFinished?(result)
    }
}
