import Carbon.HIToolbox

/// The actions that can have a global shortcut, in the order the settings list them.
enum ShortcutAction: String, CaseIterable {
    case area, window, screen, several, scrolling, text, record, pin, panel

    var title: String {
        switch self {
        case .area: return L("menu.captureArea")
        case .window: return L("menu.captureWindow")
        case .screen: return L("menu.captureScreen")
        case .several: return L("menu.captureSeveral")
        case .scrolling: return L("menu.scrollingCapture")
        case .text: return L("menu.recognizeText")
        case .record: return L("menu.recordScreen")
        case .pin: return L("menu.pinClipboard")
        case .panel: return L("menu.quickPanel")
        }
    }

    /// The same keys as the system's screenshot shortcuts, which this app is a layer on:
    /// ⇧⌘3 the screen, ⇧⌘4 an area, ⇧⌘5 the panel with everything. They reach the app
    /// once the system's own are switched off; the settings say how.
    var defaultShortcut: Shortcut? {
        let modifiers = UInt32(shiftKey | cmdKey)
        switch self {
        case .screen: return Shortcut(keyCode: UInt32(kVK_ANSI_3), modifiers: modifiers, key: "3")
        case .area: return Shortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: modifiers, key: "4")
        case .panel: return Shortcut(keyCode: UInt32(kVK_ANSI_5), modifiers: modifiers, key: "5")
        default: return nil
        }
    }

    /// Whether the system would answer any shortcut in `table` first.
    static func anyTaken(_ table: [ShortcutAction: Shortcut], by system: [SystemHotKey]) -> Bool {
        table.values.contains { $0.isTaken(by: system) }
    }

    /// Identifies the action in a hot key event.
    var hotKeyID: UInt32 { UInt32(Self.allCases.firstIndex(of: self)! + 1) }

    var preferenceKey: String { "shortcut.\(rawValue)" }

    /// Reads a preference: never set means the default, an empty text means none.
    func shortcut(fromStored stored: String?) -> Shortcut? {
        guard let stored = stored else { return defaultShortcut }
        return Shortcut(stored: stored)
    }

    /// `table` with `shortcut` given to `action`. A shortcut can only start one thing, so
    /// an action that had the same one loses it.
    static func assigning(_ shortcut: Shortcut?, to action: ShortcutAction,
                          in table: [ShortcutAction: Shortcut]) -> [ShortcutAction: Shortcut] {
        var table = table.filter { $0.value != shortcut }
        table[action] = shortcut
        return table
    }
}
