import AppKit

/// Runs one annotation editor as its own short-lived process
/// (`--editor <image> <pin-output>`). Editing a large capture needs tens of megabytes
/// that the allocator would otherwise keep in the menu bar app for good; here the
/// system gets all of it back when the editor window closes.
final class EditorProcessDelegate: NSObject, NSApplicationDelegate {
    private let imageURL: URL
    /// Where the result is written if the user chooses Pin; the menu bar app picks it up.
    private let pinURL: URL
    /// The pictures a combined capture was made of, each with its place: `--part <file> x,y,w,h`.
    private let parts: [(file: URL, frame: CGRect)]
    private var editor: AnnotationEditor?

    init(imagePath: String, pinPath: String, arguments: [String]) {
        imageURL = URL(fileURLWithPath: imagePath)
        pinURL = URL(fileURLWithPath: pinPath)
        parts = arguments.indices.dropLast(2).compactMap { index in
            let n = arguments[index + 2].split(separator: ",").compactMap { Double($0) }
            guard arguments[index] == "--part", n.count == 4 else { return nil }
            return (URL(fileURLWithPath: arguments[index + 1]), CGRect(x: n[0], y: n[1], width: n[2], height: n[3]))
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        QuietMode.start()
        EditMenu.install()
        let data = try? Data(contentsOf: imageURL)
        try? FileManager.default.removeItem(at: imageURL)
        // Read once into memory, like the capture, and the hand-over files deleted.
        let pictures = parts.compactMap { part -> (picture: CapturedImage, frame: CGRect)? in
            defer { try? FileManager.default.removeItem(at: part.file) }
            return (try? Data(contentsOf: part.file)).flatMap(CapturedImage.init(data:)).map { ($0, part.frame) }
        }
        guard let data = data, let capture = CapturedImage(data: data) else {
            NSApp.terminate(nil)
            return
        }
        // Should a picture be missing, the capture as it was combined is edited instead.
        let editor = AnnotationEditor(capture: capture, parts: pictures.count == parts.count ? pictures : [])
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
        // `--demo-crop` leaves a crop frame over the samples, ready to be kept.
        if CommandLine.arguments.contains("--demo-crop") { editor.runDemo(thenCopy: false, thenCrop: true) }
        // `--demo-arrange` drags one of several pictures over another and puts white between them.
        if CommandLine.arguments.contains("--demo-arrange") { editor.runArrangeDemo() }
    }
}
