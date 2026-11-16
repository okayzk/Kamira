import AppKit
import Carbon.HIToolbox
import ImageIO
import UniformTypeIdentifiers

// Minimal test runner for the non-UI logic. Run with ./test.sh.

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { return }
    failures += 1
    print("FAIL (line \(line)): \(message)")
}

/// Encodes a solid-colour bitmap of the given pixel size, tagged with a DPI.
func makeImageData(width: Int, height: Int, dpi: Double, type: UTType) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let out = NSMutableData()
    let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
    let properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
    CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
    CGImageDestinationFinalize(destination)
    return out as Data
}

func isPNG(_ data: Data) -> Bool { data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) }

// A Retina capture: pixel size is reported as-is, point size is halved.
let retinaPNG = makeImageData(width: 800, height: 400, dpi: 144, type: .png)
if let capture = CapturedImage(data: retinaPNG) {
    check(capture.pixelSize == CGSize(width: 800, height: 400), "pixel size, got \(capture.pixelSize)")
    check(capture.pointSize == CGSize(width: 400, height: 200), "point size, got \(capture.pointSize)")
    check(capture.pngData() == retinaPNG, "PNG input must be passed through untouched")
    if let small = capture.downsampled(maxPixel: 200) {
        check(small.width == 200 && small.height == 100, "downsample to 200, got \(small.width)x\(small.height)")
    } else { check(false, "downsampled returned nil") }
    if let same = capture.downsampled(maxPixel: 5000) {
        check(same.width == 800, "downsampling must never upscale, got \(same.width)")
    } else { check(false, "downsampled returned nil") }
    check(capture.suggestedFileName.hasSuffix(".png"), "file name, got \(capture.suggestedFileName)")
} else { check(false, "PNG data was rejected") }

// Non-Retina TIFF (what some apps put on the clipboard): converted to PNG on export.
let tiff = makeImageData(width: 300, height: 300, dpi: 72, type: .tiff)
if let capture = CapturedImage(data: tiff) {
    check(capture.pointSize == CGSize(width: 300, height: 300), "72 dpi point size, got \(capture.pointSize)")
    if let png = capture.pngData() {
        check(isPNG(png), "TIFF input must be exported as PNG")
        check(CapturedImage(data: png)?.pixelSize == CGSize(width: 300, height: 300), "converted PNG keeps its size")
    } else { check(false, "pngData returned nil for TIFF") }
} else { check(false, "TIFF data was rejected") }

check(CapturedImage(data: Data("not an image".utf8)) == nil, "garbage data must be rejected")

// A window capture has see-through margins (its shadow); an ordinary capture does not.
do {
    let context = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 40, y: 40, width: 220, height: 120))
    let out = NSMutableData()
    let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    check(CapturedImage(data: out as Data)?.hasTransparentEdges == true, "a picture with clear margins has transparent edges")
    check(CapturedImage(data: retinaPNG)?.hasTransparentEdges == false, "a solid picture has no transparent edges")
    // A small shadow of our own: only for window captures, with room around the picture.
    let cutOut = CapturedImage(data: out as Data)!   // 300×200 px at 72 dpi
    if let data = WindowShadow.adding(to: cutOut), let shadowed = CapturedImage(data: data),
       let picture = shadowed.fullSizeUncached() {
        check(shadowed.pixelSize == CGSize(width: 328, height: 228), "shadow adds its margins, got \(shadowed.pixelSize)")
        check(shadowed.pointSize == shadowed.pixelSize, "shadow keeps the resolution, got \(shadowed.pointSize)")
        var bytes = [UInt8](repeating: 0, count: 328 * 228 * 4)
        let canvas = CGContext(data: &bytes, width: 328, height: 228, bitsPerComponent: 8, bytesPerRow: 328 * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        canvas.draw(picture, in: CGRect(x: 0, y: 0, width: 328, height: 228))
        func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[(y * 328 + x) * 4 + 3] }   // y from the top
        check(alpha(164, 114) == 255, "the picture itself stays solid")
        // The box ends 40 px above the old bottom edge; just under it lies shadow.
        check(alpha(164, 10 + 160 + 4) > 20 && alpha(164, 10 + 160 + 4) < 255, "shadow under the picture, got \(alpha(164, 174))")
        check(alpha(2, 2) == 0, "nothing in the far corner, got \(alpha(2, 2))")
    } else { check(false, "shadow was not added") }
    check(WindowShadow.adding(to: CapturedImage(data: retinaPNG)!) == nil, "an ordinary capture gets no shadow")
    // Larger steps of the setting give a larger shadow and more room for it.
    check(WindowShadow.adding(to: cutOut, level: 2).flatMap { CapturedImage(data: $0) }?.pixelSize
            == CGSize(width: 356, height: 256), "the second step doubles the margins")
    check(WindowShadow.adding(to: cutOut, level: 3).flatMap { CapturedImage(data: $0) }?.pixelSize
            == CGSize(width: 384, height: 284), "the third step triples them")
    // The setting: 0 is none, the last step is the system's own shadow. A choice made
    // before there were steps carries over.
    check(WindowShadow.level(stored: nil, earlier: nil) == 1, "small by default")
    check(WindowShadow.level(stored: 3, earlier: "none") == 3, "the stored step wins")
    check(WindowShadow.level(stored: 9, earlier: nil) == WindowShadow.systemLevel, "kept within the steps")
    check(WindowShadow.level(stored: nil, earlier: "none") == 0, "earlier choice: none")
    check(WindowShadow.level(stored: nil, earlier: "small") == 1, "earlier choice: small")
    check(WindowShadow.level(stored: nil, earlier: "system") == WindowShadow.systemLevel, "earlier choice: system")
    check(WindowShadow.systemLevel == 4, "five steps from none to the system's")
}

// Annotations are stored in image points and exported at full pixel resolution.
/// Reads one pixel (x from the left, y from the top) as 0...1 RGB.
func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Double, g: Double, b: Double) {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let i = (y * image.width + x) * 4
    return (Double(bytes[i]) / 255, Double(bytes[i + 1]) / 255, Double(bytes[i + 2]) / 255)
}

let base = CapturedImage(data: makeImageData(width: 400, height: 200, dpi: 144, type: .png))! // 200×100 pt
let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
let counter = Annotation(tool: .counter, color: red, points: [CGPoint(x: 50, y: 50)], text: "1")
let box = Annotation(tool: .rectangle, color: red,
                     points: [CGPoint(x: 120, y: 20), CGPoint(x: 180, y: 80)])
