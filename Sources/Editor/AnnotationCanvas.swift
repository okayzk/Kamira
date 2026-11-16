import AppKit

/// The drawing surface: shows the capture and turns mouse gestures into annotations.
/// A click on an existing annotation selects it instead of drawing: it can then be
/// dragged, reshaped by its handles, recoloured or deleted; double-clicking text edits it.
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
    private(set) var annotations: [Annotation] = [] { didSet { needsDisplay = true } }
    /// The annotation being dragged out right now.
    private var current: Annotation? { didSet { needsDisplay = true } }
    /// Index into `annotations` of the selected one.
    private var selected: Int? { didSet { needsDisplay = true } }
    private enum Drag {
        case move(from: CGPoint, original: Annotation)
        case handle(Int)
    }
    /// What the mouse is doing to the selected annotation right now.
    private var drag: Drag?
    /// Earlier states of `annotations`, newest last; undo goes back one.
    private var history: [[Annotation]] = []
    /// The annotation whose colour the last change set, so that dragging through the
    /// colour picker is one undo step rather than dozens.
    private var lastRecolored: Int?
    /// True while the text field holds an existing text annotation taken out for editing.
    private var editingExistingText = false
    /// How close, in view points, a click must be to count as on an annotation.
    private static let grabDistance: CGFloat = 6

    private let imageSize: CGSize
    private let baseImage: CGImage?
    private let mosaic: CGImage?
    /// Live editor for the text tool; replaced by a text annotation when committed.
    private var textField: NSTextField?
    private var textAnchor = CGPoint.zero
    /// View points per image point.
    private var scale: CGFloat { bounds.width / imageSize.width }
    /// How far the scroll view around the canvas is zoomed in. Handles and the distance
    /// that counts as a hit are divided by it, so they stay the same size on screen.
    private var zoom: CGFloat { enclosingScrollView?.magnification ?? 1 }

    init(capture: CapturedImage, size: NSSize, color: CGColor) {
        imageSize = capture.pointSize
        self.color = color
        // Only as many pixels as the canvas can show when zoomed in all the way (never
        // more than the capture has); the export decodes the original itself.
        let backing = NSScreen.underPointer?.backingScaleFactor ?? 2
        let largestZoom = EditorZoom.steps[EditorZoom.steps.count - 1]
        baseImage = capture.downsampled(maxPixel: max(size.width, size.height) * backing * largestZoom)
        mosaic = AnnotationRenderer.mosaicImage(for: capture)
        super.init(frame: NSRect(origin: .zero, size: size))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // The window can be dragged by its background, and AppKit counts a view that is not
    // opaque as background: without this, drawing would drag the window along.
    override var mouseDownCanMoveWindow: Bool { false }
    /// Arrow for the pointer, crosshair for the drawing tools.
    private var restingCursor: NSCursor { tool == nil ? .arrow : .crosshair }
    override func resetCursorRects() { addCursorRect(bounds, cursor: restingCursor) }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if let baseImage = baseImage {
            context.interpolationQuality = .high
            context.draw(baseImage, in: bounds)
        }
        AnnotationRenderer.draw(annotations + (current.map { [$0] } ?? []), in: context,
                                scale: scale, imageSize: imageSize, mosaic: mosaic)
        if let index = selected { drawSelection(of: annotations[index], in: context) }
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

    /// Remembers the present state so that `undo()` can come back to it.
    private func record() {
        history.append(annotations)
        lastRecolored = nil
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
        (handle(at: point) != nil || annotation(at: point) != nil ? NSCursor.openHand : restingCursor).set()
    }

    // MARK: Drawing gestures

    /// Event location in image points, kept inside the image.
    private func imagePoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(point.x, 0), bounds.width) / scale,
                       y: min(max(point.y, 0), bounds.height) / scale)
    }

    override func mouseDown(with event: NSEvent) {
        let hadText = textField != nil
        commitText()
        let point = imagePoint(event)
        // An existing annotation under the pointer takes the click, whatever the tool.
        if let handle = handle(at: point) {
            record()
            drag = .handle(handle)
            return
        }
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
        guard let tool = tool else { return }
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
        if let index = selected, let drag = drag {
            switch drag {
            case .handle(let handle):
                annotations[index] = annotations[index].movingHandle(handle, to: point)
            case .move(let from, let original):
                annotations[index] = original.moved(by: CGVector(dx: point.x - from.x, dy: point.y - from.y),
                                                    keepingInside: CGRect(origin: .zero, size: imageSize))
            }
            return
        }
        guard var annotation = current else { return }
        if annotation.tool == .pen { annotation.points.append(point) }
        else { annotation.points[1] = point }
        current = annotation
    }

    override func mouseUp(with event: NSEvent) {
        if let drag = drag {
            self.drag = nil
            // A click that only selected changed nothing, so there is nothing to undo.
            if case .move(_, let original) = drag, let index = selected,
               annotations[index].points == original.points {
                history.removeLast()
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
        case 53: window?.close() // Esc
        case 51 where selected != nil, 117 where selected != nil: deleteSelected() // Delete, Forward Delete
        default: super.keyDown(with: event)
        }
    }

    func undo() {
        if textField != nil {
            discardText()
        } else if let previous = history.popLast() {
            selected = nil
            lastRecolored = nil
            annotations = previous
        }
    }

    /// Development aid: replays one gesture per tool through the real mouse handlers,
    /// so the drawing path can be checked without touching the pointer.
    func drawSamples(colors: [CGColor], thenEdit: Bool = false) {
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
            let point = convert(NSPoint(x: x * bounds.width, y: y * bounds.height), to: nil)
            return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                      windowNumber: window?.windowNumber ?? 0, context: nil,
                                      eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func gesture(_ tool: AnnotationTool, _ colorIndex: Int, _ path: [(CGFloat, CGFloat)]) {
            self.tool = tool
            selected = nil
            applyColor(colors[colorIndex])
            mouseDown(with: event(.leftMouseDown, path[0].0, path[0].1))
            for step in path.dropFirst() { mouseDragged(with: event(.leftMouseDragged, step.0, step.1)) }
            mouseUp(with: event(.leftMouseUp, path.last!.0, path.last!.1))
        }
        gesture(.arrow, 0, [(0.08, 0.9), (0.28, 0.72)])
        gesture(.line, 2, [(0.08, 0.66), (0.3, 0.66)])
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
        let x = point.x * scale
        // The field's text starts 2 pt in from its frame; line the glyphs up with the click.
        field.frame = NSRect(x: x - 2, y: point.y * scale - height,
                             width: max(40, bounds.width - x), height: height)
        addSubview(field)
        textField = field
        textAnchor = point
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
            annotations.append(Annotation(tool: .text, color: ink, points: [textAnchor], text: text))
        }
        editingExistingText = false
        window?.makeFirstResponder(self)
    }

    private func discardText() {
        guard let field = textField else { return }
        textField = nil
        field.removeFromSuperview()
        // Giving up an edit puts the original text back.
        if editingExistingText, let previous = history.popLast() { annotations = previous }
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
