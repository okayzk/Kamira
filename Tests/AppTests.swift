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
        check(Demo.parse(["K", "--demo-preview"]).isEmpty, "a picture demo needs its file")
    }
}