if let data = AnnotationRenderer.export(capture: base, annotations: [counter, box]),
   let out = CapturedImage(data: data), let image = out.fullSizeUncached() {
    check(out.pixelSize == CGSize(width: 400, height: 200), "export keeps pixel size, got \(out.pixelSize)")
    check(out.pointSize == CGSize(width: 200, height: 100), "export keeps point size, got \(out.pointSize)")
    let disc = pixel(image, x: 82, y: 100)      // inside the counter disc, left of the digit
    check(disc.r > 0.8 && disc.b < 0.3, "counter disc should be red, got \(disc)")
    let edge = pixel(image, x: 240, y: 100)     // on the rectangle's left edge
    check(edge.r > 0.8 && edge.b < 0.3, "rectangle edge should be red, got \(edge)")
    let inside = pixel(image, x: 300, y: 100)   // rectangle interior is not filled
    check(inside.r < 0.5 && inside.b > 0.6, "rectangle interior should be untouched, got \(inside)")
} else { check(false, "export failed") }

let boxOnly = Annotation(tool: .rectangle, color: red, points: [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 40)])
check(boxOnly.rect == CGRect(x: 10, y: 10, width: 20, height: 30), "rect from two corners")
let reversed = Annotation(tool: .rectangle, color: red, points: [CGPoint(x: 30, y: 40), CGPoint(x: 10, y: 10)])
check(reversed.rect == boxOnly.rect, "rect must not depend on drag direction")

// Editing a finished annotation: what a click hits, moving, and dragging a handle.
do {
    func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
    check(boxOnly.hitTest(at(10, 25), tolerance: 3), "a rectangle is hit on its outline")
    check(boxOnly.hitTest(at(32, 25), tolerance: 3), "a rectangle is hit just outside its outline")
    check(!boxOnly.hitTest(at(20, 25), tolerance: 3), "a rectangle is not hit in its empty middle")
    check(!boxOnly.hitTest(at(50, 25), tolerance: 3), "a rectangle is not hit far away")
    let ring = Annotation(tool: .ellipse, color: red, points: [at(0, 0), at(100, 60)])
    check(ring.hitTest(at(50, 60), tolerance: 3) && ring.hitTest(at(0, 30), tolerance: 3), "an ellipse is hit on its outline")
    check(!ring.hitTest(at(50, 30), tolerance: 3) && !ring.hitTest(at(2, 2), tolerance: 3),
          "an ellipse is not hit in its middle or in the corner of its box")
    let arrow = Annotation(tool: .arrow, color: red, points: [at(0, 0), at(100, 100)])
    check(arrow.hitTest(at(51, 49), tolerance: 3), "an arrow is hit along its line")
    check(!arrow.hitTest(at(80, 20), tolerance: 3), "an arrow is not hit beside its line")
    check(!arrow.hitTest(at(120, 120), tolerance: 3), "an arrow is not hit beyond its end")
    let stroke = Annotation(tool: .pen, color: red, points: [at(0, 0), at(50, 0), at(50, 50)])
    check(stroke.hitTest(at(50, 30), tolerance: 3) && !stroke.hitTest(at(25, 25), tolerance: 3), "a pen stroke is hit on the stroke only")
    let marker = Annotation(tool: .highlight, color: red, points: [at(10, 10), at(60, 30)])
    check(marker.hitTest(at(30, 20), tolerance: 3), "a highlight is hit anywhere inside")
    check(counter.hitTest(at(58, 55), tolerance: 3) && !counter.hitTest(at(80, 50), tolerance: 3), "a counter is hit on its disc")
    let label = Annotation(tool: .text, color: red, points: [at(20, 80)], text: "Hello")
    check(abs(label.bounds.maxY - 80) < 0.001 && label.bounds.minX == 20 && label.bounds.width > 30 && label.bounds.height > 15,
          "text hangs below its anchor, got \(label.bounds)")
    check(label.hitTest(at(30, 70), tolerance: 3) && !label.hitTest(at(30, 90), tolerance: 3), "text is hit on its box")

    check(stroke.moved(by: CGVector(dx: 5, dy: -2)).points == [at(5, -2), at(55, -2), at(55, 48)], "moving shifts every point")

    check(arrow.handles == [at(0, 0), at(100, 100)], "an arrow has a handle at each end")
    check(reversed.handles.count == 4 && Set(reversed.handles.map { "\($0.x),\($0.y)" }) == ["10.0,10.0", "30.0,10.0", "10.0,40.0", "30.0,40.0"],
          "a rectangle has a handle at each corner, got \(reversed.handles)")
    check(stroke.handles.isEmpty && label.handles.isEmpty && counter.handles.isEmpty, "pen, text and counter can only be moved")
    // Dragging a corner moves that corner and leaves the opposite one alone, whichever
    // way the rectangle was first drawn.
    for shape in [boxOnly, reversed] {
        guard let corner = shape.handles.firstIndex(of: at(30, 10)) else { check(false, "corner handle missing"); continue }
        check(shape.movingHandle(corner, to: at(50, 0)).rect == CGRect(x: 10, y: 0, width: 40, height: 40),
              "dragging the bottom-right corner, got \(shape.movingHandle(corner, to: at(50, 0)).rect)")
    }
    check(arrow.movingHandle(1, to: at(40, 10)).points == [at(0, 0), at(40, 10)], "dragging an arrow's head")

    // The move is cut short at the image edge instead of losing the annotation.
    let limit = CGRect(x: 0, y: 0, width: 200, height: 100)
    check(boxOnly.moved(by: CGVector(dx: 500, dy: -500), keepingInside: limit).rect == CGRect(x: 180, y: 0, width: 20, height: 30),
          "a move stops at the image edge")

    // Deleting a counter closes the gap in the numbering.
    var marks = (1...3).map { Annotation(tool: .counter, color: red, points: [at(CGFloat($0) * 10, 10)], text: "\($0)") }
    marks.insert(boxOnly, at: 1)
    marks.remove(at: 0)
    check(Annotation.renumberingCounters(marks).map(\.text) == ["", "1", "2"], "counters are renumbered in order")
}

// MARK: File-backed captures

let storeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("ce-test-store-\(getpid())")
var storedFile: URL?
do {
    let stored = CapturedImage.stored(makeImageData(width: 60, height: 40, dpi: 144, type: .png), in: storeDirectory)
    check(stored != nil, "a capture can be stored in a file")
    storedFile = stored?.fileURL
    check(storedFile?.pathExtension == "png", "PNG data is stored with a .png extension")
    check(storedFile.map { FileManager.default.fileExists(atPath: $0.path) } == true, "the file exists while the capture does")
    check(stored?.pixelSize == CGSize(width: 60, height: 40), "a stored capture reads its size")
    check(stored?.pngData().map(isPNG) == true, "a stored capture still yields PNG data")
}
check(storedFile.map { FileManager.default.fileExists(atPath: $0.path) } == false, "the file is deleted with the capture")
let junk = storeDirectory.appendingPathComponent("junk.png")
try? Data("not an image".utf8).write(to: junk)
check(CapturedImage(owningFile: junk) == nil, "a file that is not an image is rejected")
check(!FileManager.default.fileExists(atPath: junk.path), "a rejected file is deleted too")
try? FileManager.default.removeItem(at: storeDirectory)

// MARK: GIF writer

func solidImage(width: Int, height: Int, red: CGFloat) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: red, green: 0.2, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

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

// MARK: Scroll stitching

/// A tall "page" of pseudo-random rows, viewed through a window with a sticky header
/// and footer, as a scrolling app would show it.
func makeScrollFrame(page: [UInt8], pageRows: Int, width: Int, height: Int, offset: Int,
                     header: Int, footer: Int) -> [UInt8] {
    var frame = [UInt8](repeating: 0, count: width * height * 4)
    for row in 0..<height {
        for column in 0..<width {
            let target = (row * width + column) * 4
            if row < header {
                frame[target] = 200; frame[target + 1] = UInt8(column % 200); frame[target + 2] = 40
            } else if row >= height - footer {
                frame[target] = 30; frame[target + 1] = 90; frame[target + 2] = UInt8((column * 3) % 200)
            } else {
                let source = ((row + offset) * width + column) * 4
                frame[target] = page[source]; frame[target + 1] = page[source + 1]; frame[target + 2] = page[source + 2]
            }
            frame[target + 3] = 255
        }
    }
    return frame
}

do {
    let width = 64, height = 120, pageRows = 760, header = 10, footer = 14
    var seed: UInt64 = 42
    var page = [UInt8](repeating: 255, count: width * pageRows * 4)
    for index in 0..<(width * pageRows) {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        page[index * 4] = UInt8(truncatingIfNeeded: seed >> 33) & 0xFC
        page[index * 4 + 1] = UInt8(truncatingIfNeeded: seed >> 41) & 0xFC
        page[index * 4 + 2] = UInt8(truncatingIfNeeded: seed >> 49) & 0xFC
    }
    let rawURL = FileManager.default.temporaryDirectory.appendingPathComponent("ce-test-stitch-\(getpid()).raw")
    if let stitcher = ScrollStitcher(width: width, height: height, outputURL: rawURL) {
        // What a live preview is told must add up to the finished picture.
        var announcedRows = 0, addedRows = 0, announcedBytes = 0
        stitcher.onRowsAdded = { pixels, rows in
            announcedRows += rows
            addedRows += rows
            announcedBytes += pixels.count
        }
        stitcher.onRowsRemoved = { announcedRows -= $0 }
        func feed(_ offset: Int) -> ScrollStitcher.Outcome {
            let frame = makeScrollFrame(page: page, pageRows: pageRows, width: width, height: height,
                                        offset: offset, header: header, footer: footer)
            return frame.withUnsafeBytes { stitcher.add($0) }
        }
        check(feed(0) == .started, "first frame starts the picture")
        check(feed(0) == .unchanged, "an identical frame changes nothing")
        check(feed(37) == .moved(newRows: 37), "scrolling 37 rows adds 37 rows")
        check(feed(80) == .moved(newRows: 43), "scrolling on adds the difference")
        check(feed(50) == .moved(newRows: 0), "scrolling back adds nothing")
        check(feed(110) == .moved(newRows: 30), "after scrolling back, only rows never seen are added")
        check(feed(600) == .lost, "a jump with no overlap is ignored")
        check(feed(150) == .moved(newRows: 40), "stitching continues from the last good frame")
        let rows = stitcher.finish()
        // Header, then page rows up to the last frame's bottom edge, then the footer once.
        let expectedRows = height + 150
        check(rows == expectedRows, "stitched height should be \(expectedRows), got \(rows)")
        check(announcedRows == expectedRows, "rows announced to a preview, got \(announcedRows)")
        check(announcedBytes == addedRows * width * 4, "the announced rows come with their pixels")
        let raw = [UInt8]((try? Data(contentsOf: rawURL)) ?? Data())
        check(raw.count == expectedRows * width * 4, "raw file holds exactly the stitched rows")
        if raw.count == expectedRows * width * 4 {
            var wrong = 0
            for row in header..<(expectedRows - footer) {
                // Stitched row r (below the header) is page row r.
                for column in stride(from: 0, to: width, by: 7) {
                    let a = (row * width + column) * 4
                    if raw[a] != page[a] || raw[a + 1] != page[a + 1] || raw[a + 2] != page[a + 2] { wrong += 1 }
                }
            }
            check(wrong == 0, "stitched body must equal the page, \(wrong) samples differ")
            let lastRow = (expectedRows - 1) * width * 4
            check(raw[lastRow] == 30 && raw[lastRow + 1] == 90, "the footer is added once at the end")
            let footerStart = (expectedRows - footer - 1) * width * 4
            check(raw[footerStart] != 30 || raw[footerStart + 1] != 90, "no footer copies inside the body")
        }
    } else { check(false, "stitcher should open its output file") }
    try? FileManager.default.removeItem(at: rawURL)
}

