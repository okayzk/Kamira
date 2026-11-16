import Foundation

/// The steps of the window-shadow setting.
enum WindowShadowLevel {
    /// The steps of the setting run from 0, no shadow, to this one, the system's own;
    /// those in between are drawn by `WindowShadow`.
    static let system = 4
    /// The step the preferences hold. `earlier` is the choice of none, small or system
    /// that the setting was before it had steps.
    static func level(stored: Int?, earlier: String?) -> Int {
        if let stored = stored { return min(max(stored, 0), system) }
        switch earlier {
        case "none": return 0
        case "system": return system
        default: return 1
        }
    }
}
