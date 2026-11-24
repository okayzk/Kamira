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

    // A line is drawn end to end, with nothing at its end.
    check(AnnotationTool.allCases.firstIndex(of: .line) == 1, "the line comes right after the arrow")
    let rule = Annotation(tool: .line, color: red, points: [CGPoint(x: 20, y: 50), CGPoint(x: 180, y: 50)])
    if let data = AnnotationRenderer.export(capture: base, annotations: [rule]),
       let image = CapturedImage(data: data)?.fullSizeUncached() {
        let middle = pixel(image, x: 200, y: 100)
        check(middle.r > 0.8 && middle.b < 0.3, "a line is drawn along its length, got \(middle)")
        let end = pixel(image, x: 340, y: 100)
        check(end.r > 0.8 && end.b < 0.3, "a line reaches its end, got \(end)")
        for y in [88, 112] {
            let beside = pixel(image, x: 340, y: y)
            check(beside.r < 0.5 && beside.b > 0.6, "a line has no arrowhead, got \(beside) at y \(y)")
        }
    } else { check(false, "line export failed") }

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
        let line = Annotation(tool: .line, color: red, points: [at(100, 0), at(0, 100)])
        check(line.hitTest(at(49, 50), tolerance: 3), "a line is hit along its length")
        check(!line.hitTest(at(20, 20), tolerance: 3) && !line.hitTest(at(-20, 120), tolerance: 3),
              "a line is not hit beside it or beyond its end")
        check(line.bounds == CGRect(x: 0, y: 0, width: 100, height: 100), "a line's bounds span its ends")
        check(line.handles == [at(100, 0), at(0, 100)], "a line has a handle at each end")
        check(line.movingHandle(0, to: at(60, 40)).points == [at(60, 40), at(0, 100)], "dragging one end of a line")
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

        // Shift: lines and arrows in steps of 45°, rectangles square and ellipses round.
        let room = CGRect(x: -200, y: -200, width: 400, height: 400)
        func snap(_ tool: AnnotationTool, _ point: CGPoint, from anchor: CGPoint = at(0, 0), inside limit: CGRect = room) -> CGPoint {
            Annotation.snapped(point, from: anchor, tool: tool, inside: limit)
        }
        check(snap(.line, at(100, 10)) == at(100, 0), "a nearly level line becomes level, ending under the pointer")
        check(snap(.arrow, at(-8, 100)) == at(0, 100), "a nearly upright arrow becomes upright")
        check(snap(.line, at(-100, -6)) == at(-100, 0), "level towards the left too")
        let diagonal = snap(.line, at(100, 80))
        check(abs(diagonal.x - 90) < 0.001 && abs(diagonal.y - 90) < 0.001, "a line near 45° goes to 45°, got \(diagonal)")
        check(snap(.rectangle, at(50, 30), from: at(10, 10)) == at(50, 50), "a rectangle becomes a square as large as the longer side")
        check(snap(.ellipse, at(-20, 0), from: at(10, 10)) == at(-20, -20), "an ellipse becomes a circle, whichever way it is dragged")
        check(snap(.rectangle, at(50, 30), from: at(10, 10), inside: CGRect(x: 0, y: 0, width: 100, height: 40)) == at(40, 40),
              "a square stops at the edge of the image")
        let corner = snap(.line, at(100, 100), from: at(10, 10), inside: CGRect(x: 0, y: 0, width: 100, height: 40))
        check(abs(corner.x - 40) < 0.001 && abs(corner.y - 40) < 0.001, "a 45° line stops at the edge of the image, got \(corner)")
        check(snap(.pen, at(37, 11)) == at(37, 11) && snap(.highlight, at(37, 11)) == at(37, 11), "other tools are left alone")

        // Shift while dragging a handle: the opposite end or corner stays where it is.
        let wide = Annotation(tool: .rectangle, color: red, points: [at(0, 0), at(40, 20)])
        check(wide.movingHandle(3, to: at(50, 30), snappingInside: room).rect == CGRect(x: 0, y: 0, width: 50, height: 50),
              "dragging a corner with Shift keeps a square")
        check(wide.movingHandle(0, to: at(-5, 15), snappingInside: room).rect == CGRect(x: -5, y: -25, width: 45, height: 45),
              "dragging the opposite corner with Shift keeps a square too")
        let tilted = Annotation(tool: .line, color: red, points: [at(0, 0), at(100, 0)])
        let raised = tilted.movingHandle(1, to: at(60, 70), snappingInside: room).points[1]
        check(abs(raised.x - 65) < 0.001 && abs(raised.y - 65) < 0.001, "dragging a line's end with Shift turns it by 45°, got \(raised)")
        check(tilted.movingHandle(0, to: at(10, 3), snappingInside: room).points == [at(10, 0), at(100, 0)],
              "either end of a line can be dragged with Shift")

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

    testCropping(base: base, red: red, counter: counter)
    testLayers(red: red)
}

