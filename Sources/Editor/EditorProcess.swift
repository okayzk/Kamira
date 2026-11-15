import AppKit

/// Runs one annotation editor as its own short-lived process
/// (`--editor <image> <pin-output>`). Editing a large capture needs tens of megabytes
/// that the allocator would otherwise keep in the menu bar app for good; here the
/// system gets all of it back when the editor window closes.
final class EditorProcessDelegate: NSObject, NSApplicationDelegate {
    private let imageURL: URL
    /// Where the result is written if the user chooses Pin; the menu bar app picks it up.
    private let pinURL: URL
    private var editor: AnnotationEditor?

    init(imagePath: String, pinPath: String) {
        imageURL = URL(fileURLWithPath: imagePath)
        pinURL = URL(fileURLWithPath: pinPath)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        EditMenu.install()
        let data = try? Data(contentsOf: imageURL)
        try? FileManager.default.removeItem(at: imageURL)
        guard let data = data, let capture = CapturedImage(data: data) else {
            NSApp.terminate(nil)
            return
        }
        let editor = AnnotationEditor(capture: capture)
        editor.onPin = { [pinURL] result in try? result.pngData()?.write(to: pinURL, options: .atomic) }
        editor.onClose = { _ in NSApp.terminate(nil) }
        self.editor = editor
        editor.show()
        // Development aids: replay one gesture per tool, optionally copying the result.
        if CommandLine.arguments.contains("--demo-draw") { editor.runDemo(thenCopy: false) }
        if CommandLine.arguments.contains("--demo-copy") { editor.runDemo(thenCopy: true) }
        // `--demo-move` goes on to edit the samples: delete, recolour, reshape, move.
        if CommandLine.arguments.contains("--demo-move") { editor.runDemo(thenCopy: false, thenEdit: true) }
        // `--demo-zoom` looks at the samples from close up.
        if CommandLine.arguments.contains("--demo-zoom") { editor.runDemo(thenCopy: false, thenEdit: true, zoom: 4) }
    }
}
