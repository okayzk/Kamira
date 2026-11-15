import Foundation

/// Joins successive pictures of the same screen region, taken while its content is being
/// scrolled, into one tall picture.
///
/// Each frame is compared with the previous one row by row to find how far the content
/// moved; only the rows that have newly come into view are added. Scrolling back up is
/// followed without adding anything. A bar that stays put at the bottom of the region
/// (a sticky footer, or a floating bar the page shows through) is left out while
/// scrolling and added once at the end; one at the top is naturally kept from the first
/// frame only.
///
/// The picture is written straight to `outputURL` as raw RGBA rows, so memory use does
/// not grow with its height.
final class ScrollStitcher {
    enum Outcome: Equatable {
        /// The first frame, taken whole.
        case started
        /// Nothing moved.
        case unchanged
        /// The content moved; `newRows` rows were added (0 when scrolling back).
        case moved(newRows: Int)
        /// No overlap with the previous frame could be found; the frame was ignored.
        case lost
    }

    let width: Int
    let height: Int
    /// Rows written so far, not counting a footer still to be added by `finish()`.
    private(set) var writtenRows = 0
    /// Height the finished picture would have right now.
    var totalRows: Int { writtenRows + (footer ?? 0) }

    /// For a live preview: called with rows as they are added to the picture (their
    /// pixels are only valid during the call), and when rows are taken back again.
    var onRowsAdded: ((UnsafeRawBufferPointer, Int) -> Void)?
    var onRowsRemoved: ((Int) -> Void)?

    private let handle: FileHandle
    private let maxRows: Int
    private var lastRows = RowFeatures(values: [], count: 0)
    private var lastPixels = Data()
    /// The bottom third of the frame taken at the lowest point reached, and where that
    /// frame sat: the end of the picture comes from here, also after scrolling back up.
    private var deepestTail = Data()
    private var deepest = -1
    /// The most rows the footer may take.
    private var footerLimit: Int { height / 3 }
    /// Where the top of the latest frame sits in the stitched picture.
    private var position = 0
    /// Height of the part at the bottom that is kept out of the picture until the end,
    /// because something there does not scroll; unknown until the first move. It only
    /// grows: a bar the page shows through can look like page until text passes under it.
    private var footer: Int?

