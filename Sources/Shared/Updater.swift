import Sparkle

/// New versions, found and installed by Sparkle from the signed feed named in Info.plist
/// (SUFeedURL, written by scripts/build.sh). Sparkle shows its own windows. Going online
/// on its own is the user's choice (`policy`), off until they make it.
enum Updater {
    private static let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                                 userDriverDelegate: nil)

    /// Starts the updater, so that automatic checks run when they are on.
    static func start() { _ = controller }

    static var policy: UpdatePolicy {
        get {
            UpdatePolicy(checks: controller.updater.automaticallyChecksForUpdates,
                         installs: controller.updater.automaticallyDownloadsUpdates)
        }
        set {
            controller.updater.automaticallyChecksForUpdates = newValue.checks
            controller.updater.automaticallyDownloadsUpdates = newValue.installs
        }
    }

    /// Seconds between automatic checks, one of `UpdatePolicy.intervals`.
    static var interval: TimeInterval {
        get { UpdatePolicy.interval(nearest: controller.updater.updateCheckInterval) }
        set { controller.updater.updateCheckInterval = newValue }
    }

    static func checkNow() { controller.checkForUpdates(nil) }
}
