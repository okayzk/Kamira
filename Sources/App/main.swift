import AppKit

// A lightweight companion to macOS's own Screenshot utility.
// No third-party dependencies, no capture history, and no polling while idle.

// Helper modes end with the app that started them (see `ParentWatch`). Two are left to
// finish instead, as they hold the user's work: an annotation editor, and a recording
// being made into a GIF.
let stoppedWithApp = ["--ocr", "--ocr-warm-up", "--window-shadow", "--scroll-capture", "--desktop-cover", "--quicklook"]
if CommandLine.arguments.contains(where: stoppedWithApp.contains) { ParentWatch.start() }

// Helper mode: convert a finished recording to a GIF and exit, without any UI.
if let index = CommandLine.arguments.firstIndex(of: "--convert-gif"),
   index + 2 < CommandLine.arguments.count {
    let side = index + 3 < CommandLine.arguments.count ? Int(CommandLine.arguments[index + 3]) ?? 0 : 0
    GIFConverter.runHelper(video: CommandLine.arguments[index + 1],
                           gif: CommandLine.arguments[index + 2], maxSide: side)
}

// Helper mode: print the text found in a picture and exit; see `TextRecognizer`.
if let index = CommandLine.arguments.firstIndex(of: "--ocr"), index + 1 < CommandLine.arguments.count {
    TextRecognizer.runHelper(image: CommandLine.arguments[index + 1])
}
// Helper mode: read a drawn picture once so the next reading is quick; see `TextRecognizer.runWarmUp`.
if CommandLine.arguments.contains("--ocr-warm-up") { TextRecognizer.runWarmUp() }

// Helper mode: give a window capture a shadow of the given step and exit; see `WindowShadow`.
if let index = CommandLine.arguments.firstIndex(of: "--window-shadow"), index + 1 < CommandLine.arguments.count {
    let level = index + 2 < CommandLine.arguments.count ? Int(CommandLine.arguments[index + 2]) ?? 1 : 1
    WindowShadow.runHelper(image: CommandLine.arguments[index + 1], level: level)
}

// Helper mode: scrolling capture of one screen region; see `ScrollCaptureHelper`.
if let index = CommandLine.arguments.firstIndex(of: "--scroll-capture") {
    ScrollCaptureHelper.run(arguments: Array(CommandLine.arguments[(index + 1)...]))
}

// Helper mode: cover the desktop icons with the wallpaper until told to stop; see `DesktopCover`.
if CommandLine.arguments.contains("--desktop-cover") { DesktopCover.runHelper() }

let application = NSApplication.shared
// Helper mode: one annotation editor, which quits when its window closes.
let editorDelegate: EditorProcessDelegate? = {
    guard let index = CommandLine.arguments.firstIndex(of: "--editor"),
          index + 2 < CommandLine.arguments.count else { return nil }
    return EditorProcessDelegate(imagePath: CommandLine.arguments[index + 1],
                                 pinPath: CommandLine.arguments[index + 2])
}()
if let editorDelegate = editorDelegate {
    application.delegate = editorDelegate
    application.run()
    exit(0)
}
// Helper mode: Quick Look for one file; quits when the panel closes.
if let index = CommandLine.arguments.firstIndex(of: "--quicklook"), index + 1 < CommandLine.arguments.count {
    let quickLook = QuickLookProcessDelegate(path: CommandLine.arguments[index + 1])
    application.delegate = quickLook
    application.run()
    exit(0)
}
let delegate = AppDelegate()
application.delegate = delegate
application.run()
