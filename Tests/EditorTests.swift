import AppKit

/// The annotation editor (Sources/Editor/).
func testEditor() {
    // Annotations are stored in image points and exported at full pixel resolution.
    let base = CapturedImage(data: makeImageData(width: 400, height: 200, dpi: 144, type: .png))! // 200×100 pt
    let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    let counter = Annotation(tool: .counter, color: red, points: [CGPoint(x: 50, y: 50)], text: "1")
    let box = Annotation(tool: .rectangle, color: red,
                         points: [CGPoint(x: 120, y: 20), CGPoint(x: 180, y: 80)])
    if let data = AnnotationRenderer.export(capture: base, annotations: [counter, box]),
       let out = CapturedImage(data: data), let image = out.fullSizeUncached() {
        check(out.pixelSize == CGSize(width: 400, height: 200), "export keeps pixel size, got \(out.pixelSize)")
        check(out.pointSize == CGSize(width: 200, height: 100), "export keeps point size, got \(out.pointSize)")
        let disc = pixel(image, x: 82, y: 100)      // inside the counter disc, left of the digit
        check(disc.r > 0.8 && disc.b < 0.3, "counter disc should be red, got \(disc)")
        let edge = pixel(image, x: 240, y: 100)     // on the rectangle's left edge
        check(edge.r > 0.8 && edge.b < 0.3, "rectangle edge should be red, got \(edge)")
        let inside = pixel(image, x: 300, y: 100)   // rectangle interior is not filled
        check(inside.r < 0.5 && inside.b > 0.6, "rectangle interior should be untouched, got \(inside)")
    } else { check(false, "export failed") }

    let boxOnly = Annotation(tool: .rectangle, color: red, points: [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 40)])
    check(boxOnly.rect == CGRect(x: 10, y: 10, width: 20, height: 30), "rect from two corners")
    let reversed = Annotation(tool: .rectangle, color: red, points: [CGPoint(x: 30, y: 40), CGPoint(x: 10, y: 10)])
    check(reversed.rect == boxOnly.rect, "rect must not depend on drag direction")

    // Editing a finished annotation: what a click hits, moving, and dragging a handle.
    do {
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        check(boxOnly.hitTest(at(10, 25), tolerance: 3), "a rectangle is hit on its outline")
        check(boxOnly.hitTest(at(32, 25), tolerance: 3), "a rectangle is hit just outside its outline")
        check(!boxOnly.hitTest(at(20, 25), tolerance: 3), "a rectangle is not hit in its empty middle")
        check(!boxOnly.hitTest(at(50, 25), tolerance: 3), "a rectangle is not hit far away")
        let ring = Annotation(tool: .ellipse, color: red, points: [at(0, 0), at(100, 60)])
        check(ring.hitTest(at(50, 60), tolerance: 3) && ring.hitTest(at(0, 30), tolerance: 3), "an ellipse is hit on its outline")
        check(!ring.hitTest(at(50, 30), tolerance: 3) && !ring.hitTest(at(2, 2), tolerance: 3),
              "an ellipse is not hit in its middle or in the corner of its box")
        let arrow = Annotation(tool: .arrow, color: red, points: [at(0, 0), at(100, 100)])
        check(arrow.hitTest(at(51, 49), tolerance: 3), "an arrow is hit along its line")
        check(!arrow.hitTest(at(80, 20), tolerance: 3), "an arrow is not hit beside its line")
        check(!arrow.hitTest(at(120, 120), tolerance: 3), "an arrow is not hit beyond its end")
        let stroke = Annotation(tool: .pen, color: red, points: [at(0, 0), at(50, 0), at(50, 50)])
        check(stroke.hitTest(at(50, 30), tolerance: 3) && !stroke.hitTest(at(25, 25), tolerance: 3), "a pen stroke is hit on the stroke only")
        let marker = Annotation(tool: .highlight, color: red, points: [at(10, 10), at(60, 30)])
        check(marker.hitTest(at(30, 20), tolerance: 3), "a highlight is hit anywhere inside")
        check(counter.hitTest(at(58, 55), tolerance: 3) && !counter.hitTest(at(80, 50), tolerance: 3), "a counter is hit on its disc")
        let label = Annotation(tool: .text, color: red, points: [at(20, 80)], text: "Hello")
        check(abs(label.bounds.maxY - 80) < 0.001 && label.bounds.minX == 20 && label.bounds.width > 30 && label.bounds.height > 15,
              "text hangs below its anchor, got \(label.bounds)")
        check(label.hitTest(at(30, 70), tolerance: 3) && !label.hitTest(at(30, 90), tolerance: 3), "text is hit on its box")

        check(stroke.moved(by: CGVector(dx: 5, dy: -2)).points == [at(5, -2), at(55, -2), at(55, 48)], "moving shifts every point")

        check(arrow.handles == [at(0, 0), at(100, 100)], "an arrow has a handle at each end")
        check(reversed.handles.count == 4 && Set(reversed.handles.map { "\($0.x),\($0.y)" }) == ["10.0,10.0", "30.0,10.0", "10.0,40.0", "30.0,40.0"],
              "a rectangle has a handle at each corner, got \(reversed.handles)")
        check(stroke.handles.isEmpty && label.handles.isEmpty && counter.handles.isEmpty, "pen, text and counter can only be moved")
        // Dragging a corner moves that corner and leaves the opposite one alone, whichever
        // way the rectangle was first drawn.
        for shape in [boxOnly, reversed] {
            guard let corner = shape.handles.firstIndex(of: at(30, 10)) else { check(false, "corner handle missing"); continue }
            check(shape.movingHandle(corner, to: at(50, 0)).rect == CGRect(x: 10, y: 0, width: 40, height: 40),
                  "dragging the bottom-right corner, got \(shape.movingHandle(corner, to: at(50, 0)).rect)")
        }
        check(arrow.movingHandle(1, to: at(40, 10)).points == [at(0, 0), at(40, 10)], "dragging an arrow's head")

        // The move is cut short at the image edge instead of losing the annotation.
        let limit = CGRect(x: 0, y: 0, width: 200, height: 100)
        check(boxOnly.moved(by: CGVector(dx: 500, dy: -500), keepingInside: limit).rect == CGRect(x: 180, y: 0, width: 20, height: 30),
              "a move stops at the image edge")

        // Deleting a counter closes the gap in the numbering.
        var marks = (1...3).map { Annotation(tool: .counter, color: red, points: [at(CGFloat($0) * 10, 10)], text: "\($0)") }
        marks.insert(boxOnly, at: 1)
        marks.remove(at: 0)
        check(Annotation.renumberingCounters(marks).map(\.text) == ["", "1", "2"], "counters are renumbered in order")
    }

    // Editor zoom: fixed steps for the button and the keys, limits for the pinch.
    check(EditorZoom.stepIn(from: 1) == 2 && EditorZoom.stepIn(from: 1.5) == 2, "zooming in goes to the next step")
    check(EditorZoom.stepIn(from: 8) == 8, "no step beyond the largest")
    check(EditorZoom.stepOut(from: 8) == 4 && EditorZoom.stepOut(from: 1.5) == 1, "zooming out goes to the step below")
    check(EditorZoom.stepOut(from: 1) == 1, "never smaller than the whole picture")
    check(EditorZoom.clamped(0.3) == 1 && EditorZoom.clamped(20) == 8 && EditorZoom.clamped(3) == 3, "zoom limits")
}
