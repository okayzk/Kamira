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
