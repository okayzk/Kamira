import AppKit

/// Choosing a region to record or to capture while scrolling (Sources/Selection/).
func testSelection() {
    // The dimming around a selection: rectangles that cover the screen except the
    // selection, without overlapping it or each other.
    do {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        check(SelectionShade.dimmed(screen, except: nil) == [screen], "nothing selected: the whole screen is dimmed")
        let selection = CGRect(x: 300, y: 200, width: 640, height: 400)
        let parts = SelectionShade.dimmed(screen, except: selection)
        let area = parts.reduce(0) { $0 + $1.width * $1.height }
        check(area == screen.width * screen.height - selection.width * selection.height,
              "the dimming covers all but the selection, got \(parts)")
        check(parts.allSatisfy { !$0.intersects(selection) && screen.contains($0) }, "none over the selection or off screen")
        check(parts.indices.allSatisfy { i in parts.indices.allSatisfy { j in i == j || !parts[i].intersects(parts[j]) } },
              "no two overlap, or the overlap would be darker")
        let corner = CGRect(x: 0, y: 0, width: 500, height: 300)
        check(SelectionShade.dimmed(screen, except: corner).allSatisfy { $0.width > 0 && $0.height > 0 },
              "a selection at the edge leaves no empty pieces")
        check(SelectionShade.dimmed(screen, except: screen).isEmpty, "the whole screen selected: nothing dimmed")
    }

    // The size label sits below the selection, or inside it when the screen ends there.
    do {
        let text = CGSize(width: 60, height: 14)
        check(SelectionShade.labelFrame(for: CGRect(x: 300, y: 200, width: 640, height: 400), text: text)
                == CGRect(x: 300, y: 173, width: 72, height: 20), "below the selection")
        check(SelectionShade.labelFrame(for: CGRect(x: 300, y: 10, width: 640, height: 400), text: text)
                == CGRect(x: 300, y: 15, width: 72, height: 20), "inside it at the bottom of the screen")
    }
}