/// Several pictures in one editor: where each lies, which is on top, and the whole they make.
private func testLayers(red: CGColor) {
    let left = CGRect(x: 16, y: 16, width: 100, height: 50), right = CGRect(x: 132, y: 16, width: 60, height: 50)

    // One picture is the canvas, as before; several have the gap around them.
    check(LayerStack(frames: [CGRect(x: 0, y: 0, width: 200, height: 100)]).bounds == CGRect(x: 0, y: 0, width: 200, height: 100),
          "one picture: the canvas is the picture")
    var stack = LayerStack(frames: [left, right])
    check(stack.isSeveral && stack.bounds == CGRect(x: 0, y: 0, width: 208, height: 82), "several: the gap around them, got \(stack.bounds)")
    check(stack.layers.map(\.picture) == [0, 1], "in the order taken, the first at the bottom")

    // The topmost picture under a point; none in the gap.
    check(stack.topmost(at: CGPoint(x: 50, y: 40)) == 0 && stack.topmost(at: CGPoint(x: 150, y: 40)) == 1, "the picture under a point")
    check(stack.topmost(at: CGPoint(x: 124, y: 40)) == nil, "nothing in the gap")

    // A picture moved anywhere; the whole follows it, gap included.
    stack.move(1, to: CGPoint(x: 16, y: -100))
    check(stack.layers[1].frame == CGRect(x: 16, y: -100, width: 60, height: 50), "moved, got \(stack.layers[1].frame)")
    check(stack.bounds == CGRect(x: 0, y: -116, width: 132, height: 198), "the whole takes it in, got \(stack.bounds)")

    // Over one another, the later is on top until the order changes. Indices count
    // from the bottom of the stack.
    stack.move(1, to: CGPoint(x: 40, y: 30))
    let overlap = CGPoint(x: 60, y: 40)
    func pictureOnTop() -> Int? { stack.topmost(at: overlap).map { stack.layers[$0].picture } }
    check(pictureOnTop() == 1, "the later one on top")
    stack.sendToBack(1)
    check(stack.layers.map(\.picture) == [1, 0] && pictureOnTop() == 0,
          "sent to the back it lies under the other, got \(stack.layers.map(\.picture))")
    stack.bringToFront(1)
    check(stack.layers.map(\.picture) == [1, 0], "already in front: no change")
    stack.bringToFront(0)
    check(stack.layers.map(\.picture) == [0, 1] && pictureOnTop() == 1, "brought to the front")
    check(stack.layers[1].frame == CGRect(x: 40, y: 30, width: 60, height: 50), "a picture keeps its place when restacked")

    // A screenshot added in the editor goes beside what is shown: to the right, tops
    // level, or below, left edges level, whichever leaves the whole nearer a square.
    var tall = LayerStack(frames: [CGRect(x: 0, y: 0, width: 100, height: 300)])
    check(tall.placeForNext(CGSize(width: 100, height: 100)) == CGPoint(x: 116, y: 200),
          "beside a tall picture: to the right, tops level, got \(tall.placeForNext(CGSize(width: 100, height: 100)))")
    let wide = LayerStack(frames: [CGRect(x: 0, y: 0, width: 300, height: 100)])
    check(wide.placeForNext(CGSize(width: 100, height: 100)) == CGPoint(x: 0, y: -116), "below a wide one, lefts level")
    let square = LayerStack(frames: [CGRect(x: 0, y: 0, width: 100, height: 100)])
    check(square.placeForNext(CGSize(width: 100, height: 100)) == CGPoint(x: 116, y: 0), "as square either way: to the right")
    tall.add(picture: 1, at: CGPoint(x: 116, y: 200), size: CGSize(width: 100, height: 100))
    check(tall.isSeveral && tall.layers.last?.picture == 1 && tall.bounds == CGRect(x: -16, y: -16, width: 248, height: 332),
          "added on top, the gap around both, got \(tall.bounds)")

    // Adding after a crop: each picture keeps only what the crop kept, so nothing cut
    // away comes back as the whole grows; a picture the crop left out goes.
    var cropped = LayerStack(frames: [CGRect(x: 16, y: 16, width: 100, height: 50), CGRect(x: 132, y: 16, width: 60, height: 50)])
    cropped.keepOnly(CGRect(x: 30, y: 20, width: 40, height: 30))
    check(cropped.layers.count == 1 && cropped.layers[0].shownFrame == CGRect(x: 30, y: 20, width: 40, height: 30),
          "only what the crop kept, got \(cropped.layers.map(\.shownFrame))")
    check(cropped.layers[0].frame == CGRect(x: 16, y: 16, width: 100, height: 50), "the picture itself stays where it lay")
    check(cropped.bounds == CGRect(x: 30, y: 20, width: 40, height: 30), "one picture again: no gap")
    check(cropped.topmost(at: CGPoint(x: 20, y: 20)) == nil, "the part cut away cannot be picked up")
    cropped.move(0, to: CGPoint(x: 0, y: 0))
    check(cropped.layers[0].shownFrame == CGRect(x: 14, y: 4, width: 40, height: 30), "what is kept moves with the picture")

    // The export: the pictures where they lie, the background between them, the
    // annotations over them, at the sharpest picture's resolution.
    let sharp = CapturedImage(data: makeImageData(width: 200, height: 100, dpi: 144, type: .png))!   // 100 × 50 pt
    let plain = CapturedImage(data: makeImageData(width: 60, height: 50, dpi: 72, type: .png))!      // 60 × 50 pt
    let pictures = LayerStack(frames: [left, right])
    let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    let mark = Annotation(tool: .highlight, color: red, points: [CGPoint(x: 100, y: 0), CGPoint(x: 140, y: 82)])
    if let data = AnnotationRenderer.export(pictures: [sharp, plain], stack: pictures, background: white,
                                            annotations: [mark], area: pictures.bounds),
       let out = CapturedImage(data: data), let image = out.fullSizeUncached() {
        check(out.pointSize == CGSize(width: 208, height: 82) && out.pixelSize == CGSize(width: 416, height: 164),
              "the whole at 2×, got \(out.pointSize) \(out.pixelSize)")
        func at(_ x: CGFloat, _ y: CGFloat) -> (r: Double, g: Double, b: Double) {   // points from the bottom-left
            pixel(image, x: Int(x * 2), y: Int((82 - y) * 2))
        }
        let gap = at(4, 4), first = at(50, 40), second = at(170, 40), marked = at(124, 40)
        check(gap.r > 0.99 && gap.g > 0.99 && gap.b > 0.99, "the background in the gap, got \(gap)")
        check(first.b > 0.8 && first.r < 0.3, "the first picture in its place, got \(first)")
        check(second.b > 0.8 && second.r < 0.3, "the second in its place, got \(second)")
        check(marked.r > 0.99 && marked.g < 0.7, "the highlight over the background, got \(marked)")
    } else { check(false, "several pictures were not exported") }
    // Cropped to a part of the whole.
    if let data = AnnotationRenderer.export(pictures: [sharp, plain], stack: pictures, background: nil,
                                            annotations: [], area: CGRect(x: 120, y: 10, width: 40, height: 30)),
       let out = CapturedImage(data: data), let image = out.fullSizeUncached() {
        check(out.pixelSize == CGSize(width: 80, height: 60), "a crop of the whole, got \(out.pixelSize)")
        var bytes = [UInt8](repeating: 0, count: 80 * 60 * 4)
        let canvas = CGContext(data: &bytes, width: 80, height: 60, bitsPerComponent: 8, bytesPerRow: 80 * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        canvas.draw(image, in: CGRect(x: 0, y: 0, width: 80, height: 60))
        check(bytes[(30 * 80 + 4) * 4 + 3] == 0, "see-through in the gap without a background")
        check(bytes[(30 * 80 + 60) * 4 + 3] == 255, "the second picture inside the crop")
    } else { check(false, "a crop of several pictures was not exported") }

    // A crop made part of the pictures holds for the annotations too: what lay outside it
    // stays out of sight and out of reach, wherever the annotation is moved.
    let across = Annotation(tool: .highlight, color: red, points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 40)])
        .keepingOnly(CGRect(x: 0, y: 0, width: 50, height: 82))
    check(across.hitTest(CGPoint(x: 20, y: 20), tolerance: 0) && !across.hitTest(CGPoint(x: 80, y: 20), tolerance: 0),
          "reached only where it still shows")
    check(across.bounds == CGRect(x: 0, y: 0, width: 50, height: 40), "its bounds are what shows, got \(across.bounds)")
    check(across.moved(by: CGVector(dx: 10, dy: 0)).bounds == CGRect(x: 10, y: 0, width: 50, height: 40),
          "what shows moves with it")
    if let data = AnnotationRenderer.export(pictures: [sharp, plain], stack: LayerStack(frames: [left, right]), background: nil,
                                            annotations: [across], area: CGRect(x: 0, y: 0, width: 208, height: 82)),
       let image = CapturedImage(data: data)?.fullSizeUncached() {
        // On the first picture, 20 points up: 20 points in still shows, 60 points in was cropped away.
        let shown = pixel(image, x: 40, y: 124), hidden = pixel(image, x: 120, y: 124)
        check(shown.r > 0.4, "drawn where it shows, got \(shown)")
        check(hidden.r < 0.3, "not drawn where it was cropped away, got \(hidden)")
    } else { check(false, "a kept annotation was not exported") }

    // A picture that keeps only part of itself is drawn as only that part.
    var partial = LayerStack(frames: [left])
    partial.keepOnly(CGRect(x: 16, y: 16, width: 50, height: 50))
    partial.add(picture: 1, at: CGPoint(x: 82, y: 16), size: plain.pointSize)
    if let data = AnnotationRenderer.export(pictures: [sharp, plain], stack: partial, background: nil,
                                            annotations: [], area: partial.bounds),
       let out = CapturedImage(data: data), let image = out.fullSizeUncached() {
        check(out.pointSize == CGSize(width: 158, height: 82), "the kept part, the new one and the gap, got \(out.pointSize)")
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let canvas = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                               bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        canvas.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        func alpha(_ x: CGFloat, _ y: CGFloat) -> UInt8 { bytes[(Int((82 - y) * 2) * image.width + Int(x * 2)) * 4 + 3] }
        check(alpha(40, 40) == 255, "the part kept is drawn")
        check(alpha(74, 40) == 0, "the part cut away is not, got \(alpha(74, 40))")
        check(alpha(110, 40) == 255, "the new picture beside it")
    } else { check(false, "a picture keeping part of itself was not exported") }
}

