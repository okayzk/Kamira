import AppKit
import Carbon.HIToolbox

/// What more than one feature uses (Sources/Shared/).
func testShared() {
    // A Retina capture: pixel size is reported as-is, point size is halved.
    if let capture = CapturedImage(data: retinaPNG) {
        check(capture.pixelSize == CGSize(width: 800, height: 400), "pixel size, got \(capture.pixelSize)")
        check(capture.pointSize == CGSize(width: 400, height: 200), "point size, got \(capture.pointSize)")
        check(capture.pngData() == retinaPNG, "PNG input must be passed through untouched")
        if let small = capture.downsampled(maxPixel: 200) {
            check(small.width == 200 && small.height == 100, "downsample to 200, got \(small.width)x\(small.height)")
        } else { check(false, "downsampled returned nil") }
        if let same = capture.downsampled(maxPixel: 5000) {
            check(same.width == 800, "downsampling must never upscale, got \(same.width)")
        } else { check(false, "downsampled returned nil") }
        check(capture.suggestedFileName.hasSuffix(".png"), "file name, got \(capture.suggestedFileName)")
    } else { check(false, "PNG data was rejected") }

    // Non-Retina TIFF (what some apps put on the clipboard): converted to PNG on export.
    let tiff = makeImageData(width: 300, height: 300, dpi: 72, type: .tiff)
    if let capture = CapturedImage(data: tiff) {
        check(capture.pointSize == CGSize(width: 300, height: 300), "72 dpi point size, got \(capture.pointSize)")
        if let png = capture.pngData() {
            check(isPNG(png), "TIFF input must be exported as PNG")
            check(CapturedImage(data: png)?.pixelSize == CGSize(width: 300, height: 300), "converted PNG keeps its size")
        } else { check(false, "pngData returned nil for TIFF") }
    } else { check(false, "TIFF data was rejected") }

    check(CapturedImage(data: Data("not an image".utf8)) == nil, "garbage data must be rejected")

        // The setting: 0 is none, the last step is the system's own shadow. A choice made
        // before there were steps carries over.
        check(WindowShadowLevel.level(stored: nil, earlier: nil) == 1, "small by default")
        check(WindowShadowLevel.level(stored: 3, earlier: "none") == 3, "the stored step wins")
        check(WindowShadowLevel.level(stored: 9, earlier: nil) == WindowShadowLevel.system, "kept within the steps")
        check(WindowShadowLevel.level(stored: nil, earlier: "none") == 0, "earlier choice: none")
        check(WindowShadowLevel.level(stored: nil, earlier: "small") == 1, "earlier choice: small")
        check(WindowShadowLevel.level(stored: nil, earlier: "system") == WindowShadowLevel.system, "earlier choice: system")
        check(WindowShadowLevel.system == 4, "five steps from none to the system's")

    // File-backed captures.
    let storeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("ce-test-store-\(getpid())")
    var storedFile: URL?
    do {
        let stored = CapturedImage.stored(makeImageData(width: 60, height: 40, dpi: 144, type: .png), in: storeDirectory)
        check(stored != nil, "a capture can be stored in a file")
        storedFile = stored?.fileURL
        check(storedFile?.pathExtension == "png", "PNG data is stored with a .png extension")
        check(storedFile.map { FileManager.default.fileExists(atPath: $0.path) } == true, "the file exists while the capture does")
        check(stored?.pixelSize == CGSize(width: 60, height: 40), "a stored capture reads its size")
        check(stored?.pngData().map(isPNG) == true, "a stored capture still yields PNG data")
    }
    check(storedFile.map { FileManager.default.fileExists(atPath: $0.path) } == false, "the file is deleted with the capture")
    let junk = storeDirectory.appendingPathComponent("junk.png")
    try? Data("not an image".utf8).write(to: junk)
    check(CapturedImage(owningFile: junk) == nil, "a file that is not an image is rejected")
    check(!FileManager.default.fileExists(atPath: junk.path), "a rejected file is deleted too")

    // A copied image file is the file's own picture, even when Finder puts the file's
    // icon beside it, and the file itself is left where it was.
    do {
        let originals = storeDirectory.appendingPathComponent("originals", isDirectory: true)
        try? FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        func clipboard(file: URL, icon: Data? = nil) -> NSPasteboard {
            let pasteboard = NSPasteboard.withUniqueName()
            pasteboard.clearContents()
            pasteboard.setString(file.absoluteString, forType: .fileURL)
            if let icon = icon { pasteboard.setData(icon, forType: .tiff) }
            return pasteboard
        }
        let pngFile = originals.appendingPathComponent("Photo.png")
        try? makeImageData(width: 60, height: 40, dpi: 144, type: .png).write(to: pngFile)
        let icon = makeImageData(width: 32, height: 32, dpi: 72, type: .tiff)
        let pasted = CapturedImage.fromPasteboard(clipboard(file: pngFile, icon: icon), storingIn: storeDirectory)
        check(pasted?.pixelSize == CGSize(width: 60, height: 40), "an image file is read, not its icon, got \(String(describing: pasted?.pixelSize))")
        check(pasted?.pointSize == CGSize(width: 30, height: 20), "an image file keeps its resolution")
        check(pasted?.fileURL != nil && pasted?.fileURL != pngFile, "a copy of the file backs the capture")
        check(FileManager.default.fileExists(atPath: pngFile.path), "the copied file stays where it was")

        let jpegFile = originals.appendingPathComponent("Photo.jpg")
        try? makeImageData(width: 50, height: 20, dpi: 72, type: .jpeg).write(to: jpegFile)
        let jpeg = CapturedImage.fromPasteboard(clipboard(file: jpegFile), storingIn: storeDirectory)
        check(jpeg?.pixelSize == CGSize(width: 50, height: 20), "a JPEG file is read too")
        check(jpeg?.pngData().map(isPNG) == true && jpeg?.fileURL?.pathExtension == "png", "a JPEG file is kept as PNG")

        let textFile = originals.appendingPathComponent("Notes.txt")
        try? Data("not an image".utf8).write(to: textFile)
        check(CapturedImage.fromPasteboard(clipboard(file: textFile), storingIn: storeDirectory) == nil,
              "a file that is not an image gives nothing")
        check(FileManager.default.fileExists(atPath: textFile.path), "a file that is not an image is left alone")
    }
    try? FileManager.default.removeItem(at: storeDirectory)

    // File names from the user's pattern, and a free place for them in the folder.
    do {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 11; parts.day = 13; parts.hour = 17; parts.minute = 4; parts.second = 9
        let date = Calendar.current.date(from: parts)!
        check(FileNaming.name(format: "Screenshot %Y-%m-%d at %H.%M.%S", date: date, fallback: "x")
                == "Screenshot 2026-11-13 at 17.04.09", "the default pattern")
        check(FileNaming.name(format: "截图 %m%d", date: date, fallback: "x") == "截图 1113", "words around the date stay as they are")
        // A name cannot hold what would be taken for a folder or, in Finder, shown as one.
        check(FileNaming.name(format: "a/b:c %H:%M", date: date, fallback: "x") == "a-b-c 17-04", "no slashes or colons")
        check(FileNaming.name(format: "   ", date: date, fallback: "Screenshot %Y") == "Screenshot 2026", "an empty pattern gives the default")
        check(FileNaming.name(format: ".hidden", date: date, fallback: "x") == "hidden", "never a hidden file")

        let folder = URL(fileURLWithPath: "/tmp/ce-names", isDirectory: true)
        let taken: Set<String> = ["Shot.png", "Shot 2.png"]
        let free = FileNaming.available("Shot", extension: "png", in: folder) { taken.contains($0.lastPathComponent) }
        check(free.lastPathComponent == "Shot 3.png", "a taken name gets the next number, got \(free.lastPathComponent)")
        let first = FileNaming.available("New", extension: "mp4", in: folder) { taken.contains($0.lastPathComponent) }
        check(first.path == "/tmp/ce-names/New.mp4", "a free name stays as it is, got \(first.path)")

        // How long a preview stays: seconds, 0 for until it is closed. The earlier on/off
        // setting meant ten seconds.
        check(PreviewTiming.closeAfter(stored: nil, earlier: nil) == 0, "previews stay by default")
        check(PreviewTiming.closeAfter(stored: nil, earlier: true) == 10, "the earlier setting carries over")
        check(PreviewTiming.closeAfter(stored: 30, earlier: true) == 30, "the stored time wins")
        check(PreviewTiming.closeAfter(stored: -5, earlier: nil) == 0, "never negative")
        check(PreviewTiming.choices(including: 10) == [0, 5, 10, 30, 60], "the times offered")
        check(PreviewTiming.choices(including: 20) == [0, 5, 10, 20, 30, 60], "a time set by hand is offered too")
    }

    // Shortcuts: how they are shown, kept in the preferences, and checked against the system's.
    do {
        let area = Shortcut(keyCode: 21, modifiers: UInt32(shiftKey | cmdKey), key: "4")
        check(area.display == "⇧⌘4", "display, got \(area.display)")
        let all = Shortcut(keyCode: 1, modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey), key: "s")
        check(all.display == "⌃⌥⇧⌘S", "modifiers in the system's order and the key in capitals, got \(all.display)")
        // Keys that print nothing are named by their key code, whatever the event reported.
        check(Shortcut(keyCode: 49, modifiers: UInt32(controlKey), key: " ").display == "⌃Space", "space bar")
        check(Shortcut(keyCode: 122, modifiers: 0, key: "\u{F704}").display == "F1", "function key")

        check(Shortcut(stored: area.stored) == area, "a stored shortcut reads back, stored as \(area.stored)")
        let comma = Shortcut(keyCode: 43, modifiers: UInt32(cmdKey), key: ",")
        check(Shortcut(stored: comma.stored) == comma, "a comma key survives storing, stored as \(comma.stored)")
        check(Shortcut(stored: "") == nil && Shortcut(stored: "x,1,a") == nil, "garbage is not a shortcut")

        // A global shortcut needs ⌘, ⌃ or ⌥: a letter alone or with Shift would swallow typing.
        check(area.isUsable, "⇧⌘4 is usable")
        check(!Shortcut(keyCode: 1, modifiers: UInt32(shiftKey), key: "s").isUsable, "⇧S is not usable")
        check(!Shortcut(keyCode: 1, modifiers: 0, key: "s").isUsable, "S alone is not usable")
        check(Shortcut(keyCode: 122, modifiers: 0, key: "").isUsable, "a function key alone is usable")

        // The modifiers AppKit reports for a key press, and the ones a menu item wants.
        let pressed = Shortcut(keyCode: 21, flags: [.shift, .command, .capsLock, .numericPad], key: "4")
        check(pressed == area, "AppKit flags become Carbon modifiers, extras ignored")
        check(area.menuModifiers == [.shift, .command] && area.menuKey == "4", "menu item for ⇧⌘4")
        check(all.menuKey == "s", "menu keys are lower case, got \(all.menuKey)")

        // The system's own shortcuts win while they are switched on.
        let system = [SystemHotKey(keyCode: 21, modifiers: UInt32(shiftKey | cmdKey), enabled: true),
                      SystemHotKey(keyCode: 20, modifiers: UInt32(shiftKey | cmdKey), enabled: false)]
        check(area.isTaken(by: system), "⇧⌘4 is taken while the system's is on")
        check(!Shortcut(keyCode: 20, modifiers: UInt32(shiftKey | cmdKey), key: "3").isTaken(by: system),
              "⇧⌘3 is free once the system's is off")
        check(!Shortcut(keyCode: 21, modifiers: UInt32(cmdKey), key: "4").isTaken(by: system), "⌘4 is another shortcut")
        check(!SystemHotKey.current().isEmpty, "the system reports its shortcuts")

        // Defaults are the system's screenshot shortcuts; the other actions start without one.
        check(ShortcutAction.area.defaultShortcut?.display == "⇧⌘4", "default for an area")
        check(ShortcutAction.screen.defaultShortcut?.display == "⇧⌘3", "default for the screen")
        check(ShortcutAction.panel.defaultShortcut?.display == "⇧⌘5", "default for the Quick Panel")
        check(ShortcutAction.record.defaultShortcut == nil, "recording has no default")
        // The welcome window asks for the system's to be switched off while any shortcut in use is taken.
        let systemOn = [SystemHotKey(keyCode: 21, modifiers: UInt32(shiftKey | cmdKey), enabled: true)]
        let systemOff = [SystemHotKey(keyCode: 21, modifiers: UInt32(shiftKey | cmdKey), enabled: false)]
        let defaults = [ShortcutAction.area: area]
        check(ShortcutAction.anyTaken(defaults, by: systemOn), "⇧⌘4 is taken while the system's is on")
        check(!ShortcutAction.anyTaken(defaults, by: systemOff), "and free once it is off")
        check(!ShortcutAction.anyTaken([.area: Shortcut(keyCode: 21, modifiers: UInt32(cmdKey | optionKey), key: "4")], by: systemOn),
              "a shortcut of one's own is free")
        check(Set(ShortcutAction.allCases.map(\.hotKeyID)).count == ShortcutAction.allCases.count, "distinct hot key ids")

        // One shortcut belongs to one action: giving it to another takes it from the first.
        var table: [ShortcutAction: Shortcut] = [.area: area, .screen: all]
        table = ShortcutAction.assigning(area, to: .record, in: table)
        check(table[.record] == area && table[.area] == nil && table[.screen] == all, "moved to the new action")
        table = ShortcutAction.assigning(nil, to: .screen, in: table)
        check(table[.screen] == nil && table[.record] == area, "cleared")

        // What the preferences hold: nothing means the default, an empty text means none.
        check(ShortcutAction.area.shortcut(fromStored: nil) == ShortcutAction.area.defaultShortcut, "unset: default")
        check(ShortcutAction.area.shortcut(fromStored: "") == nil, "empty: no shortcut")
        check(ShortcutAction.record.shortcut(fromStored: area.stored) == area, "stored: that shortcut")
    }

    // The largest a recording may grow, and how long that lasts on a given screen.
    do {
        check(RecordingSize.gigabytes(stored: nil) == RecordingSize.defaultGigabytes, "unset: the default")
        check(RecordingSize.gigabytes(stored: 0) == 1 && RecordingSize.gigabytes(stored: -3) == 1, "at least 1 GB")
        check(RecordingSize.gigabytes(stored: 5000) == 1000, "at most 1000 GB")
        check(RecordingSize.gigabytes(stored: 20) == 20, "a stored size is kept")
        check(RecordingSize.bytes(gigabytes: 10) == 10_000_000_000, "GB as Finder counts them")
        // Measured on a 3840 x 2160 screen: 10 GB lasts about 43 minutes of constant motion
        // and about 277 minutes of a still screen.
        let span = RecordingSize.minutes(gigabytes: 10, pixels: 3840 * 2160)
        check(span.shortest == 43 && span.longest == 277, "10 GB at 4K, got \(span)")
        let small = RecordingSize.minutes(gigabytes: 10, pixels: 1440 * 900)
        check(small.shortest > span.shortest * 6, "a smaller screen lasts longer, got \(small)")
    }

    // A stored capture is the very file a drag hands over: a PNG under its readable name,
    // in a folder of its own, gone with the capture; a dragged-out one lingers a while.
    do {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kamira-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var capture = CapturedImage.stored(retinaPNG, in: folder)
        let file = capture?.fileURL
        check(file?.lastPathComponent == capture?.suggestedFileName, "named as it will be dragged, got \(file?.lastPathComponent ?? "nil")")
        check(file?.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL,
              "in a folder of its own inside the capture folder")
        let tiff = CapturedImage.stored(makeImageData(width: 30, height: 20, dpi: 72, type: .tiff), in: folder)
        check(tiff?.fileURL?.pathExtension == "png" && (try? Data(contentsOf: tiff!.fileURL!)).map(isPNG) == true,
              "a TIFF is stored as PNG")
        capture = nil
        check(file.map { !FileManager.default.fileExists(atPath: $0.path) } == true, "the file goes with the capture")
        check(file.map { !FileManager.default.fileExists(atPath: $0.deletingLastPathComponent().path) } == true, "and its folder")

        CapturedImage.dragGrace = 0.2
        var dragged = CapturedImage.stored(retinaPNG, in: folder)
        let draggedFile = dragged!.fileURL!
        dragged?.wasDraggedOut = true
        dragged = nil
        check(FileManager.default.fileExists(atPath: draggedFile.path), "a dragged-out file outlives its capture for a while")
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        check(!FileManager.default.fileExists(atPath: draggedFile.path), "and is gone after the grace period")
    }

    // Updates: the three choices in Settings are Sparkle's two flags, and back.
    for policy in UpdatePolicy.allCases {
        check(UpdatePolicy(checks: policy.checks, installs: policy.installs) == policy, "\(policy) survives Sparkle's flags")
    }
    check(!UpdatePolicy.manual.checks && !UpdatePolicy.manual.installs, "manual neither checks nor installs")
    check(UpdatePolicy.ask.checks && !UpdatePolicy.ask.installs, "ask checks, then asks")
    check(UpdatePolicy.automatic.checks && UpdatePolicy.automatic.installs, "automatic checks and installs")
    check(UpdatePolicy(checks: false, installs: true) == .manual, "no checks means manual, whatever else is stored")
    check(UpdatePolicy.interval(nearest: 86_400) == 86_400, "a day stays a day")
    check(UpdatePolicy.interval(nearest: 3_600) == 86_400, "an hour shows as a day")
    check(UpdatePolicy.interval(nearest: 700_000) == 604_800, "about a week shows as a week")
    check(UpdatePolicy.interval(nearest: 10_000_000) == 2_592_000, "longer than a month shows as a month")
}
