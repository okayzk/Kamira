import Foundation

/// What the app itself reads: the demo arguments (Sources/App/).
func testApp() {
    // Demo modes: the arguments become what to show, in the order the app always showed them
    // (not the order typed), with the picture demos last and in the order given.
    do {
        check(Demo.parse(["Kamira"]).isEmpty, "no arguments, no demos")
        check(!Demo.isAny(["Kamira", "--quiet"]) && Demo.isAny(["Kamira", "--demo-show-capture-ui"]),
              "any --demo- argument counts as a demo run")
        let mixed = Demo.parse(["Kamira", "--demo-preview", "/a.png", "--demo-palette", "--demo-welcome-pending",
                                "--demo-pin", "/b.png", "--demo-settings"])
        check(mixed == [.welcome(pending: true), .palette, .settings(nil), .preview(URL(fileURLWithPath: "/a.png")),
                        .pin(URL(fileURLWithPath: "/b.png"))], "fixed order, pictures last, got \(mixed)")
        check(Demo.parse(["K", "--demo-welcome"]) == [.welcome(pending: false)], "the welcome window")
        check(Demo.parse(["K", "--demo-about", "--demo-settings-screenshots"]) == [.settings(.screenshots), .settings(.about)],
              "panes in their own order")
        check(Demo.parse(["K", "--demo-shortcut-guide"]) == [.settings(.shortcuts), .shortcutGuide],
              "the guide opens on the shortcuts pane")
        check(Demo.parse(["K", "--demo-shortcuts", "--demo-shortcut-guide"]) == [.settings(.shortcuts), .shortcutGuide],
              "the shortcuts pane once")
        let record = Demo.parse(["K", "--demo-record", "3", "--region", "0,0,320,200", "--gif", "--screen", "1",
                                 "--window", "77"])
        check(record == [.record(seconds: 3, region: CGRect(x: 0, y: 0, width: 320, height: 200), screen: 1,
                                 window: 77, gif: true, microphone: false)], "a recording, got \(record)")
        check(Demo.parse(["K", "--demo-record", "2", "--mic"]) == [.record(seconds: 2, region: nil, screen: nil, window: nil,
                                                                         gif: false, microphone: true)], "the whole screen")
        check(Demo.parse(["K", "--demo-record", "soon"]).isEmpty, "a recording needs its seconds")
        check(Demo.parse(["K", "--demo-record", "2", "--region", "1,2,3"]) == [.record(seconds: 2, region: nil, screen: nil,
                                                                                    window: nil, gif: false, microphone: false)],
              "a region needs four numbers")
        check(Demo.parse(["K", "--demo-scroll", "10,20,300,400"]) == [.scroll(area: CGRect(x: 10, y: 20, width: 300, height: 400))],
              "a scrolling capture")
        check(Demo.parse(["K", "--demo-scroll", "10,20"]).isEmpty, "a scrolling capture needs four numbers")
        check(Demo.parse(["K", "--demo-unpin", "4", "--demo-ocr", "/t.png", "--demo-recording", "/r.mp4",
                          "--demo-select", "--demo-menu", "--demo-login-item"])
              == [.loginItem, .menu, .select, .unpin(after: 4), .recognizeText(URL(fileURLWithPath: "/t.png")),
                  .recording(URL(fileURLWithPath: "/r.mp4"))], "the others in their order")
        check(Demo.parse(["K", "--demo-edit", "/e.png", "--demo-draw", "/d.png"])
              == [.edit(URL(fileURLWithPath: "/e.png"), mode: nil), .edit(URL(fileURLWithPath: "/d.png"), mode: "--demo-draw")],
              "the editor, plain and drawing")
        check(Demo.parse(["K", "--demo-several", "/a.png", "--demo-pin", "/p.png", "--demo-several", "/b.png"])
              == [.pin(URL(fileURLWithPath: "/p.png")), .several([URL(fileURLWithPath: "/a.png"), URL(fileURLWithPath: "/b.png")])],
              "several pictures make one demo, after the single ones")
        check(Demo.parse(["K", "--demo-preview"]).isEmpty, "a picture demo needs its file")
    }

    // A helper process ends with the app that started it. The app here is a shell that
    // starts this test program as a probe and leaves, at once or after a while.
    do {
        func probe(parentLasting seconds: Double) -> pid_t? {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("kamira-probe-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: file) }
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/sh")
            shell.arguments = ["-c", "\"$0\" --parent-watch-probe >/dev/null 2>&1 & echo $! > \"$1\"; sleep \(seconds)",
                               CommandLine.arguments[0], file.path]
            guard (try? shell.run()) != nil else { return nil }
            for _ in 0..<40 {
                if let text = try? String(contentsOf: file, encoding: .utf8),
                   let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return pid }
                Thread.sleep(forTimeInterval: 0.05)
            }
            return nil
        }
        func ends(_ pid: pid_t, within seconds: Double) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if kill(pid, 0) != 0 { return true }
                Thread.sleep(forTimeInterval: 0.05)
            }
            kill(pid, SIGKILL)
            return false
        }
        if let early = probe(parentLasting: 0) {
            check(ends(early, within: 2), "a helper whose app is already gone ends")
        } else { check(false, "the probe did not start") }
        if let late = probe(parentLasting: 1) {
            Thread.sleep(forTimeInterval: 0.4)
            check(kill(late, 0) == 0, "a helper keeps running while its app does")
            check(ends(late, within: 3), "a helper ends when its app goes")
        } else { check(false, "the probe did not start") }
    }
}
