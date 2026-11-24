import AppKit

/// The drawing surface: shows the capture and turns mouse gestures into annotations.
/// A click on an existing annotation selects it instead of drawing: it can then be
/// dragged, reshaped by its handles, recoloured or deleted; double-clicking text edits it.
/// After a crop the canvas shows only the part kept (`area`); the annotations keep their
/// place on the whole picture, so undoing the crop brings back everything as it was.
/// Several pictures (screenshots combined into one) each lie where the user drags them
/// with the pointer and can be restacked from their menu; the canvas is the whole they
/// make, with the background between them. The annotations lie over all of them and
/// stay where they are drawn.
final class AnnotationCanvas: NSView, NSTextFieldDelegate {
    /// What a drag on empty space draws; nil is the pointer, which only selects.
    var tool: AnnotationTool? {
        didSet { if tool != oldValue { window?.invalidateCursorRects(for: self) } }
    }
    /// Called when the canvas itself changed `tool`: selecting an annotation switches to
    /// the tool that drew it.
    var onToolChange: ((AnnotationTool?) -> Void)?
    /// Colour for new annotations; change it with `applyColor(_:)`.
    private(set) var color: CGColor
    /// Changed only by the canvas. (Not private.)
    var annotations: [Annotation] = [] { didSet { needsDisplay = true } }
    /// The annotation being dragged out right now.
    private var current: Annotation? { didSet { needsDisplay = true } }
    /// Index into `annotations` of the selected one. (Not private, here and below where
    /// marked: the several-pictures half of the canvas is in `AnnotationCanvas+Pictures`.)
    var selected: Int? { didSet { needsDisplay = true } }
    /// Where the pictures lie, bottom to top. Changed only by the canvas.
    var stack: LayerStack { didSet { needsDisplay = true } }
    /// What lies between several pictures; nil is see-through.
    private(set) var background: CGColor? { didSet { needsDisplay = true } }
    /// Called when the background changed, also by undoing.
    var onBackgroundChange: ((CGColor?) -> Void)?
    /// What a crop keeps, in image points; nil keeps everything. (Not private.)
    var crop: CGRect? { didSet { needsDisplay = true } }
    var isCropped: Bool { crop != nil }
    /// The whole as it was when a picture began to be dragged: what is shown holds still
    /// until it is let go.
    private var heldArea: CGRect?
    /// The part shown and exported, in image points: the crop, or else the whole.
    var area: CGRect { crop ?? heldArea ?? stack.bounds }
    /// Called with the previous `area` when a crop, moving a picture, or undoing either changed it.
    var onAreaChange: ((_ previous: CGRect) -> Void)?
    /// Index into `stack.layers` of the selected picture, while there are several. (Not private.)
    var selectedLayer: Int? { didSet { needsDisplay = true } }
    /// What assistive apps see of several pictures, by picture, kept so that they keep
    /// their place after an action. (Not private.)
    var pictureElements: [Int: NSAccessibilityElement] = [:]
    /// The frame being adjusted while cropping; nil otherwise.
    private var cropFrame: CropFrame? {
        didSet {
            needsDisplay = true
            if (cropFrame == nil) != (oldValue == nil) {
                window?.invalidateCursorRects(for: self)
                onCroppingChange?(cropFrame != nil)
            }
        }
    }
    var isCropping: Bool { cropFrame != nil }
    /// Called when cropping begins or ends.
    var onCroppingChange: ((Bool) -> Void)?
    private enum Drag {
        case move(from: CGPoint, original: Annotation)
        case handle(Int)
        case moveCrop(from: CGPoint, original: CropFrame)
        case cropHandle(Int)
        /// A new crop frame dragged out from `from`; a stray click puts `previous` back.
        case newCrop(from: CGPoint, previous: CropFrame)
        /// The selected picture, which lay at `origin`.
        case moveLayer(from: CGPoint, origin: CGPoint)
    }
    /// What the mouse is doing to the selected annotation or the crop frame right now.
    private var drag: Drag?
    /// What undo brings back: the annotations, the crop, where the pictures lie and the
    /// background, together.
    private struct Snapshot {
        var annotations: [Annotation]
        var crop: CGRect?
        var stack: LayerStack
        var background: CGColor?
    }
    /// Earlier states, newest last; undo goes back one.
    private var history: [Snapshot] = []
    /// The annotation whose colour the last change set, so that dragging through the
    /// colour picker is one undo step rather than dozens.
    private var lastRecolored: Int?
    /// The same for the background.
    private var backgroundRecorded = false
    /// True while the text field holds an existing text annotation taken out for editing.
    private var editingExistingText = false
    /// How close, in view points, a click must be to count as on an annotation.
    private static let grabDistance: CGFloat = 6

