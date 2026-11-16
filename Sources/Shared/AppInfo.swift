import Foundation

/// The app's name, version and source, as `scripts/build.sh` wrote them into Info.plist
/// from `app.env`. Read from the bundle rather than written here, so that renaming the
/// app is one line in that file and not a search through the code.
enum AppInfo {
    private static func value(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    /// The executable carries the same name, which also covers a helper process.
    static let name = value("CFBundleName") ?? ProcessInfo.processInfo.processName
    static let version = value("CFBundleShortVersionString") ?? ""
    static let repository = value("AppRepositoryURL").flatMap(URL.init(string:))
}
