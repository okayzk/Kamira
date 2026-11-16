import AppKit
import ServiceManagement

/// The user's choices. Everything is kept by the system: preferences in user defaults,
/// the login item in the system's own list (System Settings → General → Login Items).
enum Settings {
    private static func flag(_ key: String, default fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? fallback : UserDefaults.standard.bool(forKey: key)
    }

    /// Whether the welcome window was closed once.
    static var welcomed: Bool {
        get { flag("welcomed", default: false) }
        set { UserDefaults.standard.set(newValue, forKey: "welcomed") }
    }

    static var previewEnabled: Bool {
        get { flag("previewEnabled", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: "previewEnabled") }
    }
    /// Seconds before a screenshot's or a recording's preview closes by itself; 0 keeps
    /// it until it is closed.
    static var previewCloseAfter: Int {
        get {
            PreviewTiming.closeAfter(stored: UserDefaults.standard.object(forKey: "previewCloseAfter") as? Int,
                                     earlier: UserDefaults.standard.object(forKey: "previewAutoClose") as? Bool)
        }
        set { UserDefaults.standard.set(newValue, forKey: "previewCloseAfter") }
    }
    static var recordingPreviewCloseAfter: Int {
        get { PreviewTiming.closeAfter(stored: UserDefaults.standard.object(forKey: "recordingPreviewCloseAfter") as? Int, earlier: nil) }
        set { UserDefaults.standard.set(newValue, forKey: "recordingPreviewCloseAfter") }
    }

    // What happens to a capture by itself, without the preview's buttons.
    static var copyAfterCapture: Bool {
        get { flag("copyAfterCapture", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: "copyAfterCapture") }
    }
    static var saveAfterCapture: Bool {
        get { flag("saveAfterCapture", default: false) }
        set { UserDefaults.standard.set(newValue, forKey: "saveAfterCapture") }
    }
    /// A recording stops by itself at this size (`RecordingSize`).
    static var maxRecordingGigabytes: Int {
        get { RecordingSize.gigabytes(stored: UserDefaults.standard.object(forKey: "maxRecordingGigabytes") as? Int) }
        set { UserDefaults.standard.set(RecordingSize.gigabytes(stored: newValue), forKey: "maxRecordingGigabytes") }
    }

    /// Where captures are saved, and where save panels open: the folder chosen here, or
    /// the one the system saves its own screenshots to.
    static var saveDirectory: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: "saveDirectory") {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                    return URL(fileURLWithPath: path, isDirectory: true)
                }
            }
            return systemSaveDirectory
        }
        set { UserDefaults.standard.set(newValue.path, forKey: "saveDirectory") }
    }
    /// Folder the system saves screenshots to, falling back to the Desktop.
    private static var systemSaveDirectory: URL {
        if let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               isDirectory.boolValue { return url }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    /// The patterns saved files are named by; see `FileNaming`.
    static var screenshotNameFormat: String {
        get { UserDefaults.standard.string(forKey: FileNaming.screenshotKey) ?? FileNaming.screenshotDefault }
        set { UserDefaults.standard.set(newValue, forKey: FileNaming.screenshotKey) }
    }
    static var recordingNameFormat: String {
        get { UserDefaults.standard.string(forKey: FileNaming.recordingKey) ?? FileNaming.recordingDefault }
        set { UserDefaults.standard.set(newValue, forKey: FileNaming.recordingKey) }
    }

    /// Covers the desktop icons while a screenshot or a recording is taken; see `DesktopCover`.
    static var hideDesktopIcons: Bool {
        get { flag("hideDesktopIcons", default: false) }
        set { UserDefaults.standard.set(newValue, forKey: "hideDesktopIcons") }
    }
    /// With the preview off, a finished recording goes straight to the save folder.
    static var recordingPreviewEnabled: Bool {
        get { flag("recordingPreviewEnabled", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: "recordingPreviewEnabled") }
    }
    static var fadePinsOnHover: Bool {
        get { flag("fadeEnabled", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: "fadeEnabled") }
    }
    /// With the icon hidden, opening the app again shows it together with the settings.
    static var hideMenuBarIcon: Bool {
        get { flag("hideMenuBarIcon", default: false) }
        set { UserDefaults.standard.set(newValue, forKey: "hideMenuBarIcon") }
    }

    /// The shadow around a window capture: 0 for none, up to `WindowShadowLevel.system`
    /// for the system's own.
    static var windowShadowLevel: Int {
        get {
            WindowShadowLevel.level(stored: UserDefaults.standard.object(forKey: "windowShadowLevel") as? Int,
                               earlier: UserDefaults.standard.string(forKey: "windowShadow"))
        }
        set { UserDefaults.standard.set(newValue, forKey: "windowShadowLevel") }
    }

    /// The global shortcut of each action that has one.
    static var shortcuts: [ShortcutAction: Shortcut] {
        get {
            var table: [ShortcutAction: Shortcut] = [:]
            for action in ShortcutAction.allCases {
                table[action] = action.shortcut(fromStored: UserDefaults.standard.string(forKey: action.preferenceKey))
            }
            return table
        }
        set {
            // An empty text, not a missing one: missing means the default.
            for action in ShortcutAction.allCases {
                UserDefaults.standard.set(newValue[action]?.stored ?? "", forKey: action.preferenceKey)
            }
        }
    }

    static var openAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    static func setOpenAtLogin(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
