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
    /// Several screenshots combined go with the pictures they were made of, so that the
    /// editor can lay them out again.
    func open(_ capture: CapturedImage, demo: String? = nil) {
        let id = UUID().uuidString
        let imageURL = directory.appendingPathComponent("edit-\(id).png")
        let pinURL = directory.appendingPathComponent("pin-\(id).png")
        // Copies, which the editor deletes: the capture keeps its own for the next time.
        let parts = capture.parts.enumerated().map { index, part in
            (part, directory.appendingPathComponent("edit-\(id)-\(index).\(part.file.pathExtension)"))
        }
        let partArguments = parts.flatMap { part, copy -> [String] in
            let f = part.frame
            return ["--part", copy.path, "\(f.minX),\(f.minY),\(f.width),\(f.height)"]
        }
        let helper = Process()
        helper.executableURL = Bundle.main.executableURL
        helper.arguments = ["--editor", imageURL.path, pinURL.path] + partArguments
            + (demo.map { [$0] } ?? []) + QuietMode.arguments
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
                parts.forEach { try? FileManager.default.removeItem(at: $0.1) }
            }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try capture.data.write(to: imageURL, options: .atomic)
            for (part, copy) in parts { try FileManager.default.copyItem(at: part.file, to: copy) }
            try helper.run()
            editors.append(helper)
        } catch {
            // Nothing was started, so nothing else will clear the hand-over files.
            try? FileManager.default.removeItem(at: imageURL)
            parts.forEach { try? FileManager.default.removeItem(at: $0.1) }
            onError?(L("error.editor", error.localizedDescription))
        }
    }

    /// Ends every editor, as the app quits.
    func closeAll() {
        editors.forEach { $0.terminate() }
    }
}