    /// The pictures as drawn on screen. (Not private.)
    let pictures: EditorPictures
    /// Live editor for the text tool; replaced by a text annotation when committed.
    private var textField: NSTextField?
    var isTyping: Bool { textField != nil }
    private var textAnchor = CGPoint.zero
    /// Where the text being edited may show (`Annotation.clip`).
    private var textClip: CGRect?
    /// View points per image point. (Not private.)
    var scale: CGFloat { bounds.width / area.width }
    /// How far the scroll view around the canvas is zoomed in. Handles and the distance
    /// that counts as a hit are divided by it, so they stay the same size on screen.
    private var zoom: CGFloat { enclosingScrollView?.magnification ?? 1 }

    /// `pictures` lying at `frames`, shown `size` large.
    init(pictures: [CapturedImage], frames: [CGRect], background: CGColor?, size: NSSize, color: CGColor) {
        stack = LayerStack(frames: frames)
        self.background = background
        self.color = color
        self.pictures = EditorPictures(pictures, viewScale: size.width / LayerStack(frames: frames).bounds.width)
        super.init(frame: NSRect(origin: .zero, size: size))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // The window can be dragged by its background, and AppKit counts a view that is not
    // opaque as background: without this, drawing would drag the window along.
    override var mouseDownCanMoveWindow: Bool { false }
    /// Arrow for the pointer, crosshair for the drawing tools and for cropping.
    private var restingCursor: NSCursor { tool == nil && !isCropping ? .arrow : .crosshair }
    override func resetCursorRects() { addCursorRect(bounds, cursor: restingCursor) }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        // Drawn as the whole picture, shifted so that the part kept fills the view.
        context.translateBy(x: -area.minX * scale, y: -area.minY * scale)
        pictures.draw(stack, background: background, in: context, scale: scale)
        AnnotationRenderer.draw(annotations + (current.map { [$0] } ?? []), in: context,
                                scale: scale, mosaic: pictures.mosaic(stack))
        if let index = selectedLayer {
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(2 / zoom)
            context.stroke(stack.layers[index].frame.applying(CGAffineTransform(scaleX: scale, y: scale)))
        }
        if let index = selected { drawSelection(of: annotations[index], in: context) }
        if let frame = cropFrame { drawCrop(frame, in: context) }
        context.restoreGState()
    }