    /// `width` and `height` are the frame size in pixels; frames are RGBA, 4 bytes per pixel.
    init?(width: Int, height: Int, outputURL: URL, maxRows: Int = 60_000) {
        guard width > 0, height > 0, FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: outputURL) else { return nil }
        self.width = width
        self.height = height
        self.handle = handle
        self.maxRows = maxRows
    }

    func add(_ pixels: UnsafeRawBufferPointer) -> Outcome {
        guard pixels.count >= width * height * 4 else { return .lost }
        let rows = Self.rowFeatures(pixels, width: width, height: height)
        guard lastRows.count > 0 else {
            write(pixels, rows: 0..<height)
            rememberTail(pixels)
            remember(rows, pixels)
            return .started
        }
        guard let motion = Self.motion(from: lastRows, to: rows) else { return .lost }
        let shift = motion.shift
        // The frame to compare against stays the same until real movement is seen, so
        // that very slow scrolling adds up instead of being lost a row at a time.
        if shift == 0 { return .unchanged }
        // The footer is whatever at the bottom does not scroll with the page: a bar that
        // stayed the same, or anything the pixels show did not move along (a floating
        // bar the page shows through, a button in a corner). It only grows.
        let fixed = max(footer ?? 0, motion.footer, unmovedBottom(pixels, shift: shift))
        // Rows at the end of the picture were written while they stood where the footer is
        // now known to be (the whole first frame, or a bar noticed only now): take them
        // back. The page they belong to is written again once it has risen above the bar.
        let grown = min(fixed - (footer ?? 0), writtenRows)
        footer = fixed
        if grown > 0 {
            writtenRows -= grown
            onRowsRemoved?(grown)
            try? handle.truncate(atOffset: UInt64(writtenRows * width * 4))
            _ = try? handle.seekToEnd()
        }
        let previous = position
        position += shift
        var added = 0
        // Rows that passed the footer and the top edge in one step were never above the
        // bar in any frame: they come from under it in the previous one, rather than
        // leaving a hole.
        if position > writtenRows, writtenRows < maxRows, lastPixels.count == width * height * 4 {
            let range = (writtenRows - previous)..<min(position - previous, height)
            if range.lowerBound >= 0, !range.isEmpty {
                lastPixels.withUnsafeBytes { write($0, rows: range) }
                added += range.count
            }
        }
        let visibleBottom = position + height - fixed
        if visibleBottom > writtenRows, writtenRows < maxRows {
            let first = max(0, writtenRows - position)
            let last = min(height - fixed, first + (maxRows - writtenRows))
            if first < last {
                write(pixels, rows: first..<last)
                added += last - first
            }
        }
        if position >= deepest { rememberTail(pixels) }
        remember(rows, pixels)
        return .moved(newRows: added)
    }

    /// Adds the footer and closes the file. Returns the height of the picture in rows.
    func finish() -> Int {
        if let fixed = footer, fixed > 0, deepestTail.count == footerLimit * width * 4 {
            deepestTail.withUnsafeBytes { write($0, rows: (footerLimit - fixed)..<footerLimit) }
        }
        footer = 0
        try? handle.close()
        return writtenRows
    }

    private func write(_ pixels: UnsafeRawBufferPointer, rows: Range<Int>) {
        let bytesPerRow = width * 4
        let slice = UnsafeRawBufferPointer(rebasing: pixels[(rows.lowerBound * bytesPerRow)..<(rows.upperBound * bytesPerRow)])
        handle.write(Data(slice))
        writtenRows += rows.count
        onRowsAdded?(slice, rows.count)
    }

    /// Keeps the bottom of the frame that reaches lowest so far.
    private func rememberTail(_ pixels: UnsafeRawBufferPointer) {
        deepest = position
        let start = (height - footerLimit) * width * 4
        deepestTail = Data(pixels[start..<(height * width * 4)])
    }

    /// How many rows at the bottom did not move along with a scroll by `shift`, judged
    /// pixel by pixel across the whole width: the row features leave out the edges and
    /// average over wide blocks, so a button in a corner is invisible to them. The same
    /// part of the page is looked up in both frames, low in one and higher in the other;
    /// from the first row that differs down to the edge something is in the way. A
    /// little is added for the soft edge and shadow floating bars have. Taking too much
    /// costs nothing: those rows are written from a later frame, or at the end.
    private func unmovedBottom(_ pixels: UnsafeRawBufferPointer, shift: Int) -> Int {
        let distance = abs(shift)
        guard distance > 0, lastPixels.count == width * height * 4 else { return 0 }
        let bytesPerRow = width * 4
        // More than dithering, on more than a stray pixel or two.
        let tolerance = 12, allowed = max(4, width / 200)
        return lastPixels.withUnsafeBytes { old -> Int in
            // Scrolling down, the old frame holds the page low; scrolling up, the new one.
            let (low, high) = shift > 0 ? (old, pixels) : (pixels, old)
            var first: Int?
            for row in stride(from: height - 1, through: height - footerLimit, by: -1) where row - distance >= 0 {
                var a = row * bytesPerRow, b = (row - distance) * bytesPerRow
                var differing = 0
                for _ in 0..<width {
                    if abs(Int(low[a]) - Int(high[b])) > tolerance || abs(Int(low[a + 1]) - Int(high[b + 1])) > tolerance
                        || abs(Int(low[a + 2]) - Int(high[b + 2])) > tolerance {
                        differing += 1
                        if differing >= allowed { break }
                    }
                    a += 4
                    b += 4
                }
                if differing >= allowed { first = row }
            }
            return first.map { min(footerLimit, height - $0 + 16) } ?? 0
        }
    }

    private func remember(_ rows: RowFeatures, _ pixels: UnsafeRawBufferPointer) {
        lastRows = rows
        lastPixels = Data(pixels.prefix(width * height * 4))
    }

    // MARK: Comparing frames

    /// A compact description of every row of a frame: the average brightness of a number
    /// of blocks across the row. Real screen captures carry faint pixel noise even in
    /// flat areas, so rows are compared through these averages rather than pixel by pixel.
    struct RowFeatures {
        static let blocks = 32
        /// Largest difference between two block averages (0–255) that still counts as equal.
        static let tolerance = 3

        var values: [UInt8]
        var count: Int

        func value(_ row: Int, _ block: Int) -> Int { Int(values[row * Self.blocks + block]) }

        func blockMatches(_ block: Int, _ row: Int, _ other: RowFeatures, _ otherRow: Int) -> Bool {
            abs(value(row, block) - other.value(otherRow, block)) <= Self.tolerance
        }

        /// Whether two rows look alike in the given blocks, allowing `slack` blocks to differ.
        func matches(_ row: Int, _ other: RowFeatures, _ otherRow: Int, blocks: [Int], slack: Int = 0) -> Bool {
            var misses = 0
            for block in blocks where !blockMatches(block, row, other, otherRow) {
                misses += 1
                if misses > slack { return false }
            }
            return true
        }
    }

    /// The edges of each row are left out because a scroll bar there changes from frame
    /// to frame.
    static func rowFeatures(_ pixels: UnsafeRawBufferPointer, width: Int, height: Int) -> RowFeatures {
        let blocks = RowFeatures.blocks
        var values = [UInt8](repeating: 0, count: height * blocks)
        let firstColumn = width * 4 / 100
        let blockWidth = (width * 90 / 100 - firstColumn) / blocks
        guard blockWidth > 0 else { return RowFeatures(values: values, count: height) }
        for row in 0..<height {
            var offset = (row * width + firstColumn) * 4
            for block in 0..<blocks {
                var sum = 0
                for _ in 0..<blockWidth {
                    sum += Int(pixels[offset]) + 2 * Int(pixels[offset + 1]) + Int(pixels[offset + 2])
                    offset += 4
                }
                values[row * blocks + block] = UInt8(sum / (4 * blockWidth))
            }
        }
        return RowFeatures(values: values, count: height)
    }

    /// How the content moved between two frames.
    struct Motion: Equatable {
        /// Rows the content moved up (negative: moved down); 0 if it did not move.
        var shift: Int
        /// Rows at the top and bottom that stayed put while the rest scrolled.
        var header: Int
        var footer: Int
    }

    /// Works out the movement between two frames, or nil if they have no convincing
    /// overlap.
    ///
    /// Parts of the region that do not scroll are found first and left out: columns that
    /// stay the same (a sidebar, the desktop beside a window) and rows at the top and
    /// bottom that stay the same (title bars, sticky bars). For the rest, every possible
    /// shift is scored by the average difference between the rows it would line up, and
    /// the best one is accepted if it explains the new frame much better than "nothing
    /// moved" does. Scoring by average difference, rather than counting exact row
    /// matches, keeps this working for low-contrast content such as text on a dark
    /// background and for small things that change by themselves (a cursor, a clock).
    ///
    /// The average is taken over the rows that say something (a row with detail on
    /// either side of the pair) and leaves out the quarter of them that fit worst.
    ///
    /// A bar the page shows through, like Safari's tool bar on macOS 26, neither scrolls
    /// nor stays the same: it is not found as a sticky bar, and its rows fit no shift at
    /// all. Counted in, they made every shift look wrong ("too fast" at the first
    /// movement). So the best shift is judged a second time without the columns and the
    /// rows at either end of the frame that do not fit it, which is where such bars are.
    static func motion(from old: RowFeatures, to new: RowFeatures) -> Motion? {
        let height = new.count
        guard old.count == height, height > 1 else { return nil }
        let still = Motion(shift: 0, header: 0, footer: 0)
        let allBlocks = Array(0..<RowFeatures.blocks)

        // A column takes part only if it has detail (places where it changes from one row
        // to the next) and that detail did not stay where it was.
        var active: [Int] = []
        for block in allBlocks {
            var detail = 0
            var stayed = 0
            for row in 1..<height where !new.blockMatches(block, row, new, row - 1) {
                detail += 1
                if new.blockMatches(block, row, old, row), new.blockMatches(block, row - 1, old, row - 1) { stayed += 1 }
            }
            if detail >= 4, stayed * 100 < detail * 90 { active.append(block) }
        }
        guard !active.isEmpty else { return still }

        // Sticky bars: rows at either end that did not change in the scrolling columns.
        // A couple of blocks may differ, e.g. a clock inside a status bar.
        let slack = active.count / 8
        var header = 0
        while header < height / 2, new.matches(header, old, header, blocks: active, slack: slack) { header += 1 }
        var footer = 0
        while footer < height / 3,
              new.matches(height - 1 - footer, old, height - 1 - footer, blocks: active, slack: slack) { footer += 1 }
        let body = header..<(height - footer)
        guard body.count >= 16 else { return still }

        // One number per row for a fast first pass, and which rows carry detail: rows of
        // one colour look alike everywhere and prove nothing.
        var newSums = [Int](repeating: 0, count: height)
        var oldSums = [Int](repeating: 0, count: height)
        var newDetail = [Bool](repeating: false, count: height)
        var oldDetail = [Bool](repeating: false, count: height)
        var detailBefore = [Int](repeating: 0, count: height + 1)
        for row in 0..<height {
            for block in active {
                newSums[row] += new.value(row, block)
                oldSums[row] += old.value(row, block)
            }
            newDetail[row] = row > 0 && !new.matches(row, new, row - 1, blocks: active)
            oldDetail[row] = row > 0 && !old.matches(row, old, row - 1, blocks: active)
            detailBefore[row + 1] = detailBefore[row] + (newDetail[row] ? 1 : 0)
        }
        func rows(for shift: Int) -> Range<Int> {
            // Row `row` of the new frame shows what row `row + shift` of the old one showed.
            shift >= 0 ? body.lowerBound..<(body.upperBound - shift) : (body.lowerBound - shift)..<body.upperBound
        }
        // Row differences are counted in steps of a quarter of a brightness level.
        let steps = 4, bins = 256 * steps
        var histogram = [Int](repeating: 0, count: bins)
        /// The average difference, in brightness levels per block, between the rows a shift
        /// lines up: over the rows with detail, without the quarter that fit worst.
        /// `difference` gives one pair of rows' total over the active blocks.
        func cost(_ shift: Int, _ difference: (_ row: Int, _ oldRow: Int) -> Int) -> Double {
            for bin in 0..<bins { histogram[bin] = 0 }
            var counted = 0
            for row in rows(for: shift) where newDetail[row] || oldDetail[row + shift] {
                histogram[min(bins - 1, difference(row, row + shift) * steps / active.count)] += 1
                counted += 1
            }
            guard counted > 0 else { return 0 }
            let kept = max(1, counted * 3 / 4)
            var total = 0, taken = 0
            for bin in 0..<bins where taken < kept {
                let take = min(histogram[bin], kept - taken)
                total += take * bin
                taken += take
            }
            return Double(total) / Double(kept * steps)
        }
        func quickCost(_ shift: Int) -> Double {
            cost(shift) { row, oldRow in abs(newSums[row] - oldSums[oldRow]) }
        }
        func fullCost(_ shift: Int) -> Double {
            cost(shift) { row, oldRow in
                var total = 0
                for block in active { total += abs(new.value(row, block) - old.value(oldRow, block)) }
                return total
            }
        }
        /// The second look at a shift, for regions where something neither scrolls nor
        /// stays the same: a bar or a strip the page shows through. First the columns
        /// that do not follow the shift are set aside (a strip down a side), then the
        /// rows at either end that do not (a bar across the top or bottom), and what is
        /// left in the middle is judged as before. The ends are looked for in the first
        /// two fifths and the last third only, so that a shift that fits nowhere keeps
        /// its bad middle and is still refused.
        func fitsInTheMiddle(_ shift: Int) -> Bool {
            let range = rows(for: shift)
            func differs(_ row: Int, _ block: Int, by shift: Int) -> Bool {
                abs(new.value(row, block) - old.value(row + shift, block)) > 6
            }
            // A column follows the shift if most of its detail lands where the shift says.
            let following = active.filter { block in
                var detail = 0, misplaced = 0
                for row in range where row > 0 && !new.blockMatches(block, row, new, row - 1) {
                    detail += 1
                    if differs(row, block, by: shift) { misplaced += 1 }
                }
                return detail >= 4 && misplaced * 2 < detail
            }
            guard following.count >= max(4, active.count / 3) else { return false }
            // One block alone may straddle the edge of a column that does not scroll.
            let allowed = max(2, following.count / 12)
            func fits(_ row: Int) -> Bool {
                var differing = 0
                for block in following where differs(row, block, by: shift) {
                    differing += 1
                    if differing >= allowed { return false }
                }
                return true
            }
            var first = range.lowerBound, last = range.upperBound
            for row in range.prefix(range.count * 2 / 5) where !fits(row) { first = row + 1 }
            for row in range.suffix(range.count / 3).reversed() where !fits(row) { last = row }
            guard last - first >= 16 else { return false }
            /// Average difference per block over the rows with detail, without the
            /// quarter that fit worst.
            func middleCost(_ shift: Int) -> Double? {
                var costs: [Int] = []
                for row in first..<last where newDetail[row] || oldDetail[row + shift] {
                    var total = 0
                    for block in following { total += abs(new.value(row, block) - old.value(row + shift, block)) }
                    costs.append(total)
                }
                guard costs.count >= max(4, (last - first) / 40) else { return nil }
                costs.sort()
                let kept = costs.prefix(max(1, costs.count * 3 / 4))
                return Double(kept.reduce(0, +)) / Double(kept.count * following.count)
            }
            guard let cost = middleCost(shift), let unmoved = middleCost(0) else { return false }
            return cost <= 3 && cost <= unmoved * 0.5
        }

        let unmoved = fullCost(0)
        if unmoved <= 0.25 { return still }
        // Something small that changes by itself (a cursor, a clock, a spinner) alters
        // only a few rows; scrolling alters most rows that have anything in them.
        var changedRows = 0
        for row in 0..<height where !new.matches(row, old, row, blocks: allBlocks) { changedRows += 1 }
        let changedLittle = changedRows * 100 <= height * 12

        // First pass over every shift with the per-row sums; keep the most promising few.
        var candidates: [(shift: Int, cost: Double)] = []
        for distance in 1..<body.count {
            for shift in [distance, -distance] {
                let range = rows(for: shift)
                // The rows lined up must carry some detail, or any shift would seem to fit.
                guard range.count >= 16, detailBefore[range.upperBound] - detailBefore[range.lowerBound]
                        >= max(4, range.count / 40) else { continue }
                candidates.append((shift, quickCost(shift)))
            }
        }
        candidates.sort { $0.cost < $1.cost }
        var best: (shift: Int, cost: Double)?
        for candidate in candidates.prefix(8) {
            let cost = fullCost(candidate.shift)
            if best == nil || cost < best!.cost { best = (candidate.shift, cost) }
        }
        if !changedLittle, let best = best {
            if best.cost <= 3, best.cost <= unmoved * 0.5 {
                return Motion(shift: best.shift, header: header, footer: footer)
            }
            if fitsInTheMiddle(best.shift) { return Motion(shift: best.shift, header: header, footer: footer) }
        }
        // No shift explains the change. If little changed, it was not scrolling.
        return changedLittle ? still : nil
    }
}
