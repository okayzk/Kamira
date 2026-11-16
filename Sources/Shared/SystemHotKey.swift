import Carbon.HIToolbox

/// One of macOS's own shortcuts (System Settings → Keyboard → Keyboard Shortcuts).
struct SystemHotKey {
    var keyCode: UInt32
    var modifiers: UInt32
    var enabled: Bool

    /// What the system has right now, switched on or not.
    static func current() -> [SystemHotKey] {
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr,
              let entries = list?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let keyCode = entry[kHISymbolicHotKeyCode as String] as? Int,
                  let modifiers = entry[kHISymbolicHotKeyModifiers as String] as? Int,
                  keyCode >= 0, modifiers >= 0 else { return nil }
            return SystemHotKey(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers),
                                enabled: entry[kHISymbolicHotKeyEnabled as String] as? Bool ?? false)
        }
    }
}