    /// Dims what the crop leaves out and outlines what it keeps, with a handle at each
    /// corner and in the middle of each edge.
    private func drawCrop(_ frame: CropFrame, in context: CGContext) {
        let toView = CGAffineTransform(scaleX: scale, y: scale)
        let kept = frame.rect.applying(toView)
        context.setFillColor(CGColor(gray: 0, alpha: 0.5))
        context.addRect(area.applying(toView))
        context.addRect(kept)
        context.fillPath(using: .evenOdd)
        let point = 1 / zoom
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(point)
        context.stroke(kept)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.35))
        for handle in frame.handles {
            let dot = CGRect(x: handle.x * scale - 4.5 * point, y: handle.y * scale - 4.5 * point,
                             width: 9 * point, height: 9 * point)
            context.fillEllipse(in: dot)
            context.strokeEllipse(in: dot)
        }
    }

    /// Marks the selected annotation: round handles where it can be reshaped, otherwise
    /// a dashed outline. Only on screen, never in the exported picture.
    private func drawSelection(of annotation: Annotation, in context: CGContext) {
        let accent = NSColor.controlAccentColor.cgColor
        context.setStrokeColor(accent)
        let box = annotation.bounds.applying(CGAffineTransform(scaleX: scale, y: scale))
        let handles = annotation.handles
        // One point on screen, however far the canvas is zoomed in.
        let point = 1 / zoom
        if handles.isEmpty {
            context.setLineWidth(1.5 * point)
            context.setLineDash(phase: 0, lengths: [4 * point, 3 * point])
            context.stroke(box.insetBy(dx: -5 * point, dy: -5 * point))
            context.setLineDash(phase: 0, lengths: [])
            return
        }
        if !annotation.isSegment {
            context.setLineWidth(point)
            context.stroke(box)
        }
        context.setLineWidth(1.5 * point)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        for handle in handles {
            let dot = CGRect(x: handle.x * scale - 4.5 * point, y: handle.y * scale - 4.5 * point,
                             width: 9 * point, height: 9 * point)
            context.fillEllipse(in: dot)
            context.strokeEllipse(in: dot)
        }
    }

    /// Remembers the present state so that `undo()` can come back to it. (Not private.)
    func record() {
        history.append(Snapshot(annotations: annotations, crop: crop, stack: stack, background: background))
        lastRecolored = nil
        backgroundRecorded = false
    }

    /// Sets what lies between several pictures. While `continuing` (the colour panel
    /// being dragged through), one undo step covers all of it.
    func applyBackground(_ newBackground: CGColor?, continuing: Bool = false) {
        if !(continuing && backgroundRecorded) {
            record()
            backgroundRecorded = continuing
        }
        background = newBackground
        onBackgroundChange?(newBackground)
    }

    /// The topmost picture under `point`, only while there are several to tell apart. (Not private.)
    func layer(at point: CGPoint) -> Int? {
        stack.isSeveral ? stack.topmost(at: point) : nil
    }

    /// The topmost annotation under `point` (image points).
    private func annotation(at point: CGPoint) -> Int? {
        annotations.indices.last { annotations[$0].hitTest(point, tolerance: Self.grabDistance / scale / zoom) }
    }

    /// The handle of the selected annotation under `point`.
    private func handle(at point: CGPoint) -> Int? {
        guard let index = selected else { return nil }
        let reach = (Self.grabDistance + 2) / scale / zoom
        return annotations[index].handles.firstIndex { hypot($0.x - point.x, $0.y - point.y) <= reach }
    }

    /// Sets the colour for new annotations and recolours the selected one.
    func applyColor(_ newColor: CGColor) {
        color = newColor
        textField?.textColor = NSColor(cgColor: newColor)
        guard let index = selected else { return }
        if lastRecolored != index {
            record()
            lastRecolored = index
        }
        annotations[index].color = newColor
    }

    private func deleteSelected() {
        guard let index = selected else { return }
        record()
        selected = nil
        annotations.remove(at: index)
        annotations = Annotation.renumberingCounters(annotations)
    }

    // The pointer shows whether a click would grab an annotation or draw.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        guard textField == nil else { return }
        let point = imagePoint(event)
        if let frame = cropFrame {
            if let handle = cropHandle(at: point, of: frame) {
                Self.resizeCursor(forCropHandle: handle).set()
            } else {
                (frame.rect != area && frame.rect.contains(point) ? NSCursor.openHand : restingCursor).set()
            }
            return
        }
        let grabs = handle(at: point) != nil || annotation(at: point) != nil || (tool == nil && layer(at: point) != nil)
        (grabs ? NSCursor.openHand : restingCursor).set()
    }

    // MARK: Drawing gestures

    /// Event location in image points, kept inside what is shown unless `anywhere`: a
    /// picture can be dragged beyond the edge, and the whole grows to take it in. (Not private.)
    func imagePoint(_ event: NSEvent, anywhere: Bool = false) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        let x = anywhere ? point.x : min(max(point.x, 0), bounds.width)
        let y = anywhere ? point.y : min(max(point.y, 0), bounds.height)
        return CGPoint(x: area.minX + x / scale, y: area.minY + y / scale)
    }

    override func mouseDown(with event: NSEvent) {
        let hadText = textField != nil
        commitText()
        let point = imagePoint(event)
        dragPoint = nil
        if let frame = cropFrame {
            cropMouseDown(at: point, frame: frame, clickCount: event.clickCount)
            return
        }
        // An existing annotation under the pointer takes the click, whatever the tool.
        if let handle = handle(at: point) {
            record()
            drag = .handle(handle)
            return
        }
        selectedLayer = nil
        if let index = annotation(at: point) {
            selected = index
            if tool != annotations[index].tool {
                tool = annotations[index].tool
                onToolChange?(tool)
            }
            if event.clickCount == 2, annotations[index].tool == .text {
                editText(at: index)
            } else {
                record()
                drag = .move(from: point, original: annotations[index])
            }
            return
        }
        selected = nil
        guard let tool = tool else {
            // The pointer on one of several pictures picks it up.
            if let index = layer(at: point) {
                selectedLayer = index
                record()
                heldArea = area
                drag = .moveLayer(from: imagePoint(event, anywhere: true), origin: stack.layers[index].frame.origin)
            }
            return
        }
        switch tool {
        case .text:
            // A click that just finished one text does not immediately start another.
            if !hadText { beginText(at: point) }
        case .counter:
            let number = annotations.filter { $0.tool == .counter }.count + 1
            record()
            annotations.append(Annotation(tool: .counter, color: color, points: [point], text: "\(number)"))
        default:
            current = Annotation(tool: tool, color: color, points: [point, point])
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = imagePoint(event)
        dragPoint = point
        if isCropping {
            cropMouseDragged(to: point)
        } else if let index = selectedLayer, case .moveLayer(let from, let origin)? = drag {
            let to = imagePoint(event, anywhere: true)
            stack.move(index, to: CGPoint(x: origin.x + to.x - from.x, y: origin.y + to.y - from.y))
        } else if let index = selected, case .move(let from, let original)? = drag {
            annotations[index] = original.moved(by: CGVector(dx: point.x - from.x, dy: point.y - from.y),
                                                keepingInside: area)
        } else if var annotation = current, annotation.tool == .pen {
            annotation.points.append(point)
            current = annotation
        } else {
            stretch(to: point, snappingInside: snapLimit(event))
        }
    }

    /// Where the pointer last was during a drag, so that pressing or letting go of Shift
    /// reshapes what is being drawn without waiting for the pointer to move.
    private var dragPoint: CGPoint?

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        if let point = dragPoint { stretch(to: point, snappingInside: snapLimit(event)) }
    }

    /// What is shown while Shift is held: what `Annotation.snapped` keeps within.
    private func snapLimit(_ event: NSEvent) -> CGRect? {
        event.modifierFlags.contains(.shift) ? area : nil
    }

    /// Takes the end being dragged, of the shape being drawn or of the selected one's
    /// handle, to `point`; with `limit`, snapped as Shift asks.
    private func stretch(to point: CGPoint, snappingInside limit: CGRect?) {
        if let index = selected, case .handle(let handle)? = drag {
            annotations[index] = annotations[index].movingHandle(handle, to: point, snappingInside: limit)
        } else if var annotation = current, annotation.tool != .pen {
            annotation.points[1] = limit.map {
                Annotation.snapped(point, from: annotation.points[0], tool: annotation.tool, inside: $0)
            } ?? point
            current = annotation
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragPoint = nil
        if isCropping {
            cropMouseUp()
            return
        }
        if let drag = drag {
            self.drag = nil
            // A click that only selected changed nothing, so there is nothing to undo.
            if case .move(_, let original) = drag, let index = selected,
               annotations[index].points == original.points {
                history.removeLast()
            }
            if case .moveLayer(_, let origin) = drag, let index = selectedLayer, let held = heldArea {
                if stack.layers[index].frame.origin == origin { history.removeLast() }
                // The whole takes in where the picture was put.
                heldArea = nil
                if area != held { onAreaChange?(held) }
            }
            return
        }
        guard let annotation = current else { return }
        current = nil
        // Ignore stray clicks that did not drag out anything visible.
        let extent = annotation.points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        guard max(extent.width, extent.height) * scale >= 3 else { return }
        record()
        annotations.append(annotation)
        // A new shape shows its handles straight away, ready to be adjusted.
        selected = annotation.handles.isEmpty ? nil : annotations.count - 1
    }

    /// Return or Enter was pressed while not cropping or typing.
    var onReturn: (() -> Void)?

    /// Called when ⌘ with the scroll wheel asks for a zoom of `factor` around a point of the canvas.
    var onZoom: ((_ factor: CGFloat, _ centre: NSPoint) -> Void)?

    // ⌘ with the scroll wheel zooms, for a mouse that cannot pinch; otherwise the wheel
    // moves around the zoomed picture as in any scroll view.
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else { return super.scrollWheel(with: event) }
        onZoom?(1 + max(-0.5, min(0.5, event.scrollingDeltaY * 0.02)), convert(event.locationInWindow, from: nil))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53 where isCropping: cancelCrop() // Esc
        case 53: window?.close()
        case 36 where isCropping, 76 where isCropping: commitCrop() // Return, Enter
        case 36, 76: onReturn?()
        case 51 where selected != nil, 117 where selected != nil: deleteSelected() // Delete, Forward Delete
        default: super.keyDown(with: event)
        }
    }

    /// Leaves cropping without a change, or goes back one step.
    func undo() {
        if textField != nil {
            discardText()
        } else if isCropping {
            cancelCrop()
        } else if let previous = history.popLast() {
            selected = nil
            selectedLayer = nil
            lastRecolored = nil
            backgroundRecorded = false
            let old = area
            annotations = previous.annotations
            crop = previous.crop
            stack = previous.stack
            if previous.background != background {
                background = previous.background
                onBackgroundChange?(background)
            }
            if area != old { onAreaChange?(old) }
        }
    }

    // MARK: Cropping

    /// Shows the crop frame around everything shown, ready to be pulled in by its handles
    /// or dragged out afresh.
    func beginCrop() {
        commitText()
        selected = nil
        selectedLayer = nil
        current = nil
        drag = nil
        cropFrame = CropFrame(rect: area)
    }

    /// Keeps what the frame holds, rounded to whole pixels, and leaves cropping.
    func commitCrop() {
        guard let frame = cropFrame else { return }
        cropFrame = nil
        drag = nil
        let d = pictures.pixelDensity
        let r = frame.rect
        let minX = (r.minX * d).rounded() / d, maxX = (r.maxX * d).rounded() / d
        let minY = (r.minY * d).rounded() / d, maxY = (r.maxY * d).rounded() / d
        let kept = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).intersection(area)
        guard !kept.isNull, kept.width >= CropFrame.minimumSide, kept.height >= CropFrame.minimumSide,
              kept != area else { return }
        record()
        let old = area
        crop = kept
        onAreaChange?(old)
    }

    /// Leaves cropping without changing anything.
    func cancelCrop() {
        drag = nil
        cropFrame = nil
    }

    /// The system's resize pointer for the edge or corner a crop handle moves, in the
    /// order of `CropFrame.handles`.
    private static func resizeCursor(forCropHandle index: Int) -> NSCursor {
        let positions: [NSCursor.FrameResizePosition] = [.bottomLeft, .bottom, .bottomRight, .right,
                                                         .topRight, .top, .topLeft, .left]
        return NSCursor.frameResize(position: positions[index], directions: .all)
    }

    /// The crop handle under `point`, if any.
    private func cropHandle(at point: CGPoint, of frame: CropFrame) -> Int? {
        let reach = (Self.grabDistance + 2) / scale / zoom
        return frame.handles.firstIndex { hypot($0.x - point.x, $0.y - point.y) <= reach }
    }

    /// A handle reshapes the frame and a drag inside it moves it; anywhere else, or
    /// anywhere while the frame still holds everything, a new frame is dragged out.
    /// Double-clicking inside the frame keeps what it holds.
    private func cropMouseDown(at point: CGPoint, frame: CropFrame, clickCount: Int) {
        if let handle = cropHandle(at: point, of: frame) {
            drag = .cropHandle(handle)
        } else if frame.rect != area, frame.rect.contains(point) {
            if clickCount == 2 { return commitCrop() }
            drag = .moveCrop(from: point, original: frame)
        } else {
            drag = .newCrop(from: point, previous: frame)
            cropFrame = CropFrame.spanning(point, point, inside: area)
        }
    }

    private func cropMouseDragged(to point: CGPoint) {
        guard let frame = cropFrame else { return }
        switch drag {
        case .cropHandle(let handle)?:
            cropFrame = frame.movingHandle(handle, to: point, inside: area)
        case .moveCrop(let from, let original)?:
            cropFrame = original.moved(by: CGVector(dx: point.x - from.x, dy: point.y - from.y), inside: area)
        case .newCrop(let from, _)?:
            cropFrame = CropFrame.spanning(from, point, inside: area)
        default:
            break
        }
    }

    private func cropMouseUp() {
        // A click that dragged out nothing visible leaves the frame as it was.
        if case .newCrop(_, let previous)? = drag, let frame = cropFrame,
           min(frame.rect.width, frame.rect.height) * scale < 3 || min(frame.rect.width, frame.rect.height) < CropFrame.minimumSide {
            cropFrame = previous
        }
        drag = nil
    }

    /// Development aid: replays one gesture per tool through the real mouse handlers,
    /// so the drawing path can be checked without touching the pointer.
    /// `thenCrop` goes on to crop the samples: a new frame dragged out over most of the
    /// picture and its right edge pulled in, left there to be kept or cancelled.
    func drawSamples(colors: [CGColor], thenEdit: Bool = false, thenCrop: Bool = false) {
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, _ flags: NSEvent.ModifierFlags) -> NSEvent {
            let point = convert(NSPoint(x: x * bounds.width, y: y * bounds.height), to: nil)
            return NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0,
                                      windowNumber: window?.windowNumber ?? 0, context: nil,
                                      eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func gesture(_ tool: AnnotationTool, _ colorIndex: Int, _ path: [(CGFloat, CGFloat)],
                     _ flags: NSEvent.ModifierFlags = []) {
            self.tool = tool
            selected = nil
            applyColor(colors[colorIndex])
            mouseDown(with: event(.leftMouseDown, path[0].0, path[0].1, flags))
            for step in path.dropFirst() { mouseDragged(with: event(.leftMouseDragged, step.0, step.1, flags)) }
            mouseUp(with: event(.leftMouseUp, path.last!.0, path.last!.1, flags))
        }
        gesture(.arrow, 0, [(0.08, 0.9), (0.28, 0.72)])
        gesture(.line, 2, [(0.08, 0.66), (0.3, 0.66)])
        // With Shift: a slanted drag gives a level line, an oblong one a circle.
        gesture(.line, 3, [(0.3, 0.1), (0.45, 0.14)], .shift)
        gesture(.ellipse, 3, [(0.47, 0.04), (0.52, 0.2)], .shift)
        gesture(.rectangle, 1, [(0.36, 0.62), (0.6, 0.92)])
        gesture(.ellipse, 2, [(0.66, 0.62), (0.9, 0.92)])
        let wave: [(CGFloat, CGFloat)] = (0...20).map { step in
            let t = CGFloat(step)
            return (0.08 + t * 0.012, 0.55 + 0.05 * sin(t * 0.9))
        }
        gesture(.pen, 3, wave)
        gesture(.highlight, 1, [(0.08, 0.36), (0.42, 0.43)])
        gesture(.counter, 0, [(0.5, 0.4)])
        gesture(.counter, 0, [(0.56, 0.4)])
        gesture(.mosaic, 0, [(0.62, 0.12), (0.92, 0.45)])
        gesture(.text, 3, [(0.08, 0.25)])
        textField?.stringValue = "Hello 标注 123"
        commitText()
        if thenCrop {
            beginCrop()
            gesture(.arrow, 0, [(0.04, 0.2), (0.6, 0.95)])
            // The right edge's handle is the fourth, at its middle.
            gesture(.arrow, 0, [(0.6, 0.575), (0.5, 0.575)])
            return
        }
        guard thenEdit else { return }
        // Edit what was just drawn: delete the first counter (the second becomes 1), turn
        // the pen stroke blue, pull the arrow's head, then move the rectangle and leave
        // it selected.
        gesture(.arrow, 0, [(0.5, 0.4)])
        deleteSelected()
        gesture(.arrow, 0, [(0.08, 0.55)])
        applyColor(colors[3])
        gesture(.arrow, 0, [(0.18, 0.81)])
        gesture(.arrow, 0, [(0.28, 0.72), (0.3, 0.55)])
        gesture(.arrow, 0, [(0.36, 0.8), (0.4, 0.7)])
    }

    // MARK: Text tool

    /// Takes a text annotation out of the picture and back into the text field.
    private func editText(at index: Int) {
        let annotation = annotations[index]
        record()
        selected = nil
        annotations.remove(at: index)
        beginText(at: annotation.points[0], editing: annotation)
    }

    private func beginText(at point: CGPoint, editing existing: Annotation? = nil) {
        editingExistingText = existing != nil
        let field = NSTextField(string: existing?.text ?? "")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .boldSystemFont(ofSize: AnnotationRenderer.fontSize * scale)
        field.textColor = NSColor(cgColor: existing?.color ?? color)
        field.delegate = self
        let height = field.fittingSize.height
        let x = (point.x - area.minX) * scale
        // The field's text starts 2 pt in from its frame; line the glyphs up with the click.
        field.frame = NSRect(x: x - 2, y: (point.y - area.minY) * scale - height,
                             width: max(40, bounds.width - x), height: height)
        addSubview(field)
        textField = field
        textAnchor = point
        textClip = existing?.clip
        window?.makeFirstResponder(field)
    }

    /// Turns the text being typed into an annotation. Safe to call when nothing is being typed.
    func commitText() {
        guard let field = textField else { return }
        textField = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        let ink = field.textColor?.cgColor ?? color
        field.removeFromSuperview()
        // Taking an existing text out for editing was already recorded as one step;
        // emptying it deletes it.
        if !text.isEmpty {
            if !editingExistingText { record() }
            annotations.append(Annotation(tool: .text, color: ink, points: [textAnchor], text: text, clip: textClip))
        }
        editingExistingText = false
        window?.makeFirstResponder(self)
    }

    private func discardText() {
        guard let field = textField else { return }
        textField = nil
        field.removeFromSuperview()
        // Giving up an edit puts the original text back.
        if editingExistingText, let previous = history.popLast() { annotations = previous.annotations }
        editingExistingText = false
        window?.makeFirstResponder(self)
    }

    func controlTextDidEndEditing(_ notification: Notification) { commitText() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        discardText()
        return true
    }
}
