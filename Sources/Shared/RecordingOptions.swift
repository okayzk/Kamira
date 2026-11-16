import ScreenCaptureKit

struct RecordingOptions {
    /// Record what the Mac is playing.
    var systemAudio = true
    /// Record the default microphone, mixed into the same audio track as the system audio.
    var microphone = false
    /// Produce an animated GIF (no sound) instead of an .mp4.
    var gif = false
}
