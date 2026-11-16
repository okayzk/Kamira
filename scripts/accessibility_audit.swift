// Reads every window of the built app the way VoiceOver and other assistive apps do,
// in each demo mode, and lists what they could not use: a control without a name, a
// control or window without a stable identifier, a window with nothing in it.
// Run by scripts/accessibility_audit.sh, which builds it; needs the Accessibility
// permission for the terminal (System Settings → Privacy & Security → Accessibility).
import AppKit
import ApplicationServices
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("usage: accessibility_audit <app executable> <work directory> [--all]")
    exit(2)
}
/// The recording selector dims every screen while it is read, so it is left out unless asked for.
let includeSelector = arguments.contains("--all")
let executable = arguments[1]
let work = URL(fileURLWithPath: arguments[2], isDirectory: true)
guard AXIsProcessTrusted() else {
    print("The terminal needs the Accessibility permission (System Settings → Privacy & Security → Accessibility).")
    exit(2)
}

// MARK: Sample files for the demo modes

/// A picture with something on it, as a screenshot would be.
func writeSample(_ type: UTType, to url: URL) {
    let context = CGContext(data: nil, width: 640, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
    context.setFillColor(CGColor(red: 0.2, green: 0.45, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 60, y: 60, width: 300, height: 180))
    let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
}
try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
let image = work.appendingPathComponent("sample.png")
let gif = work.appendingPathComponent("sample.gif")
writeSample(.png, to: image)
writeSample(.gif, to: gif)

/// Each surface of the app, opened by its demo mode. `--demo-edit` opens the editor in a
/// helper process, which is read as well. A scrolling capture's helper shows only the live
/// preview, a picture with nothing to act on, so its windows are left out.
let unreadHelpers: Set<String> = ["Scrolling capture"]
let scenarios: [(name: String, flags: [String])] = [
    ("Quick Panel", ["--demo-palette"]),
    ("Screenshot preview", ["--demo-preview", image.path]),
    ("Recording preview", ["--demo-recording", gif.path]),
    ("Pin", ["--demo-pin", image.path]),
    ("Editor", ["--demo-edit", image.path]),
    ("Settings: General", ["--demo-settings"]),
    ("Settings: Screenshots", ["--demo-settings-screenshots"]),
    ("Settings: Recording", ["--demo-settings-recording"]),
    ("Settings: Shortcuts", ["--demo-shortcuts"]),
    ("Settings: About", ["--demo-about"]),
    ("Welcome", ["--demo-welcome"]),
    ("Scrolling capture", ["--demo-scroll", "200,200,600,400"])
] + (includeSelector ? [("Recording selector", ["--demo-select"])] : [])

// MARK: Reading the tree

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func text(_ element: AXUIElement, _ name: String) -> String {
    guard let value = attribute(element, name), CFGetTypeID(value) == CFStringGetTypeID() else { return "" }
    return (value as! String).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// What a person using VoiceOver would hear as the element's name.
func name(of element: AXUIElement) -> String {
    for key in [kAXTitleAttribute, kAXDescriptionAttribute] where !text(element, key).isEmpty {
        return text(element, key)
    }
    if let title = attribute(element, kAXTitleUIElementAttribute), CFGetTypeID(title) == AXUIElementGetTypeID() {
        let titleElement = title as! AXUIElement
        return text(titleElement, kAXValueAttribute).isEmpty ? text(titleElement, kAXTitleAttribute)
                                                            : text(titleElement, kAXValueAttribute)
    }
    return ""
}

func children(of element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

/// Roles a person acts on; each needs a name and an identifier.
let controls: Set<String> = ["AXButton", "AXRadioButton", "AXCheckBox", "AXPopUpButton", "AXMenuButton",
                             "AXSlider", "AXTextField", "AXComboBox", "AXIncrementor", "AXLink"]

/// An identifier AppKit made up is not stable.
func hasIdentifier(_ element: AXUIElement) -> Bool {
    let identifier = text(element, kAXIdentifierAttribute)
    return !identifier.isEmpty && !identifier.hasPrefix("_NS:")
}

/// The tool bar of the settings window and the close, minimise and zoom buttons belong
/// to the system.
let windowButtons: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"]
func isSystemPart(_ element: AXUIElement, path: [String]) -> Bool {
    path.contains { $0.hasPrefix("AXToolbar") } || windowButtons.contains(text(element, kAXSubroleAttribute))
}

/// The segments of a segmented control have no identifiers of their own; the control has.
func isSegment(_ element: AXUIElement) -> Bool {
    guard text(element, kAXRoleAttribute) == "AXRadioButton",
          let parent = attribute(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
    return hasIdentifier(parent as! AXUIElement)
}

var problems: [String] = []

func audit(_ element: AXUIElement, path: [String], scenario: String) {
    let role = text(element, kAXRoleAttribute)
    let label = name(of: element)
    let here = path + [label.isEmpty ? role : "\(role) “\(label)”"]
    let location = "\(scenario): " + here.joined(separator: " › ")
    var actions: CFArray?
    let acts = AXUIElementCopyActionNames(element, &actions) == .success
        ? ((actions as? [String]) ?? []).filter { !["AXShowMenu", "AXScrollToVisible", "AXRaise"].contains($0) } : []
    let actionable = controls.contains(role) || (role == "AXImage" && !acts.isEmpty)
    if actionable && !isSystemPart(element, path: path) {
        if label.isEmpty { problems.append("\(location): no name") }
        if !hasIdentifier(element) && !isSegment(element) { problems.append("\(location): no identifier") }
    }
    for child in children(of: element) { audit(child, path: here, scenario: scenario) }
}

func windowCount(of pid: pid_t) -> Int {
    ((attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement]) ?? []).count
}

func auditWindows(of pid: pid_t, scenario: String) -> Int {
    let windows = (attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement]) ?? []
    for window in windows {
        let title = text(window, kAXTitleAttribute)
        let identifier = text(window, kAXIdentifierAttribute)
        let label = "AXWindow “\(title.isEmpty ? identifier : title)”"
        if !hasIdentifier(window) { problems.append("\(scenario): \(label): no identifier") }
        if children(of: window).isEmpty { problems.append("\(scenario): \(label): nothing in it") }
        audit(window, path: [], scenario: scenario)
    }
    return windows.count
}

// MARK: Running each demo

func childProcesses(of pid: pid_t) -> [pid_t] {
    let pgrep = Process()
    let pipe = Pipe()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-P", String(pid)]
    pgrep.standardOutput = pipe
    try? pgrep.run()
    pgrep.waitUntilExit()
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return output.split(separator: "\n").compactMap { pid_t($0) }
}

for scenario in scenarios {
    let app = Process()
    app.executableURL = URL(fileURLWithPath: executable)
    // Quiet: no focus, no shortcuts, no menu bar icon, clicks pass through (QuietMode).
    app.arguments = scenario.flags + ["--quiet", "-AppleLanguages", "(en)"]
    app.standardOutput = FileHandle.nullDevice
    app.standardError = FileHandle.nullDevice
    try! app.run()
    // Until the first window is up (a cold start takes longer), then a moment for its content.
    for _ in 0..<24 where windowCount(of: app.processIdentifier) == 0 { Thread.sleep(forTimeInterval: 0.25) }
    Thread.sleep(forTimeInterval: 0.5)
    var windows = auditWindows(of: app.processIdentifier, scenario: scenario.name)
    let helpers = childProcesses(of: app.processIdentifier)
    for helper in helpers where !unreadHelpers.contains(scenario.name) {
        windows += auditWindows(of: helper, scenario: scenario.name)
    }
    if windows == 0 { problems.append("\(scenario.name): no window to read") }
    // Read again: a helper may have started while the windows were read.
    for helper in childProcesses(of: app.processIdentifier) { kill(helper, SIGTERM) }
    app.terminate()
    app.waitUntilExit()
}

if problems.isEmpty {
    print("Accessibility audit: every control has a name and an identifier (\(scenarios.count) surfaces).")
    exit(0)
}
problems.forEach { print($0) }
print("\(problems.count) problem(s).")
exit(1)