/// Cropping: the frame the user adjusts, and the export of the part it keeps.
private func testCropping(base: CapturedImage, red: CGColor, counter: Annotation) {
    func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
    let picture = CGRect(x: 0, y: 0, width: 200, height: 100)
    let frame = CropFrame(rect: CGRect(x: 20, y: 10, width: 100, height: 60))

    // Eight handles: the corners and the middle of each edge, anticlockwise from the bottom left.
    check(frame.handles == [at(20, 10), at(70, 10), at(120, 10), at(120, 40),
                            at(120, 70), at(70, 70), at(20, 70), at(20, 40)],
          "a crop frame has a handle at each corner and edge, got \(frame.handles)")
    check(frame.movingHandle(6, to: at(5, 90), inside: picture).rect == CGRect(x: 5, y: 10, width: 115, height: 80),
          "dragging the top-left corner moves the left and top edges")
    check(frame.movingHandle(3, to: at(150, 0), inside: picture).rect == CGRect(x: 20, y: 10, width: 130, height: 60),
          "dragging the middle of an edge moves that edge only")
    check(frame.movingHandle(2, to: at(500, -50), inside: picture).rect == CGRect(x: 20, y: 0, width: 180, height: 70),
          "a handle stops at the edge of the picture")
    check(frame.movingHandle(7, to: at(400, 40), inside: picture).rect.width == CropFrame.minimumSide,
          "an edge stops short of the opposite one")
    check(frame.moved(by: CGVector(dx: 500, dy: 5), inside: picture).rect == CGRect(x: 100, y: 15, width: 100, height: 60),
          "moving the frame stops at the edge of the picture")
    check(CropFrame.spanning(at(150, 90), at(-10, 50), inside: picture).rect == CGRect(x: 0, y: 50, width: 150, height: 40),
          "a frame dragged out in any direction stays inside the picture")

    // The export keeps only the frame's part of the picture, annotations included.
    let area = CGRect(x: 30, y: 30, width: 50, height: 40)
    if let data = AnnotationRenderer.export(capture: base, annotations: [counter], area: area),
       let out = CapturedImage(data: data), let image = out.fullSizeUncached() {
        check(out.pixelSize == CGSize(width: 100, height: 80), "a cropped export has the frame's size, got \(out.pixelSize)")
        check(out.pointSize == CGSize(width: 50, height: 40), "a cropped export keeps the pixel density, got \(out.pointSize)")
        let disc = pixel(image, x: 22, y: 40)       // the counter, now 20 pt in from the left and the top
        check(disc.r > 0.8 && disc.b < 0.3, "the counter moves with the crop, got \(disc)")
        let rest = pixel(image, x: 90, y: 70)
        check(rest.r < 0.5 && rest.b > 0.6, "the rest of the crop is the picture, got \(rest)")
    } else { check(false, "cropped export failed") }
    if let data = AnnotationRenderer.export(capture: base, annotations: [], area: area) {
        check(CapturedImage(data: data)?.pixelSize == CGSize(width: 100, height: 80), "a crop without annotations is exported too")
    } else { check(false, "crop-only export failed") }
}
