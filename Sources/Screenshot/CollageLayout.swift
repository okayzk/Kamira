import CoreGraphics

/// Where each of several screenshots goes when they are combined into one picture: in
/// the order taken, left to right in rows like a page, the rows as long as makes the
/// whole nearest a square. The same gap lies between pictures and around them; in a row,
/// pictures line up at the top. Everything is in points.
enum CollageLayout {
    /// Each picture's frame, measured from the bottom-left corner of the whole as Core
    /// Graphics measures, and the size of the whole.
    static func arrange(_ sizes: [CGSize], gap: CGFloat) -> (frames: [CGRect], size: CGSize) {
        guard !sizes.isEmpty else { return ([], .zero) }
        // Every row length worth trying is the width of some run of pictures in a row.
        var limits = Set<CGFloat>()
        for start in sizes.indices {
            var width = -gap
            for size in sizes[start...] {
                width += gap + size.width
                limits.insert(width)
            }
        }
        // Squarest first; between two as square, the one with fewer rows (screens are wide).
        func score(_ rows: [[Int]]) -> (CGFloat, Int) {
            let size = wholeSize(rows, sizes, gap)
            return (max(size.width, size.height) / min(size.width, size.height), rows.count)
        }
        let best = limits.map { rows(sizes, gap, limit: $0) }.min { score($0) < score($1) }!
        return place(best, sizes, gap)
    }

    /// The pictures (as indices) row by row: each row takes the next pictures while they
    /// fit in `limit`, and always at least one.
    private static func rows(_ sizes: [CGSize], _ gap: CGFloat, limit: CGFloat) -> [[Int]] {
        var rows: [[Int]] = []
        var width: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            if let last = rows.indices.last, width + gap + size.width <= limit {
                rows[last].append(index)
                width += gap + size.width
            } else {
                rows.append([index])
                width = size.width
            }
        }
        return rows
    }

    private static func wholeSize(_ rows: [[Int]], _ sizes: [CGSize], _ gap: CGFloat) -> CGSize {
        let widths = rows.map { row in row.reduce(-gap) { $0 + gap + sizes[$1].width } }
        let heights = rows.map { row in row.map { sizes[$0].height }.max()! }
        return CGSize(width: widths.max()! + gap * 2,
                      height: heights.reduce(0, +) + gap * CGFloat(rows.count + 1))
    }

    private static func place(_ rows: [[Int]], _ sizes: [CGSize], _ gap: CGFloat) -> (frames: [CGRect], size: CGSize) {
        let size = wholeSize(rows, sizes, gap)
        var frames = [CGRect](repeating: .zero, count: sizes.count)
        // Top of the current row, coming down from the top edge.
        var top = size.height - gap
        for row in rows {
            var x = gap
            for index in row {
                frames[index] = CGRect(x: x, y: top - sizes[index].height,
                                       width: sizes[index].width, height: sizes[index].height)
                x += sizes[index].width + gap
            }
            top -= row.map { sizes[$0].height }.max()! + gap
        }
        return (frames, size)
    }
}
