import Foundation

/// Names for saved captures, from a pattern the user can change. The pattern is what the
/// system's own `strftime` understands (`%Y`, `%m`, `%d`, `%H`, `%M`, `%S`, …) with any
/// words around it.
enum FileNaming {
    static let screenshotDefault = "Screenshot %Y-%m-%d at %H.%M.%S"
    static let recordingDefault = "Recording %Y-%m-%d at %H.%M.%S"
    /// Where the patterns are kept. Read here rather than through `Settings`, because
    /// the helper processes name files too.
    static let screenshotKey = "screenshotNameFormat"
    static let recordingKey = "recordingNameFormat"

    /// The name for a screenshot or a recording taken now, without its extension.
    static func screenshotName(at date: Date = Date()) -> String {
        name(format: UserDefaults.standard.string(forKey: screenshotKey) ?? "", date: date, fallback: screenshotDefault)
    }
    static func recordingName(at date: Date = Date()) -> String {
        name(format: UserDefaults.standard.string(forKey: recordingKey) ?? "", date: date, fallback: recordingDefault)
    }

    /// `format` filled in for `date`. Slashes and colons become dashes (one would be
    /// taken for a folder, Finder shows the other as one), a leading dot is dropped so
    /// the file is not hidden, and a pattern that leaves nothing gives `fallback`.
    static func name(format: String, date: Date, fallback: String) -> String {
        func filled(_ pattern: String) -> String {
            var time = time_t(date.timeIntervalSince1970)
            var parts = tm()
            localtime_r(&time, &parts)
            var buffer = [CChar](repeating: 0, count: 512)
            let length = strftime(&buffer, buffer.count, pattern, &parts)
            var text = length > 0 ? String(cString: buffer) : ""
            text = text.map { "/:\n\r".contains($0) ? "-" : String($0) }.joined()
            text = text.trimmingCharacters(in: .whitespaces)
            while text.hasPrefix(".") { text.removeFirst() }
            return text
        }
        let name = filled(format)
        return name.isEmpty ? filled(fallback) : name
    }

    /// A place for `name` in `directory` that nothing has yet: the name itself, or with
    /// 2, 3, … after it.
    static func available(_ name: String, extension ext: String, in directory: URL,
                          exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        var url = directory.appendingPathComponent(name).appendingPathExtension(ext)
        var number = 2
        while exists(url) {
            url = directory.appendingPathComponent("\(name) \(number)").appendingPathExtension(ext)
            number += 1
        }
        return url
    }
}

/// How long a floating preview stays before it closes by itself.
/// A small diagnostic log that never grows without bound: once it passes `limit` bytes,
/// only its newest `keep` bytes, from the start of a line, are kept.
enum LogFile {
    static func append(_ line: String, to url: URL, limit: Int = 1_000_000, keep: Int = 250_000) {
        let data = Data((line.hasSuffix("\n") ? line : line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            let size = (try? handle.seekToEnd()) ?? 0
            if Int(size) + data.count <= limit {
                handle.write(data)
                try? handle.close()
                return
            }
            try? handle.close()
            var kept = ((try? Data(contentsOf: url)) ?? Data()).suffix(keep)
            if let newline = kept.firstIndex(of: UInt8(ascii: "\n")) { kept = kept[kept.index(after: newline)...] }
            try? (Data(kept) + data).write(to: url, options: .atomic)
        } else {
            try? data.write(to: url)
        }
    }
}

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

/// How far the app goes on its own about new versions. Sparkle keeps this as two flags:
/// whether it checks, and whether it then downloads and installs without asking.
enum UpdatePolicy: CaseIterable {
    case manual, ask, automatic

    init(checks: Bool, installs: Bool) {
        self = !checks ? .manual : installs ? .automatic : .ask
    }
    var checks: Bool { self != .manual }
    var installs: Bool { self == .automatic }

    /// Seconds between checks offered in Settings: a day, a week, a month.
    static let intervals: [TimeInterval] = [86_400, 604_800, 2_592_000]

    /// The offered interval closest to `seconds`, which Sparkle may hold as any number.
    static func interval(nearest seconds: TimeInterval) -> TimeInterval {
        intervals.min { abs($0 - seconds) < abs($1 - seconds) }!
    }
}