// A region where much stays put: a tall sticky header and footer and a sidebar whose
// content does not scroll. The movement of the rest must still be found.
do {
    let width = 240, height = 200, pageRows = 900, header = 60, footer = 40, sidebar = 70
    var seed: UInt64 = 7
    func random() -> UInt8 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return UInt8(truncatingIfNeeded: seed >> 40)
    }
    var page = [UInt8](repeating: 255, count: width * pageRows * 4)
    for index in 0..<(width * pageRows) { for channel in 0..<3 { page[index * 4 + channel] = random() } }
    var chrome = [UInt8](repeating: 255, count: width * height * 4)   // what does not scroll
    for index in 0..<(width * height) { for channel in 0..<3 { chrome[index * 4 + channel] = random() } }
    func frame(_ offset: Int) -> [UInt8] {
        var out = chrome
        for row in header..<(height - footer) {
            for column in sidebar..<width {
                let target = (row * width + column) * 4, source = ((row + offset) * width + column) * 4
                for channel in 0..<3 { out[target + channel] = page[source + channel] }
            }
        }
        return out
    }
    func motion(_ from: Int, _ to: Int) -> ScrollStitcher.Motion? {
        let a = frame(from), b = frame(to)
        let old = a.withUnsafeBytes { ScrollStitcher.rowFeatures($0, width: width, height: height) }
        let new = b.withUnsafeBytes { ScrollStitcher.rowFeatures($0, width: width, height: height) }
        return ScrollStitcher.motion(from: old, to: new)
    }
    let down = motion(100, 130)
    check(down?.shift == 30, "movement is found despite static parts, got \(String(describing: down))")
    check(down?.header == header && down?.footer == footer, "sticky bars are measured, got \(String(describing: down))")
    check(motion(130, 85)?.shift == -45, "scrolling back is found too")
    check(motion(100, 100)?.shift == 0, "no movement is reported as none")
    check(motion(100, 170)?.shift == 70, "a move of most of the scrolling part is still found")
    check(motion(100, 400) == nil, "a jump beyond the scrolling part is reported as lost")
}

// Text on a dark background, as in a terminal: low contrast, lines that look much
// alike, a title bar and a status bar that stay put (the status bar holding a clock
// that changes), and the faint pixel noise real captures have.
do {
    let width = 600, height = 400, lineHeight = 26, lines = 60, header = 30, footer = 50
    var seed: UInt64 = 99
    func random(_ bound: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int((seed >> 33) % UInt64(bound))
    }
    // glyphs[line][cell]: whether a character is drawn there, and how bright its strokes are.
    let cells = width / 10
    var glyphs = [[Int]](repeating: [Int](repeating: 0, count: cells), count: lines)
    for line in 0..<lines {
        let length = 10 + random(cells - 10)
        for cell in 0..<length where random(10) < 8 { glyphs[line][cell] = 120 + random(100) }
    }
    func frame(_ offset: Int, clock: Int) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                var value = 22
                if row < header {
                    value = (column / 10 + row / 6) % 5 == 0 ? 90 : 40
                } else if row >= height - footer {
                    value = (column / 14 + row / 5) % 4 == 0 ? 110 : 30
                    if column > 400, column < 440, (row + clock) % 7 < 3 { value = 200 }
                } else {
                    let y = row - header + offset
                    let line = y / lineHeight, within = y % lineHeight
                    let brightness = glyphs[line][column / 10]
                    // Strokes cover part of the cell and part of the line's height.
                    if brightness > 0, within >= 6, within < 20, (column % 10) < 6, (column + within * 3 + line) % 3 != 0 {
                        value = brightness
                    }
                }
                value += random(3) - 1
                let target = (row * width + column) * 4
                out[target] = UInt8(value); out[target + 1] = UInt8(value); out[target + 2] = UInt8(value)
            }
        }
        return out
    }
    func motion(_ from: Int, _ to: Int, clock: Int = 1) -> ScrollStitcher.Motion? {
        let a = frame(from, clock: 0), b = frame(to, clock: clock)
        let old = a.withUnsafeBytes { ScrollStitcher.rowFeatures($0, width: width, height: height) }
        let new = b.withUnsafeBytes { ScrollStitcher.rowFeatures($0, width: width, height: height) }
        return ScrollStitcher.motion(from: old, to: new)
    }
    for (from, to) in [(100, 126), (100, 113), (100, 107), (100, 230), (300, 222), (100, 340)] {
        let found = motion(from, to)
        check(found?.shift == to - from, "terminal-like text: move of \(to - from) rows, got \(String(describing: found))")
    }
    check(motion(100, 100)?.shift == 0, "a changing clock alone is not movement, got \(String(describing: motion(100, 100)))")
    check(motion(100, 100, clock: 0)?.shift == 0, "identical content with capture noise is not movement")
    let bars = motion(100, 152)
    // Blank rows next to a bar cannot be told from the bar, so up to a line more is fine.
    check(bars.map { $0.header >= header && $0.header <= header + lineHeight
                     && $0.footer >= footer && $0.footer <= footer + lineHeight } == true,
          "title and status bars are measured, got \(String(describing: bars))")
}

// Text recognition: fragments are put back into reading order, one line per row.
do {
    typealias Fragment = TextRecognizer.Fragment
    // Boxes are normalised with the origin at the bottom-left, as Vision reports them.
    let table = [
        Fragment(text: "42", box: CGRect(x: 0.6, y: 0.50, width: 0.1, height: 0.1)),
        Fragment(text: "Total", box: CGRect(x: 0.1, y: 0.51, width: 0.2, height: 0.1)),
        Fragment(text: "Name  Count", box: CGRect(x: 0.1, y: 0.80, width: 0.6, height: 0.1)),
        Fragment(text: "last line", box: CGRect(x: 0.1, y: 0.10, width: 0.4, height: 0.1))
    ]
    check(TextRecognizer.assemble(table) == "Name  Count\nTotal 42\nlast line",
          "fragments in reading order, got \(TextRecognizer.assemble(table).debugDescription)")
    check(TextRecognizer.assemble([]) == "", "no fragments give no text")
    // A tall fragment beside two short lines must not swallow both into one row.
    let stacked = [
        Fragment(text: "a", box: CGRect(x: 0.1, y: 0.60, width: 0.2, height: 0.05)),
        Fragment(text: "b", box: CGRect(x: 0.1, y: 0.52, width: 0.2, height: 0.05))
    ]
    check(TextRecognizer.assemble(stacked) == "a\nb", "lines close together stay separate")

    // End to end with the system recogniser, on the picture the warm-up reads: it must
    // hold English and Chinese, so that warming up prepares what a real reading needs.
    let picture = TextRecognizer.warmUpPicture()
    let expected = "Hello Capture 2026\n滚动长截图与文字识别"
    let direct = (try? TextRecognizer.recognize(picture)) ?? "<failed>"
    check(direct == expected, "warm-up picture recognised, got \(direct.debugDescription)")
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("ce-ocr-test-\(UUID().uuidString).png")
    try! NSBitmapImageRep(cgImage: picture).representation(using: .png, properties: [:])!.write(to: file)
    let text = (try? TextRecognizer.recognize(imageAt: file)) ?? "<failed>"
    try? FileManager.default.removeItem(at: file)
    check(text == expected, "recognised text from a file, got \(text.debugDescription)")
}

