import Foundation

/// The text named `key` in the user's language. English and Simplified Chinese each
/// have a full table of their own in `Resources/<language>.lproj/Localizable.strings`,
/// written separately rather than one translated from the other. Any other language
/// gets English (the bundle's development region).
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// The same for text with `%@` / `%d` placeholders.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: arguments)
}
