import AppKit

/// Reads the text in a picture and copies it, in a helper process (`--ocr`, see
/// `TextRecognizer`), and prepares that helper's models when the app starts
/// (`--ocr-warm-up`). What happens is told through the callbacks; the app shows it.
final class TextReader {
    /// The reading waits for the warm-up, which is still preparing the models.
    var onPreparing: (() -> Void)?
    /// The text found, already on the clipboard.
    var onCopied: ((String) -> Void)?
    var onNothingFound: (() -> Void)?
    /// A message for the user: the helper could not be started.
    var onError: ((String) -> Void)?

    /// The helper that prepares text recognition at launch; see `TextRecognizer.runWarmUp`.
    private var warmUpHelper: Process?

    /// Starts the warm-up helper, which reads one drawn picture so that the user's first
    /// reading does not wait for the system to prepare its models.
    func warmUp() {
        let helper = Process()
        helper.executableURL = Bundle.main.executableURL
        helper.arguments = ["--ocr-warm-up"]
        guard (try? helper.run()) != nil else { return }
        warmUpHelper = helper
    }

    /// Recognises the text in the image file and copies it.
    func read(_ file: URL, removingFile: Bool) {
        // While the warm-up still prepares the models, a second reader would prepare them
        // again alongside it and finish later than the warm-up does (52 s against 42 s,
        // measured): wait for it instead, and say why nothing happens yet.
        if let warmUp = warmUpHelper, warmUp.isRunning {
            onPreparing?()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                warmUp.waitUntilExit()
                DispatchQueue.main.async { self?.read(file, removingFile: removingFile) }
            }
            return
        }
        let helper = Process()
        let pipe = Pipe()
        helper.executableURL = Bundle.main.executableURL
        helper.arguments = ["--ocr", file.path]
        helper.standardOutput = pipe
        do { try helper.run() } catch {
            if removingFile { try? FileManager.default.removeItem(at: file) }
            onError?(L("error.textRecognition", error.localizedDescription))
            return
        }
        // Read while the helper runs: a long text would otherwise fill the pipe and stall it.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            helper.waitUntilExit()
            if removingFile { try? FileManager.default.removeItem(at: file) }
            let text = helper.terminationStatus == 0 ? String(data: data, encoding: .utf8) ?? "" : ""
            DispatchQueue.main.async {
                guard !text.isEmpty else {
                    self?.onNothingFound?()
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self?.onCopied?(text)
            }
        }
    }
}
