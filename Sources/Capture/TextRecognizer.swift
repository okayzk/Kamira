import Foundation
import Vision

/// Reads the text in a picture with the system's own recogniser (Vision). Runs in a
/// helper process (`--ocr <image>`), never inside the menu bar app: the recogniser's
/// models take far more memory than the app is allowed to keep.
enum TextRecognizer {
    /// One piece of recognised text. `box` is normalised (0...1) with the origin at the
    /// bottom-left of the picture, as Vision reports it.
    struct Fragment {
        var text: String
        var box: CGRect
    }

    /// Puts fragments back into reading order: rows from top to bottom, and within a row
    /// from left to right, separated by a space. Fragments share a row when the middle
    /// of one lies within the height of the row's first fragment, so table cells and
    /// terminal columns on the same line come out as one line.
    static func assemble(_ fragments: [Fragment]) -> String {
        var rows: [[Fragment]] = []
        for fragment in fragments.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let first = rows.last?.first, fragment.box.midY > first.box.minY {
                rows[rows.count - 1].append(fragment)
            } else {
                rows.append([fragment])
            }
        }
        return rows.map { row in
            row.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ")
        }.joined(separator: "\n")
    }

    /// The text in the image file, or an empty string when there is none.
    static func recognize(imageAt url: URL) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Let the system decide the language line by line. Measured on a screen of mixed
        // code and Chinese: a fixed list with Chinese first turns ASCII punctuation into
        // full-width forms, and English first drops the Chinese lines altogether.
        request.automaticallyDetectsLanguage = true
        // Screens are full of code, names and commands that a dictionary "corrects" into
        // wrong words ("assert" became "assent"), and loading it took 15 s in a new process.
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(url: url).perform([request])
        return assemble((request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { Fragment(text: $0.string, box: observation.boundingBox) }
        })
    }

    /// Entry point for the helper process: prints the text to standard output; never returns.
    static func runHelper(image: String) -> Never {
        do {
            let text = try recognize(imageAt: URL(fileURLWithPath: image))
            FileHandle.standardOutput.write(Data(text.utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("ocr: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
