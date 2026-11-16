import AppKit

/// Opens the annotation editor in a helper process (`--editor`, see
/// `EditorProcessDelegate`), so that the memory editing needs is fully returned when the
/// editor closes. A result the user pins comes back as a file, and goes to `onPin`.
final class EditorLauncher {
    /// The edited picture, to be pinned.
    var onPin: ((CapturedImage) -> Void)?
    /// A message for the user.
    var onError: ((String) -> Void)?

    /// Where the picture to edit and the pinned result are handed over.
    private let directory: URL
    /// Running editors, one process each.
    private var editors: [Process] = []

    init(directory: URL) {
        self.directory = directory
    }

    /// `demo` is one of the editor's demo flags (`--demo-draw` and the like), or nil.
    func open(_ capture: CapturedImage, demo: String? = nil) {
        let id = UUID().uuidString
        let imageURL = directory.appendingPathComponent("edit-\(id).png")
        let pinURL = directory.appendingPathComponent("pin-\(id).png")
        let helper = Process()
        helper.executableURL = Bundle.main.executableURL
        helper.arguments = ["--editor", imageURL.path, pinURL.path] + (demo.map { [$0] } ?? []) + QuietMode.arguments
        helper.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.editors.removeAll { $0 === process }
                // The capture takes the file over and deletes it when the pin closes.
                if FileManager.default.fileExists(atPath: pinURL.path),
                   let result = CapturedImage(owningFile: pinURL) {
                    self.onPin?(result)
                }
                try? FileManager.default.removeItem(at: imageURL)
            }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try capture.data.write(to: imageURL, options: .atomic)
            try helper.run()
            editors.append(helper)
        } catch {
            onError?(L("error.editor", error.localizedDescription))
        }
    }

    /// Ends every editor, as the app quits.
    func closeAll() {
        editors.forEach { $0.terminate() }
    }
}
