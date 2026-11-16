import ScreenCaptureKit

/// Why a recording ended without the user stopping it.
enum RecordingLimit {
    /// The file reached the size set in Settings.
    case size
    /// The disk holding the file had less than `ScreenRecorder.minimumFreeSpace` left.
    case disk
}
