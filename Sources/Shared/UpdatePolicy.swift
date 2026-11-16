import Foundation

/// How far the app goes on its own about new versions. Sparkle keeps this as two flags:
/// whether it checks, and whether it then downloads and installs without asking.
enum UpdatePolicy: CaseIterable {
    case manual, ask, automatic

    init(checks: Bool, installs: Bool) {
        self = !checks ? .manual : installs ? .automatic : .ask
    }
    var checks: Bool { self != .manual }
    var installs: Bool { self == .automatic }

    /// Seconds between checks offered in Settings: a day, a week, a month.
    static let intervals: [TimeInterval] = [86_400, 604_800, 2_592_000]

    /// The offered interval closest to `seconds`, which Sparkle may hold as any number.
    static func interval(nearest seconds: TimeInterval) -> TimeInterval {
        intervals.min { abs($0 - seconds) < abs($1 - seconds) }!
    }
}