// A see-through bar over the page (Safari's tool bar on macOS 26): the page shows through
// it blurred, so its rows change with every scroll yet do not move. The movement of the
// page under and below it must still be found.
do {
    let width = 256, height = 400, pageRows = 1200, bar = 40
    // A web page: white, with lines of dark words.
    var page = [UInt8](repeating: 255, count: width * pageRows)
    var seed: UInt64 = 7
    for line in 0..<(pageRows / 24) {
        let words = (0..<(width / 8)).map { _ -> Bool in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (seed >> 40) % 3 != 0
        }
        // Lines differ in length, as text does.
        let length = 8 + Int((seed >> 20) % UInt64(width / 8 - 8))
        for row in (line * 24 + 6)..<(line * 24 + 16) {
            for column in 0..<width where column / 8 < length && words[column / 8] { page[row * width + column] = 40 }
        }
    }
    func frame(_ offset: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                var value = Int(page[(row + offset) * width + column])
                if row < bar {
                    // Dark glass: what lies under it, blurred up and down, at a fifth of its contrast.
                    var sum = 0
                    for near in -6...6 { sum += Int(page[max(0, row + offset + near) * width + column]) }
                    value = 50 + sum / 13 / 5
                }
                let target = (row * width + column) * 4
                pixels[target] = UInt8(value); pixels[target + 1] = UInt8(value); pixels[target + 2] = UInt8(value)
            }
        }
        return pixels
    }
    func motion(_ from: Int, _ to: Int) -> ScrollStitcher.Motion? {
        let a = frame(from), b = frame(to)
        let old = a.withUnsafeBytes { ScrollStitcher.rowFeatures($0, width: width, height: height) }
        let new = b.withUnsafeBytes { ScrollStitcher.rowFeatures($0, width: width, height: height) }
        return ScrollStitcher.motion(from: old, to: new)
    }
    check(motion(0, 30)?.shift == 30, "30 rows under a see-through bar, got \(String(describing: motion(0, 30)))")
    check(motion(30, 85)?.shift == 55, "55 rows under a see-through bar, got \(String(describing: motion(30, 85)))")
    check(motion(85, 60)?.shift == -25, "back up under a see-through bar, got \(String(describing: motion(85, 60)))")
    check(motion(60, 60)?.shift == 0, "not moving under a see-through bar")
    check(motion(0, 700) == nil, "a jump with no overlap is still lost")
}

// A see-through bar at the bottom of the region (a floating tool bar, a tab bar, a chat
// box): the page shows through it blurred. It must not be stitched into the picture as
// if it were page; it belongs at the very end, once.
do {
    let width = 256, height = 400, pageRows = 1400, bar = 40
    /// A white page with lines of dark words from `firstLine` on; `gap` leaves a range of rows empty.
    func makePage(gap: Range<Int>) -> [UInt8] {
        var page = [UInt8](repeating: 255, count: width * pageRows)
        var seed: UInt64 = 11
        for line in 0..<(pageRows / 24) {
            let words = (0..<(width / 8)).map { _ -> Bool in
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return (seed >> 40) % 3 != 0
            }
            let length = 8 + Int((seed >> 20) % UInt64(width / 8 - 8))
            // Every row of a line differs a little from the one above, as letters do.
            for row in (line * 24 + 6)..<(line * 24 + 16) where !gap.contains(row) {
                for column in 0..<width where column / 8 < length && words[column / 8] {
                    page[row * width + column] = UInt8(40 + (row % 5) * 6)
                }
            }
        }
        return page
    }
    /// One frame. The bar covers `columns` of the bottom rows, `lift` rows above the
    /// edge; `tint` darkens it (0 leaves only the blur, 100 makes it solid).
    func frame(_ page: [UInt8], _ offset: Int, columns: Range<Int>, lift: Int, tint: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                var value = Int(page[(row + offset) * width + column])
                if row >= height - bar - lift, row < height - lift, columns.contains(column) {
                    var sum = 0
                    for near in -6...6 { sum += Int(page[(row + offset + near) * width + column]) }
                    value = tint == 100 ? 90 : sum / 13 - tint * (sum / 13) / 100
                }
                let target = (row * width + column) * 4
                pixels[target] = UInt8(value); pixels[target + 1] = UInt8(value); pixels[target + 2] = UInt8(value)
            }
        }
        return pixels
    }
    /// Scrolls down in steps, finishes, and says how the picture differs from the page
    /// above where the bar sits at the end.
    func stitch(_ name: String, page: [UInt8], columns: Range<Int>, lift: Int, tint: Int) {
        let rawURL = FileManager.default.temporaryDirectory.appendingPathComponent("ce-test-bar-\(getpid()).raw")
        defer { try? FileManager.default.removeItem(at: rawURL) }
        guard let stitcher = ScrollStitcher(width: width, height: height, outputURL: rawURL) else {
            check(false, "\(name): stitcher was not created")
            return
        }
        var removed = 0
        stitcher.onRowsRemoved = { removed += $0 }
        let offsets = stride(from: 0, through: 690, by: 30)
        for offset in offsets {
            let outcome = frame(page, offset, columns: columns, lift: lift, tint: tint).withUnsafeBytes { stitcher.add($0) }
            check(outcome != .lost, "\(name): lost at \(offset)")
        }
        let rows = stitcher.finish()
        check(rows == height + 690, "\(name): height \(rows), expected \(height + 690)")
        let raw = [UInt8]((try? Data(contentsOf: rawURL)) ?? Data())
        guard raw.count == rows * width * 4, rows == height + 690 else { return }
        var wrongRows = 0
        for row in 0..<(rows - bar - lift) {
            for column in 0..<width where raw[(row * width + column) * 4] != page[row * width + column] {
                wrongRows += 1
                break
            }
        }
        check(wrongRows == 0, "\(name): \(wrongRows) rows of the picture are not the page")
        check(removed > 0, "\(name): the bar's rows were taken back out")
    }
    let text = makePage(gap: 0..<0)
    stitch("dark glass bar", page: text, columns: 0..<width, lift: 0, tint: 60)
    stitch("clear glass bar", page: text, columns: 0..<width, lift: 0, tint: 0)
    stitch("floating pill", page: text, columns: 70..<190, lift: 12, tint: 60)
    // Nothing under the bar at first: it cannot be seen until text passes beneath it.
    stitch("clear bar over an empty stretch", page: makePage(gap: 250..<520), columns: 0..<width, lift: 0, tint: 0)
    // Something small in a corner, at the very edge where rows are not even compared.
    stitch("button in the corner", page: text, columns: 232..<252, lift: 10, tint: 100)
    stitch("glass button in the corner", page: text, columns: 4..<30, lift: 10, tint: 50)

    // Stopping after scrolling back up: the end of the picture is still the lowest point reached.
    let rawURL = FileManager.default.temporaryDirectory.appendingPathComponent("ce-test-back-\(getpid()).raw")
    if let stitcher = ScrollStitcher(width: width, height: height, outputURL: rawURL) {
        for offset in [0, 30, 60, 90, 120, 90, 60] {
            _ = frame(text, offset, columns: 0..<width, lift: 0, tint: 60).withUnsafeBytes { stitcher.add($0) }
        }
        let rows = stitcher.finish()
        let raw = [UInt8]((try? Data(contentsOf: rawURL)) ?? Data())
        check(rows == height + 120, "after scrolling back: height \(rows), expected \(height + 120)")
        if raw.count == rows * width * 4, rows == height + 120 {
            let wrong = (0..<(rows - bar)).filter { row in
                (0..<width).contains { raw[(row * width + $0) * 4] != text[row * width + $0] }
            }.count
            check(wrong == 0, "after scrolling back: \(wrong) rows are not the page")
        }
    } else { check(false, "stitcher was not created") }
    try? FileManager.default.removeItem(at: rawURL)

    // A see-through strip down one side (a glass sidebar over the page): it changes with
    // every scroll and does not move. The movement beside it must still be found.
    func sideFrame(_ offset: Int) -> [UInt8] {
        var pixels = frame(text, offset, columns: 0..<0, lift: 0, tint: 0)
        for row in 0..<height {
            for column in 0..<72 {
                var sum = 0
                for near in -6...6 { sum += Int(text[max(0, row + offset + near) * width + column]) }
                let value = UInt8(40 + sum / 13 / 4)
                let target = (row * width + column) * 4
                pixels[target] = value; pixels[target + 1] = value; pixels[target + 2] = value
            }
        }
        return pixels
    }
    func sideMotion(_ from: Int, _ to: Int) -> ScrollStitcher.Motion? {
        let a = sideFrame(from), b = sideFrame(to)
        let old = a.withUnsafeBytes { ScrollStitcher.rowFeatures($0, width: width, height: height) }
        let new = b.withUnsafeBytes { ScrollStitcher.rowFeatures($0, width: width, height: height) }
        return ScrollStitcher.motion(from: old, to: new)
    }
    check(sideMotion(0, 30)?.shift == 30, "beside a see-through strip, got \(String(describing: sideMotion(0, 30)))")
    check(sideMotion(60, 20)?.shift == -40, "back up beside a see-through strip, got \(String(describing: sideMotion(60, 20)))")
    check(sideMotion(0, 700) == nil, "a jump beside a see-through strip is still lost")
}

