import AppKit
import Carbon.HIToolbox

/// The global shortcuts, registered with the system for as long as the app runs.
final class HotKeys {
    /// The shortcut of this action was pressed.
    var onPress: ((ShortcutAction) -> Void)?

    private var references: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?

    /// Starts hearing the shortcuts that `register` registers.
    init() {
        var kind = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData = userData, let event = event else { return OSStatus(-9874) }
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let keys = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
            let which = pressed.id
            DispatchQueue.main.async {
                if let action = ShortcutAction.allCases.first(where: { $0.hotKeyID == which }) { keys.onPress?(action) }
            }
            return noErr
        }, 1, &kind, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    /// Registers the shortcuts the settings hold, in place of those registered before.
    /// One the system uses for itself registers without error and then never arrives;
    /// the settings mark those (`Shortcut.isTaken`).
    func register() {
        unregister()
        // A test copy must not take the shortcuts from the copy in use.
        guard !QuietMode.isOn else { return }
        for (action, shortcut) in Settings.shortcuts {
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: OSType(0x43455054), id: action.hotKeyID) // 'CEPT'
            let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, identifier,
                                             GetApplicationEventTarget(), 0, &reference)
            if result != noErr {
                NSLog("%@: shortcut %@ could not be registered (%d).", AppInfo.name, shortcut.display, result)
            }
            references.append(reference)
        }
    }

    func unregister() {
        references.compactMap { $0 }.forEach { UnregisterEventHotKey($0) }
        references.removeAll()
    }
}
