import AppKit

/// Text recognition (Sources/TextRecognition/).
func testTextRecognition() {
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
}
