import Foundation

enum PreviewTiming {
    /// Seconds; 0 keeps the preview until it is closed. `earlier` is the on/off setting
    /// this replaced, which closed previews after ten seconds.
    static func closeAfter(stored: Int?, earlier: Bool?) -> Int {
        if let stored = stored { return max(0, stored) }
        return earlier == true ? 10 : 0
    }

    /// The times the settings offer, with the current one among them.
    static func choices(including current: Int) -> [Int] {
        Array(Set([0, 5, 10, 30, 60] + [max(0, current)])).sorted()
    }
}
