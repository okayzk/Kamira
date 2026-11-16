import Foundation

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
