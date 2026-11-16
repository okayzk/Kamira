import Foundation

/// The largest a recording may grow before it stops by itself, and how long that lasts.
enum RecordingSize {
    static let defaultGigabytes = 10
    static let range = 1...1000
    /// H.264 at 60 frames a second, as the recorder writes it, in bits a second per pixel:
    /// measured on 2026-11-15 on a 3840 x 2160 screen, with the screen still and with text
    /// scrolling without pause. Real recordings fall between the two.
    static let stillBitsPerPixel = 0.58
    static let busyBitsPerPixel = 3.72

    static func gigabytes(stored: Int?) -> Int {
        guard let stored = stored else { return defaultGigabytes }
        return min(max(stored, range.lowerBound), range.upperBound)
    }

    /// Gigabytes as Finder counts them.
    static func bytes(gigabytes: Int) -> Int64 { Int64(gigabytes) * 1_000_000_000 }

    /// Minutes `gigabytes` last for a whole screen of `pixels`: with constant motion,
    /// and with the screen still.
    static func minutes(gigabytes: Int, pixels: Double) -> (shortest: Int, longest: Int) {
        let bits = Double(bytes(gigabytes: gigabytes)) * 8
        func minutes(_ rate: Double) -> Int { Int(bits / (rate * max(pixels, 1)) / 60) }
        return (minutes(busyBitsPerPixel), minutes(stillBitsPerPixel))
    }
}
