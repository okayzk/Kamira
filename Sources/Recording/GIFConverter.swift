import AVFoundation

/// Turns a video file into a looping animated GIF. Runs in a helper process
/// (`--convert-gif <video> <gif> [longest side]`), never inside the menu bar app.
enum GIFConverter {
    static func convert(video: URL, to gif: URL, framesPerSecond: Int, maxSide: Int) async throws {
        let asset = AVURLAsset(url: video)
        let seconds = try await asset.load(.duration).seconds
        guard seconds.isFinite, seconds > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let count = max(1, Int(seconds * Double(framesPerSecond)))
        let times = (0..<count).map {
            CMTime(value: CMTimeValue($0), timescale: CMTimeScale(framesPerSecond))
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Scales down, keeping the aspect ratio, when the video is larger than this.
        if maxSide > 0 { generator.maximumSize = CGSize(width: maxSide, height: maxSide) }
        let tolerance = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond * 2))
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        guard let writer = GIFWriter(url: gif, framesPerSecond: framesPerSecond) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for await result in generator.images(for: times) {
            // A frame that cannot be decoded is skipped rather than failing the whole file.
            guard let image = try? result.image else { continue }
            _ = autoreleasepool { writer.add(image) }
        }
        guard writer.finish() else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Entry point for the helper process; never returns.
    static func runHelper(video: String, gif: String, maxSide: Int) -> Never {
        Task {
            do {
                try await convert(video: URL(fileURLWithPath: video), to: URL(fileURLWithPath: gif),
                                  framesPerSecond: ScreenRecorder.gifFramesPerSecond, maxSide: maxSide)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("GIF conversion failed: \(error)\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }
}
