import AppKit
import ImageIO

private func solidImage(width: Int, height: Int, red: CGFloat) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: red, green: 0.2, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

/// Recording: GIFs and the log (Sources/Recording/).
func testRecording() {
    let gifURL = FileManager.default.temporaryDirectory.appendingPathComponent("ce-test-\(getpid()).gif")
    if let writer = GIFWriter(url: gifURL, framesPerSecond: 10) {
        let dark = solidImage(width: 40, height: 24, red: 0.1)
        // Same as `dark` except for a bright right half.
        let halfContext = CGContext(data: nil, width: 40, height: 24, bitsPerComponent: 8,
                                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        halfContext.draw(dark, in: CGRect(x: 0, y: 0, width: 40, height: 24))
        halfContext.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1))
        halfContext.fill(CGRect(x: 20, y: 0, width: 20, height: 24))
        let half = halfContext.makeImage()!
        // Two identical frames, then a partly different one, then the first again.
        for image in [dark, dark, half, dark] { check(writer.add(image), "frame should be accepted") }
        check(writer.finish(), "GIF should be written")
        if let source = CGImageSourceCreateWithURL(gifURL as CFURL, nil) {
            check(CGImageSourceGetCount(source) == 3, "unchanged frames merge: got \(CGImageSourceGetCount(source)) frames")
            func delay(_ index: Int) -> Double {
                let all = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
                let gif = all?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                return (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue ?? -1
            }
            check(abs(delay(0) - 0.2) < 0.001, "merged frame lasts two frame times, got \(delay(0))")
            check(abs(delay(1) - 0.1) < 0.001, "single frame lasts one frame time, got \(delay(1))")
            // ImageIO composites frames when reading, so each one shows the full picture.
            if let first = CGImageSourceCreateImageAtIndex(source, 0, nil),
               let second = CGImageSourceCreateImageAtIndex(source, 1, nil),
               let third = CGImageSourceCreateImageAtIndex(source, 2, nil) {
                check(first.width == 40 && first.height == 24, "GIF keeps the frame size")
                check(pixel(first, x: 30, y: 12).r < 0.2, "first frame is dark")
                check(pixel(second, x: 30, y: 12).r > 0.7, "changed half shows in the second frame")
                check(pixel(second, x: 10, y: 12).r < 0.2, "unchanged half stays dark")
                check(pixel(third, x: 30, y: 12).r < 0.2, "third frame is dark again")
            } else { check(false, "GIF frames should decode") }
            // Later frames must be stored as differences: a graphic control block with the
            // transparency flag (0x05) instead of a full opaque frame (0x04).
            let raw = (try? Data(contentsOf: gifURL)) ?? Data()
            func blocks(_ flag: UInt8) -> Int {
                let pattern = Data([0x21, 0xF9, 0x04, flag])
                var count = 0, start = raw.startIndex
                while let found = raw.range(of: pattern, in: start..<raw.endIndex) {
                    count += 1
                    start = found.upperBound
                }
                return count
            }
            check(blocks(0x04) == 1 && blocks(0x05) == 2, "one full frame, two difference frames")
            let file = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
            let loop = (file?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? NSNumber
            check(loop?.intValue == 0, "GIF should loop forever")
        } else { check(false, "written GIF should be readable") }
        if CommandLine.arguments.contains("--keep") { print(gifURL.path) } else { try? FileManager.default.removeItem(at: gifURL) }
    } else { check(false, "GIF writer should open the file") }

    // A log never grows past its limit: past it, only its newest whole lines are kept.
    do {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("kamira-test-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        for index in 0..<400 { LogFile.append("line \(index) " + String(repeating: "x", count: 40), to: log, limit: 4_000, keep: 1_000) }
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        check(text.utf8.count <= 4_000, "within the limit, got \(text.utf8.count) bytes")
        check(text.hasSuffix("line 399 " + String(repeating: "x", count: 40) + "\n"), "the newest line is kept")
        check(text.hasPrefix("line "), "starts on a whole line, got \(text.prefix(12))")
        check(!text.contains("line 0 "), "the oldest lines are dropped")
    }
}