// The live preview of a scrolling capture: a narrow copy of the newest part of the picture.
do {
    func rows(_ count: Int, _ red: UInt8, _ blue: UInt8) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: 100 * count * 4)
        for index in 0..<(100 * count) {
            pixels[index * 4] = red
            pixels[index * 4 + 1] = 0
            pixels[index * 4 + 2] = blue
        }
        return pixels
    }
    /// The colour at the middle of a row of the preview, counted from its bottom.
    func colour(_ strip: ScrollPreviewStrip, rowFromBottom: Int) -> (red: UInt8, blue: UInt8)? {
        guard let image = strip.image() else { return nil }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let offset = ((image.height - 1 - rowFromBottom) * image.width + image.width / 2) * 4
        return (bytes[offset], bytes[offset + 2])
    }
    if let strip = ScrollPreviewStrip(sourceWidth: 100, width: 50, height: 40) {
        check(strip.image() == nil, "nothing to show before the first rows")
        rows(20, 255, 0).withUnsafeBytes { strip.append($0, rows: 20) }
        check(strip.image()?.height == 10 && strip.image()?.width == 50, "20 rows at half size are 10, got \(strip.image()?.height ?? -1)")
        rows(20, 0, 255).withUnsafeBytes { strip.append($0, rows: 20) }
        check(strip.image()?.height == 20, "the preview grows with the picture")
        if let bottom = colour(strip, rowFromBottom: 2), let top = colour(strip, rowFromBottom: 17) {
            check(bottom.blue > 200 && bottom.red < 50, "the newest rows are at the bottom, got \(bottom)")
            check(top.red > 200 && top.blue < 50, "older rows above them, got \(top)")
        } else { check(false, "no preview picture") }
        // The stitcher takes back the first frame's footer once it knows there is one.
        strip.removeLast(rows: 20)
        check(strip.image()?.height == 10, "removed rows leave the preview")
        check((colour(strip, rowFromBottom: 2)?.red ?? 0) > 200, "what was above them is at the bottom again")
        // Once it is full the preview keeps the newest part only.
        rows(200, 0, 255).withUnsafeBytes { strip.append($0, rows: 200) }
        check(strip.image()?.height == 40, "never taller than its room, got \(strip.image()?.height ?? -1)")
        check((colour(strip, rowFromBottom: 38)?.blue ?? 0) > 200, "the oldest part has scrolled away")
    } else { check(false, "preview strip was not created") }
    // Additions that end inside a preview row leave no dark line between them.
    if let strip = ScrollPreviewStrip(sourceWidth: 100, width: 30, height: 40) {
        for _ in 0..<12 { rows(7, 255, 255).withUnsafeBytes { strip.append($0, rows: 7) } }
        let height = strip.image()?.height ?? 0
        check(height == 25, "84 rows at three tenths, got \(height)")
        check((0..<height).allSatisfy { (colour(strip, rowFromBottom: $0)?.red ?? 0) > 240 }, "no seams between additions")
    } else { check(false, "preview strip was not created") }

    // Where the preview goes: right of the region, left when there is no room, else nowhere.
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let right = ScrollPreviewLayout.frame(beside: CGRect(x: 300, y: 200, width: 600, height: 400), in: screen)
    check(right == CGRect(x: 912, y: 200, width: 160, height: 400), "right of the region, got \(String(describing: right))")
    let left = ScrollPreviewLayout.frame(beside: CGRect(x: 800, y: 200, width: 600, height: 400), in: screen)
    check(left == CGRect(x: 628, y: 200, width: 160, height: 400), "left of it, got \(String(describing: left))")
    check(ScrollPreviewLayout.frame(beside: CGRect(x: 60, y: 200, width: 1320, height: 400), in: screen) == nil,
          "no room on either side: no preview")
}

