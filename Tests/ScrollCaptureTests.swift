import AppKit

/// A tall "page" of pseudo-random rows, viewed through a window with a sticky header
/// and footer, as a scrolling app would show it.
private func makeScrollFrame(page: [UInt8], pageRows: Int, width: Int, height: Int, offset: Int,
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

/// Scrolling capture: stitching and its live preview (Sources/ScrollCapture/).
func testScrollCapture() {
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
}
