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