// File names from the user's pattern, and a free place for them in the folder.
do {
    var parts = DateComponents()
    parts.year = 2026; parts.month = 11; parts.day = 13; parts.hour = 17; parts.minute = 4; parts.second = 9
    let date = Calendar.current.date(from: parts)!
    check(FileNaming.name(format: "Screenshot %Y-%m-%d at %H.%M.%S", date: date, fallback: "x")
            == "Screenshot 2026-11-13 at 17.04.09", "the default pattern")
    check(FileNaming.name(format: "截图 %m%d", date: date, fallback: "x") == "截图 1113", "words around the date stay as they are")
    // A name cannot hold what would be taken for a folder or, in Finder, shown as one.
    check(FileNaming.name(format: "a/b:c %H:%M", date: date, fallback: "x") == "a-b-c 17-04", "no slashes or colons")
    check(FileNaming.name(format: "   ", date: date, fallback: "Screenshot %Y") == "Screenshot 2026", "an empty pattern gives the default")
    check(FileNaming.name(format: ".hidden", date: date, fallback: "x") == "hidden", "never a hidden file")

    let folder = URL(fileURLWithPath: "/tmp/ce-names", isDirectory: true)
    let taken: Set<String> = ["Shot.png", "Shot 2.png"]
    let free = FileNaming.available("Shot", extension: "png", in: folder) { taken.contains($0.lastPathComponent) }
    check(free.lastPathComponent == "Shot 3.png", "a taken name gets the next number, got \(free.lastPathComponent)")
    let first = FileNaming.available("New", extension: "mp4", in: folder) { taken.contains($0.lastPathComponent) }
    check(first.path == "/tmp/ce-names/New.mp4", "a free name stays as it is, got \(first.path)")

    // How long a preview stays: seconds, 0 for until it is closed. The earlier on/off
    // setting meant ten seconds.
    check(PreviewTiming.closeAfter(stored: nil, earlier: nil) == 0, "previews stay by default")
    check(PreviewTiming.closeAfter(stored: nil, earlier: true) == 10, "the earlier setting carries over")
    check(PreviewTiming.closeAfter(stored: 30, earlier: true) == 30, "the stored time wins")
    check(PreviewTiming.closeAfter(stored: -5, earlier: nil) == 0, "never negative")
    check(PreviewTiming.choices(including: 10) == [0, 5, 10, 30, 60], "the times offered")
    check(PreviewTiming.choices(including: 20) == [0, 5, 10, 20, 30, 60], "a time set by hand is offered too")
}

// Editor zoom: fixed steps for the button and the keys, limits for the pinch.
check(EditorZoom.stepIn(from: 1) == 2 && EditorZoom.stepIn(from: 1.5) == 2, "zooming in goes to the next step")
check(EditorZoom.stepIn(from: 8) == 8, "no step beyond the largest")
check(EditorZoom.stepOut(from: 8) == 4 && EditorZoom.stepOut(from: 1.5) == 1, "zooming out goes to the step below")
check(EditorZoom.stepOut(from: 1) == 1, "never smaller than the whole picture")
check(EditorZoom.clamped(0.3) == 1 && EditorZoom.clamped(20) == 8 && EditorZoom.clamped(3) == 3, "zoom limits")

// Shortcuts: how they are shown, kept in the preferences, and checked against the system's.
do {
    let area = Shortcut(keyCode: 21, modifiers: UInt32(shiftKey | cmdKey), key: "4")
    check(area.display == "⇧⌘4", "display, got \(area.display)")
    let all = Shortcut(keyCode: 1, modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey), key: "s")
    check(all.display == "⌃⌥⇧⌘S", "modifiers in the system's order and the key in capitals, got \(all.display)")
    // Keys that print nothing are named by their key code, whatever the event reported.
    check(Shortcut(keyCode: 49, modifiers: UInt32(controlKey), key: " ").display == "⌃Space", "space bar")
    check(Shortcut(keyCode: 122, modifiers: 0, key: "\u{F704}").display == "F1", "function key")

    check(Shortcut(stored: area.stored) == area, "a stored shortcut reads back, stored as \(area.stored)")
    let comma = Shortcut(keyCode: 43, modifiers: UInt32(cmdKey), key: ",")
    check(Shortcut(stored: comma.stored) == comma, "a comma key survives storing, stored as \(comma.stored)")
    check(Shortcut(stored: "") == nil && Shortcut(stored: "x,1,a") == nil, "garbage is not a shortcut")

    // A global shortcut needs ⌘, ⌃ or ⌥: a letter alone or with Shift would swallow typing.
    check(area.isUsable, "⇧⌘4 is usable")
    check(!Shortcut(keyCode: 1, modifiers: UInt32(shiftKey), key: "s").isUsable, "⇧S is not usable")
    check(!Shortcut(keyCode: 1, modifiers: 0, key: "s").isUsable, "S alone is not usable")
    check(Shortcut(keyCode: 122, modifiers: 0, key: "").isUsable, "a function key alone is usable")

    // The modifiers AppKit reports for a key press, and the ones a menu item wants.
    let pressed = Shortcut(keyCode: 21, flags: [.shift, .command, .capsLock, .numericPad], key: "4")
    check(pressed == area, "AppKit flags become Carbon modifiers, extras ignored")
    check(area.menuModifiers == [.shift, .command] && area.menuKey == "4", "menu item for ⇧⌘4")
    check(all.menuKey == "s", "menu keys are lower case, got \(all.menuKey)")

    // The system's own shortcuts win while they are switched on.
    let system = [SystemHotKey(keyCode: 21, modifiers: UInt32(shiftKey | cmdKey), enabled: true),
                  SystemHotKey(keyCode: 20, modifiers: UInt32(shiftKey | cmdKey), enabled: false)]
    check(area.isTaken(by: system), "⇧⌘4 is taken while the system's is on")
    check(!Shortcut(keyCode: 20, modifiers: UInt32(shiftKey | cmdKey), key: "3").isTaken(by: system),
          "⇧⌘3 is free once the system's is off")
    check(!Shortcut(keyCode: 21, modifiers: UInt32(cmdKey), key: "4").isTaken(by: system), "⌘4 is another shortcut")
    check(!SystemHotKey.current().isEmpty, "the system reports its shortcuts")

    // Defaults are the system's screenshot shortcuts; the other actions start without one.
    check(ShortcutAction.area.defaultShortcut?.display == "⇧⌘4", "default for an area")
    check(ShortcutAction.screen.defaultShortcut?.display == "⇧⌘3", "default for the screen")
    check(ShortcutAction.panel.defaultShortcut?.display == "⇧⌘5", "default for the Quick Panel")
    check(ShortcutAction.record.defaultShortcut == nil, "recording has no default")
    // The welcome window asks for the system's to be switched off while any shortcut in use is taken.
    let systemOn = [SystemHotKey(keyCode: 21, modifiers: UInt32(shiftKey | cmdKey), enabled: true)]
    let systemOff = [SystemHotKey(keyCode: 21, modifiers: UInt32(shiftKey | cmdKey), enabled: false)]
    let defaults = [ShortcutAction.area: area]
    check(ShortcutAction.anyTaken(defaults, by: systemOn), "⇧⌘4 is taken while the system's is on")
    check(!ShortcutAction.anyTaken(defaults, by: systemOff), "and free once it is off")
    check(!ShortcutAction.anyTaken([.area: Shortcut(keyCode: 21, modifiers: UInt32(cmdKey | optionKey), key: "4")], by: systemOn),
          "a shortcut of one's own is free")
    check(Set(ShortcutAction.allCases.map(\.hotKeyID)).count == ShortcutAction.allCases.count, "distinct hot key ids")

    // One shortcut belongs to one action: giving it to another takes it from the first.
    var table: [ShortcutAction: Shortcut] = [.area: area, .screen: all]
    table = ShortcutAction.assigning(area, to: .record, in: table)
    check(table[.record] == area && table[.area] == nil && table[.screen] == all, "moved to the new action")
    table = ShortcutAction.assigning(nil, to: .screen, in: table)
    check(table[.screen] == nil && table[.record] == area, "cleared")

    // What the preferences hold: nothing means the default, an empty text means none.
    check(ShortcutAction.area.shortcut(fromStored: nil) == ShortcutAction.area.defaultShortcut, "unset: default")
    check(ShortcutAction.area.shortcut(fromStored: "") == nil, "empty: no shortcut")
    check(ShortcutAction.record.shortcut(fromStored: area.stored) == area, "stored: that shortcut")
}

