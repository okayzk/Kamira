import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut: a key and its modifiers, in the terms the system's hot key
/// registration uses (a virtual key code and Carbon modifier bits).
struct Shortcut: Equatable {
    var keyCode: UInt32
    /// Any of `cmdKey`, `shiftKey`, `optionKey`, `controlKey`.
    var modifiers: UInt32
    /// What the key prints without modifiers ("4", "s"), as the keyboard layout reported
    /// it when the shortcut was recorded. Key codes are positions, not characters, so
    /// this is kept rather than looked up.
    var key: String

    /// Keys that print nothing: the name shown, and the character a menu item needs.
    private static let named: [UInt32: (name: String, menu: Int)] = {
        var keys: [UInt32: (String, Int)] = [
            UInt32(kVK_Space): ("Space", 0x20), UInt32(kVK_Return): ("↩", 0x0D), UInt32(kVK_Tab): ("⇥", 0x09),
            UInt32(kVK_Delete): ("⌫", 0x08), UInt32(kVK_Escape): ("⎋", 0x1B),
            UInt32(kVK_LeftArrow): ("←", NSLeftArrowFunctionKey), UInt32(kVK_RightArrow): ("→", NSRightArrowFunctionKey),
            UInt32(kVK_DownArrow): ("↓", NSDownArrowFunctionKey), UInt32(kVK_UpArrow): ("↑", NSUpArrowFunctionKey)
        ]
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
                            kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (index, code) in functionKeys.enumerated() {
            keys[UInt32(code)] = ("F\(index + 1)", NSF1FunctionKey + index)
        }
        return keys
    }()

    private static let allModifiers = UInt32(cmdKey | shiftKey | optionKey | controlKey)

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.allModifiers
        // The same key is the same shortcut whatever the event said it prints.
        self.key = Self.named[keyCode] == nil ? key.lowercased() : ""
    }

    /// From a key press as AppKit reports it.
    init(keyCode: UInt16, flags: NSEvent.ModifierFlags, key: String) {
        var modifiers = 0
        if flags.contains(.command) { modifiers |= cmdKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.control) { modifiers |= controlKey }
        self.init(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers), key: key)
    }

    /// As macOS writes shortcuts: ⌃⌥⇧⌘ in that order, then the key.
    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + (Self.named[keyCode]?.name ?? key.uppercased())
    }

    /// A global shortcut takes its key away from every app, so it needs ⌘, ⌃ or ⌥; only
    /// a function key may stand alone.
    var isUsable: Bool {
        if modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 { return true }
        return Self.named[keyCode]?.name.hasPrefix("F") == true
    }

    // MARK: Menu items

    var menuKey: String {
        guard let named = Self.named[keyCode], let scalar = Unicode.Scalar(named.menu) else { return key }
        return String(Character(scalar))
    }

    var menuModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        return flags
    }

    // MARK: Preferences

    /// "key code,modifiers,key"; the key comes last because it may itself be a comma.
    var stored: String { "\(keyCode),\(modifiers),\(key)" }

    init?(stored: String) {
        let parts = stored.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let keyCode = UInt32(parts[0]), let modifiers = UInt32(parts[1]) else { return nil }
        self.init(keyCode: keyCode, modifiers: modifiers, key: String(parts[2]))
    }

    // MARK: The system's shortcuts

    /// True while macOS has the same shortcut switched on for something of its own: the
    /// system answers first, and this app never hears the key.
    func isTaken(by system: [SystemHotKey]) -> Bool {
        system.contains { $0.enabled && $0.keyCode == keyCode && $0.modifiers == modifiers }
    }
}
