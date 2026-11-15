import AppKit

extension NSScreen {
    /// The screen the pointer is on: where the user is looking, and so where a preview,
    /// a pin, the editor or a message should appear. `NSScreen.main` is the screen of
    /// the key window, which a menu bar app usually does not have.
    static var underPointer: NSScreen? {
        let pointer = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(pointer) } ?? main
    }

    /// The screen most of `rect` (global AppKit coordinates) lies on.
    static func containing(_ rect: CGRect) -> NSScreen? {
        screens.max { $0.frame.intersection(rect).width * $0.frame.intersection(rect).height
            < $1.frame.intersection(rect).width * $1.frame.intersection(rect).height } ?? main
    }
}