// The largest a recording may grow, and how long that lasts on a given screen.
do {
    check(RecordingSize.gigabytes(stored: nil) == RecordingSize.defaultGigabytes, "unset: the default")
    check(RecordingSize.gigabytes(stored: 0) == 1 && RecordingSize.gigabytes(stored: -3) == 1, "at least 1 GB")
    check(RecordingSize.gigabytes(stored: 5000) == 1000, "at most 1000 GB")
    check(RecordingSize.gigabytes(stored: 20) == 20, "a stored size is kept")
    check(RecordingSize.bytes(gigabytes: 10) == 10_000_000_000, "GB as Finder counts them")
    // Measured on a 3840 x 2160 screen: 10 GB lasts about 43 minutes of constant motion
    // and about 277 minutes of a still screen.
    let span = RecordingSize.minutes(gigabytes: 10, pixels: 3840 * 2160)
    check(span.shortest == 43 && span.longest == 277, "10 GB at 4K, got \(span)")
    let small = RecordingSize.minutes(gigabytes: 10, pixels: 1440 * 900)
    check(small.shortest > span.shortest * 6, "a smaller screen lasts longer, got \(small)")
}

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

// A stored capture is the very file a drag hands over: a PNG under its readable name,
// in a folder of its own, gone with the capture; a dragged-out one lingers a while.
do {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kamira-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    var capture = CapturedImage.stored(retinaPNG, in: folder)
    let file = capture?.fileURL
    check(file?.lastPathComponent == capture?.suggestedFileName, "named as it will be dragged, got \(file?.lastPathComponent ?? "nil")")
    check(file?.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL,
          "in a folder of its own inside the capture folder")
    let tiff = CapturedImage.stored(makeImageData(width: 30, height: 20, dpi: 72, type: .tiff), in: folder)
    check(tiff?.fileURL?.pathExtension == "png" && (try? Data(contentsOf: tiff!.fileURL!)).map(isPNG) == true,
          "a TIFF is stored as PNG")
    capture = nil
    check(file.map { !FileManager.default.fileExists(atPath: $0.path) } == true, "the file goes with the capture")
    check(file.map { !FileManager.default.fileExists(atPath: $0.deletingLastPathComponent().path) } == true, "and its folder")

    CapturedImage.dragGrace = 0.2
    var dragged = CapturedImage.stored(retinaPNG, in: folder)
    let draggedFile = dragged!.fileURL!
    dragged?.wasDraggedOut = true
    dragged = nil
    check(FileManager.default.fileExists(atPath: draggedFile.path), "a dragged-out file outlives its capture for a while")
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    check(!FileManager.default.fileExists(atPath: draggedFile.path), "and is gone after the grace period")
}

// Updates: the three choices in Settings are Sparkle's two flags, and back.
for policy in UpdatePolicy.allCases {
    check(UpdatePolicy(checks: policy.checks, installs: policy.installs) == policy, "\(policy) survives Sparkle's flags")
}
check(!UpdatePolicy.manual.checks && !UpdatePolicy.manual.installs, "manual neither checks nor installs")
check(UpdatePolicy.ask.checks && !UpdatePolicy.ask.installs, "ask checks, then asks")
check(UpdatePolicy.automatic.checks && UpdatePolicy.automatic.installs, "automatic checks and installs")
check(UpdatePolicy(checks: false, installs: true) == .manual, "no checks means manual, whatever else is stored")
check(UpdatePolicy.interval(nearest: 86_400) == 86_400, "a day stays a day")
check(UpdatePolicy.interval(nearest: 3_600) == 86_400, "an hour shows as a day")
check(UpdatePolicy.interval(nearest: 700_000) == 604_800, "about a week shows as a week")
check(UpdatePolicy.interval(nearest: 10_000_000) == 2_592_000, "longer than a month shows as a month")

print(failures == 0 ? "All tests passed." : "\(failures) test(s) failed.")
exit(failures == 0 ? 0 : 1)
